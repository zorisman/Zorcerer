//! One filesystem request sent by the plugin-manager child.
//!
//! `path` is the original `game://` URI for path operations. `handle` is a
//! manager-side ID for handle operations. `data` is standard base64; `length`
//! is the requested raw byte count. Only the fields relevant to `op` are
//! meaningful.

/// Operation to execute.
op: FileOperations,
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
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !ParsedFileRequest {
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

/// Serializes `request` as a JSON-RPC request into `buffer`.
///
/// Uses `file_request_id` so the waiter can match the response. The returned
/// slice borrows `buffer`.
///
/// Errors: `error.OutOfMemory` while encoding the parameters,
/// `error.WriteFailed` when the request does not fit `buffer`, and writer
/// errors from parameter encoding.
pub fn encode(request: *const @This(), buffer: []u8) ![]const u8 {
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
pub fn send(request: *const @This(), fd: std.os.linux.fd_t) !void {
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
pub fn fromResponse(
    fd: std.os.linux.fd_t,
    allocator: std.mem.Allocator,
) !std.json.Parsed(@This()) {
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

/// A filesystem request parsed from a JSON-RPC request.
///
/// `value` borrows the JSON owned by `rpc`; both stay valid until `deinit()`.
pub const ParsedFileRequest = struct {
    /// Parsed JSON-RPC request whose method names the operation.
    rpc: zjr.RpcRequestResult,
    /// Operation and parameters extracted from `rpc`.
    value: FileRequest,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *const @This()) void {
        self.rpc.deinit();
    }

    /// Returns the request ID used for the matching response.
    pub fn id(self: *const @This()) zjr.RpcId {
        return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNone();
    }
};
