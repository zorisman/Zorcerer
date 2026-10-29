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

    fn deinit(self: *MockHost) void {
        self.log_buffer.deinit(self.allocator);
        self.written_path.deinit(self.allocator);
        self.written_data.deinit(self.allocator);
        self.command.deinit(self.allocator);
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
};

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
    , "@zlua/zostd_host_test.lua");

    try std.testing.expectEqualStrings("hello from lua", host.log_buffer.items);
    try std.testing.expectEqualStrings("plugin://out.txt", host.written_path.items);
    try std.testing.expectEqualStrings("payload", host.written_data.items);
    try std.testing.expectEqualStrings("say hello", host.command.items);
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
