//! One filesystem result returned by the engine process.
//!
//! `status` is a `plugin-context.file_*` value. The remaining fields are
//! meaningful only when `status == file_ok`: `handle` for opens, `value` for
//! `tell`/`size`, `written` for writes, `data` for reads, and
//! `name`/`is_directory` for enumeration. `done` marks an exhausted
//! enumeration and is accompanied by `status == file_end`.

/// `plugin-context.file_*` status of the operation.
status: c_int = 0,
/// Newly opened file or enumeration handle.
handle: u64 = 0,
/// Position or size result.
value: u64 = 0,
/// Number of bytes accepted by a write.
written: usize = 0,
/// Base64-encoded bytes returned by a read.
data: []const u8 = "",
/// Next directory entry name.
name: []const u8 = "",
/// Whether the entry named by `name` is a directory.
is_directory: bool = false,
/// Whether the enumeration has no more entries.
done: bool = false,
