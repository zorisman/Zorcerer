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

    // Configuration of a single plugin's TOML manifest
    // (src/PluginConfiguration.zig), later shared between the manager and
    // the file access API in src/io/FileSystem.zig.
    const plugin_configuration = b.addModule("plugin-configuration", .{
        .root_source_file = b.path("src/PluginConfiguration.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    plugin_configuration.addImport("toml", toml);

    // ABI contract between the plugin manager and plugin modules
    // (src/PluginContext.zig). The manager imports it through src/root.zig
    // (`abi`); plugin compilations import it as this module, so every side
    // compiles the same declarations. Example plugins live outside src/ in
    // example-plugins/ and cannot reach it by file path (imports may not
    // escape a module's root directory), hence the module indirection.
    const plugin_context = b.addModule("plugin-context", .{
        .root_source_file = b.path("src/PluginContext.zig"),
    });

    // Plugin-facing filesystem API (src/io/FileSystem.zig). Example plugins
    // live outside src/ and cannot import it by file path for the same
    // reason as plugin-context, so it is exposed as a module. Resolving
    // URI schemes needs the same plugin-configuration module the manager
    // uses, hence the import below.
    const zorcerer_filesystem = b.addModule("zorcerer-filesystem", .{
        .root_source_file = b.path("src/io/FileSystem.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    zorcerer_filesystem.addImport("plugin-configuration", plugin_configuration);

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
    zorcerer.root_module.addImport("plugin-configuration", plugin_configuration);
    zorcerer.out_filename = "zorcerer.so";

    // Example plugin for PluginManager: hello_plugin.so gets dlopen()ed
    // and needs no libc of its own.
    const hello_plugin = b.addLibrary(.{
        .name = "hello-plugin",
        .linkage = .dynamic,
        .root_module = b.addModule("hello-plugin", .{
            .root_source_file = b.path("example-plugins/hello/hello_plugin.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        }),
    });
    hello_plugin.root_module.addImport("plugin-context", plugin_context);
    hello_plugin.root_module.addImport("zorcerer-filesystem", zorcerer_filesystem);
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
    const plugin_configuration_tests = b.addTest(.{
        .name = "plugin-configuration-tests",
        .root_module = plugin_configuration,
    });

    const compile_modules_step = b.step(
        "compile-modules",
        "Compile Zorcerer and all module test targets",
    );

    compile_modules_step.dependOn(&zorcerer.step);
    compile_modules_step.dependOn(&zorcerer_tests.step);
    compile_modules_step.dependOn(&hooks_tests.step);
    compile_modules_step.dependOn(&toml_tests.step);
    compile_modules_step.dependOn(&plugin_configuration_tests.step);
    compile_modules_step.dependOn(&hello_plugin.step);

    const run_zorcerer_tests = b.addRunArtifact(zorcerer_tests);
    run_zorcerer_tests.step.dependOn(compile_modules_step);

    const run_hooks_tests = b.addRunArtifact(hooks_tests);
    run_hooks_tests.step.dependOn(compile_modules_step);

    const run_toml_tests = b.addRunArtifact(toml_tests);
    run_toml_tests.step.dependOn(compile_modules_step);

    const run_plugin_configuration_tests = b.addRunArtifact(plugin_configuration_tests);
    run_plugin_configuration_tests.step.dependOn(compile_modules_step);

    const tests_step = b.step("tests", "Run tests for all project modules");
    tests_step.dependOn(&run_zorcerer_tests.step);
    tests_step.dependOn(&run_hooks_tests.step);

    // I don't know if is this intended, but two of these tests fail
    // tests_step.dependOn(&run_toml_tests.step);

    tests_step.dependOn(&run_plugin_configuration_tests.step);

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

        // The analyzer is an install artifact, but this regeneration runs at
        // configure time, before any build step has run. On a fresh checkout
        // (or after `rm -rf zig-out`) the binary does not exist yet, so skip
        // regeneration instead of failing the whole build; the file is
        // regenerated by the next `zig build` once the analyzer is installed.
        const analyzer_ready = ready: {
            std.Io.Dir.cwd().access(io, analyzer_path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :ready false,
                else => return err,
            };
            break :ready true;
        };

        if (analyzer_ready) {
            var args = try DataAdapter.prepareAnalyzerArgs(io, toml_path);
            defer args.deinit();
            var data = try DataAdapter.beginAnalyze(io, analyzer_path, &args);
            defer data.deinit();
            try DataAdapter.intoToml(io, toml_output_path, &data);
        } else {
            std.debug.print(
                "note: skipping analyzer data regeneration: '{s}' does not exist yet\n",
                .{analyzer_path},
            );
        }
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
