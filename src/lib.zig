const std = @import("std");
const builtin = @import("builtin");
const GameDll = @import("GameDll.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

/// Fake CreateInterface method, which SDK tries to call
export fn CreateInterface(name: usize, return_code: usize) callconv(.c) usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var root = std.Io.Dir.cwd();

    const dir = root.openDir(io, "./", .{}) catch |err| {
        std.debug.print("openDir error: {s}\n", .{@errorName(err)});
        return 0;
    };

    startInterception() catch |err| {
        std.debug.print("startInterception error: {s}\n", .{@errorName(err)});
        return 0;
    };

    const dll_path = GameDll.File.getAbsolutePath(io, std.heap.page_allocator, dir) catch |err| {
        std.debug.print("startInterception error: {s}\n", .{@errorName(err)});
        return 0;
    };
    var dll = std.DynLib.open(dll_path) catch |err| {
        std.debug.print("dynLib opening error: {s}\n", .{@errorName(err)});
        return 0;
    };
    defer dll.close();

    const real_func = dll.lookup(*const @TypeOf(CreateInterface), "CreateInterface") orelse {
        std.debug.print("Failed to find function in DLL", .{});
        return 0;
    };

    const real_val = real_func(name, return_code);
    return real_val;
}

/// This is the "entry point" of Zorcerer.
fn startInterception() !void {
    if (!GameDll.is_loaded) {
        GameDll.is_loaded = true;

    }
}
