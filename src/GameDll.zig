const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

pub var is_loaded = false;

pub const File = struct {
    /// Generates path to server_serv DLL
    inline fn getRelativePath() []const u8 {
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

    pub fn getAbsolutePath(io: Io, allocator: Allocator, root: Dir) ![]const u8 {
        const server_dll_path = getRelativePath();

        var buffer: [256]u8 = undefined;
        const root_path_len = try root.realPath(io, &buffer);
        const path: []const u8 = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ buffer[0..root_path_len], server_dll_path });

        return path;
    }
};
