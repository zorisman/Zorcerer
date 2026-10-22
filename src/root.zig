pub const Indexes = @import("codegen_generated/engine_indexes.zig");

/// ABI contract between the plugin manager (src/PluginManager.zig) and
/// every plugin it loads (see src/PluginContext.zig and
/// example-plugins/hello/hello_plugin.zig; plugin compilations get the
/// same declarations through the `plugin-context` build module).
pub const abi = @import("PluginContext.zig");

/// Minimal Source SDK console logger for the plugin manager's own
/// messages (src/Log.zig).
pub const Log = @import("Log.zig");
