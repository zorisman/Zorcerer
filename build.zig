const std = @import("std");
const index_analyzer = @import("src/zig_build_utils/build_index_analyzer.zig");
const codegen = @import("src/zig_build_utils/EngineIndexesGenerator.zig");
const DataAdapter = @import("src/analyzers/AnalyzerDataAdapter.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .abi = .gnu,
            .os_tag = .linux,
            .cpu_arch = .x86_64
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const io = b.graph.io;

    const hooks = b.addModule("hooks", .{
        .root_source_file = b.path("extern/zig-hooks/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .link_libc = true,
    });

    const toml = b.addModule("toml", .{
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

    index_analyzer.addIndexAnalyzer(b);

    const toml_path = b.path("config/raw_data.toml").getPath(b);
    const analyzer_path = b.path("zig-out/bin/vtable-index-analyzer").getPath(b);
    const toml_output_path = b.path("config/engine_data.toml").getPath(b);

    var args = try DataAdapter.prepareAnalyzerArgs(io, toml_path);
    defer args.deinit();
    var data = try DataAdapter.beginAnalyze(io, analyzer_path, &args);
    defer data.deinit();
    try DataAdapter.intoToml(io, toml_output_path, &data);

    b.installArtifact(zorcerer);
}
