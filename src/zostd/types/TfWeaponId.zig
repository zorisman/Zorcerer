//! TF2 weapon archetype ID (`ETFWeaponType`).
//!
//! The C++ enum is append-only ("ADD NEW WEAPONS HERE TO AVOID BREAKING DEMOS",
//! `src/game/shared/tf/tf_shareddefs.h:519-523`). `TF_WEAPON_NONE` is 0 and
//! `TF_WEAPON_COUNT` follows the last named weapon; it is 110 in this checkout.
//! That count is revision-specific, not a live-server guarantee.
//!
//! A weapon ID is an archetype, not an econ item definition and not a loadout
//! slot. `MAX_WEAPONS` (48) and `MAX_WEAPON_SLOTS` (6) are array/slot bounds
//! (`src/game/shared/shareddefs.h:115-118`), not the enum count.

pub const TfWeaponId = extern struct {
    /// Raw `ETFWeaponType` value. Unknown values from a newer server must pass
    /// through unchanged.
    value: u32,

    /// `TF_WEAPON_NONE`.
    pub const none: TfWeaponId = .{ .value = 0 };

    /// `TF_WEAPON_COUNT` in this SDK checkout. This is a bound, not a weapon
    /// ID, so it is kept as a scalar rather than a `TfWeaponId`.
    pub const count_in_this_sdk: u32 = 110;

    /// Returns whether the value is below this checkout's `TF_WEAPON_COUNT`.
    ///
    /// A true result does not prove the value is valid on the running server;
    /// the server may have a different revision.
    pub fn isKnownInThisSdk(self: TfWeaponId) bool {
        return self.value < count_in_this_sdk;
    }
};

comptime {
    if (@sizeOf(TfWeaponId) != 4) @compileError("TfWeaponId must stay 4 bytes");
}
