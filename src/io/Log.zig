//! Minimal logging front-end for the plugin manager (src/PluginManager.zig).
//!
//! Outside the forked plugin-manager process, logLine() formats one message
//! and sends it to the Source SDK logging system: the engine's
//! IVEngineServer::LogPrint, expressed as the context/print pair of abi.Logger
//! (src/PluginContext.zig).
//!
//! The hook into the engine stays with the entrypoint: it resolves the
//! IVEngineServer pointer and its LogPrint vtable slot, then hands them
//! over with setup(). Until that happens, logLine() silently drops
//! messages, mirroring how Manager.logLine() behaves before setLogger().
//!
//! The forked child inherits the parent's engine sink, which must not be
//! called across the fork. setupIpc() replaces that sink: from then on every
//! message is sent to the parent as an IPC `stderr` notification, and the
//! parent forwards it to the engine console. pluginPrint() exposes the same
//! IPC-backed sink to plugins through abi.Logger.

const std = @import("std");
const abi = @import("../PluginContext.zig");
const Ipc = @import("../Ipc.zig");

/// The captured Source SDK logging sink: the engine context paired with
/// its LogPrint entry, exactly as Logger describes it. Null until setup() or
/// while an IPC sink is active.
var logger: ?abi.Logger = null;

/// Parent connection used for logging from the forked child. Null in the
/// parent process and before setupIpc().
var ipc_fd: ?std.os.linux.fd_t = null;

/// Message substituted when a formatted line does not fit the log buffer.
const too_long_message = "[zorcerer] (message too long to log)\n";

/// Captures the Source SDK logging sink used by every later logLine()
/// call. Intended to be called once, when the engine interface becomes
/// available (see Entrypoint.zig's load() and PluginManager.setLogger()).
/// Clears any IPC sink, because this sink belongs to the engine process.
pub fn setup(sink: abi.Logger) void {
    logger = sink;
    ipc_fd = null;
}

/// Replaces the inherited engine sink with the IPC channel to the parent.
///
/// Intended for the forked plugin-manager process: calling the engine's
/// LogPrint after a fork is unsafe, so every later logLine() and
/// pluginPrint() call becomes a `stderr` notification on `fd` instead.
pub fn setupIpc(fd: std.os.linux.fd_t) void {
    logger = null;
    ipc_fd = fd;
}

/// Formats `fmt` with `args` and sends the result through the active sink:
/// the Source SDK logging system captured by setup(), or the parent IPC
/// channel captured by setupIpc(). Calls with neither sink do nothing.
/// Callers supply the trailing "\n" in `fmt`. On a too-long message only
/// a fixed note is sent, mirroring Manager.logLine()'s behavior.
pub fn logLine(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line: [:0]const u8 = if (std.fmt.bufPrintZ(&buf, fmt, args)) |formatted|
        formatted
    else |_|
        too_long_message;

    if (ipc_fd) |fd| {
        Ipc.sendRequest(fd, .{ .operation = .stderr, .message = line }) catch {};
        return;
    }

    const sink = logger orelse return;
    sink.print(sink.context, line.ptr);
}

/// Prints one plugin message through the active sink.
///
/// Signature-compatible with abi.Logger.PrintFn so PluginManager can hand it
/// to plugins as `HostApi.logger.print`. The context is unused; the sink is
/// process-global. After setupIpc() the message is sent to the parent over
/// IPC; otherwise it goes to the engine sink from setup(). Messages are
/// dropped while neither sink is configured.
pub fn pluginPrint(context: *anyopaque, message: [*:0]const u8) callconv(.c) void {
    _ = context;

    if (ipc_fd) |fd| {
        Ipc.sendRequest(fd, .{ .operation = .stderr, .message = std.mem.span(message) }) catch {};
        return;
    }

    const sink = logger orelse return;
    sink.print(sink.context, message);
}
