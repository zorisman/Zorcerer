const std = @import("std");
const zroot = @import("zroot");
const ssdk = zroot.ssdk;
const CCommand = ssdk.ClientCommand;
const PlayerInfo = ssdk.PlayerInfo;
const ConVar = ssdk.ConVar;
const Indexes = ssdk.indexes;
const QueryResult = zroot.ipc.QueryResult;
const QueryError = zroot.ipc.Query.Query.QueryError;
const Queries = zroot.ipc.query_types.GameQueries.Queries;

test "CCommand matches the Source SDK binary layout" {
    try std.testing.expectEqual(@as(usize, 1544), @sizeOf(CCommand));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CCommand, "m_nArgc"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(CCommand, "m_nArgv0Size"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CCommand, "m_pArgSBuffer"));
    try std.testing.expectEqual(@as(usize, 520), @offsetOf(CCommand, "m_pArgvBuffer"));
    try std.testing.expectEqual(@as(usize, 1032), @offsetOf(CCommand, "m_ppArgv"));
}

test "CCommand.commandText reads the NUL-terminated command line" {
    var command = std.mem.zeroes(CCommand);
    command.m_nArgc = 2;
    const text = "zlua ping";
    @memcpy(command.m_pArgSBuffer[0..text.len], text);

    try std.testing.expectEqualStrings(text, command.commandText().?);

    command.m_nArgc = 0;
    try std.testing.expect(command.commandText() == null);
}

/// Number of slots in the fake engine vtable: enough for every method the
/// queries bind, including the last one the generator records.
const fake_engine_slot_count = Indexes.IVEngineServer.set_paused_forced + 1;

/// Number of slots in the fake cvar vtable.
const fake_cvar_slot_count = Indexes.ICvar.factory_internal_iterator + 1;

/// A fake interface object: the engine sees the vptr as the first word.
fn FakeObject(comptime slot_count: usize) type {
    return struct {
        vptr: [*]const *const anyopaque = undefined,
        vtable: [slot_count]*const anyopaque = undefined,

        fn init() @This() {
            var object = @This(){};
            for (&object.vtable) |*slot| slot.* = @ptrCast(&fakeUnused);
            return object;
        }

        /// Publishes the object after it has reached its final address.
        fn interface(self: *@This()) *anyopaque {
            self.vptr = &self.vtable;
            return @ptrCast(self);
        }
    };
}

/// Placeholder vtable entry for methods a test does not exercise.
fn fakeUnused(_: *anyopaque) callconv(.c) void {}

fn fakeIsDedicated(_: *anyopaque) callconv(.c) bool {
    return true;
}

fn fakeIsPaused(_: *anyopaque) callconv(.c) bool {
    return true;
}

fn fakeEntityCount(_: *anyopaque) callconv(.c) c_int {
    return 42;
}

fn fakeServerVersion(_: *anyopaque) callconv(.c) c_int {
    return 123;
}

fn fakeServerTime(_: *anyopaque) callconv(.c) f32 {
    return 4.5;
}

fn fakeGameDir(_: *anyopaque, buffer: [*]u8, max_length: c_int) callconv(.c) void {
    const text = "tf";
    const length = @min(text.len + 1, @as(usize, @intCast(max_length)));
    @memcpy(buffer[0..text.len], text);
    if (length > text.len) buffer[text.len] = 0;
}

fn fakePEntity(_: *anyopaque, index: c_int) callconv(.c) ?*anyopaque {
    return if (index == 1) @ptrFromInt(@as(usize, 0x1000)) else null;
}

fn fakePlayerInfo(
    _: *anyopaque,
    index: c_int,
    info: *PlayerInfo,
) callconv(.c) bool {
    if (index != 1) return false;
    info.* = std.mem.zeroes(PlayerInfo);
    @memcpy(info.name[0..5], "Alice");
    info.user_id = 7;
    @memcpy(info.guid[0..3], "STE");
    info.friends_id = 99;
    @memcpy(info.friends_name[0..3], "Bob");
    info.fake_player = false;
    info.is_hltv = false;
    return true;
}

fn fakeClientCvar(
    _: *anyopaque,
    index: c_int,
    name: [*:0]const u8,
) callconv(.c) ?[*:0]const u8 {
    if (index != 1) return null;
    if (!std.mem.eql(u8, std.mem.span(name), "cl_name")) return null;
    return "client-value";
}

/// Builds an engine binding whose vtable answers every query.
fn fakeEngine() FakeObject(fake_engine_slot_count) {
    var engine = FakeObject(fake_engine_slot_count).init();
    engine.vtable[Indexes.IVEngineServer.is_dedicated_server] = @ptrCast(&fakeIsDedicated);
    engine.vtable[Indexes.IVEngineServer.get_entity_count] = @ptrCast(&fakeEntityCount);
    engine.vtable[Indexes.IVEngineServer.p_entity_of_ent_index] = @ptrCast(&fakePEntity);
    engine.vtable[Indexes.IVEngineServer.get_game_dir] = @ptrCast(&fakeGameDir);
    engine.vtable[Indexes.IVEngineServer.get_client_con_var_value] = @ptrCast(&fakeClientCvar);
    engine.vtable[Indexes.IVEngineServer.is_paused] = @ptrCast(&fakeIsPaused);
    engine.vtable[Indexes.IVEngineServer.get_player_info] = @ptrCast(&fakePlayerInfo);
    engine.vtable[Indexes.IVEngineServer.get_server_version] = @ptrCast(&fakeServerVersion);
    engine.vtable[Indexes.IVEngineServer.get_server_time] = @ptrCast(&fakeServerTime);
    return engine;
}

/// Root ConVar used by the fake `ICvar`.
var fake_cvar_root: ConVar = undefined;

fn fakeFindVar(_: *anyopaque, name: [*:0]const u8) callconv(.c) ?*ConVar {
    if (!std.mem.eql(u8, std.mem.span(name), "sv_cheats")) return null;
    return &fake_cvar_root;
}

/// Initializes `fake_cvar_root` and returns a fake `ICvar` that finds it.
fn fakeCvar() FakeObject(fake_cvar_slot_count) {
    fake_cvar_root = std.mem.zeroes(ConVar);
    fake_cvar_root.parent = &fake_cvar_root;
    fake_cvar_root.string_value = "1";
    fake_cvar_root.int_value = 1;
    fake_cvar_root.float_value = 1.0;

    var cvar = FakeObject(fake_cvar_slot_count).init();
    cvar.vtable[Indexes.ICvar.find_var] = @ptrCast(&fakeFindVar);
    return cvar;
}

test "server info query binds the engine vtable and reports values" {
    var engine = fakeEngine();
    var queries = Queries{};
    queries.setEngine(engine.interface());
    queries.setMap("cp_badlands");

    const text = try Queries.handle(&queries, std.testing.allocator, .{ .query = .server_info });
    defer std.testing.allocator.free(text);

    var parsed = try std.json.parseFromSlice(QueryResult.ServerInfo, std.testing.allocator, text, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.dedicated);
    try std.testing.expect(parsed.value.paused);
    try std.testing.expectEqual(@as(c_int, 42), parsed.value.entity_count);
    try std.testing.expectEqual(@as(c_int, 123), parsed.value.server_version);
    try std.testing.expectEqual(@as(f32, 4.5), parsed.value.server_time);
    try std.testing.expectEqualStrings("tf", parsed.value.game_dir);
    try std.testing.expectEqualStrings("cp_badlands", parsed.value.map_name);
}

test "map name is empty outside a level" {
    var engine = fakeEngine();
    var queries = Queries{};
    queries.setEngine(engine.interface());
    queries.setMap("cp_badlands");
    queries.clearMap();

    const text = try Queries.handle(&queries, std.testing.allocator, .{ .query = .server_info });
    defer std.testing.allocator.free(text);

    var parsed = try std.json.parseFromSlice(QueryResult.ServerInfo, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("", parsed.value.map_name);
}

test "player info query reports an empty slot and a filled slot" {
    var engine = fakeEngine();
    var queries = Queries{};
    queries.setEngine(engine.interface());

    const empty_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .player_info, .index = 2 },
    );
    defer std.testing.allocator.free(empty_text);

    var empty = try std.json.parseFromSlice(QueryResult.PlayerInfo, std.testing.allocator, empty_text, .{});
    defer empty.deinit();
    try std.testing.expect(!empty.value.present);

    const filled_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .player_info, .index = 1 },
    );
    defer std.testing.allocator.free(filled_text);

    var filled = try std.json.parseFromSlice(QueryResult.PlayerInfo, std.testing.allocator, filled_text, .{});
    defer filled.deinit();
    try std.testing.expect(filled.value.present);
    try std.testing.expectEqual(@as(c_int, 7), filled.value.user_id);
    try std.testing.expectEqual(@as(u32, 99), filled.value.friends_id);
    try std.testing.expectEqualStrings("Alice", filled.value.name);
    try std.testing.expectEqualStrings("STE", filled.value.guid);
    try std.testing.expectEqualStrings("Bob", filled.value.friends_name);
}

test "entity query reports present and missing indexes" {
    var engine = fakeEngine();
    var queries = Queries{};
    queries.setEngine(engine.interface());

    const present_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .entity_exists, .index = 1 },
    );
    defer std.testing.allocator.free(present_text);
    var present = try std.json.parseFromSlice(QueryResult.EntityInfo, std.testing.allocator, present_text, .{});
    defer present.deinit();
    try std.testing.expect(present.value.exists);

    const missing_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .entity_exists, .index = 2 },
    );
    defer std.testing.allocator.free(missing_text);
    var missing = try std.json.parseFromSlice(QueryResult.EntityInfo, std.testing.allocator, missing_text, .{});
    defer missing.deinit();
    try std.testing.expect(!missing.value.exists);
}

test "server cvar query reads the mirrored ConVar layout" {
    var cvar = fakeCvar();
    var queries = Queries{};
    queries.setCvar(cvar.interface());

    const found_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .server_cvar, .name = "sv_cheats" },
    );
    defer std.testing.allocator.free(found_text);
    var found = try std.json.parseFromSlice(QueryResult.CvarValue, std.testing.allocator, found_text, .{});
    defer found.deinit();
    try std.testing.expect(found.value.found);
    try std.testing.expectEqual(@as(c_int, 1), found.value.int_value);
    try std.testing.expectEqual(@as(f32, 1.0), found.value.float_value);
    try std.testing.expectEqualStrings("1", found.value.text);

    const missing_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .server_cvar, .name = "missing" },
    );
    defer std.testing.allocator.free(missing_text);
    var missing = try std.json.parseFromSlice(QueryResult.CvarValue, std.testing.allocator, missing_text, .{});
    defer missing.deinit();
    try std.testing.expect(!missing.value.found);
}

test "client cvar query reads the engine value" {
    var engine = fakeEngine();
    var queries = Queries{};
    queries.setEngine(engine.interface());

    const text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .client_cvar, .index = 1, .name = "cl_name" },
    );
    defer std.testing.allocator.free(text);
    var parsed = try std.json.parseFromSlice(QueryResult.CvarValue, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.found);
    try std.testing.expectEqualStrings("client-value", parsed.value.text);
}

test "queries fail cleanly when the engine is not bound" {
    var queries = Queries{};
    try std.testing.expectError(
        QueryError.EngineUnavailable,
        Queries.handle(&queries, std.testing.allocator, .{ .query = .server_info }),
    );
    try std.testing.expectError(
        QueryError.CvarUnavailable,
        Queries.handle(
            &queries,
            std.testing.allocator,
            .{ .query = .server_cvar, .name = "sv_cheats" },
        ),
    );
}
