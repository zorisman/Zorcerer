//! Foundation for loading our plugin loader into a TF2 dedicated server as
//! a Valve Server Plugin (VSP) - the same, Valve-documented mechanism
//! Metamod:Source itself uses to get loaded, rather than substituting or
//! LD_PRELOAD-wrapping server.so/engine.so.
//!
//! Engine-side indices and version strings come from exactly one place:
//! codegen_generated/engine_indexes.zig. Its producer,
//! build/EngineIndexesGenerator.zig, runs during the build: the analyzer
//! adapter feeds it the C++ analyzer's stdout, and it writes the generated
//! file directly. Nothing in this file hand-maintains an index or a
//! version string of its own.
//!
//! Engine version handling in `load` no longer needs the removed
//! src/analyzers/EngineVersions.zig: the engine server interface is
//! probed directly against the version strings the codegen module knows
//! (see engine_interface_versions), and the version check in load()
//! refuses every build whose answered string does not equal the one the
//! codegen indices were generated for. That leaves the version probe
//! reduced to "which string answered" - the part the removed module used
//! to own.
//!
//! The plugin manager itself runs in a forked child process. `load` forks it
//! through `forkChild`, the child loads the plugins (`pluginManagerChild`) and
//! reports over a socket pair, and this process consumes that report through
//! `jsonListener`. The child then serves VSP callback events through the
//! manager's own listener (`PluginManager.listenForEvents`).
//!
//! Messages are framed JSON-RPC 2.0 messages (see src/Ipc.zig). The manager's
//! readiness report is a `ready` notification whose `params.message` is the
//! child's readiness text. The callbacks send a request named after the event
//! and receive a JSON-RPC result `"Event is X"` (or an error response).
//! `unload` closes the parent's socket end, which tells the child to unload
//! its plugins and exit, then reaps it.
//!
//! *** VERIFY BEFORE USE ***
//! The IServerPluginCallbacks method list below follows the Valve
//! Developer Wiki (https://developer.valvesoftware.com/wiki/IServerPluginCallbacks)
//! and the historical public/engine/iserverplugin.h header. The first
//! nine methods (Load through LevelShutdown) have been stable across
//! every version of this interface I could find and are implemented for
//! real. Everything after that - the client/command callbacks added in
//! later interface versions (ClientConnect, ClientCommand,
//! NetworkIDValidated, OnQueryCvarValueFinished, OnEdictAllocated/Freed,
//! ...) - is backed by `genericStub`, a placeholder that safely ignores
//! whatever arguments it's called with and returns 0 (== false ==
//! PLUGIN_CONTINUE == null, a safe default for all of them).
//!
//! This padding exists so that if your exact TF2 build's interface has a
//! few more trailing methods than the nine implemented here, the engine
//! calling into one of them lands on a harmless no-op instead of jumping
//! into unmapped memory. It is NOT a substitute for implementing the
//! callbacks you actually want to act on - look up their real position
//! in your hl2sdk-tf2 checkout (public/engine/iserverplugin.h) and
//! replace the matching stub slot. `stub_count` is a guess at "more than
//! enough"; too large is harmless (an unindexed stub is simply never
//! called), but too *small* for your build's real interface means a call
//! past the end of the array - a crash. When in doubt, raise it.
//!
//! `plugin_interface_versions` - the versions of *our own*
//! IServerPluginCallbacks *we* claim to implement - is a separate concern
//! from engine-side detection: a wrong entry there just means
//! CreateInterface returns null for it and the engine tries the next one
//! (or logs an error and moves on) - it can't crash anything the way a
//! wrong engine-side vtable index can, so it doesn't need the same
//! verified-match treatment, even though it now comes from the codegen
//! too (consistency, not safety).
//!
//! Build with `zig build`: the result is zig-out/lib/zorcerer.so, built
//! for the x86_64-linux-gnu target configured in build.zig. Drop the .so
//! at `<mod>/addons/<name>.so` alongside a matching .vdf, e.g.
//! `tf/addons/zorcerer.so` + `tf/addons/zorcerer.vdf`. For fast iteration
//! without restarting the server, the engine also supports
//! loading/unloading a VSP interactively from the server console:
//! `plugin_load addons/zorcerer` / `plugin_unload <index>` (index shown
//! by `plugin_print`) - no .vdf needed while testing. Note `plugin_load`
//! only works before a map is running (see the console-command discussion
//! earlier) - the .vdf route is what actually loads this on a live server.

const std = @import("std");
const zjr = @import("zjr");
const Ipc = @import("Ipc.zig");
const VTableHooks = @import("hooks").VTableHook;
const root = @import("../root.zig");
const Indexes = root.codegen.indexes;
const Manager = @import("PluginManager.zig");
const Log = root.io.Log;
const abi = root.abi;
const fork = @import("ForkProcess.zig");
const JsonRpc = @import("JsonRpc.zig");
const Vsp = @import("Vsp.zig");

/// An IServerPluginCallbacks instance is just a vptr as far as the engine
/// is concerned - no RTTI header to worry about, since nothing does
/// dynamic_cast/typeid on a plugin interface the engine loaded generically.
const PluginObject = extern struct {
    vptr: [*]const Vsp.Slot,
};

/// VSP callbacks this Entrypoint implements. `Vsp.VTable` owns the slot
/// order; this instance only selects the concrete functions.
const plugin_vtable = Vsp.VTable{
    .load = load,
    .unload = unload,
    .pause = pause,
    .unpause = unpause,
    .getPluginDescription = getPluginDescription,
    .levelInit = levelInit,
    .serverActivate = serverActivate,
    .levelShutdown = levelShutdown,
};

/// Stable storage for the slot array generated from `plugin_vtable`. It must
/// outlive the engine's use of the plugin instance, so it lives in a global
/// rather than on `CreateInterface`'s stack. `CreateInterface` fills it
/// before publishing `plugin_instance` to the engine.
var source_vtable: [Vsp.VTable.slot_count]Vsp.Slot = undefined;

var plugin_instance = PluginObject{ .vptr = &source_vtable };
var engine: ?*anyopaque = null;

/// Plugin manager singleton. The forked child (`pluginManagerChild`) uses it to
/// discover/cache the plugin .so files under tf/addons/zorcerer/plugins/, run
/// each plugin's load() hook, and serve callback events through
/// `Manager.listenForEvents`. The parent only wires the engine logger into its
/// copy before forking and keeps the manifests from `readConfig()`; the child's
/// own copy is released when it exits (see src/PluginManager.zig).
var plugin_manager = Manager.Manager.init();

/// The forked plugin-manager process, or null while none runs.
var manager_child: ?fork.ForkedChild = null;

/// Child body: loads the plugin manager, reports readiness to the parent, and
/// then serves callback events until the parent closes the channel.
///
/// Readiness is sent after the load attempt finishes, whether or not any
/// plugins were found. A successful attempt sends `manager_ready_message`; a
/// failed one sends the failure text, which the parent treats as a failed
/// startup instead of ignoring it.
///
/// The listener runs even when loading failed, so the Entrypoint's synchronous
/// event exchange never blocks on a process that has already stopped reading.
///
/// Unlike a minimal reporting child, this one allocates and performs file and
/// dynamic-library I/O while loading plugins. That is safe only as long as the
/// parent is effectively single-threaded when `forkChild` is called, which
/// holds for the engine's VSP `Load` call.
fn pluginManagerChild(fd: std.os.linux.fd_t) void {
    // The child must not call the engine's inherited LogPrint after the fork;
    // route manager and plugin messages to the parent over IPC instead.
    plugin_manager.setIpcLogger(fd);

    plugin_manager.loadPlugins() catch |err| {
        // A global failure (unreadable plugin root, out of memory, ...) is
        // reported as a failed readiness text so the parent refuses startup.
        var message_buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "plugin load failed: {s}",
            .{@errorName(err)},
        ) catch "plugin load failed";
        Ipc.sendReady(fd, message) catch return;
        Manager.listenForEvents(fd);
        plugin_manager.unloadAll();
        return;
    };

    Ipc.sendReady(fd, fork.manager_ready_message) catch return;
    Manager.listenForEvents(fd);
    plugin_manager.unloadAll();
}

fn load(
    this: *anyopaque,
    interface_factory: Vsp.CreateInterfaceFn,
    game_server_factory: Vsp.CreateInterfaceFn,
) callconv(.c) bool {
    _ = this;
    _ = game_server_factory;

    // Extracting the Source engine's console logging function, in three
    // steps:
    //   1. Get the engine interface itself out of the engine: probe the
    //      engine module's CreateInterface factory with the IVEngineServer
    //      version strings the codegen knows (newest first) and remember
    //      the string that actually answered.
    //   2. Receive the LogPrint pointer out of that interface via
    //      logPrintOf(), which picks the virtual method table slot the
    //      codegen recorded under IVEngineServer.log_print.
    //   3. Capture both in the Log module as its Source SDK logging sink,
    //      before any load decision is made, so even the refusal messages
    //      below reach the server console. The same print function is
    //      handed to the plugin manager further down.
    //
    // Only a matching engine build is fully trustworthy: for any refused
    // build the single log call in the refusal path may go through a slot
    // whose meaning shifted with the engine version - the accepted
    // trade-off for being able to report the refusal at all. Without any
    // answered engine build there is nothing to extract the logger from
    // and no working channel to report that fact through; the load is
    // refused immediately.
    var probe_version_buf: [32]u8 = undefined;
    const engine_version: []const u8 = version: {
        for (Vsp.engine_interface_versions) |requested_version| {
            const engine_module_name = std.fmt.bufPrintZ(
                &probe_version_buf,
                "{s}",
                .{requested_version},
            ) catch break :version "";
            engine = interface_factory(engine_module_name.ptr, null);

            if (engine != null) {
                break :version requested_version;
            }
        }
        break :version "";
    };
    if (engine_version.len == 0) {
        return false;
    }

    if (!std.mem.eql(u8, engine_version, Indexes.interfaceversion_vengineserver)) {
        Log.logLine(
            "[Zorcerer] engine version mismatch: indices are for {s}, engine answered as {s} - refusing to install hooks\n",
            .{ Indexes.interfaceversion_vengineserver, engine_version },
        );
        return false;
    }

    Log.logLine("[Zorcerer] Load() reached, engine version confirmed: {s}\n", .{engine_version});

    if (manager_child != null) {
        Log.logLine("[Zorcerer] plugin manager is already running; refusing a second one\n", .{});
        return false;
    }

    manager_child = fork.forkChild(pluginManagerChild) catch |err| {
        Log.logLine("[Zorcerer] forking the plugin manager failed: {s}\n", .{@errorName(err)});
        return false;
    };

    // Waits for the child's readiness report, forwarding any log lines it sends
    // on the way. A failed plugin load is reported as a failed readiness text,
    // so it refuses the startup instead of returning a successful load. The
    // child keeps running (and the socket open) afterwards; unload() is what
    // closes the socket and reaps it.
    JsonRpc.jsonListener(manager_child.?.socket, null) catch |err| {
        if (err != error.PluginLoadFailed) {
            Log.logLine("[Zorcerer] plugin manager startup failed: {s}\n", .{@errorName(err)});
        }
        if (manager_child) |*child| child.finish() catch {};
        manager_child = null;
        return false;
    };

    const manifests = plugin_manager.readConfig() catch null;
    if (manifests) |m| {
        for (m) |manifest| {
            std.debug.print("\n{s}: {s}\n", .{ manifest.id, manifest.version });
        }
    }

    return true;
}

fn unload(this: *anyopaque) callconv(.c) void {
    _ = this;
    Log.logLine("[Zorcerer] unloading, removing demo hooks.\n", .{});

    if (manager_child) |*child| {
        // Closing our end is the shutdown signal: the child's event listener
        // sees EOF, unloads its plugins and exits, so finish() can reap it.
        child.finish() catch |err| {
            Log.logLine("[Zorcerer] plugin manager shutdown failed: {s}\n", .{@errorName(err)});
        };
        manager_child = null;
    }

    // Releases the manifests the parent parsed in load(). The child's plugin
    // state lived in its own copy of the manager and is already gone.
    plugin_manager.deinit();
    engine = null;
    // The Log module keeps the captured sink: the engine interface stays
    // resident for the whole process lifetime, so it remains valid, and
    // plugin_load/reload re-captures it in load() anyway.
}

/// Reports one VSP callback to the forked plugin manager and executes its
/// reply.
///
/// Does nothing while no manager process is running (before `load` succeeds or
/// after `unload`). The exchange is synchronous: the manager answers every
/// event with exactly one response frame, which `jsonListener` prints, so
/// "Event is X" reaches stderr before the callback returns. Log notifications
/// sent by the child meanwhile are forwarded instead of being mistaken for the
/// response.
///
/// `payload` is optional JSON text with event parameters; the manager forwards
/// it unchanged to Lua scripts and native plugins.
///
/// The engine invokes VSP callbacks from one thread at a time; this function
/// is not reentrant and must not be called concurrently.
///
/// Errors are logged rather than propagated: the engine callbacks have no way
/// to report failure, and `unload` owns the manager's lifetime.
fn sendManagerEvent(event: Ipc.Event, payload: ?[]const u8) void {
    const child = if (manager_child) |*running| running else return;

    Ipc.sendEvent(child.socket, event, payload) catch |err| {
        Log.logLine(
            "[Zorcerer] sending the {s} event to the plugin manager failed: {s}\n",
            .{ @tagName(event), @errorName(err) },
        );
        return;
    };

    JsonRpc.jsonListener(child.socket, Ipc.event_request_id) catch |err| {
        Log.logLine(
            "[Zorcerer] handling the plugin manager's reply to {s} failed: {s}\n",
            .{ @tagName(event), @errorName(err) },
        );
    };
}

/// VSP `Pause` callback: notifies the manager that the game was paused.
fn pause(this: *anyopaque) callconv(.c) void {
    _ = this;
    sendManagerEvent(.pause, null);
}

/// VSP `UnPause` callback: notifies the manager that the game was unpaused.
fn unpause(this: *anyopaque) callconv(.c) void {
    _ = this;
    sendManagerEvent(.unpause, null);
}

/// VSP `GetPluginDescription` callback: returns the text the engine shows in
/// `plugin_print`. The returned string is static and needs no release.
fn getPluginDescription(this: *anyopaque) callconv(.c) [*:0]const u8 {
    _ = this;
    return "Zorcerer";
}

/// VSP `LevelInit` callback: logs the map and notifies the manager.
/// `map_name` is the engine-owned, zero-terminated map name; it is only read
/// during this call. The manager receives it in the event payload as JSON.
fn levelInit(this: *anyopaque, map_name: [*:0]const u8) callconv(.c) void {
    _ = this;
    const name = std.mem.span(map_name);
    Log.logLine("[Zorcerer] LevelInit: {s}\n", .{name});

    const allocator = std.heap.page_allocator;
    const payload = std.json.Stringify.valueAlloc(allocator, .{ .map = name }, .{}) catch null;
    defer if (payload) |text| allocator.free(text);
    sendManagerEvent(.levelInit, payload);
}

/// VSP `ServerActivate` callback: logs the edict and client limits and
/// notifies the manager. `edict_list` is deliberately ignored because the
/// manager receives no engine memory across the process boundary.
fn serverActivate(
    this: *anyopaque,
    edict_list: *anyopaque,
    edict_count: c_int,
    client_max: c_int,
) callconv(.c) void {
    _ = this;
    _ = edict_list;
    Log.logLine("[Zorcerer] ServerActivate: {d} edicts, {d} max clients\n", .{ edict_count, client_max });

    const allocator = std.heap.page_allocator;
    const payload = std.json.Stringify.valueAlloc(
        allocator,
        .{ .edict_count = edict_count, .client_max = client_max },
        .{},
    ) catch null;
    defer if (payload) |text| allocator.free(text);
    sendManagerEvent(.serverActivate, payload);
}

/// VSP `LevelShutdown` callback: logs the shutdown and notifies the manager.
fn levelShutdown(this: *anyopaque) callconv(.c) void {
    _ = this;
    Log.logLine("[Zorcerer] LevelShutdown\n", .{});
    sendManagerEvent(.levelShutdown, null);
}

pub export fn CreateInterface(name: [*:0]const u8, return_code: ?*c_int) callconv(.c) ?*anyopaque {
    const requested = std.mem.span(name);
    for (Vsp.plugin_interface_versions) |version| {
        if (std.mem.eql(u8, requested, version)) {
            // Initialize before publishing the instance: the engine uses the
            // vptr as soon as CreateInterface returns.
            source_vtable = plugin_vtable.intoSourceVTable();
            if (return_code) |rc| rc.* = Vsp.iface_ok;
            return @ptrCast(&plugin_instance);
        }
    }
    if (return_code) |rc| rc.* = Vsp.iface_failed;
    return null;
}
