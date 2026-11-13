//! Filesystem operations carried by `file.*` JSON-RPC methods.
//!
//! This module owns the mapping between an operation and its JSON-RPC
//! method name in both directions.

const std = @import("std");

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

    /// Returns the JSON-RPC method name for `self`.
    pub fn method(self: FileOperations) [:0]const u8 {
        return switch (self) {
            .open => "file.open",
            .close => "file.close",
            .read => "file.read",
            .write => "file.write",
            .seek => "file.seek",
            .tell => "file.tell",
            .size => "file.size",
            .flush => "file.flush",
            .remove => "file.remove",
            .find_open => "file.findOpen",
            .find_next => "file.findNext",
            .find_close => "file.findClose",
        };
    }

    /// Returns the operation named by a JSON-RPC method, or null.
    pub fn fromMethod(method_name: []const u8) ?FileOperations {
        inline for (std.meta.fields(FileOperations)) |field| {
            const op: FileOperations = @enumFromInt(field.value);
            if (std.mem.eql(u8, method_name, op.method())) return op;
        }
        return null;
    }
};
