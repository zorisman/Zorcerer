//! Foundation for loading our plugin loader into a TF2 dedicated server as
//! a Valve Server Plugin (VSP) - the same, Valve-documented mechanism
//! Metamod:Source itself uses to get loaded, rather than substituting or
//! LD_PRELOAD-wrapping server.so/engine.so.
//!
//! Engine-side indices and version strings come from exactly one place:
//! codegen_generated/engine_indexes.zig. That file is committed by hand;
//! its producer, build/EngineIndexesGenerator.zig, is not wired into the
//! build yet. Nothing in this file hand-maintains an index or a version
//! string of its own.
//!
//! Engine version detection in `load` is being reworked after
//! src/analyzers/EngineVersions.zig was removed. Until that rewrite
//! lands, some calls and inline comments below still refer to the
//! deleted module and are not current.
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
const VTableHooks = @import("hooks").VTableHook;
const Indexes = @import("codegen_generated/engine_indexes.zig");
const Manager = @import("PluginManager.zig");
const Log = @import("log");
const abi = @import("plugin-abi");

pub const CreateInterfaceFn = *const fn (name: [*:0]const u8, return_code: ?*c_int) callconv(.c) ?*anyopaque;

const iface_ok: c_int = 0;
const iface_failed: c_int = 1;

/// Version strings this plugin answers to, newest first. All of them get
/// the same vtable - the padding described above is what makes that safe.
const plugin_interface_versions = [_][]const u8{
    Indexes.interfaceversion_iserverplugincallbacks,
    Indexes.interfaceversion_iserverplugincallbacks_version_2,
    Indexes.interfaceversion_iserverplugincallbacks_version_1,
};

const Slot = ?*const anyopaque;

/// An IServerPluginCallbacks instance is just a vptr as far as the engine
/// is concerned - no RTTI header to worry about, since nothing does
/// dynamic_cast/typeid on a plugin interface the engine loaded generically.
const PluginObject = extern struct {
    vptr: [*]const Slot,
};

var plugin_instance = PluginObject{ .vptr = &vtable };
var engine: ?*anyopaque = null;

/// Plugin manager singleton. load() wires the engine logger into it, then
/// discovers/caches the plugin .so files under tf/addons/zorcerer/plugins/
/// and runs each plugin's load() hook; unload() runs the unload() hooks
/// again and releases everything (see src/PluginManager.zig).
var plugin_manager = Manager.Manager.init();

fn load(
    this: *anyopaque,
    interface_factory: CreateInterfaceFn,
    game_server_factory: CreateInterfaceFn,
) callconv(.c) bool {
    _ = this;
    _ = game_server_factory;

    // Wiring for every log line below: the entrypoint logs only through
    // the Log module, whose single routing point cannot work until the
    // engine's IVEngineServer pointer and LogPrint vtable slot are
    // captured as its Source SDK logging sink. This happens right after
    // detection, before any decision is made, so that even the refusal
    // messages below reach the server console. The same print function
    // is handed to the plugin manager further down, though its own
    // setLogger() would capture the identical sink for it.
    Log.setup(.{ .context = engine.?, .print = print_fn });

    // The codegen's indices and version strings were generated from
    // exactly one engine build: whatever CreateInterface actually
    // answered when engine_indexes.zig was produced. Hooks whose
    // positions came from those indices are only valid for an engine
    // answering the same version string. Checking it here makes that
    // invariant visible in the server's own log instead of leaving it
    // implicit, and this is the one spot that must start doing real
    // work if detection is ever loosened to accept more than one
    // version string.
    if (!std.mem.eql(u8, detection.engine_version, Indexes.interfaceversion_vengineserver)) {
        Log.logLine(
            "[MyLoader] engine version mismatch: indices are for {s}, engine answered as {s} - refusing to install hooks\n",
            .{ Indexes.interfaceversion_vengineserver, detection.engine_version },
        );
        return false;
    }

    Log.logLine("[MyLoader] Load() reached, engine version confirmed: {s}\n", .{detection.engine_version});

    // From here on the engine pointers are valid; hand them to the plugin
    // manager as the way every scanned plugin prints into the server
    // console, then discover and load the plugins.
    plugin_manager.setLogger(engine.?, print_fn);
    plugin_manager.loadPlugins() catch |err| {
        // A scan that ends badly can only leave zero plugins (loadPlugins
        // unloads on the way out); the server load itself continues.
        Log.logLine("[MyLoader] plugin loading failed: {s}\n", .{@errorName(err)});
    };

    const manifests: ?[]const Manager.Manifest = plugin_manager.readConfig() catch null;
    if (manifests) |m| {
        for (m) |manifest| {
            std.debug.print("\n{s}: {s}\n", .{ manifest.id, manifest.version });
        }
    }

    return true;
}

fn unload(this: *anyopaque) callconv(.c) void {
    _ = this;
    Log.logLine("[MyLoader] unloading, removing demo hooks.\n", .{});
    // Runs every active plugin's unload() and releases the caches; the
    // manager itself stays reusable for a plugin_load/reload of ours.
    plugin_manager.deinit();
    engine = null;
    // The Log module keeps the captured sink: the engine interface stays
    // resident for the whole process lifetime, so it remains valid, and
    // plugin_load/reload re-captures it in load() anyway.
}

fn pause(this: *anyopaque) callconv(.c) void {
    _ = this;
}

fn unpause(this: *anyopaque) callconv(.c) void {
    _ = this;
}

fn getPluginDescription(this: *anyopaque) callconv(.c) [*:0]const u8 {
    _ = this;
    return "MyLoader foundation (Zig)";
}

fn levelInit(this: *anyopaque, map_name: [*:0]const u8) callconv(.c) void {
    _ = this;
    Log.logLine("[MyLoader] LevelInit: {s}\n", .{std.mem.span(map_name)});
}

fn serverActivate(
    this: *anyopaque,
    edict_list: *anyopaque,
    edict_count: c_int,
    client_max: c_int,
) callconv(.c) void {
    _ = this;
    _ = edict_list;
    Log.logLine("[MyLoader] ServerActivate: {d} edicts, {d} max clients\n", .{ edict_count, client_max });
}

fn gameFrame(this: *anyopaque, simulating: bool) callconv(.c) void {
    _ = this;
    _ = simulating;
}

fn levelShutdown(this: *anyopaque) callconv(.c) void {
    _ = this;
    Log.logLine("[MyLoader] LevelShutdown\n", .{});
}

/// Placeholder for every method this foundation doesn't implement yet.
/// Declared with zero parameters on purpose: the calling convention
/// doesn't validate argument count on entry, so this safely ignores
/// whatever registers/stack the real call set up and returns 0 in the
/// return register - false / PLUGIN_CONTINUE / null, whichever the real
/// signature expected. Replace the corresponding slot below once you
/// actually need that callback to do something.
fn genericStub() callconv(.c) usize {
    return 0;
}

/// "More than enough" trailing slots for interface versions newer than
/// what's implemented above. Raise this if your SDK header has more
/// methods than this accounts for; see the module doc-comment.
const stub_count = 20;

const vtable = [_]Slot{
    @ptrCast(&load),
    @ptrCast(&unload),
    @ptrCast(&pause),
    @ptrCast(&unpause),
    @ptrCast(&getPluginDescription),
    @ptrCast(&levelInit),
    @ptrCast(&serverActivate),
    @ptrCast(&gameFrame),
    @ptrCast(&levelShutdown),
} ++ ([_]Slot{@ptrCast(&genericStub)} ** stub_count);

export fn CreateInterface(name: [*:0]const u8, return_code: ?*c_int) callconv(.c) ?*anyopaque {
    const requested = std.mem.span(name);
    for (plugin_interface_versions) |version| {
        if (std.mem.eql(u8, requested, version)) {
            if (return_code) |rc| rc.* = iface_ok;
            return @ptrCast(&plugin_instance);
        }
    }
    if (return_code) |rc| rc.* = iface_failed;
    return null;
}
