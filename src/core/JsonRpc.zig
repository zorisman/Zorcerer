const std = @import("std");
const zjr = @import("zjr");
const Ipc = @import("Ipc.zig");
const Log = @import("../root.zig").io.Log;
const fork = @import("ForkProcess.zig");

/// Executes one JSON-RPC response received from the plugin manager.
///
/// Error responses are printed as diagnostics instead of being treated as
/// results; the engine callbacks have no way to report the failure.
///
/// Errors: `error.UnexpectedResultType` when a successful response does not
/// carry the event text as a JSON string.
fn handleResponse(response: zjr.RpcResponse) !void {
    if (response.hasErr()) {
        std.debug.print(
            "JSON-RPC error {d}: {s}\n",
            .{ response.err().code, response.err().message },
        );
        return;
    }

    switch (response.result) {
        .string => |text| std.debug.print("{s}", .{text}),
        else => return error.UnexpectedResultType,
    }
}

/// Verifies that a response answers the request the listener is waiting for.
///
/// Errors: `error.UnexpectedResponseId` when no response is expected yet or
/// when the response carries a different ID.
pub fn validateResponseId(actual: zjr.RpcId, expected_response_id: ?i64) !void {
    const expected = expected_response_id orelse return error.UnexpectedResponseId;
    if (!actual.eql(expected)) return error.UnexpectedResponseId;
}

/// Answers game queries sent by the plugin-manager child.
///
/// `handle` runs in the engine process, builds a JSON document describing the
/// queried value, and returns it allocated with the allocator it receives. The
/// listener owns and frees that text after sending the response. An error means
/// the query could not be answered; the child receives a JSON-RPC error.
pub const QueryHandler = struct {
    /// Opaque value passed back to `handle`; may be null.
    context: ?*anyopaque,
    /// Executes one query and returns its JSON result text.
    handle: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: Ipc.QueryRequest,
    ) anyerror![]u8,
};

/// Executes one game query and sends its JSON-RPC response.
///
/// A null handler answers `MethodNotFound` instead of stalling the child. A
/// handler failure answers `InternalError` with the error name. Notifications
/// (requests without an ID) are executed without a reply, as JSON-RPC requires.
///
/// Errors are the allocation and framing errors from message composition and
/// `Ipc.writeFrame`.
fn handleQuery(
    socket: std.os.linux.fd_t,
    request: Ipc.QueryRequest,
    id: zjr.RpcId,
    handler: ?QueryHandler,
) !void {
    const allocator = std.heap.page_allocator;

    const active_handler = handler orelse {
        if (!id.isNotification()) {
            try Ipc.sendErrorResponse(socket, id, .MethodNotFound, "Query is not available");
        }
        return;
    };

    const result_text = active_handler.handle(active_handler.context, allocator, request) catch |err| {
        if (!id.isNotification()) {
            try Ipc.sendErrorResponse(socket, id, .InternalError, @errorName(err));
        }
        return;
    };
    defer allocator.free(result_text);

    if (id.isNotification()) return;

    // Query results are typed JSON documents; transmitting them as a JSON
    // string keeps every response result a string, like event responses.
    const quoted = try std.json.Stringify.valueAlloc(allocator, result_text, .{});
    defer allocator.free(quoted);
    try Ipc.sendResultResponse(socket, id, quoted);
}

/// Listener for the manager's messages: reads framed JSON-RPC messages from
/// `socket` until the expected response or readiness arrives.
///
/// Notifications (`.stderr` log lines and `.ready`) are executed without a
/// reply, so child logging cannot terminate the listener or satisfy a pending
/// event exchange. Child game queries are executed through `query_handler`
/// while the listener keeps waiting for its own response. Responses are matched
/// against `expected_response_id`.
///
/// `expected_response_id` is null while waiting for readiness: the listener
/// returns after a successful `.ready` and fails with `error.PluginLoadFailed`
/// on a failed readiness text. For event exchanges it is
/// `Ipc.event_request_id`: the listener returns after handling that response.
///
/// Errors: `error.InvalidFrame` when the frame marker is missing,
/// `error.EmptyMessage` for a zero-length payload, `error.UnexpectedResponseId`
/// for a response that does not match a pending event, the framing errors of
/// `Ipc.readFrame`, the JSON errors of `Ipc.parseRequest`/`Ipc.parseResponse`,
/// and the response-shape errors of `handleResponse`.
pub fn jsonListener(
    socket: std.os.linux.fd_t,
    expected_response_id: ?i64,
    query_handler: ?QueryHandler,
) !void {
    const allocator = std.heap.page_allocator;

    while (true) {
        const frame = try Ipc.readFrame(socket);
        if (!frame.framed) return error.InvalidFrame;
        if (!frame.received) return error.EmptyMessage;

        if (Ipc.parseQuery(allocator, frame.text())) |query| {
            defer query.deinit();
            try handleQuery(socket, query.value, query.id(), query_handler);
            continue;
        } else |err| switch (err) {
            // Not a query: fall through to operation/response handling.
            error.UnknownMethod, error.NotRpcRequest => {},
            else => return err,
        }

        const request = Ipc.parseRequest(allocator, frame.text()) catch |err| switch (err) {
            error.NotRpcRequest => {
                var response = Ipc.parseResponse(allocator, frame.text());
                defer response.deinit();
                const rpc_response = try response.value();
                try validateResponseId(rpc_response.id, expected_response_id);
                try handleResponse(rpc_response);
                return;
            },
            else => return err,
        };
        defer request.deinit();

        const request_id = request.id();
        const outcome = try handleRequest(request.value);

        if (!request_id.isNotification()) {
            try Ipc.sendResultResponse(socket, request_id, "\"OK\"");
        }

        if (outcome == .ready and expected_response_id == null) return;
    }
}

/// What the listener should do after executing one operation notification.
pub const RequestOutcome = enum {
    /// Keep serving the channel.
    continue_listening,
    /// The child reported successful readiness.
    ready,
};

/// Executes one operation notification received from the plugin manager.
///
/// `.stderr` messages are forwarded to the parent's log sink. `.ready` with
/// `manager_ready_message` reports success. Any other readiness text means the
/// child could not load its plugins: it is logged as a startup failure and
/// returned as `error.PluginLoadFailed`, so `load()` refuses the plugin set.
pub fn handleRequest(request: Ipc.Request) !RequestOutcome {
    switch (request.operation) {
        .stderr => {
            Log.logLine("{s}", .{request.message});
            return .continue_listening;
        },
        .ready => {
            if (std.mem.eql(u8, request.message, fork.manager_ready_message)) {
                return .ready;
            }
            Log.logLine("[MyLoader] plugin manager startup failed: {s}\n", .{request.message});
            return error.PluginLoadFailed;
        },
    }
}
