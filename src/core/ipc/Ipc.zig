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

// --- Filesystem -------------------------------------------------------------

/// Largest raw file-data chunk one filesystem message carries.
///
/// Base64 expands three input bytes to four characters, so a chunk this size
/// fits `max_payload_len` together with its JSON envelope.
pub const file_chunk_len: usize = 2048;

// --- Engine commands --------------------------------------------------------

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

// --- Client messages --------------------------------------------------------

/// Request ID the plugin-manager child uses for client-print requests.
///
/// Client prints are synchronous and strictly one at a time: the child blocks
/// until the engine process has delivered the message, and the parent is
/// already listening while it waits for readiness, an event response, or the
/// shutdown answer. Keeping the ID distinct from `event_request_id`,
/// `query_request_id`, `file_request_id`, `server_command_request_id`, and
/// `shutdown_request_id` prevents a reply from satisfying the wrong exchange.
pub const client_print_request_id: i64 = 103;

/// Largest message one `engine.clientPrint` request accepts, in bytes.
///
/// The value leaves room for the JSON envelope and for escaping the message
/// inside a `max_payload_len` frame even when every byte needs a two-character
/// escape. Longer messages are rejected rather than truncated, because a
/// truncated message would reach the client with unintended text.
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

/// Reasons `validateClientPrint()` rejects a client message.
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
pub fn validateClientPrint(text: []const u8) ClientPrintError!void {
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
/// with `validateClientPrint()` before sending or executing it.
///
/// Errors: `error.NotRpcRequest` when `text` is a response or batch,
/// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
/// `error.UnknownMethod` when the method is not a client-print request, and
/// `error.InvalidParams` when `message` is missing or not a string, or
/// `plugin_id` is not a string.
pub fn parseClientPrint(
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
/// Uses `client_print_request_id` so the waiter can match the response. The
/// returned slice borrows `buffer`.
///
/// Errors: `error.OutOfMemory` while encoding the parameters,
/// `error.WriteFailed` when the request does not fit `buffer`, and writer
/// errors from parameter encoding.
pub fn encodeClientPrint(
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
        zjr.RpcId.of(client_print_request_id),
        &writer,
    );
    return writer.buffered();
}

/// Serializes `request` as a JSON-RPC request and sends it as one frame.
///
/// Precondition: the message already passed `validateClientPrint()` and the
/// parent is listening for child requests, which holds while it waits for
/// readiness, an event response, or the shutdown answer.
///
/// Errors: `error.WriteFailed` when the request does not fit the stack buffer
/// or the write fails, `error.OutOfMemory` while encoding the parameters, and
/// `error.PayloadTooLarge` from `writeFrame`.
pub fn sendClientPrint(
    fd: std.os.linux.fd_t,
    request: ClientPrintRequest,
) !void {
    var buffer: [max_payload_len]u8 = undefined;
    const payload_json = try encodeClientPrint(&buffer, request);
    try writeFrame(fd, payload_json);
}

/// Reads the parent's response to the in-flight client-print request.
///
/// Returns the parsed result. The value owns no strings, so it remains valid
/// after the response storage is released.
///
/// Errors: framing errors from `readFrame`; `error.InvalidFrame` when the
/// marker is missing; `error.EmptyMessage` for an empty payload;
/// `error.UnexpectedClientPrintResponse` when the payload is not a single
/// JSON-RPC response; `error.UnexpectedResponseId` when the response does not
/// answer `client_print_request_id`; `error.ClientPrintFailed` when the parent
/// returned a JSON-RPC error; and `error.UnexpectedResultType` when the result
/// is not a JSON string. JSON parsing errors are those of
/// `std.json.parseFromSlice`.
pub fn receiveClientPrintResult(
    fd: std.os.linux.fd_t,
    allocator: std.mem.Allocator,
) !ClientPrintResult {
    const frame = try readFrame(fd);
    if (!frame.framed) return error.InvalidFrame;
    if (!frame.received) return error.EmptyMessage;

    var response = parseResponse(allocator, frame.text());
    defer response.deinit();
    const rpc_response = response.value() catch return error.UnexpectedClientPrintResponse;

    if (!rpc_response.id.eql(client_print_request_id)) {
        return error.UnexpectedResponseId;
    }
    if (rpc_response.hasErr()) return error.ClientPrintFailed;

    const text = switch (rpc_response.result) {
        .string => |bytes| bytes,
        else => return error.UnexpectedResultType,
    };
    var parsed = try std.json.parseFromSlice(ClientPrintResult, allocator, text, .{});
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
