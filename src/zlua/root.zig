//! ZLua: the LuaJIT runtime embedded in Zorcerer.
//!
//! The module contains the runtime, its Lua-facing `zostd` bridge, and the
//! executable contract for both. The plugin manager creates one `Runtime` per
//! loaded Lua script; the tests here exercise the same state lifecycle without
//! requiring a plugin manifest or a forked engine process.

const std = @import("std");
const Runtime = @import("Runtime.zig").Runtime;
const zostd_bridge = @import("zostd.zig");

/// Re-exported for callers that only import the `zlua` module.
pub const runtime = @import("Runtime.zig");

/// One loaded Lua script: discovery, runtime setup, lifecycle events, and
/// teardown.
pub const Script = @import("Script.zig").Script;

/// Re-exported so callers can inspect the installed Lua-facing type bridge.
pub const zostd = zostd_bridge;

test "LuaJIT runtime exposes and prints a zostd type value" {
    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.openSafeLibs();
    lua_runtime.installZostd();

    try lua_runtime.run(
        \\local team = zostd.types.TfTeam.red
        \\print("zostd.types.TfTeam.red.value = " .. team.value)
        \\assert(team.value == 2)
        \\assert(zostd.types.TfTeam.is_game_team(team) == true)
        \\assert(zostd.types.TfTeam.is_game_team(zostd.types.TfTeam.spectator) == false)
    , "@zlua/zostd_types_test.lua");
}

test "zostd exposes every Source SDK value type to Lua" {
    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.openSafeLibs();
    lua_runtime.installZostd();

    try lua_runtime.run(
        \\local types = zostd.types
        \\
        \\local team = types.TfTeam.red
        \\assert(team.value == 2)
        \\assert(team.name == "red")
        \\assert(types.TfTeam.halloween.value == 5)
        \\assert(types.TfTeam.is_game_team(team) == true)
        \\assert(types.TfTeam.is_game_team(types.TfTeam.spectator) == false)
        \\assert(types.TfTeam.is_game_team(2) == true)
        \\assert(types.TfTeam.is_game_team({ value = 1 }) == false)
        \\
        \\assert(types.TfClass.soldier.value == 3)
        \\assert(types.TfClass.is_normal_player(types.TfClass.scout) == true)
        \\assert(types.TfClass.is_normal_player(types.TfClass.civilian) == false)
        \\
        \\assert(types.TfCondition.invalid.value == -1)
        \\assert(types.TfCondition.first.value == 0)
        \\assert(types.TfCondition.last_in_this_sdk == 131)
        \\assert(types.TfCondition.is_invalid(types.TfCondition.invalid) == true)
        \\assert(types.TfCondition.is_known_in_this_sdk({ value = 130 }) == true)
        \\assert(types.TfCondition.is_known_in_this_sdk({ value = 131 }) == false)
        \\
        \\assert(types.TfObjectType.sentrygun.value == 2)
        \\assert(types.TfObjectType.obj_last.value == 4)
        \\assert(types.TfObjectType.is_known_in_this_sdk(types.TfObjectType.teleporter) == true)
        \\assert(types.TfObjectType.is_known_in_this_sdk(types.TfObjectType.obj_last) == false)
        \\
        \\assert(types.TfWeaponId.none.value == 0)
        \\assert(types.TfWeaponId.count_in_this_sdk == 110)
        \\assert(types.TfWeaponId.is_known_in_this_sdk({ value = 109 }) == true)
        \\assert(types.TfWeaponId.is_known_in_this_sdk({ value = 110 }) == false)
        \\
        \\assert(types.QueryCvarCookie.invalid.value == -1)
        \\assert(types.QueryCvarCookie.is_valid({ value = 7 }) == true)
        \\assert(types.QueryCvarCookie.is_valid(types.QueryCvarCookie.invalid) == false)
        \\
        \\assert(types.ModelIndex.is_valid({ value = 0 }) == true)
        \\assert(types.ModelIndex.is_valid({ value = -1 }) == false)
        \\assert(types.ModelIndex.is_precached({ value = 0 }) == true)
        \\assert(types.ModelIndex.is_dynamic({ value = -2 }) == true)
        \\assert(types.ModelIndex.dynamic_index({ value = -2 }) == 0)
        \\assert(types.ModelIndex.dynamic_index({ value = 0 }) == nil)
        \\assert(types.ModelIndex.is_client_only({ value = -2 }) == false)
        \\assert(types.ModelIndex.is_client_only({ value = -3 }) == true)
        \\
        \\local handle = { value = 0x00020001 }
        \\assert(types.EntityHandle.invalid.value == 0xFFFFFFFF)
        \\assert(types.EntityHandle.is_valid(handle) == true)
        \\assert(types.EntityHandle.is_valid(types.EntityHandle.invalid) == false)
        \\assert(types.EntityHandle.raw_index(handle) == 1)
        \\assert(types.EntityHandle.serial(handle) == 2)
        \\assert(types.EntityHandle.entity_index(handle).value == 1)
        \\assert(types.EntityHandle.edict_index(handle).value == 1)
        \\assert(types.EntityHandle.entity_index(types.EntityHandle.invalid) == nil)
        \\local built = types.EntityHandle.from_parts(1, 2)
        \\assert(built.value == 0x00020001)
        \\
        \\assert(types.EntityIndex.max_value == 8191)
        \\assert(types.EntityIndex.to_edict_index({ value = 5 }).value == 5)
        \\assert(types.EntityIndex.to_edict_index({ value = 2048 }) == nil)
        \\assert(types.EntityIndex.from_edict_index({ value = 7 }).value == 7)
        \\
        \\assert(types.StringToken.is_null({ value = 0 }) == true)
        \\assert(types.StringToken.is_null({ value = 1 }) == false)
        \\assert(types.StringToken.eql({ value = 7 }, { value = 7 }) == true)
        \\assert(types.StringToken.eql({ value = 7 }, { value = 8 }) == false)
        \\
        \\assert(types.DamageMask.has_any({ value = 5 }, { value = 1 }) == true)
        \\assert(types.DamageMask.has_any({ value = 4 }, { value = 1 }) == false)
    , "@zlua/zostd_all_types_test.lua");
}

test "safe libraries omit filesystem, process, and FFI escapes" {
    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.openSafeLibs();

    try lua_runtime.run(
        \\assert(type(string) == "table")
        \\assert(type(table) == "table")
        \\assert(type(math) == "table")
        \\assert(type(bit) == "table")
        \\assert(io == nil)
        \\assert(os == nil)
        \\assert(package == nil)
        \\assert(debug == nil)
        \\assert(jit == nil)
        \\assert(ffi == nil)
        \\assert(dofile == nil)
        \\assert(loadfile == nil)
        \\assert(loadstring == nil)
        \\assert(load == nil)
        \\assert(zostd == nil)
    , "@zlua/sandbox_test.lua");

    lua_runtime.installZostd();
    try lua_runtime.run(
        \\assert(zostd.version() == 1)
        \\assert(type(zostd.types) == "table")
    , "@zlua/zostd_install_test.lua");
}

/// Host implementation used by the zosstd tests. It records everything the
/// Lua script asks for so the test can assert the calls after the chunk runs.
const MockHost = struct {
    allocator: std.mem.Allocator,
    log_buffer: std.ArrayList(u8) = .empty,
    written_path: std.ArrayList(u8) = .empty,
    written_data: std.ArrayList(u8) = .empty,
    command: std.ArrayList(u8) = .empty,
    client_message: std.ArrayList(u8) = .empty,
    net_written: std.ArrayList(u8) = .empty,

    fn deinit(self: *MockHost) void {
        self.log_buffer.deinit(self.allocator);
        self.written_path.deinit(self.allocator);
        self.written_data.deinit(self.allocator);
        self.command.deinit(self.allocator);
        self.client_message.deinit(self.allocator);
        self.net_written.deinit(self.allocator);
    }

    fn log(context: ?*anyopaque, message: []const u8) void {
        const self: *MockHost = @ptrCast(@alignCast(context.?));
        self.log_buffer.appendSlice(self.allocator, message) catch {};
    }

    fn pluginId(context: ?*anyopaque) []const u8 {
        _ = context;
        return "mock-plugin";
    }

    fn readFile(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) ![]u8 {
        _ = context;
        if (std.mem.eql(u8, path, "plugin://hello.txt")) {
            return allocator.dupe(u8, "hello from host");
        }
        return error.FileNotFound;
    }

    fn writeFile(
        context: ?*anyopaque,
        path: []const u8,
        data: []const u8,
    ) !void {
        const self: *MockHost = @ptrCast(@alignCast(context.?));
        try self.written_path.appendSlice(self.allocator, path);
        try self.written_data.appendSlice(self.allocator, data);
    }

    fn serverCommand(context: ?*anyopaque, command: []const u8) !void {
        const self: *MockHost = @ptrCast(@alignCast(context.?));
        try self.command.appendSlice(self.allocator, command);
    }

    fn clientPrint(context: ?*anyopaque, message: []const u8) !void {
        const self: *MockHost = @ptrCast(@alignCast(context.?));
        try self.client_message.appendSlice(self.allocator, message);
    }

    /// Accepts port 27015 and returns the fixed handle 7.
    fn netConnect(_: ?*anyopaque, host: []const u8, port: u16) !u64 {
        if (!std.mem.eql(u8, host, "example.com") or port != 27015) {
            return error.PermissionDenied;
        }
        return 7;
    }

    /// Accepts only the mock handle.
    fn netClose(_: ?*anyopaque, handle: u64) !void {
        if (handle != 7) return error.InvalidHandle;
    }

    /// Copies a fixed payload into the caller's buffer.
    fn netRead(_: ?*anyopaque, handle: u64, destination: []u8) !usize {
        if (handle != 7) return error.InvalidHandle;
        const payload = "pong";
        const count = @min(payload.len, destination.len);
        @memcpy(destination[0..count], payload[0..count]);
        return count;
    }

    /// Records the written payload and reports it as accepted.
    fn netWrite(context: ?*anyopaque, handle: u64, source: []const u8) !usize {
        const self: *MockHost = @ptrCast(@alignCast(context.?));
        if (handle != 7) return error.InvalidHandle;
        try self.net_written.appendSlice(self.allocator, source);
        return source.len;
    }

    /// Reports the connection as readable.
    fn netPoll(
        _: ?*anyopaque,
        handle: u64,
        events: u8,
        timeout_ms: u32,
        out_events: *u8,
    ) !void {
        _ = timeout_ms;
        if (handle != 7) return error.InvalidHandle;
        out_events.* = events & zostd_bridge.net_poll_in;
    }

    /// Fills a fixed server snapshot for the `zostd.game` tests.
    fn gameServerInfo(_: ?*anyopaque, out: *zostd_bridge.GameServerInfo) c_int {
        out.* = std.mem.zeroes(zostd_bridge.GameServerInfo);
        out.dedicated = true;
        out.paused = false;
        out.entity_count = 12;
        out.server_version = 9000;
        out.server_time = 1.5;
        const game_dir = "tf";
        @memcpy(out.game_dir[0..game_dir.len], game_dir);
        out.game_dir_len = game_dir.len;
        const map_name = "cp_process";
        @memcpy(out.map_name[0..map_name.len], map_name);
        out.map_name_len = map_name.len;
        return zostd_bridge.game_query_ok;
    }

    /// Fills a player for slot 1 and reports an empty slot otherwise.
    fn gamePlayerInfo(
        _: ?*anyopaque,
        index: c_int,
        out: *zostd_bridge.GamePlayerInfo,
    ) c_int {
        out.* = std.mem.zeroes(zostd_bridge.GamePlayerInfo);
        out.index = index;
        if (index != 1) return zostd_bridge.game_query_ok;

        out.present = true;
        out.user_id = 5;
        out.friends_id = 77;
        out.fake_player = true;
        const name = "Alice";
        @memcpy(out.name[0..name.len], name);
        out.name_len = name.len;
        const guid = "STEAM";
        @memcpy(out.guid[0..guid.len], guid);
        out.guid_len = guid.len;
        const friends_name = "Bob";
        @memcpy(out.friends_name[0..friends_name.len], friends_name);
        out.friends_name_len = friends_name.len;
        return zostd_bridge.game_query_ok;
    }

    /// Reports entity 1 as present.
    fn gameEntityExists(_: ?*anyopaque, index: c_int, out: *bool) c_int {
        out.* = index == 1;
        return zostd_bridge.game_query_ok;
    }

    /// Reports `sv_cheats` as a found server cvar.
    fn gameServerCvar(
        _: ?*anyopaque,
        name: []const u8,
        out: *zostd_bridge.GameCvarValue,
    ) c_int {
        out.* = std.mem.zeroes(zostd_bridge.GameCvarValue);
        if (!std.mem.eql(u8, name, "sv_cheats")) return zostd_bridge.game_query_ok;

        out.found = true;
        out.int_value = 1;
        out.float_value = 1.0;
        const text = "1";
        @memcpy(out.text[0..text.len], text);
        out.text_len = text.len;
        return zostd_bridge.game_query_ok;
    }

    /// Reports `cl_name` for client 1.
    fn gameClientCvar(
        _: ?*anyopaque,
        index: c_int,
        name: []const u8,
        out: *zostd_bridge.GameCvarValue,
    ) c_int {
        out.* = std.mem.zeroes(zostd_bridge.GameCvarValue);
        if (index != 1 or !std.mem.eql(u8, name, "cl_name")) {
            return zostd_bridge.game_query_ok;
        }

        out.found = true;
        const text = "client";
        @memcpy(out.text[0..text.len], text);
        out.text_len = text.len;
        return zostd_bridge.game_query_ok;
    }
};

test "zostd.game queries expose host snapshots to Lua" {
    var host = MockHost{ .allocator = std.testing.allocator };
    defer host.deinit();

    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.setHost(.{
        .context = &host,
        .server_info = MockHost.gameServerInfo,
        .player_info = MockHost.gamePlayerInfo,
        .entity_exists = MockHost.gameEntityExists,
        .server_cvar = MockHost.gameServerCvar,
        .client_cvar = MockHost.gameClientCvar,
    });
    lua_runtime.openSafeLibs();
    lua_runtime.installZostd();

    try lua_runtime.run(
        \\local info = assert(zostd.game.server_info())
        \\assert(info.dedicated == true)
        \\assert(info.paused == false)
        \\assert(info.entity_count == 12)
        \\assert(info.server_version == 9000)
        \\assert(info.server_time == 1.5)
        \\assert(info.game_dir == "tf")
        \\assert(info.map_name == "cp_process")
        \\
        \\local player = assert(zostd.game.player_info(1))
        \\assert(player.index == 1)
        \\assert(player.user_id == 5)
        \\assert(player.friends_id == 77)
        \\assert(player.fake_player == true)
        \\assert(player.is_hltv == false)
        \\assert(player.name == "Alice")
        \\assert(player.guid == "STEAM")
        \\assert(player.friends_name == "Bob")
        \\assert(zostd.game.player_info(2) == nil)
        \\
        \\assert(zostd.game.entity_exists(1) == true)
        \\assert(zostd.game.entity_exists(2) == false)
        \\
        \\local cvar = assert(zostd.game.server_cvar("sv_cheats"))
        \\assert(cvar.int_value == 1)
        \\assert(cvar.float_value == 1.0)
        \\assert(cvar.text == "1")
        \\assert(zostd.game.server_cvar("missing") == nil)
        \\
        \\local client = assert(zostd.game.client_cvar(1, "cl_name"))
        \\assert(client.text == "client")
        \\assert(zostd.game.client_cvar(2, "cl_name") == nil)
    , "@zlua/zostd_game_test.lua");
}

test "zostd.game reports unconfigured queries without raising" {
    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.openSafeLibs();
    lua_runtime.installZostd();

    try lua_runtime.run(
        \\local info, info_error = zostd.game.server_info()
        \\assert(info == nil)
        \\assert(string.find(info_error, "not configured", 1, true) ~= nil)
        \\
        \\local exists, exists_error = zostd.game.entity_exists(1)
        \\assert(exists == false)
        \\assert(string.find(exists_error, "not configured", 1, true) ~= nil)
    , "@zlua/zostd_game_unconfigured_test.lua");
}

test "zostd host operations are callable from Lua" {
    var host = MockHost{ .allocator = std.testing.allocator };
    defer host.deinit();

    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.setHost(.{
        .context = &host,
        .log = MockHost.log,
        .plugin_id = MockHost.pluginId,
        .read_file = MockHost.readFile,
        .write_file = MockHost.writeFile,
        .server_command = MockHost.serverCommand,
        .client_print = MockHost.clientPrint,
    });
    lua_runtime.openSafeLibs();
    lua_runtime.installZostd();

    try lua_runtime.run(
        \\assert(zostd.version() == 1)
        \\assert(zostd.plugin_id() == "mock-plugin")
        \\assert(zostd.log("hello from lua") == true)
        \\
        \\local contents = assert(zostd.read_file("plugin://hello.txt"))
        \\assert(contents == "hello from host")
        \\
        \\local missing, read_error = zostd.read_file("plugin://missing.txt")
        \\assert(missing == nil)
        \\assert(type(read_error) == "string")
        \\assert(string.find(read_error, "FileNotFound", 1, true) ~= nil)
        \\
        \\assert(zostd.write_file("plugin://out.txt", "payload") == true)
        \\assert(zostd.server_command("say hello") == true)
        \\assert(zostd.client_print("Pong!") == true)
    , "@zlua/zostd_host_test.lua");

    try std.testing.expectEqualStrings("hello from lua", host.log_buffer.items);
    try std.testing.expectEqualStrings("plugin://out.txt", host.written_path.items);
    try std.testing.expectEqualStrings("payload", host.written_data.items);
    try std.testing.expectEqualStrings("say hello", host.command.items);
    try std.testing.expectEqualStrings("Pong!", host.client_message.items);
}

test "zostd.net forwards outbound operations to the host" {
    var host = MockHost{ .allocator = std.testing.allocator };
    defer host.deinit();

    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.setHost(.{
        .context = &host,
        .connect = MockHost.netConnect,
        .close_connection = MockHost.netClose,
        .read_network = MockHost.netRead,
        .write_network = MockHost.netWrite,
        .poll_network = MockHost.netPoll,
    });
    lua_runtime.openSafeLibs();
    lua_runtime.installZostd();

    try lua_runtime.run(
        \\assert(zostd.net.poll_in == 1)
        \\assert(zostd.net.poll_out == 2)
        \\assert(zostd.net.poll_error == 4)
        \\assert(zostd.net.poll_hup == 8)
        \\
        \\local handle = assert(zostd.net.connect("example.com", 27015))
        \\assert(handle == 7)
        \\assert(zostd.net.write(handle, "ping") == 4)
        \\local data = assert(zostd.net.read(handle, 8))
        \\assert(data == "pong")
        \\local events = assert(zostd.net.poll(handle, zostd.net.poll_in, 0))
        \\assert(events == zostd.net.poll_in)
        \\assert(zostd.net.close(handle) == true)
        \\
        \\local denied, denied_error = zostd.net.connect("example.com", 1)
        \\assert(denied == nil)
        \\assert(string.find(denied_error, "PermissionDenied", 1, true) ~= nil)
    , "@zlua/zostd_net_test.lua");

    try std.testing.expectEqualStrings("ping", host.net_written.items);
}

test "zostd.net reports unconfigured operations without raising" {
    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.openSafeLibs();
    lua_runtime.installZostd();

    try lua_runtime.run(
        \\local handle, handle_error = zostd.net.connect("example.com", 80)
        \\assert(handle == nil)
        \\assert(string.find(handle_error, "not configured", 1, true) ~= nil)
        \\
        \\local closed, close_error = zostd.net.close(1)
        \\assert(closed == nil)
        \\assert(string.find(close_error, "not configured", 1, true) ~= nil)
    , "@zlua/zostd_net_unconfigured_test.lua");
}

test "built-in plugin:// backend reads and writes inside the plugin root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.writeFile(io, .{
        .sub_path = "hello.txt",
        .data = "hello from disk",
    });

    const root = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path[0..]},
    );
    defer std.testing.allocator.free(root);

    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.setPluginId("disk-plugin");
    lua_runtime.setPluginRoot(root);
    lua_runtime.openSafeLibs();
    lua_runtime.installZostd();

    try lua_runtime.run(
        \\assert(zostd.plugin_id() == "disk-plugin")
        \\
        \\local contents = assert(zostd.read_file("plugin://hello.txt"))
        \\assert(contents == "hello from disk")
        \\
        \\assert(zostd.write_file("plugin://out.txt", "written by lua") == true)
        \\
        \\local escape, path_error = zostd.read_file("plugin://../escape.txt")
        \\assert(escape == nil)
        \\assert(string.find(path_error, "InvalidPath", 1, true) ~= nil)
        \\
        \\local command, command_error = zostd.server_command("say hello")
        \\assert(command == nil)
        \\assert(string.find(command_error, "not configured", 1, true) ~= nil)
    , "@zlua/plugin_root_test.lua");

    const written = try tmp.dir.readFileAlloc(
        io,
        "out.txt",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("written by lua", written);
}

test "zostd event callbacks receive event name and payload" {
    var host = MockHost{ .allocator = std.testing.allocator };
    defer host.deinit();

    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.setHost(.{
        .context = &host,
        .log = MockHost.log,
    });
    lua_runtime.openSafeLibs();
    lua_runtime.installZostd();

    try lua_runtime.run(
        \\zostd.on("pause", function(event, payload)
        \\    zostd.log("first:" .. event .. ":" .. tostring(payload))
        \\end)
        \\zostd.on("pause", function(event, payload)
        \\    zostd.log("second:" .. event .. ":" .. tostring(payload))
        \\end)
        \\zostd.on("custom", function(event, payload)
        \\    error("callback failure")
        \\end)
    , "@zlua/zostd_events_test.lua");

    lua_runtime.dispatchEvent("pause", "now");
    lua_runtime.dispatchEvent("custom", null);
    lua_runtime.dispatchEvent("missing", null);

    try std.testing.expect(std.mem.indexOf(
        u8,
        host.log_buffer.items,
        "first:pause:now",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host.log_buffer.items,
        "second:pause:now",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host.log_buffer.items,
        "zostd.on(custom) failed",
    ) != null);
}

test "clientCommand payload reaches Lua and client_print replies" {
    var host = MockHost{ .allocator = std.testing.allocator };
    defer host.deinit();

    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.setHost(.{
        .context = &host,
        .client_print = MockHost.clientPrint,
    });
    lua_runtime.openSafeLibs();
    lua_runtime.installZostd();

    try lua_runtime.run(
        \\zostd.on("clientCommand", function(event, payload)
        \\    local command = tostring(payload or ""):match("^%s*(.-)%s*$"):lower()
        \\    if command == "zlua ping" then
        \\        assert(zostd.client_print("Pong!") == true)
        \\    end
        \\end)
    , "@zlua/zostd_client_command_test.lua");

    lua_runtime.dispatchEvent("clientCommand", "zlua ping");
    try std.testing.expectEqualStrings("Pong!", host.client_message.items);

    lua_runtime.dispatchEvent("clientCommand", "zlua nope");
    try std.testing.expectEqualStrings("Pong!", host.client_message.items);
}

test "runtime reports syntax and runtime errors on the Lua stack" {
    var lua_runtime = try Runtime.init(std.testing.allocator);
    defer lua_runtime.deinit();

    lua_runtime.openSafeLibs();
    lua_runtime.installZostd();

    try std.testing.expectError(
        error.InvalidSyntax,
        lua_runtime.run("local =", "@zlua/invalid_syntax.lua"),
    );
    const syntax_message = try lua_runtime.lua.toString(-1);
    try std.testing.expect(std.mem.span(syntax_message).len != 0);
    lua_runtime.lua.pop(1);

    try std.testing.expectError(
        error.Runtime,
        lua_runtime.run("error('boom')", "@zlua/runtime_error.lua"),
    );
    const runtime_message = try lua_runtime.lua.toString(-1);
    try std.testing.expect(std.mem.indexOf(
        u8,
        std.mem.span(runtime_message),
        "boom",
    ) != null);
    lua_runtime.lua.pop(1);

    try std.testing.expectEqual(@as(i32, 0), lua_runtime.lua.getTop());
}
