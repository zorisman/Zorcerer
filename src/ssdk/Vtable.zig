//! Helpers for reading C++ virtual method pointers out of engine objects.
//!
//! The code generator records method slots but not signatures, so each caller
//! supplies the exact C ABI of the virtual it invokes. This module only
//! performs the two indirections shared by every binding: from the object to
//! its vtable, and from the vtable to one slot.

const std = @import("std");

/// Returns the raw function pointer stored at `slot` in `object`'s vtable.
///
/// `object` must be a live engine interface whose first field is a vtable
/// pointer, and `slot` must be the index recorded for the running engine build.
/// No validation is attempted here; callers are responsible for checking the
/// engine interface version before binding.
pub fn slot(object: *anyopaque, comptime index: usize) *const anyopaque {
    const interface: *const *const anyopaque = @ptrCast(@alignCast(object));
    const methods: [*]const *const anyopaque = @ptrCast(@alignCast(interface.*));
    return methods[index];
}
