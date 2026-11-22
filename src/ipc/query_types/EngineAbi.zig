const PlayerInfo = @import("PlayerInfo.zig");

/// The exact C ABI of the `IVEngineServer` virtuals this module calls.
///
/// Signatures come from eiface.h [checkout]. The struct records signatures
/// only; `bind` resolves the pointers at the codegen-recorded vtable slots.
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
pub fn bind(interface: *anyopaque) @This() {
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
