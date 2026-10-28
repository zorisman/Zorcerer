//! Opaque Source filesystem file handle (`FileHandle_t`).
//!
//! `FileHandle_t` is `void*` (`src/public/filesystem.h:38`). It is not a
//! `std.fs.File` and must be closed by the same engine filesystem that produced
//! it. A null handle is the failure result in practice; do not free the pointee
//! or perform pointer arithmetic on it.
//!
//! The engine filesystem owns the handle's lifetime. For `game://` content the
//! engine pathID/search-path model applies; `plugin://` content uses `std.Io`
//! instead (see `docs/references/source-sdk/filesystem.md` §12). Do not route a
//! handle across those domains.

pub const FileHandle = extern struct {
    /// Raw `void*`; null when opening failed.
    raw: ?*anyopaque,

    /// Returns whether the handle is null.
    pub fn isNull(self: FileHandle) bool {
        return self.raw == null;
    }
};

comptime {
    if (@sizeOf(FileHandle) != @sizeOf(?*anyopaque))
        @compileError("FileHandle must stay pointer-sized");
}
