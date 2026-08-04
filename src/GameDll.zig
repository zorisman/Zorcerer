const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

pub const DllFile = struct {
    const relative_path: []const u8 = switch (builtin.target.os.tag) {
        .windows => "tf/bin/win32/server_srv.dll",
        .linux => "tf/bin/linux64/server_srv.so",
        else => @compileError("This OS is not supported")
    };
    var absolute_path: []const u8 = undefined;

    /// Returns relative path to server_serv DLL, like this: "tf/bin/(your_os)/server_srv.(dll|so)"
    pub inline fn getRelativePath() []const u8 {
        return relative_path;
    }

    /// Generates absolute path to server_serv DLL
    pub fn getAbsolutePath(io: Io, allocator: Allocator, root: Dir) ![]const u8 {
        if (absolute_path.len <= 0) {
            var buffer: [256]u8 = undefined;
            const root_path_len = try root.realPath(io, &buffer);
            absolute_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ buffer[0..root_path_len], relative_path });
        }

        return absolute_path;
    }
};
