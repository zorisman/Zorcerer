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

/// `FCVAR_NEVER_AS_STRING` (iconvar.h:55 [checkout]).
const cvar_never_as_string: c_int = 1 << 12;

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
