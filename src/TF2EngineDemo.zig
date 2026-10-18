//! Demo: hooks two IVEngineServer methods with VTableHooks.VtableHook, to
//! prove the interception actually fires against a live TF2 dedicated
//! server.
//!
//! Changes in this revision: `install` now takes an
//! `EngineVersions.KnownBuild` (the result of `EngineVersions.detect`,
//! called in Entrypoint.zig's `load`) instead of computing
//! `log_print_index`/`server_command_index` itself. Those indices come
//! from a maintained, calibrated table now (see EngineVersions.zig),
//! because different engine builds genuinely have different values for
//! them - a single hard-coded (or even single compiled-in,
//! engine_adapter.cpp-derived) index is only ever correct for the one
//! build it was derived against.
//!
//! `install` still guards against being called twice without an
//! intervening `uninstall` (the `installed` flag) - this is the fix for
//! the crash we diagnosed from crash_20261015214353_2.dmp: a second,
//! unguarded install() captured the first install's own detour as "the
//! original function", so the next real LogPrint call recursed into
//! itself until the stack was exhausted.
//!
//! Note the detours still call through `log_print_hook.original_fn` /
//! `server_command_hook.original_fn` as raw function pointers, *not*
//! through anything that does a fresh virtual dispatch. Whatever's
//! *currently* in the vtable slot, once a hook is installed, is our own
//! detour - routing "call the original" through a fresh virtual call
//! would recreate the exact same infinite-recursion crash, just via a
//! different-looking call. `original_fn` is the one value guaranteed to
//! be the pre-hook implementation, captured once at install time - that
//! has to be what's used to call through.

const std = @import("std");
const VTableHooks = @import("hooks").VTableHook;
const EngineVersions = @import("analyzers/EngineVersions.zig");

const LogPrintFn = *const fn (engine: *anyopaque, msg: [*:0]const u8) callconv(.c) void;
const ServerCommandFn = *const fn (engine: *anyopaque, str: [*:0]const u8) callconv(.c) void;

var log_print_hook: VTableHooks.VtableHook = undefined;
var server_command_hook: VTableHooks.VtableHook = undefined;
var installed = false;

/// Hook 1: every line the engine logs also gets a "[MyLoader]"-tagged
/// echo printed right alongside it - the most visible possible proof the
/// hook fires, since LogPrint is called constantly (server startup alone
/// produces dozens of calls, before you even type anything).
fn detourLogPrint(engine: *anyopaque, msg: [*:0]const u8) callconv(.c) void {
    const original: LogPrintFn = @ptrCast(log_print_hook.original_fn);

    var buf: [512]u8 = undefined;
    const line: [:0]const u8 = if (std.fmt.bufPrintZ(
        &buf,
        "[MyLoader] LogPrint hook fired: {s}",
        .{std.mem.span(msg)},
    )) |formatted|
        formatted
    else |_|
        "[MyLoader] LogPrint hook fired (message too long to echo)\n";

    original(engine, line.ptr);
    original(engine, msg); // let the real message through too, unmodified
}

/// Hook 2: every server console command typed/queued gets echoed with a
/// tag before it runs - type anything at the server console (even just
/// `status`) and you should see it logged twice: once by us, once by
/// whatever actually executes it.
fn detourServerCommand(engine: *anyopaque, str: [*:0]const u8) callconv(.c) void {
    const original: ServerCommandFn = @ptrCast(server_command_hook.original_fn);
    const log_original: LogPrintFn = @ptrCast(log_print_hook.original_fn);

    var buf: [512]u8 = undefined;
    const line: [:0]const u8 = if (std.fmt.bufPrintZ(
        &buf,
        "[MyLoader] ServerCommand hook fired: {s}\n",
        .{std.mem.span(str)},
    )) |formatted|
        formatted
    else |_|
        "[MyLoader] ServerCommand hook fired (command too long to echo)\n";

    log_original(engine, line.ptr);
    original(engine, str);
}

/// `engine` is an IVEngineServer* (see Entrypoint.zig for how one is
/// obtained). `build` is the calibrated-table entry EngineVersions.detect
/// matched against the running engine - its indices, not a guess, are
/// what gets hooked. Installs both demo hooks; on failure, anything
/// already installed is rolled back before the error is returned. A
/// second call while already installed is a harmless no-op.
pub fn install(engine: *anyopaque, build: EngineVersions.KnownBuild) VTableHooks.HookError!void {
    if (installed) return;

    const vtable = VTableHooks.vtableOf(engine);

    log_print_hook = try VTableHooks.VtableHook.install(
        vtable,
        build.log_print_index,
        @ptrCast(&detourLogPrint),
    );
    errdefer log_print_hook.uninstall() catch {};

    server_command_hook = try VTableHooks.VtableHook.install(
        vtable,
        build.server_command_index,
        @ptrCast(&detourServerCommand),
    );

    installed = true;
}

/// Restores both original vtable entries. Call this from your plugin's
/// unload path. A call while not installed is a harmless no-op.
pub fn uninstall() void {
    if (!installed) return;
    server_command_hook.uninstall() catch {};
    log_print_hook.uninstall() catch {};
    installed = false;
}
