//! Shared-library fixture for src/core/PluginLibrary.zig tests.
//!
//! Exports the minimum ABI surface the loader requires. The functions only
//! return success; the tests exercise symbol resolution, not plugin logic.

const abi = @import("plugin-context");

export fn load(ctx: *abi.PluginContext) callconv(.c) c_int {
    _ = ctx;
    return 0;
}

export fn unload(ctx: *abi.PluginContext) callconv(.c) c_int {
    _ = ctx;
    return 0;
}
