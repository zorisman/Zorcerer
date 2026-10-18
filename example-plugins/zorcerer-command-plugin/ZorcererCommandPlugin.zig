//! Minimal Zorcerer plugin: registers the `zorcerer` server-console command.
//!
//! Build this as a shared library and place it beside zorcerer-command.toml.
//! The manager must pass PluginAPI.Context to load(), as documented in README.md.

const PluginAPI = @import("PluginAPI.zig");
const ZorcererCommand = @import("ZorcererCommand.zig");

var installed = false;

export fn load(context: *const PluginAPI.Context) callconv(.c) bool {
    if (context.abi_version != PluginAPI.abi_version) return false;
    if (context.struct_size < @sizeOf(PluginAPI.Context)) return false;

    // A repeated load callback must not register the same command twice.
    if (installed) return true;

    ZorcererCommand.install(context.interface_factory, context.engine) catch return false;
    installed = true;
    return true;
}

export fn unload() callconv(.c) void {
    if (!installed) return;
    ZorcererCommand.uninstall();
    installed = false;
}
