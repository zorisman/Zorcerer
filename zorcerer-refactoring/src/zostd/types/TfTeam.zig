//! TF2 team value.
//!
//! Teams share the engine's unassigned/spectator namespace and then append
//! RED/BLUE (`src/game/shared/shareddefs.h:278-283`;
//! `src/game/shared/tf/tf_shareddefs.h:31-50`). Negative values are selectors or
//! sentinels, not teams. The value is an integer newtype so future team values
//! and aliases are preserved.
//!
//! `TF_TEAM_PVE_INVADERS` aliases BLUE and `TF_TEAM_PVE_DEFENDERS` aliases RED;
//! they are not new numeric values. `TF_TEAM_HALLOWEEN` aliases AUTOASSIGN (5).

pub const TfTeam = extern struct {
    /// Raw team value.
    value: i32,

    /// "Any team" selector, not a team.
    pub const any: TfTeam = .{ .value = -2 };

    /// Invalid team sentinel.
    pub const invalid: TfTeam = .{ .value = -1 };

    /// Not assigned to a team.
    pub const unassigned: TfTeam = .{ .value = 0 };

    /// Spectator team (`LAST_SHARED_TEAM`).
    pub const spectator: TfTeam = .{ .value = 1 };

    /// RED team (`LAST_SHARED_TEAM + 1`).
    pub const red: TfTeam = .{ .value = 2 };

    /// BLU team.
    pub const blue: TfTeam = .{ .value = 3 };

    /// Number of TF teams (`TF_TEAM_COUNT`).
    pub const count: TfTeam = .{ .value = 4 };

    /// Auto-assignment selector (`TF_TEAM_COUNT + 1`).
    pub const autoassign: TfTeam = .{ .value = 5 };

    /// Halloween alias for `autoassign`.
    pub const halloween: TfTeam = .{ .value = 5 };

    /// Returns whether this is RED or BLUE, mirroring `IsValidTFTeam`.
    ///
    /// Unassigned, spectator, selectors, and unknown future values return false.
    pub fn isGameTeam(self: TfTeam) bool {
        return self.value == red.value or self.value == blue.value;
    }
};

comptime {
    if (@sizeOf(TfTeam) != 4) @compileError("TfTeam must stay 4 bytes");
}
