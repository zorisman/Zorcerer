//! Engine-side implementation of the `game://` filesystem service.
//!
//! This file runs in the engine process. The forked plugin-manager child
//! forwards every `game://` request over the IPC channel; the handlers here
//! validate the URI, translate it into an engine name, and call the
//! `IFileSystem`/`IBaseFileSystem` virtuals the analyzer indexed
//! (src/codegen_generated/engine_indexes.zig).
//!
//! The child never receives an engine pointer. Handles are engine-process
//! integers that only mean something to this binding; the child wraps them in
//! its own per-plugin handle table.
//!
//! `game://` content is read-only by policy: open only accepts read mode,
//! writes and removals are refused before any engine call, and directory
//! enumeration goes through `IFileSystem`'s find session.

const std = @import("std");
const FileRequest = root.io.fs.FileRequest;
const FileResult = root.io.fs.FileResult;
const root = @import("zroot");
const Indexes = root.codegen.indexes;
const abi = @import("plugin-context");
const file_system = root.io.filesystem;

/// One engine file handle owned by this process.
const FileHandle = struct {
    /// The engine's `FileHandle_t` for the opened file.
    file: file_system.Handle,
};

/// One engine directory enumeration owned by this process.
///
/// `first_name` copies the first `FindFirstEx` result immediately because the
/// engine only keeps an entry name valid until the next find call.
const FindSession = struct {
    /// The engine's `FileFindHandle_t`, or `invalid_find_handle`.
    handle: file_system.FindHandle,
    /// First entry name captured at open.
    first_name: [file_system.max_engine_name_len]u8 = undefined,
    /// Number of valid bytes in `first_name`.
    first_name_len: usize = 0,
    /// Whether the first entry is a directory.
    first_is_directory: bool = false,
    /// Whether `first_name` still has to be reported.
    first_pending: bool = false,
};

/// The engine filesystem virtuals this binding calls.
///
/// The signatures mirror `IBaseFileSystem` (`public/filesystem.h`); the slot
/// indices are supplied by `Indexes.IBaseFileSystem` and are resolved from the
/// running engine's vtable at bind time.
const BaseOps = struct {
    /// `IBaseFileSystem::Read`.
    read: *const fn (*anyopaque, [*]u8, c_int, file_system.Handle) callconv(.c) c_int,
    /// `IBaseFileSystem::Write`.
    write: *const fn (*anyopaque, [*]const u8, c_int, file_system.Handle) callconv(.c) c_int,
    /// `IBaseFileSystem::Open`.
    open: *const fn (
        *anyopaque,
        [*:0]const u8,
        [*:0]const u8,
        ?[*:0]const u8,
    ) callconv(.c) ?file_system.Handle,
    /// `IBaseFileSystem::Close`.
    close: *const fn (*anyopaque, file_system.Handle) callconv(.c) void,
    /// `IBaseFileSystem::Seek`.
    seek: *const fn (*anyopaque, file_system.Handle, c_int, c_int) callconv(.c) void,
    /// `IBaseFileSystem::Tell`.
    tell: *const fn (*anyopaque, file_system.Handle) callconv(.c) c_uint,
    /// `IBaseFileSystem::Size` for an open handle.
    size: *const fn (*anyopaque, file_system.Handle) callconv(.c) c_uint,
    /// `IBaseFileSystem::Flush`.
    flush: *const fn (*anyopaque, file_system.Handle) callconv(.c) void,
};

/// The `IFileSystem` find-session virtuals this binding calls.
const FindOps = struct {
    /// `IFileSystem::FindFirstEx`.
    find_first_ex: *const fn (
        *anyopaque,
        [*:0]const u8,
        [*:0]const u8,
        *file_system.FindHandle,
    ) callconv(.c) ?[*:0]const u8,
    /// `IFileSystem::FindNext`.
    find_next: *const fn (*anyopaque, file_system.FindHandle) callconv(.c) ?[*:0]const u8,
    /// `IFileSystem::FindIsDirectory`.
    find_is_directory: *const fn (*anyopaque, file_system.FindHandle) callconv(.c) bool,
    /// `IFileSystem::FindClose`.
    find_close: *const fn (*anyopaque, file_system.FindHandle) callconv(.c) void,
};

/// Bound engine filesystem plus the handles the plugin-manager child opened
/// through it.
///
/// Invariants: `filesystem` is the `IFileSystem` object and `base` is the
/// `IBaseFileSystem` subobject of the same object. Both are process-resident
/// engine interfaces. Maps are initialized by `init()`; `deinit()` is
/// idempotent and closes every handle still open.
pub const Binding = struct {
    /// Allocator used for the handle tables and result documents.
    allocator: std.mem.Allocator,
    /// The `IFileSystem` object, or null while unbound.
    filesystem: ?*anyopaque = null,
    /// The `IBaseFileSystem` subobject, or null while unbound.
    base: ?*anyopaque = null,
    /// Resolved base virtuals, or null while unbound.
    base_ops: ?BaseOps = null,
    /// Resolved find virtuals, or null while unbound.
    find_ops: ?FindOps = null,
    /// Open file handles keyed by the ID the child received.
    handles: std.AutoHashMap(u64, FileHandle),
    /// Open find sessions keyed by the ID the child received.
    finds: std.AutoHashMap(u64, FindSession),
    /// Next handle ID; never zero.
    next_handle: u64 = 1,
    /// Whether the maps are initialized and may be used or deinitialized.
    maps_open: bool = false,

    /// Creates an unbound binding with initialized handle tables.
    pub fn init(allocator: std.mem.Allocator) Binding {
        return .{
            .allocator = allocator,
            .handles = std.AutoHashMap(u64, FileHandle).init(allocator),
            .finds = std.AutoHashMap(u64, FindSession).init(allocator),
            .maps_open = true,
        };
    }

    /// Binds the engine filesystem interfaces and resolves their virtuals.
    ///
    /// `filesystem` is the `VFileSystem022` answer (or null when the engine did
    /// not provide one). `base_interface` is the `VBaseFileSystem011` answer
    /// when the engine factory provides it; when null, the binding asks the
    /// `IFileSystem` `QueryInterface` slot first and falls back to the
    /// secondary subobject at offset `@sizeOf(*anyopaque)`.
    ///
    /// Errors: `error.FilesystemUnavailable` when `filesystem` is null.
    pub fn bind(
        self: *@This(),
        filesystem: ?*anyopaque,
        base_interface: ?*anyopaque,
    ) !void {
        self.deinit();

        const fs = filesystem orelse return error.FilesystemUnavailable;
        const base = base_interface orelse queryBase(fs) orelse secondaryBase(fs);

        if (!self.maps_open) {
            self.handles = std.AutoHashMap(u64, FileHandle).init(self.allocator);
            self.finds = std.AutoHashMap(u64, FindSession).init(self.allocator);
            self.maps_open = true;
        }

        self.filesystem = fs;
        self.base = base;
        self.base_ops = .{
            .read = @ptrCast(slot(base, Indexes.IBaseFileSystem.read)),
            .write = @ptrCast(slot(base, Indexes.IBaseFileSystem.write)),
            .open = @ptrCast(slot(base, Indexes.IBaseFileSystem.open)),
            .close = @ptrCast(slot(base, Indexes.IBaseFileSystem.close)),
            .seek = @ptrCast(slot(base, Indexes.IBaseFileSystem.seek)),
            .tell = @ptrCast(slot(base, Indexes.IBaseFileSystem.tell)),
            .size = @ptrCast(slot(base, Indexes.IBaseFileSystem.size)),
            .flush = @ptrCast(slot(base, Indexes.IBaseFileSystem.flush)),
        };
        self.find_ops = .{
            .find_first_ex = @ptrCast(slot(fs, Indexes.IFileSystem.find_first_ex)),
            .find_next = @ptrCast(slot(fs, Indexes.IFileSystem.find_next)),
            .find_is_directory = @ptrCast(slot(fs, Indexes.IFileSystem.find_is_directory)),
            .find_close = @ptrCast(slot(fs, Indexes.IFileSystem.find_close)),
        };
    }

    /// Closes every open file and find session and releases the handle tables.
    ///
    /// Safe to call more than once and on an unbound binding.
    pub fn deinit(self: *@This()) void {
        if (!self.maps_open) return;

        if (self.base_ops) |ops| {
            var handles = self.handles.valueIterator();
            while (handles.next()) |entry| {
                ops.close(self.base.?, entry.file);
            }
        }
        if (self.find_ops) |ops| {
            var finds = self.finds.valueIterator();
            while (finds.next()) |session| {
                if (session.handle != file_system.invalid_find_handle) {
                    ops.find_close(self.filesystem.?, session.handle);
                }
            }
        }

        self.handles.deinit();
        self.finds.deinit();
        self.maps_open = false;
        self.filesystem = null;
        self.base = null;
        self.base_ops = null;
        self.find_ops = null;
        self.next_handle = 1;
    }

    /// Executes one `game://` filesystem request from the plugin manager.
    ///
    /// Returns a JSON document describing an `FileResult`, allocated with
    /// `allocator` and owned by the caller. The result status distinguishes
    /// permission errors, missing handles, open failures, and transport-level
    /// failures without terminating the listener.
    pub fn handle(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: FileRequest,
    ) anyerror![]u8 {
        const self: *@This() = @ptrCast(@alignCast(context orelse return error.MissingContext));

        const ops = self.base_ops orelse
            return result(allocator, .{ .status = abi.file_unavailable });
        const find_ops = self.find_ops orelse
            return result(allocator, .{ .status = abi.file_unavailable });
        const filesystem = self.filesystem orelse
            return result(allocator, .{ .status = abi.file_unavailable });

        return switch (request.op) {
            .open => {
                if (request.mode != @intFromEnum(abi.FileMode.read)) {
                    return result(allocator, .{ .status = abi.file_permission_denied });
                }
                const name = engineName(request.path) orelse
                    return result(allocator, .{ .status = abi.file_permission_denied });
                if (name.len == 0) {
                    return result(allocator, .{ .status = abi.file_invalid_argument });
                }

                var name_buffer: [file_system.max_engine_name_len]u8 = undefined;
                const name_z = std.fmt.bufPrintZ(&name_buffer, "{s}", .{name}) catch
                    return result(allocator, .{ .status = abi.file_name_too_long });

                const file = ops.open(
                    self.base.?,
                    name_z.ptr,
                    "rb",
                    file_system.game_path_id,
                ) orelse return result(allocator, .{ .status = abi.file_open_failed });

                const id = self.allocateHandleId();
                self.handles.put(id, .{ .file = file }) catch {
                    ops.close(self.base.?, file);
                    return error.OutOfMemory;
                };
                return result(allocator, .{ .status = abi.file_ok, .handle = id });
            },
            .close => {
                const entry = self.handles.fetchRemove(request.handle) orelse
                    return result(allocator, .{ .status = abi.file_invalid_handle });
                ops.close(self.base.?, entry.value.file);
                return result(allocator, .{ .status = abi.file_ok });
            },
            .read => {
                const entry = self.handles.get(request.handle) orelse
                    return result(allocator, .{ .status = abi.file_invalid_handle });

                const wanted = @min(request.length, FileRequest.file_chunk_len);
                if (wanted == 0) return result(allocator, .{ .status = abi.file_ok });

                var buffer: [FileRequest.file_chunk_len]u8 = undefined;
                const bytes_read = ops.read(
                    self.base.?,
                    &buffer,
                    @intCast(wanted),
                    entry.file,
                );
                if (bytes_read < 0) {
                    return result(allocator, .{ .status = abi.file_io_error });
                }

                const count: usize = @intCast(bytes_read);
                if (count == 0) return result(allocator, .{ .status = abi.file_ok });

                const encoded_len = std.base64.standard.Encoder.calcSize(count);
                const encoded = try allocator.alloc(u8, encoded_len);
                defer allocator.free(encoded);
                const encoded_slice = std.base64.standard.Encoder.encode(
                    encoded,
                    buffer[0..count],
                );
                return result(allocator, .{
                    .status = abi.file_ok,
                    .data = encoded_slice,
                });
            },
            .write => result(allocator, .{ .status = abi.file_permission_denied }),
            .seek => {
                const entry = self.handles.get(request.handle) orelse
                    return result(allocator, .{ .status = abi.file_invalid_handle });
                const position = std.math.cast(c_int, request.offset) orelse
                    return result(allocator, .{ .status = abi.file_invalid_argument });
                const origin: file_system.SeekFrom = switch (request.origin) {
                    @intFromEnum(abi.FileSeekFrom.start) => .start,
                    @intFromEnum(abi.FileSeekFrom.current) => .current,
                    @intFromEnum(abi.FileSeekFrom.end) => .end,
                    else => return result(allocator, .{ .status = abi.file_invalid_argument }),
                };
                ops.seek(self.base.?, entry.file, position, @intFromEnum(origin));
                return result(allocator, .{ .status = abi.file_ok });
            },
            .tell => {
                const entry = self.handles.get(request.handle) orelse
                    return result(allocator, .{ .status = abi.file_invalid_handle });
                return result(allocator, .{
                    .status = abi.file_ok,
                    .value = ops.tell(self.base.?, entry.file),
                });
            },
            .size => {
                const entry = self.handles.get(request.handle) orelse
                    return result(allocator, .{ .status = abi.file_invalid_handle });
                return result(allocator, .{
                    .status = abi.file_ok,
                    .value = ops.size(self.base.?, entry.file),
                });
            },
            .flush => {
                const entry = self.handles.get(request.handle) orelse
                    return result(allocator, .{ .status = abi.file_invalid_handle });
                ops.flush(self.base.?, entry.file);
                return result(allocator, .{ .status = abi.file_ok });
            },
            .remove => result(allocator, .{ .status = abi.file_permission_denied }),
            .find_open => {
                const name = engineName(request.path) orelse
                    return result(allocator, .{ .status = abi.file_permission_denied });

                var wildcard_buffer: [file_system.max_engine_name_len + 2]u8 = undefined;
                const wildcard: [*:0]const u8 = if (name.len == 0)
                    "*"
                else
                    (std.fmt.bufPrintZ(&wildcard_buffer, "{s}/*", .{name}) catch
                        return result(allocator, .{ .status = abi.file_name_too_long })).ptr;

                var find_handle: file_system.FindHandle = file_system.invalid_find_handle;
                const first = find_ops.find_first_ex(
                    filesystem,
                    wildcard,
                    file_system.game_path_id,
                    &find_handle,
                );

                var session = FindSession{ .handle = find_handle };
                if (first) |first_name| {
                    const bytes = std.mem.span(first_name);
                    if (bytes.len > file_system.max_engine_name_len) {
                        if (find_handle != file_system.invalid_find_handle) {
                            find_ops.find_close(filesystem, find_handle);
                        }
                        return result(allocator, .{ .status = abi.file_name_too_long });
                    }
                    @memcpy(session.first_name[0..bytes.len], bytes);
                    session.first_name_len = bytes.len;
                    session.first_is_directory = find_ops.find_is_directory(
                        filesystem,
                        find_handle,
                    );
                    session.first_pending = true;
                }

                const id = self.allocateHandleId();
                self.finds.put(id, session) catch {
                    if (find_handle != file_system.invalid_find_handle) {
                        find_ops.find_close(filesystem, find_handle);
                    }
                    return error.OutOfMemory;
                };
                return result(allocator, .{ .status = abi.file_ok, .handle = id });
            },
            .find_next => {
                const session = self.finds.getPtr(request.handle) orelse
                    return result(allocator, .{ .status = abi.file_invalid_handle });

                if (session.first_pending) {
                    session.first_pending = false;
                    return result(allocator, .{
                        .status = abi.file_ok,
                        .name = session.first_name[0..session.first_name_len],
                        .is_directory = session.first_is_directory,
                    });
                }

                if (session.handle == file_system.invalid_find_handle) {
                    return result(allocator, .{ .status = abi.file_end, .done = true });
                }

                const found = find_ops.find_next(filesystem, session.handle) orelse
                    return result(allocator, .{ .status = abi.file_end, .done = true });
                const name = std.mem.span(found);
                if (name.len > file_system.max_engine_name_len) {
                    return result(allocator, .{ .status = abi.file_name_too_long });
                }

                return result(allocator, .{
                    .status = abi.file_ok,
                    .name = name,
                    .is_directory = find_ops.find_is_directory(filesystem, session.handle),
                });
            },
            .find_close => {
                const entry = self.finds.fetchRemove(request.handle) orelse
                    return result(allocator, .{ .status = abi.file_invalid_handle });
                if (entry.value.handle != file_system.invalid_find_handle) {
                    find_ops.find_close(filesystem, entry.value.handle);
                }
                return result(allocator, .{ .status = abi.file_ok });
            },
        };
    }

    /// Reserves and returns the next non-zero handle ID.
    ///
    /// The counter wraps at `maxInt(u64)` back to 1. Collisions would require
    /// 2^64 live handles and are not tracked separately.
    fn allocateHandleId(self: *@This()) u64 {
        const id = self.next_handle;
        self.next_handle +%= 1;
        if (self.next_handle == 0) self.next_handle = 1;
        return id;
    }
};

/// Serializes one filesystem result as a JSON document.
///
/// The returned slice is owned by the caller and freed with `allocator`.
///
/// Errors: `error.OutOfMemory` when serialization cannot allocate.
fn result(allocator: std.mem.Allocator, value: FileResult) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Returns the engine name addressed by a `game://` URI, or null when the URI
/// uses another scheme, contains a parent component, a backslash, or a NUL.
///
/// The returned slice aliases `path`; no normalization is needed because the
/// engine accepts `/`-separated names relative to pathID `GAME`.
fn engineName(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, file_system.game_scheme)) return null;
    const tail = std.mem.trimStart(u8, path[file_system.game_scheme.len..], "/");
    if (std.mem.indexOfScalar(u8, tail, 0) != null) return null;
    if (std.mem.indexOfScalar(u8, tail, '\\') != null) return null;

    var components = std.mem.splitScalar(u8, tail, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return null;
    }
    return tail;
}

/// Returns the function pointer at `index` of `interface`'s vtable.
///
/// Precondition: `index` names an existing virtual of the interface the
/// analyzer generated it for. This is the only place vtable slots are
/// dereferenced, and every index comes from `engine_indexes.zig`.
fn slot(interface: *anyopaque, index: usize) *const anyopaque {
    const vtable_pointer: *const [*]const *const anyopaque =
        @ptrCast(@alignCast(interface));
    const vtable = vtable_pointer.*;
    return vtable[index];
}

/// Asks `IFileSystem`'s `QueryInterface` virtual for `VBaseFileSystem011`.
///
/// Returns null when the engine does not answer the query.
fn queryBase(filesystem: *anyopaque) ?*anyopaque {
    const query_interface: *const fn (
        *anyopaque,
        [*:0]const u8,
    ) callconv(.c) ?*anyopaque = @ptrCast(
        slot(filesystem, Indexes.IFileSystem.query_interface),
    );

    var version_buffer: [64]u8 = undefined;
    const version = std.fmt.bufPrintZ(
        &version_buffer,
        "{s}",
        .{Indexes.basefilesystem_interface_version},
    ) catch return null;
    return query_interface(filesystem, version.ptr);
}

/// Returns the `IBaseFileSystem` subobject of an `IFileSystem` object.
///
/// `IFileSystem` has two polymorphic bases: `IAppSystem` at offset zero and
/// `IBaseFileSystem` at offset `@sizeOf(*anyopaque)` (both bases contain only
/// a vptr). The resulting pointer loads the secondary vtable, whose entries
/// adjust back to the complete object before calling the real methods.
fn secondaryBase(filesystem: *anyopaque) *anyopaque {
    const bytes: [*]u8 = @ptrCast(filesystem);
    return @ptrCast(bytes + @sizeOf(*anyopaque));
}

// --- Tests -------------------------------------------------------------------

test "engineName translates game:// tails and rejects escapes" {
    try std.testing.expectEqualStrings(
        "materials/readme.txt",
        engineName("game://materials/readme.txt").?,
    );
    try std.testing.expectEqualStrings("", engineName("game://").?);

    try std.testing.expect(engineName("plugin://note.txt") == null);
    try std.testing.expect(engineName("game://../escape") == null);
    try std.testing.expect(engineName("game://a/../../b") == null);
    try std.testing.expect(engineName("game://a\\b") == null);
}
