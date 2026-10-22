//! Minimal logging front-end for the plugin manager (src/PluginManager.zig).
//!
//! logLine() formats one message and sends it to the Source SDK logging
//! system: the engine's IVEngineServer::LogPrint, expressed as the
//! context/print pair of abi.Logger (src/PluginContext.zig). Allowing any other
//! destination is out of scope for now.
//!
//! The hook into the engine stays with the entrypoint: it resolves the
//! IVEngineServer pointer and its LogPrint vtable slot, then hands them
//! over with setup(). Until that happens, logLine() silently drops
//! messages, mirroring how Manager.logLine() behaves before setLogger().

const std = @import("std");
const abi = @import("PluginContext.zig");

/// The captured Source SDK logging sink: the engine context paired with
/// its LogPrint entry, exactly as Logger describes it. Null until setup().
var logger: ?abi.Logger = null;

/// Captures the Source SDK logging sink used by every later logLine()
/// call. Intended to be called once, when the engine interface becomes
/// available (see Entrypoint.zig's load() and PluginManager.setLogger()).
pub fn setup(sink: abi.Logger) void {
    logger = sink;
}

/// Formats `fmt` with `args` and sends the result through the Source SDK
/// logging system captured by setup(); calls before setup() do nothing.
/// Callers supply the trailing "\n" in `fmt`. On a too-long message only
/// a fixed note is sent, mirroring Manager.logLine()'s behavior.
pub fn logLine(comptime fmt: []const u8, args: anytype) void {
    const sink = logger orelse return;

    var buf: [512]u8 = undefined;
    const line: [:0]const u8 = if (std.fmt.bufPrintZ(&buf, fmt, args)) |formatted|
        formatted
    else |_|
        "[zorcerer] (message too long to log)\n";
    sink.print(sink.context, line.ptr);
}
