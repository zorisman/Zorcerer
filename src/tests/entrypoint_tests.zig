const std = @import("std");
const zjr = @import("zjr");
const fork = @import("../core/ForkProcess.zig");
const Ipc = @import("../core/Ipc.zig");
const JsonRpc = @import("../core/JsonRpc.zig");
const Manager = @import("../core/PluginManager.zig");
const Log = @import("../io/Log.zig");

test {
    _ = @import("zjr");
}

/// Child used by the IPC tests: sends the same readiness message the
/// plugin-manager child sends once it is ready.
fn testReportChild(fd: std.os.linux.fd_t) void {
    Ipc.sendReady(fd, fork.manager_ready_message) catch {};
}

/// Child used by the logging test: forwards a plugin print over IPC.
fn testLogChild(fd: std.os.linux.fd_t) void {
    Log.setupIpc(fd);
    Log.pluginPrint(undefined, "plugin log line\n");
}

test "child logging is sent over IPC" {
    var child = try fork.forkChild(testLogChild);
    defer child.finish() catch {};

    const frame = try Ipc.readFrame(child.socket);
    const request = try Ipc.parseRequest(std.testing.allocator, frame.text());
    defer request.deinit();

    try std.testing.expectEqual(Ipc.Operation.stderr, request.value.operation);
    try std.testing.expectEqualStrings("plugin log line\n", request.value.message);
    try std.testing.expect(request.id().isNone());
}

test "forked child reports that it initialized" {
    var child = try fork.forkChild(testReportChild);
    defer child.finish() catch {};

    const frame = try Ipc.readFrame(child.socket);
    try std.testing.expect(frame.framed);
}

test "parent receives a JSON message from the child" {
    var child = try fork.forkChild(testReportChild);
    defer child.finish() catch {};

    const frame = try Ipc.readFrame(child.socket);
    try std.testing.expect(frame.received);

    const request = try Ipc.parseRequest(std.testing.allocator, frame.text());
    defer request.deinit();
    try std.testing.expectEqual(Ipc.Operation.ready, request.value.operation);
    try std.testing.expectEqualStrings(fork.manager_ready_message, request.value.message);
    try std.testing.expect(request.id().isNone());
}

test "child payload matches the serialized request" {
    var child = try fork.forkChild(testReportChild);
    defer child.finish() catch {};

    const frame = try Ipc.readFrame(child.socket);
    try std.testing.expect(frame.matches(
        "{\"jsonrpc\": \"2.0\", \"method\": \"ready\", \"params\": {\"message\":\"Hello from fork\"}}",
    ));
}

test "listener schema decodes the ready operation" {
    const request = try Ipc.parseRequest(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"ready\",\"params\":{\"message\":\"Hello from fork\"}}",
    );
    defer request.deinit();

    try std.testing.expectEqual(Ipc.Operation.ready, request.value.operation);
    try std.testing.expectEqualStrings("Hello from fork", request.value.message);
}

test "listener schema decodes the stderr operation" {
    const request = try Ipc.parseRequest(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"stderr\",\"params\":{\"message\":\"a log line\"}}",
    );
    defer request.deinit();

    try std.testing.expectEqual(Ipc.Operation.stderr, request.value.operation);
    try std.testing.expectEqualStrings("a log line", request.value.message);
}

test "successful readiness is accepted" {
    try std.testing.expectEqual(
        JsonRpc.RequestOutcome.ready,
        try JsonRpc.handleRequest(.{ .operation = .ready, .message = fork.manager_ready_message }),
    );
}

test "failed readiness is rejected" {
    try std.testing.expectError(
        error.PluginLoadFailed,
        JsonRpc.handleRequest(.{
            .operation = .ready,
            .message = "plugin loading failed: OutOfMemory",
        }),
    );
}

test "unexpected response IDs are rejected" {
    try std.testing.expectError(
        error.UnexpectedResponseId,
        JsonRpc.validateResponseId(zjr.RpcId.of(2), Ipc.event_request_id),
    );
    try std.testing.expectError(
        error.UnexpectedResponseId,
        JsonRpc.validateResponseId(zjr.RpcId.of(Ipc.event_request_id), null),
    );
    try JsonRpc.validateResponseId(zjr.RpcId.of(Ipc.event_request_id), Ipc.event_request_id);
}

test "listener schema rejects an unknown operation" {
    try std.testing.expectError(
        error.UnknownMethod,
        Ipc.parseRequest(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"stdout\",\"params\":{\"message\":\"x\"}}",
        ),
    );
}

test "listener schema ignores unknown JSON-RPC fields" {
    const request = try Ipc.parseRequest(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"stderr\",\"params\":{\"message\":\"x\"},\"unexpected\":1}",
    );
    defer request.deinit();

    try std.testing.expectEqual(Ipc.Operation.stderr, request.value.operation);
    try std.testing.expectEqualStrings("x", request.value.message);
}

test "event JSON matches the schema" {
    const cases = [_]struct { event: Ipc.Event, name: []const u8 }{
        .{ .event = .pause, .name = "pause" },
        .{ .event = .unpause, .name = "unpause" },
        .{ .event = .levelInit, .name = "levelInit" },
        .{ .event = .serverActivate, .name = "serverActivate" },
        .{ .event = .levelShutdown, .name = "levelShutdown" },
    };

    var buffer: [128]u8 = undefined;
    for (cases) |case| {
        const text = try Ipc.encodeEvent(&buffer, case.event);

        var expected_buffer: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(
            &expected_buffer,
            "{{\"jsonrpc\": \"2.0\", \"method\": \"{s}\", \"id\": {d}}}",
            .{ case.name, Ipc.event_request_id },
        );
        try std.testing.expectEqualStrings(expected, text);

        const parsed = try Ipc.parseEvent(std.testing.allocator, text);
        defer parsed.deinit();
        try std.testing.expectEqual(case.event, parsed.value.event);
        try std.testing.expect(parsed.id().eql(Ipc.event_request_id));
    }
}

test "event schema rejects an unknown callback" {
    try std.testing.expectError(
        error.UnknownMethod,
        Ipc.parseEvent(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"bogus\",\"id\":1}",
        ),
    );
}

test "manager answers every Entrypoint event with a JSON-RPC result" {
    var child = try fork.forkChild(Manager.listenForEvents);
    defer child.finish() catch {};

    const cases = [_]struct { event: Ipc.Event, name: []const u8 }{
        .{ .event = .pause, .name = "pause" },
        .{ .event = .unpause, .name = "unpause" },
        .{ .event = .levelInit, .name = "levelInit" },
        .{ .event = .serverActivate, .name = "serverActivate" },
        .{ .event = .levelShutdown, .name = "levelShutdown" },
    };

    for (cases) |case| {
        try Ipc.sendEvent(child.socket, case.event);

        const frame = try Ipc.readFrame(child.socket);
        try std.testing.expect(frame.received);

        var response = Ipc.parseResponse(std.testing.allocator, frame.text());
        defer response.deinit();
        const rpc_response = try response.value();
        try std.testing.expect(!rpc_response.hasErr());
        try std.testing.expect(rpc_response.id.eql(Ipc.event_request_id));

        var expected_buffer: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(
            &expected_buffer,
            "Event is {s}",
            .{case.name},
        );
        try std.testing.expectEqualStrings(expected, rpc_response.result.string);
    }
}

test "manager ignores event notifications" {
    var child = try fork.forkChild(Manager.listenForEvents);
    defer child.finish() catch {};

    // Neither a valid event notification nor an invalid one may produce a
    // reply; only the following request is answered.
    try Ipc.writeFrame(child.socket, "{\"jsonrpc\":\"2.0\",\"method\":\"pause\"}");
    try Ipc.writeFrame(child.socket, "{\"jsonrpc\":\"2.0\",\"method\":\"bogus\"}");
    try Ipc.sendEvent(child.socket, .unpause);

    const frame = try Ipc.readFrame(child.socket);
    try std.testing.expect(frame.received);

    var response = Ipc.parseResponse(std.testing.allocator, frame.text());
    defer response.deinit();
    const rpc_response = try response.value();
    try std.testing.expect(!rpc_response.hasErr());
    try std.testing.expect(rpc_response.id.eql(Ipc.event_request_id));
    try std.testing.expectEqualStrings("Event is unpause", rpc_response.result.string);
}

test "manager answers an unknown event instead of stalling" {
    var child = try fork.forkChild(Manager.listenForEvents);
    defer child.finish() catch {};

    try Ipc.writeFrame(
        child.socket,
        "{\"jsonrpc\":\"2.0\",\"method\":\"bogus\",\"id\":3}",
    );

    const frame = try Ipc.readFrame(child.socket);
    var response = Ipc.parseResponse(std.testing.allocator, frame.text());
    defer response.deinit();
    const rpc_response = try response.value();

    try std.testing.expect(rpc_response.hasErr());
    try std.testing.expect(rpc_response.id.eql(3));
    try std.testing.expectEqual(
        @as(i32, @intFromEnum(zjr.ErrorCode.MethodNotFound)),
        rpc_response.err().code,
    );
    try std.testing.expectEqualStrings("Event is invalid", rpc_response.err().message);
}
