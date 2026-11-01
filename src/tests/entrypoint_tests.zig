const std = @import("std");
const zjr = @import("zjr");
const root = @import("zroot");
const Entrypoint = root.core.Entrypoint;
const Vsp = root.core.Vsp;
const fork = root.core.ForkProcess;
const Ipc = root.Ipc;
const JsonRpc = root.core.JsonRpc;
const Manager = root.core.PluginManager;
const EngineCommands = root.core.EngineCommands;
const FileService = root.core.FileService;
const LuaHost = root.core.LuaHost;
const zlua = @import("zlua");
const Log = root.io.Log;

/// Mirrors Entrypoint.PluginObject so tests can inspect the published vtable.
const PluginObject = extern struct {
    vptr: [*]const Vsp.Slot,
};

/// Factory that resolves no engine interface; `load` refuses it immediately.
fn noEngineInterface(_: [*:0]const u8, _: ?*c_int) callconv(.c) ?*anyopaque {
    return null;
}

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

test "CreateInterface publishes a populated VSP vtable" {
    for (Vsp.plugin_interface_versions) |version| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrintZ(&name_buffer, "{s}", .{version});

        var return_code: c_int = -1;
        const interface_ptr = Entrypoint.CreateInterface(name.ptr, &return_code) orelse
            return error.ExpectedInterface;
        try std.testing.expectEqual(Vsp.iface_ok, return_code);

        const object: *const PluginObject = @ptrCast(@alignCast(interface_ptr));
        for (object.vptr[0..Vsp.VTable.slot_count]) |slot| {
            try std.testing.expect(slot != null);
        }

        const description: *const fn (*anyopaque) callconv(.c) [*:0]const u8 =
            @ptrCast(object.vptr[4].?);
        try std.testing.expectEqualStrings("Zorcerer", std.mem.span(description(interface_ptr)));

        const load: *const fn (
            *anyopaque,
            Vsp.CreateInterfaceFn,
            Vsp.CreateInterfaceFn,
        ) callconv(.c) bool = @ptrCast(object.vptr[0].?);
        try std.testing.expect(!load(interface_ptr, noEngineInterface, noEngineInterface));
    }
}

test "CreateInterface rejects unknown interface versions" {
    var return_code: c_int = -1;
    try std.testing.expect(Entrypoint.CreateInterface("IServerPluginCallbacks999", &return_code) == null);
    try std.testing.expectEqual(Vsp.iface_failed, return_code);
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
        const text = try Ipc.encodeEvent(&buffer, case.event, null);

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

test "event payload round-trips as JSON text" {
    var buffer: [256]u8 = undefined;
    const text = try Ipc.encodeEvent(&buffer, .levelInit, "{\"map\":\"de_dust2\"}");

    const parsed = try Ipc.parseEvent(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expectEqual(Ipc.Event.levelInit, parsed.value.event);
    try std.testing.expectEqualStrings("{\"map\":\"de_dust2\"}", parsed.value.payload.?);
}

test "event schema rejects a non-string payload" {
    try std.testing.expectError(
        error.InvalidParams,
        Ipc.parseEvent(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"levelInit\",\"params\":{\"payload\":1},\"id\":1}",
        ),
    );
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
        try Ipc.sendEvent(child.socket, case.event, null);

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
    try Ipc.sendEvent(child.socket, .unpause, null);

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

test "query request round-trips through the IPC schema" {
    var buffer: [256]u8 = undefined;
    const text = try Ipc.encodeQuery(&buffer, .{
        .query = .player_info,
        .index = 3,
        .name = "cl_name",
    });

    const parsed = try Ipc.parseQuery(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqual(Ipc.Query.player_info, parsed.value.query);
    try std.testing.expectEqual(@as(c_int, 3), parsed.value.index);
    try std.testing.expectEqualStrings("cl_name", parsed.value.name);
    try std.testing.expect(parsed.id().eql(Ipc.query_request_id));
}

test "query schema rejects non-query methods and bad parameters" {
    try std.testing.expectError(
        error.UnknownMethod,
        Ipc.parseQuery(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"stderr\",\"params\":{\"message\":\"x\"}}",
        ),
    );
    try std.testing.expectError(
        error.InvalidParams,
        Ipc.parseQuery(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"query.playerInfo\",\"params\":{\"index\":\"x\"},\"id\":100}",
        ),
    );
}

/// Answers every child query with a fixed server-info document.
fn testQueryHandler(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: Ipc.QueryRequest,
) anyerror![]u8 {
    if (request.query != .server_info) return error.UnexpectedQuery;
    return allocator.dupe(u8, "{\"dedicated\":true}");
}

/// Child that asks one question before reporting readiness.
fn testQueryChild(fd: std.os.linux.fd_t) void {
    Ipc.sendQuery(fd, .{ .query = .server_info }) catch return;
    const text = Ipc.receiveQueryResult(fd, std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(text);

    if (!std.mem.eql(u8, text, "{\"dedicated\":true}")) return;
    Ipc.sendReady(fd, fork.manager_ready_message) catch {};
}

test "parent listener answers a child query while waiting for readiness" {
    var child = try fork.forkChild(testQueryChild);
    defer child.finish() catch {};

    try JsonRpc.jsonListener(
        child.socket,
        null,
        .{ .context = null, .handle = testQueryHandler },
        null,
        null,
    );
}

/// Answers one filesystem request with a fixed result document.
fn testFileHandler(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: Ipc.FileRequest,
) anyerror![]u8 {
    if (request.op != .open) return error.UnexpectedRequest;
    if (!std.mem.eql(u8, request.path, "game://materials")) return error.UnexpectedPath;
    return allocator.dupe(u8, "{\"status\":0,\"handle\":5}");
}

/// Child that asks one filesystem question before reporting readiness.
fn testFileChild(fd: std.os.linux.fd_t) void {
    Ipc.sendFileRequest(fd, .{ .op = .open, .path = "game://materials" }) catch return;
    const result = Ipc.receiveFileResult(fd, std.heap.page_allocator) catch return;
    defer result.deinit();

    if (result.value.status != 0 or result.value.handle != 5) return;
    Ipc.sendReady(fd, fork.manager_ready_message) catch {};
}

test "parent listener answers a child file request while waiting for readiness" {
    var child = try fork.forkChild(testFileChild);
    defer child.finish() catch {};

    try JsonRpc.jsonListener(
        child.socket,
        null,
        null,
        .{ .context = null, .handle = testFileHandler },
        null,
    );
}

test "file request round-trips through the IPC schema" {
    var buffer: [Ipc.max_payload_len]u8 = undefined;
    const text = try Ipc.encodeFileRequest(&buffer, .{
        .op = .write,
        .path = "plugin://note.txt",
        .mode = 1,
        .handle = 9,
        .offset = -4,
        .origin = 2,
        .length = 64,
        .data = "aGVsbG8=",
    });

    const parsed = try Ipc.parseFileRequest(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqual(Ipc.FileOp.write, parsed.value.op);
    try std.testing.expectEqualStrings("plugin://note.txt", parsed.value.path);
    try std.testing.expectEqual(@as(c_int, 1), parsed.value.mode);
    try std.testing.expectEqual(@as(u64, 9), parsed.value.handle);
    try std.testing.expectEqual(@as(i64, -4), parsed.value.offset);
    try std.testing.expectEqual(@as(c_int, 2), parsed.value.origin);
    try std.testing.expectEqual(@as(usize, 64), parsed.value.length);
    try std.testing.expectEqualStrings("aGVsbG8=", parsed.value.data);
    try std.testing.expect(parsed.id().eql(Ipc.file_request_id));
}

test "file schema rejects non-file methods" {
    try std.testing.expectError(
        error.UnknownMethod,
        Ipc.parseFileRequest(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"pause\",\"id\":1}",
        ),
    );
}

/// Records the command passed to a fake `IVEngineServer::ServerCommand`.
const CommandSink = struct {
    /// Last command text received, including the added line terminator but
    /// without the NUL byte.
    buffer: [Ipc.max_command_len + 1]u8 = undefined,
    /// Number of valid bytes in `buffer`.
    len: usize = 0,

    /// Copies and records one command. The signature matches
    /// `EngineCommands.EngineOps.server_command`.
    fn execute(engine: *anyopaque, command: [*:0]const u8) callconv(.c) void {
        const self: *CommandSink = @ptrCast(@alignCast(engine));
        const text = std.mem.span(command);
        @memcpy(self.buffer[0..text.len], text);
        self.len = text.len;
    }
};

test "engine command binding validates and forwards one command" {
    var sink = CommandSink{};
    var binding = EngineCommands.Binding{
        .engine = &sink,
        .ops = .{ .server_command = CommandSink.execute },
    };

    const text = try EngineCommands.Binding.handle(
        &binding,
        std.testing.allocator,
        .{ .command = "say hello", .plugin_id = "demo" },
    );
    defer std.testing.allocator.free(text);

    var parsed = try std.json.parseFromSlice(
        Ipc.ServerCommandResult,
        std.testing.allocator,
        text,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.value.accepted);
    try std.testing.expectEqualStrings("say hello\n", sink.buffer[0..sink.len]);
}

test "engine command binding rejects invalid text before the engine call" {
    var sink = CommandSink{};
    var binding = EngineCommands.Binding{
        .engine = &sink,
        .ops = .{ .server_command = CommandSink.execute },
    };

    try std.testing.expectError(
        error.EmptyCommand,
        EngineCommands.Binding.handle(&binding, std.testing.allocator, .{ .command = " \t" }),
    );
    try std.testing.expectError(
        error.EmbeddedNul,
        EngineCommands.Binding.handle(
            &binding,
            std.testing.allocator,
            .{ .command = "say\x00hello" },
        ),
    );
    try std.testing.expectError(
        error.MultilineCommand,
        EngineCommands.Binding.handle(
            &binding,
            std.testing.allocator,
            .{ .command = "say hello\nquit" },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), sink.len);
}

test "command request round-trips through the IPC schema" {
    var buffer: [Ipc.max_payload_len]u8 = undefined;
    const text = try Ipc.encodeServerCommand(&buffer, .{
        .command = "say hello",
        .plugin_id = "demo",
    });

    const parsed = try Ipc.parseServerCommand(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("say hello", parsed.value.command);
    try std.testing.expectEqualStrings("demo", parsed.value.plugin_id);
    try std.testing.expect(parsed.id().eql(Ipc.server_command_request_id));
}

test "command validation rejects unsafe text" {
    const too_long = [_]u8{'a'} ** (Ipc.max_command_len + 1);

    try std.testing.expectError(error.EmptyCommand, Ipc.validateCommand(" \t"));
    try std.testing.expectError(error.CommandTooLong, Ipc.validateCommand(&too_long));
    try std.testing.expectError(error.EmbeddedNul, Ipc.validateCommand("say\x00hello"));
    try std.testing.expectError(error.MultilineCommand, Ipc.validateCommand("say hello\nquit"));
    try std.testing.expectError(error.MultilineCommand, Ipc.validateCommand("say hello\rquit"));
    try std.testing.expectError(error.ControlCharacter, Ipc.validateCommand("say\x01hello"));
    try Ipc.validateCommand("say hello\tagain");
}

/// Answers one command request and reports readiness.
fn testCommandHandler(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: Ipc.ServerCommandRequest,
) anyerror![]u8 {
    if (!std.mem.eql(u8, request.command, "say hello")) return error.UnexpectedCommand;
    if (!std.mem.eql(u8, request.plugin_id, "demo")) return error.UnexpectedPluginId;
    return allocator.dupe(u8, "{\"accepted\":true}");
}

/// Child that sends one command request before reporting readiness.
fn testCommandChild(fd: std.os.linux.fd_t) void {
    Ipc.sendServerCommand(fd, .{
        .command = "say hello",
        .plugin_id = "demo",
    }) catch return;
    const result = Ipc.receiveServerCommandResult(fd, std.heap.page_allocator) catch return;
    if (!result.accepted) return;
    Ipc.sendReady(fd, fork.manager_ready_message) catch {};
}

test "parent listener answers a child command while waiting for readiness" {
    var child = try fork.forkChild(testCommandChild);
    defer child.finish() catch {};

    try JsonRpc.jsonListener(
        child.socket,
        null,
        null,
        null,
        .{ .context = null, .handle = testCommandHandler },
    );
}

test "shutdown request round-trips through the IPC schema" {
    const parsed = try Ipc.parseShutdown(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"shutdown\",\"id\":200}",
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.id().eql(Ipc.shutdown_request_id));
}

test "manager acknowledges shutdown and stops listening" {
    var child = try fork.forkChild(Manager.listenForEvents);
    defer child.finish() catch {};

    try Ipc.sendShutdown(child.socket);

    const frame = try Ipc.readFrame(child.socket);
    try std.testing.expect(frame.received);

    var response = Ipc.parseResponse(std.testing.allocator, frame.text());
    defer response.deinit();
    const rpc_response = try response.value();
    try std.testing.expect(!rpc_response.hasErr());
    try std.testing.expect(rpc_response.id.eql(Ipc.shutdown_request_id));
    try std.testing.expectEqualStrings("OK", rpc_response.result.string);
}

test "query client receives a result from a responder" {
    var child = try fork.forkChild(testQueryResponder);
    defer child.finish() catch {};

    try Ipc.sendQuery(child.socket, .{
        .query = .entity_exists,
        .index = 4,
    });
    const text = try Ipc.receiveQueryResult(child.socket, std.testing.allocator);
    defer std.testing.allocator.free(text);

    var parsed = try std.json.parseFromSlice(Ipc.EntityInfo, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.exists);
}

/// Answers one query request with a fixed entity document.
fn testQueryResponder(fd: std.os.linux.fd_t) void {
    const frame = Ipc.readFrame(fd) catch return;
    const parsed = Ipc.parseQuery(std.heap.page_allocator, frame.text()) catch return;
    defer parsed.deinit();

    if (parsed.value.query != .entity_exists or parsed.value.index != 4) return;
    Ipc.sendResultResponse(fd, parsed.id(), "\"{\\\"exists\\\":true}\"") catch {};
}

test "Lua script queries the game through LuaHost" {
    var child = try fork.forkChild(testLuaGameQueryResponder);
    defer child.finish() catch {};

    var manager = Manager.Manager.init();
    manager.ipc_fd = child.socket;
    defer manager.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var plugin_dir = try tmp.dir.createDirPathOpen(std.testing.io, "demo", .{});
    plugin_dir.close(std.testing.io);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "demo/main.lua",
        .data =
        \\local info = assert(zostd.game.server_info())
        \\assert(info.dedicated == true)
        \\assert(info.paused == false)
        \\assert(info.entity_count == 12)
        \\assert(info.server_version == 9000)
        \\assert(math.abs(info.server_time - 1.5) < 0.001)
        \\assert(info.game_dir == "tf")
        \\assert(info.map_name == "cp_process")
        \\
        \\local player = assert(zostd.game.player_info(1))
        \\assert(player.index == 1)
        \\assert(player.user_id == 5)
        \\assert(player.friends_id == 77)
        \\assert(player.name == "Alice")
        \\assert(player.guid == "STEAM")
        \\assert(player.friends_name == "Bob")
        \\assert(player.fake_player == true)
        \\assert(player.is_hltv == false)
        \\assert(zostd.game.player_info(2) == nil)
        \\
        \\assert(zostd.game.entity_exists(1) == true)
        \\assert(zostd.game.entity_exists(2) == false)
        \\
        \\local cvar = assert(zostd.game.server_cvar("sv_cheats"))
        \\assert(cvar.int_value == 1)
        \\assert(math.abs(cvar.float_value - 1.0) < 0.001)
        \\assert(cvar.text == "1")
        \\assert(zostd.game.server_cvar("missing") == nil)
        \\
        \\local client = assert(zostd.game.client_cvar(1, "cl_name"))
        \\assert(client.text == "client")
        \\assert(zostd.game.client_cvar(2, "cl_name") == nil)
        ,
    });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const plugins_root = path_buffer[0..root_len];

    var service = try FileService.Service.init(
        std.testing.allocator,
        std.testing.io,
        child.socket,
        plugins_root,
    );
    defer service.deinit();

    const files = try service.createPluginFiles("demo");
    defer service.destroyPluginFiles(files);

    var host_context = LuaHost.Context{ .manager = &manager, .files = files };
    var script = try zlua.Script.load(std.testing.allocator, std.testing.io, .{
        .plugins_directory = plugins_root,
        .directory_name = "demo",
        .host = LuaHost.host(&host_context),
    });
    defer script.deinit();
}

test "Lua script sends a server command through LuaHost" {
    var child = try fork.forkChild(testLuaServerCommandResponder);
    defer child.finish() catch {};

    var manager = Manager.Manager.init();
    manager.ipc_fd = child.socket;
    defer manager.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var plugin_dir = try tmp.dir.createDirPathOpen(std.testing.io, "demo", .{});
    plugin_dir.close(std.testing.io);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "demo/main.lua",
        .data =
        \\assert(zostd.plugin_id() == "demo")
        \\local ok = assert(zostd.server_command("say hello"))
        \\assert(ok == true)
        \\
        \\local bad, bad_error = zostd.server_command(
        \\    "say hello" .. string.char(10) .. "quit")
        \\assert(bad == nil)
        \\assert(string.find(bad_error, "MultilineCommand", 1, true) ~= nil)
        ,
    });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const plugins_root = path_buffer[0..root_len];

    var service = try FileService.Service.init(
        std.testing.allocator,
        std.testing.io,
        child.socket,
        plugins_root,
    );
    defer service.deinit();

    const files = try service.createPluginFiles("demo");
    defer service.destroyPluginFiles(files);

    var host_context = LuaHost.Context{
        .manager = &manager,
        .files = files,
        .plugin_id = "demo",
    };
    var script = try zlua.Script.load(std.testing.allocator, std.testing.io, .{
        .plugins_directory = plugins_root,
        .directory_name = "demo",
        .host = LuaHost.host(&host_context),
    });
    defer script.deinit();
}

/// Answers one `engine.serverCommand` request and returns an acceptance
/// document.
fn testLuaServerCommandResponder(fd: std.os.linux.fd_t) void {
    const frame = Ipc.readFrame(fd) catch return;
    if (!frame.framed or !frame.received) return;

    const parsed = Ipc.parseServerCommand(std.heap.page_allocator, frame.text()) catch return;
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.command, "say hello")) return;
    if (!std.mem.eql(u8, parsed.value.plugin_id, "demo")) return;
    Ipc.sendResultResponse(
        fd,
        parsed.id(),
        "\"{\\\"accepted\\\":true}\"",
    ) catch return;
}

/// Answers every game-query request with a fixed document matching the query
/// and its parameters, until the parent closes the socket.
///
/// Results are serialized as JSON strings because `Ipc.receiveQueryResult`
/// expects the result of a query response to be a string containing the result
/// document.
fn testLuaGameQueryResponder(fd: std.os.linux.fd_t) void {
    const allocator = std.heap.page_allocator;

    const server_info_result =
        \\{"dedicated":true,"paused":false,"entity_count":12,"server_version":9000,"server_time":1.5,"game_dir":"tf","map_name":"cp_process"}
    ;
    const player_present_result =
        \\{"present":true,"index":1,"user_id":5,"friends_id":77,"name":"Alice","guid":"STEAM","friends_name":"Bob","fake_player":true,"is_hltv":false}
    ;
    const player_absent_result =
        \\{"present":false,"index":2,"user_id":0,"friends_id":0,"name":"","guid":"","friends_name":"","fake_player":false,"is_hltv":false}
    ;
    const entity_present_result =
        \\{"exists":true}
    ;
    const entity_absent_result =
        \\{"exists":false}
    ;
    const cvar_present_result =
        \\{"found":true,"int_value":1,"float_value":1.0,"text":"1"}
    ;
    const cvar_absent_result =
        \\{"found":false,"int_value":0,"float_value":0.0,"text":""}
    ;
    const client_cvar_present_result =
        \\{"found":true,"int_value":0,"float_value":0.0,"text":"client"}
    ;

    while (true) {
        const frame = Ipc.readFrame(fd) catch return;
        if (!frame.framed or !frame.received) return;

        const parsed = Ipc.parseQuery(allocator, frame.text()) catch return;
        defer parsed.deinit();

        const result_text: []const u8 = switch (parsed.value.query) {
            .server_info => server_info_result,
            .player_info => if (parsed.value.index == 1)
                player_present_result
            else
                player_absent_result,
            .entity_exists => if (parsed.value.index == 1)
                entity_present_result
            else
                entity_absent_result,
            .server_cvar => if (std.mem.eql(u8, parsed.value.name, "sv_cheats"))
                cvar_present_result
            else
                cvar_absent_result,
            .client_cvar => if (parsed.value.index == 1 and
                std.mem.eql(u8, parsed.value.name, "cl_name"))
                client_cvar_present_result
            else
                cvar_absent_result,
        };

        const quoted = std.json.Stringify.valueAlloc(allocator, result_text, .{}) catch return;
        defer allocator.free(quoted);
        Ipc.sendResultResponse(fd, parsed.id(), quoted) catch return;
    }
}
