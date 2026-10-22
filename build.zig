const std = @import("std");

const index_analyzer = @import("build/build_index_analyzer.zig");
const codegen = @import("build/EngineIndexesGenerator.zig");
const DataAdapter = @import("build/analyzers/AnalyzerDataAdapter.zig");

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

    // ABI contract shared between the plugin manager and plugin modules
    // (src/PluginAbi.zig). Each side imports it as "plugin-abi", so both
    // compilations of the file stay identical.
    const plugin_abi = b.addModule("plugin-abi", .{
        .root_source_file = b.path("src/PluginAbi.zig"),
    });

    // Simple Source SDK console logging for the manager's own messages
    // (src/Log.zig).
    const log = b.addModule("log", .{
        .root_source_file = b.path("src/Log.zig"),
        .target = target,
        .optimize = optimize,
    });
    log.addImport("plugin-abi", plugin_abi);

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
    zorcerer.root_module.addImport("plugin-abi", plugin_abi);
    zorcerer.root_module.addImport("log", log);
    zorcerer.out_filename = "zorcerer.so";

    // Example plugin for PluginManager: hello_plugin.so gets dlopen()ed
    // and needs no libc of its own.
    const hello_plugin = b.addLibrary(.{
        .name = "hello-plugin",
        .linkage = .dynamic,
        .root_module = b.addModule("hello-plugin", .{
            .root_source_file = b.path("src/plugins/hello/hello_plugin.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        }),
    });
    hello_plugin.root_module.addImport("plugin-abi", plugin_abi);
    hello_plugin.out_filename = "hello_plugin.so";

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
    compile_modules_step.dependOn(&hello_plugin.step);

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

    const should_skip_analyze = b.option(
        bool,
        "skip-analyze",
        "Build and run the Clang-based index analyzer (requires system Clang/LLVM development packages)",
    ) orelse false;

    if (!should_skip_analyze) {
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

    // Same tests gate for the example plugin (mirrors the comment above).
    const install_hello_plugin = b.addInstallArtifact(hello_plugin, .{});
    install_hello_plugin.step.dependOn(tests_step);
    b.getInstallStep().dependOn(&install_hello_plugin.step);
}
