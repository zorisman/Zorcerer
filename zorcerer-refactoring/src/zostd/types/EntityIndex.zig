//! A full entity-list slot index.
//!
//! Source has two slot namespaces. `EntityIndex` covers
//! `NUM_ENT_ENTRIES` (`0..8191`, `src/public/const.h:76-78`). The first
//! `MAX_EDICTS` slots (`0..2047`) are networkable; the rest are
//! client/server-only entity-list slots (`src/game/shared/entitylist_base.h:107-108`).
//!
//! This is a namespace tag, not a stable entity identity. A slot can be freed
//! and reused; use `EntityHandle` when the incarnation matters.

const EdictIndex = @import("EdictIndex.zig").EdictIndex;

pub const EntityIndex = extern struct {
    /// Slot number in the full entity list.
    value: u16,

    /// Highest valid full entity-list slot (`NUM_ENT_ENTRIES - 1`).
    pub const max_value: u16 = 8191;

    /// Converts to a networkable edict slot when the index is below
    /// `MAX_EDICTS`; otherwise returns null.
    ///
    /// This is the check that keeps an `EntityIndex` from being used where the
    /// SDK requires an `EdictIndex` (`src/game/shared/entitylist_base.h:126-133`).
    pub fn toEdictIndex(self: EntityIndex) ?EdictIndex {
        if (self.value >= EdictIndex.max_count) return null;
        return EdictIndex{ .value = self.value };
    }

    /// Widens an edict slot to the full entity-list namespace.
    pub fn fromEdictIndex(index: EdictIndex) EntityIndex {
        return .{ .value = index.value };
    }
};

comptime {
    if (@sizeOf(EntityIndex) != 2) @compileError("EntityIndex must stay 2 bytes");
}
