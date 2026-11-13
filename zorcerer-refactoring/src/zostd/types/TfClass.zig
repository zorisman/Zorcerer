//! TF2 player class value (`ETFClass`).
//!
//! The C++ enum is append-only: new classes must be added after Engineer and
//! before `TF_CLASS_CIVILIAN` (`src/game/shared/tf/tf_shareddefs.h:203-222`).
//! This is an integer newtype, not a Zig enum, so values from a newer server are
//! preserved instead of becoming a safety error.
//!
//! `TF_CLASS_COUNT` is `TF_CLASS_COUNT_ALL` (11 in this checkout). It includes
//! `TF_CLASS_UNDEFINED` and `TF_CLASS_CIVILIAN`; normal player classes are
//! `1..9` (`src/game/shared/tf/tf_shareddefs.h:196-224`). `TF_CLASS_RANDOM` is a
//! menu/selection value (12), not a player class.

pub const TfClass = extern struct {
    /// Raw C enum value. Do not confuse it with a menu index; the enum order is
    /// not the menu order and the SDK exposes a remap table.
    value: i32,

    pub const undefined_class: TfClass = .{ .value = 0 };
    pub const scout: TfClass = .{ .value = 1 };
    pub const sniper: TfClass = .{ .value = 2 };
    pub const soldier: TfClass = .{ .value = 3 };
    pub const demoman: TfClass = .{ .value = 4 };
    pub const medic: TfClass = .{ .value = 5 };
    pub const heavyweapons: TfClass = .{ .value = 6 };
    pub const pyro: TfClass = .{ .value = 7 };
    pub const spy: TfClass = .{ .value = 8 };
    pub const engineer: TfClass = .{ .value = 9 };
    pub const civilian: TfClass = .{ .value = 10 };
    pub const count_all: TfClass = .{ .value = 11 };
    pub const random: TfClass = .{ .value = 12 };

    /// Returns whether this is a normal playable class (`1..9`).
    ///
    /// Mirrors `IsValidTFPlayerClass`; `CIVILIAN`, `RANDOM`, and `UNDEFINED`
    /// return false.
    pub fn isNormalPlayer(self: TfClass) bool {
        return self.value >= 1 and self.value <= 9;
    }
};

comptime {
    if (@sizeOf(TfClass) != 4) @compileError("TfClass must stay 4 bytes");
}
