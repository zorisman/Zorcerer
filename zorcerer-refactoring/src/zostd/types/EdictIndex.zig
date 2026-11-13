//! A networkable edict slot index.
//!
//! `MAX_EDICTS` is `1 << MAX_EDICT_BITS` (`2048`,
//! `src/public/const.h:64-67`), and only the first `MAX_EDICTS` entity-list
//! slots are networkable (`src/game/shared/entitylist_base.h:107-108`).
//! `EdictIndex` is restricted to `0..2047`.
//!
//! The index names a slot, not an entity incarnation. A freed slot can be
//! reused; use `EntityHandle` for stable identity. Use
//! `EntityIndex.fromEdictIndex()` to widen to the full entity-list namespace.

pub const EdictIndex = extern struct {
    /// Networkable edict slot number.
    value: u16,

    /// Number of networkable slots (`MAX_EDICTS`); valid values are below it.
    pub const max_count: u16 = 2048;
};

comptime {
    if (@sizeOf(EdictIndex) != 2) @compileError("EdictIndex must stay 2 bytes");
}
