//! Source damage flag mask (`DMG_*`).
//!
//! Damage flags are a 32-bit bitmask (`src/game/shared/shareddefs.h:437-481`).
//! `DMG_GENERIC` is 0 and the named generic bits run through
//! `DMG_LASTGENERICFLAG` (`DMG_BUCKSHOT`, bit 29). The header warns against
//! adding more generic flags because mods depend on the existing range.
//!
//! Preserve the whole word. A plugin that only understands bits 0..29 must not
//! clear bits 30..31, which may be engine-specific or future flags.

pub const DamageMask = extern struct {
    /// Raw `DMG_*` bits.
    bits: u32,

    /// Returns whether any bit in `flags` is set in this mask.
    ///
    /// An empty mask (`bits == 0`) matches nothing, so this returns false.
    pub fn hasAny(self: DamageMask, flags: DamageMask) bool {
        return (self.bits & flags.bits) != 0;
    }
};

comptime {
    if (@sizeOf(DamageMask) != 4) @compileError("DamageMask must stay 4 bytes");
}
