//! Core implementation of zlua's external `zostd.Host` interface.
//!
//! This is the only core file that knows how a Lua script's capabilities map
//! onto Zorcerer services. `zlua` owns the Lua state and script lifecycle;
//! `PluginManager` owns the script entry and passes this host table to
//! `zlua.Script.load()`. File paths reaching these callbacks are already
//! normalized by zlua, so they always carry a `plugin://` or `game://` scheme.
//! Engine writes and client messages are forwarded through the manager's IPC
//! channel; no engine pointer reaches a callback.
//!
//! The context is heap-allocated by the manager so it stays stable while the
//! script list grows. It borrows `manager` and `files`; both must outlive the
//! script runtime. This module owns no state.

const std = @import("std");
const root = @import("zroot");
const abi = root.abi;
const Log = root.io.Log;
const Manager = @import("PluginManager.zig").Manager;
const FileService = @import("FileService.zig");
const NetworkService = @import("NetworkService.zig");
const zlua = @import("zlua");

/// Per-script host context passed back to every `zostd` callback.
pub const Context = struct {
    /// Manager that owns the script and answers game queries and commands.
    manager: *Manager,
    /// Filesystem context of the script's plugin directory.
    files: *FileService.PluginFiles,
    /// Network context of the script's plugin directory. Borrowed; the
    /// manager destroys it after the script's runtime closes.
    network: *NetworkService.PluginNetwork,
    /// Id of the script's plugin directory. Advisory attribution for command
    /// audit logs; an empty slice means the caller did not supply one.
    plugin_id: []const u8 = "",
};

/// Returns the host table for one script.
///
/// `context` is borrowed by the returned table and must remain valid until the
/// script's runtime is closed.
pub fn host(context: *Context) zlua.zostd.Host {
    return .{
        .context = context,
        .log = logMessage,
        .plugin_id = pluginId,
        .read_file = readFile,
        .write_file = writeFile,
        .server_command = serverCommand,
        .client_print = clientPrint,
        .server_info = gameServerInfo,
        .player_info = gamePlayerInfo,
        .entity_exists = gameEntityExists,
        .server_cvar = gameServerCvar,
        .client_cvar = gameClientCvar,
        .connect = networkConnect,
        .close_connection = networkClose,
        .read_network = networkRead,
        .write_network = networkWrite,
        .poll_network = networkPoll,
    };
}

/// Returns the context behind an ABI `context` pointer, or null when absent.
fn contextOf(raw: ?*anyopaque) ?*Context {
    const context = raw orelse return null;
    return @ptrCast(@alignCast(context));
}

/// Prefixes and forwards one `zostd.log()` message to the manager log.
fn logMessage(context: ?*anyopaque, message: []const u8) void {
    _ = context;
    Log.logLine("[zlua] {s}\n", .{message});
}

/// Returns the script's plugin id, or an empty slice when no context is set.
fn pluginId(context: ?*anyopaque) []const u8 {
    return (contextOf(context) orelse return "").plugin_id;
}

/// Implements `zostd.server_command()` by forwarding the command through the
/// manager's IPC channel.
///
/// The call returns after the Entrypoint has handed the command to the engine.
/// It does not report whether the engine recognized or successfully executed
/// it. Errors: the `Manager.executeServerCommand` errors, or
/// `error.Unavailable` when the context is missing.
fn serverCommand(context: ?*anyopaque, command: []const u8) anyerror!void {
    const host_context = contextOf(context) orelse return error.Unavailable;
    return host_context.manager.executeServerCommand(host_context.plugin_id, command);
}

/// Implements `zostd.client_print()` by printing to the client whose command is
/// currently being handled.
///
/// Only valid during a `clientCommand` event; outside one the manager returns
/// `error.NoActiveClientCommand`. The call returns after the Entrypoint has
/// handed the message to `ClientPrintf`, not after the client displays it.
/// Errors: the `Manager.executeClientPrint` errors, or `error.Unavailable` when
/// the context is missing.
fn clientPrint(context: ?*anyopaque, message: []const u8) anyerror!void {
    const host_context = contextOf(context) orelse return error.Unavailable;
    return host_context.manager.executeClientPrint(host_context.plugin_id, message);
}

/// Implements `zostd.read_file()` through the script's filesystem context.
///
/// `path` is already a `plugin://` or `game://` URI. The returned bytes are
/// allocated with `allocator` and owned by the caller.
///
/// Errors: the `PluginFiles` errors for `path`, or `error.Unavailable` when the
/// context is missing.
fn readFile(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    path: []const u8,
) anyerror![]u8 {
    const host_context = contextOf(context) orelse return error.Unavailable;
    return host_context.files.readAll(allocator, path);
}

/// Implements `zostd.write_file()` through the script's filesystem context.
///
/// `path` is already a URI; `game://` writes fail with
/// `error.PermissionDenied`. Errors: the `PluginFiles` errors for `path`, or
/// `error.Unavailable` when the context is missing.
fn writeFile(
    context: ?*anyopaque,
    path: []const u8,
    data: []const u8,
) anyerror!void {
    const host_context = contextOf(context) orelse return error.Unavailable;
    return host_context.files.writeAll(path, data);
}

/// Implements `zostd.net.connect()` through the script's network context.
///
/// The context applies the manifest's deny-by-default allowlist and returns an
/// error when the destination is not permitted.
///
/// Errors: the `PluginNetwork` connect errors, or `error.Unavailable` when the
/// context is missing.
fn networkConnect(context: ?*anyopaque, host_name: []const u8, port: u16) anyerror!u64 {
    const host_context = contextOf(context) orelse return error.Unavailable;
    var handle: u64 = 0;
    try host_context.network.connect(host_name, port, .tcp, &handle);
    return handle;
}

/// Implements `zostd.net.close()` through the script's network context.
fn networkClose(context: ?*anyopaque, handle: u64) anyerror!void {
    const host_context = contextOf(context) orelse return error.Unavailable;
    return host_context.network.close(handle);
}

/// Implements `zostd.net.read()` through the script's network context.
fn networkRead(context: ?*anyopaque, handle: u64, destination: []u8) anyerror!usize {
    const host_context = contextOf(context) orelse return error.Unavailable;
    return host_context.network.read(handle, destination);
}

/// Implements `zostd.net.write()` through the script's network context.
fn networkWrite(context: ?*anyopaque, handle: u64, source: []const u8) anyerror!usize {
    const host_context = contextOf(context) orelse return error.Unavailable;
    return host_context.network.write(handle, source);
}

/// Implements `zostd.net.poll()` through the script's network context.
fn networkPoll(
    context: ?*anyopaque,
    handle: u64,
    events: u8,
    timeout_ms: u32,
    out_events: *u8,
) anyerror!void {
    const host_context = contextOf(context) orelse return error.Unavailable;
    return host_context.network.poll(handle, events, timeout_ms, out_events);
}

/// Forwards `zostd.game.server_info()` to the manager's query client.
fn gameServerInfo(context: ?*anyopaque, out: *zlua.zostd.GameServerInfo) c_int {
    const self = (contextOf(context) orelse return abi.query_unavailable).manager;
    var info = std.mem.zeroes(abi.ServerInfo);
    info.struct_size = @sizeOf(abi.ServerInfo);

    const status = self.queryServerInfo(&info);
    if (status != abi.query_ok and status != abi.query_truncated) return status;

    out.dedicated = info.dedicated != 0;
    out.paused = info.paused != 0;
    out.entity_count = info.entity_count;
    out.server_version = info.server_version;
    out.server_time = info.server_time;
    out.game_dir_len = info.game_dir_len;
    @memcpy(&out.game_dir, &info.game_dir);
    out.map_name_len = info.map_name_len;
    @memcpy(&out.map_name, &info.map_name);
    return status;
}

/// Forwards `zostd.game.player_info()` to the manager's query client.
fn gamePlayerInfo(
    context: ?*anyopaque,
    index: c_int,
    out: *zlua.zostd.GamePlayerInfo,
) c_int {
    const self = (contextOf(context) orelse return abi.query_unavailable).manager;
    var info = std.mem.zeroes(abi.PlayerInfo);
    info.struct_size = @sizeOf(abi.PlayerInfo);

    const status = self.queryPlayerInfo(index, &info);
    if (status != abi.query_ok and status != abi.query_truncated) return status;

    out.* = std.mem.zeroes(zlua.zostd.GamePlayerInfo);
    out.present = info.present != 0;
    out.index = info.index;
    out.user_id = info.user_id;
    out.friends_id = info.friends_id;
    out.fake_player = info.fake_player != 0;
    out.is_hltv = info.is_hltv != 0;
    out.name_len = info.name_len;
    @memcpy(&out.name, &info.name);
    out.guid_len = info.guid_len;
    @memcpy(&out.guid, &info.guid);
    out.friends_name_len = info.friends_name_len;
    @memcpy(&out.friends_name, &info.friends_name);
    return status;
}

/// Forwards `zostd.game.entity_exists()` to the manager's query client.
fn gameEntityExists(context: ?*anyopaque, index: c_int, out: *bool) c_int {
    const self = (contextOf(context) orelse return abi.query_unavailable).manager;
    var info = std.mem.zeroes(abi.EntityInfo);
    info.struct_size = @sizeOf(abi.EntityInfo);

    const status = self.queryEntityInfo(index, &info);
    if (status != abi.query_ok) return status;
    out.* = info.exists != 0;
    return status;
}

/// Forwards `zostd.game.server_cvar()` to the manager's query client.
fn gameServerCvar(
    context: ?*anyopaque,
    name: []const u8,
    out: *zlua.zostd.GameCvarValue,
) c_int {
    const self = (contextOf(context) orelse return abi.query_unavailable).manager;
    var value = std.mem.zeroes(abi.CvarValue);
    value.struct_size = @sizeOf(abi.CvarValue);

    const status = self.queryServerCvar(name, &value);
    if (status != abi.query_ok and status != abi.query_truncated) return status;
    return copyCvarValue(value, status, out);
}

/// Forwards `zostd.game.client_cvar()` to the manager's query client.
fn gameClientCvar(
    context: ?*anyopaque,
    index: c_int,
    name: []const u8,
    out: *zlua.zostd.GameCvarValue,
) c_int {
    const self = (contextOf(context) orelse return abi.query_unavailable).manager;
    var value = std.mem.zeroes(abi.CvarValue);
    value.struct_size = @sizeOf(abi.CvarValue);

    const status = self.queryClientCvar(index, name, &value);
    if (status != abi.query_ok and status != abi.query_truncated) return status;
    return copyCvarValue(value, status, out);
}

/// Copies an ABI cvar result into its Lua-bridge counterpart.
fn copyCvarValue(
    value: abi.CvarValue,
    status: c_int,
    out: *zlua.zostd.GameCvarValue,
) c_int {
    out.* = std.mem.zeroes(zlua.zostd.GameCvarValue);
    out.found = value.found != 0;
    out.int_value = value.int_value;
    out.float_value = value.float_value;
    out.text_len = value.text_len;
    @memcpy(&out.text, &value.text);
    return status;
}
