//! Exact C ABI of the `IVEngineServer` virtuals used by the query handler.
//!
//! The signatures come from `eiface.h` [checkout]. This module records only
//! function types; `bind` resolves the pointers at the vtable slots recorded
//! in the generated indexes for the engine build the project targets.

const PlayerInfo = @import("types/PlayerInfo.zig").PlayerInfo;
const Indexes = @import("zroot").ssdk.indexes;
const Vtable = @import("Vtable.zig");

/// The `IVEngineServer` methods the query handler invokes.
///
/// Every field is a raw function pointer with the method's C calling
/// convention; no C++ method is called through a generated wrapper. `bind`
/// fills every field from the engine object's vtable, so an instance is only
/// valid for a live `IVEngineServer` of the indexed build.
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
    /// `interface` must be a live `IVEngineServer` of the build the generated
    /// indexes were produced for. No runtime verification is attempted here;
    /// `Entrypoint.load` refuses mismatched engine builds before any binding
    /// happens.
    pub fn bind(interface: *anyopaque) EngineAbi {
        return .{
            .is_dedicated_server = @ptrCast(Vtable.slot(
                interface,
                Indexes.IVEngineServer.is_dedicated_server,
            )),
            .get_entity_count = @ptrCast(Vtable.slot(
                interface,
                Indexes.IVEngineServer.get_entity_count,
            )),
            .p_entity_of_ent_index = @ptrCast(Vtable.slot(
                interface,
                Indexes.IVEngineServer.p_entity_of_ent_index,
            )),
            .get_game_dir = @ptrCast(Vtable.slot(
                interface,
                Indexes.IVEngineServer.get_game_dir,
            )),
            .get_client_con_var_value = @ptrCast(Vtable.slot(
                interface,
                Indexes.IVEngineServer.get_client_con_var_value,
            )),
            .is_paused = @ptrCast(Vtable.slot(
                interface,
                Indexes.IVEngineServer.is_paused,
            )),
            .get_player_info = @ptrCast(Vtable.slot(
                interface,
                Indexes.IVEngineServer.get_player_info,
            )),
            .get_server_version = @ptrCast(Vtable.slot(
                interface,
                Indexes.IVEngineServer.get_server_version,
            )),
            .get_server_time = @ptrCast(Vtable.slot(
                interface,
                Indexes.IVEngineServer.get_server_time,
            )),
        };
    }
};
