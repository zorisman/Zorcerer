/// Typed description of the `IServerPluginCallbacks` methods the Entrypoint
/// implements. Field order is the Source vtable slot order; `intoSourceVTable`
/// turns one into the flat pointer array the engine consumes.
///
/// Every callback receives the plugin instance pointer as `this`; the
/// Entrypoint ignores it because its state is process-global.
pub const VTable = struct {
    /// Slot 0: called once by the engine to let the plugin initialize.
    /// Returning false tells the engine the plugin refused to load.
    load: *const fn (
        this: *anyopaque,
        interface_factory: CreateInterfaceFn,
        game_server_factory: CreateInterfaceFn,
    ) callconv(.c) bool,

    unload: *const fn (
        this: *anyopaque,
    ) callconv(.c) void,

    pause: *const fn (
        this: *anyopaque,
    ) callconv(.c) void = VspDefaults.pause,

    unpause: *const fn (
        this: *anyopaque,
    ) callconv(.c) void = VspDefaults.unpause,

    getPluginDescription: *const fn (
        this: *anyopaque,
    ) callconv(.c) [*:0]const u8 = VspDefaults.getPluginDescription,

    levelInit: *const fn (
        this: *anyopaque,
        map_name: [*:0]const u8,
    ) callconv(.c) void = VspDefaults.levelInit,

    serverActivate: *const fn (
        this: *anyopaque,
        edict_list: *anyopaque,
        edict_count: c_int,
        client_max: c_int,
    ) callconv(.c) void = VspDefaults.serverActivate,

    gameFrame: *const fn (
        this: *anyopaque,
        simulating: bool,
    ) callconv(.c) void = VspDefaults.gameFrame,

    levelShutdown: *const fn (
        this: *anyopaque,
    ) callconv(.c) void = VspDefaults.levelShutdown,

    /// Number of leading slots described by named fields, in vtable order.
    pub const implemented_count = 9;

    /// Total number of slots in a generated vtable, including the padding
    /// that makes it safe for interface versions newer than the implemented
    /// methods.
    pub const slot_count = implemented_count + stub_count;

    /// Converts this description into the flat slot array the engine reads
    /// through the plugin instance's vptr.
    ///
    /// The returned array is a value, not a view into `self`, so it stays
    /// independent of the `VTable` and of this call's stack frame. The caller
    /// must store it somewhere with a stable address (for example a global)
    /// before publishing a pointer to it to the engine.
    pub fn intoSourceVTable(self: *const @This()) [slot_count]Slot {
        var source: [slot_count]Slot = undefined;
        source[0] = @ptrCast(self.load);
        source[1] = @ptrCast(self.unload);
        source[2] = @ptrCast(self.pause);
        source[3] = @ptrCast(self.unpause);
        source[4] = @ptrCast(self.getPluginDescription);
        source[5] = @ptrCast(self.levelInit);
        source[6] = @ptrCast(self.serverActivate);
        source[7] = @ptrCast(self.gameFrame);
        source[8] = @ptrCast(self.levelShutdown);

        for (source[implemented_count..]) |*slot| {
            slot.* = @ptrCast(&genericStub);
        }
        return source;
    }
};

const std = @import("std");
const root = @import("../root.zig");
const Indexes = root.codegen.indexes;

/// Version strings this plugin answers to, newest first. All of them get
/// the same vtable - the padding described above is what makes that safe.
pub const plugin_interface_versions = [_][]const u8{
    Indexes.interfaceversion_iserverplugincallbacks,
    Indexes.interfaceversion_iserverplugincallbacks_version_2,
    Indexes.interfaceversion_iserverplugincallbacks_version_1,
};

/// IVEngineServer interface version strings the engine module might
/// answer with, newest first. Both these strings and the LogPrint slot
/// index that logPrintOf() consumes come from the same codegen module,
/// so engine probing and index use agree on which engine build the slot
/// layout was recorded for. Order: the current build answers with the
/// exact string the codegen generated for, while older recognized builds
/// surface only through the fallback constants.
pub const engine_interface_versions = [_][]const u8{
    Indexes.interfaceversion_vengineserver,
    Indexes.interfaceversion_vengineserver_version_22,
    Indexes.interfaceversion_vengineserver_version_21,
};

/// `CreateInterface` success code returned through its optional out-parameter.
pub const iface_ok: c_int = 0;
/// `CreateInterface` failure code returned through its optional out-parameter.
pub const iface_failed: c_int = 1;

pub const Slot = ?*const anyopaque;
pub const CreateInterfaceFn = *const fn (name: [*:0]const u8, return_code: ?*c_int) callconv(.c) ?*anyopaque;

const VspDefaults = struct {
    pub fn pause(this: *anyopaque) callconv(.c) void {
        _ = this;
    }

    pub fn unpause(this: *anyopaque) callconv(.c) void {
        _ = this;
    }

    pub fn getPluginDescription(this: *anyopaque) callconv(.c) [*:0]const u8 {
        _ = this;
        return "Unnamed plugin";
    }

    pub fn levelInit(this: *anyopaque, map_name: [*:0]const u8) callconv(.c) void {
        _ = this;
        _ = map_name;
    }

    pub fn serverActivate(
        this: *anyopaque,
        edict_list: *anyopaque,
        edict_count: c_int,
        client_max: c_int,
    ) callconv(.c) void {
        _ = this;
        _ = edict_list;
        _ = edict_count;
        _ = client_max;
    }

    pub fn gameFrame(this: *anyopaque, simulating: bool) callconv(.c) void {
        _ = this;
        _ = simulating;
    }

    pub fn levelShutdown(this: *anyopaque) callconv(.c) void {
        _ = this;
    }
};

/// Placeholder for every method this foundation doesn't implement yet.
/// Declared with zero parameters on purpose: the calling convention
/// doesn't validate argument count on entry, so this safely ignores
/// whatever registers/stack the real call set up and returns 0 in the
/// return register - false / PLUGIN_CONTINUE / null, whichever the real
/// signature expected. Replace the corresponding slot below once you
/// actually need that callback to do something.
fn genericStub() callconv(.c) usize {
    return 0;
}

/// "More than enough" trailing slots for interface versions newer than
/// what's implemented above. Raise this if your SDK header has more
/// methods than this accounts for; see the module doc-comment.
const stub_count = 20;
