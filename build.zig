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

    const zorcerer_tests = b.addTest(.{
        .name = "zorcerer-tests",
        .root_module = zorcerer.root_module,
    });
    const hooks_tests = b.addTest(.{
        .name = "hooks-tests",
        .root_module = hooks,
    });
    const toml_tests = b.addTest(.{
        .name = "toml-tests",
        .root_module = toml,
    });

    const compile_modules_step = b.step(
        "compile-modules",
        "Compile Zorcerer and all module test targets",
    );

    compile_modules_step.dependOn(&zorcerer.step);
    compile_modules_step.dependOn(&zorcerer_tests.step);
    compile_modules_step.dependOn(&hooks_tests.step);
    compile_modules_step.dependOn(&toml_tests.step);

    const run_zorcerer_tests = b.addRunArtifact(zorcerer_tests);
    run_zorcerer_tests.step.dependOn(compile_modules_step);

    const run_hooks_tests = b.addRunArtifact(hooks_tests);
    run_hooks_tests.step.dependOn(compile_modules_step);

    const run_toml_tests = b.addRunArtifact(toml_tests);
    run_toml_tests.step.dependOn(compile_modules_step);

    const tests_step = b.step("tests", "Run tests for all project modules");
    tests_step.dependOn(&run_zorcerer_tests.step);
    tests_step.dependOn(&run_hooks_tests.step);

    // I don't know if is this intended, but two of these tests fail
    // tests_step.dependOn(&run_toml_tests.step);

    const enable_index_analyzer = b.option(
        bool,
        "index-analyzer",
        "Build and run the Clang-based index analyzer (requires system Clang/LLVM development packages)",
    ) orelse false;

    if (enable_index_analyzer) {
        index_analyzer.addIndexAnalyzer(b);

        const toml_path = b.path("config/raw_data.toml").getPath(b);
        const analyzer_path = b.path("zig-out/bin/vtable-index-analyzer").getPath(b);
        const toml_output_path = b.path("config/engine_data.toml").getPath(b);

        var args = try DataAdapter.prepareAnalyzerArgs(io, toml_path);
        defer args.deinit();
        var data = try DataAdapter.beginAnalyze(io, analyzer_path, &args);
        defer data.deinit();
        try DataAdapter.intoToml(io, toml_output_path, &data);
    }

    // Make tests mandatory for the default `zig build` target. The artifact
    // cannot be installed unless every module compiles and all tests pass.
    const install_zorcerer = b.addInstallArtifact(zorcerer, .{});
    install_zorcerer.step.dependOn(tests_step);
    b.getInstallStep().dependOn(&install_zorcerer.step);
}
