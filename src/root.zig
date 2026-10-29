const std = @import("std");

/// ABI contract between the plugin manager (src/PluginManager.zig) and
/// every plugin it loads (see src/PluginContext.zig and
/// example-plugins/hello/hello_plugin.zig; plugin compilations get the
/// same declarations through the `plugin-context` build module).
pub const abi = @import("PluginContext.zig");

/// Minimal Source SDK console logger for the plugin manager's own
/// messages (src/io/Log.zig).
pub const Ipc = @import("core/Ipc.zig");

pub const io = struct {
    pub const Log = @import("io/Log.zig");
    pub const fs = @import("io/file_system.zig");
};

pub const codegen = struct {
    pub const indexes = @import("codegen_generated/engine_indexes.zig");
};

const tests = struct {
    const ipc_tests = @import("tests/ipc_tests.zig");
    const entrypoint_tests = @import("tests/entrypoint_tests.zig");
};

// Compile-checks and unit-tests src/analyzers/VTableResolver.zig. Nothing
// in production code references the resolver yet, so this branch of the
// import graph is the only thing keeping it under the build's purview; it
// must keep compiling and testing against the real toolchain even before
// a hook-install site starts calling it.
test "src/analyzers/VTableResolver.zig compiles and passes its unit tests" {
    std.testing.refAllDecls(@import("analyzers/VTableResolver.zig"));
}

// Compile-checks and unit-tests src/io/FileSystem.zig. Nothing in
// production code references the filesystem layer yet, so this branch of
// the import graph is the only thing keeping it under the build's
// purview; it must keep compiling and testing against the real toolchain
// even before hosting code starts calling it.
test "src/io/FileSystem.zig compiles and passes its unit tests" {
    std.testing.refAllDecls(@import("io/file_system.zig"));
}
