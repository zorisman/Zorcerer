const std = @import("std");

/// Binary layout of Source's `CCommand` (see `tier1/convar.h`).
///
/// The engine passes a reference to its own `CCommand` into `ClientCommand`.
/// This mirror exists only to read the tokenized command text without calling
/// C++ methods through the reference. The field names match the SDK's private
/// members to make the layout easy to audit; they are not a public API.
///
/// Invariants: `m_nArgc` is the number of parsed arguments, `m_nArgv0Size` is
/// the byte length of argument zero, and `m_pArgSBuffer` holds the full
/// NUL-terminated command line. `m_ppArgv` points into the two buffers and is
/// not used here. `commandText()` only reads the first `m_nArgc > 0` case.
pub const ClientCommand = extern struct {
    /// Number of tokenized arguments, including the command name.
    m_nArgc: c_int,
    /// Size of the command name in `m_pArgSBuffer`.
    m_nArgv0Size: c_int,
    /// Full command line, NUL-terminated by the engine.
    m_pArgSBuffer: [512]u8,
    /// Tokenized argument storage; unused by this mirror.
    m_pArgvBuffer: [512]u8,
    /// Pointers into `m_pArgvBuffer`; unused by this mirror.
    m_ppArgv: [64]?*const u8,

    /// Returns the full command line, excluding the terminating NUL.
    ///
    /// Returns null when the engine reported no arguments. The returned slice
    /// borrows the engine-owned `CCommand` and is valid only during the
    /// `ClientCommand` callback.
    pub fn commandText(self: *const @This()) ?[]const u8 {
        if (self.m_nArgc <= 0) return null;
        const text = std.mem.sliceTo(self.m_pArgSBuffer[0..], 0);
        if (text.len == 0) return null;
        return text;
    }
};
