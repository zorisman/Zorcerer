const std = @import("std");

/// ABI contract between the plugin manager
/// (src/core/plugin/PluginManager.zig) and every plugin it loads
/// (see src/core/plugin/PluginContext.zig and
/// example-plugins/hello/hello_plugin.zig). Both sides import the same
/// `plugin-context` build module so their declarations stay identical.
pub const abi = @import("plugin-context");

/// IPC transport and message-schema modules (src/ipc). Each concern has
/// exactly one owning module; files in this module re-export them so callers
/// can use `zroot` instead of path-relative imports.
pub const ipc = struct {
    /// Raw byte transport over the IPC socket descriptor.
    pub const DescriptorIo = @import("ipc/DescriptorIo.zig");
    /// Frame encoding for the IPC channel.
    pub const Frame = @import("ipc/Frame.zig");
    /// Fixed JSON-RPC request IDs shared by both endpoints.
    pub const IdentifierRegistry = @import("ipc/IdentifierRegistry.zig");
    /// Parsed JSON-RPC responses.
    pub const Response = @import("ipc/Response.zig");
    /// JSON-RPC response sending.
    pub const Sender = @import("ipc/Sender.zig");
    /// Operation notifications (stderr/ready) and their requests.
    pub const Operation = @import("ipc/Operation.zig");
    pub const Request = @import("ipc/Request.zig");
    /// VSP callback event schema.
    pub const Event = @import("ipc/Event.zig");
    /// Game-query schema and results.
    pub const Query = @import("ipc/Query.zig");
    pub const QueryResult = @import("ipc/query_types/QueryResult.zig");
    /// Engine-side game-query handler; the wire schema lives in `Query`.
    pub const query_types = struct {
        pub const GameQueries = @import("ipc/query_types/GameQueries.zig");
    };
    /// Server-command, client-print, and shutdown schemas.
    pub const ServerCommand = @import("ipc/ServerCommand.zig");
    pub const ClientPrint = @import("ipc/ClientPrint.zig");
    pub const Shutdown = @import("ipc/Shutdown.zig");
    /// Forked child process management.
    pub const ForkProcess = @import("ipc/ForkProcess.zig");
    /// Engine-side JSON-RPC dispatch listener.
    pub const JsonRpc = @import("ipc/JsonRpc.zig");
};

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
    /// File-operation wire schemas exchanged over the IPC channel
    /// (src/io/fs). The io domain owns the `file.*` message data; the
    /// transport lives in `ipc`.
    pub const fs = struct {
        pub const FileOperation = @import("io/fs/FileOperation.zig");
        pub const FileRequest = @import("io/fs/FileRequest.zig");
        pub const FileResult = @import("io/fs/FileResult.zig");
    };
};

pub const codegen = struct {
    pub const indexes = @import("codegen_generated/engine_indexes.zig");
};

/// Core modules re-exported so files in this module can use `zroot` instead of
/// parent-relative import paths.
pub const core = struct {
    pub const EngineClients = @import("core/engine/EngineClients.zig");
    pub const EngineCommands = @import("core/engine/EngineCommands.zig");
    pub const EngineFilesystem = @import("core/engine/EngineFilesystem.zig");
    pub const Entrypoint = @import("core/Entrypoint.zig");
    pub const FileService = @import("core/FileService.zig");
    pub const LuaHost = @import("core/LuaHost.zig");
    pub const NetworkService = @import("core/NetworkService.zig");
    pub const PluginManager = @import("core/plugin/PluginManager.zig");
    pub const QueryClient = @import("core/plugin/QueryClient.zig");
};

/// Source SDK ABI declarations: engine interface layouts, generated indexes,
/// and the VSP vtable contract. Nothing here owns process or IPC state.
pub const ssdk = struct {
    /// Generated interface version strings and vtable slots.
    pub const indexes = @import("codegen_generated/engine_indexes.zig");
    pub const Iface = @import("ssdk/types/Iface.zig").Iface;
    pub const PluginStates = @import("ssdk/types/PluginStates.zig").PluginStates;
    pub const ClientCommand = @import("ssdk/types/ClientCommand.zig").ClientCommand;
    pub const ConCommandBase = @import("ssdk/types/ConCommandBase.zig").ConCommandBase;
    pub const ConVar = @import("ssdk/types/ConVar.zig").ConVar;
    pub const PlayerInfo = @import("ssdk/types/PlayerInfo.zig").PlayerInfo;
    pub const Vsp = @import("ssdk/Vsp.zig");
    pub const Vtable = @import("ssdk/Vtable.zig");
    pub const EngineAbi = @import("ssdk/EngineAbi.zig").EngineAbi;
    pub const CvarAbi = @import("ssdk/CvarAbi.zig").CvarAbi;
    pub const cvar_never_as_string = @import("ssdk/CvarAbi.zig").cvar_never_as_string;
    pub const VspHost = @import("ssdk/VspHost.zig");
};

const tests = struct {
    const ipc_tests = @import("tests/ipc_tests.zig");
    const entrypoint_tests = @import("tests/entrypoint_tests.zig");
    const ssdk_tests = @import("tests/ssdk_tests.zig");
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

test "src/ipc modules" {
    std.testing.refAllDecls(tests.ipc_tests);
}

test "src/tests/ssdk_tests.zig" {
    std.testing.refAllDecls(tests.ssdk_tests);
}

test "src/core/FileService.zig" {
    std.testing.refAllDecls(@import("core/FileService.zig"));
}

test "src/core/EngineFilesystem.zig" {
    std.testing.refAllDecls(@import("core/engine/EngineFilesystem.zig"));
}

test "src/core/EngineClients.zig" {
    std.testing.refAllDecls(@import("core/engine/EngineClients.zig"));
}

test "src/core/NetworkService.zig" {
    std.testing.refAllDecls(@import("core/NetworkService.zig"));
}
