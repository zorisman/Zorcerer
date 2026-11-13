//! Read-only game-state queries executed in the engine process.
//!
//! The plugin-manager child never dereferences an engine pointer. When a
//! native plugin or Lua script asks for game state, the child sends an
//! `Query.QueryRequest` to this process, and `Queries.handle` answers through
//! the typed `IVEngineServer` and `ICvar` bindings below. All access is
//! synchronous and read-only.
//!
//! The engine interface and the cvar interface are process-lifetime objects.
//! `Queries` only stores the already-resolved interface pointers and the map
//! name cached from the VSP `levelInit` callback; it never holds a pointer
//! into engine memory that outlives one query.

const std = @import("std");
const ipc = @import("zroot").ipc;
const Query = ipc.Query.Query;
const QueryResult = ipc.QueryResult;
const Sender = ipc.Sender;
const Indexes = @import("zroot").codegen.indexes;

/// Longest text value returned by a query. Matches `MAX_PATH`, the bound the
/// engine documents for `GetGameDir`.
pub const max_text_len: usize = 260;

/// `MAX_PLAYER_NAME_LENGTH` (const.h:41 [checkout]).
pub const max_player_name_len: usize = 32;

/// `SIGNED_GUID_LEN + 1` (const.h:74 [checkout]): 32 hashed characters plus
/// the terminator.
pub const max_guid_len: usize = 33;

/// `MAX_CUSTOM_FILES` (const.h:99 [checkout]).
pub const max_custom_files: usize = 4;

/// `FCVAR_NEVER_AS_STRING` (iconvar.h:55 [checkout]).
const cvar_never_as_string: c_int = 1 << 12;

/// The exact C ABI of the `IVEngineServer` virtuals this module calls.
///
/// Signatures come from eiface.h [checkout]. The struct records signatures
/// only; `bind` resolves the pointers at the codegen-recorded vtable slots.
pub const EngineAbi = struct {
    /// `IsDedicatedServer` (eiface.h:108, slot 2).
    is_dedicated_server: *const fn (engine: *anyopaque) callconv(.c) bool,
    /// `GetEntityCount` (eiface.h:147, slot 17).
    get_entity_count: *const fn (engine: *anyopaque) callconv(.c) c_int,
    /// `PEntityOfEntIndex` (eiface.h:151, slot 19): null for an unused slot.
    p_entity_of_ent_index: *const fn (engine: *anyopaque, index: c_int) callconv(.c) ?*anyopaque,
    /// `GetGameDir` (eiface.h:231, slot 51): writes a zero-terminated path.
    get_game_dir: *const fn (engine: *anyopaque, buffer: [*]u8, max_length: c_int) callconv(.c) void,
    /// `GetClientConVarValue` (eiface.h:244, slot 55): null when the client
    /// is invalid.
    get_client_con_var_value: *const fn (
        engine: *anyopaque,
        client_index: c_int,
        name: [*:0]const u8,
    ) callconv(.c) ?[*:0]const u8,
    /// `IsPaused` (eiface.h:317, slot 80).
    is_paused: *const fn (engine: *anyopaque) callconv(.c) bool,
    /// `GetPlayerInfo` (eiface.h:388, slot 105): false when the slot has no
    /// connected player.
    get_player_info: *const fn (
        engine: *anyopaque,
        entity_index: c_int,
        info: *PlayerInfo,
    ) callconv(.c) bool,
    /// `GetServerVersion` (eiface.h:421, slot 117).
    get_server_version: *const fn (engine: *anyopaque) callconv(.c) c_int,
    /// `GetServerTime` (eiface.h:424, slot 118).
    get_server_time: *const fn (engine: *anyopaque) callconv(.c) f32,

    /// Resolves every method pointer from `interface`'s vtable.
    ///
    /// Precondition: `interface` is a live `IVEngineServer` of the build the
    /// codegen indices were generated for. No verification is attempted here;
    /// `Entrypoint.load` refuses mismatched engine builds.
    pub fn bind(interface: *anyopaque) EngineAbi {
        return .{
            .is_dedicated_server = @ptrCast(vtableSlot(
                interface,
                Indexes.IVEngineServer.is_dedicated_server,
            )),
            .get_entity_count = @ptrCast(vtableSlot(
                interface,
                Indexes.IVEngineServer.get_entity_count,
            )),
            .p_entity_of_ent_index = @ptrCast(vtableSlot(
                interface,
                Indexes.IVEngineServer.p_entity_of_ent_index,
            )),
            .get_game_dir = @ptrCast(vtableSlot(
                interface,
                Indexes.IVEngineServer.get_game_dir,
            )),
            .get_client_con_var_value = @ptrCast(vtableSlot(
                interface,
                Indexes.IVEngineServer.get_client_con_var_value,
            )),
            .is_paused = @ptrCast(vtableSlot(
                interface,
                Indexes.IVEngineServer.is_paused,
            )),
            .get_player_info = @ptrCast(vtableSlot(
                interface,
                Indexes.IVEngineServer.get_player_info,
            )),
            .get_server_version = @ptrCast(vtableSlot(
                interface,
                Indexes.IVEngineServer.get_server_version,
            )),
            .get_server_time = @ptrCast(vtableSlot(
                interface,
                Indexes.IVEngineServer.get_server_time,
            )),
        };
    }
};

/// The subset of `player_info_t` (cdll_int.h:71-96 [checkout]) this module
/// reads. The struct keeps the full layout, including `customFiles` and
/// `filesDownloaded`, because the engine writes the complete C++ object.
///
/// `REPLAY_ENABLED` adds `isreplay` after `ishltv`; the following fields stay
/// aligned either way, so this layout is valid for both configurations.
pub const PlayerInfo = extern struct {
    /// `name[MAX_PLAYER_NAME_LENGTH]`.
    name: [max_player_name_len]u8,
    /// `userID`.
    user_id: c_int,
    /// `guid[SIGNED_GUID_LEN + 1]`.
    guid: [max_guid_len]u8,
    /// Padding before the 4-byte-aligned `friendsID`.
    padding0: [3]u8,
    /// `friendsID`.
    friends_id: u32,
    /// `friendsName[MAX_PLAYER_NAME_LENGTH]`.
    friends_name: [max_player_name_len]u8,
    /// `fakeplayer`.
    fake_player: bool,
    /// `ishltv`.
    is_hltv: bool,
    /// `isreplay` when `REPLAY_ENABLED` is set; otherwise padding.
    is_replay: bool,
    /// Padding before the 4-byte-aligned `customFiles`.
    padding1: u8,
    /// `customFiles[MAX_CUSTOM_FILES]`.
    custom_files: [max_custom_files]u32,
    /// `filesDownloaded`.
    files_downloaded: u8,
    /// Trailing padding to the struct's 4-byte alignment.
    padding2: [3]u8,
};

comptime {
    // These offsets are the Itanium C++ ABI layout of the declarations in
    // cdll_int.h [checkout]. Keeping them explicit makes an accidental field
    // reorder a compile error rather than a silent misread.
    if (@offsetOf(PlayerInfo, "user_id") != 32) @compileError("player_info_t.userID moved");
    if (@offsetOf(PlayerInfo, "guid") != 36) @compileError("player_info_t.guid moved");
    if (@offsetOf(PlayerInfo, "friends_id") != 72) @compileError("player_info_t.friendsID moved");
    if (@offsetOf(PlayerInfo, "friends_name") != 76) @compileError("player_info_t.friendsName moved");
    if (@offsetOf(PlayerInfo, "fake_player") != 108) @compileError("player_info_t.fakeplayer moved");
    if (@offsetOf(PlayerInfo, "custom_files") != 112) @compileError("player_info_t.customFiles moved");
}

/// The public fields of `ConCommandBase` (convar.h:99-175 [checkout]).
///
/// Only the layout is mirrored; the virtual methods are never called through
/// this struct.
pub const ConCommandBase = extern struct {
    /// Primary vtable pointer.
    vtable: *const anyopaque,
    /// `m_pNext`.
    next: ?*ConCommandBase,
    /// `m_bRegistered`.
    registered: bool,
    /// Padding before the pointer-aligned name.
    padding0: [7]u8,
    /// `m_pszName`.
    name: ?[*:0]const u8,
    /// `m_pszHelpString`.
    help: ?[*:0]const u8,
    /// `m_nFlags`.
    flags: c_int,
    /// Padding to the 8-byte alignment of the `IConVar` base.
    padding1: [4]u8,
};

/// The `ConVar` data layout needed to read a value (convar.h:318-452
/// [checkout]).
///
/// `ConVar` inherits `ConCommandBase` (primary base) and `IConVar` (secondary
/// base with its own vtable pointer). The value accessors are inline in C++
/// and read `m_pParent->m_pszString`/`m_fValue`/`m_nValue`, so the same fields
/// are mirrored here. A found cvar's `parent` is the root declaration; when it
/// is null the found object itself is used, matching the engine's invariant
/// that a registered cvar's parent is itself.
pub const ConVar = extern struct {
    /// `ConCommandBase` primary base.
    base: ConCommandBase,
    /// `IConVar` secondary vtable pointer.
    iconvar_vtable: *const anyopaque,
    /// `m_pParent`.
    parent: ?*ConVar,
    /// `m_pszDefaultValue`.
    default_value: ?[*:0]const u8,
    /// `m_pszString`.
    string_value: ?[*:0]const u8,
    /// `m_StringLength`.
    string_length: c_int,
    /// `m_fValue`.
    float_value: f32,
    /// `m_nValue`.
    int_value: c_int,
    /// `m_bHasMin`.
    has_min: bool,
    /// Padding before `m_fMinVal`.
    padding0: [3]u8,
    /// `m_fMinVal`.
    min_value: f32,
    /// `m_bHasMax`.
    has_max: bool,
    /// Padding before `m_fMaxVal`.
    padding1: [3]u8,
    /// `m_fMaxVal`.
    max_value: f32,
    /// Padding before `m_fnChangeCallback`.
    padding2: [4]u8,
    /// `m_fnChangeCallback`.
    change_callback: ?*const anyopaque,
    /// `m_bHasCompMin`.
    has_comp_min: bool,
    /// Padding before `m_fCompMinVal`.
    padding3: [3]u8,
    /// `m_fCompMinVal`.
    comp_min_value: f32,
    /// `m_bHasCompMax`.
    has_comp_max: bool,
    /// Padding before `m_fCompMaxVal`.
    padding4: [3]u8,
    /// `m_fCompMaxVal`.
    comp_max_value: f32,
    /// `m_bCompetitiveRestrictions`.
    competitive_restrictions: bool,
    /// Trailing padding to the struct's 8-byte alignment.
    padding5: [7]u8,
};

comptime {
    if (@offsetOf(ConCommandBase, "name") != 24) @compileError("ConCommandBase.m_pszName moved");
    if (@offsetOf(ConCommandBase, "flags") != 40) @compileError("ConCommandBase.m_nFlags moved");
    if (@offsetOf(ConVar, "parent") != 56) @compileError("ConVar.m_pParent moved");
    if (@offsetOf(ConVar, "string_value") != 72) @compileError("ConVar.m_pszString moved");
    if (@offsetOf(ConVar, "float_value") != 84) @compileError("ConVar.m_fValue moved");
    if (@offsetOf(ConVar, "int_value") != 88) @compileError("ConVar.m_nValue moved");
}

/// The exact C ABI of the `ICvar` virtuals this module calls.
pub const CvarAbi = struct {
    /// `FindVar` non-const overload (icvar.h:73, slot 12).
    find_var: *const fn (cvar: *anyopaque, name: [*:0]const u8) callconv(.c) ?*ConVar,

    /// Resolves the method pointer from `interface`'s vtable.
    ///
    /// Precondition: `interface` is a live `ICvar` of the version named by
    /// `Indexes.cvar_interface_version`.
    pub fn bind(interface: *anyopaque) CvarAbi {
        return .{
            .find_var = @ptrCast(vtableSlot(interface, Indexes.ICvar.find_var)),
        };
    }
};

/// Returns the raw function pointer at `slot` in `interface`'s vtable.
fn vtableSlot(interface: *anyopaque, comptime slot: usize) *const anyopaque {
    const object: *const *const anyopaque = @ptrCast(@alignCast(interface));
    const vtable: [*]const *const anyopaque = @ptrCast(@alignCast(object.*));
    return vtable[slot];
}

/// Errors a query can report to the JSON-RPC listener.
pub const QueryError = error{
    /// No `IVEngineServer` binding is available.
    EngineUnavailable,
    /// No `ICvar` binding is available.
    CvarUnavailable,
    /// A cvar name does not fit the engine's zero-terminated buffer.
    NameTooLong,
};

/// The engine-facing side of game queries.
///
/// One instance lives in the engine process and is filled by `Entrypoint` as
/// the interfaces and map name become available. `context` handed to the
/// JSON-RPC listener is a pointer to this value, so it must not move while the
/// listener is running (the Entrypoint keeps it in a global).
pub const Queries = struct {
    /// Bound `IVEngineServer`, or null before `load()`.
    engine: ?*anyopaque = null,
    /// Bound `ICvar`, or null when the interface could not be resolved.
    cvar: ?*anyopaque = null,
    /// Current map name copied from `levelInit`. Only the first
    /// `max_text_len` bytes are kept.
    map_name: [max_text_len]u8 = undefined,
    /// Number of valid bytes in `map_name`; zero outside a level.
    map_name_len: usize = 0,

    /// Forgets the engine bindings. Called from the VSP `unload` callback.
    pub fn clear(self: *Queries) void {
        self.engine = null;
        self.cvar = null;
        self.map_name_len = 0;
    }

    /// Records the engine interface used for all non-cvar queries.
    pub fn setEngine(self: *Queries, engine: ?*anyopaque) void {
        self.engine = engine;
    }

    /// Records the cvar interface used for server-cvar queries.
    pub fn setCvar(self: *Queries, cvar: ?*anyopaque) void {
        self.cvar = cvar;
    }

    /// Caches the current map name. Overlong names are stored truncated.
    pub fn setMap(self: *Queries, name: []const u8) void {
        const stored = @min(name.len, self.map_name.len);
        @memcpy(self.map_name[0..stored], name[0..stored]);
        self.map_name_len = stored;
    }

    /// Clears the cached map name when the level shuts down.
    pub fn clearMap(self: *Queries) void {
        self.map_name_len = 0;
    }

    /// Returns the cached map name, or an empty slice outside a level.
    fn mapName(self: *const Queries) []const u8 {
        return self.map_name[0..self.map_name_len];
    }

    /// Executes one query and returns its JSON result text.
    ///
    /// The returned slice is owned by the caller and allocated with
    /// `allocator`.
    ///
    /// Errors: `QueryError` when the required interface is unavailable;
    /// `error.OutOfMemory` when building the JSON text fails.
    pub fn handle(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: Query.QueryRequest,
    ) anyerror![]u8 {
        const self: *Queries = @ptrCast(@alignCast(context orelse return QueryError.EngineUnavailable));
        return switch (request.query) {
            .server_info => self.serverInfo(allocator),
            .player_info => self.playerInfo(allocator, request.index),
            .entity_exists => self.entityExists(allocator, request.index),
            .server_cvar => self.serverCvar(allocator, request.name),
            .client_cvar => self.clientCvar(allocator, request.index, request.name),
        };
    }

    /// Builds the `server_info` result.
    fn serverInfo(self: *Queries, allocator: std.mem.Allocator) ![]u8 {
        const engine = self.engine orelse return QueryError.EngineUnavailable;
        const abi = EngineAbi.bind(engine);

        var game_dir: [max_text_len]u8 = undefined;
        @memset(&game_dir, 0);
        abi.get_game_dir(engine, &game_dir, game_dir.len);
        const game_dir_len = std.mem.indexOfScalar(u8, &game_dir, 0) orelse game_dir.len;

        return std.json.Stringify.valueAlloc(allocator, QueryResult.ServerInfo{
            .dedicated = abi.is_dedicated_server(engine),
            .paused = abi.is_paused(engine),
            .entity_count = abi.get_entity_count(engine),
            .server_version = abi.get_server_version(engine),
            .server_time = abi.get_server_time(engine),
            .game_dir = game_dir[0..game_dir_len],
            .map_name = self.mapName(),
        }, .{});
    }

    /// Builds the `player_info` result.
    fn playerInfo(self: *Queries, allocator: std.mem.Allocator, index: c_int) ![]u8 {
        const engine = self.engine orelse return QueryError.EngineUnavailable;
        const abi = EngineAbi.bind(engine);

        var info: PlayerInfo = std.mem.zeroes(PlayerInfo);
        const present = abi.get_player_info(engine, index, &info);
        if (!present) {
            return std.json.Stringify.valueAlloc(allocator, QueryResult.PlayerInfo{
                .present = false,
                .index = index,
                .user_id = 0,
                .friends_id = 0,
                .name = "",
                .guid = "",
                .friends_name = "",
                .fake_player = false,
                .is_hltv = false,
            }, .{});
        }

        return std.json.Stringify.valueAlloc(allocator, QueryResult.PlayerInfo{
            .present = true,
            .index = index,
            .user_id = info.user_id,
            .friends_id = info.friends_id,
            .name = textField(&info.name),
            .guid = textField(&info.guid),
            .friends_name = textField(&info.friends_name),
            .fake_player = info.fake_player,
            .is_hltv = info.is_hltv,
        }, .{});
    }

    /// Builds the `entity_exists` result.
    fn entityExists(self: *Queries, allocator: std.mem.Allocator, index: c_int) ![]u8 {
        const engine = self.engine orelse return QueryError.EngineUnavailable;
        const abi = EngineAbi.bind(engine);
        return std.json.Stringify.valueAlloc(allocator, QueryResult.EntityInfo{
            .exists = abi.p_entity_of_ent_index(engine, index) != null,
        }, .{});
    }

    /// Builds the `server_cvar` result.
    fn serverCvar(self: *Queries, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        const cvar = self.cvar orelse return QueryError.CvarUnavailable;
        const abi = CvarAbi.bind(cvar);

        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);

        const found = abi.find_var(cvar, name_z) orelse {
            return std.json.Stringify.valueAlloc(allocator, QueryResult.CvarValue{
                .found = false,
                .int_value = 0,
                .float_value = 0,
                .text = "",
            }, .{});
        };

        return std.json.Stringify.valueAlloc(allocator, cvarValue(found), .{});
    }

    /// Builds the `client_cvar` result.
    fn clientCvar(
        self: *Queries,
        allocator: std.mem.Allocator,
        index: c_int,
        name: []const u8,
    ) ![]u8 {
        const engine = self.engine orelse return QueryError.EngineUnavailable;
        const abi = EngineAbi.bind(engine);

        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);

        const value = abi.get_client_con_var_value(engine, index, name_z) orelse {
            return std.json.Stringify.valueAlloc(allocator, QueryResult.CvarValue{
                .found = false,
                .int_value = 0,
                .float_value = 0,
                .text = "",
            }, .{});
        };

        return std.json.Stringify.valueAlloc(allocator, QueryResult.CvarValue{
            .found = true,
            .int_value = 0,
            .float_value = 0,
            .text = std.mem.span(value),
        }, .{});
    }
};

/// Reads one fixed-size, possibly unterminated player-info field.
///
/// Returns `field` up to its first zero byte, or the whole field when it has no
/// terminator.
fn textField(field: []const u8) []const u8 {
    return std.mem.sliceTo(field, 0);
}

/// Builds the JSON value for a found server cvar.
///
/// The C++ accessors read the root declaration through `m_pParent`; this
/// mirrors that behavior, including the `FCVAR_NEVER_AS_STRING` check.
fn cvarValue(found: *const ConVar) QueryResult.CvarValue {
    const root = found.parent orelse found;

    const text = if ((found.base.flags & cvar_never_as_string) != 0)
        "FCVAR_NEVER_AS_STRING"
    else if (root.string_value) |string_value|
        std.mem.span(string_value)
    else
        "";

    return .{
        .found = true,
        .int_value = root.int_value,
        .float_value = root.float_value,
        .text = text,
    };
}

// --- Tests -------------------------------------------------------------------

/// Number of slots in the fake engine vtable: enough for every method the
/// queries bind, including the last one the generator records.
const fake_engine_slot_count = Indexes.IVEngineServer.set_paused_forced + 1;

/// Number of slots in the fake cvar vtable.
const fake_cvar_slot_count = Indexes.ICvar.factory_internal_iterator + 1;

/// A fake interface object: the engine sees the vptr as the first word.
fn FakeObject(comptime slot_count: usize) type {
    return struct {
        vptr: [*]const *const anyopaque = undefined,
        vtable: [slot_count]*const anyopaque = undefined,

        fn init() @This() {
            var object = @This(){};
            for (&object.vtable) |*slot| slot.* = @ptrCast(&fakeUnused);
            return object;
        }

        /// Publishes the object after it has reached its final address.
        fn interface(self: *@This()) *anyopaque {
            self.vptr = &self.vtable;
            return @ptrCast(self);
        }
    };
}

/// Placeholder vtable entry for methods a test does not exercise.
fn fakeUnused(_: *anyopaque) callconv(.c) void {}

fn fakeIsDedicated(_: *anyopaque) callconv(.c) bool {
    return true;
}

fn fakeIsPaused(_: *anyopaque) callconv(.c) bool {
    return true;
}

fn fakeEntityCount(_: *anyopaque) callconv(.c) c_int {
    return 42;
}

fn fakeServerVersion(_: *anyopaque) callconv(.c) c_int {
    return 123;
}

fn fakeServerTime(_: *anyopaque) callconv(.c) f32 {
    return 4.5;
}

fn fakeGameDir(_: *anyopaque, buffer: [*]u8, max_length: c_int) callconv(.c) void {
    const text = "tf";
    const length = @min(text.len + 1, @as(usize, @intCast(max_length)));
    @memcpy(buffer[0..text.len], text);
    if (length > text.len) buffer[text.len] = 0;
}

fn fakePEntity(_: *anyopaque, index: c_int) callconv(.c) ?*anyopaque {
    return if (index == 1) @ptrFromInt(@as(usize, 0x1000)) else null;
}

fn fakePlayerInfo(
    _: *anyopaque,
    index: c_int,
    info: *PlayerInfo,
) callconv(.c) bool {
    if (index != 1) return false;
    info.* = std.mem.zeroes(PlayerInfo);
    @memcpy(info.name[0..5], "Alice");
    info.user_id = 7;
    @memcpy(info.guid[0..3], "STE");
    info.friends_id = 99;
    @memcpy(info.friends_name[0..3], "Bob");
    info.fake_player = false;
    info.is_hltv = false;
    return true;
}

fn fakeClientCvar(
    _: *anyopaque,
    index: c_int,
    name: [*:0]const u8,
) callconv(.c) ?[*:0]const u8 {
    if (index != 1) return null;
    if (!std.mem.eql(u8, std.mem.span(name), "cl_name")) return null;
    return "client-value";
}

/// Builds an engine binding whose vtable answers every query.
fn fakeEngine() FakeObject(fake_engine_slot_count) {
    var engine = FakeObject(fake_engine_slot_count).init();
    engine.vtable[Indexes.IVEngineServer.is_dedicated_server] = @ptrCast(&fakeIsDedicated);
    engine.vtable[Indexes.IVEngineServer.get_entity_count] = @ptrCast(&fakeEntityCount);
    engine.vtable[Indexes.IVEngineServer.p_entity_of_ent_index] = @ptrCast(&fakePEntity);
    engine.vtable[Indexes.IVEngineServer.get_game_dir] = @ptrCast(&fakeGameDir);
    engine.vtable[Indexes.IVEngineServer.get_client_con_var_value] = @ptrCast(&fakeClientCvar);
    engine.vtable[Indexes.IVEngineServer.is_paused] = @ptrCast(&fakeIsPaused);
    engine.vtable[Indexes.IVEngineServer.get_player_info] = @ptrCast(&fakePlayerInfo);
    engine.vtable[Indexes.IVEngineServer.get_server_version] = @ptrCast(&fakeServerVersion);
    engine.vtable[Indexes.IVEngineServer.get_server_time] = @ptrCast(&fakeServerTime);
    return engine;
}

/// Root ConVar used by the fake `ICvar`.
var fake_cvar_root: ConVar = undefined;

fn fakeFindVar(_: *anyopaque, name: [*:0]const u8) callconv(.c) ?*ConVar {
    if (!std.mem.eql(u8, std.mem.span(name), "sv_cheats")) return null;
    return &fake_cvar_root;
}

/// Initializes `fake_cvar_root` and returns a fake `ICvar` that finds it.
fn fakeCvar() FakeObject(fake_cvar_slot_count) {
    fake_cvar_root = std.mem.zeroes(ConVar);
    fake_cvar_root.parent = &fake_cvar_root;
    fake_cvar_root.string_value = "1";
    fake_cvar_root.int_value = 1;
    fake_cvar_root.float_value = 1.0;

    var cvar = FakeObject(fake_cvar_slot_count).init();
    cvar.vtable[Indexes.ICvar.find_var] = @ptrCast(&fakeFindVar);
    return cvar;
}

test "server info query binds the engine vtable and reports values" {
    var engine = fakeEngine();
    var queries = Queries{};
    queries.setEngine(engine.interface());
    queries.setMap("cp_badlands");

    const text = try Queries.handle(&queries, std.testing.allocator, .{ .query = .server_info });
    defer std.testing.allocator.free(text);

    var parsed = try std.json.parseFromSlice(QueryResult.ServerInfo, std.testing.allocator, text, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.dedicated);
    try std.testing.expect(parsed.value.paused);
    try std.testing.expectEqual(@as(c_int, 42), parsed.value.entity_count);
    try std.testing.expectEqual(@as(c_int, 123), parsed.value.server_version);
    try std.testing.expectEqual(@as(f32, 4.5), parsed.value.server_time);
    try std.testing.expectEqualStrings("tf", parsed.value.game_dir);
    try std.testing.expectEqualStrings("cp_badlands", parsed.value.map_name);
}

test "map name is empty outside a level" {
    var engine = fakeEngine();
    var queries = Queries{};
    queries.setEngine(engine.interface());
    queries.setMap("cp_badlands");
    queries.clearMap();

    const text = try Queries.handle(&queries, std.testing.allocator, .{ .query = .server_info });
    defer std.testing.allocator.free(text);

    var parsed = try std.json.parseFromSlice(QueryResult.ServerInfo, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("", parsed.value.map_name);
}

test "player info query reports an empty slot and a filled slot" {
    var engine = fakeEngine();
    var queries = Queries{};
    queries.setEngine(engine.interface());

    const empty_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .player_info, .index = 2 },
    );
    defer std.testing.allocator.free(empty_text);

    var empty = try std.json.parseFromSlice(QueryResult.PlayerInfo, std.testing.allocator, empty_text, .{});
    defer empty.deinit();
    try std.testing.expect(!empty.value.present);

    const filled_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .player_info, .index = 1 },
    );
    defer std.testing.allocator.free(filled_text);

    var filled = try std.json.parseFromSlice(QueryResult.PlayerInfo, std.testing.allocator, filled_text, .{});
    defer filled.deinit();
    try std.testing.expect(filled.value.present);
    try std.testing.expectEqual(@as(c_int, 7), filled.value.user_id);
    try std.testing.expectEqual(@as(u32, 99), filled.value.friends_id);
    try std.testing.expectEqualStrings("Alice", filled.value.name);
    try std.testing.expectEqualStrings("STE", filled.value.guid);
    try std.testing.expectEqualStrings("Bob", filled.value.friends_name);
}

test "entity query reports present and missing indexes" {
    var engine = fakeEngine();
    var queries = Queries{};
    queries.setEngine(engine.interface());

    const present_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .entity_exists, .index = 1 },
    );
    defer std.testing.allocator.free(present_text);
    var present = try std.json.parseFromSlice(QueryResult.EntityInfo, std.testing.allocator, present_text, .{});
    defer present.deinit();
    try std.testing.expect(present.value.exists);

    const missing_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .entity_exists, .index = 2 },
    );
    defer std.testing.allocator.free(missing_text);
    var missing = try std.json.parseFromSlice(QueryResult.EntityInfo, std.testing.allocator, missing_text, .{});
    defer missing.deinit();
    try std.testing.expect(!missing.value.exists);
}

test "server cvar query reads the mirrored ConVar layout" {
    var cvar = fakeCvar();
    var queries = Queries{};
    queries.setCvar(cvar.interface());

    const found_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .server_cvar, .name = "sv_cheats" },
    );
    defer std.testing.allocator.free(found_text);
    var found = try std.json.parseFromSlice(QueryResult.CvarValue, std.testing.allocator, found_text, .{});
    defer found.deinit();
    try std.testing.expect(found.value.found);
    try std.testing.expectEqual(@as(c_int, 1), found.value.int_value);
    try std.testing.expectEqual(@as(f32, 1.0), found.value.float_value);
    try std.testing.expectEqualStrings("1", found.value.text);

    const missing_text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .server_cvar, .name = "missing" },
    );
    defer std.testing.allocator.free(missing_text);
    var missing = try std.json.parseFromSlice(QueryResult.CvarValue, std.testing.allocator, missing_text, .{});
    defer missing.deinit();
    try std.testing.expect(!missing.value.found);
}

test "client cvar query reads the engine value" {
    var engine = fakeEngine();
    var queries = Queries{};
    queries.setEngine(engine.interface());

    const text = try Queries.handle(
        &queries,
        std.testing.allocator,
        .{ .query = .client_cvar, .index = 1, .name = "cl_name" },
    );
    defer std.testing.allocator.free(text);
    var parsed = try std.json.parseFromSlice(QueryResult.CvarValue, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.found);
    try std.testing.expectEqualStrings("client-value", parsed.value.text);
}

test "queries fail cleanly when the engine is not bound" {
    var queries = Queries{};
    try std.testing.expectError(
        QueryError.EngineUnavailable,
        Queries.handle(&queries, std.testing.allocator, .{ .query = .server_info }),
    );
    try std.testing.expectError(
        QueryError.CvarUnavailable,
        Queries.handle(
            &queries,
            std.testing.allocator,
            .{ .query = .server_cvar, .name = "sv_cheats" },
        ),
    );
}
