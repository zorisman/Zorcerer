//! TF2 condition ID (`ETFCond`).
//!
//! The C++ enum is append-only ("ADD NEW ITEMS HERE TO AVOID BREAKING DEMOS",
//! `src/game/shared/tf/tf_shareddefs.h:825-833`). `TF_COND_INVALID` is -1,
//! `TF_COND_AIMING` is 0, and `TF_COND_LAST` is 131 in this checkout.
//!
//! A condition ID is not a duration and not a provider. The game's condition
//! state carries timers/providers elsewhere; this type only mirrors the ID.

pub const TfCondition = extern struct {
    /// Raw `ETFCond` value. Unknown values from a newer server must pass through
    /// unchanged.
    value: i32,

    /// `TF_COND_INVALID`.
    pub const invalid: TfCondition = .{ .value = -1 };

    /// First valid condition (`TF_COND_AIMING`).
    pub const first: TfCondition = .{ .value = 0 };

    /// `TF_COND_LAST` in this SDK checkout. This is an exclusive upper bound,
    /// not a condition, so it is kept as a scalar.
    pub const last_in_this_sdk: i32 = 131;

    /// Returns whether the value is in `0..130` for this checkout.
    ///
    /// This mirrors the source's range check
    /// (`src/game/shared/tf/tf_shareddefs.h:837-839`). A newer server may have
    /// additional valid conditions.
    pub fn isKnownInThisSdk(self: TfCondition) bool {
        return self.value >= 0 and self.value < last_in_this_sdk;
    }

    /// Returns whether this is `TF_COND_INVALID`.
    pub fn isInvalid(self: TfCondition) bool {
        return self.value == invalid.value;
    }
};

comptime {
    if (@sizeOf(TfCondition) != 4) @compileError("TfCondition must stay 4 bytes");
}
