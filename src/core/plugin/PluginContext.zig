//! ABI contract between the Zorcerer plugin manager
//! (src/core/plugin/PluginManager.zig)
//! and every native plugin it loads.
//!
//! The file is shared by both sides of the dlopen() boundary: the manager
//! imports it as the `plugin-context` build module and plugin modules import
//! the same module, so these declarations stay identical everywhere.
//!
//! Every plugin exports the two symbols shown below with C linkage
//! (Zig: `export fn`, with `callconv(.c)`):
//!
//!     load(ctx: *PluginContext) callconv(.c) c_int
//!     unload(ctx: *PluginContext) callconv(.c) c_int
//!
//! A plugin may additionally export an optional runtime-event hook:
//!
//!     onEvent(ctx: *PluginContext, event: *const Event) callconv(.c) c_int
//!
//! - The plugin manager looks both required symbols up with dlsym() and
//!   calls them through the matching function pointers; a plugin missing one
//!   of them is skipped. A missing `onEvent` is not an error and only means
//!   the plugin receives no runtime events.
//! - A plugin must check `ctx.abi_version` and `ctx.struct_size` before
//!   reading any other field. The host sets both to the contract it was
//!   compiled with; a plugin compiled against a newer contract must refuse
//!   the context instead of reading fields the host did not provide.
//! - Both functions return 0 on success. Any nonzero return value marks
//!   load() as failed; the manager then never calls that plugin's unload().
//! - `PluginContext.logger` is how a plugin prints into the server console;
//!   it is null when the host could not provide a way in.
//!
//! Ownership and lifetimes:
//! - Every `Text` in the context borrows memory owned by the plugin manager.
//!   The slices stay valid from load() until after unload() and must not be
//!   freed or modified by the plugin.
//! - The context itself, its logger pointer and all identity fields remain
//!   valid until after the plugin's unload() returns.
//! - The manager hands the same context to load(), unload() and onEvent().
//! - An `Event` and the texts it carries only live for one onEvent() call.

/// Version of this contract. The host writes it into every PluginContext;
/// a plugin compiled against a different version must return nonzero from
/// load() before using the remaining fields.
pub const abi_version: c_int = 2;

/// A borrowed, non-zero-terminated string in the plugin ABI.
///
/// Invariants: `ptr` points to at least `len` readable bytes. A zero-length
/// text may carry any pointer value but must not be dereferenced.
///
/// Ownership: plugin contexts only carry texts owned by the host. Plugins
/// must not free them and must not retain them after unload() returns.
pub const Text = extern struct {
    /// First byte of the borrowed string.
    ptr: [*]const u8,
    /// Number of borrowed bytes at `ptr`.
    len: usize,

    /// Builds a borrowed text that aliases `slice`.
    ///
    /// The caller must keep `slice` alive and unchanged for as long as the
    /// returned text may be observed. No allocation or copy is performed.
    pub fn fromSlice(bytes: []const u8) Text {
        return .{ .ptr = bytes.ptr, .len = bytes.len };
    }

    /// Returns the bytes referenced by this text.
    ///
    /// The returned slice aliases host-owned memory and is only valid while
    /// the containing PluginContext is valid. No allocation is performed.
    pub fn slice(self: Text) []const u8 {
        return self.ptr[0..self.len];
    }
};

/// A function that prints one message into the game server console.
/// `message` is zero-terminated (engine LogPrint ABI); the logger lives until
/// at least after unload() of the plugins it was handed to.
pub const Logger = extern struct {
    /// Opaque context `print` requires; implementation-defined by the
    /// host (the engine's IVEngineServer pointer for Zorcerer).
    context: *anyopaque,
    print: PrintFn,

    pub const PrintFn = *const fn (context: *anyopaque, message: [*:0]const u8) callconv(.c) void;
};

/// Identity and manifest data of the plugin receiving a PluginContext.
///
/// Every field is a borrowed view of the validated manifest the manager
/// loaded for this plugin. See Text's lifetime rules.
pub const PluginInfo = extern struct {
    /// Plugin id, which is also the plugin's directory name.
    id: Text,
    /// Human-readable display name from the manifest.
    name: Text,
    /// Semantic version string from the manifest.
    version: Text,
    /// Author string from the manifest.
    author: Text,
    /// Library path from the manifest, relative to the plugin directory.
    library_path: Text,
};

/// Context passed to a plugin's load()/unload().
///
/// Layout: `abi_version` and `struct_size` are the first two fields so a
/// plugin can validate the context before touching anything else. New
/// fields may only be appended; plugins must use `struct_size` to decide
/// which trailing fields are safe to read.
pub const PluginContext = extern struct {
    /// ABI version of this context; see `abi_version`.
    abi_version: c_int,
    /// Size of this context in bytes as provided by the host. A plugin
    /// compiled against a newer contract must treat a smaller value as an
    /// incompatible host.
    struct_size: usize,
    /// Server console sink, or null when the host has none.
    logger: ?*const Logger,
    /// Identity and manifest data of the plugin receiving this context.
    plugin: PluginInfo,
    /// Read-only game-state queries, or null when the host has no IPC channel
    /// to the engine process (for example in unit tests). Added after version
    /// 2 without changing `abi_version`; old plugins ignore it via
    /// `struct_size`.
    game: ?*const GameApi,
    /// Filesystem access, or null when the host does not provide it. Like
    /// `game`, this field was appended after version 2 without changing
    /// `abi_version`; old plugins ignore it via `struct_size`.
    files: ?*const FileApi,
    /// Outbound network access, or null when the host does not provide it.
    /// Like `game` and `files`, this field was appended after version 2
    /// without changing `abi_version`.
    network: ?*const NetworkApi,
};

/// Plugin's `load` export.
pub const LoadFn = *const fn (ctx: *PluginContext) callconv(.c) c_int;

/// Plugin's `unload` export; called only when load() returned 0.
pub const UnloadFn = *const fn (ctx: *PluginContext) callconv(.c) c_int;

/// Return value of `OnEventFn` that lets the manager deliver the same event
/// to the remaining initialized plugins.
pub const plugin_continue: c_int = 0;

/// Return value of `OnEventFn` that stops the manager from delivering the
/// same event to plugins later in load order. It cannot cancel the engine
/// action, which has already happened when a runtime event is delivered.
pub const plugin_stop: c_int = 1;

/// One runtime event handed to a plugin's `onEvent` export.
///
/// All fields are borrowed from the plugin manager and are only valid for
/// the duration of the `onEvent` call; a plugin that needs them later must
/// copy them. `struct_size` follows the same append-only rule as
/// `PluginContext`, so a plugin can reject an event it does not understand.
pub const Event = extern struct {
    /// Size of this struct in bytes as provided by the host.
    struct_size: usize,
    /// Event name, for example `pause`, `levelInit`, or `serverActivate`.
    /// The spelling matches the names Lua scripts receive.
    name: Text,
    /// Zero or more JSON-serialized parameters, or an empty text when the
    /// event carries none. The empty text must not be dereferenced.
    payload: Text,
};

/// Optional plugin `onEvent` export; called for every runtime event after
/// `load()` returned 0.
///
/// A plugin that does not export it simply receives no events. The return
/// value should be `plugin_continue`; any other value stops delivery to the
/// remaining plugins (see `plugin_stop`).
pub const OnEventFn = *const fn (ctx: *PluginContext, event: *const Event) callconv(.c) c_int;

// --- Game queries -----------------------------------------------------------

/// Status returned by a `GameApi` query: the query succeeded.
pub const query_ok: c_int = 0;
/// Status returned when the host has no engine channel or interface for the
/// query (for example before `load()` finished or after `unload()`).
pub const query_unavailable: c_int = 1;
/// Status returned when the host could not complete the query because the
/// transport to the engine process failed. The output is left unspecified.
pub const query_transport_error: c_int = 2;
/// Status returned when the query succeeded but a text value did not fit its
/// fixed-size output buffer. The stored length still reports the full value
/// length, so the plugin can detect truncation and retry with its own buffer.
pub const query_truncated: c_int = 3;

/// Capacity of every text field in the game-query output structs. It matches
/// the Source engine's `MAX_PATH`, which bounds engine-returned directory,
/// map, name, and cvar strings used by these queries.
pub const query_text_capacity: usize = 260;

/// Result of `GameApi.server_info`: a read-only snapshot of server state.
///
/// The caller must set `struct_size` to `@sizeOf(ServerInfo)` before the call.
/// Text fields are not zero-terminated; their `*_len` field reports the full
/// value length, which may exceed the array capacity when the query returned
/// `query_truncated`.
pub const ServerInfo = extern struct {
    /// Size of this struct in bytes as provided by the plugin.
    struct_size: usize,
    /// Nonzero when the engine is a dedicated server.
    dedicated: u8,
    /// Nonzero when the server is paused.
    paused: u8,
    /// Reserved padding; must be zero.
    reserved: [2]u8,
    /// Number of entity slots the engine reports in use.
    entity_count: c_int,
    /// Engine build number (`IVEngineServer::GetServerVersion`).
    server_version: c_int,
    /// Seconds since server start (`IVEngineServer::GetServerTime`).
    server_time: f32,
    /// Full length of `game_dir`, including bytes not stored.
    game_dir_len: usize,
    /// The game/mod directory, for example `tf`.
    game_dir: [query_text_capacity]u8,
    /// Full length of `map_name`, including bytes not stored. Zero outside an
    /// active level.
    map_name_len: usize,
    /// Current map name, cached from `levelInit`.
    map_name: [query_text_capacity]u8,
};

/// Result of `GameApi.player_info`: engine-side identity of one client.
///
/// The caller must set `struct_size` before the call. When `present` is zero
/// the player slot is empty and the remaining fields are zeroed.
pub const PlayerInfo = extern struct {
    /// Size of this struct in bytes as provided by the plugin.
    struct_size: usize,
    /// Nonzero when the engine returned info for the requested slot.
    present: u8,
    /// Nonzero when the client is a bot.
    fake_player: u8,
    /// Nonzero when the client is an HLTV proxy.
    is_hltv: u8,
    /// Reserved padding; must be zero.
    reserved: u8,
    /// Entity index the caller requested.
    index: c_int,
    /// Server-assigned user id.
    user_id: c_int,
    /// Steam friends id.
    friends_id: u32,
    /// Full length of `name`, including bytes not stored.
    name_len: usize,
    /// Player display name.
    name: [query_text_capacity]u8,
    /// Full length of `guid`, including bytes not stored.
    guid_len: usize,
    /// Steam id string.
    guid: [query_text_capacity]u8,
    /// Full length of `friends_name`, including bytes not stored.
    friends_name_len: usize,
    /// Steam friends name.
    friends_name: [query_text_capacity]u8,
};

/// Result of `GameApi.entity_exists`: whether an entity index is in use.
pub const EntityInfo = extern struct {
    /// Size of this struct in bytes as provided by the plugin.
    struct_size: usize,
    /// Nonzero when the engine has an entity at the requested index.
    exists: u8,
    /// Reserved padding; must be zero.
    reserved: [7]u8,
};

/// Result of `GameApi.server_cvar` and `GameApi.client_cvar`.
///
/// The caller must set `struct_size` before the call. `found == 0` means no
/// such cvar exists (server query) or the client is not connected (client
/// query); the remaining fields are zeroed.
pub const CvarValue = extern struct {
    /// Size of this struct in bytes as provided by the plugin.
    struct_size: usize,
    /// Nonzero when the cvar was found.
    found: u8,
    /// Reserved padding; must be zero.
    reserved: [3]u8,
    /// Integer representation of the cvar value.
    int_value: c_int,
    /// Floating-point representation of the cvar value.
    float_value: f32,
    /// Full length of `text`, including bytes not stored.
    text_len: usize,
    /// String representation of the cvar value.
    text: [query_text_capacity]u8,
};

/// Read-only, synchronous access to game state, called from plugin code.
///
/// Every function returns one of the `query_*` status values. They are
/// synchronous: the manager forwards the query to the engine process over the
/// IPC channel and blocks until the answer arrives. The engine-forked child
/// never dereferences an engine pointer itself.
///
/// Lifetime: `context` is owned by the host; `struct_size` follows the same
/// append-only rule as `PluginContext`.
pub const GameApi = extern struct {
    /// Size of this struct in bytes as provided by the host.
    struct_size: usize,
    /// Opaque host context; pass back unchanged.
    context: ?*anyopaque,
    /// Fills `out` with a server-state snapshot.
    server_info: *const fn (context: ?*anyopaque, out: *ServerInfo) callconv(.c) c_int,
    /// Fills `out` with the identity of the player at entity index `index`.
    player_info: *const fn (context: ?*anyopaque, index: c_int, out: *PlayerInfo) callconv(.c) c_int,
    /// Fills `out` with whether entity index `index` is in use.
    entity_info: *const fn (context: ?*anyopaque, index: c_int, out: *EntityInfo) callconv(.c) c_int,
    /// Fills `out` with the server cvar named `name`.
    server_cvar: *const fn (context: ?*anyopaque, name: Text, out: *CvarValue) callconv(.c) c_int,
    /// Fills `out` with client `index`'s cvar named `name`.
    client_cvar: *const fn (context: ?*anyopaque, index: c_int, name: Text, out: *CvarValue) callconv(.c) c_int,
};

// --- Filesystem -------------------------------------------------------------

/// Status returned by a `FileApi` operation: the operation succeeded.
pub const file_ok: c_int = 0;
/// Status returned when the host has no filesystem service, no IPC channel to
/// the engine process, or no engine filesystem binding for a `game://` path.
pub const file_unavailable: c_int = 1;
/// Status returned when the host could not complete a `game://` operation
/// because the transport to the engine process failed.
pub const file_transport_error: c_int = 2;
/// Status returned when the requested access is not permitted, for example a
/// write to `game://`, a `..` component, or an unsupported URI scheme.
pub const file_permission_denied: c_int = 3;
/// Status returned when the backend reports that the file or directory does
/// not exist.
pub const file_not_found: c_int = 4;
/// Status returned when the backend refused to open the file or directory.
pub const file_open_failed: c_int = 5;
/// Status returned for an I/O failure after a handle was opened.
pub const file_io_error: c_int = 6;
/// Status returned when `handle` does not name an open file or directory owned
/// by the calling plugin.
pub const file_invalid_handle: c_int = 7;
/// Status returned for a malformed argument, such as an unknown open mode.
pub const file_invalid_argument: c_int = 8;
/// Status returned when an engine-side file name, directory name, or wildcard
/// exceeds the implementation limit.
pub const file_name_too_long: c_int = 9;
/// Status returned by `find_next` when the directory enumeration is exhausted.
pub const file_end: c_int = 10;

/// Open modes accepted by `FileApi.open`.
///
/// `game://` content is read-only, so only `.read` is accepted for it.
pub const FileMode = enum(c_int) {
    /// Open an existing file for reading.
    read = 0,
    /// Create or truncate a file for writing.
    write = 1,
    /// Create a file or keep its content and write at the end.
    append = 2,
};

/// Seek origins accepted by `FileApi.seek`.
pub const FileSeekFrom = enum(c_int) {
    /// Offset from the beginning of the file.
    start = 0,
    /// Offset relative to the current position.
    current = 1,
    /// Offset relative to the end of the file.
    end = 2,
};

/// Synchronous filesystem access called from plugin code.
///
/// Paths use two URI schemes:
/// - `plugin://<tail>` addresses the calling plugin's own directory and is
///   read/write. The plugin manager opens it directly through the host
///   filesystem.
/// - `game://<tail>` addresses the running game's mod directory and is
///   read-only. The plugin manager forwards it to the engine process over IPC;
///   the forked child never dereferences an engine filesystem pointer.
///
/// Handles are opaque, non-zero integers owned by the host. They are valid
/// only for the plugin context that opened them and only until `close` or
/// `find_close` is called, or until the plugin's `unload()` returns. The host
/// closes any handle a plugin leaves open when the plugin unloads.
///
/// Every function is synchronous. `read` and `write` return the byte count on
/// success and a negated `file_*` status on failure; the other functions
/// return a `file_*` status directly. `read` may return fewer bytes than
/// requested, including 0 at end of file; callers must loop for whole-file
/// I/O.
///
/// Lifetime: `context` is owned by the host and is this plugin's filesystem
/// context. `struct_size` follows the same append-only rule as
/// `PluginContext`.
pub const FileApi = extern struct {
    /// Size of this struct in bytes as provided by the host.
    struct_size: usize,
    /// Opaque host context; pass back unchanged.
    context: ?*anyopaque,
    /// Opens `path` with `mode` and stores its handle in `out_handle`.
    open: *const fn (
        context: ?*anyopaque,
        path: Text,
        mode: FileMode,
        out_handle: *u64,
    ) callconv(.c) c_int,
    /// Closes a file handle opened by `open`.
    close: *const fn (context: ?*anyopaque, handle: u64) callconv(.c) c_int,
    /// Reads at most `destination.len` bytes from `handle`.
    ///
    /// Returns the number of bytes read (0 at end of file) or a negated
    /// `file_*` status.
    read: *const fn (
        context: ?*anyopaque,
        handle: u64,
        destination: [*]u8,
        destination_len: usize,
    ) callconv(.c) isize,
    /// Writes at most `source.len` bytes to `handle`.
    ///
    /// Returns the number of bytes written or a negated `file_*` status.
    write: *const fn (
        context: ?*anyopaque,
        handle: u64,
        source: [*]const u8,
        source_len: usize,
    ) callconv(.c) isize,
    /// Moves the file pointer of `handle` by `offset` from `origin`.
    seek: *const fn (
        context: ?*anyopaque,
        handle: u64,
        offset: i64,
        origin: FileSeekFrom,
    ) callconv(.c) c_int,
    /// Stores the current file pointer of `handle` in `out_offset`.
    tell: *const fn (context: ?*anyopaque, handle: u64, out_offset: *u64) callconv(.c) c_int,
    /// Stores the size of the file behind `handle` in `out_size`.
    size: *const fn (context: ?*anyopaque, handle: u64, out_size: *u64) callconv(.c) c_int,
    /// Asks the backend to flush buffered data for `handle`.
    flush: *const fn (context: ?*anyopaque, handle: u64) callconv(.c) c_int,
    /// Deletes `path`. Only `plugin://` paths are removable.
    remove: *const fn (context: ?*anyopaque, path: Text) callconv(.c) c_int,
    /// Opens the directory `path` for enumeration and stores its handle in
    /// `out_handle`.
    find_open: *const fn (
        context: ?*anyopaque,
        path: Text,
        out_handle: *u64,
    ) callconv(.c) c_int,
    /// Copies the next entry name of `handle` into `name`.
    ///
    /// On success, `out_len` receives the name length and `out_is_directory`
    /// receives non-zero for directories. If the name does not fit
    /// `name.len`, the function returns `file_name_too_long` and `out_len`
    /// receives the required capacity. It returns `file_end` when the
    /// enumeration is exhausted, in which case `out_len` is zero.
    find_next: *const fn (
        context: ?*anyopaque,
        handle: u64,
        name: [*]u8,
        name_len: usize,
        out_len: *usize,
        out_is_directory: *u8,
    ) callconv(.c) c_int,
    /// Ends a directory enumeration started by `find_open`.
    find_close: *const fn (context: ?*anyopaque, handle: u64) callconv(.c) c_int,
};

// --- Networking -------------------------------------------------------------

/// Status returned by a `NetworkApi` operation: the operation succeeded.
pub const network_ok: c_int = 0;
/// Status returned when the host has no network service.
pub const network_unavailable: c_int = 1;
/// Status returned when the destination is not permitted by the plugin's
/// manifest policy, or resolves into private address space without
/// `allow_private`.
pub const network_permission_denied: c_int = 2;
/// Status returned for a malformed argument, such as an unsupported protocol
/// or an empty host.
pub const network_invalid_argument: c_int = 3;
/// Status returned when the host name could not be resolved.
pub const network_resolution_failed: c_int = 4;
/// Status returned when the resolved address could not be connected.
pub const network_connect_failed: c_int = 5;
/// Status returned when the resolve, connect, read, write, or poll deadline
/// elapsed.
pub const network_timeout: c_int = 6;
/// Status returned when a non-blocking operation has no progress to report.
/// The synchronous `read`/`write` helpers normally wait for the deadline
/// instead of returning this status.
pub const network_would_block: c_int = 7;
/// Status returned when the peer closed the connection.
pub const network_closed: c_int = 8;
/// Status returned when the plugin reached `max_connections`.
pub const network_resource_limit: c_int = 9;
/// Status returned for an I/O failure on an open connection.
pub const network_io_error: c_int = 10;
/// Status returned when `handle` does not name an open connection owned by
/// the calling plugin.
pub const network_invalid_handle: c_int = 11;

/// Transport protocols accepted by `NetworkApi.connect`.
pub const NetworkProtocol = enum(c_int) {
    /// Reliable, ordered byte stream (TCP).
    tcp = 0,
};

/// Event bit in `NetworkApi.poll` arguments and results: readable.
pub const network_poll_in: u8 = 1;
/// Event bit in `NetworkApi.poll` arguments and results: writable.
pub const network_poll_out: u8 = 2;
/// Event bit in `NetworkApi.poll` results: error condition.
pub const network_poll_error: u8 = 4;
/// Event bit in `NetworkApi.poll` results: peer closed or hung up.
pub const network_poll_hup: u8 = 8;

/// Outbound-only network access called from plugin code.
///
/// The plugin manager performs every operation in the forked child; no engine
/// pointer or engine-side socket is involved. Only outbound TCP connections
/// are supported. TLS, HTTP, WebSocket, and inbound listeners are not part of
/// this contract.
///
/// A plugin's manifest `[network]` table is deny-by-default: `connect` fails
/// with `network_permission_denied` unless one `allow` rule matches the
/// requested host and port. Host-name resolution runs on a dedicated resolver
/// thread; the calling thread waits for its answer but never performs DNS
/// itself. Connections use non-blocking sockets and bounded `poll`, so a call
/// blocks for at most the policy's connect or I/O timeout.
///
/// Handles are opaque, non-zero integers valid only in the plugin context that
/// opened them and only until `close` is called or the plugin's `unload()`
/// returns. The host closes every remaining handle when the plugin unloads.
///
/// Lifetime: `context` is owned by the host and is this plugin's network
/// context. `struct_size` follows the same append-only rule as
/// `PluginContext`.
pub const NetworkApi = extern struct {
    /// Size of this struct in bytes as provided by the host.
    struct_size: usize,
    /// Opaque host context; pass back unchanged.
    context: ?*anyopaque,
    /// Opens a connection to `host`:`port` and stores its handle in
    /// `out_handle`.
    connect: *const fn (
        context: ?*anyopaque,
        host: Text,
        port: u16,
        protocol: NetworkProtocol,
        out_handle: *u64,
    ) callconv(.c) c_int,
    /// Closes a connection opened by `connect`.
    close: *const fn (context: ?*anyopaque, handle: u64) callconv(.c) c_int,
    /// Reads at most `destination_len` bytes from `handle`.
    ///
    /// Returns the number of bytes read, 0 at end of stream, or a negated
    /// `network_*` status. It waits until data arrives or the policy's I/O
    /// timeout elapses.
    read: *const fn (
        context: ?*anyopaque,
        handle: u64,
        destination: [*]u8,
        destination_len: usize,
    ) callconv(.c) isize,
    /// Writes at most `source_len` bytes to `handle`.
    ///
    /// Returns the number of bytes written or a negated `network_*` status.
    /// It waits until at least some progress is possible or the policy's I/O
    /// timeout elapses.
    write: *const fn (
        context: ?*anyopaque,
        handle: u64,
        source: [*]const u8,
        source_len: usize,
    ) callconv(.c) isize,
    /// Waits until `handle` reports at least one of the `events` bits, or
    /// `timeout_ms` elapses.
    ///
    /// `events` is a combination of `network_poll_in` and `network_poll_out`.
    /// The result is stored in `out_events` as a combination of the poll bits,
    /// including `network_poll_error` and `network_poll_hup`. A zero result
    /// means the timeout elapsed. The host caps `timeout_ms` by the policy's
    /// `poll_timeout_ms`.
    poll: *const fn (
        context: ?*anyopaque,
        handle: u64,
        events: u8,
        timeout_ms: u32,
        out_events: *u8,
    ) callconv(.c) c_int,
};
