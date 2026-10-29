//! Framed JSON-RPC 2.0 messages for the IPC channel between `Entrypoint.zig`
//! and the forked plugin-manager process (`PluginManager.zig`).
//!
//! One message is one frame on the connected stream socket created for the
//! fork:
//!
//!     marker (1 byte, 0xA5) | length (u32, little-endian) | JSON payload
//!
//! The payload is a JSON-RPC 2.0 request, notification, or response. Both
//! processes use this module, so the framing and the message schema cannot
//! drift apart. `writeAll` sends with `MSG_NOSIGNAL`, so a peer that already
//! exited yields `error.WriteFailed` instead of terminating the process with
//! SIGPIPE.

const std = @import("std");
const zjr = @import("zjr");

/// Largest payload, in bytes, one frame may carry.
///
/// The length is read before the payload, so the receiver can reject an
/// oversized frame instead of blocking on a corrupt length.
pub const max_payload_len: usize = 4096;

/// First byte of every frame.
///
/// It distinguishes a frame from a truncated or desynchronized stream: without
/// it the following length bytes cannot be interpreted.
const frame_marker: u8 = 0xA5;

/// Request ID used by `sendEvent`.
///
/// The Entrypoint sends callback events synchronously, one at a time, so a
/// fixed positive ID is sufficient and lets the listener match the response.
pub const event_request_id: i64 = 1;

/// One frame read from the channel.
///
/// The flags describe what arrived, not what was expected: a peer that sent a
/// marker and then closed can yield `framed == true` with no payload.
pub const Frame = struct {
    /// True when the first byte was `frame_marker`.
    framed: bool = false,

    /// True when the frame carried at least one payload byte.
    received: bool = false,

    /// Raw payload bytes. Only the first `payload_len` entries are meaningful.
    payload: [max_payload_len]u8 = undefined,

    /// Number of valid bytes in `payload`; never exceeds `payload.len`.
    payload_len: usize = 0,

    /// Returns the received payload.
    ///
    /// The returned slice borrows this frame and remains valid for as long as
    /// the frame does.
    pub fn text(self: *const Frame) []const u8 {
        return self.payload[0..self.payload_len];
    }

    /// Reports whether the payload equals `expected`.
    ///
    /// Returns false when a payload of a different length arrived.
    pub fn matches(self: *const Frame, expected: []const u8) bool {
        return std.mem.eql(u8, self.text(), expected);
    }
};

/// Reads one frame from `fd`.
///
/// The returned frame owns its payload bytes. A first byte that does not match
/// `frame_marker` yields `framed == false` and stops reading, because the rest
/// of the frame cannot be interpreted without the marker.
///
/// Errors: `error.PeerClosed` for a truncated frame, `error.PayloadTooLarge`
/// when the announced length exceeds `max_payload_len`, and `error.ReadFailed`
/// for a non-`EINTR` read failure.
pub fn readFrame(fd: std.os.linux.fd_t) !Frame {
    var frame = Frame{};

    var marker: [1]u8 = undefined;
    try readExact(fd, &marker);
    frame.framed = marker[0] == frame_marker;
    if (!frame.framed) return frame;

    var length_bytes: [4]u8 = undefined;
    try readExact(fd, &length_bytes);
    const payload_len: usize = std.mem.readInt(u32, &length_bytes, .little);
    if (payload_len > max_payload_len) return error.PayloadTooLarge;

    try readExact(fd, frame.payload[0..payload_len]);
    frame.payload_len = payload_len;
    frame.received = payload_len > 0;
    return frame;
}

/// Writes one frame carrying `payload` to `fd`.
///
/// Precondition: `fd` is the connected stream socket used for the IPC channel.
///
/// Errors: `error.PayloadTooLarge` when `payload` exceeds `max_payload_len`,
/// and `error.WriteFailed` when the peer closed or any other write failed.
pub fn writeFrame(fd: std.os.linux.fd_t, payload: []const u8) !void {
    if (payload.len > max_payload_len) return error.PayloadTooLarge;

    var header: [5]u8 = undefined;
    header[0] = frame_marker;
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);

    try writeAll(fd, &header);
    try writeAll(fd, payload);
}

/// Reads exactly `buffer.len` bytes from `fd`.
///
/// Errors: `error.PeerClosed` when the peer closed first; `error.ReadFailed`
/// for any other read failure (see `readAtMost`).
fn readExact(fd: std.os.linux.fd_t, buffer: []u8) !void {
    const read_len = try readAtMost(fd, buffer);
    if (read_len != buffer.len) return error.PeerClosed;
}

/// Reads from `fd` until `buffer` is full or the peer closes its end.
///
/// Returns the number of bytes read. Retries interrupted reads. Returns
/// `error.ReadFailed` for a non-`EINTR` read failure.
fn readAtMost(fd: std.os.linux.fd_t, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const rc = std.os.linux.read(fd, buffer[total..].ptr, buffer.len - total);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                total += rc;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
    return total;
}

/// Writes all of `buffer` to the connected socket `fd`.
///
/// Uses `MSG_NOSIGNAL` so a peer that already closed the channel produces an
/// error instead of SIGPIPE. Retries interrupted and partial writes.
///
/// Errors: `error.WriteFailed` on any write failure.
fn writeAll(fd: std.os.linux.fd_t, buffer: []const u8) !void {
    var written: usize = 0;
    while (written < buffer.len) {
        const rc = std.os.linux.sendto(
            fd,
            buffer[written..].ptr,
            buffer.len - written,
            std.os.linux.MSG.NOSIGNAL,
            null,
            0,
        );
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.WriteFailed;
                written += rc;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

/// Operations the Entrypoint's JSON-RPC listener understands.
pub const Operation = enum {
    /// Write `message` to the parent's log sink.
    stderr,
    /// Report that the plugin-manager child finished its load attempt.
    ///
    /// The message is the child's readiness text. The Entrypoint treats its
    /// expected readiness text as success and any other text as a startup
    /// failure.
    ready,
};

/// Parameters of one operation notification.
///
/// Schemas:
///
///     {"jsonrpc": "2.0", "method": "stderr", "params": {"message": "..."}}
///     {"jsonrpc": "2.0", "method": "ready", "params": {"message": "..."}}
pub const Request = struct {
    /// What the receiver should do with `message`.
    operation: Operation,
    /// Payload for `operation`; for `.stderr` it is logged verbatim, for
    /// `.ready` it is the child's readiness text.
    message: []const u8,
};

/// An operation notification parsed from a JSON-RPC request.
///
/// `value` borrows the JSON owned by `rpc`; both stay valid until `deinit()`.
pub const ParsedRequest = struct {
    /// Parsed JSON-RPC request. Its `params` hold the operation message.
    rpc: zjr.RpcRequestResult,
    /// Operation and message extracted from `rpc`.
    value: Request,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *const ParsedRequest) void {
        self.rpc.deinit();
    }

    /// Returns the request ID, which is `.none` for a notification.
    pub fn id(self: *const ParsedRequest) zjr.RpcId {
        return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNone();
    }
};

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
pub fn parseRequest(allocator: std.mem.Allocator, text: []const u8) !ParsedRequest {
    var rpc = zjr.parseRpcRequest(allocator, text);
    errdefer rpc.deinit();

    if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
    const request = rpc.request_msg.request;
    if (request.hasError()) return error.InvalidRpcRequest;

    const operation = operationFromMethod(request.method) orelse return error.UnknownMethod;
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

/// Serializes `request` as a JSON-RPC notification and sends it as one frame.
///
/// The notification has no `id`, as required for JSON-RPC notifications.
/// Errors: `error.WriteFailed`/`error.OutOfMemory` from message composition,
/// and `error.PayloadTooLarge`/`error.WriteFailed` from `writeFrame`.
pub fn sendRequest(fd: std.os.linux.fd_t, request: Request) !void {
    const allocator = std.heap.page_allocator;
    const payload = try zjr.composer.makeRequestJson(
        allocator,
        @tagName(request.operation),
        .{ .message = request.message },
        zjr.RpcId.ofNone(),
    );
    defer allocator.free(payload);
    try writeFrame(fd, payload);
}

/// Reports the child's readiness state with a `ready` notification.
///
/// `message` is the child's readiness text. The Entrypoint treats its expected
/// readiness text as success and any other text as a failed startup.
/// Errors are those of `sendRequest`.
pub fn sendReady(fd: std.os.linux.fd_t, message: []const u8) !void {
    try sendRequest(fd, .{ .operation = .ready, .message = message });
}

/// Callbacks whose occurrence the Entrypoint reports to the plugin manager.
pub const Event = enum {
    /// Entrypoint.pause() ran.
    pause,
    /// Entrypoint.unpause() ran.
    unpause,
    /// Entrypoint.levelInit() ran.
    levelInit,
    /// Entrypoint.serverActivate() ran.
    serverActivate,
    /// Entrypoint.levelShutdown() ran.
    levelShutdown,
};

/// One event request payload.
///
/// In JSON-RPC the event callback is the method name, so the wire message is:
///
///     {"jsonrpc": "2.0", "method": "pause", "id": 1}
pub const EventMessage = struct {
    /// Callback that fired.
    event: Event,
};

/// An event request parsed from a JSON-RPC request.
///
/// `value` borrows the JSON owned by `rpc`; both stay valid until `deinit()`.
pub const ParsedEvent = struct {
    /// Parsed JSON-RPC request whose method names the event.
    rpc: zjr.RpcRequestResult,
    /// Event extracted from `rpc`.
    value: EventMessage,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *const ParsedEvent) void {
        self.rpc.deinit();
    }

    /// Returns the request ID used for the matching response.
    pub fn id(self: *const ParsedEvent) zjr.RpcId {
        return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNull();
    }
};

/// Parses one JSON-RPC event request.
///
/// The JSON-RPC method name selects the event. The returned value owns the
/// parsed JSON until `deinit()`.
///
/// Errors: `error.NotRpcRequest` when `text` is a response or batch,
/// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
/// `error.UnknownMethod` when the method is not one of `Event`'s callbacks.
pub fn parseEvent(allocator: std.mem.Allocator, text: []const u8) !ParsedEvent {
    var rpc = zjr.parseRpcRequest(allocator, text);
    errdefer rpc.deinit();

    if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
    const request = rpc.request_msg.request;
    if (request.hasError()) return error.InvalidRpcRequest;

    const event = eventFromMethod(request.method) orelse return error.UnknownMethod;
    return .{
        .rpc = rpc,
        .value = .{ .event = event },
    };
}

/// Serializes `event` as a JSON-RPC request into `buffer`.
///
/// Uses `event_request_id` so the listener can answer with a matching ID.
/// The returned slice borrows `buffer`.
///
/// Errors: `error.WriteFailed` when the event does not fit `buffer`.
pub fn encodeEvent(buffer: []u8, event: Event) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try zjr.composer.writeRequestJson(
        @tagName(event),
        null,
        zjr.RpcId.of(event_request_id),
        &writer,
    );
    return writer.buffered();
}

/// Serializes `event` as a JSON-RPC request and sends it as one frame.
///
/// Uses `event_request_id` so the listener can answer with a matching ID.
/// Errors: `error.WriteFailed` when the event does not fit the stack buffer or
/// the write fails, and `error.PayloadTooLarge` from `writeFrame`.
pub fn sendEvent(fd: std.os.linux.fd_t, event: Event) !void {
    var buffer: [128]u8 = undefined;
    const payload = try encodeEvent(&buffer, event);
    try writeFrame(fd, payload);
}

/// Formats the result text the manager answers `event` with: `"Event is X"`.
///
/// The returned slice borrows `buffer`.
///
/// Errors: `error.NoSpaceLeft` when `buffer` is too small.
pub fn eventResponseText(buffer: []u8, event: Event) ![]const u8 {
    return std.fmt.bufPrint(buffer, "Event is {s}", .{@tagName(event)});
}

/// Sends one successful JSON-RPC response.
///
/// `id` is the ID of the request being answered. `result_json` is the
/// already-serialized JSON value of the result, not a plain string, so callers
/// control whether the result is a string, object, or null.
///
/// Errors: `error.NoResponseForNotification` when `id` is not a valid request
/// ID, plus allocation and framing errors from message composition and
/// `writeFrame`.
pub fn sendResultResponse(fd: std.os.linux.fd_t, id: zjr.RpcId, result_json: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const response_json = try zjr.composer.makeResponseJson(allocator, id, result_json);
    const payload = response_json orelse return error.NoResponseForNotification;
    defer allocator.free(payload);
    try writeFrame(fd, payload);
}

/// Sends the successful JSON-RPC response for one event request.
///
/// `id` is the ID of the request being answered. The result is the string
/// returned by `eventResponseText`.
///
/// Errors: `error.NoSpaceLeft` when the stack buffer is too small,
/// `error.NoResponseForNotification` when `id` is not a valid request ID,
/// plus allocation and framing errors from message composition and
/// `writeFrame`.
pub fn sendEventResponse(fd: std.os.linux.fd_t, event: Event, id: zjr.RpcId) !void {
    const allocator = std.heap.page_allocator;
    var buffer: [64]u8 = undefined;
    const message = try eventResponseText(&buffer, event);

    const result_json = try std.json.Stringify.valueAlloc(allocator, message, .{});
    defer allocator.free(result_json);

    try sendResultResponse(fd, id, result_json);
}

/// Sends a JSON-RPC error response.
///
/// `id` is the request ID being answered, or `.ofNull()` when it could not be
/// determined. `code` selects the JSON-RPC error code; `message` is the error
/// text. Errors are the allocation and framing errors from message composition
/// and `writeFrame`.
pub fn sendErrorResponse(fd: std.os.linux.fd_t, id: zjr.RpcId, code: zjr.ErrorCode, message: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const payload = try zjr.composer.makeErrorResponseJson(allocator, id, code, message);
    defer allocator.free(payload);
    try writeFrame(fd, payload);
}

/// Answers an event frame that could not be decoded.
///
/// The request ID is recovered when `request_json` is structurally a
/// JSON-RPC request, so the caller's synchronous exchange still receives a
/// matching error response. Unknown methods produce `MethodNotFound`;
/// malformed envelopes use their own parse/validation code. Notifications
/// (requests without an ID) are not answered, matching JSON-RPC.
///
/// Errors are the allocation and framing errors from message composition and
/// `writeFrame`.
pub fn sendInvalidEventResponse(fd: std.os.linux.fd_t, request_json: []const u8) !void {
    const allocator = std.heap.page_allocator;
    var rpc = zjr.parseRpcRequest(allocator, request_json);
    defer rpc.deinit();

    var id = zjr.RpcId.ofNull();
    var code: zjr.ErrorCode = .InvalidRequest;
    if (rpc.isRequest()) {
        const request = rpc.request_msg.request;
        id = request.id;
        if (id.isNotification()) return;
        if (request.hasError()) {
            code = request.err().code;
        } else if (eventFromMethod(request.method) == null) {
            code = .MethodNotFound;
        } else {
            code = .InvalidParams;
        }
    }
    try sendErrorResponse(fd, id, code, "Event is invalid");
}

/// A JSON-RPC response parsed from one IPC payload.
///
/// `rpc` owns the parsed JSON until `deinit()`.
pub const ParsedResponse = struct {
    /// Parsed JSON-RPC response.
    rpc: zjr.RpcResponseResult,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *ParsedResponse) void {
        self.rpc.deinit();
    }

    /// Returns the single response inside `rpc`.
    ///
    /// Errors: `error.NotSingleRpcResponse` for a batch or empty response.
    pub fn value(self: *ParsedResponse) !zjr.RpcResponse {
        return self.rpc.response();
    }
};

/// Parses one JSON-RPC response payload.
///
/// The returned value owns the parsed JSON until `deinit()`.
pub fn parseResponse(allocator: std.mem.Allocator, text: []const u8) ParsedResponse {
    return .{ .rpc = zjr.parseRpcResponse(allocator, text) };
}

/// Returns the operation named by a JSON-RPC method, or null.
fn operationFromMethod(method: []const u8) ?Operation {
    if (std.mem.eql(u8, method, "stderr")) return .stderr;
    if (std.mem.eql(u8, method, "ready")) return .ready;
    return null;
}

/// Returns the event named by a JSON-RPC method, or null.
fn eventFromMethod(method: []const u8) ?Event {
    inline for (std.meta.fields(Event)) |field| {
        if (std.mem.eql(u8, method, field.name)) {
            return @as(Event, @enumFromInt(field.value));
        }
    }
    return null;
}
