const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

pub var is_loaded = false;

pub const File = struct {
    /// Generates relative path to server_serv DLL, like this: "tf/bin/(your_os)/server_srv.(dll|so)"
    pub const relative_path: []const u8 = switch (builtin.target.os.tag) {
        .windows => "tf/bin/win32/server_srv.dll",
        .linux => "tf/bin/linux64/server_srv.so",
        else => @compileError("This OS is not supported")
    };

    /// Generates absolute path to server_serv DLL
    pub fn getAbsolutePath(io: Io, allocator: Allocator, root: Dir) ![]const u8 {

        var buffer: [256]u8 = undefined;
        const root_path_len = try root.realPath(io, &buffer);
        const path: []const u8 = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ buffer[0..root_path_len], relative_path });

        return path;
    }
};
