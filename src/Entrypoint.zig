//! Foundation for loading our plugin loader into a TF2 dedicated server as
//! a Valve Server Plugin (VSP) - the same, Valve-documented mechanism
//! Metamod:Source itself uses to get loaded, rather than substituting or
//! LD_PRELOAD-wrapping server.so/engine.so.
//!
//! Changes in this revision: `engine_interface_version` and
//! `log_print_index` are no longer hard-coded. Different engine builds
//! have genuinely different values for both (that's exactly why the
//! original hard-coded numbers were dangerous - correct for one branch,
//! silently wrong on another) - see EngineVersions.zig for the detector
//! and the maintained table of calibrated values it looks them up from.
//! If the running engine doesn't match anything in that table, `load`
//! refuses cleanly (logged nowhere, since we don't have a verified
//! LogPrint index to log *through* yet - that's the one case where this
//! can't report its own failure) rather than guessing.
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
//! from engine-side detection: it's a list, not a single guess, because
//! a wrong entry there just means CreateInterface returns null for it
//! and the engine tries the next one (or logs an error and moves on) -
//! it can't crash anything the way a wrong engine-side vtable index can,
//! so it doesn't need the same calibrated-table treatment.
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
const TF2EngineDemo = @import("TF2EngineDemo.zig");
const EngineVersions = @import("EngineVersions.zig");

const iface_ok: c_int = 0;
const iface_failed: c_int = 1;

/// Version strings this plugin answers to, newest first. All of them get
/// the same vtable - the padding described above is what makes that safe.
const plugin_interface_versions = [_][:0]const u8{
    "ISERVERPLUGINCALLBACKS003",
    "ISERVERPLUGINCALLBACKS002",
    "ISERVERPLUGINCALLBACKS001",
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

var load_calls: usize = 0;
var unload_calls: usize = 0;

fn load(
    this: *anyopaque,
    interface_factory: EngineVersions.CreateInterfaceFn,
    game_server_factory: EngineVersions.CreateInterfaceFn,
) callconv(.c) bool {
    // _ = this;
    // _ = game_server_factory;

    // Refuses cleanly (just `return false`) on an unrecognized build -
    // we deliberately do NOT fall back to a guessed index here. See the
    // module doc-comment and EngineVersions.zig for why.
    const detection = EngineVersions.detect(interface_factory) catch {
        return false;
    };

    engine = detection.engine;
    const engine_vtable = VTableHooks.vtableOf(detection.engine);
    log_print = @ptrCast(engine_vtable[detection.build.log_print_index]);
    std.debug.print("{d}", .{@intFromPtr(engine_vtable[detection.build.log_print_index])});
    logLine("[MyLoader] Load() reached, recognized engine build: {s}\n", .{detection.build.engine_version});

    TF2EngineDemo.install(detection.engine, detection.build) catch |err| {
        logLine("[MyLoader] failed to install demo hooks: {s}\n", .{@errorName(err)});
        return false;
    };

    logLine("[MyLoader] demo hooks installed.\n", .{});

    load_calls += 1;

    std.debug.print(
        "[Zorcerer] Load #{d}: this=0x{x}, engine_factory=0x{x}, game_factory=0x{x}\n",
        .{
            load_calls,
            @intFromPtr(this),
            @intFromPtr(interface_factory),
            @intFromPtr(game_server_factory),
        },
    );
    return true;
}

fn unload(this: *anyopaque) callconv(.c) void {
    // _ = this;
    logLine("[MyLoader] unloading, removing demo hooks.\n", .{});
    TF2EngineDemo.uninstall();
    engine = null;
    log_print = null;

    unload_calls += 1;

    std.debug.print(
        "[Zorcerer] Unload #{d}: this=0x{x}\n",
        .{
            unload_calls,
            @intFromPtr(this),
        },
    );
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
