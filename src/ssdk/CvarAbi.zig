//! Exact C ABI of the `ICvar` virtual used to read server cvars.
//!
//! The signature comes from `icvar.h` [checkout]. The declaration mirrors the
//! engine's compiled interface; no C++ method is called through a generated
//! wrapper.

const ConVar = @import("types/ConVar.zig").ConVar;
const Indexes = @import("zroot").ssdk.indexes;
const Vtable = @import("Vtable.zig");

/// `FCVAR_NEVER_AS_STRING` (iconvar.h:55 [checkout]).
///
/// A cvar with this flag stores its value only numerically; reading the string
/// field would report the flag name instead of a real value.
pub const cvar_never_as_string: c_int = 1 << 12;

/// The `ICvar` method the query handler calls.
///
/// `find_var` returns a pointer borrowed from the engine's cvar registry; the
/// caller reads its mirrored `ConVar` fields but must not retain the pointer.
pub const CvarAbi = struct {
    /// `FindVar` non-const overload (icvar.h:73, slot 12).
    find_var: *const fn (cvar: *anyopaque, name: [*:0]const u8) callconv(.c) ?*ConVar,

    /// Resolves `FindVar` from `interface`'s vtable.
    ///
    /// `interface` must be a live `ICvar` of the version named by the generated
    /// indexes. No runtime verification is performed here; the caller is
    /// responsible for checking the engine build before binding.
    pub fn bind(interface: *anyopaque) CvarAbi {
        return .{
            .find_var = @ptrCast(Vtable.slot(interface, Indexes.ICvar.find_var)),
        };
    }
};
