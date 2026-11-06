/// Result values of `PLUGIN_RESULT`, the C enum returned by callbacks such as
/// `ClientCommand`.
///
/// The SDK declares the enum with an `int` representation, so the Entrypoint
/// uses `c_int` for the callback return type and these constants for the
/// values. Returning `plugin_stop` from `ClientCommand` keeps the game DLL from
/// processing the command again.
pub const plugin_continue: c_int = 0;
/// Run the game DLL function but use this plugin's return value instead.
pub const plugin_override: c_int = 1;
/// Do not run the game DLL function at all.
pub const plugin_stop: c_int = 2;

/// Binary layout of Source's `CCommand` (see `tier1/convar.h`).
///
/// The engine passes a reference to its own `CCommand` into `ClientCommand`.
/// This mirror exists only to read the tokenized command text without calling
/// C++ methods through the reference. The field names match the SDK's private
/// members to make the layout easy to audit; they are not a public API.
///
/// Invariants: `m_nArgc` is the number of parsed arguments, `m_nArgv0Size` is
/// the byte length of argument zero, and `m_pArgSBuffer` holds the full
/// NUL-terminated command line. `m_ppArgv` points into the two buffers and is
/// not used here. `commandText()` only reads the first `m_nArgc > 0` case.
pub const CCommand = extern struct {
    /// Number of tokenized arguments, including the command name.
    m_nArgc: c_int,
    /// Size of the command name in `m_pArgSBuffer`.
    m_nArgv0Size: c_int,
    /// Full command line, NUL-terminated by the engine.
    m_pArgSBuffer: [512]u8,
    /// Tokenized argument storage; unused by this mirror.
    m_pArgvBuffer: [512]u8,
    /// Pointers into `m_pArgvBuffer`; unused by this mirror.
    m_ppArgv: [64]?*const u8,

    /// Returns the full command line, excluding the terminating NUL.
    ///
    /// Returns null when the engine reported no arguments. The returned slice
    /// borrows the engine-owned `CCommand` and is valid only during the
    /// `ClientCommand` callback.
    pub fn commandText(self: *const @This()) ?[]const u8 {
        if (self.m_nArgc <= 0) return null;
        const text = std.mem.sliceTo(self.m_pArgSBuffer[0..], 0);
        if (text.len == 0) return null;
        return text;
    }
};

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

    clientActive: *const fn (
        this: *anyopaque,
        entity: *anyopaque,
    ) callconv(.c) void = VspDefaults.clientActive,

    clientDisconnect: *const fn (
        this: *anyopaque,
        entity: *anyopaque,
    ) callconv(.c) void = VspDefaults.clientDisconnect,

    clientPutInServer: *const fn (
        this: *anyopaque,
        entity: *anyopaque,
        player_name: [*:0]const u8,
    ) callconv(.c) void = VspDefaults.clientPutInServer,

    setCommandClient: *const fn (
        this: *anyopaque,
        index: c_int,
    ) callconv(.c) void = VspDefaults.setCommandClient,

    clientSettingsChanged: *const fn (
        this: *anyopaque,
        entity: *anyopaque,
    ) callconv(.c) void = VspDefaults.clientSettingsChanged,

    clientConnect: *const fn (
        this: *anyopaque,
        allow_connect: *bool,
        entity: *anyopaque,
        name: [*:0]const u8,
        address: [*:0]const u8,
        reject: [*]u8,
        max_reject_len: c_int,
    ) callconv(.c) c_int = VspDefaults.clientConnect,

    /// Slot 15: a client typed a command at its console.
    ///
    /// `entity` is the issuing player's `edict_t*` and `args` is the engine's
    /// `CCommand&`, both borrowed for the duration of the call. Return
    /// `plugin_stop` to keep the game DLL from also processing the command.
    clientCommand: *const fn (
        this: *anyopaque,
        entity: *anyopaque,
        args: *const CCommand,
    ) callconv(.c) c_int = VspDefaults.clientCommand,

    /// Number of leading slots described by named fields, in vtable order.
    pub const implemented_count = 16;

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
        source[9] = @ptrCast(self.clientActive);
        source[10] = @ptrCast(self.clientDisconnect);
        source[11] = @ptrCast(self.clientPutInServer);
        source[12] = @ptrCast(self.setCommandClient);
        source[13] = @ptrCast(self.clientSettingsChanged);
        source[14] = @ptrCast(self.clientConnect);
        source[15] = @ptrCast(self.clientCommand);

        for (source[implemented_count..]) |*slot| {
            slot.* = @ptrCast(&genericStub);
        }
        return source;
    }
};

const std = @import("std");
const root = @import("zroot");
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

    pub fn clientActive(this: *anyopaque, entity: *anyopaque) callconv(.c) void {
        _ = this;
        _ = entity;
    }

    pub fn clientDisconnect(this: *anyopaque, entity: *anyopaque) callconv(.c) void {
        _ = this;
        _ = entity;
    }

    pub fn clientPutInServer(
        this: *anyopaque,
        entity: *anyopaque,
        player_name: [*:0]const u8,
    ) callconv(.c) void {
        _ = this;
        _ = entity;
        _ = player_name;
    }

    pub fn setCommandClient(this: *anyopaque, index: c_int) callconv(.c) void {
        _ = this;
        _ = index;
    }

    pub fn clientSettingsChanged(this: *anyopaque, entity: *anyopaque) callconv(.c) void {
        _ = this;
        _ = entity;
    }

    pub fn clientConnect(
        this: *anyopaque,
        allow_connect: *bool,
        entity: *anyopaque,
        name: [*:0]const u8,
        address: [*:0]const u8,
        reject: [*]u8,
        max_reject_len: c_int,
    ) callconv(.c) c_int {
        _ = this;
        _ = allow_connect;
        _ = entity;
        _ = name;
        _ = address;
        _ = reject;
        _ = max_reject_len;
        return plugin_continue;
    }

    pub fn clientCommand(
        this: *anyopaque,
        entity: *anyopaque,
        args: *const CCommand,
    ) callconv(.c) c_int {
        _ = this;
        _ = entity;
        _ = args;
        return plugin_continue;
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

test "CCommand matches the Source SDK binary layout" {
    try std.testing.expectEqual(@as(usize, 1544), @sizeOf(CCommand));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CCommand, "m_nArgc"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(CCommand, "m_nArgv0Size"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CCommand, "m_pArgSBuffer"));
    try std.testing.expectEqual(@as(usize, 520), @offsetOf(CCommand, "m_pArgvBuffer"));
    try std.testing.expectEqual(@as(usize, 1032), @offsetOf(CCommand, "m_ppArgv"));
}

test "CCommand.commandText reads the NUL-terminated command line" {
    var command = std.mem.zeroes(CCommand);
    command.m_nArgc = 2;
    const text = "zlua ping";
    @memcpy(command.m_pArgSBuffer[0..text.len], text);

    try std.testing.expectEqualStrings(text, command.commandText().?);

    command.m_nArgc = 0;
    try std.testing.expect(command.commandText() == null);
}
