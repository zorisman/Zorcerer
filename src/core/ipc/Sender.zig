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
