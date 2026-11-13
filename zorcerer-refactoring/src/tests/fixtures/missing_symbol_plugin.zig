//! Shared-library fixture for src/core/plugin/PluginLibrary.zig tests.
//!
//! Exports only `load`, so the loader must reject it as missing `unload`.

const abi = @import("plugin-context");

export fn load(ctx: *abi.PluginContext) callconv(.c) c_int {
    _ = ctx;
    return 0;
}
