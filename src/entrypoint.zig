const std = @import("std");

export fn Greet() callconv(.c) void {
    std.debug.print("Hello from Zig!\n", .{});
}
