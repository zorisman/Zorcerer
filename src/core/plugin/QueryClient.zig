//! Client side of the read-only game-query IPC service.
//!
//! A plugin running in the forked manager process asks for game state through
//! this client. Requests travel over the manager's socket to the engine
//! process, which is the only side allowed to touch engine interfaces. This
//! module owns the transport, result parsing, and conversion into the stable
//! `plugin-context` ABI values handed to plugins; it owns no sockets itself.

const std = @import("std");
const root = @import("zroot");
const abi = root.abi;
const Query = root.ipc.Query.Query;
const QueryResult = root.ipc.QueryResult;

/// Issues game queries over one manager IPC channel.
///
/// `allocator` owns the JSON result buffers returned by `fetch` and freed by
/// the query methods. `fd` is the child's end of the socket pair and may be
/// null while the channel is not configured; queries then fail with
/// `error.QueryUnavailable`. The caller must keep the socket open for the
/// duration of every call.
pub const Client = struct {
    /// Allocator used to receive and parse JSON result documents.
    allocator: std.mem.Allocator,
    /// Child end of the IPC socket pair, or null when unavailable.
    fd: ?std.os.linux.fd_t = null,

    /// Sends one query and waits for the engine's result document.
    ///
    /// The returned text is allocated with `allocator` and owned by the
    /// caller.
    ///
    /// Errors: `error.QueryUnavailable` when no socket is configured, plus the
    /// framing, JSON, and response errors of `Query.sendQuery` and
    /// `Query.receiveQueryResult`.
    pub fn fetch(self: *const Client, request: Query.QueryRequest) ![]u8 {
        const fd = self.fd orelse return error.QueryUnavailable;
        try Query.sendQuery(fd, request);
        return Query.receiveQueryResult(fd, self.allocator);
    }

    /// Executes the `server_info` query into `out`.
    pub fn queryServerInfo(self: *const Client, out: *abi.ServerInfo) c_int {
        const text = self.fetch(.{ .query = .server_info }) catch |err|
            return queryStatus(err);
        defer self.allocator.free(text);

        var parsed = std.json.parseFromSlice(
            QueryResult.ServerInfo,
            self.allocator,
            text,
            .{},
        ) catch return abi.query_transport_error;
        defer parsed.deinit();

        out.* = std.mem.zeroes(abi.ServerInfo);
        out.struct_size = @sizeOf(abi.ServerInfo);
        out.dedicated = @intFromBool(parsed.value.dedicated);
        out.paused = @intFromBool(parsed.value.paused);
        out.entity_count = parsed.value.entity_count;
        out.server_version = parsed.value.server_version;
        out.server_time = parsed.value.server_time;

        var truncated = false;
        const game_dir = storeText(&out.game_dir, parsed.value.game_dir);
        out.game_dir_len = game_dir.len;
        truncated = truncated or game_dir.truncated;

        const map_name = storeText(&out.map_name, parsed.value.map_name);
        out.map_name_len = map_name.len;
        truncated = truncated or map_name.truncated;

        return if (truncated) abi.query_truncated else abi.query_ok;
    }

    /// Executes the `player_info` query for `index` into `out`.
    pub fn queryPlayerInfo(self: *const Client, index: c_int, out: *abi.PlayerInfo) c_int {
        const text = self.fetch(.{ .query = .player_info, .index = index }) catch |err|
            return queryStatus(err);
        defer self.allocator.free(text);

        var parsed = std.json.parseFromSlice(
            QueryResult.PlayerInfo,
            self.allocator,
            text,
            .{},
        ) catch return abi.query_transport_error;
        defer parsed.deinit();

        out.* = std.mem.zeroes(abi.PlayerInfo);
        out.struct_size = @sizeOf(abi.PlayerInfo);
        out.index = parsed.value.index;
        out.present = @intFromBool(parsed.value.present);
        if (!parsed.value.present) return abi.query_ok;

        out.user_id = parsed.value.user_id;
        out.friends_id = parsed.value.friends_id;
        out.fake_player = @intFromBool(parsed.value.fake_player);
        out.is_hltv = @intFromBool(parsed.value.is_hltv);

        var truncated = false;
        const name = storeText(&out.name, parsed.value.name);
        out.name_len = name.len;
        truncated = truncated or name.truncated;

        const guid = storeText(&out.guid, parsed.value.guid);
        out.guid_len = guid.len;
        truncated = truncated or guid.truncated;

        const friends_name = storeText(&out.friends_name, parsed.value.friends_name);
        out.friends_name_len = friends_name.len;
        truncated = truncated or friends_name.truncated;

        return if (truncated) abi.query_truncated else abi.query_ok;
    }

    /// Executes the `entity_exists` query for `index` into `out`.
    pub fn queryEntityInfo(self: *const Client, index: c_int, out: *abi.EntityInfo) c_int {
        const text = self.fetch(.{ .query = .entity_exists, .index = index }) catch |err|
            return queryStatus(err);
        defer self.allocator.free(text);

        var parsed = std.json.parseFromSlice(
            QueryResult.EntityInfo,
            self.allocator,
            text,
            .{},
        ) catch return abi.query_transport_error;
        defer parsed.deinit();

        out.* = std.mem.zeroes(abi.EntityInfo);
        out.struct_size = @sizeOf(abi.EntityInfo);
        out.exists = @intFromBool(parsed.value.exists);
        return abi.query_ok;
    }

    /// Executes the `server_cvar` query for `name` into `out`.
    pub fn queryServerCvar(self: *const Client, name: []const u8, out: *abi.CvarValue) c_int {
        const text = self.fetch(.{ .query = .server_cvar, .name = name }) catch |err|
            return queryStatus(err);
        defer self.allocator.free(text);

        var parsed = std.json.parseFromSlice(
            QueryResult.CvarValue,
            self.allocator,
            text,
            .{},
        ) catch return abi.query_transport_error;
        defer parsed.deinit();

        return fillCvarValue(parsed.value, out);
    }

    /// Executes the `client_cvar` query for client `index` into `out`.
    pub fn queryClientCvar(
        self: *const Client,
        index: c_int,
        name: []const u8,
        out: *abi.CvarValue,
    ) c_int {
        const text = self.fetch(.{
            .query = .client_cvar,
            .index = index,
            .name = name,
        }) catch |err| return queryStatus(err);
        defer self.allocator.free(text);

        var parsed = std.json.parseFromSlice(
            QueryResult.CvarValue,
            self.allocator,
            text,
            .{},
        ) catch return abi.query_transport_error;
        defer parsed.deinit();

        return fillCvarValue(parsed.value, out);
    }
};

/// Translates a query failure into an ABI status.
fn queryStatus(err: anyerror) c_int {
    return switch (err) {
        error.QueryUnavailable => abi.query_unavailable,
        else => abi.query_transport_error,
    };
}

/// Copies `source` into `destination`.
///
/// Returns the full source length, which callers store so a plugin can detect
/// truncation, and whether any bytes were dropped.
fn storeText(destination: []u8, source: []const u8) struct { len: usize, truncated: bool } {
    const stored = @min(destination.len, source.len);
    @memcpy(destination[0..stored], source[0..stored]);
    return .{ .len = source.len, .truncated = source.len > destination.len };
}

/// Fills an ABI cvar result from its JSON form.
fn fillCvarValue(value: QueryResult.CvarValue, out: *abi.CvarValue) c_int {
    out.* = std.mem.zeroes(abi.CvarValue);
    out.struct_size = @sizeOf(abi.CvarValue);
    out.found = @intFromBool(value.found);
    out.int_value = value.int_value;
    out.float_value = value.float_value;

    const text = storeText(&out.text, value.text);
    out.text_len = text.len;
    return if (text.truncated) abi.query_truncated else abi.query_ok;
}
