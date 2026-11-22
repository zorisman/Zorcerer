//! The `engine.clientPrint` message schema for the IPC channel.
//!
//! The plugin-manager child sends one client-print request and blocks until
//! the Entrypoint answers. Both processes use this module, so the schema
//! cannot drift apart. The Entrypoint remains the actual boundary: the
//! child's validation is only an early diagnostic.

const std = @import("std");
const zjr = @import("zjr");
const Frame = @import("Frame.zig");
const Response = @import("Response.zig");
const Identifiers = @import("IdentifierRegistry.zig").Identifiers;

/// Largest message one `engine.clientPrint` request accepts, in bytes.
///
/// The value leaves room for the JSON envelope and for escaping the message
/// inside a `Frame.max_payload_len` frame even when every byte needs a
/// two-character escape. Longer messages are rejected rather than truncated,
/// because a truncated message would reach the client with unintended text.
pub const max_client_print_len: usize = 1024;

/// JSON-RPC method the plugin-manager child uses to ask the engine process to
/// print one message in a client's console.
pub const client_print_method = "engine.clientPrint";

/// One client-print request sent by the plugin-manager child.
///
/// `message` is the text shown in the client's console. `plugin_id` is
/// advisory attribution for the Entrypoint's audit log; it never grants or
/// denies access. The target is the client whose `ClientCommand` callback is
/// currently active, so no entity index crosses the process boundary.
pub const ClientPrintRequest = struct {
    /// Message to print in the active client's console.
    message: []const u8,
    /// Id of the plugin or Lua script that sent the request.
    plugin_id: []const u8 = "",
};

/// JSON result of an accepted `engine.clientPrint` request.
///
/// `printed` reports that the Entrypoint called `IVEngineServer::ClientPrintf`
/// for the active client. It does not prove that the client displayed the
/// text.
pub const ClientPrintResult = struct {
    /// Whether the message was handed to the engine.
    printed: bool,
};

/// Reasons `validate()` rejects a client message.
pub const ClientPrintError = error{
    /// The message is empty or consists only of whitespace.
    EmptyClientPrint,
    /// The message is longer than `max_client_print_len`.
    ClientPrintTooLong,
    /// The message contains a NUL byte that would truncate the C string.
    EmbeddedNul,
    /// The message contains a line break and would print multiple lines.
    MultilineClientPrint,
    /// The message contains an unsupported control character. Tab is allowed.
    ControlCharacter,
};

/// Validates a client-console message before it is sent or printed.
///
/// Both the child and the Entrypoint call this function. The Entrypoint remains
/// the actual boundary: the child's validation is only an early diagnostic.
///
/// Whitespace-only text is rejected. The text must fit `max_client_print_len`,
/// must not contain `\x00` (`ClientPrintf` receives a zero-terminated string),
/// and must be a single line. Other control characters are rejected because a
/// console message has no use for them; tab is allowed.
///
/// Errors: the `ClientPrintError` variants described above.
pub fn validate(text: []const u8) ClientPrintError!void {
    if (std.mem.trim(u8, text, " \t").len == 0) return error.EmptyClientPrint;
    if (text.len > max_client_print_len) return error.ClientPrintTooLong;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.MultilineClientPrint;
    for (text) |byte| {
        if (byte < 0x20 and byte != '\t') return error.ControlCharacter;
    }
}

/// A client-print request parsed from a JSON-RPC request.
///
/// `value` borrows the JSON owned by `rpc`; both stay valid until `deinit()`.
pub const ParsedClientPrint = struct {
    /// Parsed JSON-RPC request carrying the message.
    rpc: zjr.RpcRequestResult,
    /// Message and attribution extracted from `rpc`.
    value: ClientPrintRequest,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *const ParsedClientPrint) void {
        self.rpc.deinit();
    }

    /// Returns the request ID used for the matching response.
    pub fn id(self: *const ParsedClientPrint) zjr.RpcId {
        return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNone();
    }
};

/// Parses one `engine.clientPrint` JSON-RPC request.
///
/// The method is `engine.clientPrint`. Object parameters must carry a string
/// `message`; an optional string `plugin_id` is copied into
/// `ClientPrintRequest.plugin_id`.
///
/// This function checks parameter types only. Callers validate the message text
/// with `validate()` before sending or executing it.
///
/// Errors: `error.NotRpcRequest` when `text` is a response or batch,
/// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
/// `error.UnknownMethod` when the method is not a client-print request, and
/// `error.InvalidParams` when `message` is missing or not a string, or
/// `plugin_id` is not a string.
pub fn parse(
    allocator: std.mem.Allocator,
    text: []const u8,
) !ParsedClientPrint {
    var rpc = zjr.parseRpcRequest(allocator, text);
    errdefer rpc.deinit();

    if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
    const request = rpc.request_msg.request;
    if (request.hasError()) return error.InvalidRpcRequest;
    if (!std.mem.eql(u8, request.method, client_print_method)) {
        return error.UnknownMethod;
    }

    const params = request.objectParams() orelse return error.InvalidParams;
    const message = switch (params.get("message") orelse return error.InvalidParams) {
        .string => |bytes| bytes,
        else => return error.InvalidParams,
    };

    var value = ClientPrintRequest{ .message = message };
    if (params.get("plugin_id")) |plugin_id_value| {
        value.plugin_id = switch (plugin_id_value) {
            .string => |bytes| bytes,
            else => return error.InvalidParams,
        };
    }

    return .{ .rpc = rpc, .value = value };
}

/// Parameters serialized into an `engine.clientPrint` request.
const ClientPrintParams = struct {
    /// See `ClientPrintRequest.message`.
    message: []const u8,
    /// See `ClientPrintRequest.plugin_id`.
    plugin_id: []const u8,
};

/// Serializes `request` as an `engine.clientPrint` request into `buffer`.
///
/// Uses `Identifiers.client_print_request_id` so the waiter can match the
/// response. The returned slice borrows `buffer`.
///
/// Errors: `error.OutOfMemory` while encoding the parameters,
/// `error.WriteFailed` when the request does not fit `buffer`, and writer
/// errors from parameter encoding.
pub fn encode(
    buffer: []u8,
    request: ClientPrintRequest,
) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);

    const allocator = std.heap.page_allocator;
    const params_json = try std.json.Stringify.valueAlloc(
        allocator,
        ClientPrintParams{
            .message = request.message,
            .plugin_id = request.plugin_id,
        },
        .{},
    );
    defer allocator.free(params_json);

    try zjr.composer.writeRequestJson(
        client_print_method,
        params_json,
        Identifiers.client_print_request_id.rpcId(),
        &writer,
    );
    return writer.buffered();
}

/// Serializes `request` as a JSON-RPC request and sends it as one frame.
///
/// Precondition: the message already passed `validate()` and the
/// parent is listening for child requests, which holds while it waits for
/// readiness, an event response, or the shutdown answer.
///
/// Errors: `error.WriteFailed` when the request does not fit the stack buffer
/// or the write fails, `error.OutOfMemory` while encoding the parameters, and
/// `error.PayloadTooLarge` from `Frame.write`.
pub fn send(
    fd: std.os.linux.fd_t,
    request: ClientPrintRequest,
) !void {
    var buffer: [Frame.max_payload_len]u8 = undefined;
    const payload_json = try encode(&buffer, request);
    try Frame.write(fd, payload_json);
}

/// Reads the parent's response to the in-flight client-print request.
///
/// Returns the parsed result. The value owns no strings, so it remains valid
/// after the response storage is released.
///
/// Errors: framing errors from `Frame.read`; `error.InvalidFrame` when the
/// marker is missing; `error.EmptyMessage` for an empty payload;
/// `error.UnexpectedClientPrintResponse` when the payload is not a single
/// JSON-RPC response; `error.UnexpectedResponseId` when the response does not
/// answer the client-print request ID; `error.ClientPrintFailed` when the
/// parent returned a JSON-RPC error; and `error.UnexpectedResultType` when the
/// result is not a JSON string. JSON parsing errors are those of
/// `std.json.parseFromSlice`.
pub fn receiveResult(
    fd: std.os.linux.fd_t,
    allocator: std.mem.Allocator,
) !ClientPrintResult {
    const frame = try Frame.read(fd);
    if (!frame.framed) return error.InvalidFrame;
    if (!frame.received) return error.EmptyMessage;

    var response = Response.parseResponse(allocator, frame.text());
    defer response.deinit();
    const rpc_response = response.value() catch return error.UnexpectedClientPrintResponse;

    if (!rpc_response.id.eql(@intFromEnum(Identifiers.client_print_request_id))) {
        return error.UnexpectedResponseId;
    }
    if (rpc_response.hasErr()) return error.ClientPrintFailed;

    const result_text = switch (rpc_response.result) {
        .string => |bytes| bytes,
        else => return error.UnexpectedResultType,
    };
    var parsed = try std.json.parseFromSlice(ClientPrintResult, allocator, result_text, .{});
    defer parsed.deinit();
    return parsed.value;
}
