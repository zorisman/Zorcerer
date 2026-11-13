/// Filesystem operations carried by `file.*` JSON-RPC methods.
pub const FileOperations = enum {
    /// Open a file.
    open,
    /// Close a file handle.
    close,
    /// Read from a file handle.
    read,
    /// Write to a file handle.
    write,
    /// Move a file handle's read/write pointer.
    seek,
    /// Read a file handle's current pointer.
    tell,
    /// Read a file handle's size.
    size,
    /// Flush a file handle's buffered data.
    flush,
    /// Delete a file.
    remove,
    /// Open a directory enumeration.
    find_open,
    /// Read the next directory entry.
    find_next,
    /// Close a directory enumeration.
    find_close,
};
