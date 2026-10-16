//! Foundation for loading our plugin loader into a TF2 dedicated server as
//! a Valve Server Plugin (VSP) - the same, Valve-documented mechanism
//! Metamod:Source itself uses to get loaded, rather than substituting or
//! LD_PRELOAD-wrapping server.so/engine.so.
//!
//! *** VERIFY BEFORE USE ***
//! The method list below follows IServerPluginCallbacks as documented on
//! the Valve Developer Wiki
//! (https://developer.valvesoftware.com/wiki/IServerPluginCallbacks) and
//! the historical public/engine/iserverplugin.h header. The first nine
//! methods (Load through LevelShutdown) have been stable across every
//! version of this interface I could find and are implemented for real.
//! Everything after that - the client/command callbacks added in later
//! interface versions (ClientConnect, ClientCommand, NetworkIDValidated,
//! OnQueryCvarValueFinished, OnEdictAllocated/Freed, ...) - is backed by
//! `genericStub`, a placeholder that safely ignores whatever arguments
//! it's called with and returns 0 (== false == PLUGIN_CONTINUE == null,
//! a safe default for all of them).
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
//! Also unverified: `engine_interface_version` ("VEngineServer022") and
//! the vtable index (76) used to grab IVEngineServer::LogPrint for our
//! own startup messages - same numbers TF2EngineDemo.zig already uses
//! and flags; see that file's doc-comment for how to re-derive them.
//! `plugin_interface_versions` is a list, not a single guess: a wrong
//! *plugin* version string just means CreateInterface returns null for
//! it and the engine tries the next one in its own list, or logs an
//! error and moves on - it does not crash anything, unlike a wrong
//! vtable index.
//!
//! I could not compile-check this file myself (no Zig 0.16 toolchain,
//! and obviously no TF2 dedicated server, available in this environment)
//! - please build and load it on a listen/test server first, not
//! production.
//!
//! Build as a shared library for x86_64-linux. Drop the result at
//! `<mod>/addons/<name>.so` alongside the matching myplugin.vdf (see the
//! sibling file), e.g. `tf/addons/myloader.so` + `tf/addons/myloader.vdf`.
//! For fast iteration without restarting the server, the engine also
//! supports loading/unloading a VSP interactively from the server
//! console: `plugin_load addons/myloader` / `plugin_unload <index>`
//! (index shown by `plugin_print`) - no .vdf needed while testing.

const std = @import("std");
const VTableHooks = @import("hooks").VTableHook;
const TF2EngineDemo = @import("TF2EngineDemo.zig");

/// From public/tier1/interface.h.
const CreateInterfaceFn = *const fn (name: [*:0]const u8, return_code: ?*c_int) callconv(.c) ?*anyopaque;
const iface_ok: c_int = 0;
const iface_failed: c_int = 1;

/// Version strings this plugin answers to, newest first. All of them get
/// the same vtable - the padding described above is what makes that safe.
const plugin_interface_versions = [_][:0]const u8{
    "ISERVERPLUGINCALLBACKS003",
    "ISERVERPLUGINCALLBACKS002",
    "ISERVERPLUGINCALLBACKS001",
};

/// From hl2sdk public/eiface.h - same values TF2EngineDemo.zig uses.
const engine_interface_version = "VEngineServer022";
const log_print_index = 76;

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

fn load(
    this: *anyopaque,
    interface_factory: CreateInterfaceFn,
    game_server_factory: CreateInterfaceFn,
) callconv(.c) bool {
    _ = this;
    _ = game_server_factory;

    const engine_ptr = interface_factory(engine_interface_version, null) orelse return false;
    engine = engine_ptr;

    const engine_vtable = VTableHooks.vtableOf(engine_ptr);
    log_print = @ptrCast(engine_vtable[log_print_index]);
    logLine("[MyLoader] Load() reached, IVEngineServer acquired.\n", .{});

    TF2EngineDemo.install(engine_ptr) catch |err| {
        logLine("[MyLoader] failed to install demo hooks: {s}\n", .{@errorName(err)});
        return false;
    };

    logLine("[MyLoader] demo hooks installed.\n", .{});
    return true;
}

fn unload(this: *anyopaque) callconv(.c) void {
    _ = this;
    logLine("[MyLoader] unloading, removing demo hooks.\n", .{});
    TF2EngineDemo.uninstall();
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
/// Declared with zero parameters on purpose: the x86-64 SysV calling
/// convention doesn't validate argument count on entry, so this safely
/// ignores whatever registers/stack the real call set up and returns 0 in
/// rax - false / PLUGIN_CONTINUE / null, whichever the real signature
/// expected. Replace the corresponding slot below once you actually need
/// that callback to do something.
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
