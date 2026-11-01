//! Example plugin for the manager in src/PluginManager.zig.
//!
//! This file is built into zig-out/lib/hello_plugin.so (see build.zig) and
//! is placed into a plugin directory under tf/addons/zorcerer/plugins/,
//! e.g.:
//!
//!     tf/addons/zorcerer/plugins/hello/hello_plugin.so
//!
//! The plugin manager dlopen()s the .so, looks up the exported `load` and
//! `unload` symbols (ABI contract in src/core/PluginContext.zig) and calls
//! them with a *PluginContext. It also resolves the optional `onEvent`
//! export, which this plugin implements to log runtime events.
//!
//! On load(), the plugin creates/overwrites `plugin://hello.txt` with a
//! report that lists the non-directory entries of `game://materials`, one
//! name per line. It then logs a one-line server snapshot through the
//! read-only game-query capability when the host provides one. On unload(), it
//! deletes that same file. Both file operations go through `ctx.files`
//! (`abi.FileApi`): the host opens `plugin://` paths on its own filesystem and
//! forwards `game://` paths to the engine process over IPC, so the plugin
//! never dereferences an engine filesystem pointer.
//!
//! `unload()` keeps using the same `ctx.files` capability; the host closes
//! any handles the plugin leaves open after `unload()` returns.

const std = @import("std");
const abi = @import("plugin-context");

/// Report location inside this plugin's own directory.
const report_uri = "plugin://hello.txt";

/// Directory whose non-directory entries the report lists.
const materials_uri = "game://materials";

/// Buffer size for one directory entry name. The host reports names that do
/// not fit as `file_name_too_long` instead of truncating them.
const max_entry_name_len: usize = 1024;

/// Sends one message through the logger the plugin manager configured.
/// Does nothing when the host could not provide one.
fn consolePrint(ctx: *abi.PluginContext, message: [:0]const u8) void {
    if (ctx.logger) |logger| {
        logger.print(logger.context, message.ptr);
    }
}

/// Writes all of `bytes` to an open `FileApi` handle.
///
/// The host may accept fewer bytes than requested, so this loops until every
/// byte is written.
///
/// Errors: `error.WriteFailed` when the host reports a negative status or
/// stops making progress.
fn writeAll(files: *const abi.FileApi, handle: u64, bytes: []const u8) !void {
    var written: usize = 0;
    while (written != bytes.len) {
        const count = files.write(
            files.context,
            handle,
            bytes.ptr + written,
            bytes.len - written,
        );
        if (count <= 0) return error.WriteFailed;
        written += @intCast(count);
    }
}

/// Deletes the report file through the host filesystem API.
///
/// Errors: `error.RemoveFailed` when the host does not report `file_ok`.
fn removeReport(files: *const abi.FileApi) !void {
    const status = files.remove(files.context, abi.Text.fromSlice(report_uri));
    if (status != abi.file_ok) return error.RemoveFailed;
}

/// Creates/overwrites `plugin://hello.txt` and writes the non-directory
/// entry names of `game://materials` into it, one per line.
///
/// Errors: `error.ReportOpenFailed` when the report cannot be opened,
/// `error.DirectoryReadFailed` when enumeration fails after opening, and
/// `error.WriteFailed` from `writeAll`. A missing `game://` service is not an
/// error: the function records that limitation in the report instead.
///
/// Side effects: creates or truncates `hello.txt` in the plugin directory.
/// If anything fails after the file was created, the file is removed again so
/// a failed load() leaves no stray report (the manager never calls unload()
/// for a plugin whose load() failed).
fn writeReport(files: *const abi.FileApi) !void {
    var output: u64 = 0;
    const open_status = files.open(
        files.context,
        abi.Text.fromSlice(report_uri),
        .write,
        &output,
    );
    if (open_status != abi.file_ok) return error.ReportOpenFailed;

    errdefer removeReport(files) catch {};
    defer _ = files.close(files.context, output);

    var directory: u64 = 0;
    const find_status = files.find_open(
        files.context,
        abi.Text.fromSlice(materials_uri),
        &directory,
    );
    if (find_status != abi.file_ok) {
        // The host may have no engine filesystem binding; record the
        // limitation instead of failing a load() over host plumbing.
        try writeAll(
            files,
            output,
            "game://materials: engine filesystem binding not available\n",
        );
        return;
    }
    defer _ = files.find_close(files.context, directory);

    // Entry names are only valid for one `find_next` call, so each name is
    // written immediately; directories are skipped to keep the listing
    // non-recursive.
    var name_buffer: [max_entry_name_len]u8 = undefined;
    while (true) {
        var name_len: usize = 0;
        var is_directory: u8 = 0;
        const status = files.find_next(
            files.context,
            directory,
            &name_buffer,
            name_buffer.len,
            &name_len,
            &is_directory,
        );
        if (status == abi.file_end) break;
        if (status != abi.file_ok) return error.DirectoryReadFailed;
        if (is_directory != 0) continue;

        try writeAll(files, output, name_buffer[0..name_len]);
        try writeAll(files, output, "\n");
    }
}

/// Logs a one-line server snapshot through the read-only game-query
/// capability.
///
/// Does nothing when the host does not provide `ctx.game`. Query failures are
/// logged rather than propagated: the example must keep loading on a host
/// without an engine channel.
fn logServerInfo(ctx: *abi.PluginContext) void {
    const game = ctx.game orelse return;
    if (game.struct_size < @sizeOf(abi.GameApi)) return;

    var info: abi.ServerInfo = std.mem.zeroes(abi.ServerInfo);
    info.struct_size = @sizeOf(abi.ServerInfo);
    const status = game.server_info(game.context, &info);
    if (status != abi.query_ok and status != abi.query_truncated) {
        var error_buffer: [128]u8 = undefined;
        const error_message = std.fmt.bufPrintZ(
            &error_buffer,
            "hello_plugin: server info unavailable (query status {d})\n",
            .{status},
        ) catch return;
        consolePrint(ctx, error_message);
        return;
    }

    const map_length = @min(info.map_name_len, info.map_name.len);
    const dir_length = @min(info.game_dir_len, info.game_dir.len);
    var message_buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrintZ(
        &message_buffer,
        "hello_plugin: map {s}, {d} entities, {s} mode, {d}s uptime, game dir {s}\n",
        .{
            info.map_name[0..map_length],
            info.entity_count,
            if (info.dedicated != 0) "dedicated" else "listen",
            info.server_time,
            info.game_dir[0..dir_length],
        },
    ) catch return;
    consolePrint(ctx, message);
}

export fn load(ctx: *abi.PluginContext) callconv(.c) c_int {
    if (ctx.abi_version != abi.abi_version or
        ctx.struct_size < @sizeOf(abi.PluginContext))
    {
        std.debug.print(
            "hello_plugin: PluginContext ABI mismatch, host {d}/{d} != plugin {d}/{d}\n",
            .{
                ctx.abi_version,
                ctx.struct_size,
                abi.abi_version,
                @sizeOf(abi.PluginContext),
            },
        );
        return 1;
    }

    const files = ctx.files orelse {
        consolePrint(ctx, "hello_plugin: host provides no filesystem API\n");
        logServerInfo(ctx);
        return 0;
    };
    if (files.struct_size < @sizeOf(abi.FileApi)) {
        consolePrint(ctx, "hello_plugin: host filesystem API is too old\n");
        logServerInfo(ctx);
        return 0;
    }

    writeReport(files) catch |err| {
        std.debug.print("hello_plugin: could not write {s} ({s})\n", .{ report_uri, @errorName(err) });
        return 1;
    };
    logServerInfo(ctx);

    var message_buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrintZ(
        &message_buffer,
        "hello_plugin: {s} v{s} loaded\n",
        .{ ctx.plugin.id.slice(), ctx.plugin.version.slice() },
    ) catch "hello_plugin: loaded\n";
    consolePrint(ctx, message);
    return 0;
}

export fn unload(ctx: *abi.PluginContext) callconv(.c) c_int {
    if (ctx.abi_version != abi.abi_version or
        ctx.struct_size < @sizeOf(abi.PluginContext))
    {
        return 1;
    }

    const files = ctx.files orelse {
        consolePrint(ctx, "hello_plugin: host provides no filesystem API\n");
        return 0;
    };
    if (files.struct_size < @sizeOf(abi.FileApi)) {
        consolePrint(ctx, "hello_plugin: host filesystem API is too old\n");
        return 0;
    }

    removeReport(files) catch |err| {
        std.debug.print("hello_plugin: could not remove {s} ({s})\n", .{ report_uri, @errorName(err) });
        return 1;
    };

    consolePrint(ctx, "hello_plugin: unloaded\n");
    return 0;
}

/// Optional runtime-event hook: logs the event name and keeps delivery going.
///
/// `event` and its texts are only valid during this call, so nothing is
/// retained. A context or event struct from an incompatible ABI is ignored
/// rather than dereferenced.
export fn onEvent(ctx: *abi.PluginContext, event: *const abi.Event) callconv(.c) c_int {
    if (ctx.abi_version != abi.abi_version or event.struct_size < @sizeOf(abi.Event)) {
        return abi.plugin_continue;
    }

    var message_buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrintZ(
        &message_buffer,
        "hello_plugin: event {s}\n",
        .{event.name.slice()},
    ) catch return abi.plugin_continue;
    consolePrint(ctx, message);
    return abi.plugin_continue;
}
