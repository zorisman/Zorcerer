const std = @import("std");

/// ABI contract between the plugin manager (src/PluginManager.zig) and
/// every plugin it loads (see src/PluginContext.zig and
/// example-plugins/hello/hello_plugin.zig; plugin compilations get the
/// same declarations through the `plugin-context` build module).
pub const abi = @import("core/PluginContext.zig");
pub const Ipc = @import("core/Ipc.zig");

// Force the VSP entrypoint into the library: its exported `CreateInterface`
// symbol is not referenced by any other declaration, so a lazy import would
// leave it out of the shared object.
comptime {
    _ = @import("core/Entrypoint.zig");
}

/// Blocking operations
pub const io = struct {
    /// Minimal Source SDK console logger for the plugin manager's own
    /// messages (src/io/Log.zig).
    pub const Log = @import("io/Log.zig");
    /// Wrappers for std.Io and Source filesystems
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
test "src/analyzers/VTableResolver.zig" {
    std.testing.refAllDecls(@import("analyzers/VTableResolver.zig"));
}

// Compile-checks and unit-tests src/io/FileSystem.zig. Nothing in
// production code references the filesystem layer yet, so this branch of
// the import graph is the only thing keeping it under the build's
// purview; it must keep compiling and testing against the real toolchain
// even before hosting code starts calling it.
test "src/io/FileSystem.zig" {
    std.testing.refAllDecls(@import("io/file_system.zig"));
}

test "src/core/Entrypoint.zig" {
    std.testing.refAllDecls(tests.entrypoint_tests);
}

test "src/core/Ipc.zig" {
    std.testing.refAllDecls(tests.ipc_tests);
}
