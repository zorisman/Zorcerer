//! Plugin-facing filesystem service used inside the forked plugin manager.
//!
//! Each native plugin and each Lua script receives its own `PluginFiles`
//! instance. It owns the plugin's `plugin://` root and a handle table, so a
//! handle opened by one plugin is never visible to another. `plugin://` I/O is
//! performed locally through `std.Io`; `game://` I/O is forwarded to the
//! engine process over the manager's IPC channel (see `EngineFilesystem.zig`)
//! and the child never touches an engine filesystem pointer.
//!
//! Handles are opaque non-zero integers valid only in the owning plugin's
//! table. `closeAll()` closes everything the plugin left open and is called
//! after its `unload()` hook returns, which keeps files usable during unload.

const std = @import("std");
const abi = @import("plugin-context");
const file_system = @import("zroot").io.filesystem;
const Ipc = @import("Ipc.zig");

/// Largest file `readAll()` loads into memory for the Lua bridge.
///
/// It matches `zostd.max_file_size`; larger files fail with
/// `error.FileTooLarge` instead of growing without bound.
pub const max_read_all_len: usize = 8 * 1024 * 1024;

/// Host-side filesystem service shared by every plugin in the manager
/// process.
///
/// The service resolves the plugin directory to an absolute root once, because
/// `HostFile`/`HostDirectory` perform absolute host I/O, and registers that
/// root with `file_system.setZorcererRoot()` so their under-root checks accept
/// per-plugin paths. The service must outlive every `PluginFiles` it creates.
pub const Service = struct {
    /// Allocator used for roots, handle tables, and IPC result documents.
    allocator: std.mem.Allocator,
    /// `std.Io` instance used for `plugin://` host I/O.
    io: std.Io,
    /// Child's end of the IPC channel, or null when no engine process is
    /// reachable (`game://` then reports `file_unavailable`).
    ipc_fd: ?std.os.linux.fd_t,
    /// Absolute path of the `plugins` directory, owned by the service.
    plugins_root: []u8,

    /// Resolves `plugins_directory` against the process working directory.
    ///
    /// `plugins_directory` may be relative (the manager's default) or already
    /// absolute. The resolved root is registered as the module-wide
    /// `plugin://` root and stays valid until `deinit()`.
    ///
    /// Errors: filesystem errors from resolving the working directory and
    /// `error.OutOfMemory` when joining the paths.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        ipc_fd: ?std.os.linux.fd_t,
        plugins_directory: []const u8,
    ) !Service {
        const plugins_root = try absolutePluginsRoot(allocator, io, plugins_directory);
        errdefer allocator.free(plugins_root);

        file_system.setZorcererRoot(plugins_root);
        return .{
            .allocator = allocator,
            .io = io,
            .ipc_fd = ipc_fd,
            .plugins_root = plugins_root,
        };
    }

    /// Clears the registered root and frees the service's storage.
    ///
    /// Every `PluginFiles` created by the service must have been destroyed
    /// first; `PluginManager.deinit()` enforces that by unloading plugins
    /// before releasing the service.
    pub fn deinit(self: *Service) void {
        file_system.setZorcererRoot("");
        self.allocator.free(self.plugins_root);
        self.plugins_root = &.{};
    }

    /// Creates the filesystem context for one plugin directory.
    ///
    /// `plugin_id` is the plugin's directory name. It must not be empty, `.`,
    /// `..`, or contain a path separator; invalid ids yield
    /// `error.InvalidPluginId` so a manifest can never escape the plugin root.
    ///
    /// The returned pointer is owned by the caller and released with
    /// `destroyPluginFiles()`.
    ///
    /// Errors: `error.InvalidPluginId`, `error.OutOfMemory`, and filesystem
    /// errors from joining the root.
    pub fn createPluginFiles(self: *Service, plugin_id: []const u8) !*PluginFiles {
        if (!validPluginId(plugin_id)) return error.InvalidPluginId;

        const allocator = self.allocator;
        const root = try std.Io.Dir.path.join(allocator, &.{ self.plugins_root, plugin_id });
        errdefer allocator.free(root);

        const files = try allocator.create(PluginFiles);
        errdefer allocator.destroy(files);

        files.* = .{
            .service = self,
            .root = root,
            .handles = std.AutoHashMap(u64, *Handle).init(allocator),
            .api = .{
                .struct_size = @sizeOf(abi.FileApi),
                .context = files,
                .open = apiOpen,
                .close = apiClose,
                .read = apiRead,
                .write = apiWrite,
                .seek = apiSeek,
                .tell = apiTell,
                .size = apiSize,
                .flush = apiFlush,
                .remove = apiRemove,
                .find_open = apiFindOpen,
                .find_next = apiFindNext,
                .find_close = apiFindClose,
            },
        };
        return files;
    }

    /// Closes every handle still open in `files` and releases it.
    pub fn destroyPluginFiles(self: *Service, files: *PluginFiles) void {
        files.deinit();
        self.allocator.destroy(files);
    }
};

/// Filesystem context of one plugin.
///
/// `api` is the ABI table handed to native plugins through
/// `PluginContext.files`; its `context` points back to this value. The Lua
/// bridge uses the same value directly through `Service` helpers. All fields
/// are owned by the manager and remain valid until `PluginManager` destroys the
/// context after the plugin's `unload()` returned.
pub const PluginFiles = struct {
    /// Service that owns the allocator and IPC channel.
    service: *Service,
    /// Absolute root directory for this plugin's `plugin://` URIs.
    root: []u8,
    /// Open handles owned by this plugin, keyed by the ABI-visible ID.
    handles: std.AutoHashMap(u64, *Handle),
    /// Next ABI-visible handle ID; never zero.
    next_handle: u64 = 1,
    /// ABI table handed to native plugin code.
    api: abi.FileApi,

    /// Closes every remaining handle and releases the handle table and root.
    ///
    /// Remote handles still receive a `close`/`findClose` request while the
    /// IPC channel is open; transport failures are ignored because teardown
    /// cannot report them.
    pub fn deinit(self: *PluginFiles) void {
        self.closeAll();
        self.handles.deinit();
        self.service.allocator.free(self.root);
        self.root = &.{};
    }

    /// Closes every open file and directory enumeration owned by the plugin.
    ///
    /// Host handles are closed directly; engine handles are closed through the
    /// still-open IPC channel. Idempotent: the table is emptied.
    pub fn closeAll(self: *PluginFiles) void {
        var handles = self.handles.valueIterator();
        while (handles.next()) |stored| {
            const handle = stored.*;
            switch (handle.*) {
                .host_file => |*file| file.close(),
                .host_directory => |*directory| directory.close(),
                .game_file => |remote| self.closeRemote(.{
                    .op = .close,
                    .handle = remote,
                }),
                .game_directory => |remote| self.closeRemote(.{
                    .op = .find_close,
                    .handle = remote,
                }),
            }
            self.service.allocator.destroy(handle);
        }
        self.handles.clearRetainingCapacity();
    }

    /// Reads a whole file through `openFile`/`read`.
    ///
    /// `path` may use either scheme; `game://` content is read-only. The
    /// returned bytes are allocated with `allocator` and owned by the caller.
    ///
    /// Errors: the status errors of `openFile`/`read`, `error.OutOfMemory`,
    /// and `error.FileTooLarge` when the file exceeds `max_read_all_len`.
    pub fn readAll(
        self: *PluginFiles,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) ![]u8 {
        var handle_id: u64 = 0;
        try self.openFile(path, .read, &handle_id);
        defer self.closeQuietly(handle_id);

        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);

        var buffer: [Ipc.file_chunk_len]u8 = undefined;
        while (true) {
            const count = try self.read(handle_id, &buffer);
            if (count == 0) break;
            if (bytes.items.len + count > max_read_all_len) return error.FileTooLarge;
            try bytes.appendSlice(allocator, buffer[0..count]);
        }
        return bytes.toOwnedSlice(allocator);
    }

    /// Writes `data` to a whole `plugin://` file.
    ///
    /// The file is created or truncated before writing. `game://` paths are
    /// refused with `error.PermissionDenied`.
    ///
    /// Errors: the status errors of `openFile`/`write`.
    pub fn writeAll(self: *PluginFiles, path: []const u8, data: []const u8) !void {
        var handle_id: u64 = 0;
        try self.openFile(path, .write, &handle_id);
        defer self.closeQuietly(handle_id);

        var written: usize = 0;
        while (written != data.len) {
            const count = try self.write(handle_id, data[written..]);
            if (count == 0) return error.WriteFailed;
            written += count;
        }
    }

    /// Opens a file and stores its ABI-visible handle in `out_handle`.
    ///
    /// `game://` only accepts `.read`; any write mode is refused with
    /// `error.PermissionDenied` before IPC traffic.
    ///
    /// Errors: `error.SchemeNotSupported`, `error.InvalidPath` for traversal
    /// or malformed tails, host open errors mapped by `hostStatus`, and the
    /// status errors of the remote engine call.
    fn openFile(
        self: *PluginFiles,
        path: []const u8,
        mode: abi.FileMode,
        out_handle: *u64,
    ) FileError!void {
        const parsed = try parsePath(path);
        switch (parsed.scheme) {
            .plugin => {
                const absolute = try self.resolvePlugin(parsed.tail);
                defer self.service.allocator.free(absolute);

                const target = file_system.ZorcererPath{
                    .absolute_path = absolute,
                    .permissions = file_system.read_write_permissions,
                    .scheme = .plugin,
                };
                const host_mode: file_system.Mode = switch (mode) {
                    .read => .read,
                    .write => .write,
                    .append => .append,
                };
                const file = file_system.HostFile.open(
                    self.service.io,
                    target,
                    host_mode,
                ) catch |err| return hostStatus(err);

                out_handle.* = try self.addHandle(.{ .host_file = file });
            },
            .game => {
                if (mode != .read) return error.PermissionDenied;

                var response = try self.remoteCall(.{
                    .op = .open,
                    .path = path,
                    .mode = @intFromEnum(mode),
                });
                defer response.deinit();
                try requireOk(response.value);

                out_handle.* = try self.addHandle(.{ .game_file = response.value.handle });
            },
        }
    }

    /// Closes one file handle.
    ///
    /// Errors: `error.InvalidHandle` when `handle` is unknown or names a
    /// directory enumeration, and transport errors while closing an engine
    /// handle.
    fn closeFile(self: *PluginFiles, handle: u64) FileError!void {
        const stored = try self.getHandle(handle);
        switch (stored.*) {
            .host_file => |*file| file.close(),
            .game_file => |remote| {
                var response = try self.remoteCall(.{ .op = .close, .handle = remote });
                defer response.deinit();
                try requireOk(response.value);
            },
            else => return error.InvalidHandle,
        }
        if (self.handles.fetchRemove(handle)) |entry| {
            self.service.allocator.destroy(entry.value);
        }
    }

    /// Closes a handle, ignoring every error. Used by whole-file helpers whose
    /// result already decides success.
    fn closeQuietly(self: *PluginFiles, handle: u64) void {
        self.closeFile(handle) catch {};
    }

    /// Reads from an open file into `destination`.
    ///
    /// Engine-backed reads are capped at `Ipc.file_chunk_len` and decoded from
    /// base64. Returns the number of bytes read; zero means end of file.
    ///
    /// Errors: `error.InvalidHandle`, host read errors mapped by `hostStatus`,
    /// and the status errors of the remote engine call.
    fn read(self: *PluginFiles, handle: u64, destination: []u8) FileError!usize {
        const stored = try self.getHandle(handle);
        return switch (stored.*) {
            .host_file => |*file| file.read(destination) catch |err| hostStatus(err),
            .game_file => |remote| {
                const wanted = @min(destination.len, Ipc.file_chunk_len);
                if (wanted == 0) return 0;

                var response = try self.remoteCall(.{
                    .op = .read,
                    .handle = remote,
                    .length = wanted,
                });
                defer response.deinit();
                try requireOk(response.value);

                if (response.value.data.len == 0) return 0;
                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(
                    response.value.data,
                ) catch return error.Transport;
                if (decoded_len > destination.len) return error.Transport;
                std.base64.standard.Decoder.decode(
                    destination[0..decoded_len],
                    response.value.data,
                ) catch return error.Transport;
                return decoded_len;
            },
            else => error.InvalidHandle,
        };
    }

    /// Writes `source` to an open `plugin://` file.
    ///
    /// `game://` handles are read-only and return `error.PermissionDenied`.
    ///
    /// Errors: `error.InvalidHandle`, `error.PermissionDenied`, and host write
    /// errors mapped by `hostStatus`.
    fn write(self: *PluginFiles, handle: u64, source: []const u8) FileError!usize {
        const stored = try self.getHandle(handle);
        return switch (stored.*) {
            .host_file => |*file| file.write(source) catch |err| hostStatus(err),
            .game_file => error.PermissionDenied,
            else => error.InvalidHandle,
        };
    }

    /// Moves an open file's read/write pointer.
    ///
    /// Engine seeks cannot report failure (the C virtual returns void); callers
    /// verify with `tell`.
    ///
    /// Errors: `error.InvalidHandle`, host seek errors mapped by `hostStatus`,
    /// and the status errors of the remote engine call.
    fn seek(
        self: *PluginFiles,
        handle: u64,
        offset: i64,
        origin: abi.FileSeekFrom,
    ) FileError!void {
        const stored = try self.getHandle(handle);
        switch (stored.*) {
            .host_file => |*file| {
                const host_origin: file_system.SeekFrom = switch (origin) {
                    .start => .start,
                    .current => .current,
                    .end => .end,
                };
                file.seek(offset, host_origin) catch |err| return hostStatus(err);
            },
            .game_file => |remote| {
                var response = try self.remoteCall(.{
                    .op = .seek,
                    .handle = remote,
                    .offset = offset,
                    .origin = @intFromEnum(origin),
                });
                defer response.deinit();
                try requireOk(response.value);
            },
            else => return error.InvalidHandle,
        }
    }

    /// Returns an open file's current read/write pointer.
    ///
    /// Errors: `error.InvalidHandle` and the status errors of the remote
    /// engine call.
    fn tell(self: *PluginFiles, handle: u64) FileError!usize {
        const stored = try self.getHandle(handle);
        return switch (stored.*) {
            .host_file => |*file| file.tell(),
            .game_file => |remote| {
                var response = try self.remoteCall(.{ .op = .tell, .handle = remote });
                defer response.deinit();
                try requireOk(response.value);
                return std.math.cast(usize, response.value.value) orelse error.IoFailed;
            },
            else => error.InvalidHandle,
        };
    }

    /// Returns an open file's size.
    ///
    /// Errors: `error.InvalidHandle`, host stat errors mapped by `hostStatus`,
    /// and the status errors of the remote engine call.
    fn size(self: *PluginFiles, handle: u64) FileError!usize {
        const stored = try self.getHandle(handle);
        return switch (stored.*) {
            .host_file => |*file| file.size() catch |err| hostStatus(err),
            .game_file => |remote| {
                var response = try self.remoteCall(.{ .op = .size, .handle = remote });
                defer response.deinit();
                try requireOk(response.value);
                return std.math.cast(usize, response.value.value) orelse error.IoFailed;
            },
            else => error.InvalidHandle,
        };
    }

    /// Flushes an open file's buffered data.
    ///
    /// Errors: `error.InvalidHandle`, host flush errors mapped by `hostStatus`,
    /// and the status errors of the remote engine call.
    fn flush(self: *PluginFiles, handle: u64) FileError!void {
        const stored = try self.getHandle(handle);
        switch (stored.*) {
            .host_file => |*file| file.flush() catch |err| return hostStatus(err),
            .game_file => |remote| {
                var response = try self.remoteCall(.{ .op = .flush, .handle = remote });
                defer response.deinit();
                try requireOk(response.value);
            },
            else => return error.InvalidHandle,
        }
    }

    /// Deletes a `plugin://` file without opening it.
    ///
    /// Errors: `error.PermissionDenied` for `game://` paths,
    /// `error.InvalidPath`, and host removal errors mapped by `hostStatus`.
    fn removeFile(self: *PluginFiles, path: []const u8) FileError!void {
        const parsed = try parsePath(path);
        if (parsed.scheme != .plugin) return error.PermissionDenied;

        const absolute = try self.resolvePlugin(parsed.tail);
        defer self.service.allocator.free(absolute);

        const target = file_system.ZorcererPath{
            .absolute_path = absolute,
            .permissions = file_system.read_write_permissions,
            .scheme = .plugin,
        };
        file_system.HostFile.remove(self.service.io, target) catch |err| return hostStatus(err);
    }

    /// Opens a directory enumeration and stores its ABI-visible handle.
    ///
    /// Errors: `error.SchemeNotSupported`, `error.InvalidPath`, host open
    /// errors mapped by `hostStatus`, and the status errors of the remote
    /// engine call.
    fn findOpen(self: *PluginFiles, path: []const u8, out_handle: *u64) FileError!void {
        const parsed = try parsePath(path);
        switch (parsed.scheme) {
            .plugin => {
                const absolute = try self.resolvePlugin(parsed.tail);
                defer self.service.allocator.free(absolute);

                const target = file_system.ZorcererPath{
                    .absolute_path = absolute,
                    .permissions = file_system.read_write_permissions,
                    .scheme = .plugin,
                };
                const directory = file_system.HostDirectory.open(
                    self.service.io,
                    target,
                ) catch |err| return hostStatus(err);

                out_handle.* = try self.addHandle(.{ .host_directory = directory });
            },
            .game => {
                var response = try self.remoteCall(.{
                    .op = .find_open,
                    .path = path,
                });
                defer response.deinit();
                try requireOk(response.value);

                out_handle.* = try self.addHandle(.{
                    .game_directory = response.value.handle,
                });
            },
        }
    }

    /// Copies the next directory entry name and reports its directory flag.
    ///
    /// `out_len` receives the name length, or the required capacity when it
    /// does not fit `destination`. Returns `error.End` when the enumeration is
    /// exhausted and `error.NameTooLong` on a short buffer.
    ///
    /// Errors: `error.InvalidHandle`, `error.End`, `error.NameTooLong`, host
    /// iteration errors mapped by `hostStatus`, and the status errors of the
    /// remote engine call.
    fn findNext(
        self: *PluginFiles,
        handle: u64,
        destination: []u8,
        out_len: *usize,
        out_is_directory: *u8,
    ) FileError!void {
        const stored = try self.getHandle(handle);
        switch (stored.*) {
            .host_directory => |*directory| {
                const entry = directory.next(destination) catch |err| return hostStatus(err);
                const found = entry orelse return error.End;
                out_len.* = found.name.len;
                out_is_directory.* = @intFromBool(found.is_directory);
            },
            .game_directory => |remote| {
                var response = try self.remoteCall(.{
                    .op = .find_next,
                    .handle = remote,
                });
                defer response.deinit();
                if (response.value.status == abi.file_end) return error.End;
                if (response.value.status != abi.file_ok) {
                    return statusError(response.value.status);
                }

                out_len.* = response.value.name.len;
                if (response.value.name.len > destination.len) return error.NameTooLong;
                @memcpy(destination[0..response.value.name.len], response.value.name);
                out_is_directory.* = @intFromBool(response.value.is_directory);
            },
            else => return error.InvalidHandle,
        }
    }

    /// Ends one directory enumeration.
    ///
    /// Errors: `error.InvalidHandle` when `handle` is unknown or names a file,
    /// and transport errors while closing an engine enumeration.
    fn findClose(self: *PluginFiles, handle: u64) FileError!void {
        const stored = try self.getHandle(handle);
        switch (stored.*) {
            .host_directory => |*directory| directory.close(),
            .game_directory => |remote| {
                var response = try self.remoteCall(.{
                    .op = .find_close,
                    .handle = remote,
                });
                defer response.deinit();
                try requireOk(response.value);
            },
            else => return error.InvalidHandle,
        }
        if (self.handles.fetchRemove(handle)) |entry| {
            self.service.allocator.destroy(entry.value);
        }
    }

    /// Registers `handle` under a fresh ABI-visible ID.
    ///
    /// The value is heap-allocated so its address stays stable while the hash
    /// map grows; the ID is never zero.
    ///
    /// Errors: `error.OutOfMemory`.
    fn addHandle(self: *PluginFiles, handle: Handle) FileError!u64 {
        const allocator = self.service.allocator;
        const stored = allocator.create(Handle) catch return error.OutOfMemory;
        stored.* = handle;

        const id = self.next_handle;
        self.next_handle +%= 1;
        if (self.next_handle == 0) self.next_handle = 1;

        self.handles.put(id, stored) catch {
            allocator.destroy(stored);
            return error.OutOfMemory;
        };
        return id;
    }

    /// Returns the stored handle for `id`.
    ///
    /// Errors: `error.InvalidHandle` when the plugin does not own `id`.
    fn getHandle(self: *PluginFiles, id: u64) FileError!*Handle {
        return self.handles.get(id) orelse error.InvalidHandle;
    }

    /// Resolves a `plugin://` tail against this plugin's root.
    ///
    /// The caller owns the returned absolute path and frees it with the
    /// service allocator.
    ///
    /// Errors: `error.OutOfMemory`.
    fn resolvePlugin(self: *PluginFiles, tail: []const u8) FileError![]u8 {
        const allocator = self.service.allocator;
        if (tail.len == 0) return allocator.dupe(u8, self.root) catch error.OutOfMemory;
        return std.Io.Dir.path.join(allocator, &.{ self.root, tail }) catch error.OutOfMemory;
    }

    /// Sends one request to the engine process and reads its result.
    ///
    /// The returned document borrows its parsed JSON until `deinit()`.
    ///
    /// Errors: `error.Unavailable` without an IPC channel,
    /// `error.Transport` for framing, JSON, and JSON-RPC failures.
    fn remoteCall(self: *PluginFiles, request: Ipc.FileRequest) FileError!std.json.Parsed(Ipc.FileResult) {
        const fd = self.service.ipc_fd orelse return error.Unavailable;
        Ipc.sendFileRequest(fd, request) catch return error.Transport;
        return Ipc.receiveFileResult(fd, self.service.allocator) catch return error.Transport;
    }

    /// Sends a close request and ignores the result.
    fn closeRemote(self: *PluginFiles, request: Ipc.FileRequest) void {
        var response = self.remoteCall(request) catch return;
        response.deinit();
    }
};

/// One open handle owned by a plugin.
const Handle = union(enum) {
    /// `plugin://` file opened through `std.Io`.
    host_file: file_system.HostFile,
    /// `plugin://` directory enumeration opened through `std.Io`.
    host_directory: file_system.HostDirectory,
    /// `game://` file handle owned by the engine process.
    game_file: u64,
    /// `game://` directory enumeration owned by the engine process.
    game_directory: u64,
};

/// `FileApi` statuses, restricted to the errors this module reports.
const FileError = error{
    /// No IPC channel or engine filesystem binding.
    Unavailable,
    /// The request cannot be performed under the `game://` write policy or
    /// escapes the plugin root.
    PermissionDenied,
    /// The engine-process transport failed.
    Transport,
    /// The file or directory does not exist.
    NotFound,
    /// The backend refused an open.
    OpenFailed,
    /// An I/O operation after a successful open failed.
    IoFailed,
    /// The handle is unknown or has the wrong kind.
    InvalidHandle,
    /// An argument is malformed.
    InvalidArgument,
    /// A name does not fit the caller's buffer.
    NameTooLong,
    /// The directory enumeration is exhausted.
    End,
    /// Allocation failed.
    OutOfMemory,
    /// The path uses no supported URI scheme.
    SchemeNotSupported,
    /// The path contains a parent component or another unsafe element.
    InvalidPath,
};

/// A parsed `plugin://` or `game://` URI.
const ParsedPath = struct {
    /// Backend selected by the URI prefix.
    scheme: Scheme,
    /// Path relative to the scheme's root.
    tail: []const u8,
};

/// Backend selected by a URI prefix.
const Scheme = enum {
    /// The calling plugin's own directory; read/write host I/O.
    plugin,
    /// The running game's mod directory; read-only engine I/O.
    game,
};

/// Parses a plugin URI and rejects traversal and malformed tails.
///
/// Errors: `error.SchemeNotSupported` for other schemes and
/// `error.InvalidPath` for `..` components, backslashes, or embedded NULs.
fn parsePath(path: []const u8) FileError!ParsedPath {
    if (std.mem.startsWith(u8, path, file_system.plugin_scheme)) {
        const tail = std.mem.trimStart(u8, path[file_system.plugin_scheme.len..], "/");
        try validateTail(tail);
        return .{ .scheme = .plugin, .tail = tail };
    }
    if (std.mem.startsWith(u8, path, file_system.game_scheme)) {
        const tail = std.mem.trimStart(u8, path[file_system.game_scheme.len..], "/");
        try validateTail(tail);
        return .{ .scheme = .game, .tail = tail };
    }
    return error.SchemeNotSupported;
}

/// Rejects parent traversal, backslashes, and embedded NULs in a URI tail.
fn validateTail(tail: []const u8) FileError!void {
    if (std.mem.indexOfScalar(u8, tail, 0) != null) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, tail, '\\') != null) return error.InvalidPath;

    var components = std.mem.splitScalar(u8, tail, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.InvalidPath;
    }
}

/// Converts a host-backend failure into the shared `FileError` set.
fn hostStatus(err: anyerror) FileError {
    return switch (err) {
        error.PermissionDenied, error.OperationNotAllowed => error.PermissionDenied,
        error.OpenFailed => error.OpenFailed,
        error.NameTooLong => error.NameTooLong,
        error.ReadFailed,
        error.WriteFailed,
        error.SeekFailed,
        error.PositionOverflow,
        error.SizeFailed,
        error.FlushFailed,
        error.RemoveFailed,
        error.IoFailed,
        => error.IoFailed,
        else => error.IoFailed,
    };
}

/// Converts an engine-process status into the shared `FileError` set.
fn statusError(status: c_int) FileError {
    return switch (status) {
        abi.file_unavailable => error.Unavailable,
        abi.file_transport_error => error.Transport,
        abi.file_permission_denied => error.PermissionDenied,
        abi.file_not_found => error.NotFound,
        abi.file_open_failed => error.OpenFailed,
        abi.file_io_error => error.IoFailed,
        abi.file_invalid_handle => error.InvalidHandle,
        abi.file_invalid_argument => error.InvalidArgument,
        abi.file_name_too_long => error.NameTooLong,
        abi.file_end => error.End,
        else => error.Transport,
    };
}

/// Returns the ABI status for `err`.
fn statusOf(err: FileError) c_int {
    return switch (err) {
        error.Unavailable => abi.file_unavailable,
        error.PermissionDenied => abi.file_permission_denied,
        error.Transport => abi.file_transport_error,
        error.NotFound => abi.file_not_found,
        error.OpenFailed => abi.file_open_failed,
        error.IoFailed => abi.file_io_error,
        error.InvalidHandle => abi.file_invalid_handle,
        error.InvalidArgument => abi.file_invalid_argument,
        error.NameTooLong => abi.file_name_too_long,
        error.End => abi.file_end,
        error.OutOfMemory => abi.file_io_error,
        error.SchemeNotSupported, error.InvalidPath => abi.file_permission_denied,
    };
}

/// Fails with the status carried by an engine result unless it is `file_ok`.
fn requireOk(value: Ipc.FileResult) FileError!void {
    if (value.status == abi.file_ok) return;
    return statusError(value.status);
}

/// Validates a plugin directory name before joining it under the plugin root.
fn validPluginId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    if (std.mem.indexOfScalar(u8, id, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, id, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, id, '\\') != null) return false;
    return true;
}

/// Resolves `plugins_directory` against the process working directory.
///
/// `std.Io.Dir.cwd().realPath()` asks procfs for `AT_FDCWD`, which Linux does
/// not expose, so the working directory is opened as a real handle first.
///
/// Errors: filesystem errors from opening and resolving the working directory
/// and `error.OutOfMemory` when joining the paths.
fn absolutePluginsRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    plugins_directory: []const u8,
) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(plugins_directory)) {
        return allocator.dupe(u8, plugins_directory);
    }

    const cwd_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer cwd_dir.close(io);

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try cwd_dir.realPath(io, &cwd_buffer);
    return std.Io.Dir.path.join(allocator, &.{ cwd_buffer[0..cwd_len], plugins_directory });
}

/// Returns the plugin context behind an ABI `context` pointer.
fn pluginFiles(raw: ?*anyopaque) ?*PluginFiles {
    const context = raw orelse return null;
    return @ptrCast(@alignCast(context));
}

/// `FileApi.open` implementation.
fn apiOpen(
    raw: ?*anyopaque,
    path: abi.Text,
    mode: abi.FileMode,
    out_handle: *u64,
) callconv(.c) c_int {
    const self = pluginFiles(raw) orelse return abi.file_unavailable;
    out_handle.* = 0;
    self.openFile(path.slice(), mode, out_handle) catch |err| return statusOf(err);
    return abi.file_ok;
}

/// `FileApi.close` implementation.
fn apiClose(raw: ?*anyopaque, handle: u64) callconv(.c) c_int {
    const self = pluginFiles(raw) orelse return abi.file_unavailable;
    self.closeFile(handle) catch |err| return statusOf(err);
    return abi.file_ok;
}

/// `FileApi.read` implementation.
fn apiRead(
    raw: ?*anyopaque,
    handle: u64,
    destination: [*]u8,
    destination_len: usize,
) callconv(.c) isize {
    const self = pluginFiles(raw) orelse return -@as(isize, abi.file_unavailable);
    const count = self.read(handle, destination[0..destination_len]) catch |err|
        return -@as(isize, statusOf(err));
    return @intCast(count);
}

/// `FileApi.write` implementation.
fn apiWrite(
    raw: ?*anyopaque,
    handle: u64,
    source: [*]const u8,
    source_len: usize,
) callconv(.c) isize {
    const self = pluginFiles(raw) orelse return -@as(isize, abi.file_unavailable);
    const count = self.write(handle, source[0..source_len]) catch |err|
        return -@as(isize, statusOf(err));
    return @intCast(count);
}

/// `FileApi.seek` implementation.
fn apiSeek(
    raw: ?*anyopaque,
    handle: u64,
    offset: i64,
    origin: abi.FileSeekFrom,
) callconv(.c) c_int {
    const self = pluginFiles(raw) orelse return abi.file_unavailable;
    self.seek(handle, offset, origin) catch |err| return statusOf(err);
    return abi.file_ok;
}

/// `FileApi.tell` implementation.
fn apiTell(raw: ?*anyopaque, handle: u64, out_offset: *u64) callconv(.c) c_int {
    const self = pluginFiles(raw) orelse return abi.file_unavailable;
    out_offset.* = 0;
    const offset = self.tell(handle) catch |err| return statusOf(err);
    out_offset.* = @intCast(offset);
    return abi.file_ok;
}

/// `FileApi.size` implementation.
fn apiSize(raw: ?*anyopaque, handle: u64, out_size: *u64) callconv(.c) c_int {
    const self = pluginFiles(raw) orelse return abi.file_unavailable;
    out_size.* = 0;
    const size = self.size(handle) catch |err| return statusOf(err);
    out_size.* = @intCast(size);
    return abi.file_ok;
}

/// `FileApi.flush` implementation.
fn apiFlush(raw: ?*anyopaque, handle: u64) callconv(.c) c_int {
    const self = pluginFiles(raw) orelse return abi.file_unavailable;
    self.flush(handle) catch |err| return statusOf(err);
    return abi.file_ok;
}

/// `FileApi.remove` implementation.
fn apiRemove(raw: ?*anyopaque, path: abi.Text) callconv(.c) c_int {
    const self = pluginFiles(raw) orelse return abi.file_unavailable;
    self.removeFile(path.slice()) catch |err| return statusOf(err);
    return abi.file_ok;
}

/// `FileApi.find_open` implementation.
fn apiFindOpen(
    raw: ?*anyopaque,
    path: abi.Text,
    out_handle: *u64,
) callconv(.c) c_int {
    const self = pluginFiles(raw) orelse return abi.file_unavailable;
    out_handle.* = 0;
    self.findOpen(path.slice(), out_handle) catch |err| return statusOf(err);
    return abi.file_ok;
}

/// `FileApi.find_next` implementation.
fn apiFindNext(
    raw: ?*anyopaque,
    handle: u64,
    name: [*]u8,
    name_len: usize,
    out_len: *usize,
    out_is_directory: *u8,
) callconv(.c) c_int {
    const self = pluginFiles(raw) orelse return abi.file_unavailable;
    out_len.* = 0;
    out_is_directory.* = 0;
    self.findNext(handle, name[0..name_len], out_len, out_is_directory) catch |err|
        return statusOf(err);
    return abi.file_ok;
}

/// `FileApi.find_close` implementation.
fn apiFindClose(raw: ?*anyopaque, handle: u64) callconv(.c) c_int {
    const self = pluginFiles(raw) orelse return abi.file_unavailable;
    self.findClose(handle) catch |err| return statusOf(err);
    return abi.file_ok;
}

// --- Tests -------------------------------------------------------------------

test "parsePath accepts both schemes and rejects traversal" {
    const plugin = try parsePath("plugin://nested/file.txt");
    try std.testing.expectEqual(Scheme.plugin, plugin.scheme);
    try std.testing.expectEqualStrings("nested/file.txt", plugin.tail);

    const game = try parsePath("game://materials");
    try std.testing.expectEqual(Scheme.game, game.scheme);
    try std.testing.expectEqualStrings("materials", game.tail);

    try std.testing.expectError(error.InvalidPath, parsePath("plugin://../escape"));
    try std.testing.expectError(error.InvalidPath, parsePath("game://a/../../b"));
    try std.testing.expectError(error.SchemeNotSupported, parsePath("http://example.com"));
}

test "validPluginId rejects separators and traversal" {
    try std.testing.expect(validPluginId("hello"));
    try std.testing.expect(!validPluginId(""));
    try std.testing.expect(!validPluginId("."));
    try std.testing.expect(!validPluginId(".."));
    try std.testing.expect(!validPluginId("a/b"));
    try std.testing.expect(!validPluginId("a\\b"));
}

test "plugin files read, write, and remove inside their own root" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const plugins_root = path_buffer[0..root_len];

    var hello_dir = try tmp.dir.createDirPathOpen(io, "hello", .{});
    hello_dir.close(io);

    const saved_root = file_system.zorcerer_root;
    var service = try Service.init(std.testing.allocator, io, null, plugins_root);
    defer {
        service.deinit();
        file_system.zorcerer_root = saved_root;
    }
    const files = try service.createPluginFiles("hello");
    defer service.destroyPluginFiles(files);

    try files.writeAll("plugin://note.txt", "hello filesystem");
    const data = try files.readAll(std.testing.allocator, "plugin://note.txt");
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("hello filesystem", data);

    // `game://` has no IPC channel here, so writes must be refused before any
    // transport is attempted.
    try std.testing.expectError(
        error.PermissionDenied,
        files.writeAll("game://note.txt", "x"),
    );
    try std.testing.expectError(
        error.InvalidPath,
        files.readAll(std.testing.allocator, "plugin://../escape"),
    );

    try files.removeFile("plugin://note.txt");
    try std.testing.expectError(
        error.OpenFailed,
        files.readAll(std.testing.allocator, "plugin://note.txt"),
    );
}
