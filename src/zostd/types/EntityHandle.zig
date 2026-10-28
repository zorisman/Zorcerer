//! Stable 32-bit identity of a Source engine entity.
//!
//! `EntityHandle` mirrors `CBaseHandle` (`src/public/basehandle.h:30-81`): the
//! low 16 bits are the entity-list entry index and the high 16 bits are the
//! serial number. `0xFFFF_FFFF` is the invalid sentinel.
//!
//! The whole 32-bit word is preserved. Server-side producers may use only 15
//! serial bits because the game reserves the high bit for static props
//! (`src/game/shared/entitylist_base.cpp:14-16`), and networked handles use 10
//! serial bits (`src/public/const.h:86-89`). Those are producer policies, not
//! invariants of this type.
//!
//! A non-sentinel handle is not proof that the entity is alive: the slot may
//! have been freed and reused with a different serial. Resolve the handle
//! through the host before dereferencing anything.

const EntityIndex = @import("EntityIndex.zig").EntityIndex;
const EdictIndex = @import("EdictIndex.zig").EdictIndex;

pub const EntityHandle = extern struct {
    /// Raw `CBaseHandle::m_Index` word. Preserve all 32 bits when copying.
    bits: u32,

    /// The invalid handle sentinel (`INVALID_EHANDLE_INDEX`).
    pub const invalid: EntityHandle = .{ .bits = 0xFFFF_FFFF };

    /// Mask for the low 16 entry-index bits.
    pub const entry_mask: u32 = 0xFFFF;

    /// Number of bits the serial is shifted by.
    pub const serial_shift: u5 = 16;

    /// Packs an entry index and serial into a handle.
    ///
    /// `index` is the raw 16-bit field, not an `EdictIndex`; the caller is
    /// responsible for passing an index that is valid for the producer.
    /// `serial` is stored unchanged in the high 16 bits. This function does not
    /// check liveness and does not reject the invalid sentinel encoding.
    pub fn fromParts(index: u16, serial: u16) EntityHandle {
        return .{ .bits = @as(u32, index) | (@as(u32, serial) << serial_shift) };
    }

    /// Returns whether the value is not the invalid sentinel.
    ///
    /// This is the same narrow check as `CBaseHandle::IsValid()`
    /// (`src/public/basehandle.h:132-135`). It does not prove that the target
    /// entity still exists; a stale handle with a matching old serial can pass
    /// this check and still resolve to null.
    pub fn isValid(self: EntityHandle) bool {
        return self.bits != invalid.bits;
    }

    /// Returns the raw low 16 entry-index bits.
    ///
    /// For the invalid sentinel this returns `0xFFFF`, intentionally not the
    /// legacy `8191` result of `CBaseHandle::GetEntryIndex()`
    /// (`src/public/basehandle.h:137-154`). Use `entityIndex()` when the
    /// invalid-sentinel case should become null.
    pub fn rawIndex(self: EntityHandle) u16 {
        return @truncate(self.bits & entry_mask);
    }

    /// Returns the high 16 serial bits unchanged.
    ///
    /// The server may use only 15 meaningful bits and the network encoding only
    /// 10; do not truncate or validate the serial here.
    pub fn serial(self: EntityHandle) u16 {
        return @truncate(self.bits >> serial_shift);
    }

    /// Returns the full entity-list slot index, or null for the invalid
    /// sentinel or a raw index outside `NUM_ENT_ENTRIES`.
    ///
    /// The result may still be a non-networkable slot; use `edictIndex()` when
    /// only the networkable range is acceptable.
    pub fn entityIndex(self: EntityHandle) ?EntityIndex {
        if (!self.isValid()) return null;
        const raw = self.rawIndex();
        if (raw > EntityIndex.max_value) return null;
        return EntityIndex{ .value = raw };
    }

    /// Returns the networkable edict slot, or null when the handle is invalid,
    /// outside `NUM_ENT_ENTRIES`, or beyond `MAX_EDICTS`.
    pub fn edictIndex(self: EntityHandle) ?EdictIndex {
        const index = self.entityIndex() orelse return null;
        return index.toEdictIndex();
    }
};

comptime {
    if (@sizeOf(EntityHandle) != 4) @compileError("EntityHandle must stay 4 bytes");
}
