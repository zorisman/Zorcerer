//! One operation notification sent by the plugin-manager child.
//!
//! The child reports log lines (`.stderr`) and its readiness (`.ready`) as
//! JSON-RPC notifications; the Entrypoint's listener executes them without a
//! reply.

const std = @import("std");
const zjr = @import("zjr");
const Frame = @import("Frame.zig");
const Operation = @import("Operation.zig").Operation;

/// This module as the request type: its fields carry the notification.
const Request = @import("Request.zig");

/// What the receiver should do with `message`.
operation: Operation,
/// Payload for `operation`; for `.stderr` it is logged verbatim, for
/// `.ready` it is the child's readiness text.
message: []const u8,

/// Parses one JSON-RPC operation notification.
///
/// Unknown methods, malformed requests, and missing or non-string `message`
/// parameters are rejected. The returned value owns the parsed JSON until
/// `deinit()`.
///
/// Errors: `error.NotRpcRequest` when `text` is a response or batch,
/// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
/// `error.UnknownMethod` for an operation this module does not implement,
/// `error.InvalidParams`/`error.MissingMessage` for malformed parameters.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !ParsedRequest {
    var rpc = zjr.parseRpcRequest(allocator, text);
    errdefer rpc.deinit();

    if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
    const request = rpc.request_msg.request;
    if (request.hasError()) return error.InvalidRpcRequest;

    const operation = Operation.fromMethod(request.method) orelse return error.UnknownMethod;
    const params = request.objectParams() orelse return error.InvalidParams;
    const message_value = params.get("message") orelse return error.MissingMessage;
    const message = switch (message_value) {
        .string => |value| value,
        else => return error.InvalidParams,
    };

    return .{
        .rpc = rpc,
        .value = .{ .operation = operation, .message = message },
    };
}

/// Serializes `self` as a JSON-RPC notification and sends it as one frame.
///
/// The notification has no `id`, as required for JSON-RPC notifications.
/// Errors: `error.WriteFailed`/`error.OutOfMemory` from message composition,
/// and `error.PayloadTooLarge`/`error.WriteFailed` from `Frame.write`.
pub fn send(self: *const @This(), fd: std.os.linux.fd_t) !void {
    const allocator = std.heap.page_allocator;
    const payload = try zjr.composer.makeRequestJson(
        allocator,
        @tagName(self.operation),
        .{ .message = self.message },
        zjr.RpcId.ofNone(),
    );
    defer allocator.free(payload);
    try Frame.write(fd, payload);
}

/// Reports the child's readiness state with a `ready` notification.
///
/// `message` is the child's readiness text. The Entrypoint treats its expected
/// readiness text as success and any other text as a failed startup.
/// Errors are those of `send`.
pub fn ready(fd: std.os.linux.fd_t, message: []const u8) !void {
    var request = @This(){ .operation = .ready, .message = message };
    try request.send(fd);
}

/// An operation notification parsed from a JSON-RPC request.
///
/// `value` borrows the JSON owned by `rpc`; both stay valid until `deinit()`.
const ParsedRequest = struct {
    /// Parsed JSON-RPC request. Its `params` hold the operation message.
    rpc: zjr.RpcRequestResult,
    /// Operation and message extracted from `rpc`.
    value: Request,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *const @This()) void {
        self.rpc.deinit();
    }

    /// Returns the request ID, which is `.none` for a notification.
    pub fn id(self: *const @This()) zjr.RpcId {
        return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNone();
    }
};
