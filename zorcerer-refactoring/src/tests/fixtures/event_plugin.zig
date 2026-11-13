//! Shared-library fixture for src/core/plugin/PluginLibrary.zig tests.
//!
//! Exports the required ABI surface plus the optional `onEvent` export, so
//! the loader test can verify that a plugin subscribing to runtime events is
//! discovered. The callbacks only return success; the tests exercise symbol
//! resolution, not plugin logic.

const abi = @import("plugin-context");

export fn load(ctx: *abi.PluginContext) callconv(.c) c_int {
    _ = ctx;
    return 0;
}

export fn unload(ctx: *abi.PluginContext) callconv(.c) c_int {
    _ = ctx;
    return 0;
}

export fn onEvent(ctx: *abi.PluginContext, event: *const abi.Event) callconv(.c) c_int {
    _ = ctx;
    _ = event;
    return abi.plugin_continue;
}
