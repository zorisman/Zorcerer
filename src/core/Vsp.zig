pub const VTable = struct {
    load: *const fn (
        this: *anyopaque,
        interface_factory: CreateInterfaceFn,
        game_server_factory: CreateInterfaceFn,
    ) callconv(.c) void,

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
        map_name: [*:0]const u8
    ) callconv(.c) void = VspDefaults.levelInit,

    serverActivate: *const fn (
        this: *anyopaque,
        edict_list: *anyopaque,
        edict_count: c_int,
        client_max: c_int,
    ) callconv(.c) void = VspDefaults.serverActivate,

    gameFrame: *const fn (
        this: *anyopaque,
        simulating: bool
    ) callconv(.c) void = VspDefaults.gameFrame,

    levelShutdown: *const fn (
        this: *anyopaque
    ) callconv(.c) void = VspDefaults.levelShutdown,


    pub fn intoSourceVTable(self: *@This()) []const Slot {
        const vtable = [_]Slot{
            self.VTable.load,
            self.VTable.unload,
            self.VTable.pause,
            self.VTable.unpause,
            self.VTable.getPluginDescription,
            self.VTable.levelInit,
            self.VTable.serverActivate,
            self.VTable.gameFrame,
            self.VTable.levelShutdown,
        } ++ ([_]Slot{@ptrCast(&genericStub)} ** stub_count);

        return vtable;
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
