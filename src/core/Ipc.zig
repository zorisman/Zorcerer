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
///     {"jsonrpc": "2.0", "method": "levelInit", "params": {"payload": "{\"map\":\"de_dust2\"}"}, "id": 1}
pub const EventMessage = struct {
    /// Callback that fired.
    event: Event,
    /// Optional JSON text with event-specific parameters. It is transmitted
    /// as a JSON string and borrows the parsed request.
    payload: ?[]const u8 = null,
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
/// The JSON-RPC method name selects the event. An optional object `params`
/// may carry a string member `payload`, which is returned unchanged as JSON
/// text. The returned value owns the parsed JSON until `deinit()`.
///
/// Errors: `error.NotRpcRequest` when `text` is a response or batch,
/// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
/// `error.UnknownMethod` when the method is not one of `Event`'s callbacks,
/// and `error.InvalidParams` when `payload` is not a string.
pub fn parseEvent(allocator: std.mem.Allocator, text: []const u8) !ParsedEvent {
    var rpc = zjr.parseRpcRequest(allocator, text);
    errdefer rpc.deinit();

    if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
    const request = rpc.request_msg.request;
    if (request.hasError()) return error.InvalidRpcRequest;

    const event = eventFromMethod(request.method) orelse return error.UnknownMethod;

    var payload: ?[]const u8 = null;
    if (request.objectParams()) |params| {
        if (params.get("payload")) |value| {
            payload = switch (value) {
                .string => |bytes| bytes,
                else => return error.InvalidParams,
            };
        }
    }

    return .{
        .rpc = rpc,
        .value = .{ .event = event, .payload = payload },
    };
}

/// Serializes `event` as a JSON-RPC request into `buffer`.
///
/// Uses `event_request_id` so the listener can answer with a matching ID.
/// `payload` is optional JSON text that is transmitted as a string inside an
/// object `params`. The returned slice borrows `buffer`.
///
/// Errors: `error.OutOfMemory` while encoding the parameters,
/// `error.WriteFailed` when the event does not fit `buffer`, and writer
/// errors from parameter encoding.
pub fn encodeEvent(buffer: []u8, event: Event, payload: ?[]const u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);

    if (payload) |text| {
        const allocator = std.heap.page_allocator;
        const params_json = try std.json.Stringify.valueAlloc(
            allocator,
            .{ .payload = text },
            .{},
        );
        defer allocator.free(params_json);

        try zjr.composer.writeRequestJson(
            @tagName(event),
            params_json,
            zjr.RpcId.of(event_request_id),
            &writer,
        );
    } else {
        try zjr.composer.writeRequestJson(
            @tagName(event),
            null,
            zjr.RpcId.of(event_request_id),
            &writer,
        );
    }

    return writer.buffered();
}

/// Serializes `event` as a JSON-RPC request and sends it as one frame.
///
/// Uses `event_request_id` so the listener can answer with a matching ID.
/// `payload` is optional JSON text; see `encodeEvent`.
/// Errors: `error.WriteFailed` when the event does not fit the stack buffer or
/// the write fails, `error.OutOfMemory` while encoding the parameters, and
/// `error.PayloadTooLarge` from `writeFrame`.
pub fn sendEvent(fd: std.os.linux.fd_t, event: Event, payload: ?[]const u8) !void {
    var buffer: [max_payload_len]u8 = undefined;
    const payload_json = try encodeEvent(&buffer, event, payload);
    try writeFrame(fd, payload_json);
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

// --- Game queries -----------------------------------------------------------

/// Request ID the plugin-manager child uses for game queries.
///
/// Queries are synchronous and strictly one at a time, and the parent is
/// always blocked on the child's readiness or event response while a query is
/// in flight, so a single fixed positive ID is sufficient.
pub const query_request_id: i64 = 100;

/// Read-only game-state queries a plugin may send to the engine process.
pub const Query = enum {
    /// Server state snapshot: dedicated flag, pause, entity count, version,
    /// uptime, game directory, and current map name.
    server_info,
    /// Engine player identity for one entity index.
    player_info,
    /// Whether an entity index is currently in use.
    entity_exists,
    /// Server cvar lookup by name.
    server_cvar,
    /// One client's cvar value.
    client_cvar,
};

/// One game-query request.
///
/// `index` is meaningful for player, entity, and client-cvar queries; `name`
/// is meaningful for cvar queries. The other field is ignored.
pub const QueryRequest = struct {
    /// Query to execute.
    query: Query,
    /// Entity or client index, depending on `query`.
    index: c_int = 0,
    /// Cvar name for cvar queries.
    name: []const u8 = "",
};

/// JSON result of the `server_info` query.
pub const ServerInfo = struct {
    /// Nonzero when the engine is a dedicated server.
    dedicated: bool,
    /// Nonzero when the server is paused.
    paused: bool,
    /// Number of entity slots the engine reports in use.
    entity_count: c_int,
    /// Engine build number.
    server_version: c_int,
    /// Seconds since server start.
    server_time: f32,
    /// Game/mod directory, for example `tf`.
    game_dir: []const u8,
    /// Current map name, or an empty string outside a level.
    map_name: []const u8,
};

/// JSON result of the `player_info` query.
pub const PlayerInfo = struct {
    /// Nonzero when the engine returned info for the requested slot.
    present: bool,
    /// Entity index the caller requested.
    index: c_int,
    /// Server-assigned user id.
    user_id: c_int,
    /// Steam friends id.
    friends_id: u32,
    /// Player display name.
    name: []const u8,
    /// Steam id string.
    guid: []const u8,
    /// Steam friends name.
    friends_name: []const u8,
    /// Nonzero when the client is a bot.
    fake_player: bool,
    /// Nonzero when the client is an HLTV proxy.
    is_hltv: bool,
};

/// JSON result of the `entity_exists` query.
pub const EntityInfo = struct {
    /// Nonzero when the engine has an entity at the requested index.
    exists: bool,
};

/// JSON result of the cvar queries.
pub const CvarValue = struct {
    /// Nonzero when the cvar was found.
    found: bool,
    /// Integer representation of the value.
    int_value: c_int,
    /// Floating-point representation of the value.
    float_value: f32,
    /// String representation of the value.
    text: []const u8,
};

/// A game-query request parsed from a JSON-RPC request.
///
/// `value` borrows the JSON owned by `rpc`; both stay valid until `deinit()`.
pub const ParsedQuery = struct {
    /// Parsed JSON-RPC request whose method names the query.
    rpc: zjr.RpcRequestResult,
    /// Query extracted from `rpc`.
    value: QueryRequest,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *const ParsedQuery) void {
        self.rpc.deinit();
    }

    /// Returns the request ID used for the matching response.
    pub fn id(self: *const ParsedQuery) zjr.RpcId {
        return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNone();
    }
};

/// Parses one JSON-RPC game-query request.
///
/// The method names are `query.serverInfo`, `query.playerInfo`,
/// `query.entityExists`, `query.serverCvar`, and `query.clientCvar`. Optional
/// object parameters may carry integer `index` and string `name`.
///
/// Errors: `error.NotRpcRequest` when `text` is a response or batch,
/// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
/// `error.UnknownMethod` when the method is not a query, and
/// `error.InvalidParams` when a parameter has the wrong type.
pub fn parseQuery(allocator: std.mem.Allocator, text: []const u8) !ParsedQuery {
    var rpc = zjr.parseRpcRequest(allocator, text);
    errdefer rpc.deinit();

    if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
    const request = rpc.request_msg.request;
    if (request.hasError()) return error.InvalidRpcRequest;

    const query = queryFromMethod(request.method) orelse return error.UnknownMethod;

    var value = QueryRequest{ .query = query };
    if (request.objectParams()) |params| {
        if (params.get("index")) |index_value| {
            const raw_index = switch (index_value) {
                .integer => |number| number,
                else => return error.InvalidParams,
            };
            value.index = std.math.cast(c_int, raw_index) orelse return error.InvalidParams;
        }
        if (params.get("name")) |name_value| {
            value.name = switch (name_value) {
                .string => |bytes| bytes,
                else => return error.InvalidParams,
            };
        }
    }

    return .{ .rpc = rpc, .value = value };
}

/// Serializes `request` as a JSON-RPC request into `buffer`.
///
/// Uses `query_request_id` so the waiter can match the response. The returned
/// slice borrows `buffer`.
///
/// Errors: `error.OutOfMemory` while encoding the parameters,
/// `error.WriteFailed` when the request does not fit `buffer`, and writer
/// errors from parameter encoding.
pub fn encodeQuery(buffer: []u8, request: QueryRequest) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);

    const allocator = std.heap.page_allocator;
    const params_json = try std.json.Stringify.valueAlloc(
        allocator,
        .{ .index = request.index, .name = request.name },
        .{},
    );
    defer allocator.free(params_json);

    try zjr.composer.writeRequestJson(
        queryMethod(request.query),
        params_json,
        zjr.RpcId.of(query_request_id),
        &writer,
    );
    return writer.buffered();
}

/// Serializes `request` as a JSON-RPC request and sends it as one frame.
///
/// Precondition: the parent must be listening for child requests, which holds
/// while it waits for readiness or for an event response.
///
/// Errors: `error.WriteFailed` when the request does not fit the stack buffer
/// or the write fails, `error.OutOfMemory` while encoding the parameters, and
/// `error.PayloadTooLarge` from `writeFrame`.
pub fn sendQuery(fd: std.os.linux.fd_t, request: QueryRequest) !void {
    var buffer: [max_payload_len]u8 = undefined;
    const payload_json = try encodeQuery(&buffer, request);
    try writeFrame(fd, payload_json);
}

/// Reads the parent's response to the in-flight query.
///
/// Returns the result text, which is a JSON document describing the queried
/// value. The caller owns the returned slice and frees it with `allocator`.
///
/// Errors: framing errors from `readFrame`; `error.InvalidFrame` when the
/// marker is missing; `error.EmptyMessage` for an empty payload;
/// `error.UnexpectedQueryResponse` when the payload is not a single JSON-RPC
/// response; `error.UnexpectedResponseId` when the response does not answer
/// `query_request_id`; `error.QueryFailed` when the parent returned a
/// JSON-RPC error; `error.UnexpectedResultType` when the result is not a JSON
/// string; and `error.OutOfMemory` when copying the text fails.
pub fn receiveQueryResult(fd: std.os.linux.fd_t, allocator: std.mem.Allocator) ![]u8 {
    const frame = try readFrame(fd);
    if (!frame.framed) return error.InvalidFrame;
    if (!frame.received) return error.EmptyMessage;

    var response = parseResponse(allocator, frame.text());
    defer response.deinit();
    const rpc_response = response.value() catch return error.UnexpectedQueryResponse;

    if (!rpc_response.id.eql(query_request_id)) return error.UnexpectedResponseId;
    if (rpc_response.hasErr()) return error.QueryFailed;

    return switch (rpc_response.result) {
        .string => |text| allocator.dupe(u8, text),
        else => error.UnexpectedResultType,
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

// --- Filesystem -------------------------------------------------------------

/// Request ID the plugin-manager child uses for filesystem requests.
///
/// File requests are synchronous and strictly one at a time: the child blocks
/// until the engine process answers, and the parent is already listening while
/// it waits for readiness, an event response, or the shutdown answer.
pub const file_request_id: i64 = 101;

/// Request ID the engine process uses to ask the plugin-manager child to
/// unload its plugins and stop serving the channel.
pub const shutdown_request_id: i64 = 200;

/// Largest raw file-data chunk one filesystem message carries.
///
/// Base64 expands three input bytes to four characters, so a chunk this size
/// fits `max_payload_len` together with its JSON envelope.
pub const file_chunk_len: usize = 2048;

/// Filesystem operations carried by `file.*` JSON-RPC methods.
pub const FileOp = enum {
    /// Open a file.
    open,
    /// Close a file handle.
    close,
    /// Read from a file handle.
    read,
    /// Write to a file handle.
    write,
    /// Move a file handle's read/write pointer.
    seek,
    /// Read a file handle's current pointer.
    tell,
    /// Read a file handle's size.
    size,
    /// Flush a file handle's buffered data.
    flush,
    /// Delete a file.
    remove,
    /// Open a directory enumeration.
    find_open,
    /// Read the next directory entry.
    find_next,
    /// Close a directory enumeration.
    find_close,
};

/// One filesystem request sent by the plugin-manager child.
///
/// `path` is the original `game://` URI for path operations. `handle` is a
/// manager-side ID for handle operations. `data` is standard base64; `length`
/// is the requested raw byte count. Only the fields relevant to `op` are
/// meaningful.
pub const FileRequest = struct {
    /// Operation to execute.
    op: FileOp,
    /// `game://` URI for `open`, `remove`, and `find_open`.
    path: []const u8 = "",
    /// Requested open mode; see `plugin-context.FileMode`.
    mode: c_int = 0,
    /// Manager-side file or enumeration handle.
    handle: u64 = 0,
    /// Signed offset for `seek`.
    offset: i64 = 0,
    /// Seek origin; see `plugin-context.FileSeekFrom`.
    origin: c_int = 0,
    /// Maximum raw byte count for `read`.
    length: usize = 0,
    /// Base64-encoded payload for `write`.
    data: []const u8 = "",
};

/// One filesystem result returned by the engine process.
///
/// `status` is a `plugin-context.file_*` value. The remaining fields are
/// meaningful only when `status == file_ok`: `handle` for opens, `value` for
/// `tell`/`size`, `written` for writes, `data` for reads, and
/// `name`/`is_directory` for enumeration. `done` marks an exhausted
/// enumeration and is accompanied by `status == file_end`.
pub const FileResult = struct {
    /// `plugin-context.file_*` status of the operation.
    status: c_int = 0,
    /// Newly opened file or enumeration handle.
    handle: u64 = 0,
    /// Position or size result.
    value: u64 = 0,
    /// Number of bytes accepted by a write.
    written: usize = 0,
    /// Base64-encoded bytes returned by a read.
    data: []const u8 = "",
    /// Next directory entry name.
    name: []const u8 = "",
    /// Whether the entry named by `name` is a directory.
    is_directory: bool = false,
    /// Whether the enumeration has no more entries.
    done: bool = false,
};

/// A filesystem request parsed from a JSON-RPC request.
///
/// `value` borrows the JSON owned by `rpc`; both stay valid until `deinit()`.
pub const ParsedFileRequest = struct {
    /// Parsed JSON-RPC request whose method names the operation.
    rpc: zjr.RpcRequestResult,
    /// Operation and parameters extracted from `rpc`.
    value: FileRequest,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *const ParsedFileRequest) void {
        self.rpc.deinit();
    }

    /// Returns the request ID used for the matching response.
    pub fn id(self: *const ParsedFileRequest) zjr.RpcId {
        return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNone();
    }
};

/// Parses one JSON-RPC filesystem request.
///
/// The method names are `file.open`, `file.close`, `file.read`, `file.write`,
/// `file.seek`, `file.tell`, `file.size`, `file.flush`, `file.remove`,
/// `file.findOpen`, `file.findNext`, and `file.findClose`. Object parameters
/// carry the fields of `FileRequest`.
///
/// Errors: `error.NotRpcRequest` when `text` is a response or batch,
/// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
/// `error.UnknownMethod` when the method is not a file operation, and
/// `error.InvalidParams` when a parameter has the wrong type or does not fit
/// its destination type.
pub fn parseFileRequest(allocator: std.mem.Allocator, text: []const u8) !ParsedFileRequest {
    var rpc = zjr.parseRpcRequest(allocator, text);
    errdefer rpc.deinit();

    if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
    const request = rpc.request_msg.request;
    if (request.hasError()) return error.InvalidRpcRequest;

    const op = fileOpFromMethod(request.method) orelse return error.UnknownMethod;
    var value = FileRequest{ .op = op };

    if (request.objectParams()) |params| {
        if (params.get("path")) |path_value| {
            value.path = switch (path_value) {
                .string => |bytes| bytes,
                else => return error.InvalidParams,
            };
        }
        if (params.get("data")) |data_value| {
            value.data = switch (data_value) {
                .string => |bytes| bytes,
                else => return error.InvalidParams,
            };
        }
        if (try optionalInt(params, "mode", c_int)) |mode| value.mode = mode;
        if (try optionalInt(params, "handle", u64)) |handle| value.handle = handle;
        if (try optionalInt(params, "offset", i64)) |offset| value.offset = offset;
        if (try optionalInt(params, "origin", c_int)) |origin| value.origin = origin;
        if (try optionalInt(params, "length", usize)) |length| value.length = length;
    }

    return .{ .rpc = rpc, .value = value };
}

/// Parameters serialized into a `file.*` request.
///
/// Keeping `op` out of the payload avoids sending the operation twice: the
/// JSON-RPC method already selects it.
const FileParams = struct {
    /// See `FileRequest.path`.
    path: []const u8,
    /// See `FileRequest.mode`.
    mode: c_int,
    /// See `FileRequest.handle`.
    handle: u64,
    /// See `FileRequest.offset`.
    offset: i64,
    /// See `FileRequest.origin`.
    origin: c_int,
    /// See `FileRequest.length`.
    length: usize,
    /// See `FileRequest.data`.
    data: []const u8,
};

/// Serializes `request` as a JSON-RPC request into `buffer`.
///
/// Uses `file_request_id` so the waiter can match the response. The returned
/// slice borrows `buffer`.
///
/// Errors: `error.OutOfMemory` while encoding the parameters,
/// `error.WriteFailed` when the request does not fit `buffer`, and writer
/// errors from parameter encoding.
pub fn encodeFileRequest(buffer: []u8, request: FileRequest) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);

    const allocator = std.heap.page_allocator;
    const params_json = try std.json.Stringify.valueAlloc(
        allocator,
        FileParams{
            .path = request.path,
            .mode = request.mode,
            .handle = request.handle,
            .offset = request.offset,
            .origin = request.origin,
            .length = request.length,
            .data = request.data,
        },
        .{},
    );
    defer allocator.free(params_json);

    try zjr.composer.writeRequestJson(
        fileMethod(request.op),
        params_json,
        zjr.RpcId.of(file_request_id),
        &writer,
    );
    return writer.buffered();
}

/// Serializes `request` as a JSON-RPC request and sends it as one frame.
///
/// Precondition: the parent must be listening for child requests, which holds
/// while it waits for readiness, an event response, or the shutdown answer.
///
/// Errors: `error.WriteFailed` when the request does not fit the stack buffer
/// or the write fails, `error.OutOfMemory` while encoding the parameters, and
/// `error.PayloadTooLarge` from `writeFrame`.
pub fn sendFileRequest(fd: std.os.linux.fd_t, request: FileRequest) !void {
    var buffer: [max_payload_len]u8 = undefined;
    const payload_json = try encodeFileRequest(&buffer, request);
    try writeFrame(fd, payload_json);
}

/// Reads the parent's response to the in-flight filesystem request.
///
/// Returns the parsed result, whose string fields borrow its storage. The
/// caller owns the result and releases it with `deinit()`.
///
/// Errors: framing errors from `readFrame`; `error.InvalidFrame` when the
/// marker is missing; `error.EmptyMessage` for an empty payload;
/// `error.UnexpectedFileResponse` when the payload is not a single JSON-RPC
/// response; `error.UnexpectedResponseId` when the response does not answer
/// `file_request_id`; `error.FileFailed` when the parent returned a JSON-RPC
/// error; `error.UnexpectedResultType` when the result is not a JSON string;
/// and `error.OutOfMemory` or `error.SyntaxError` while parsing the result.
pub fn receiveFileResult(
    fd: std.os.linux.fd_t,
    allocator: std.mem.Allocator,
) !std.json.Parsed(FileResult) {
    const frame = try readFrame(fd);
    if (!frame.framed) return error.InvalidFrame;
    if (!frame.received) return error.EmptyMessage;

    var response = parseResponse(allocator, frame.text());
    defer response.deinit();
    const rpc_response = response.value() catch return error.UnexpectedFileResponse;

    if (!rpc_response.id.eql(file_request_id)) return error.UnexpectedResponseId;
    if (rpc_response.hasErr()) return error.FileFailed;

    const text = switch (rpc_response.result) {
        .string => |bytes| bytes,
        else => return error.UnexpectedResultType,
    };
    return std.json.parseFromSlice(FileResult, allocator, text, .{});
}

// --- Engine commands --------------------------------------------------------

/// Request ID the plugin-manager child uses for engine command requests.
///
/// Commands are synchronous and strictly one at a time: the child blocks until
/// the engine process has accepted the command, and the parent is already
/// listening while it waits for readiness, an event response, or the shutdown
/// answer. Keeping the ID distinct from `event_request_id`,
/// `query_request_id`, `file_request_id`, and `shutdown_request_id` prevents a
/// reply from satisfying the wrong exchange.
pub const server_command_request_id: i64 = 102;

/// Largest command text one `engine.serverCommand` request accepts, in bytes.
///
/// The value leaves room for the JSON envelope and for escaping the command
/// inside a `max_payload_len` frame even when every byte needs a two-character
/// escape. Longer commands are rejected rather than truncated, because a
/// truncated command could execute something other than what the caller
/// intended.
pub const max_command_len: usize = 1024;

/// JSON-RPC method the plugin-manager child uses to ask the engine process to
/// execute one server command.
pub const server_command_method = "engine.serverCommand";

/// One engine command request sent by the plugin-manager child.
///
/// `command` is the raw command line; the Entrypoint validates it again before
/// handing it to the engine. `plugin_id` is advisory attribution for the
/// Entrypoint's audit log; it never grants or denies access.
pub const ServerCommandRequest = struct {
    /// Command line to queue in the engine command buffer.
    command: []const u8,
    /// Id of the plugin or Lua script that sent the request.
    plugin_id: []const u8 = "",
};

/// JSON result of an accepted `engine.serverCommand` request.
///
/// `accepted` reports that the Entrypoint passed the command to the engine. It
/// does not report whether the engine recognized or successfully executed it.
pub const ServerCommandResult = struct {
    /// Whether the command was handed to the engine.
    accepted: bool,
};

/// Reasons `validateCommand()` rejects command text.
pub const CommandError = error{
    /// The command is empty or consists only of whitespace.
    EmptyCommand,
    /// The command is longer than `max_command_len`.
    CommandTooLong,
    /// The command contains a NUL byte that would truncate the C string.
    EmbeddedNul,
    /// The command contains a line break and would inject multiple commands.
    MultilineCommand,
    /// The command contains an unsupported control character. Tab is allowed.
    ControlCharacter,
};

/// Validates command text before it is sent or executed.
///
/// Both the child and the Entrypoint call this function. The Entrypoint remains
/// the actual boundary: the child's validation is only an early diagnostic.
///
/// Whitespace-only text is rejected. The text must fit `max_command_len`, must
/// not contain `\x00` (the engine receives a zero-terminated string), and must
/// be a single line: `\r` and `\n` are rejected so one request cannot smuggle
/// several commands past logging or future policy checks. Other control
/// characters are rejected because the engine command parser has no use for
/// them and JSON would expand each one into a longer escape; tab is allowed.
///
/// Errors: the `CommandError` variants described above.
pub fn validateCommand(text: []const u8) CommandError!void {
    if (std.mem.trim(u8, text, " \t").len == 0) return error.EmptyCommand;
    if (text.len > max_command_len) return error.CommandTooLong;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.MultilineCommand;
    for (text) |byte| {
        if (byte < 0x20 and byte != '\t') return error.ControlCharacter;
    }
}

/// A command request parsed from a JSON-RPC request.
///
/// `value` borrows the JSON owned by `rpc`; both stay valid until `deinit()`.
pub const ParsedServerCommand = struct {
    /// Parsed JSON-RPC request carrying the command.
    rpc: zjr.RpcRequestResult,
    /// Command and attribution extracted from `rpc`.
    value: ServerCommandRequest,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *const ParsedServerCommand) void {
        self.rpc.deinit();
    }

    /// Returns the request ID used for the matching response.
    pub fn id(self: *const ParsedServerCommand) zjr.RpcId {
        return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNone();
    }
};

/// Parses one `engine.serverCommand` JSON-RPC request.
///
/// The method is `engine.serverCommand`. Object parameters must carry a string
/// `command`; an optional string `plugin_id` is copied into
/// `ServerCommandRequest.plugin_id`.
///
/// This function checks parameter types only. Callers validate the command text
/// with `validateCommand()` before sending or executing it.
///
/// Errors: `error.NotRpcRequest` when `text` is a response or batch,
/// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
/// `error.UnknownMethod` when the method is not a command request,
/// `error.InvalidParams` when `command` is missing or not a string, or
/// `plugin_id` is not a string.
pub fn parseServerCommand(
    allocator: std.mem.Allocator,
    text: []const u8,
) !ParsedServerCommand {
    var rpc = zjr.parseRpcRequest(allocator, text);
    errdefer rpc.deinit();

    if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
    const request = rpc.request_msg.request;
    if (request.hasError()) return error.InvalidRpcRequest;
    if (!std.mem.eql(u8, request.method, server_command_method)) {
        return error.UnknownMethod;
    }

    const params = request.objectParams() orelse return error.InvalidParams;
    const command = switch (params.get("command") orelse return error.InvalidParams) {
        .string => |bytes| bytes,
        else => return error.InvalidParams,
    };

    var value = ServerCommandRequest{ .command = command };
    if (params.get("plugin_id")) |plugin_id_value| {
        value.plugin_id = switch (plugin_id_value) {
            .string => |bytes| bytes,
            else => return error.InvalidParams,
        };
    }

    return .{ .rpc = rpc, .value = value };
}

/// Parameters serialized into an `engine.serverCommand` request.
const ServerCommandParams = struct {
    /// See `ServerCommandRequest.command`.
    command: []const u8,
    /// See `ServerCommandRequest.plugin_id`.
    plugin_id: []const u8,
};

/// Serializes `request` as an `engine.serverCommand` request into `buffer`.
///
/// Uses `server_command_request_id` so the waiter can match the response. The
/// returned slice borrows `buffer`.
///
/// Errors: `error.OutOfMemory` while encoding the parameters,
/// `error.WriteFailed` when the request does not fit `buffer`, and writer
/// errors from parameter encoding.
pub fn encodeServerCommand(
    buffer: []u8,
    request: ServerCommandRequest,
) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);

    const allocator = std.heap.page_allocator;
    const params_json = try std.json.Stringify.valueAlloc(
        allocator,
        ServerCommandParams{
            .command = request.command,
            .plugin_id = request.plugin_id,
        },
        .{},
    );
    defer allocator.free(params_json);

    try zjr.composer.writeRequestJson(
        server_command_method,
        params_json,
        zjr.RpcId.of(server_command_request_id),
        &writer,
    );
    return writer.buffered();
}

/// Serializes `request` as a JSON-RPC request and sends it as one frame.
///
/// Precondition: the command text already passed `validateCommand()` and the
/// parent is listening for child requests, which holds while it waits for
/// readiness, an event response, or the shutdown answer.
///
/// Errors: `error.WriteFailed` when the request does not fit the stack buffer
/// or the write fails, `error.OutOfMemory` while encoding the parameters, and
/// `error.PayloadTooLarge` from `writeFrame`.
pub fn sendServerCommand(
    fd: std.os.linux.fd_t,
    request: ServerCommandRequest,
) !void {
    var buffer: [max_payload_len]u8 = undefined;
    const payload_json = try encodeServerCommand(&buffer, request);
    try writeFrame(fd, payload_json);
}

/// Reads the parent's response to the in-flight command request.
///
/// Returns the parsed result. The value owns no strings, so it remains valid
/// after the response storage is released.
///
/// Errors: framing errors from `readFrame`; `error.InvalidFrame` when the
/// marker is missing; `error.EmptyMessage` for an empty payload;
/// `error.UnexpectedCommandResponse` when the payload is not a single JSON-RPC
/// response; `error.UnexpectedResponseId` when the response does not answer
/// `server_command_request_id`; `error.CommandFailed` when the parent returned
/// a JSON-RPC error; and `error.UnexpectedResultType` when the result is not a
/// JSON string. JSON parsing errors are those of `std.json.parseFromSlice`.
pub fn receiveServerCommandResult(
    fd: std.os.linux.fd_t,
    allocator: std.mem.Allocator,
) !ServerCommandResult {
    const frame = try readFrame(fd);
    if (!frame.framed) return error.InvalidFrame;
    if (!frame.received) return error.EmptyMessage;

    var response = parseResponse(allocator, frame.text());
    defer response.deinit();
    const rpc_response = response.value() catch return error.UnexpectedCommandResponse;

    if (!rpc_response.id.eql(server_command_request_id)) {
        return error.UnexpectedResponseId;
    }
    if (rpc_response.hasErr()) return error.CommandFailed;

    const text = switch (rpc_response.result) {
        .string => |bytes| bytes,
        else => return error.UnexpectedResultType,
    };
    var parsed = try std.json.parseFromSlice(ServerCommandResult, allocator, text, .{});
    defer parsed.deinit();
    return parsed.value;
}

// --- Shutdown ---------------------------------------------------------------

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
pub fn parseShutdown(allocator: std.mem.Allocator, text: []const u8) !ParsedShutdown {
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
/// Errors: `error.OutOfMemory` while composing the request and the framing
/// errors of `writeFrame`.
pub fn sendShutdown(fd: std.os.linux.fd_t) !void {
    const allocator = std.heap.page_allocator;
    const payload = try zjr.composer.makeRequestJson(
        allocator,
        shutdown_method,
        null,
        zjr.RpcId.of(shutdown_request_id),
    );
    defer allocator.free(payload);
    try writeFrame(fd, payload);
}

/// Reads one integer parameter when it is present and fits `T`.
///
/// Returns null when the parameter is absent.
///
/// Errors: `error.InvalidParams` when the value is not a JSON integer or does
/// not fit `T`.
fn optionalInt(
    params: std.json.ObjectMap,
    name: []const u8,
    comptime T: type,
) error{InvalidParams}!?T {
    const value = params.get(name) orelse return null;
    const raw = switch (value) {
        .integer => |number| number,
        else => return error.InvalidParams,
    };
    return std.math.cast(T, raw) orelse error.InvalidParams;
}

/// Returns the JSON-RPC method name for `op`.
fn fileMethod(op: FileOp) [:0]const u8 {
    return switch (op) {
        .open => "file.open",
        .close => "file.close",
        .read => "file.read",
        .write => "file.write",
        .seek => "file.seek",
        .tell => "file.tell",
        .size => "file.size",
        .flush => "file.flush",
        .remove => "file.remove",
        .find_open => "file.findOpen",
        .find_next => "file.findNext",
        .find_close => "file.findClose",
    };
}

/// Returns the operation named by a JSON-RPC method, or null.
fn fileOpFromMethod(method: []const u8) ?FileOp {
    inline for (std.meta.fields(FileOp)) |field| {
        const op: FileOp = @enumFromInt(field.value);
        if (std.mem.eql(u8, method, fileMethod(op))) return op;
    }
    return null;
}

/// Returns the operation named by a JSON-RPC method, or null.
fn operationFromMethod(method: []const u8) ?Operation {
    if (std.mem.eql(u8, method, "stderr")) return .stderr;
    if (std.mem.eql(u8, method, "ready")) return .ready;
    return null;
}

/// Returns the JSON-RPC method name for `query`.
fn queryMethod(query: Query) [:0]const u8 {
    return switch (query) {
        .server_info => "query.serverInfo",
        .player_info => "query.playerInfo",
        .entity_exists => "query.entityExists",
        .server_cvar => "query.serverCvar",
        .client_cvar => "query.clientCvar",
    };
}

/// Returns the query named by a JSON-RPC method, or null.
fn queryFromMethod(method: []const u8) ?Query {
    if (std.mem.eql(u8, method, queryMethod(.server_info))) return .server_info;
    if (std.mem.eql(u8, method, queryMethod(.player_info))) return .player_info;
    if (std.mem.eql(u8, method, queryMethod(.entity_exists))) return .entity_exists;
    if (std.mem.eql(u8, method, queryMethod(.server_cvar))) return .server_cvar;
    if (std.mem.eql(u8, method, queryMethod(.client_cvar))) return .client_cvar;
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
