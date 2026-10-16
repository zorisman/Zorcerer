//! Demo: hooks two IVEngineServer methods with VTableHooks.VtableHook, to
//! prove the interception actually fires against a live TF2 dedicated
//! server.
//!
//! *** VERIFY THE INDICES BELOW BEFORE RUNNING THIS *** 
//! `log_print_index`/`server_command_index` were counted by hand from the
//! full, in-order IVEngineServer declaration published on the Valve
//! Developer Wiki (https://developer.valvesoftware.com/wiki/IVEngineServer),
//! which matches the long-standing layout most Source games - TF2
//! included - still share for *this specific* interface. IVEngineServer
//! has historically been one of the more stable interfaces (unlike
//! IServerGameDLL, whose INTERFACEVERSION_SERVERGAMEDLL string has bumped
//! repeatedly over TF2's life - 004, up through at least 011 as of a 2022
//! update, and possibly further since), which is why both demo hooks
//! below target IVEngineServer rather than IServerGameDLL. "Historically
//! stable" is not "guaranteed for your exact build", though. Before
//! relying on this:
//!   1. Open your own copy of hl2sdk-tf2/public/eiface.h
//!      (https://github.com/alliedmodders/hl2sdk-tf2) for the branch your
//!      server actually runs.
//!   2. Recount LogPrint's and ServerCommand's position in the class
//!      (0-based, counting every `virtual` declared above each one,
//!      including anything behind game-specific #ifdefs your build
//!      enables).
//!   3. Update the two constants below if your count differs.
//! Getting an index wrong doesn't corrupt anything by itself - the
//! mprotect and the pointer swap both still succeed - but you'll
//! overwrite the *wrong* method's slot. The next time the engine actually
//! calls that slot, it'll jump into a detour expecting different
//! arguments: likely a crash, not a clean failure. Test on a listen
//! server or an empty dedicated server first, not one with players on it.
//!
//! Getting `engine: *anyopaque` (an IVEngineServer*) depends on your
//! loader. If it's a Valve Server Plugin (engine/iserverplugin.h,
//! IServerPluginCallbacks), the engine hands your plugin an
//! `engineFactory` function in `Load()`; call
//! `engineFactory(INTERFACEVERSION_VENGINESERVER, null)` to get it, then
//! pass the result straight into `install` below.

const std = @import("std");
const VTableHooks = @import("hooks").VTableHook;

/// From hl2sdk public/eiface.h - confirm both against your own checkout
/// before relying on them (see the module doc-comment above).
const log_print_index = 76; // IVEngineServer::LogPrint
const server_command_index = 36; // IVEngineServer::ServerCommand

const LogPrintFn = *const fn (engine: *anyopaque, msg: [*:0]const u8) callconv(.c) void;
const ServerCommandFn = *const fn (engine: *anyopaque, str: [*:0]const u8) callconv(.c) void;

var log_print_hook: VTableHooks.VtableHook = undefined;
var server_command_hook: VTableHooks.VtableHook = undefined;

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

/// `engine` is an IVEngineServer* (see the module doc-comment for how to
/// obtain one). Installs both demo hooks; on failure, anything already
/// installed is rolled back before the error is returned.
pub fn install(engine: *anyopaque) VTableHooks.HookError!void {
    const vtable = VTableHooks.vtableOf(engine);

    log_print_hook = try VTableHooks.VtableHook.install(
        vtable,
        log_print_index,
        @ptrCast(&detourLogPrint),
    );
    errdefer log_print_hook.uninstall() catch {};

    server_command_hook = try VTableHooks.VtableHook.install(
        vtable,
        server_command_index,
        @ptrCast(&detourServerCommand),
    );
}

/// Restores both original vtable entries. Call this from your plugin's
/// unload path - leaving a hook installed into a vtable that's about to
/// be unloaded (or that outlives your detour functions' module) is a
/// guaranteed crash.
pub fn uninstall() void {
    server_command_hook.uninstall() catch {};
    log_print_hook.uninstall() catch {};
}
