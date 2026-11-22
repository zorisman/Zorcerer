const ConCommandBase = @import("ConCommandBase.zig").ConCommandBase;

/// The `ConVar` data layout needed to read a value (convar.h:318-452
/// [checkout]).
///
/// `ConVar` inherits `ConCommandBase` (primary base) and `IConVar` (secondary
/// base with its own vtable pointer). The value accessors are inline in C++
/// and read `m_pParent->m_pszString`/`m_fValue`/`m_nValue`, so the same fields
/// are mirrored here. A found cvar's `parent` is the root declaration; when it
/// is null the found object itself is used, matching the engine's invariant
/// that a registered cvar's parent is itself.
pub const ConVar = extern struct {
    /// `ConCommandBase` primary base.
    base: ConCommandBase,
    /// `IConVar` secondary vtable pointer.
    iconvar_vtable: *const anyopaque,
    /// `m_pParent`.
    parent: ?*ConVar,
    /// `m_pszDefaultValue`.
    default_value: ?[*:0]const u8,
    /// `m_pszString`.
    string_value: ?[*:0]const u8,
    /// `m_StringLength`.
    string_length: c_int,
    /// `m_fValue`.
    float_value: f32,
    /// `m_nValue`.
    int_value: c_int,
    /// `m_bHasMin`.
    has_min: bool,
    /// Padding before `m_fMinVal`.
    padding0: [3]u8,
    /// `m_fMinVal`.
    min_value: f32,
    /// `m_bHasMax`.
    has_max: bool,
    /// Padding before `m_fMaxVal`.
    padding1: [3]u8,
    /// `m_fMaxVal`.
    max_value: f32,
    /// Padding before `m_fnChangeCallback`.
    padding2: [4]u8,
    /// `m_fnChangeCallback`.
    change_callback: ?*const anyopaque,
    /// `m_bHasCompMin`.
    has_comp_min: bool,
    /// Padding before `m_fCompMinVal`.
    padding3: [3]u8,
    /// `m_fCompMinVal`.
    comp_min_value: f32,
    /// `m_bHasCompMax`.
    has_comp_max: bool,
    /// Padding before `m_fCompMaxVal`.
    padding4: [3]u8,
    /// `m_fCompMaxVal`.
    comp_max_value: f32,
    /// `m_bCompetitiveRestrictions`.
    competitive_restrictions: bool,
    /// Trailing padding to the struct's 8-byte alignment.
    padding5: [7]u8,
};

comptime {
    if (@offsetOf(ConVar, "parent") != 56) @compileError("ConVar.m_pParent moved");
    if (@offsetOf(ConVar, "string_value") != 72) @compileError("ConVar.m_pszString moved");
    if (@offsetOf(ConVar, "float_value") != 84) @compileError("ConVar.m_fValue moved");
    if (@offsetOf(ConVar, "int_value") != 88) @compileError("ConVar.m_nValue moved");
}
