//! TF2 buildable object type (`ObjectType_t`).
//!
//! The C++ enum is append-only ("ADD NEW ITEMS HERE TO AVOID BREAKING DEMOS",
//! `src/game/shared/tf/tf_shareddefs.h:1366-1383`). It is distinct from an
//! entity classname, a building mode, and an econ item definition.
//!
//! `BUILDING_MODE_ANY` is -1 and teleporter/sentry modes are separate enums
//! (`src/game/shared/tf/tf_shareddefs.h:1385-1397`); do not reuse one integer
//! for all three concepts.

pub const TfObjectType = extern struct {
    /// Raw `ObjectType_t` value.
    value: u32,

    pub const dispenser: TfObjectType = .{ .value = 0 };
    pub const teleporter: TfObjectType = .{ .value = 1 };
    pub const sentrygun: TfObjectType = .{ .value = 2 };
    pub const attachment_sapper: TfObjectType = .{ .value = 3 };

    /// Exclusive upper bound (`OBJ_LAST`), not an object type.
    pub const obj_last: TfObjectType = .{ .value = 4 };

    /// Returns whether the value is a known object type in this checkout.
    pub fn isKnownInThisSdk(self: TfObjectType) bool {
        return self.value < obj_last.value;
    }
};

comptime {
    if (@sizeOf(TfObjectType) != 4) @compileError("TfObjectType must stay 4 bytes");
}
