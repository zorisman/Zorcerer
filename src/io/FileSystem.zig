//! Host-side filesystem plumbing for plugins: it converts the virtual
//! `game://` and `plugin://` URI schemes into validated absolute paths, each
//! carrying the permission set the host is willing to grant for the
//! referenced location, and routes the actual I/O by scheme
//! (docs/references/source-sdk/filesystem.md §12):
//!
//! - `game://` paths go through the Source Engine filesystem
//!   (`IFileSystem`/`IBaseFileSystem`): the engine resolves names via its
//!   search paths and pack files (VPKs), so files are not touched through
//!   the shell. Files reachable this way resolve under pathID `GAME`.
//! - `plugin://` paths go through `std.Io` (the host OS filesystem):
//!   the Zorcerer tree is not engine content; the `std.Io` backend also
//!   reports failures with real host diagnostics instead of the engine's
//!   opaque ones.
//!
//! The engine binding is handed to the module as an interface pointer plus
//! explicitly resolved ABI method pointers (see `SourceFilesystem`);
//! vtable slot indices are *not* hardcoded here; slot resolution belongs to
//! binary verification (docs/references/source-sdk/filesystem.md §10.2).

const std = @import("std");

const PluginConfiguration = @import("plugin-configuration").PluginConfiguration;

/// URI scheme prefix targeting the running game's `tf` directory; the path
/// tail is relative to that directory. Resolved paths are routed to the
/// Source Engine filesystem.
pub const game_scheme = "game://";
/// URI scheme prefix targeting the calling plugin's own root directory; the
/// path tail is relative to that directory. Resolved paths are routed to
/// `std.Io`.
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

/// The URI scheme that produced a `ZorcererPath`, and therefore which
/// backend performs its I/O (see `File`).
pub const Scheme = enum {
    /// The running game's `tf` directory; Source Engine filesystem.
    game,
    /// The calling plugin's own root directory; `std.Io`.
    plugin,
};

/// A validated, host-resolved file location.
///
/// Invariant: `absolute_path` is an absolute filesystem path that resulted
/// from prefixing a `game://` or `plugin://` URI with the matching
/// configured root directory, and `permissions` describes the access the
/// host permits for that path. `scheme` records which URI produced the
/// path so `File.open()`/`Directory.open()` can route I/O to the correct
/// backend; callers that construct a `ZorcererPath` by hand must set it to
/// a scheme whose under-root validation they can satisfy.
///
/// Slices: `absolute_path` is allocated inside this module's arena and
/// remains valid for the rest of the process' lifetime, see
/// `parsePath()`'s documentation.
pub const ZorcererPath = struct {
    /// Absolute filesystem location the URI referenced.
    absolute_path: []const u8,
    /// Permissions the host allows for `absolute_path`.
    permissions: std.Io.File.Permissions,
    /// Which backend the path's I/O routes to (see `File`).
    scheme: Scheme,
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
///   directory (see `setGameRoot`); read-only, routed to the engine
///   filesystem (`.scheme == .game`).
/// - `"plugin://<tail>"` resolves `<tail>` against the calling plugin's
///   root directory, which is derived from the directory component of
///   `ctx.config.lib_path` underneath the configured Zorcerer root (see
///   `setZorcererRoot`); read and write, no execute, routed to `std.Io`
///   (`.scheme == .plugin`).
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
            .scheme = .game,
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
            .scheme = .plugin,
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

/// The engine pathID of the game's mod directory (the `tf` folder bound by
/// `game://` above). Game code addresses exactly that directory with this
/// id [checkout: nav_file.cpp:1241-1245 opens "GAME"].
///
/// The engine already mounts the tf directory under this pathID, so opening
/// `game://` files through it changes no engine state.
pub const game_path_id = "GAME";

/// The exact C ABI of the engine filesystem virtuals this module calls,
/// derived from filesystem.h [checkout]: `IBaseFileSystem` members at
/// filesystem.h:504-517. The struct records *signatures only*: concrete
/// vtable slot indices are a [binary]-level fact that binary verification
/// must establish; whoever binds an engine filesystem therefore supplies
/// the already-resolved function pointers, and no slot numbers live in this
/// module.
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

// --- Open modes and shared error sets ----------------------------------------

/// How a file is opened; shared by both backends of `File`.
///
/// Engine mapping [checkout usage: nav_file.cpp:1241 "rb";
/// ai_networkmanager.cpp:351 "wb"; physics.cpp:2910 "ab"]; host mapping in
/// `HostFile.open()`'s documentation.
pub const Mode = enum {
    /// Read-only: `Open` option string `"rb"`.
    read,
    /// Write with truncation: `Open` option string `"wb"`.
    write,
    /// Write appending past the current end: `Open` option string `"ab"`.
    append,
};

/// Unified errors of `File.open()` and of directory opens; both backends
/// accepted this coarse contract when they shared one engine implementation,
/// and it is kept so callers do not branch on the backend.
pub const OpenError = error{
    /// The path's permission set (see `checkPermission`) does not cover
    /// the requested mode.
    PermissionDenied,
    /// The path belongs to the other scheme's backend (its root does not
    /// validate), or the requested tree is not configured.
    OperationNotAllowed,
    /// An engine-side name or wildcard exceeds `max_engine_name_len`.
    NameTooLong,
    /// The backend refused to open the path; the engine does not expose
    /// the failure cause, and the `std.Io` backend is deliberately mapped
    /// to this coarse error at the plugin-facing boundary, too.
    OpenFailed,
    /// `File.open()` asked for a `.game` path while no `SourceFilesystem`
    /// binding was supplied.
    EngineNotBound,
};

/// Unified errors of file reads: the backend (engine negative byte count or
/// `std.Io` positional-read failure) is deliberately mapped to one error so
/// callers do not branch on the backend.
pub const ReadError = error{
    /// The backend reported a failed read.
    ReadFailed,
};

/// Unified errors of file writes: the backend (engine negative/zero byte
/// count or `std.Io` positional-write failure) is deliberately mapped to
/// one error so callers do not branch on the backend.
pub const WriteError = error{
    /// The backend reported a failed write or stopped making progress.
    WriteFailed,
};

/// Unified errors of seeks.
pub const SeekError = error{
    /// The offset does not fit the backend's position ABI (`c_int` for the
    /// engine, `u64`/`i64` arithmetic overflow for `std.Io`).
    PositionOverflow,
    /// `std.Io` only: the computed target position would be negative. The
    /// engine backend cannot report this (its `Seek` returns void).
    SeekFailed,
};

/// Unified errors of `size()`: `std.Io` only (its stat can fail); the
/// engine never fails this query, but the contract is shared.
pub const SizeError = error{
    /// The `std.Io` backend could not stat the file.
    SizeFailed,
};

/// Unified errors of `flush()`: `std.Io` only (its sync can fail); the
/// engine never fails this call, but the contract is shared.
pub const FlushError = error{
    /// The `std.Io` backend could not sync the file.
    FlushFailed,
};

/// Errors of `File.remove()`.
pub const RemoveError = error{
    /// The path's permission set (see `checkPermission`) does not grant
    /// write access, which deleting a file requires.
    PermissionDenied,
    /// The path's scheme has no removal backend: `game://` content is
    /// read-only by policy and the bound engine `Abi` exposes no remove
    /// method, and hand-built paths outside the plugin root are refused.
    OperationNotAllowed,
    /// The `std.Io` backend could not delete the file (for example it does
    /// not exist, or the OS refused the operation).
    RemoveFailed,
};

// --- Unified file ------------------------------------------------------------

/// A file opened through the backend selected by the path's scheme
/// (docs/references/source-sdk/filesystem.md §12):
///
/// - `.game` opens through the Source Engine filesystem (pathID `GAME`;
///   handled by `SourceFile`), so VPK/search-path resolution applies.
/// - `.plugin` opens through `std.Io` (handled by `HostFile`), so the
///   plugin's own tree is touched with plain host I/O and real host
///   error reporting (mapped to the coarse shared error sets above).
///
/// State and semantics: the read/write cursor lives in the engine or in
/// `HostFile.position`, so this value is a stateful handle, not a plain
/// value: every method takes `*File` so cursor movement through one file
/// stays visible on it. Copies of a `File` must not be interleaved with
/// the original (the `std.Io` backend's cursor would diverge).
///
/// Lifecycle: created by `open()`; the backend handle stays valid until
/// `close()`, after which this file must not be used again, and `close()`
/// must not be called twice.
///
/// `fs` must remain valid for that time too: an `IFileSystem` pointer is
/// expected to be process-resident, so keeping the binding alive is not a
/// realistic burden.
pub const File = union(enum) {
    /// `game://` content, routed through the engine filesystem.
    engine: SourceFile,
    /// `plugin://` content, routed through `std.Io`.
    host: HostFile,

    /// Opens `path` through the backend its `scheme` selects.
    ///
    /// The path's permission set is enforced first (`.read` mode needs read
    /// bits, `.write`/`.append` need write bits); see
    /// `SourceFile.open()`/`HostFile.open()` for the per-backend name and
    /// state handling.
    ///
    /// `fs` is only consulted for `.game` paths and must be non-null then
    /// (otherwise `error.EngineNotBound`); `.plugin` paths may be passed
    /// `null`.
    pub fn open(io: std.Io, fs: ?SourceFilesystem, path: ZorcererPath, mode: Mode) OpenError!File {
        return switch (path.scheme) {
            .game => .{ .engine = try SourceFile.open(fs orelse return error.EngineNotBound, path, mode) },
            .plugin => .{ .host = try HostFile.open(io, path, mode) },
        };
    }

    /// Closes the backend handle. After this call the file is stale and
    /// must not be used again, not even `close()` twice.
    pub fn close(self: *File) void {
        switch (self.*) {
            .engine => |*f| f.close(),
            .host => |*f| f.close(),
        }
    }

    /// Deletes the file `path` without opening it first.
    ///
    /// Deleting requires write access, so the path's permission set is
    /// enforced before the backend is asked; see `HostFile.remove()` for
    /// the host-side checks. This is a whole-path operation, not a method
    /// on an open file: `path` does not have to correspond to a `File`
    /// currently open through this module.
    ///
    /// `.plugin` paths are removed through `std.Io`. `.game` paths are
    /// refused with `error.OperationNotAllowed`: game content is read-only
    /// by policy and the bound engine `Abi` has no remove method, so there
    /// is no engine-side delete to call.
    ///
    /// Errors: `error.PermissionDenied` when `path` is not writable,
    /// `error.OperationNotAllowed` for `.game` paths or paths outside the
    /// configured plugin root, and `error.RemoveFailed` when the host
    /// refused the deletion.
    pub fn remove(io: std.Io, path: ZorcererPath) RemoveError!void {
        return switch (path.scheme) {
            .game => error.OperationNotAllowed,
            .plugin => HostFile.remove(io, path),
        };
    }

    /// Reads the next chunk, reporting how many bytes landed in `buffer`
    /// (may be short); reaching 0 signals end of stream. A single
    /// engine call reads at most `maxInt(c_int)` bytes (engine ABI); the
    /// `std.Io` backend has no such cap.
    pub fn read(self: *File, buffer: []u8) ReadError!usize {
        return switch (self.*) {
            inline else => |*f| f.read(buffer),
        };
    }

    /// Fills `buffer` as far as the file goes, returning the number of
    /// bytes read (equal to `buffer.len` unless end of stream was hit).
    pub fn readAll(self: *File, buffer: []u8) ReadError!usize {
        return switch (self.*) {
            inline else => |*f| f.readAll(buffer),
        };
    }

    /// Writes what one backend call accepts, returning the number of bytes
    /// written. A single engine call caps at `maxInt(c_int)` bytes; the
    /// `std.Io` backend has no such cap.
    pub fn write(self: *File, buffer: []const u8) WriteError!usize {
        return switch (self.*) {
            inline else => |*f| f.write(buffer),
        };
    }

    /// Writes the whole `buffer` or fails; zero-progress backend calls are
    /// reported as `error.WriteFailed` instead of looping.
    pub fn writeAll(self: *File, buffer: []const u8) WriteError!void {
        switch (self.*) {
            inline else => |*f| try f.writeAll(buffer),
        }
    }

    /// Moves the read/write pointer: `start` offsets are absolute
    /// (expected non-negative), `current`/`end` offsets move the pointer
    /// relative to their anchor and may be negative, which is how back-
    /// seeks are expressed.
    ///
    /// Seek failures cannot be observed for the engine backend (the
    /// engine's Seek is void; verify with `tell()`); the `std.Io` backend
    /// reports `error.SeekFailed` when the computed target is negative.
    pub fn seek(self: *File, offset: i64, from: SeekFrom) SeekError!void {
        switch (self.*) {
            inline else => |*f| try f.seek(offset, from),
        }
    }

    /// Current read/write pointer as an offset from the file start.
    pub fn tell(self: *File) usize {
        return switch (self.*) {
            inline else => |*f| f.tell(),
        };
    }

    /// File size as reported by the backend.
    pub fn size(self: *File) SizeError!usize {
        return switch (self.*) {
            inline else => |*f| try f.size(),
        };
    }

    /// Asks the backend to flush its buffers for this file. Flush failures
    /// are unobservable for the engine backend (the engine's Flush is
    /// void); the `std.Io` backend syncs and can report failure. Data
    /// still pending in a `Writer` buffer must be flushed there first.
    pub fn flush(self: *File) FlushError!void {
        switch (self.*) {
            inline else => |*f| try f.flush(),
        }
    }

    /// Streaming, buffered reader view onto an open file: `buffer` (which
    /// must be non-empty) is the caller-owned window the standard
    /// interface fills from the backend. Short reads between backend
    /// calls are transparent to the user.
    ///
    /// The reader borrows this file, so `self` must remain at a fixed
    /// (non-moving) address for as long as the reader is used; the engine
    /// variant snapshots the handle value, the `std.Io` variant shares the
    /// cursor with `self`. Reader/writer use while this file moves is
    /// caller error.
    pub fn reader(self: *File, buffer: []u8) Reader {
        return switch (self.*) {
            .engine => |f| .{ .engine = f.reader(buffer) },
            .host => |*f| .{ .host = HostFile.Reader.init(f, buffer) },
        };
    }

    /// Streaming, buffered writer view onto an open file: the caller-owned
    /// `buffer` (which must be non-empty) accumulates written bytes and is
    /// drained to the backend once full or on explicit `interface.flush()`
    /// / `File.flush()`.
    ///
    /// The writer borrows this file like `reader()` does.
    pub fn writer(self: *File, buffer: []u8) Writer {
        return switch (self.*) {
            .engine => |f| .{ .engine = f.writer(buffer) },
            .host => |*f| .{ .host = HostFile.Writer.init(f, buffer) },
        };
    }

    /// Streaming reader over an open file, one backend per variant. Both
    /// variants expose a `.interface` field of the same type
    /// (`std.Io.Reader`); use `interface()` to address it variant-
    /// independently.
    ///
    /// The backend handle is borrowed, not owned: closing the file while
    /// readers/writers are active on it is caller error.
    pub const Reader = union(enum) {
        /// Engine-backed view (see `SourceFile.Reader`).
        engine: SourceFile.Reader,
        /// `std.Io`-backed view (see `HostFile.Reader`).
        host: HostFile.Reader,

        /// The standard's streaming reader interface; see std.Io.Reader.
        /// Points into this reader's storage, which must not move while
        /// the interface is in use (see `File.reader()`).
        pub fn interface(self: *Reader) *std.Io.Reader {
            return switch (self.*) {
                inline else => |*inner| &inner.interface,
            };
        }
    };

    /// Streaming writer over an open file, one backend per variant; see
    /// `Reader` for the variant-independent `.interface` access and the
    /// fixed-address requirement (see `File.writer()`).
    pub const Writer = union(enum) {
        /// Engine-backed view (see `SourceFile.Writer`).
        engine: SourceFile.Writer,
        /// `std.Io`-backed view (see `HostFile.Writer`).
        host: HostFile.Writer,

        /// The standard's streaming writer interface; see std.Io.Writer.
        /// Points into this writer's storage, which must not move while
        /// the interface is in use (see `File.writer()`).
        pub fn interface(self: *Writer) *std.Io.Writer {
            return switch (self.*) {
                inline else => |*inner| &inner.interface,
            };
        }
    };
};

// --- Source Engine file I/O --------------------------------------------------

/// A file opened through the engine filesystem.
///
/// Lifecycle: created by `SourceFile.open()`; the engine handle stays valid
/// until `SourceFile.close()`, after which `handle` must not be used.
///
/// Only `.game`-scheme paths may be opened this way: `game://` content
/// resolves inside the engine's search paths and pack files, which only
/// the engine can see (docs/references/source-sdk/filesystem.md §12).
pub const SourceFile = struct {
    /// The engine filesystem binding the handle was created through.
    fs: SourceFilesystem,
    /// The engine's `FileHandle_t` for this file; only meaningful for the
    /// exact `fs` that produced it.
    handle: Handle,

    /// Opens `path` through the engine filesystem.
    ///
    /// The path's permission set is enforced first (`.read` mode needs read
    /// bits, `.write`/`.append` need write bits), then the path is
    /// translated into an engine name + pathID `GAME` (the engine already
    /// mounts the tf directory there, no engine state is changed).
    ///
    /// This follows filesystem.md's rule that engine-mediated file use must
    /// go via pathIDs and respect the WritePath instead of absolute paths
    /// (filesystem.md §3, §10.3).
    pub fn open(fs: SourceFilesystem, path: ZorcererPath, mode: Mode) OpenError!SourceFile {
        if (path.scheme != .game) return error.OperationNotAllowed;
        try checkPermission(path, switch (mode) {
            .read => Permission.read,
            .write, .append => Permission.write,
        });

        const root = game_root orelse return error.OperationNotAllowed;
        const engine_name = relativeUnder(root, path.absolute_path, true) orelse
            return error.OperationNotAllowed;

        var name_buf: [max_engine_name_len]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{engine_name}) catch
            return error.NameTooLong;

        const handle = fs.abi.open(fs.interface, name.ptr, optionsString(mode).ptr, game_path_id) orelse
            return error.OpenFailed;

        return SourceFile{ .fs = fs, .handle = handle };
    }

    /// Closes the engine handle. After this call the handle is stale and
    /// this file must not be used again, not even `close()` twice.
    pub fn close(self: *SourceFile) void {
        self.fs.abi.close(self.fs.interface, self.handle);
    }

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
    pub fn size(self: *const SourceFile) SizeError!usize {
        return @intCast(self.fs.abi.size(self.fs.interface, self.handle));
    }

    /// Asks the engine to flush its buffers for this file. Flush failures
    /// are unobservable (the engine's Flush is void); data still pending in
    /// a `Writer` buffer must be flushed there first.
    pub fn flush(self: *const SourceFile) FlushError!void {
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

/// The engine open option strings behind `Mode`'s variants, exact spelling
/// as used by game code [checkout: nav_file.cpp:1241 "rb",
/// ai_networkmanager.cpp:351 "wb", physics.cpp:2910 "ab"].
fn optionsString(mode: Mode) [:0]const u8 {
    return switch (mode) {
        .read => "rb",
        .write => "wb",
        .append => "ab",
    };
}

// --- std.Io file I/O (plugin:// backend) --------------------------------------

/// A file opened through `std.Io` (the host OS filesystem).
///
/// This is the backend for `plugin://` content: the Zorcerer installation
/// tree is plain host storage, not engine content, so it is touched via
/// `std.Io` and its failures report real host conditions (mapped to the
/// coarse shared error sets of `File`, docs/references/source-sdk/
/// filesystem.md §12).
///
/// The read/write pointer is tracked in `position` (explicitly, since
/// `std.Io.File` pairs positional reads/writes with explicit offsets rather
/// than a shared cursor); the same pointer serves `seek()`/`tell()`.
pub const HostFile = struct {
    /// The `std.Io` instance this file performs its I/O through.
    io: std.Io,
    /// The host file opened from `path`.
    file: std.Io.File,
    /// Current read/write pointer as an offset from the file start.
    position: u64,

    /// Opens `path` through `std.Io`.
    ///
    /// The path's permission set is enforced first (`.read` mode needs read
    /// bits, `.write`/`.append` need write bits); only `.plugin`-scheme
    /// paths strictly under the configured `zorcerer_root` are accepted
    /// (the root itself is not openable as a file), everything else is
    /// refused so hand-built paths cannot escape the plugin tree.
    ///
    /// Mode mapping:
    /// - `.read`: opens an existing file (`dir.openFileAbsolute`); the
    ///   pointer starts at 0.
    /// - `.write`: creates or truncates the file
    ///   (`dir.createFileAbsolute`, truncate); the pointer starts at 0.
    /// - `.append`: creates the file or opens it untruncated
    ///   (`dir.createFileAbsolute`, truncate off); the pointer starts at
    ///   the current end (`length()`).
    ///
    /// Note: unlike the engine mapper, `std.Io` does not create missing
    /// parent directories; the parent of `path` must already exist for
    /// write/append modes.
    pub fn open(io: std.Io, path: ZorcererPath, mode: Mode) OpenError!HostFile {
        if (path.scheme != .plugin) return error.OperationNotAllowed;
        try checkPermission(path, switch (mode) {
            .read => Permission.read,
            .write, .append => Permission.write,
        });

        const root = zorcerer_root orelse return error.OperationNotAllowed;
        if (relativeUnder(root, path.absolute_path, true) == null)
            return error.OperationNotAllowed;

        const file = switch (mode) {
            .read => std.Io.Dir.openFileAbsolute(io, path.absolute_path, .{}) catch
                return error.OpenFailed,
            .write => std.Io.Dir.createFileAbsolute(io, path.absolute_path, .{}) catch
                return error.OpenFailed,
            .append => std.Io.Dir.createFileAbsolute(io, path.absolute_path, .{ .truncate = false }) catch
                return error.OpenFailed,
        };

        var position: u64 = 0;
        if (mode == .append) {
            position = file.length(io) catch {
                file.close(io);
                return error.OpenFailed;
            };
        }

        return HostFile{ .io = io, .file = file, .position = position };
    }

    /// Closes the host file. After this call the file is stale and this
    /// file must not be used again, not even `close()` twice (closing a
    /// `std.Io.File` twice is a checked illegal behavior).
    pub fn close(self: *HostFile) void {
        self.file.close(self.io);
    }

    /// Reads the next chunk, reporting how many bytes landed in `buffer`
    /// (may be short); reaching 0 signals end of stream. The read is
    /// positional at this file's pointer and advances it by the reported
    /// byte count.
    pub fn read(self: *HostFile, buffer: []u8) ReadError!usize {
        if (buffer.len == 0) return 0;
        const bytes_read = self.file.readPositional(self.io, &.{buffer}, self.position) catch
            return error.ReadFailed;
        self.position += bytes_read;
        return bytes_read;
    }

    /// Fills `buffer` as far as the file goes, returning the number of
    /// bytes read (equal to `buffer.len` unless end of stream was hit).
    pub fn readAll(self: *HostFile, buffer: []u8) ReadError!usize {
        var filled: usize = 0;
        while (filled != buffer.len) {
            const bytes_read = try self.read(buffer[filled..]);
            if (bytes_read == 0) break;
            filled += bytes_read;
        }
        return filled;
    }

    /// Writes what one `std.Io` positional write accepts at this file's
    /// pointer, advancing the pointer by the reported byte count.
    pub fn write(self: *HostFile, buffer: []const u8) WriteError!usize {
        if (buffer.len == 0) return 0;
        const bytes_written = self.file.writePositional(self.io, &.{buffer}, self.position) catch
            return error.WriteFailed;
        self.position += bytes_written;
        return bytes_written;
    }

    /// Writes the whole `buffer` or fails; zero-progress write calls are
    /// reported as `error.WriteFailed` instead of looping.
    pub fn writeAll(self: *HostFile, buffer: []const u8) WriteError!void {
        var sent: usize = 0;
        while (sent != buffer.len) {
            const bytes_written = try self.write(buffer[sent..]);
            if (bytes_written == 0) return error.WriteFailed;
            sent += bytes_written;
        }
    }

    /// Moves this file's read/write pointer: `start` offsets are absolute
    /// (expected non-negative), `current`/`end` offsets move the pointer
    /// relative to their anchor and may be negative, which is how back-
    /// seeks are expressed. A computed target below 0 is `error.SeekFailed`;
    /// arithmetic that cannot represent the target is `PositionOverflow`.
    ///
    /// Seeking past the end is allowed (host behavior); the gap reads as
    /// zero bytes later.
    pub fn seek(self: *HostFile, offset: i64, from: SeekFrom) SeekError!void {
        const anchor: i128 = switch (from) {
            .start => if (offset < 0) return error.SeekFailed else 0,
            .current, .end => self.position,
        };
        const target: i128 = anchor + offset;
        if (target < 0) return error.SeekFailed;
        if (target > std.math.maxInt(u64)) return error.PositionOverflow;
        self.position = @intCast(target);
    }

    /// Current read/write pointer as an offset from the file start; tracks
    /// direct `read()`/`write()`/`seek()` calls on this file.
    pub fn tell(self: *const HostFile) usize {
        return @intCast(self.position);
    }

    /// File size as reported by the host (`std.Io` stat).
    pub fn size(self: *const HostFile) SizeError!usize {
        return @intCast(self.file.length(self.io) catch return error.SizeFailed);
    }

    /// Asks the host to flush file data to storage (`sync`); a failure is
    /// reported instead of being silently dropped. Data still pending in a
    /// `Writer` buffer must be flushed there first.
    pub fn flush(self: *const HostFile) FlushError!void {
        self.file.sync(self.io) catch return error.FlushFailed;
    }

    /// Deletes `path` through `std.Io` (the host OS filesystem).
    ///
    /// Deleting requires write access, so the path's permission set is
    /// enforced first; only `.plugin`-scheme paths strictly under the
    /// configured `zorcerer_root` are accepted (the root itself is not a
    /// file), everything else is refused so hand-built paths cannot escape
    /// the plugin tree.
    ///
    /// This is a static operation: no file needs to be open. It deletes one
    /// existing file and does not recurse into directories.
    ///
    /// Errors: `error.PermissionDenied` when the path is read-only,
    /// `error.OperationNotAllowed` for non-`.plugin` or out-of-root paths,
    /// and `error.RemoveFailed` when the OS refused the deletion (missing
    /// file, directory, or insufficient OS permission).
    pub fn remove(io: std.Io, path: ZorcererPath) RemoveError!void {
        if (path.scheme != .plugin) return error.OperationNotAllowed;
        try checkPermission(path, .write);

        const root = zorcerer_root orelse return error.OperationNotAllowed;
        if (relativeUnder(root, path.absolute_path, true) == null)
            return error.OperationNotAllowed;

        std.Io.Dir.deleteFileAbsolute(io, path.absolute_path) catch return error.RemoveFailed;
    }

    /// Streaming, buffered reader borrowing an open host file: `buffer`
    /// (which must be non-empty) is the caller-owned window the standard
    /// interface fills from the file via `HostFile.read()`, so reads
    /// advance the file's shared cursor (`position`).
    ///
    /// Lifetime: `file` must outlive this reader and stay at a fixed
    /// address (the file borrows are created from `File.reader()`, which
    /// hands out the address of the open `File`).
    pub const Reader = struct {
        file: *HostFile,
        /// The standard's streaming reader interface; see std.Io.Reader.
        interface: std.Io.Reader,

        /// Builds the adapter around `file`; `buffer.len` must be nonzero.
        pub fn init(file: *HostFile, buffer: []u8) Reader {
            std.debug.assert(buffer.len > 0);
            return .{
                .file = file,
                .interface = .{
                    .vtable = &.{ .stream = streamHostFile },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }
    };

    /// Streaming, buffered writer borrowing an open host file: the
    /// caller-owned `buffer` (which must be non-empty) accumulates written
    /// bytes and is drained to the file via `HostFile.write()`, so drains
    /// advance the file's shared cursor (`position`).
    ///
    /// Lifetime: same borrow rule as `Reader`.
    pub const Writer = struct {
        file: *HostFile,
        /// The standard's streaming writer interface; see std.Io.Writer.
        interface: std.Io.Writer,

        /// Builds the adapter around `file`; `buffer.len` must be nonzero.
        pub fn init(file: *HostFile, buffer: []u8) Writer {
            std.debug.assert(buffer.len > 0);
            return .{
                .file = file,
                .interface = .{
                    .vtable = &.{ .drain = drainHostFile },
                    .buffer = buffer,
                },
            };
        }
    };
};

// --- `std.Io` adapters for HostFile --------------------------------------------

/// `std.Io.Reader.VTable.stream` for `HostFile.Reader`: pulls bytes from
/// the borrowed host file into the sink (or, for small limits, straight
/// into the sink's buffer). Host end-of-file (`HostFile.read()` returning
/// 0) surfaces as `error.EndOfStream`, short reads as a short return, host
/// failures as `error.ReadFailed`.
fn streamHostFile(
    self: *std.Io.Reader,
    w: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    const reader: *HostFile.Reader = @alignCast(@fieldParentPtr("interface", self));

    if (limit == .nothing) return 0;

    const dest = limit.slice(try w.writableSliceGreedy(1));
    if (dest.len == 0) return 0;

    const bytes_read = reader.file.read(dest) catch {
        // The host failed; surface it as the standard's read failure.
        return error.ReadFailed;
    };
    if (bytes_read == 0) return error.EndOfStream;

    w.advance(bytes_read);
    return bytes_read;
}

/// `std.Io.Writer.VTable.drain` for `HostFile.Writer`: writes the buffer
/// content, then each `data` component (the last repeated `splat` times)
/// through the borrowed host file, consuming what got written. Host
/// failures surface as `error.WriteFailed`.
fn drainHostFile(
    self: *std.Io.Writer,
    data: []const []const u8,
    splat: usize,
) std.Io.Writer.Error!usize {
    const writer: *HostFile.Writer = @alignCast(@fieldParentPtr("interface", self));

    var written: usize = 0;

    // The interface contract: buffer content is consumed first, followed by
    // every slice of `data`, then `data[data.len - 1]` repeated `splat`
    // times.
    written += try fileWriteToHost(writer, self.buffered());
    for (data[0 .. data.len - 1]) |chunk| {
        written += try fileWriteToHost(writer, chunk);
    }
    if (splat > 0) {
        const repeated = data[data.len - 1];
        var remaining = splat;
        while (remaining > 0) : (remaining -= 1) {
            written += try fileWriteToHost(writer, repeated);
        }
    }

    return self.consume(written);
}

/// Writes `chunk` completely through `HostFile.write()`; zero-progress
/// host responses are a hard failure rather than an infinite loop.
fn fileWriteToHost(writer: *HostFile.Writer, chunk: []const u8) std.Io.Writer.Error!usize {
    var sent: usize = 0;
    while (sent != chunk.len) {
        const n = writer.file.write(chunk[sent..]) catch return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        sent += n;
    }
    return sent;
}

// --- Source Engine directory I/O ---------------------------------------------

/// A directory enumeration session ("opened directory") in the engine FS.
///
/// The Source filesystem has no directory handles: the closest equivalent
/// is its find session (`FindFirstEx`/`FindNext`/`FindIsDirectory`/
/// `FindClose`, filesystem.h:647-650, used like nav_file.cpp:1295-1330
/// [checkout]), which is what this type wraps.
///
/// Lifecycle: created by `SourceDirectory.open()`, entries pulled by
/// `next()`, session terminated by `close()`.
///
/// Only `.game`-scheme directories may be opened this way (see `File`).
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

    /// One filesystem entry reported by `next()`.
    pub const Entry = struct {
        /// Entry name relative to the opened directory, sliced from
        /// `next()`'s buffer and valid until the next call.
        name: []const u8,
        /// Whether the entry is itself a directory (can be opened as one).
        is_directory: bool,
    };

    /// Errors of entry enumeration; `error.IoFailed` is unreachable for the
    /// engine backend but part of the shared contract.
    pub const EntryError = error{
        /// An engine entry name does not fit `next()`'s buffer.
        NameTooLong,
        /// Host only: the underlying `std.Io` iteration failed.
        IoFailed,
    };

    /// Starts a find session over `path`'s content (the wildcard
    /// `<path>/*`, or `*` for the tree root itself) in pathID `GAME`.
    /// Read permission is enforced. Opening an unmatchable pattern yields
    /// an empty session instead of an error (the engine reports that
    /// condition via `invalid_find_handle`/null).
    pub fn open(fs: SourceFilesystem, path: ZorcererPath) OpenError!SourceDirectory {
        if (path.scheme != .game) return error.OperationNotAllowed;
        try checkPermission(path, .read);

        const root = game_root orelse return error.OperationNotAllowed;
        const engine_name = relativeUnder(root, path.absolute_path, false) orelse
            return error.OperationNotAllowed;

        var pattern_buf: [max_engine_name_len]u8 = undefined;
        const wildcard: [*:0]const u8 = if (engine_name.len == 0)
            "*"
        else
            (std.fmt.bufPrintZ(&pattern_buf, "{s}/*", .{engine_name}) catch
                return error.NameTooLong).ptr;

        var find_handle: FindHandle = invalid_find_handle;
        const first = fs.abi.find_first_ex(fs.interface, wildcard, game_path_id, &find_handle);

        var session = SourceDirectory{ .fs = fs, .find_handle = find_handle };

        if (first) |engine_first| {
            // See through the zero terminator: `engine_first` is a
            // `[*:0]const u8`, so a raw `[0..len]` slice would carry no
            // length and fail `@memcpy`'s operand checks.
            const bytes = std.mem.span(engine_first);
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
        const engine_name = self.fs.abi.find_next(self.fs.interface, self.find_handle) orelse return null;

        const name = std.mem.span(engine_name);
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

// --- std.Io directory I/O (plugin:// backend) ---------------------------------

/// A directory enumeration session over `std.Io` (the host OS filesystem):
/// this is the backend for `plugin://` directories, wrapped around
/// `std.Io.Dir.Iterator`.
///
/// Lifecycle: created by `HostDirectory.open()`, entries pulled by `next()`,
/// session terminated by `close()` (which releases the opened directory
/// handle; dropping the handle without closing it is a checked illegal
/// behavior).
pub const HostDirectory = struct {
    /// The `std.Io` instance this session performs its I/O through.
    io: std.Io,
    /// The opened directory handle, released by `close()`.
    dir: std.Io.Dir,
    /// The live iterator state; advanced by `next()`.
    iterator: std.Io.Dir.Iterator,

    /// Opens `path` for enumeration through `std.Io`.
    ///
    /// Read permission is enforced; only `.plugin`-scheme paths at or under
    /// the configured `zorcerer_root` are accepted (opening the root
    /// itself is allowed), everything else is refused so hand-built paths
    /// cannot escape the plugin tree.
    pub fn open(io: std.Io, path: ZorcererPath) OpenError!HostDirectory {
        if (path.scheme != .plugin) return error.OperationNotAllowed;
        try checkPermission(path, .read);

        const root = zorcerer_root orelse return error.OperationNotAllowed;
        if (relativeUnder(root, path.absolute_path, false) == null)
            return error.OperationNotAllowed;

        const dir = std.Io.Dir.openDirAbsolute(io, path.absolute_path, .{ .iterate = true }) catch
            return error.OpenFailed;

        // The handle is fresh and its cursor unmodified, so starting from
        // the reading state is valid per `std.Io.Dir`.
        return HostDirectory{ .io = io, .dir = dir, .iterator = dir.iterateAssumeFirstIteration() };
    }

    /// Copies the next entry's name into `name_buffer` and reports it with
    /// its directory flag; `null` once the session is exhausted. The
    /// returned `name` slice points into `name_buffer` and is valid until
    /// the next `next()` call (the host iterator invalidates its entry
    /// names across calls, same as the engine's find session).
    pub fn next(self: *HostDirectory, name_buffer: []u8) SourceDirectory.EntryError!?SourceDirectory.Entry {
        const entry = self.iterator.next(self.io) catch return error.IoFailed;
        const source_entry = entry orelse return null;

        if (source_entry.name.len > name_buffer.len) return error.NameTooLong;
        @memcpy(name_buffer[0..source_entry.name.len], source_entry.name);
        return SourceDirectory.Entry{
            .name = name_buffer[0..source_entry.name.len],
            .is_directory = source_entry.kind == .directory,
        };
    }

    /// Ends the session and releases the directory handle. This call
    /// performs exactly one `dir.close()` and must be the last operation
    /// on this session (`std.Io.Dir` checks dropping opened handles as
    /// illegal).
    pub fn close(self: *HostDirectory) void {
        self.dir.close(self.io);
    }
};

// --- Unified directory ---------------------------------------------------------

/// A directory enumeration session over `Directory`'s backend selected by
/// the path's scheme (see `File`): `.game` through the engine's find
/// session (`SourceDirectory`), `.plugin` through `std.Io`
/// (`HostDirectory`).
///
/// Lifecycle: created by `open()`, entries pulled by `next()`, session
/// terminated by `close()`.
pub const Directory = union(enum) {
    /// `game://` content, enumerated through the engine filesystem.
    engine: SourceDirectory,
    /// `plugin://` content, enumerated through `std.Io`.
    host: HostDirectory,

    /// One filesystem entry reported by `next()`.
    pub const Entry = SourceDirectory.Entry;

    /// Errors of entry enumeration (see `SourceDirectory.EntryError`).
    pub const EntryError = SourceDirectory.EntryError;

    /// Starts a session over the directory `path` through the backend its
    /// `scheme` selects; `fs` is only consulted for `.game` paths (see
    /// `File.open()` for the `EngineNotBound` contract).
    pub fn open(io: std.Io, fs: ?SourceFilesystem, path: ZorcererPath) OpenError!Directory {
        return switch (path.scheme) {
            .game => .{ .engine = try SourceDirectory.open(fs orelse return error.EngineNotBound, path) },
            .plugin => .{ .host = try HostDirectory.open(io, path) },
        };
    }

    /// Copies the next entry's name into `name_buffer` and reports it with
    /// its directory flag; `null` once the session is exhausted. The
    /// returned `name` slice points into `name_buffer` and is valid until
    /// the next `next()` call.
    pub fn next(self: *Directory, name_buffer: []u8) EntryError!?Entry {
        return switch (self.*) {
            inline else => |*session| try session.next(name_buffer),
        };
    }

    /// Ends the session; see the per-backend `close()` documentation.
    pub fn close(self: *Directory) void {
        switch (self.*) {
            inline else => |*session| session.close(),
        }
    }
};

// --- Host path/state internals ------------------------------------------------

/// Returns `absolute` stripped off the `root` prefix, or null when
/// `absolute` is not strictly under `root` (`require_inside`) resp. not at
/// or under it. Roots are expected without a trailing separator; a root of
/// "" means unconfigured and matches nothing.
///
/// Both backends use this to refuse hand-built paths outside their
/// configured tree: the engine cannot resolve names outside its search
/// paths at all, and the `std.Io` backend must not touch files outside the
/// plugin tree even though it could.
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

// --- Tests ---------------------------------------------------------------------

const test_zorcerer_root = "/steamapps/zorcerer";
const test_game_root = "/steamapps/team fortress 2/tf";

/// The `std.Io` instance the test runner owns; used for host-backend tests
/// and enumerations.
const test_io = std.testing.io;

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
    try std.testing.expectEqual(Scheme.game, resolved.scheme);
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
    try std.testing.expectEqual(Scheme.plugin, resolved.scheme);
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

// --- Mock engine filesystem (tests) -------------------------------------------

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
    .find_first_ex = mockFindFirstEx,
    .find_next = mockFindNext,
    .find_is_directory = mockFindIsDirectory,
    .find_close = mockFindClose,
};

/// Wraps `engine` into a full engine filesystem binding with the mock ABI.
fn mockFilesystem(engine: *MockFs) SourceFilesystem {
    return SourceFilesystem{ .interface = @ptrCast(engine), .abi = mock_abi };
}

// --- Source Engine I/O tests ---------------------------------------------------

test "SourceFile.open resolves game:// into the game pathID" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
    }
    setGameRoot(test_game_root);
    setZorcererRoot(test_zorcerer_root);

    var plugin_ctx = mockContext();
    const path = try parsePath(&plugin_ctx, "game://maps/arena.bsp");

    var engine = MockFs{};
    var file = try SourceFile.open(mockFilesystem(&engine), path, .read);
    defer file.close();

    // The tf directory is already mounted by the engine as GAME; no
    // engine state changes are needed, and the open went through pathID GAME.
    try std.testing.expectEqual(@as(usize, 1), engine.open_calls);
    try std.testing.expectEqualStrings("maps/arena.bsp", engine.opened_name[0..engine.opened_name_len]);
    try std.testing.expectEqualStrings("rb", engine.opened_options[0..engine.opened_options_len]);
    try std.testing.expectEqualStrings(game_path_id, engine.opened_path_id[0..engine.opened_path_id_len]);
}

test "SourceFile.open enforces permissions and refuses non-game paths" {
    const saved_game_root = game_root;
    const saved_zorcerer_root = zorcerer_root;
    defer {
        game_root = saved_game_root;
        zorcerer_root = saved_zorcerer_root;
    }
    setGameRoot(test_game_root);
    setZorcererRoot(test_zorcerer_root);

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

    // A manually built path outside the game root must be refused.
    const foreign = ZorcererPath{
        .absolute_path = "/etc/passwd",
        .permissions = read_only_permissions,
        .scheme = .game,
    };
    var engine_state2 = MockFs{};
    try std.testing.expectError(
        error.OperationNotAllowed,
        SourceFile.open(mockFilesystem(&engine_state2), foreign, .read),
    );
    try std.testing.expectEqual(@as(usize, 0), engine_state2.open_calls);

    // The engine backend never serves plugin:// paths; those route to
    // std.Io (see HostFile.open and File.open).
    var engine_state3 = MockFs{};
    try std.testing.expectError(
        error.OperationNotAllowed,
        SourceFile.open(mockFilesystem(&engine_state3), plugin_path, .read),
    );
    try std.testing.expectEqual(@as(usize, 0), engine_state3.open_calls);
}

test "SourceDirectory enumerates game:// entries and closes the find session" {
    const saved_game_root = game_root;
    defer game_root = saved_game_root;
    setGameRoot(test_game_root);

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
    defer game_root = saved_game_root;
    setGameRoot(test_game_root);

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

test "SourceFile.read/write/seek round trip through the engine ABI" {
    const saved_game_root = game_root;
    defer game_root = saved_game_root;
    setGameRoot(test_game_root);

    // game:// URIs are read-only by policy, so the URI layer never hands
    // out a writable engine path; the engine ABI still supports "wb"
    // opens [checkout: ai_networkmanager.cpp:351], which the mock ABI here
    // exercises through a path explicitly granted write permission.
    const game_path = ZorcererPath{
        .absolute_path = test_game_root ++ "/mockroundtrip/file",
        .permissions = read_write_permissions,
        .scheme = .game,
    };

    var engine = MockFs{};
    const fs = mockFilesystem(&engine);
    var file = try SourceFile.open(fs, game_path, .write);
    try file.writeAll("hello world");
    file.close();

    // Switch the mock's file content to what was written above.
    engine.content = engine.write_buffer[0..engine.write_len];
    file = try SourceFile.open(fs, game_path, .read);

    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("hello world", buffer[0..try file.readAll(&buffer)]);
    try std.testing.expectEqual(@as(usize, 11), file.tell());
    try std.testing.expectEqual(@as(usize, 11), try file.size());

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

    try file.flush();
    file.close();
}

test "SourceFile.Reader streams reads across buffer fills" {
    const saved_game_root = game_root;
    defer game_root = saved_game_root;
    setGameRoot(test_game_root);

    var plugin_ctx = mockContext();
    const game_path = try parsePath(&plugin_ctx, "game://mockreader/file");

    var engine = MockFs{ .content = "0123456789" };
    const fs = mockFilesystem(&engine);
    var file = try SourceFile.open(fs, game_path, .read);

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
    defer game_root = saved_game_root;
    setGameRoot(test_game_root);

    // Same grant as the read/write/seek test: writable engine paths do not
    // come from game:// URIs (read-only), so the test hand-builds one to
    // exercise the engine write ABI against the mock.
    const game_path = ZorcererPath{
        .absolute_path = test_game_root ++ "/mockwriter/file",
        .permissions = read_write_permissions,
        .scheme = .game,
    };

    var engine = MockFs{};
    const fs = mockFilesystem(&engine);
    var file = try SourceFile.open(fs, game_path, .write);

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
    try file.flush();
    try std.testing.expectEqual(@as(usize, 1), engine.flushed_calls);

    file.close();
}

// --- std.Io plugin:// backend tests (real host I/O, via tmpDir) ---------------

/// Per-test fixture for host-backend tests: binds a temp Zorcerer root and
/// creates the mock context's plugin directory (`plugins/hello`; the
/// `std.Io` backend does not create parent directories). The caller owns
/// the returned state and must free `root` and call `tmp.cleanup()` when
/// done; `setZorcererRoot(null)` restores the module state.
const TestFixture = struct {
    /// The temporary dir; `tmp.cleanup()` removes its subtrees.
    tmp: std.testing.TmpDir,
    /// Absolute temp Zorcerer root, allocated with `std.testing.allocator`,
    /// also bound as `zorcerer_root`.
    root: []u8,
};

/// Returns the fixture for host-backend tests.
///
/// Errors are programmer error (initialization happens exactly once):
/// failures panic rather than reuse the fixture.
fn setupPluginRoot() !TestFixture {
    var tmp = std.testing.tmpDir(.{});

    // Absolute root for `plugin://` URI resolution; allocated because the
    // module keeps the pointer and uses it after this function returns.
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(test_io, &path_buffer);
    const root = try std.testing.allocator.dupe(u8, path_buffer[0..root_len]);
    errdefer std.testing.allocator.free(root);
    setZorcererRoot(root);

    // Create the mocked plugin's directory (the parent every resolved
    // plugin:// file lives in) so writes below it succeed.
    var plugin_dir = try tmp.dir.createDirPathOpen(test_io, "plugins/hello", .{});
    plugin_dir.close(test_io);

    return .{ .tmp = tmp, .root = root };
}

/// Frees the fixture and restores the module state.
fn tearDownPluginRoot(fixture: *TestFixture) void {
    fixture.tmp.cleanup();
    std.testing.allocator.free(fixture.root);
    zorcerer_root = null;
    fixture.* = undefined;
}

test "File.open routes plugin:// through std.Io and game:// through the engine" {
    var fixture = try setupPluginRoot();
    defer tearDownPluginRoot(&fixture);

    var plugin_ctx = mockContext();
    const plugin_path = try parsePath(&plugin_ctx, "plugin://routing.cfg");

    // plugin:// needs no engine binding.
    var file = try File.open(test_io, null, plugin_path, .write);
    try file.writeAll("host");
    file.close();

    const saved_game_root = game_root;
    defer game_root = saved_game_root;
    setGameRoot(test_game_root);
    const game_path = try parsePath(&plugin_ctx, "game://maps/arena.bsp");

    // game:// without a binding is refused...
    try std.testing.expectError(error.EngineNotBound, File.open(test_io, null, game_path, .read));

    // ...and with one routes through the engine backend.
    var engine = MockFs{};
    var bound = try File.open(test_io, mockFilesystem(&engine), game_path, .read);
    try std.testing.expectEqual(std.meta.activeTag(bound), .engine);
    try std.testing.expectEqual(@as(usize, 1), engine.open_calls);
    try std.testing.expectEqualStrings(game_path_id, engine.opened_path_id[0..engine.opened_path_id_len]);
    bound.close();

    // Verify the host backend actually created the plugin:// file.
    var check = try File.open(test_io, null, plugin_path, .read);
    defer check.close();
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("host", buffer[0..try check.readAll(&buffer)]);
}

test "HostFile read/write/seek round trip" {
    var fixture = try setupPluginRoot();
    defer tearDownPluginRoot(&fixture);

    var plugin_ctx = mockContext();
    const plugin_path = try parsePath(&plugin_ctx, "plugin://roundtrip.cfg");

    var file = try File.open(test_io, null, plugin_path, .write);
    try file.writeAll("hello world");
    try std.testing.expectEqual(@as(usize, 11), file.tell());
    try std.testing.expectEqual(@as(usize, 11), try file.size());
    try file.flush();
    file.close();

    file = try File.open(test_io, null, plugin_path, .read);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("hello world", buffer[0..try file.readAll(&buffer)]);
    try std.testing.expectEqual(@as(usize, 11), file.tell());
    try std.testing.expectEqual(@as(usize, 11), try file.size());

    // Back-seek by absolute offset.
    try file.seek(4, .start);
    try std.testing.expectEqual(@as(usize, 4), file.tell());
    try std.testing.expectEqualStrings("o world", buffer[0..try file.readAll(&buffer)]);

    // Relative back-seek from the end.
    try file.seek(-5, .end);
    try std.testing.expectEqual(@as(usize, 6), file.tell());
    try std.testing.expectEqualStrings("world", buffer[0..try file.readAll(&buffer)]);
    file.close();
}

test "HostFile append keeps existing content and heads writes to the end" {
    var fixture = try setupPluginRoot();
    defer tearDownPluginRoot(&fixture);

    var plugin_ctx = mockContext();
    const plugin_path = try parsePath(&plugin_ctx, "plugin://append.log");

    var file = try File.open(test_io, null, plugin_path, .write);
    try file.writeAll("abc");
    file.close();

    file = try File.open(test_io, null, plugin_path, .append);
    try std.testing.expectEqual(@as(usize, 3), file.tell());
    try file.writeAll("de");
    try std.testing.expectEqual(@as(usize, 5), file.tell());
    file.close();

    file = try File.open(test_io, null, plugin_path, .read);
    defer file.close();
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("abcde", buffer[0..try file.readAll(&buffer)]);
}

test "HostFile refuses paths outside the configured plugin root" {
    var fixture = try setupPluginRoot();
    defer tearDownPluginRoot(&fixture);

    var plugin_ctx = mockContext();
    var engine = MockFs{};

    // A plugin path pointing at the Zorcerer installation root itself is
    // not openable as a file.
    const root_path = ZorcererPath{
        .absolute_path = zorcerer_root.?,
        .permissions = read_write_permissions,
        .scheme = .plugin,
    };
    try std.testing.expectError(
        error.OperationNotAllowed,
        HostFile.open(test_io, root_path, .write),
    );

    // Hand-built plugin paths without the configured prefix are refused.
    const foreign = ZorcererPath{
        .absolute_path = "/etc/passwd",
        .permissions = read_write_permissions,
        .scheme = .plugin,
    };
    try std.testing.expectError(
        error.OperationNotAllowed,
        File.open(test_io, mockFilesystem(&engine), foreign, .read),
    );

    // The engine backend refuses plugin:// paths; those route to std.Io.
    const plugin_path = try parsePath(&plugin_ctx, "plugin://schemes.cfg");
    try std.testing.expectError(
        error.OperationNotAllowed,
        SourceFile.open(mockFilesystem(&engine), plugin_path, .write),
    );
    try std.testing.expectEqual(@as(usize, 0), engine.open_calls);
}

test "HostFile read of a missing file fails coarsely" {
    var fixture = try setupPluginRoot();
    defer tearDownPluginRoot(&fixture);

    var plugin_ctx = mockContext();
    const missing = try parsePath(&plugin_ctx, "plugin://no_such_file.cfg");

    try std.testing.expectError(error.OpenFailed, File.open(test_io, null, missing, .read));
}

test "File.Reader streams plugin:// reads across buffer fills" {
    var fixture = try setupPluginRoot();
    defer tearDownPluginRoot(&fixture);

    var plugin_ctx = mockContext();
    const stream_path = try parsePath(&plugin_ctx, "plugin://streamed.dat");

    // Seed content through the same backend.
    var file = try File.open(test_io, null, stream_path, .write);
    try file.writeAll("0123456789");
    file.close();

    file = try File.open(test_io, null, stream_path, .read);
    var window: [6]u8 = undefined;
    var buffer: [6]u8 = undefined;
    var r = file.reader(&window);
    defer file.close();

    try r.interface().readSliceAll(&buffer);
    try std.testing.expectEqualStrings("012345", buffer[0..6]);

    try r.interface().readSliceAll(buffer[0..4]);
    try std.testing.expectEqualStrings("6789", buffer[0..4]);

    // Exactly at end of stream now.
    try std.testing.expectError(error.EndOfStream, r.interface().takeByte());
}

test "File.Writer buffers plugin:// writes and drains on overflow and flush" {
    var fixture = try setupPluginRoot();
    defer tearDownPluginRoot(&fixture);

    var plugin_ctx = mockContext();
    const sink_path = try parsePath(&plugin_ctx, "plugin://buffered.dat");

    var file = try File.open(test_io, null, sink_path, .write);
    var sink: [4]u8 = undefined;
    var w = file.writer(&sink);

    try w.interface().writeAll("abcde");
    try w.interface().writeAll("fg");
    try w.interface().flush();
    file.close();

    file = try File.open(test_io, null, sink_path, .read);
    defer file.close();
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("abcdefg", buffer[0..try file.readAll(&buffer)]);
}

test "Directory routes plugin:// through std.Io iteration" {
    var fixture = try setupPluginRoot();
    defer tearDownPluginRoot(&fixture);

    var plugin_ctx = mockContext();
    const dir_path = try parsePath(&plugin_ctx, "plugin://content");
    // The `std.Io` backend does not create parent directories: make the
    // directory under test exist first, then fill it directly.
    try fixture.tmp.dir.createDirPath(test_io, "plugins/hello/content");
    var content_dir = try std.Io.Dir.openDirAbsolute(
        test_io,
        dir_path.absolute_path,
        .{ .iterate = true },
    );
    defer content_dir.close(test_io);

    const file = try content_dir.createFile(test_io, "unit.dat", .{ .read = true });
    file.close(test_io);
    try content_dir.createDirPath(test_io, "nested");
    var dir = try Directory.open(test_io, null, dir_path);
    defer dir.close();

    var found_file = false;
    var found_nested = false;
    var name_buffer: [64]u8 = undefined;
    while (try dir.next(&name_buffer)) |entry| {
        if (std.mem.eql(u8, entry.name, "unit.dat")) {
            found_file = true;
            try std.testing.expect(!entry.is_directory);
        } else if (std.mem.eql(u8, entry.name, "nested")) {
            found_nested = true;
            try std.testing.expect(entry.is_directory);
        }
    }
    try std.testing.expect(found_file);
    try std.testing.expect(found_nested);
}

test "File.remove deletes a plugin:// file and refuses game:// paths" {
    var fixture = try setupPluginRoot();
    defer tearDownPluginRoot(&fixture);

    var plugin_ctx = mockContext();
    const plugin_path = try parsePath(&plugin_ctx, "plugin://removable.dat");

    var file = try File.open(test_io, null, plugin_path, .write);
    try file.writeAll("temporary");
    file.close();

    try File.remove(test_io, plugin_path);

    // The file is gone: reopening it for reading now fails.
    try std.testing.expectError(error.OpenFailed, File.open(test_io, null, plugin_path, .read));

    // game:// is read-only by policy: no engine delete is attempted, and
    // the bound engine ABI has no remove method either.
    const saved_game_root = game_root;
    defer game_root = saved_game_root;
    setGameRoot(test_game_root);
    const game_path = try parsePath(&plugin_ctx, "game://materials/readme.txt");
    try std.testing.expectError(error.OperationNotAllowed, File.remove(test_io, game_path));
}
