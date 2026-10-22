//! Foundation for loading our plugin loader into a TF2 dedicated server as
//! a Valve Server Plugin (VSP) - the same, Valve-documented mechanism
//! Metamod:Source itself uses to get loaded, rather than substituting or
//! LD_PRELOAD-wrapping server.so/engine.so.
//!
//! Changes in this revision: every engine-side index and version string
//! now comes from exactly one place - codegen_generated/engine_indexes.zig,
//! produced at build time by EngineIndexesGenerator.zig. Nothing in this
//! file (or TF2EngineDemo.zig, or EngineVersions.zig) hand-maintains an
//! index or a version string of its own any more. `load` also now makes
//! the version check explicit: it compares the engine version the
//! codegen's indices were generated for against the version that
//! actually answered CreateInterface, and logs the result either way,
//! rather than only ever implicitly relying on EngineVersions.detect
//! having already enforced that by construction.
//!
//! Also cleaned up here: the load_calls/unload_calls counters and the
//! raw std.debug.print pointer dumps from the "LogPrint isn't firing"
//! troubleshooting session are gone - that was diagnostic scaffolding for
//! one specific investigation, not something to ship. The one piece of
//! that session worth keeping permanently is the early, pre-LogPrint
//! failure path being visible at all (see `debugWriteStderr` below) -
//! everything else was temporary.
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
//! I could not compile-check this file myself (no Zig 0.16 toolchain,
//! and obviously no TF2 dedicated server, available in this environment)
//! - please build and load it on a listen/test server first, not
//! production.
//!
//! Build as a shared library for x86-linux (32-bit - confirmed from the
//! crash dump analyzed earlier). Drop the result at `<mod>/addons/<name>.so`
//! alongside the matching myplugin.vdf, e.g. `tf/addons/zorcerer.so` +
//! `tf/addons/zorcerer.vdf`. For fast iteration without restarting the
//! server, the engine also supports loading/unloading a VSP interactively
//! from the server console: `plugin_load addons/zorcerer` /
//! `plugin_unload <index>` (index shown by `plugin_print`) - no .vdf
//! needed while testing. Note `plugin_load` only works before a map is
//! running (see the console-command discussion earlier) - the .vdf route
//! is what actually loads this on a live server.

const std = @import("std");
const VTableHooks = @import("hooks").VTableHook;
const EngineVersions = @import("analyzers/EngineVersions.zig");
const Indexes = @import("codegen_generated/engine_indexes.zig");
const Manager = @import("PluginManager.zig");

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

/// Saved across calls so LevelInit/ServerActivate/etc. can log through
/// them. Null until Load() succeeds.
var engine: ?*anyopaque = null;

const LogPrintFn = *const fn (engine: *anyopaque, msg: [*:0]const u8) callconv(.c) void;
var log_print: ?LogPrintFn = null;

/// Plugin manager singleton. load() wires the engine logger into it, then
/// discovers/caches the plugin .so files under tf/addons/zorcerer/plugins/
/// and runs each plugin's load() hook; unload() runs the unload() hooks
/// again and releases everything (see src/PluginManager.zig).
var plugin_manager = Manager.Manager.init();

fn logLine(comptime fmt: []const u8, args: anytype) void {
    const e = engine orelse return;
    const print = log_print orelse return;

    var buf: [512]u8 = undefined;
    const line: [:0]const u8 = if (std.fmt.bufPrintZ(&buf, fmt, args)) |formatted|
        formatted
    else |_|
        "[MyLoader] (message too long to log)\n";
    print(e, line.ptr);
}

/// Writes straight to the process's own stderr via a raw syscall, no
/// engine involved. The *only* place this project reaches for this
/// instead of `logLine`: the one early failure path in `load` where, by
/// definition, we don't have a verified LogPrint pointer to log through
/// yet - which is also exactly the failure mode that produced total
/// silence during the earlier "LogPrint isn't firing" investigation.
/// Writing here means a detection failure is now visible in the server's
/// own console/log instead of vanishing.
fn debugWriteStderr(msg: []const u8) void {
    _ = std.os.linux.write(2, msg.ptr, msg.len);
}

fn load(
    this: *anyopaque,
    interface_factory: EngineVersions.CreateInterfaceFn,
    game_server_factory: EngineVersions.CreateInterfaceFn,
) callconv(.c) bool {
    _ = this;
    _ = game_server_factory;

    const detection = EngineVersions.detect(interface_factory) catch {
        // EngineVersions.detectOlderVersion is diagnostic-only - it does
        // NOT give us indices to fall back on (see EngineVersions.zig).
        // Finding a name here only changes *what gets logged*, never
        // whether we proceed: we still refuse either way.
        if (EngineVersions.detectOlderVersion(interface_factory)) |older| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "[MyLoader] engine answered as {s}, but indices were generated for {s} - refusing to load\n",
                .{ older, Indexes.interfaceversion_vengineserver },
            ) catch "[MyLoader] engine is an older, recognized build, but indices don't match it - refusing to load\n";
            debugWriteStderr(msg);
        } else {
            debugWriteStderr("[MyLoader] unrecognized engine build - refusing to load\n");
        }
        return false;
    };

    engine = detection.engine;
    log_print = @ptrCast(VTableHooks.vtableOf(detection.engine)[Indexes.IVEngineServer.log_print]);

    // The check this revision specifically adds: compare the engine
    // version the codegen's indices were generated for against the
    // version that actually answered CreateInterface, and say so in the
    // log either way - rather than only ever relying on
    // EngineVersions.detect having already enforced that match
    // internally. Given detect()'s current (deliberately strict) design,
    // `detection.engine_version` can only ever already equal
    // `Indexes.interfaceversion_vengineserver` here - this can't actually
    // fire today. It's still worth doing: it turns an invariant enforced
    // by code elsewhere into something visible in the server's own log,
    // and it's the one spot that would need to start doing real work if
    // `detect` is ever loosened to accept more than one version string.
    if (!std.mem.eql(u8, detection.engine_version, Indexes.interfaceversion_vengineserver)) {
        logLine(
            "[MyLoader] engine version mismatch: indices are for {s}, engine answered as {s} - refusing to install hooks\n",
            .{ Indexes.interfaceversion_vengineserver, detection.engine_version },
        );
        return false;
    }

    logLine("[MyLoader] Load() reached, engine version confirmed: {s}\n", .{detection.engine_version});

    // From here on the engine pointers are valid; hand them to the plugin
    // manager as the way every scanned plugin prints into the server
    // console, then discover and load the plugins.
    plugin_manager.setLogger(engine.?, log_print.?);
    plugin_manager.loadPlugins() catch |err| {
        // A scan that ends badly can only leave zero plugins (loadPlugins
        // unloads on the way out); the server load itself continues.
        logLine("[MyLoader] plugin loading failed: {s}\n", .{@errorName(err)});
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
    logLine("[MyLoader] unloading, removing demo hooks.\n", .{});
    // Runs every active plugin's unload() and releases the caches; the
    // manager itself stays reusable for a plugin_load/reload of ours.
    plugin_manager.deinit();
    engine = null;
    log_print = null;
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
    logLine("[MyLoader] LevelInit: {s}\n", .{std.mem.span(map_name)});
}

fn serverActivate(
    this: *anyopaque,
    edict_list: *anyopaque,
    edict_count: c_int,
    client_max: c_int,
) callconv(.c) void {
    _ = this;
    _ = edict_list;
    logLine("[MyLoader] ServerActivate: {d} edicts, {d} max clients\n", .{ edict_count, client_max });
}

fn gameFrame(this: *anyopaque, simulating: bool) callconv(.c) void {
    _ = this;
    _ = simulating;
}

fn levelShutdown(this: *anyopaque) callconv(.c) void {
    _ = this;
    logLine("[MyLoader] LevelShutdown\n", .{});
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
