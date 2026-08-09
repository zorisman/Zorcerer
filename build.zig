const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "server",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off
        }),
    });

    lib.root_module.addCSourceFile(.{
        .file = b.path("src/interceptor.c"),
        .language = .c
    });
    lib.out_filename = "server.so";

    b.installArtifact(lib);
}
