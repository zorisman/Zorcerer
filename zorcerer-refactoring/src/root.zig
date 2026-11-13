const std = @import("std");

/// ABI contract between the plugin manager
/// (src/core/plugin/PluginManager.zig) and every plugin it loads
/// (see src/core/plugin/PluginContext.zig and
/// example-plugins/hello/hello_plugin.zig). Both sides import the same
/// `plugin-context` build module so their declarations stay identical.
pub const abi = @import("plugin-context");
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
    /// Wrappers for std.Io and Source filesystems.
    pub const filesystem = @import("io/file_system.zig");
};

pub const codegen = struct {
    pub const indexes = @import("codegen_generated/engine_indexes.zig");
};

/// Core modules re-exported so files in this module can use `zroot` instead of
/// parent-relative import paths.
pub const core = struct {
    pub const EngineClients = @import("core/EngineClients.zig");
    pub const EngineCommands = @import("core/EngineCommands.zig");
    pub const EngineFilesystem = @import("core/EngineFilesystem.zig");
    pub const Entrypoint = @import("core/Entrypoint.zig");
    pub const FileService = @import("core/FileService.zig");
    pub const ForkProcess = @import("core/ForkProcess.zig");
    pub const GameQueries = @import("core/GameQueries.zig");
    pub const JsonRpc = @import("core/JsonRpc.zig");
    pub const LuaHost = @import("core/LuaHost.zig");
    pub const NetworkService = @import("core/NetworkService.zig");
    pub const PluginManager = @import("core/plugin/PluginManager.zig");
    pub const Vsp = @import("core/Vsp.zig");
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

test "src/core/FileService.zig" {
    std.testing.refAllDecls(@import("core/FileService.zig"));
}

test "src/core/EngineFilesystem.zig" {
    std.testing.refAllDecls(@import("core/EngineFilesystem.zig"));
}

test "src/core/EngineClients.zig" {
    std.testing.refAllDecls(@import("core/EngineClients.zig"));
}

test "src/core/NetworkService.zig" {
    std.testing.refAllDecls(@import("core/NetworkService.zig"));
}
