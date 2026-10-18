//! Demo: hooks two IVEngineServer methods with VTableHooks.VtableHook, to
//! prove the interception actually fires against a live TF2 dedicated
//! server.
//!
//! Changes in this revision: `log_print_index`/`server_command_index`
//! are no longer passed in from an `EngineVersions.KnownBuild` (that
//! type is gone - see EngineVersions.zig). `install` reads
//! `Indexes.IVEngineServer.log_print`/`.server_command` directly from
//! codegen_generated/engine_indexes.zig instead - the single source of
//! truth for every index in this project now, produced at build time by
//! EngineIndexesGenerator.zig (which drives VTableIndexAnalyzer.cpp's
//! Clang-AST analysis) rather than hand-maintained anywhere in Zig.
//! `install` no longer needs an engine-build parameter at all: it's not
//! choosing between calibrated values for different builds any more,
//! it's using the one set of indices the codegen produced, full stop.
//! Entrypoint.zig is responsible for confirming (via EngineVersions.detect)
//! that the running engine actually matches the version those indices
//! were generated for *before* calling this - this file doesn't re-check
//! that itself, so don't call `install` with an engine pointer that
//! hasn't been through that check.
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
const Indexes = @import("codegen_generated/engine_indexes.zig");

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

/// `engine` is an IVEngineServer* that Entrypoint.zig has already
/// confirmed (via EngineVersions.detect) matches the engine version
/// `Indexes.IVEngineServer`'s indices were generated for. Installs both
/// demo hooks; on failure, anything already installed is rolled back
/// before the error is returned. A second call while already installed
/// is a harmless no-op.
pub fn install(engine: *anyopaque) VTableHooks.HookError!void {
    if (installed) return;

    const vtable = VTableHooks.vtableOf(engine);

    log_print_hook = try VTableHooks.VtableHook.install(
        vtable,
        Indexes.IVEngineServer.log_print,
        @ptrCast(&detourLogPrint),
    );
    errdefer log_print_hook.uninstall() catch {};

    server_command_hook = try VTableHooks.VtableHook.install(
        vtable,
        Indexes.IVEngineServer.server_command,
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
