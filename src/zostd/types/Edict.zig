//! Opaque engine entity (`edict_t`).
//!
//! `edict_t` is a C++ class, not an integer (`src/public/edict.h:429-436`).
//! Its `CBaseEdict` base has a frozen layout note (`src/public/edict.h:164`),
//! but the numeric offsets in the deployed binary are not established by the
//! public headers. Do not lay out, construct, copy, or free this type.
//!
//! A pointer is a borrowed view of the engine's current slot occupant. It may
//! be null at callback boundaries. The slot can be freed and reused, so the
//! pointer is not a stable identity; use `EntityHandle` for that and resolve it
//! through the host.

pub const Edict = opaque {};

/// A borrowed `edict_t*`.
pub const EdictPtr = *Edict;

/// A borrowed `const edict_t*`, as used by `OnEdictFreed`.
pub const ConstEdictPtr = *const Edict;
