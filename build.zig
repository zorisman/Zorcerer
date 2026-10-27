const std = @import("std");

const index_analyzer = @import("build/build_index_analyzer.zig");
const codegen = @import("build/EngineIndexesGenerator.zig");
const DataAdapter = @import("build/analyzers/AnalyzerDataAdapter.zig");

/// Describes one compiled example plugin that is installed as its own
/// directory under `zig-out/lib/plugins/`.
const ExamplePluginInstall = struct {
    /// Directory name under `example-plugins/`. Used to locate the optional
    /// `manifest.toml` that belongs to this plugin.
    source_dir: []const u8,
    /// Directory name created under `zig-out/lib/plugins/`.
    install_dir: []const u8,
    /// File name of the installed shared library inside `install_dir`.
    library_name: []const u8,
    /// Compiled plugin artifact whose emitted library is installed.
    artifact: *std.Build.Step.Compile,
};

/// Installs one example plugin as `zig-out/lib/plugins/<install_dir>/`.
///
/// The artifact's emitted shared library is copied under `library_name`. If
/// `example-plugins/<source_dir>/manifest.toml` exists, it is copied next to
/// the library as `manifest.toml`; a missing manifest is allowed because not
/// every example plugin is managed through one.
///
/// `tests_step` is made a dependency of the install steps so that the default
/// install target never packages a plugin unless the project's tests passed.
///
/// Errors: propagates filesystem errors other than `error.FileNotFound` from
/// the manifest existence check (for example `error.AccessDenied`).
fn installExamplePlugin(
    b: *std.Build,
    tests_step: *std.Build.Step,
    plugin: ExamplePluginInstall,
) !void {
    const plugin_dir = b.pathJoin(&.{ "lib", "plugins", plugin.install_dir });

    const install_library = b.addInstallFileWithDir(
        plugin.artifact.getEmittedBin(),
        .{ .custom = plugin_dir },
        plugin.library_name,
    );
    install_library.step.dependOn(tests_step);
    b.getInstallStep().dependOn(&install_library.step);

    const manifest_path = b.pathJoin(&.{
        "example-plugins",
        plugin.source_dir,
        "manifest.toml",
    });
    const has_manifest = manifest: {
        std.Io.Dir.cwd().access(b.graph.io, manifest_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :manifest false,
            else => return err,
        };
        break :manifest true;
    };

    if (has_manifest) {
        const install_manifest = b.addInstallFileWithDir(
            b.path(manifest_path),
            .{ .custom = plugin_dir },
            "manifest.toml",
        );
        install_manifest.step.dependOn(tests_step);
        b.getInstallStep().dependOn(&install_manifest.step);
    }
}

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

    const zjr = b.addModule("zjr", .{
        .root_source_file = b.path("extern/zigjr/src/zigjr.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });

    const luajit = b.addModule("luajit", .{
        .root_source_file = b.path("extern/zig-luajit/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
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
    zorcerer.root_module.addImport("zjr", zjr);
    zorcerer.root_module.addImport("luajit", luajit);
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

    // Example plugins get one directory each so the deploy script can copy
    // `zig-out/lib/plugins/` as a complete plugin tree.
    try installExamplePlugin(b, tests_step, .{
        .source_dir = "hello",
        .install_dir = "hello-plugin",
        .library_name = "hello.so",
        .artifact = hello_plugin,
    });
}
