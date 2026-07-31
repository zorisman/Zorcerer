const std = @import("std");
const builtin = @import("builtin");

var is_loaded = false;

/// Fake CreateInterface method, which SDK tries to call
export fn CreateInterface(name: [*c]const c_char, return_code: [*c]c_int) callconv(.c) usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var root = std.Io.Dir.cwd();
    var buffer: [1024]u8 = undefined;

    const dir = root.openDir(io, "./", .{}) catch |err| {
        std.debug.print("openDir error: {s}\n", .{@errorName(err)});
        return 0;
    };

    const symbols = dir.realPath(io, &buffer) catch |err| {
        std.debug.print("root.realPath error: {s}\n", .{@errorName(err)});
        return 0;
    };

    const server_dll_path = GameRoot.generateDllPath();
    const clean_buffer = buffer[0..symbols];
    const path: []const u8 = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{clean_buffer, server_dll_path}) catch |err| {
        std.debug.print("Path format error: {s}\n", .{@errorName(err)});
        return 0;
    };

    startInterception(path) catch |err| {
        std.debug.print("startInterception error: {s}\n", .{@errorName(err)});
        return 0;
    };

    var dll = std.DynLib.open(path) catch |err| {
        std.debug.print("dynLib opening error: {s}\n", .{@errorName(err)});
        return 0;
    };
    defer dll.close();

    const real_func = dll.lookup(*const @TypeOf(CreateInterface), "CreateInterface") orelse return 0;
    return real_func(name, return_code);
}

/// This is the "entry point" of Zorcerer.
fn startInterception(dll_path: []const u8) !void {
    if (!is_loaded) {
        is_loaded = true;
        std.debug.print("DLL: {s}\n", .{dll_path});
    }
}

/// Source SDK root folder
const GameRoot = struct {
    /// Generates path to server_serv DLL
    inline fn generateDllPath() []const u8 {
        comptime {
            const target = builtin.target;
            const target_os = target.os.tag;

            const dll_format: []const u8 = switch (target_os) {
                .windows => "dll",
                .linux => "so",
                else => @compileError("This OS is not supported"),
            };

            const path = std.fmt.comptimePrint("tf/bin/server_srv.{s}", .{dll_format}).*;
            return path[0..(@sizeOf(@TypeOf(path)) - 1)];
        }
    }
};
