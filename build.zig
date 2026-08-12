const std = @import("std");

const Compile = std.Build.Step.Compile;
const Allocator = std.mem.Allocator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .abi = .gnux32,
            .os_tag = .linux,
            .cpu_arch = .x86,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "zorcerer",
        .linkage = .dynamic,
        .root_module = b.addModule("zorcerer", .{
            .root_source_file = b.path("src/entrypoint.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        }),
    });

    lib.out_filename = "zorcerer.so";
    b.installArtifact(lib);
}
