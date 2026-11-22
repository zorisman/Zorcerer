/// The public fields of `ConCommandBase` (convar.h:99-175 [checkout]).
///
/// Only the layout is mirrored; the virtual methods are never called through
/// this struct.
pub const ConCommandBase = extern struct {
    /// Primary vtable pointer.
    vtable: *const anyopaque,
    /// `m_pNext`.
    next: ?*ConCommandBase,
    /// `m_bRegistered`.
    registered: bool,
    /// Padding before the pointer-aligned name.
    padding0: [7]u8,
    /// `m_pszName`.
    name: ?[*:0]const u8,
    /// `m_pszHelpString`.
    help: ?[*:0]const u8,
    /// `m_nFlags`.
    flags: c_int,
    /// Padding to the 8-byte alignment of the `IConVar` base.
    padding1: [4]u8,
};

comptime {
    if (@offsetOf(ConCommandBase, "name") != 24) @compileError("ConCommandBase.m_pszName moved");
    if (@offsetOf(ConCommandBase, "flags") != 40) @compileError("ConCommandBase.m_nFlags moved");
}
