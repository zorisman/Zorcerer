//! The `shutdown` message schema for the IPC channel.
//!
//! The engine process asks the plugin-manager child for an orderly exit with
//! one JSON-RPC request; the child unloads every plugin, answers, and stops
//! serving the channel.

const std = @import("std");
const zjr = @import("zjr");
const Frame = @import("Frame.zig");
const Identifiers = @import("IdentifierRegistry.zig").Identifiers;

/// JSON-RPC method the engine process uses to request an orderly child exit.
pub const shutdown_method = "shutdown";

/// A shutdown request parsed from a JSON-RPC request.
///
/// `rpc` owns the parsed JSON until `deinit()`.
pub const ParsedShutdown = struct {
    /// Parsed JSON-RPC request carrying the shutdown request.
    rpc: zjr.RpcRequestResult,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *const ParsedShutdown) void {
        self.rpc.deinit();
    }

    /// Returns the request ID used for the matching response.
    pub fn id(self: *const ParsedShutdown) zjr.RpcId {
        return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNone();
    }
};

/// Parses one JSON-RPC shutdown request.
///
/// Returns `error.UnknownMethod` for any other method so a caller can fall
/// through to event parsing, and `error.NotRpcRequest` when `text` is a
/// response or batch.
///
/// Errors: `error.NotRpcRequest`, `error.InvalidRpcRequest`, and
/// `error.UnknownMethod` as described above.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !ParsedShutdown {
    var rpc = zjr.parseRpcRequest(allocator, text);
    errdefer rpc.deinit();

    if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
    const request = rpc.request_msg.request;
    if (request.hasError()) return error.InvalidRpcRequest;
    if (!std.mem.eql(u8, request.method, shutdown_method)) return error.UnknownMethod;

    return .{ .rpc = rpc };
}

/// Sends the orderly-shutdown request to the plugin-manager child.
///
/// Uses `Identifiers.shutdown_request_id` so the child can match the response.
///
/// Errors: `error.OutOfMemory` while composing the request and the framing
/// errors of `Frame.write`.
pub fn send(fd: std.os.linux.fd_t) !void {
    const allocator = std.heap.page_allocator;
    const payload = try zjr.composer.makeRequestJson(
        allocator,
        shutdown_method,
        null,
        Identifiers.shutdown_request_id.rpcId(),
    );
    defer allocator.free(payload);
    try Frame.write(fd, payload);
}
