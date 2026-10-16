const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .abi = .gnu,
            .os_tag = .linux,
            .cpu_arch = .x86_64
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const hooks = b.createModule(.{
        .root_source_file = b.path("zig-hooks/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "zorcerer",
        .linkage = .dynamic,
        .root_module = b.addModule("zorcerer", .{
            .root_source_file = b.path("src/SourcePlugin.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        }),
    });

    lib.root_module.addImport("hooks", hooks);
    lib.out_filename = "zorcerer.so";
    b.installArtifact(lib);
}
