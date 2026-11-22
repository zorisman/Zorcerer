/// JSON result of the cvar queries.
pub const CvarValue = struct {
    /// Nonzero when the cvar was found.
    found: bool,
    /// Integer representation of the value.
    int_value: c_int,
    /// Floating-point representation of the value.
    float_value: f32,
    /// String representation of the value.
    text: []const u8,
};

/// JSON result of the `server_info` query.
pub const ServerInfo = struct {
    /// Nonzero when the engine is a dedicated server.
    dedicated: bool,
    /// Nonzero when the server is paused.
    paused: bool,
    /// Number of entity slots the engine reports in use.
    entity_count: c_int,
    /// Engine build number.
    server_version: c_int,
    /// Seconds since server start.
    server_time: f32,
    /// Game/mod directory, for example `tf`.
    game_dir: []const u8,
    /// Current map name, or an empty string outside a level.
    map_name: []const u8,
};

/// JSON result of the `player_info` query.
pub const PlayerInfo = struct {
    /// Nonzero when the engine returned info for the requested slot.
    present: bool,
    /// Entity index the caller requested.
    index: c_int,
    /// Server-assigned user id.
    user_id: c_int,
    /// Steam friends id.
    friends_id: u32,
    /// Player display name.
    name: []const u8,
    /// Steam id string.
    guid: []const u8,
    /// Steam friends name.
    friends_name: []const u8,
    /// Nonzero when the client is a bot.
    fake_player: bool,
    /// Nonzero when the client is an HLTV proxy.
    is_hltv: bool,
};

/// JSON result of the `entity_exists` query.
pub const EntityInfo = struct {
    /// Nonzero when the engine has an entity at the requested index.
    exists: bool,
};
