const std = @import("std");
const builtin = @import("builtin");

/// Fake CreateInterface method, which SDK tries to call
export fn CreateInterface(name: [*c]const c_char, return_code: [*c]c_int) callconv(.c) usize {
    const server_dll_path = GameRoot.generateDllPath();
    startInterlop();

    var dll = std.DynLib.open(server_dll_path) catch return 0;
    defer dll.close();

    const real_func = dll.lookup(*const @TypeOf(CreateInterface), "CreateInterface") orelse return 0;
    return real_func(name, return_code);
}

/// This is the "entry point" of Zorcerer.
fn startInterlop() void {
    std.debug.print("Interlop success!", .{});
}

/// Source SDK root folder
const GameRoot = struct {
    /// Generates path to server_serv.so DLL
    inline fn generateDllPath() []const u8 {
        comptime {
            const target = builtin.target;
            const target_os = target.os.tag;
            const target_bit_width = target.ptrBitWidth();

            const dll_format = switch (target_os) {
                .windows => "dll",
                .linux => "so",
                else => @compileError("This OS is not supported"),
            };

            const path = std.fmt.comptimePrint("tf/bin/{s}{d}/server_serv.{s}", .{@tagName(target_os), target_bit_width, dll_format}).*;
            return path[0..@sizeOf(@TypeOf(path))];
        }
    }
};
