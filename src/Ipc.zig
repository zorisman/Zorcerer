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

/// Request ID used by the `serverCommand` test round trip.
///
/// It differs from `event_request_id` so a response can never be mistaken
/// for the reply to a VSP callback event.
pub const server_command_request_id: i64 = 2;

/// JSON-RPC method name of the test ServerCommand engine call.
///
/// The Entrypoint sends this request to the plugin manager; the manager
/// answers with the command the Entrypoint should execute through the
/// engine's original `IVEngineServer::ServerCommand` implementation.
pub const server_command_method = "serverCommand";

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
/// A frame without a `method` member is not a request: it is either a
/// response or an object that cannot be served, and `error.NotRpcRequest`
/// lets the caller try the response parser instead.
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
    // ZigJR fills a missing `method` with its empty default, so the parsed
    // envelope alone does not say whether this was a request. An empty
    // method cannot name an operation, and responses land here.
    if (request.method.len == 0) return error.NotRpcRequest;
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
    // ZigJR's empty `method` default also covers response frames; see
    // `parseRequest`.
    if (request.method.len == 0) return error.NotRpcRequest;
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

/// Answers a frame that could not be decoded.
///
/// The request ID is recovered when `request_json` is structurally a
/// JSON-RPC request, so the caller's synchronous exchange still receives a
/// matching error response. Unknown methods produce `MethodNotFound`;
/// malformed envelopes use their own parse/validation code, and a malformed
/// `serverCommand` request is reported as `InvalidParams`. Notifications
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
    var message: []const u8 = "Event is invalid";
    if (rpc.isRequest()) {
        const request = rpc.request_msg.request;
        id = request.id;
        if (id.isNotification()) return;
        const is_server_command = std.mem.eql(u8, request.method, server_command_method);
        if (request.hasError()) {
            code = request.err().code;
        } else if (!is_server_command and eventFromMethod(request.method) == null) {
            code = .MethodNotFound;
        } else {
            code = .InvalidParams;
            if (is_server_command) message = "ServerCommand is invalid";
        }
    }
    try sendErrorResponse(fd, id, code, message);
}

/// Parameters of the test `serverCommand` request.
///
/// Wire form:
///
///     {"jsonrpc":"2.0","method":"serverCommand",
///      "params":{"command":"zorcerer ping"},"id":2}
pub const ServerCommandParams = struct {
    /// Command line the Entrypoint intercepted from the engine.
    command: []const u8,
};

/// Result of the test `serverCommand` request.
///
/// The Entrypoint executes `command` through the engine's original
/// `IVEngineServer::ServerCommand` implementation after receiving it.
pub const ServerCommandResult = struct {
    /// Command to issue to the engine.
    command: []const u8,
};

/// A `serverCommand` request parsed from a JSON-RPC request.
///
/// `command` borrows the JSON owned by `rpc`; both stay valid until
/// `deinit()`.
pub const ParsedServerCommand = struct {
    /// Parsed JSON-RPC request whose params hold the intercepted command.
    rpc: zjr.RpcRequestResult,
    /// Command the Entrypoint sent to the manager.
    command: []const u8,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *const ParsedServerCommand) void {
        self.rpc.deinit();
    }

    /// Returns the request ID, which is `.none` for a notification.
    pub fn id(self: *const ParsedServerCommand) zjr.RpcId {
        return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNone();
    }
};

/// One JSON-RPC call the plugin manager's listener understands.
///
/// Events are triggered by VSP callbacks; `serverCommand` is the test engine
/// call path that lets the manager decide which command the Entrypoint should
/// execute. Keeping both in one union lets the listener parse each frame
/// exactly once.
pub const ManagerRequest = union(enum) {
    /// A VSP callback event such as `pause` or `levelInit`.
    event: ParsedEvent,
    /// A test ServerCommand engine-call request.
    server_command: ParsedServerCommand,

    /// Releases the JSON storage owned by the active variant.
    pub fn deinit(self: *ManagerRequest) void {
        switch (self.*) {
            .event => |*parsed| parsed.deinit(),
            .server_command => |*parsed| parsed.deinit(),
        }
    }

    /// Returns the request ID, which is `.none` for a notification.
    pub fn id(self: *const ManagerRequest) zjr.RpcId {
        return switch (self.*) {
            .event => |parsed| parsed.id(),
            .server_command => |parsed| parsed.id(),
        };
    }
};

/// Serializes a test `serverCommand` request as a JSON-RPC 2.0 request.
///
/// The caller owns the returned slice and frees it with `allocator.free`.
/// Errors: `error.OutOfMemory` and ZigJR's composition errors.
pub fn makeServerCommandRequest(
    allocator: std.mem.Allocator,
    command: []const u8,
) ![]const u8 {
    return zjr.composer.makeRequestJson(
        allocator,
        server_command_method,
        ServerCommandParams{ .command = command },
        zjr.RpcId.of(server_command_request_id),
    );
}

/// Serializes a `serverCommand` result as a JSON-RPC 2.0 response.
///
/// The caller owns the returned slice and frees it with `allocator.free`.
/// Errors: `error.NoResponseForNotification` when `id` is a notification,
/// plus allocation and composition errors.
pub fn makeServerCommandResponse(
    allocator: std.mem.Allocator,
    id: zjr.RpcId,
    command: []const u8,
) ![]const u8 {
    const result_json = try std.json.Stringify.valueAlloc(
        allocator,
        ServerCommandResult{ .command = command },
        .{},
    );
    defer allocator.free(result_json);

    return try zjr.composer.makeResponseJson(allocator, id, result_json) orelse
        error.NoResponseForNotification;
}

/// Sends a test `serverCommand` request as one frame.
///
/// Errors: the composition errors of `makeServerCommandRequest` and the
/// framing errors of `writeFrame`.
pub fn sendServerCommandRequest(fd: std.os.linux.fd_t, command: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const payload = try makeServerCommandRequest(allocator, command);
    defer allocator.free(payload);
    try writeFrame(fd, payload);
}

/// Sends a test `serverCommand` response as one frame.
///
/// Errors: those of `makeServerCommandResponse` and `writeFrame`.
pub fn sendServerCommandResponse(
    fd: std.os.linux.fd_t,
    id: zjr.RpcId,
    command: []const u8,
) !void {
    const allocator = std.heap.page_allocator;
    const payload = try makeServerCommandResponse(allocator, id, command);
    defer allocator.free(payload);
    try writeFrame(fd, payload);
}

/// Parses one JSON-RPC call received by the plugin manager.
///
/// The JSON-RPC method selects the variant: `serverCommand` becomes
/// `.server_command`, every name in `Event` becomes `.event`. The returned
/// value owns the parsed JSON until `deinit()`.
///
/// Errors: `error.NotRpcRequest` when `text` is a response or batch,
/// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
/// `error.UnknownMethod` for a method the manager does not implement, and
/// `error.InvalidParams`/`error.MissingCommand` for malformed
/// `serverCommand` parameters.
pub fn parseManagerRequest(
    allocator: std.mem.Allocator,
    text: []const u8,
) !ManagerRequest {
    var rpc = zjr.parseRpcRequest(allocator, text);
    errdefer rpc.deinit();

    if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
    const request = rpc.request_msg.request;
    // As in `parseRequest`, ZigJR's empty `method` default also covers
    // response frames, which are not manager calls.
    if (request.method.len == 0) return error.NotRpcRequest;
    if (request.hasError()) return error.InvalidRpcRequest;

    if (std.mem.eql(u8, request.method, server_command_method)) {
        const params = request.objectParams() orelse return error.InvalidParams;
        const command_value = params.get("command") orelse return error.MissingCommand;
        const command = switch (command_value) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        return .{ .server_command = .{ .rpc = rpc, .command = command } };
    }

    const event = eventFromMethod(request.method) orelse return error.UnknownMethod;
    return .{ .event = .{ .rpc = rpc, .value = .{ .event = event } } };
}

/// Extracts the command from a successful `serverCommand` response.
///
/// The returned slice borrows `response` and the JSON storage behind it; it
/// remains valid only while the parsed response is alive.
///
/// Errors: `error.ServerCommandFailed` for a JSON-RPC error response,
/// `error.UnexpectedResultType` when the result is not an object,
/// `error.MissingCommand` when the object has no `command`, and
/// `error.InvalidCommand` when `command` is not a string.
pub fn serverCommandFromResponse(response: zjr.RpcResponse) ![]const u8 {
    if (response.hasErr()) return error.ServerCommandFailed;

    const result = switch (response.result) {
        .object => |object| object,
        else => return error.UnexpectedResultType,
    };
    const command_value = result.get("command") orelse return error.MissingCommand;
    return switch (command_value) {
        .string => |command| command,
        else => return error.InvalidCommand,
    };
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

/// In-process JSON-RPC listener used by tests.
///
/// The listener owns an `RpcDispatcher`, registers handlers by method name,
/// and runs requests through ZigJR's `RequestPipeline`. It never opens a
/// socket or starts a subprocess.
pub const MockListener = struct {
    /// Allocator used for the dispatcher, pipeline, and response copy.
    allocator: std.mem.Allocator,
    /// Registered method table. Heap-allocated so its address is stable.
    rpc: *zjr.RpcDispatcher,
    /// ZigJR request pipeline. Heap-allocated so its internal pointers stay
    /// valid for the lifetime of the listener.
    pipeline: *zjr.RequestPipeline,
    /// Stable copy of the most recent response.
    response_buffer: [max_payload_len]u8 = undefined,
    /// Number of valid bytes in `response_buffer`.
    response_len: usize = 0,

    /// Creates a listener with no handlers.
    ///
    /// Errors: `error.OutOfMemory` when the dispatcher, pipeline, or their
    /// internal allocations cannot be created.
    pub fn init(allocator: std.mem.Allocator) !MockListener {
        const rpc = try allocator.create(zjr.RpcDispatcher);
        errdefer allocator.destroy(rpc);
        rpc.* = try zjr.RpcDispatcher.init(allocator);
        errdefer rpc.deinit();

        const pipeline = try allocator.create(zjr.RequestPipeline);
        errdefer allocator.destroy(pipeline);
        pipeline.* = try zjr.RequestPipeline.init(
            allocator,
            zjr.RequestDispatcher.implBy(rpc),
            null,
        );

        return .{
            .allocator = allocator,
            .rpc = rpc,
            .pipeline = pipeline,
        };
    }

    /// Releases the dispatcher, pipeline, and their allocations.
    pub fn deinit(self: *MockListener) void {
        self.pipeline.deinit();
        self.allocator.destroy(self.pipeline);
        self.rpc.deinit();
        self.allocator.destroy(self.rpc);
    }

    /// Registers `handler_fn` under the JSON-RPC method name `method`.
    ///
    /// Errors are ZigJR's `RegistrationErrors`.
    pub fn register(self: *MockListener, method: []const u8, comptime handler_fn: anytype) !void {
        try self.rpc.add(method, handler_fn);
    }

    /// Processes one JSON-RPC request and returns its response.
    ///
    /// The returned slice borrows `response_buffer` and stays valid until the
    /// next call to `handle` on this listener.
    ///
    /// Errors: ZigJR's pipeline writer errors, `error.EmptyResponse` when the
    /// request was a notification, and `error.PayloadTooLarge` when the
    /// response does not fit the frame buffer.
    pub fn handle(self: *MockListener, request_json: []const u8) ![]const u8 {
        const status = try self.pipeline.runRequest(request_json);
        if (!status.hasReply()) return error.EmptyResponse;

        const response = self.pipeline.responseJson();
        if (response.len > self.response_buffer.len) return error.PayloadTooLarge;
        @memcpy(self.response_buffer[0..response.len], response);
        self.response_len = response.len;
        return self.response_buffer[0..self.response_len];
    }
};

/// In-process JSON-RPC client used by tests.
///
/// The sender composes a request with ZigJR, passes it directly to a
/// `MockListener`, prints both wire messages, and returns the parsed response
/// for assertions.
pub const MockSender = struct {
    /// Allocator for request composition and response parsing.
    allocator: std.mem.Allocator,
    /// Destination for the request. Must outlive the sender.
    listener: *MockListener,

    /// Sends one JSON-RPC request and returns its parsed response.
    ///
    /// `params` must be null, an array-like tuple, or a struct; ZigJR rejects
    /// other parameter types. The returned result owns its parsed JSON until
    /// `deinit()` is called.
    ///
    /// Errors are ZigJR's composition errors, the listener's pipeline errors,
    /// and `error.OutOfMemory` while parsing the response.
    pub fn call(
        self: *MockSender,
        method: []const u8,
        params: anytype,
        id: zjr.RpcId,
    ) !zjr.RpcResponseResult {
        const request_json = try zjr.composer.makeRequestJson(self.allocator, method, params, id);
        defer self.allocator.free(request_json);

        const response_json = try self.listener.handle(request_json);
        return zjr.parseRpcResponseOwned(self.allocator, response_json, .{});
    }
};

/// Adds the two test numbers.
fn mockAddTwoNumbers(a: f64, b: f64) f64 {
    return a + b;
}

/// Message parameter for `mockReadStruct`.
const Message = struct {
    text: []const u8,
};

/// Returns the text carried by `msg`.
fn mockReadStruct(msg: Message) []const u8 {
    return msg.text;
}

test "mock JSON-RPC request/response flow" {
    var listener = try MockListener.init(std.testing.allocator);
    defer listener.deinit();
    try listener.register("mockAddTwoNumbers", mockAddTwoNumbers);
    try listener.register("mockReadStruct", mockReadStruct);

    var sender = MockSender{
        .allocator = std.testing.allocator,
        .listener = &listener,
    };

    var add_response = try sender.call("mockAddTwoNumbers", .{ 2.5, 3.5 }, zjr.RpcId.of(7));
    defer add_response.deinit();
    const add = try add_response.response();
    try std.testing.expect(!add.hasErr());
    try std.testing.expect(add.id.eql(7));
    try std.testing.expect(add.resultEql(@as(f64, 6.0)));
    const add_result = switch (add.result) {
        .float => |value| value,
        .integer => |value| @as(f64, @floatFromInt(value)),
        else => return error.UnexpectedResultType,
    };
    std.debug.print("mockAddTwoNumbers result: {}\n", .{add_result});
    try std.testing.expectEqual(@as(f64, 6.0), add_result);

    var read_response = try sender.call("mockReadStruct", .{ .text = "Hello" }, zjr.RpcId.of(8));
    defer read_response.deinit();
    const read = try read_response.response();
    try std.testing.expect(!read.hasErr());
    try std.testing.expect(read.id.eql(8));
    const read_result = read.result.string;
    std.debug.print("mockReadStruct result: {s}\n", .{read_result});
    try std.testing.expectEqualStrings("Hello", read_result);
}

test "serverCommand request is a JSON-RPC 2.0 request the manager understands" {
    const allocator = std.testing.allocator;
    const text = try makeServerCommandRequest(allocator, "zorcerer ping");
    defer allocator.free(text);

    var rpc = zjr.parseRpcRequest(allocator, text);
    defer rpc.deinit();
    try std.testing.expect(rpc.isRequest());

    const request = rpc.request_msg.request;
    try std.testing.expectEqualStrings("2.0", request.jsonrpc[0..]);
    try std.testing.expectEqualStrings(server_command_method, request.method);
    try std.testing.expect(request.id.eql(server_command_request_id));

    const params = request.objectParams() orelse return error.MissingParams;
    const command = switch (params.get("command") orelse return error.MissingCommand) {
        .string => |value| value,
        else => return error.InvalidCommand,
    };
    try std.testing.expectEqualStrings("zorcerer ping", command);

    var parsed = try parseManagerRequest(allocator, text);
    defer parsed.deinit();
    switch (parsed) {
        .server_command => |call| try std.testing.expectEqualStrings("zorcerer ping", call.command),
        .event => return error.UnexpectedEvent,
    }
    try std.testing.expect(parsed.id().eql(server_command_request_id));
}

test "serverCommand response carries the command the Entrypoint must execute" {
    const allocator = std.testing.allocator;
    const text = try makeServerCommandResponse(
        allocator,
        zjr.RpcId.of(server_command_request_id),
        "echo \"Pong!\"",
    );
    defer allocator.free(text);

    var response = parseResponse(allocator, text);
    defer response.deinit();
    const rpc = try response.value();

    try std.testing.expect(!rpc.hasErr());
    try std.testing.expect(rpc.id.eql(server_command_request_id));
    try std.testing.expectEqualStrings("echo \"Pong!\"", try serverCommandFromResponse(rpc));
}

test "parseRequest treats a response frame as not a request" {
    try std.testing.expectError(
        error.NotRpcRequest,
        parseRequest(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"result\":{},\"id\":2}",
        ),
    );
}

test "manager request parsing keeps events and serverCommand apart" {
    const allocator = std.testing.allocator;

    var event = try parseManagerRequest(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"pause\",\"id\":1}",
    );
    defer event.deinit();
    switch (event) {
        .event => |parsed| try std.testing.expectEqual(Event.pause, parsed.value.event),
        .server_command => return error.UnexpectedServerCommand,
    }

    try std.testing.expectError(
        error.UnknownMethod,
        parseManagerRequest(
            allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"bogus\",\"id\":1}",
        ),
    );
    try std.testing.expectError(
        error.MissingCommand,
        parseManagerRequest(
            allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"serverCommand\",\"params\":{},\"id\":2}",
        ),
    );
    try std.testing.expectError(
        error.NotRpcRequest,
        parseManagerRequest(
            allocator,
            "{\"jsonrpc\":\"2.0\",\"result\":{},\"id\":2}",
        ),
    );
}
