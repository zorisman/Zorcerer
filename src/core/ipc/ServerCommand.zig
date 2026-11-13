//! The `engine.serverCommand` message schema for the IPC channel.
//!
//! The plugin-manager child sends one command request and blocks until the
//! Entrypoint answers. Both processes use this module, so the schema cannot
//! drift apart. The Entrypoint remains the actual boundary: the child's
//! validation is only an early diagnostic.

const std = @import("std");
const zjr = @import("zjr");
const Frame = @import("Frame.zig");
const Response = @import("Response.zig");
const Identifiers = @import("IdentifierRegistry.zig").Identifiers;

/// Largest command text one `engine.serverCommand` request accepts, in bytes.
///
/// The value leaves room for the JSON envelope and for escaping the command
/// inside a `Frame.max_payload_len` frame even when every byte needs a
/// two-character escape. Longer commands are rejected rather than truncated,
/// because a truncated command could execute something other than what the
/// caller intended.
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

/// Reasons `validate()` rejects command text.
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
pub fn validate(text: []const u8) CommandError!void {
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
/// with `validate()` before sending or executing it.
///
/// Errors: `error.NotRpcRequest` when `text` is a response or batch,
/// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
/// `error.UnknownMethod` when the method is not a command request,
/// `error.InvalidParams` when `command` is missing or not a string, or
/// `plugin_id` is not a string.
pub fn parse(
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
/// Uses `Identifiers.server_command_request_id` so the waiter can match the
/// response. The returned slice borrows `buffer`.
///
/// Errors: `error.OutOfMemory` while encoding the parameters,
/// `error.WriteFailed` when the request does not fit `buffer`, and writer
/// errors from parameter encoding.
pub fn encode(
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
        Identifiers.server_command_request_id.rpcId(),
        &writer,
    );
    return writer.buffered();
}

/// Serializes `request` as a JSON-RPC request and sends it as one frame.
///
/// Precondition: the command text already passed `validate()` and the
/// parent is listening for child requests, which holds while it waits for
/// readiness, an event response, or the shutdown answer.
///
/// Errors: `error.WriteFailed` when the request does not fit the stack buffer
/// or the write fails, `error.OutOfMemory` while encoding the parameters, and
/// `error.PayloadTooLarge` from `Frame.write`.
pub fn send(
    fd: std.os.linux.fd_t,
    request: ServerCommandRequest,
) !void {
    var buffer: [Frame.max_payload_len]u8 = undefined;
    const payload_json = try encode(&buffer, request);
    try Frame.write(fd, payload_json);
}

/// Reads the parent's response to the in-flight command request.
///
/// Returns the parsed result. The value owns no strings, so it remains valid
/// after the response storage is released.
///
/// Errors: framing errors from `Frame.read`; `error.InvalidFrame` when the
/// marker is missing; `error.EmptyMessage` for an empty payload;
/// `error.UnexpectedCommandResponse` when the payload is not a single JSON-RPC
/// response; `error.UnexpectedResponseId` when the response does not answer
/// `Identifiers.server_command_request_id`; `error.CommandFailed` when the
/// parent returned a JSON-RPC error; and `error.UnexpectedResultType` when the
/// result is not a JSON string. JSON parsing errors are those of
/// `std.json.parseFromSlice`.
pub fn receiveResult(
    fd: std.os.linux.fd_t,
    allocator: std.mem.Allocator,
) !ServerCommandResult {
    const frame = try Frame.read(fd);
    if (!frame.framed) return error.InvalidFrame;
    if (!frame.received) return error.EmptyMessage;

    var response = Response.parseResponse(allocator, frame.text());
    defer response.deinit();
    const rpc_response = response.value() catch return error.UnexpectedCommandResponse;

    if (!rpc_response.id.eql(Identifiers.server_command_request_id.rpcId())) {
        return error.UnexpectedResponseId;
    }
    if (rpc_response.hasErr()) return error.CommandFailed;

    const result_text = switch (rpc_response.result) {
        .string => |bytes| bytes,
        else => return error.UnexpectedResultType,
    };
    var parsed = try std.json.parseFromSlice(ServerCommandResult, allocator, result_text, .{});
    defer parsed.deinit();
    return parsed.value;
}
