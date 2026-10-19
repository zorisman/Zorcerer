const std = @import("std");
const index_analyzer = @import("src/zig_build_utils/build_index_analyzer.zig");
const codegen = @import("src/zig_build_utils/EngineIndexesGenerator.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .abi = .gnu,
            .os_tag = .linux,
            .cpu_arch = .x86_64
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    index_analyzer.addIndexAnalyzer(b);

    const toml_cfg = @embedFile("./engine.toml");
    const engine_indexes_generated = try codegen.generate(b.allocator, toml_cfg);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), b.graph.io, .{
        .sub_path = b.path("src/codegen_generated/engine_indexes.zig").getPath(b),
        .data = engine_indexes_generated,
    });

    const hooks = b.createModule(.{
        .root_source_file = b.path("extern/zig-hooks/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .link_libc = true,
    });

    const zroot = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });

    const toml = b.createModule(.{
        .root_source_file = b.path("extern/zig-toml/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true
    });

    const zorcerer = b.addLibrary(.{
        .name = "zorcerer",
        .linkage = .dynamic,
        .root_module = b.addModule("zorcerer", .{
            .root_source_file = b.path("src/Entrypoint.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        }),
    });

    zorcerer.root_module.addImport("hooks", hooks);
    zorcerer.root_module.addImport("toml", toml);
    zorcerer.out_filename = "zorcerer.so";
    b.installArtifact(zorcerer);

    const zig_commands = b.addLibrary(.{
        .name = "zorcerer-commands-plugin",
        .linkage = .dynamic,
        .root_module = b.addModule("zorcerer-commands", .{
            .root_source_file = b.path("example-plugins/zorcerer-command-plugin/ZorcererCommandPlugin.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        }),
    });

    zig_commands.root_module.addImport("hooks", hooks);
    zig_commands.root_module.addImport("zroot", zroot);
    zig_commands.out_filename = "zorcerer-commands.so";
    b.installArtifact(zig_commands);
}
