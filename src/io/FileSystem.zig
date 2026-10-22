//! Host-side filesystem plumbing for plugins: it converts the virtual
//! `game://` and `plugin://` URI schemes into validated absolute paths, each
//! carrying the permission set the host is willing to grant for the
//! referenced location.
//!
//! All actual I/O of this module goes through the Source Engine filesystem
//! (`IFileSystem`/`IBaseFileSystem`, see
//! docs/references/source-sdk/filesystem.md): the engine resolves names via
//! its search paths and pack files (VPKs), so files are not touched through
//! the shell. The engine binding is handed to the module as an interface
//! pointer plus explicitly resolved ABI method pointers (see
//! `SourceFilesystem`); vtable slot indices are *not* hardcoded here; slot
//! resolution belongs to binary verification
//! (docs/references/source-sdk/filesystem.md §10.2).

const std = @import("std");

const PluginConfiguration = @import("plugin-configuration").PluginConfiguration;

/// URI scheme prefix targeting the running game's `tf` directory; the path
/// tail is relative to that directory.
pub const game_scheme = "game://";
/// URI scheme prefix targeting the calling plugin's own root directory; the
/// path tail is relative to that directory.
pub const plugin_scheme = "plugin://";

/// The kinds of access a plugin can request for a validated `ZorcererPath`.
pub const Permission = enum {
    /// Reading the path's content.
    read,
    /// Mutating the path's content.
    write,
    /// Executing the path.
    execute,
};

/// A validated, host-resolved file location.
///
/// Invariant: `absolute_path` is an absolute filesystem path that resulted
/// from prefixing a `game://` or `plugin://` URI with the matching
/// configured root directory, and `permissions` describes the access the
/// host permits for that path.
///
/// Slices: `absolute_path` is allocated inside this module's arena and
/// remains valid for the rest of the process' lifetime, see
/// `parsePath()`'s documentation.
pub const ZorcererPath = struct {
    /// Absolute filesystem location the URI referenced.
    absolute_path: []const u8,
    /// Permissions the host allows for `absolute_path`.
    permissions: std.Io.File.Permissions,
};

/// Placeholder for the runtime context of the plugin that performs the
/// filesystem query.
///
/// Warning: this is a temporary stand-in; the project already ships
/// `src/PluginContext.zig` as the plugin ABI contract, and this placeholder
/// is expected to be replaced by (or merged with) a full host-side runtime
/// context once that side of the ABI is fleshed out.
pub const PluginContext = struct {
    /// Configuration of the plugin making the query, as loaded from its
    /// manifest (see `PluginConfiguration`).
    config: PluginConfiguration,
};

/// Absolute path to the `tf` directory backing `game://` URIs, or `null`
/// while unconfigured. Must be set with `setGameRoot()` before
/// `parsePath()` encounters a `game://` URI. The pointer must remain valid
/// for as long as any caller may still observe a `ZorcererPath` derived
/// from it.
pub var game_root: ?[]const u8 = null;

/// Absolute path to this Zorcerer installation's root directory (the parent
/// of `plugins/`) backing `plugin://` URIs, or `null` while unconfigured.
/// Must be set with `setZorcererRoot()` before `parsePath()` encounters a
/// `plugin://` URI. The pointer must remain valid for as long as any caller
/// may still observe a `ZorcererPath` derived from it.
pub var zorcerer_root: ?[]const u8 = null;

/// Arena holding all path allocations of `parsePath()`; intentionally
/// never deinitialized so resolved paths stay valid for the process'
/// lifetime. Plugin roots are resolved once at startup, so the cost is
/// bounded by the number of resolved URIs.
var path_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// Permissions granted for `game://` paths: read-only for every class
/// (read only, no write, no execute bits).
pub const read_only_permissions: std.Io.File.Permissions =
    std.Io.File.Permissions.fromMode(0o444);

/// Permissions granted for `plugin://` paths: read and write for the owner
/// only (read and write only, no execute bits).
pub const read_write_permissions: std.Io.File.Permissions =
    std.Io.File.Permissions.fromMode(0o600);

/// The permission class bits checked by `checkPermission()`; a request is
/// granted when at least one permission class holds the requested bit.
fn requestedBit(requested: Permission) std.posix.mode_t {
    return switch (requested) {
        .read => 0o444,
        .write => 0o222,
        .execute => 0o111,
    };
}

/// Checks whether the allowed permission set of a validated path (see
/// `ZorcererPath.permissions`) covers the requested kind of access. The
/// request is granted when at least one permission class holds the
/// requested bit, since a host permitting a class already intends to allow
/// access through it.
///
/// Returns nothing if the request is allowed, or
/// `error.PermissionDenied` if no permission class grants the requested
/// access to `path`.
pub fn checkPermission(
    path: ZorcererPath,
    requested: Permission,
) error{PermissionDenied}!void {
    if (path.permissions.toMode() & requestedBit(requested) == 0) {
        return error.PermissionDenied;
    }
}

/// Configures the root directory resolving `game://` URIs.
///
/// The caller owns `path` and must guarantee it outlives every
/// `ZorcererPath` that may be derived from it (static or process-lifetime
/// strings are the expected input).
pub fn setGameRoot(path: []const u8) void {
    game_root = path;
}

/// Configures the root directory resolving `plugin://` URIs; this is the
/// root of the Zorcerer installation, the parent of `plugins/`.
///
/// The caller owns `path` and must guarantee it outlives every
/// `ZorcererPath` that may be derived from it (static or process-lifetime
/// strings are the expected input).
pub fn setZorcererRoot(path: []const u8) void {
    zorcerer_root = path;
}

/// Parses a `game://` or `plugin://` URI into a validated, permission-tagged
/// absolute path.
///
/// - `"game://<tail>"` resolves `<tail>` against the configured `tf`
///   directory (see `setGameRoot`); read-only.
/// - `"plugin://<tail>"` resolves `<tail>` against the calling plugin's
///   root directory, which is derived from the directory component of
///   `ctx.config.lib_path` underneath the configured Zorcerer root (see
///   `setZorcererRoot`); read and write, no execute.
/// - Any other URI format is not a supported scheme.
///
/// Parameters:
/// - `ctx`: the query's plugin context; `config.lib_path` determines the
///   plugin root for `plugin://` URIs.
/// - `path`: the raw URI as forwarded by a plugin.
///
/// Returns the validated `ZorcererPath`, or:
/// - `error.OperationNotAllowed` if the URI does not start with a supported
///   scheme prefix, if a URI tail contains a `..` path component (parent
///   traversal), or if the plugin's `lib_path` does not contain a directory
///   component (so no plugin root can be derived).
/// - `error.RootNotConfigured` if the requested scheme's root directory has
///   not been configured yet.
/// - `error.OutOfMemory` for path allocation failures.
///
/// Side effects: every successful call allocates inside this module's
/// arena, which is intentionally never released, so the returned
/// `absolute_path` stays valid for the process' lifetime. Because the
/// arena only grows, this module is only used for the bounded number of
/// path resolutions performed during startup.
pub fn parsePath(ctx: *PluginContext, path: []const u8) !ZorcererPath {
    const alloc = path_arena.allocator();

    // `game://` targets the game's `tf` directory and is read-only.
    if (std.mem.startsWith(u8, path, game_scheme)) {
        const root = game_root orelse return error.RootNotConfigured;
        return ZorcererPath{
            .absolute_path = try joinRelativeParts(alloc, root, &.{path[game_scheme.len..]}),
            .permissions = read_only_permissions,
        };
    }

    // `plugin://` targets the calling plugin's own directory and is
    // read/write only.
    if (std.mem.startsWith(u8, path, plugin_scheme)) {
        const root = zorcerer_root orelse return error.RootNotConfigured;
        const lib_directory = std.Io.Dir.path.dirname(ctx.config.lib_path) orelse
            return error.OperationNotAllowed;
        return ZorcererPath{
            .absolute_path = try joinRelativeParts(alloc, root, &.{
                lib_directory,
                path[plugin_scheme.len..],
            }),
            .permissions = read_write_permissions,
        };
    }

    return error.OperationNotAllowed;
}

/// Joins `root` with the given slash-prefixed-or-bare relative path parts.
/// Leading `/` characters of each part are treated as the scheme separator
/// boundary, not as a root switch, so they are stripped; empty parts are
/// skipped. Any part containing a `..` component is rejected so the result
/// can never escape the configured root.
///
/// Returns the joined path, or:
/// - `error.OutOfMemory` on allocation failure.
/// - `error.OperationNotAllowed` if a part contains a `..` path component
///   (parent traversal would escape the configured root).
fn joinRelativeParts(
    alloc: std.mem.Allocator,
    root: []const u8,
    relative_parts: []const []const u8,
) error{ OutOfMemory, OperationNotAllowed }![]const u8 {
    var result: []const u8 = try alloc.dupe(u8, root);
    for (relative_parts) |part| {
        if (containsParentTraversal(part)) return error.OperationNotAllowed;
        const tail = if (std.mem.startsWith(u8, part, "/")) part[1..] else part;
        if (tail.len == 0) continue;
        result = try std.Io.Dir.path.join(alloc, &.{ result, tail });
    }
    return result;
}

/// Returns `true` if and only if the `/`-separated components of `path`
/// contain `..` (parent traversal). Escaped variations of `..` are not
/// recognized, because URIs are expected to arrive un-escaped from the
/// plugins' side of the scheme.
fn containsParentTraversal(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return true;
    }
    return false;
}

// --- Source Engine filesystem binding ---------------------------------------

/// Longest engine-side name or wildcard this module expresses in one
/// zero-terminated buffer; exceeding it is `error.NameTooLong`.
pub const max_engine_name_len: usize = 1024;

/// The engine's opaque file handle (`FileHandle_t`, filesystem.h:38
/// [checkout]): a plain pointer that only means something to the engine
/// filesystem it came from.
pub const Handle = *anyopaque;

/// The engine's directory enumeration handle (`FileFindHandle_t`,
/// filesystem.h:40 [checkout]): a plain integer; see also
/// `invalid_find_handle`.
pub const FindHandle = c_int;

/// `FILESYSTEM_INVALID_FIND_HANDLE` sentinel value (filesystem.h:95-98
/// [checkout]).
pub const invalid_find_handle: FindHandle = -1;

/// `FileSystemSeek_t` positions (filesystem.h:88-93 [checkout]); the values
/// are the engine's own (C `SEEK_SET`/`SEEK_CUR`/`SEEK_END`).
pub const SeekFrom = enum(c_int) {
    /// From the beginning of the file: `FILESYSTEM_SEEK_HEAD`.
    start = 0,
    /// Relative to the current position: `FILESYSTEM_SEEK_CURRENT`.
    current = 1,
    /// Relative to the end of the file: `FILESYSTEM_SEEK_TAIL`.
    end = 2,
};

/// `SearchPathAdd_t`'s `PATH_ADD_TO_TAIL` (filesystem.h:260-264 [checkout]):
/// the path is searched last. (`PATH_ADD_TO_HEAD` is `0`.)
pub const search_path_add_to_tail: c_int = 1;

/// The engine pathID of the game's mod directory (the `tf` folder bound by
/// `game://` above). Game code addresses exactly that directory with this
/// id [checkout: nav_file.cpp:1241-1245 opens "GAME"].
pub const game_path_id = "GAME";

/// Custom pathID Zorcerer adds its own installation tree under via
/// `Abi.add_search_path` (constructed id, not an engine constant). The
/// engine resolves it against the configured `zorcerer_root`.
pub const plugin_path_id = "ZORCERER_PLUGINS";

/// The exact C ABI of the engine filesystem virtuals this module calls,
/// derived from filesystem.h [checkout]: `IBaseFileSystem` members at
/// filesystem.h:504-517 and `IFileSystem` members at 548-650. The struct
/// records *signatures only*: concrete vtable slot indices are a
/// [binary]-level fact that binary verification must establish; whoever
/// binds an engine filesystem therefore supplies the already-resolved
/// function pointers, and no slot numbers live in this module.
pub const Abi = struct {
    /// `IBaseFileSystem::Read` (filesystem.h:504): returns the number of
    /// bytes read, negative values signal failure.
    read: *const fn (fs: *anyopaque, dest: [*]u8, size: c_int, handle: Handle) callconv(.c) c_int,
    /// `IBaseFileSystem::Write` (filesystem.h:505): returns the number of
    /// bytes written, negative values signal failure.
    write: *const fn (fs: *anyopaque, src: [*]const u8, size: c_int, handle: Handle) callconv(.c) c_int,
    /// `IBaseFileSystem::Open` (filesystem.h:508). A null pathID makes the
    /// engine search all paths; failure is reported as a null handle
    /// [checkout: nav_file.cpp:1241-1248 checks `if (!file)`].
    open: *const fn (
        fs: *anyopaque,
        name: [*:0]const u8,
        options: [*:0]const u8,
        path_id: ?[*:0]const u8,
    ) callconv(.c) ?Handle,
    /// `IBaseFileSystem::Close` (filesystem.h:509).
    close: *const fn (fs: *anyopaque, handle: Handle) callconv(.c) void,
    /// `IBaseFileSystem::Seek` (filesystem.h:512): void return means seek
    /// failures are unreportable; use `SourceFile.tell()` to verify.
    seek: *const fn (fs: *anyopaque, handle: Handle, position: c_int, seek_type: c_int) callconv(.c) void,
    /// `IBaseFileSystem::Tell` (filesystem.h:513).
    tell: *const fn (fs: *anyopaque, handle: Handle) callconv(.c) c_uint,
    /// `IBaseFileSystem::Size` for an open handle (filesystem.h:514).
    size: *const fn (fs: *anyopaque, handle: Handle) callconv(.c) c_uint,
    /// `IBaseFileSystem::Flush` (filesystem.h:517): void return, flush
    /// failure is unreportable.
    flush: *const fn (fs: *anyopaque, handle: Handle) callconv(.c) void,
    /// `IFileSystem::AddSearchPath` (filesystem.h:569); `add_type` is a
    /// `SearchPathAdd_t` value.
    add_search_path: *const fn (
        fs: *anyopaque,
        path: [*:0]const u8,
        path_id: [*:0]const u8,
        add_type: c_int,
    ) callconv(.c) void,
    /// `IFileSystem::FindFirstEx` (filesystem.h:653): returns the first
    /// matching entry name or null; no result yields
    /// `invalid_find_handle` in `handle`.
    find_first_ex: *const fn (
        fs: *anyopaque,
        wildcard: [*:0]const u8,
        path_id: [*:0]const u8,
        handle: *FindHandle,
    ) callconv(.c) ?[*:0]const u8,
    /// `IFileSystem::FindNext` (filesystem.h:648): null ends the session.
    find_next: *const fn (fs: *anyopaque, handle: FindHandle) callconv(.c) ?[*:0]const u8,
    /// `IFileSystem::FindIsDirectory` (filesystem.h:649).
    find_is_directory: *const fn (fs: *anyopaque, handle: FindHandle) callconv(.c) bool,
    /// `IFileSystem::FindClose` (filesystem.h:650).
    find_close: *const fn (fs: *anyopaque, handle: FindHandle) callconv(.c) void,
};

/// A bound engine filesystem: the `IFileSystem` interface instance paired
/// with ABI method pointers resolved for exactly that engine build.
///
/// Lifetime: `interface` must stay valid while any handle created through
/// this binding is still open (engine interfaces live for the process'
/// lifetime).
pub const SourceFilesystem = struct {
    /// The bound `IFileSystem` instance pointer.
    interface: *anyopaque,
    /// Method pointers matching the running engine's interface layout.
    abi: Abi,
};

// --- Source Engine file I/O -------------------------------------------------

/// A file opened through the engine filesystem.
///
/// Lifecycle: created by `SourceFile.open()`; the engine handle stays valid
/// until `SourceFile.close()`, after which `handle` must not be used.
///
/// `fs` must remain valid for that time too: an `IFileSystem` pointer is
/// expected to be process-resident, so keeping the binding alive is not a
/// realistic burden.
pub const SourceFile = struct {
    /// The engine filesystem binding the handle was created through.
    fs: SourceFilesystem,
    /// The engine's `FileHandle_t` for this file; only meaningful for the
    /// exact `fs` that produced it.
    handle: Handle,

    /// How the file is opened, mapped onto engine option strings
    /// [checkout usage: nav_file.cpp:1241 "rb"; ai_networkmanager.cpp:351
    /// "wb"; physics.cpp:2910 "ab"].
    pub const Mode = enum {
        /// Read-only: `Open` option string `"rb"`.
        read,
        /// Write with truncation: `Open` option string `"wb"`.
        write,
        /// Write appending past the current end: `Open` option string `"ab"`.
        append,
    };

    /// Errors of `open()` and of directory opens.
    pub const OpenError = error{
        /// The path's permission set (see `checkPermission`) does not cover
        /// the requested mode.
        PermissionDenied,
        /// The path is outside the engine-mediated trees, or the Zorcerer
        /// installation root is too long to mount.
        OperationNotAllowed,
        /// An engine-side name or wildcard exceeds `max_engine_name_len`.
        NameTooLong,
        /// The engine refused to open the path; the engine does not expose
        /// the failure cause, so this error is deliberately coarse.
        OpenFailed,
    };

    /// Opens `path` through the engine filesystem.
    ///
    /// The path's permission set is enforced first (`.read` mode needs read
    /// bits, `.write`/`.append` need write bits), then the path is
    /// translated into an engine name + pathID:
    /// - paths under `game_root` open through pathID `game_path_id` (the
    ///   engine already mounts the tf directory there, no engine state is
    ///   changed), and
    /// - paths under `zorcerer_root` open through pathID `plugin_path_id`,
    ///   which is added to the engine's search paths on first use.
    ///
    /// This follows filesystem.md's rule that engine-mediated file use must
    /// go via pathIDs and respect the WritePath instead of absolute paths
    /// (filesystem.md §3, §10.3).
    ///
    /// Caveat [binary]: whether a write under `plugin_path_id`
    /// actually lands in the Zorcerer tree depends on the running engine's
    /// write-path arbitration; no engine build has been verified for that
    /// yet.
    pub fn open(fs: SourceFilesystem, path: ZorcererPath, mode: Mode) OpenError!SourceFile {
        try checkPermission(path, switch (mode) {
            .read => Permission.read,
            .write, .append => Permission.write,
        });

        const engine_path = try enginePath(path, true);
        if (engine_path.needs_plugin_mount) try mountPluginTree(fs);

        var name_buf: [max_engine_name_len]u8 = undefined;
        const engine_name = std.fmt.bufPrintZ(&name_buf, "{s}", .{engine_path.name}) catch
            return error.NameTooLong;

        const handle = fs.abi.open(fs.interface, engine_name.ptr, optionsString(mode).ptr, engine_path.path_id) orelse
            return error.OpenFailed;

        return SourceFile{ .fs = fs, .handle = handle };
    }

    /// Closes the engine handle. After this call the handle is stale and
    /// this file must not be used again, not even `close()` twice.
    pub fn close(self: *SourceFile) void {
        self.fs.abi.close(self.fs.interface, self.handle);
    }

    /// Errors of reading a file through the engine.
    pub const ReadError = error{
        /// The engine reported a failed read (negative byte count).
        ReadFailed,
    };

    /// Reads the next chunk, reporting how many bytes landed in `buffer`
    /// (may be short); reaching 0 signals end of stream. A single
    /// engine call reads at most `maxInt(c_int)` bytes (engine ABI).
    pub fn read(self: *const SourceFile, buffer: []u8) ReadError!usize {
        if (buffer.len == 0) return 0;
        const chunk = buffer[0..@min(buffer.len, std.math.maxInt(c_int))];
        const bytes_read = self.fs.abi.read(self.fs.interface, chunk.ptr, @intCast(chunk.len), self.handle);
        if (bytes_read < 0) return error.ReadFailed;
        return @intCast(bytes_read);
    }

    /// Fills `buffer` as far as the file goes, returning the number of
    /// bytes read (equal to `buffer.len` unless end of stream was hit).
    pub fn readAll(self: *const SourceFile, buffer: []u8) ReadError!usize {
        var filled: usize = 0;
        while (filled != buffer.len) {
            const bytes_read = try self.read(buffer[filled..]);
            if (bytes_read == 0) break;
            filled += bytes_read;
        }
        return filled;
    }

    /// Errors of writing a file through the engine.
    pub const WriteError = error{
        /// The engine reported a failed write or stopped making progress.
        WriteFailed,
    };

    /// Writes what one engine call accepts, capped at `maxInt(c_int)`
    /// bytes (engine ABI), returning the number of bytes written.
    pub fn write(self: *const SourceFile, buffer: []const u8) WriteError!usize {
        if (buffer.len == 0) return 0;
        const chunk = buffer[0..@min(buffer.len, std.math.maxInt(c_int))];
        const bytes_written = self.fs.abi.write(self.fs.interface, chunk.ptr, @intCast(chunk.len), self.handle);
        if (bytes_written <= 0) return error.WriteFailed;
        return @intCast(bytes_written);
    }

    /// Writes the whole `buffer` or fails; zero-progress engine calls are
    /// reported as `error.WriteFailed` instead of looping.
    pub fn writeAll(self: *const SourceFile, buffer: []const u8) WriteError!void {
        var sent: usize = 0;
        while (sent != buffer.len) {
            const bytes_written = try self.write(buffer[sent..]);
            if (bytes_written == 0) return error.WriteFailed;
            sent += bytes_written;
        }
    }

    /// Errors of seeking.
    pub const SeekError = error{
        /// The offset does not fit the engine's `c_int` position ABI.
        PositionOverflow,
    };

    /// Moves the engine read/write pointer: `start` offsets are absolute
    /// (expected non-negative), `current`/`end` offsets move the pointer
    /// relative to their anchor and may be negative, which is how back-
    /// seeks are expressed. Seek failures cannot be observed (the engine's
    /// Seek is void); verify with `tell()`.
    pub fn seek(self: *const SourceFile, offset: i64, from: SeekFrom) SeekError!void {
        const position: c_int = std.math.cast(c_int, offset) orelse return error.PositionOverflow;
        self.fs.abi.seek(self.fs.interface, self.handle, position, @intFromEnum(from));
    }

    /// Current engine read/write pointer as an offset from the file start.
    pub fn tell(self: *const SourceFile) usize {
        return @intCast(self.fs.abi.tell(self.fs.interface, self.handle));
    }

    /// File size as reported by the engine.
    pub fn size(self: *const SourceFile) usize {
        return @intCast(self.fs.abi.size(self.fs.interface, self.handle));
    }

    /// Asks the engine to flush its buffers for this file. Flush failures
    /// are unobservable (the engine's Flush is void); data still pending in
    /// a `Writer` buffer must be flushed there first.
    pub fn flush(self: *const SourceFile) void {
        self.fs.abi.flush(self.fs.interface, self.handle);
    }

    /// Streaming, buffered reader over an open engine file:
    /// `buffer` (which must be non-empty) is the caller-owned window the
    /// standard interface fills from the engine via `SourceFile.read()`.
    /// Short reads between engine calls are transparent to the user.
    ///
    /// The engine handle is borrowed, not owned: closing the file while
    /// readers/writers are active on it is caller error.
    pub const Reader = struct {
        file: SourceFile,
        /// The standard's streaming reader interface; see std.Io.Reader.
        interface: std.Io.Reader,

        /// Builds the adapter around `file`; `buffer.len` must be nonzero.
        pub fn init(file: SourceFile, buffer: []u8) Reader {
            std.debug.assert(buffer.len > 0);
            return .{
                .file = file,
                .interface = .{
                    .vtable = &.{ .stream = streamSourceFile },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }
    };

    /// `std.Io.Writer` adapter over an open engine file: the caller-owned
    /// `buffer` (which must be non-empty) accumulates written bytes and is
    /// drained to the engine once full or on explicit `interface.flush()` /
    /// `SourceFile.flush()`.
    pub const Writer = struct {
        file: SourceFile,
        /// The standard's streaming writer interface; see std.Io.Writer.
        interface: std.Io.Writer,

        /// Builds the adapter around `file`; `buffer.len` must be nonzero.
        pub fn init(file: SourceFile, buffer: []u8) Writer {
            std.debug.assert(buffer.len > 0);
            return .{
                .file = file,
                .interface = .{
                    .vtable = &.{ .drain = drainSourceFile },
                    .buffer = buffer,
                },
            };
        }
    };

    /// Builds an engine-backed `std.Io.Reader` view onto `self`.
    pub fn reader(self: SourceFile, buffer: []u8) Reader {
        return Reader.init(self, buffer);
    }

    /// Builds an engine-backed `std.Io.Writer` view onto `self`.
    pub fn writer(self: SourceFile, buffer: []u8) Writer {
        return Writer.init(self, buffer);
    }
};

/// `std.Io.Reader.VTable.stream` for `SourceFile.Reader`: pulls bytes from
/// the engine handle into the sink (or, for small limits, straight into the
/// sink's buffer). Engine end-of-file (`SourceFile.read()` returning 0)
/// surfaces as `error.EndOfStream`, short reads as a short return, engine
/// failures as `error.ReadFailed`/`error.WriteFailed`.
fn streamSourceFile(
    self: *std.Io.Reader,
    w: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    const reader: *SourceFile.Reader = @alignCast(@fieldParentPtr("interface", self));

    if (limit == .nothing) return 0;

    const dest = limit.slice(try w.writableSliceGreedy(1));
    if (dest.len == 0) return 0;

    const bytes_read = reader.file.read(dest) catch {
        // The engine failed; surface it as the standard's read failure.
        return error.ReadFailed;
    };
    if (bytes_read == 0) return error.EndOfStream;

    w.advance(bytes_read);
    return bytes_read;
}

/// `std.Io.Writer.VTable.drain` for `SourceFile.Writer`: writes the buffer
/// content, then each `data` component (the last repeated `splat` times)
/// through the engine, consuming what got written. Engine failures surface
/// as `error.WriteFailed`.
fn drainSourceFile(
    self: *std.Io.Writer,
    data: []const []const u8,
    splat: usize,
) std.Io.Writer.Error!usize {
    const writer: *SourceFile.Writer = @alignCast(@fieldParentPtr("interface", self));

    var written: usize = 0;

    // The interface contract: buffer content is consumed first, followed by
    // every slice of `data`, then `data[data.len - 1]` repeated `splat`
    // times.
    written += try fileWriteToEngine(writer, self.buffered());
    for (data[0 .. data.len - 1]) |chunk| {
        written += try fileWriteToEngine(writer, chunk);
    }
    if (splat > 0) {
        const repeated = data[data.len - 1];
        var remaining = splat;
        while (remaining > 0) : (remaining -= 1) {
            written += try fileWriteToEngine(writer, repeated);
        }
    }

    return self.consume(written);
}

/// Writes `chunk` completely through `SourceFile.write()`; zero-progress
/// engine responses are a hard failure rather than an infinite loop.
fn fileWriteToEngine(writer: *SourceFile.Writer, chunk: []const u8) std.Io.Writer.Error!usize {
    var sent: usize = 0;
    while (sent != chunk.len) {
        // SourceFile.write() already caps single calls at maxInt(c_int).
        const n = writer.file.write(chunk[sent..]) catch return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        sent += n;
    }
    return sent;
}

// --- Source Engine directory I/O --------------------------------------------

/// A directory enumeration session ("opened directory") in the engine FS.
///
/// The Source filesystem has no directory handles: the closest equivalent
/// is its find session (`FindFirstEx`/`FindNext`/`FindIsDirectory`/
/// `FindClose`, filesystem.h:647-650, used like nav_file.cpp:1295-1330
/// [checkout]), which is what this type wraps.
///
/// Lifecycle: created by `SourceDirectory.open()`, entries pulled by
/// `next()`, session terminated by `close()`.
pub const SourceDirectory = struct {
    /// The engine filesystem binding the find session was created through.
    fs: SourceFilesystem,
    /// The live `FileFindHandle_t`, or `invalid_find_handle` for an empty
    /// session (one that never yields entries and does not need closing).
    find_handle: FindHandle,
    /// Copy of the name of the first found session's first result; each
    /// engine result is only valid until the following find call, so it is
    /// captured immediately at open.
    first_name: [max_engine_name_len]u8 = undefined,
    first_name_len: usize = 0,
    /// Whether `first_name` still has to be reported by `next()`.
    first_pending: bool = false,

    /// Errors of opening a directory session; shared with file opens.
    pub const OpenError = SourceFile.OpenError;

    /// One filesystem entry reported by `next()`.
    pub const Entry = struct {
        /// Entry name relative to the opened directory, sliced from
        /// `next()`'s buffer and valid until the next call.
        name: []const u8,
        /// Whether the entry is itself a directory (can be opened as one).
        is_directory: bool,
    };

    /// Errors of entry enumeration.
    pub const EntryError = error{
        /// An engine entry name does not fit `next()`'s buffer.
        NameTooLong,
    };

    /// Starts a find session over `path`'s content (the wildcard
    /// `<path>/*`, or `*` for the tree root itself) in the path's pathID.
    /// Read permission is enforced. Opening an unmatchable pattern yields
    /// an empty session instead of an error (the engine reports that
    /// condition via `invalid_find_handle`/null).
    pub fn open(fs: SourceFilesystem, path: ZorcererPath) OpenError!SourceDirectory {
        try checkPermission(path, .read);

        const engine_path = try enginePath(path, false);
        if (engine_path.needs_plugin_mount) try mountPluginTree(fs);

        var pattern_buf: [max_engine_name_len]u8 = undefined;
        const wildcard: [*:0]const u8 = if (engine_path.name.len == 0)
            "*"
        else
            (std.fmt.bufPrintZ(&pattern_buf, "{s}/*", .{engine_path.name}) catch
                return error.NameTooLong).ptr;

        var find_handle: FindHandle = invalid_find_handle;
        const first = fs.abi.find_first_ex(fs.interface, wildcard, engine_path.path_id, &find_handle);

        var session = SourceDirectory{ .fs = fs, .find_handle = find_handle };

        if (first) |engine_name| {
            // See through the zero terminator: `engine_name` is a
            // `[*:0]const u8`, so a raw `[0..len]` slice would carry no
            // length and fail `@memcpy`'s operand checks.
            const bytes = std.mem.span(engine_name);
            if (bytes.len > max_engine_name_len) return error.NameTooLong;
            @memcpy(session.first_name[0..bytes.len], bytes);
            session.first_name_len = bytes.len;
            session.first_pending = true;
        }

        return session;
    }

    /// Copies the next entry's name into `name_buffer` and reports it with
    /// its directory flag; `null` once the session is exhausted. The
    /// returned `name` slice points into `name_buffer` and is valid until
    /// the next `next()` call.
    pub fn next(self: *SourceDirectory, name_buffer: []u8) EntryError!?Entry {
        var engine_name: ?[*:0]const u8 = null;

        if (self.first_pending) {
            self.first_pending = false;
            // `first_name` already holds the engine-owned copy.
            const name = self.first_name[0..self.first_name_len];
            if (name.len > name_buffer.len) return error.NameTooLong;
            @memcpy(name_buffer[0..name.len], name);
            return Entry{
                .name = name_buffer[0..name.len],
                .is_directory = self.fs.abi.find_is_directory(self.fs.interface, self.find_handle),
            };
        }

        if (self.find_handle == invalid_find_handle) return null;
        engine_name = self.fs.abi.find_next(self.fs.interface, self.find_handle) orelse return null;

        const name = std.mem.span(engine_name.?);
        if (name.len > name_buffer.len) return error.NameTooLong;
        @memcpy(name_buffer[0..name.len], name);
        return Entry{
            .name = name_buffer[0..name.len],
            .is_directory = self.fs.abi.find_is_directory(self.fs.interface, self.find_handle),
        };
    }

    /// Ends the find session. Closing is idempotent; after this call only
    /// further `close()` calls are valid.
    pub fn close(self: *SourceDirectory) void {
        if (self.find_handle != invalid_find_handle) {
            self.fs.abi.find_close(self.fs.interface, self.find_handle);
            self.find_handle = invalid_find_handle;
        }
    }
};

// --- Engine path/state internals --------------------------------------------

/// Where a `ZorcererPath` resolves in the engine filesystem namespace.
const EnginePath = struct {
    /// Name relative to the search path identified by `path_id` (may be
    /// empty for the tree root itself).
    name: []const u8,
    /// Zero-terminated engine pathID the name resolves against.
    path_id: [*:0]const u8,
    /// Whether `plugin_path_id` must be added to the engine's search paths
    /// before the name can resolve.
    needs_plugin_mount: bool = false,
};

/// Translates a `ZorcererPath` into an engine name + pathID.
///
/// - Prefixes resolved against `game_root` map onto `game_path_id`.
/// - Prefixes resolved against `zorcerer_root` map onto `plugin_path_id`.
/// - Everything outside these configured roots is refused: the engine can
///   only see what its search paths mediate.
///
/// `require_inside_root` treats the root itself as a file destination (not
/// openable); `false` allows the empty name (directory opening).
fn enginePath(path: ZorcererPath, require_inside_root: bool) error{OperationNotAllowed}!EnginePath {
    if (relativeUnder(game_root orelse "", path.absolute_path, require_inside_root)) |name| {
        return .{ .name = name, .path_id = game_path_id };
    }
    if (relativeUnder(zorcerer_root orelse "", path.absolute_path, require_inside_root)) |name| {
        return .{ .name = name, .path_id = plugin_path_id, .needs_plugin_mount = true };
    }
    return error.OperationNotAllowed;
}

/// Returns `absolute` stripped off the `root` prefix, or null when
/// `absolute` is not strictly under `root` (`require_inside`) resp. not at
/// or under it. Roots are expected without a trailing separator; a root of
/// "" means unconfigured and matches nothing.
fn relativeUnder(
    root: []const u8,
    absolute: []const u8,
    require_inside: bool,
) ?[]const u8 {
    if (root.len == 0) return null;
    if (!std.mem.startsWith(u8, absolute, root)) return null;
    if (absolute.len == root.len) {
        return if (require_inside) null else "";
    }
    if (absolute[root.len] != '/') return null;
    return absolute[root.len + 1 ..];
}

/// The engine open option strings behind `open()`'s modes, exact spelling
/// as used by game code [checkout: nav_file.cpp:1241 "rb",
/// ai_networkmanager.cpp:351 "wb", physics.cpp:2910 "ab"].
fn optionsString(mode: SourceFile.Mode) [:0]const u8 {
    return switch (mode) {
        .read => "rb",
        .write => "wb",
        .append => "ab",
    };
}

/// Whether `plugin_path_id` was already added to the engine FS' search
/// paths; the mount is global because the engine FS is process-resident,
/// tests reset the flag themselves.
var plugin_tree_mounted: bool = false;

/// Adds the Zorcerer installation root into the engine FS under
/// `plugin_path_id`. Idempotent per process: the first successful mount
/// sets `plugin_tree_mounted`, and every later call returns without
/// touching the engine again.
fn mountPluginTree(fs: SourceFilesystem) error{OperationNotAllowed}!void {
    if (plugin_tree_mounted) return;
    const root = zorcerer_root orelse return error.OperationNotAllowed;

    var buf: [max_engine_name_len]u8 = undefined;
    const root_z = std.fmt.bufPrintZ(&buf, "{s}", .{root}) catch return error.OperationNotAllowed;
    fs.abi.add_search_path(fs.interface, root_z.ptr, plugin_path_id, search_path_add_to_tail);
    plugin_tree_mounted = true;
}

// --- Tests -----------------------------------------------------------------

const test_zorcerer_root = "/steamapps/zorcerer";
const test_game_root = "/steamapps/team fortress 2/tf";

/// Returns a mocked plugin context whose configuration resembles a
/// `hello` plugin living under `plugins/hello/`. Only the fields relevant
/// to `parsePath()` carry mock data.
fn mockContext() PluginContext {
    return PluginContext{
        .config = PluginConfiguration{
            .plugin_id = "hello",
            .name = "Hello Example",
            .version = "0.1.0",
            .author = "Zorcerer",
            .lib_path = "plugins/hello/hello_plugin.so",
        },
    };
}

test "parsePath resolves game:// to the read-only tf directory" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
    }
    setGameRoot(test_game_root);
    zorcerer_root = null;

    var ctx = mockContext();
    const resolved = try parsePath(&ctx, "game://maps/arena.bsp");

    try std.testing.expectEqualStrings(
        "/steamapps/team fortress 2/tf/maps/arena.bsp",
        resolved.absolute_path,
    );
    try std.testing.expect(resolved.permissions.readOnly());
}

test "parsePath resolves plugin:// to the writable plugin root" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
    }
    game_root = null;
    setZorcererRoot(test_zorcerer_root);

    var ctx = mockContext();
    const resolved = try parsePath(&ctx, "plugin://settings.cfg");

    try std.testing.expectEqualStrings(
        "/steamapps/zorcerer/plugins/hello/settings.cfg",
        resolved.absolute_path,
    );
    try std.testing.expect(!resolved.permissions.readOnly());
    // Read and write only: no execute bits may be granted.
    try std.testing.expectEqual(
        @as(@TypeOf(resolved.permissions.toMode()), resolved.permissions.toMode()) & 0o111,
        0,
    );
}

test "parsePath rejects unknown schemes" {
    var ctx = mockContext();
    try std.testing.expectError(
        error.OperationNotAllowed,
        parsePath(&ctx, "filesystem://whatever"),
    );
}

test "parsePath rejects parent traversal" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
    }
    setGameRoot(test_game_root);
    setZorcererRoot(test_zorcerer_root);

    var ctx = mockContext();
    try std.testing.expectError(
        error.OperationNotAllowed,
        parsePath(&ctx, "game://../other_plugin.cfg"),
    );
    try std.testing.expectError(
        error.OperationNotAllowed,
        parsePath(&ctx, "plugin://../../tf/steal.cfg"),
    );
}

test "checkPermission rejects write and execute on game:// paths" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
    }
    setGameRoot(test_game_root);

    var ctx = mockContext();
    const resolved = try parsePath(&ctx, "game://maps/arena.bsp");

    // Disallowed: write.
    try std.testing.expectError(
        error.PermissionDenied,
        checkPermission(resolved, .write),
    );
    // Disallowed: execute.
    try std.testing.expectError(
        error.PermissionDenied,
        checkPermission(resolved, .execute),
    );
    // Sanity check: reading stays permitted.
    try checkPermission(resolved, .read);
}

test "checkPermission rejects execute on plugin:// paths" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
    }
    setZorcererRoot(test_zorcerer_root);

    var ctx = mockContext();
    const resolved = try parsePath(&ctx, "plugin://settings.cfg");

    // Disallowed: execute.
    try std.testing.expectError(
        error.PermissionDenied,
        checkPermission(resolved, .execute),
    );
    // Sanity check: read and write stay permitted.
    try checkPermission(resolved, .read);
    try checkPermission(resolved, .write);
}

// --- Mock engine filesystem (tests) -----------------------------------------

/// In-memory stand-in for the engine filesystem the mock ABI below works
/// on: records what was called with what, and serves reads/writes and a
/// find session from its own arrays.
const MockFs = struct {
    // Open bookkeeping.
    open_calls: usize = 0,
    open_fail: bool = false,
    opened_name: [128]u8 = undefined,
    opened_name_len: usize = 0,
    opened_options: [64]u8 = undefined,
    opened_options_len: usize = 0,
    opened_path_id: [32]u8 = undefined,
    opened_path_id_len: usize = 0,

    // Read bookkeeping.
    content: []const u8 = "",
    read_position: usize = 0,

    // Write bookkeeping.
    write_buffer: [256]u8 = undefined,
    write_len: usize = 0,
    write_calls: usize = 0,
    closed_calls: usize = 0,
    flushed_calls: usize = 0,
    seek_calls: usize = 0,

    // Search-path mount bookkeeping.
    mount_calls: usize = 0,
    mounted_path: [128]u8 = undefined,
    mounted_path_len: usize = 0,
    mounted_path_id: [32]u8 = undefined,
    mounted_path_id_len: usize = 0,

    // Find-session bookkeeping.
    entries: []const MockEntry = &.{},
    wildcard: [128]u8 = undefined,
    wildcard_len: usize = 0,
    find_index: usize = 0,
    find_current: usize = 0,
    find_closed: bool = false,
    find_next_calls: usize = 0,
    find_is_dir_calls: usize = 0,
};

const mock_find_handle: c_int = 77;

const MockEntry = struct {
    name: [*:0]const u8,
    is_directory: bool,
};

fn spanCopyInto(dest: []u8, src: [*:0]const u8) usize {
    const bytes = std.mem.span(src);
    const copied = @min(dest.len, bytes.len);
    @memcpy(dest[0..copied], bytes[0..copied]);
    return copied;
}

fn mockOpen(fs: *anyopaque, name: [*:0]const u8, options: [*:0]const u8, path_id: ?[*:0]const u8) callconv(.c) ?Handle {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    self.open_calls += 1;
    if (self.open_fail) return null;
    self.opened_name_len = spanCopyInto(&self.opened_name, name);
    self.opened_options_len = spanCopyInto(&self.opened_options, options);
    self.opened_path_id_len = spanCopyInto(&self.opened_path_id, path_id.?);
    self.read_position = 0;
    // A stable, unique-enough fake handle.
    return @ptrFromInt(0xCAFEBABE);
}

fn mockClose(fs: *anyopaque, handle: Handle) callconv(.c) void {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    _ = handle;
    self.closed_calls += 1;
}

fn mockRead(fs: *anyopaque, dest: [*]u8, size: c_int, handle: Handle) callconv(.c) c_int {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    _ = handle;
    const buffer = dest[0..@intCast(size)];
    const remaining = self.content.len - self.read_position;
    const copied = @min(buffer.len, remaining);
    @memcpy(buffer[0..copied], self.content[self.read_position..][0..copied]);
    self.read_position += copied;
    return @intCast(copied);
}

fn mockWrite(fs: *anyopaque, src: [*]const u8, size: c_int, handle: Handle) callconv(.c) c_int {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    _ = handle;
    const bytes = src[0..@intCast(size)];
    const room = self.write_buffer.len - self.write_len;
    const copied = @min(bytes.len, room);
    @memcpy(self.write_buffer[self.write_len..][0..copied], bytes[0..copied]);
    self.write_len += copied;
    self.write_calls += 1;
    return @intCast(copied);
}

fn mockSeek(fs: *anyopaque, handle: Handle, position: c_int, seek_type: c_int) callconv(.c) void {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    _ = handle;
    const offset: i64 = position;
    var target: i64 = switch (seek_type) {
        @intFromEnum(SeekFrom.start) => offset,
        @intFromEnum(SeekFrom.current) => @as(i64, @intCast(self.read_position)) + offset,
        else => @as(i64, @intCast(self.content.len)) + offset,
    };
    if (target < 0) target = 0;
    if (target > @as(i64, @intCast(self.content.len))) target = @intCast(self.content.len);
    self.read_position = @intCast(target);
    self.seek_calls += 1;
}

fn mockTell(fs: *anyopaque, handle: Handle) callconv(.c) c_uint {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    _ = handle;
    return @intCast(self.read_position);
}

fn mockSize(fs: *anyopaque, handle: Handle) callconv(.c) c_uint {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    _ = handle;
    return @intCast(self.content.len);
}

fn mockFlush(fs: *anyopaque, handle: Handle) callconv(.c) void {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    _ = handle;
    self.flushed_calls += 1;
}

fn mockAddSearchPath(fs: *anyopaque, path: [*:0]const u8, path_id: [*:0]const u8, add_type: c_int) callconv(.c) void {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    self.mount_calls += 1;
    self.mounted_path_len = spanCopyInto(&self.mounted_path, path);
    self.mounted_path_id_len = spanCopyInto(&self.mounted_path_id, path_id);
    // Not `try`: a C-calling-convention mock cannot return an error.
    std.testing.expectEqual(search_path_add_to_tail, add_type) catch
        std.process.abort();
}

fn mockFindFirstEx(fs: *anyopaque, wildcard: [*:0]const u8, path_id: [*:0]const u8, handle: *FindHandle) callconv(.c) ?[*:0]const u8 {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    self.wildcard_len = spanCopyInto(&self.wildcard, wildcard);
    _ = path_id;
    self.find_index = 0;
    self.find_current = 0;
    if (self.entries.len == 0) {
        handle.* = invalid_find_handle;
        return null;
    }
    handle.* = mock_find_handle;
    return self.entries[0].name;
}

fn mockFindNext(fs: *anyopaque, handle: FindHandle) callconv(.c) ?[*:0]const u8 {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    if (handle == invalid_find_handle) return null;
    self.find_next_calls += 1;
    if (self.find_index + 1 >= self.entries.len) return null;
    self.find_index += 1;
    self.find_current = self.find_index;
    return self.entries[self.find_index].name;
}

fn mockFindIsDirectory(fs: *anyopaque, handle: FindHandle) callconv(.c) bool {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    self.find_is_dir_calls += 1;
    if (handle == invalid_find_handle) return false;
    return self.entries[self.find_current].is_directory;
}

fn mockFindClose(fs: *anyopaque, handle: FindHandle) callconv(.c) void {
    const self: *MockFs = @ptrCast(@alignCast(fs));
    if (handle == invalid_find_handle) return;
    self.find_closed = true;
}

const mock_abi = Abi{
    .read = mockRead,
    .write = mockWrite,
    .open = mockOpen,
    .close = mockClose,
    .seek = mockSeek,
    .tell = mockTell,
    .size = mockSize,
    .flush = mockFlush,
    .add_search_path = mockAddSearchPath,
    .find_first_ex = mockFindFirstEx,
    .find_next = mockFindNext,
    .find_is_directory = mockFindIsDirectory,
    .find_close = mockFindClose,
};

/// Wraps `engine` into a full engine filesystem binding with the mock ABI.
fn mockFilesystem(engine: *MockFs) SourceFilesystem {
    return SourceFilesystem{ .interface = @ptrCast(engine), .abi = mock_abi };
}

// --- Source Engine I/O tests ------------------------------------------------

test "SourceFile.open translates plugin:// URIs and mounts the plugin tree" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    const saved_mount = plugin_tree_mounted;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
        plugin_tree_mounted = saved_mount;
    }
    setGameRoot(test_game_root);
    setZorcererRoot(test_zorcerer_root);
    plugin_tree_mounted = false;

    var plugin_ctx = mockContext();
    const path = try parsePath(&plugin_ctx, "plugin://settings.cfg");

    var engine = MockFs{};
    var file = try SourceFile.open(mockFilesystem(&engine), path, .write);
    file.close();

    // The plugin tree was mounted exactly once, with the Zorcerer root.
    try std.testing.expectEqual(@as(usize, 1), engine.mount_calls);
    try std.testing.expectEqualStrings(test_zorcerer_root, engine.mounted_path[0..engine.mounted_path_len]);
    try std.testing.expectEqualStrings(plugin_path_id, engine.mounted_path_id[0..engine.mounted_path_id_len]);

    // Open went through the plugin pathID, relative to the Zorcerer root.
    try std.testing.expectEqual(@as(usize, 1), engine.open_calls);
    try std.testing.expectEqualStrings("plugins/hello/settings.cfg", engine.opened_name[0..engine.opened_name_len]);
    try std.testing.expectEqualStrings("wb", engine.opened_options[0..engine.opened_options_len]);
    try std.testing.expectEqualStrings(plugin_path_id, engine.opened_path_id[0..engine.opened_path_id_len]);
    try std.testing.expectEqual(@as(usize, 1), engine.closed_calls);
}

test "SourceFile.open resolves game:// into the game pathID without mounting" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    const saved_mount = plugin_tree_mounted;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
        plugin_tree_mounted = saved_mount;
    }
    setGameRoot(test_game_root);
    plugin_tree_mounted = false;

    var plugin_ctx = mockContext();
    const path = try parsePath(&plugin_ctx, "game://maps/arena.bsp");

    var engine = MockFs{};
    var file = try SourceFile.open(mockFilesystem(&engine), path, .read);
    defer file.close();

    // The tf directory is already mounted by the engine as GAME; no
    // engine state changes are needed.
    try std.testing.expectEqual(@as(usize, 0), engine.mount_calls);
    try std.testing.expectEqual(@as(usize, 1), engine.open_calls);
    try std.testing.expectEqualStrings("maps/arena.bsp", engine.opened_name[0..engine.opened_name_len]);
    try std.testing.expectEqualStrings("rb", engine.opened_options[0..engine.opened_options_len]);
    try std.testing.expectEqualStrings(game_path_id, engine.opened_path_id[0..engine.opened_path_id_len]);
}

test "SourceFile.open enforces permissions and engine-foreign paths" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    const saved_mount = plugin_tree_mounted;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
        plugin_tree_mounted = saved_mount;
    }
    setGameRoot(test_game_root);
    setZorcererRoot(test_zorcerer_root);
    plugin_tree_mounted = false;

    var plugin_ctx = mockContext();
    const ctx = &plugin_ctx;
    const game_path = try parsePath(ctx, "game://maps/arena.bsp");
    const plugin_path = try parsePath(ctx, "plugin://settings.cfg");

    // game:// is read-only: the engine is never even asked.
    var engine_state = MockFs{};
    try std.testing.expectError(
        error.PermissionDenied,
        SourceFile.open(mockFilesystem(&engine_state), game_path, .write),
    );
    try std.testing.expectEqual(@as(usize, 0), engine_state.open_calls);

    // A manually built path outside both roots must be refused.
    const foreign = ZorcererPath{ .absolute_path = "/etc/passwd", .permissions = read_write_permissions };
    var engine_state2 = MockFs{};
    try std.testing.expectError(
        error.OperationNotAllowed,
        SourceFile.open(mockFilesystem(&engine_state2), foreign, .read),
    );
    try std.testing.expectEqual(@as(usize, 0), engine_state2.open_calls);

    // Unset Zorcerer root: plugin paths cannot get mounted at all.
    var engine_state3 = MockFs{};
    zorcerer_root = null;
    try std.testing.expectError(
        error.OperationNotAllowed,
        SourceFile.open(mockFilesystem(&engine_state3), plugin_path, .write),
    );
    try std.testing.expectEqual(@as(usize, 0), engine_state3.open_calls);
}

test "SourceFile.read/write/seek round trip through the engine ABI" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    const saved_mount = plugin_tree_mounted;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
        plugin_tree_mounted = saved_mount;
    }
    setZorcererRoot(test_zorcerer_root);
    plugin_tree_mounted = false;

    var plugin_ctx = mockContext();
    const plugin_path = try parsePath(&plugin_ctx, "plugin://settings.cfg");

    var engine = MockFs{};
    const fs = mockFilesystem(&engine);
    var file = try SourceFile.open(fs, plugin_path, .write);
    try file.writeAll("hello world");
    file.close();

    // Switch the mock's file content to what was written above.
    engine.content = engine.write_buffer[0..engine.write_len];
    file = try SourceFile.open(fs, plugin_path, .read);

    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("hello world", buffer[0..try file.readAll(&buffer)]);
    try std.testing.expectEqual(@as(usize, 11), file.tell());
    try std.testing.expectEqual(@as(usize, 11), file.size());

    try file.seek(4, .start);
    try std.testing.expectEqualStrings("o world", buffer[0..try file.readAll(&buffer)]);
    try std.testing.expectEqual(@as(usize, 11), file.tell());

    // Seeks clamp at the mock file's end.
    try file.seek(6, .current);
    try std.testing.expectEqual(@as(usize, 11), file.tell());

    // Negative offsets seek backwards from the end.
    try file.seek(-5, .end);
    try std.testing.expectEqual(@as(usize, 6), file.tell());
    try std.testing.expectEqual(@as(usize, 5), try file.readAll(&buffer));
    try std.testing.expectEqualStrings("world", buffer[0..5]);

    file.flush();
    file.close();
}

test "SourceFile.Reader streams reads across buffer fills" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    const saved_mount = plugin_tree_mounted;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
        plugin_tree_mounted = saved_mount;
    }
    setZorcererRoot(test_zorcerer_root);
    plugin_tree_mounted = false;

    var plugin_ctx = mockContext();
    const plugin_path = try parsePath(&plugin_ctx, "plugin://settings.cfg");

    var engine = MockFs{ .content = "0123456789" };
    const fs = mockFilesystem(&engine);
    var file = try SourceFile.open(fs, plugin_path, .read);

    var window: [6]u8 = undefined;
    var buffer: [6]u8 = undefined;
    var r = file.reader(&window);

    try r.interface.readSliceAll(&buffer);
    try std.testing.expectEqualStrings("012345", buffer[0..6]);

    try r.interface.readSliceAll(buffer[0..4]);
    try std.testing.expectEqualStrings("6789", buffer[0..4]);

    // Exactly at end of stream now.
    try std.testing.expectError(error.EndOfStream, r.interface.takeByte());

    file.close();
}

test "SourceFile.Writer buffers and drains to the engine" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    const saved_mount = plugin_tree_mounted;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
        plugin_tree_mounted = saved_mount;
    }
    setZorcererRoot(test_zorcerer_root);
    plugin_tree_mounted = false;

    var plugin_ctx = mockContext();
    const plugin_path = try parsePath(&plugin_ctx, "plugin://settings.cfg");

    var engine = MockFs{};
    const fs = mockFilesystem(&engine);
    var file = try SourceFile.open(fs, plugin_path, .write);

    var sink: [4]u8 = undefined;
    var w = file.writer(&sink);

    // "abcd" fills the window exactly: buffered, no engine traffic yet.
    try w.interface.writeAll("abcd");
    try std.testing.expectEqual(@as(usize, 4), w.interface.end);
    try std.testing.expectEqual(@as(usize, 0), engine.write_calls);

    // "e" overflows the window: the drain sends the buffered "abcd" and
    // then "e" itself to the engine, two separate write calls.
    try w.interface.writeAll("e");
    try std.testing.expectEqualStrings("abcde", engine.write_buffer[0..engine.write_len]);
    try std.testing.expectEqual(@as(usize, 2), engine.write_calls);

    // "fg" fits the emptied window again: buffered, no new engine call.
    try w.interface.writeAll("fg");
    try std.testing.expectEqual(@as(usize, 2), engine.write_calls);

    // Flushing the interface drains the remaining buffered bytes.
    try w.interface.flush();
    try std.testing.expectEqualStrings("abcdefg", engine.write_buffer[0..engine.write_len]);
    try std.testing.expectEqual(@as(usize, 3), engine.write_calls);

    // The engine's own buffer is flushed explicitly through the handle.
    file.flush();
    try std.testing.expectEqual(@as(usize, 1), engine.flushed_calls);

    file.close();
}

test "SourceDirectory enumerates entries and closes the find session" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    const saved_mount = plugin_tree_mounted;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
        plugin_tree_mounted = saved_mount;
    }
    setGameRoot(test_game_root);
    plugin_tree_mounted = false;

    var plugin_ctx = mockContext();
    const game_path = try parsePath(&plugin_ctx, "game://maps");

    const entries = [_]MockEntry{
        .{ .name = "arena.bsp", .is_directory = false },
        .{ .name = "some_dir", .is_directory = true },
    };
    var engine = MockFs{ .entries = &entries };
    const fs = mockFilesystem(&engine);

    var dir = try SourceDirectory.open(fs, game_path);

    var first_buffer: [64]u8 = undefined;
    var second_buffer: [64]u8 = undefined;

    const first = (try dir.next(&first_buffer)).?;
    try std.testing.expectEqualStrings("arena.bsp", first.name);
    try std.testing.expect(!first.is_directory);

    const second = (try dir.next(&second_buffer)).?;
    try std.testing.expectEqualStrings("some_dir", second.name);
    try std.testing.expect(second.is_directory);

    // Exhausted: the third pull reports the end of the session.
    try std.testing.expect((try dir.next(&second_buffer)) == null);

    dir.close();
    // Two FindNext pulls (second entry + exhaustion probe); the first entry
    // came from the FindFirstEx opening call.
    try std.testing.expectEqual(@as(usize, 2), engine.find_next_calls);
    try std.testing.expectEqual(@as(usize, 2), engine.find_is_dir_calls);
    try std.testing.expect(engine.find_closed);
    try std.testing.expectEqualStrings("maps/*", engine.wildcard[0..engine.wildcard_len]);
}

test "SourceDirectory reports an empty session without closing" {
    const saved_game_root = game_root;
    const saved_mount = plugin_tree_mounted;
    defer {
        game_root = saved_game_root;
        plugin_tree_mounted = saved_mount;
    }
    setGameRoot(test_game_root);
    plugin_tree_mounted = false;

    var plugin_ctx = mockContext();
    const game_path = try parsePath(&plugin_ctx, "game://maps");

    var engine = MockFs{ .entries = &.{} };
    const fs = mockFilesystem(&engine);

    var dir = try SourceDirectory.open(fs, game_path);
    var name_buffer: [64]u8 = undefined;
    try std.testing.expect((try dir.next(&name_buffer)) == null);

    // An empty session has no engine handle: closing must not call the engine.
    dir.close();
    try std.testing.expect(!engine.find_closed);
}
