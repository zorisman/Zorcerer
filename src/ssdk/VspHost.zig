//! VSP instance plumbing shared by the engine-facing entrypoint.
//!
//! A Valve Server Plugin instance is just a vptr from the engine's point of
//! view. This module owns the stable vtable storage, the `CreateInterface`
//! handshake, and the engine-interface probe. Process orchestration (forking,
//! IPC, and the callbacks behind the vtable) stays with `core.Entrypoint`.
//!
//! All state is process-global and intentionally lives for the lifetime of the
//! loaded library. The engine keeps the published instance pointer after
//! `CreateInterface` returns, so the vtable must never be a stack value.

const std = @import("std");
const Vsp = @import("Vsp.zig");
const Iface = @import("types/Iface.zig").Iface;
const Indexes = @import("zroot").ssdk.indexes;

/// The VSP instance as the engine sees it: a pointer to its method table.
///
/// There is no RTTI header because the engine treats a loaded plugin interface
/// generically and never performs `dynamic_cast` or `typeid` on it.
pub const PluginObject = extern struct {
    /// Method table published through `CreateInterface`.
    vptr: [*]const Vsp.Slot,
};

var source_vtable: [Vsp.VTable.slot_count]Vsp.Slot = undefined;
var plugin_instance = PluginObject{ .vptr = &source_vtable };
var engine: ?*anyopaque = null;

/// Publishes the vtable described by `callbacks` and returns the instance to
/// hand to the engine.
///
/// The returned pointer refers to process-global storage; the caller must not
/// free it or let the vtable go out of scope. Calling this again replaces the
/// slots in place, which is what a `plugin_load` after `plugin_unload` does.
pub fn publish(callbacks: Vsp.VTable) *PluginObject {
    source_vtable = callbacks.intoSourceVTable();
    return &plugin_instance;
}

/// Outcome of probing the engine's interface factory.
pub const EngineProbe = struct {
    /// Version string the factory answered with. Borrowed from
    /// `Vsp.engine_interface_versions`, so it stays valid indefinitely.
    version: []const u8,
    /// Whether the engine build matches the version the generated indexes
    /// were produced for. A false value means the slots may have moved.
    supported: bool,
};

/// Probes `factory` with the known `IVEngineServer` version strings, newest
/// first, and remembers the interface that answered.
///
/// Returns null when no version was recognized; in that case there is no
/// engine interface to use. On success the engine pointer is available through
/// `engineInterface()` until `clear()` is called. The `supported` flag reports
/// whether the answered version is the one the generated vtable indexes were
/// built for; callers must refuse to install hooks when it is false.
pub fn probeEngine(factory: Vsp.CreateInterfaceFn) ?EngineProbe {
    var version_buffer: [32]u8 = undefined;
    for (Vsp.engine_interface_versions) |requested_version| {
        const engine_module_name = std.fmt.bufPrintZ(
            &version_buffer,
            "{s}",
            .{requested_version},
        ) catch return null;
        engine = factory(engine_module_name.ptr, null);

        if (engine != null) {
            return .{
                .version = requested_version,
                .supported = std.mem.eql(
                    u8,
                    requested_version,
                    Indexes.interfaceversion_vengineserver,
                ),
            };
        }
    }
    return null;
}

/// Returns the engine interface recorded by the last successful probe, or
/// null before a probe or after `clear()`.
pub fn engineInterface() ?*anyopaque {
    return engine;
}

/// Forgets the recorded engine interface.
///
/// The engine interface itself stays resident for the process lifetime; this
/// only drops this module's reference so a later load re-probes it.
pub fn clear() void {
    engine = null;
}

/// Answers an engine `CreateInterface` request.
///
/// `callbacks` provides the concrete VSP methods; their vtable is published
/// before the instance is returned because the engine reads its vptr
/// immediately. `return_code` receives `Iface.ok` on success or
/// `Iface.failed` when the requested version is unknown.
pub fn createInterface(
    callbacks: Vsp.VTable,
    name: [*:0]const u8,
    return_code: ?*c_int,
) ?*anyopaque {
    const requested = std.mem.span(name);
    for (Vsp.plugin_interface_versions) |version| {
        if (std.mem.eql(u8, requested, version)) {
            const instance = publish(callbacks);
            if (return_code) |rc| rc.* = @intFromEnum(Iface.ok);
            return @ptrCast(instance);
        }
    }
    if (return_code) |rc| rc.* = @intFromEnum(Iface.failed);
    return null;
}
