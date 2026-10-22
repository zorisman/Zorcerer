//! Example plugin for the manager in src/PluginManager.zig.
//!
//! This file is built into zig-out/lib/hello_plugin.so (see build.zig) and
//! is placed into a plugin directory under tf/addons/zorcerer/plugins/,
//! e.g.:
//!
//!     tf/addons/zorcerer/plugins/hello/hello_plugin.so
//!
//! The plugin manager dlopen()s the .so, looks up the exported `load` and
//! `unload` symbols (ABI contract in src/PluginContext.zig) and calls them
//! with a *const HostApi. load() verifies the ABI version, then prints
//! "Hello, Plugin Manager!" and unload() prints "Bye, Plugin Manager!".
//! Both print via std.debug.print (stderr) - not the host logger; the
//! `consolePrint` helper below is the logger-based path and is not
//! called yet.

const std = @import("std");
const abi = @import("plugin-context");

/// Sends one message through the logger the plugin manager configured.
/// Does nothing when the host could not provide one.
fn consolePrint(host: *const abi.HostApi, message: [:0]const u8) void {
    if (host.logger) |logger| {
        logger.print(logger.context, message.ptr);
    }
}

export fn load(host: *const abi.HostApi) callconv(.c) c_int {
    if (host.abi_version != abi.abi_version) {
        std.debug.print(
            "hello_plugin: HostApi ABI mismatch, host {d} != plugin {d}\n",
            .{ host.abi_version, abi.abi_version },
        );
        return 1;
    }

    std.debug.print("Hello, Plugin Manager!\n", .{});
    return 0;
}

export fn unload(host: *const abi.HostApi) callconv(.c) c_int {
    _ = host;
    std.debug.print("Bye, Plugin Manager!\n", .{});
    return 0;
}
