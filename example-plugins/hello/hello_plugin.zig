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
//! name per line. On unload(), it deletes that same file. Both operations
//! go through the host filesystem API in src/io/file_system.zig, which
//! routes `plugin://` URIs to std.Io and `game://` URIs to the Source
//! Engine filesystem.
//!
//! The plugin still derives its own roots because PluginContext carries no
//! root directories yet: the manager treats its working directory as the
//! game directory and loads plugins from
//! `tf/addons/zorcerer/plugins/<id>/`, so the Zorcerer root is
//! `<cwd>/tf/addons/zorcerer` and the game root is `<cwd>/tf`. The context
//! supplies the plugin id and manifest identity used for filesystem
//! resolution and log messages.
//!
//! Enumerating `game://` needs an engine filesystem binding, which the
//! context does not carry yet. Until the host supplies one, load() still
//! creates the report but records that the material listing is
//! unavailable instead of pretending it succeeded.

const std = @import("std");
const abi = @import("plugin-context");
const filesystem = @import("zorcerer-filesystem");

/// `std.Io` adapter used for `plugin://` I/O. The manager owns no instance
/// the plugin could borrow, so the plugin keeps a single-threaded adapter
/// of its own; filesystem operations on `plugin://` do not allocate.
var threaded_io: std.Io.Threaded = .init_single_threaded;

/// Absolute Zorcerer root backing `plugin://` URIs, derived by
/// `resolveRoots()`. Stored statically because `setZorcererRoot()` keeps
/// the pointer and the plugin may use it until unload().
var zorcerer_root: [std.Io.Dir.max_path_bytes]u8 = undefined;

/// Absolute game root (the `tf` directory) backing `game://` URIs, derived
/// by `resolveRoots()`; same lifetime rule as `zorcerer_root`.
var game_root: [std.Io.Dir.max_path_bytes]u8 = undefined;

/// Report location relative to this plugin's own directory, as interpreted
/// by `filesystem.parsePath()`.
const report_uri = "plugin://hello.txt";

/// Directory whose non-directory entries the report lists.
const materials_uri = "game://materials";

/// Derives this process' game and Zorcerer roots from the working
/// directory and registers them with the filesystem module.
///
/// The manager resolves plugins relative to the process' working directory
/// (`tf/addons/zorcerer/plugins`), so the same convention is mirrored here:
/// `<cwd>/tf/addons/zorcerer` for `plugin://` and `<cwd>/tf` for `game://`.
///
/// Errors: any failure of `std.Io.Dir.realPath` (for example the current
/// directory no longer exists) and `error.RootPathTooLong` when a derived
/// root does not fit the static buffers.
///
/// Side effects: overwrites both static root buffers and hands their
/// pointers to `filesystem.setZorcererRoot()` / `filesystem.setGameRoot()`.
fn resolveRoots(io: std.Io) !void {
    // `std.Io.Dir.cwd().realPath()` asks procfs for fd -100 (AT_FDCWD),
    // which Linux does not expose; opening "." yields a real handle whose
    // canonical path can be read.
    const cwd_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer cwd_dir.close(io);

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try cwd_dir.realPath(io, &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];

    const zorcerer = std.fmt.bufPrint(
        &zorcerer_root,
        "{s}/tf/addons/zorcerer",
        .{cwd},
    ) catch return error.RootPathTooLong;
    const game = std.fmt.bufPrint(&game_root, "{s}/tf", .{cwd}) catch
        return error.RootPathTooLong;

    filesystem.setZorcererRoot(zorcerer);
    filesystem.setGameRoot(game);
}

/// Creates/overwrites `plugin://hello.txt` and writes the non-directory
/// entry names of `game://materials` into it, one per line.
///
/// `ctx` is the manager-provided context for this plugin; `plugin.id`
/// names the directory `plugin://` resolves under.
///
/// Errors: URI resolution failures (`filesystem.parsePath`), file opening
/// and writing failures, and directory enumeration failures. When the
/// engine filesystem is not bound, the function does not fail: it writes an
/// explanatory line into the report.
///
/// Side effects: creates or truncates `hello.txt` in the plugin directory.
/// If anything fails after the file was created, the file is removed again
/// so a failed load() leaves no stray report (the manager never calls
/// unload() for a plugin whose load() failed).
fn writeReport(io: std.Io, ctx: *abi.PluginContext) !void {
    const report = try filesystem.parsePath(ctx, report_uri);

    var output = try filesystem.File.open(io, null, report, .write);
    errdefer filesystem.File.remove(io, report) catch {};
    defer output.close();

    const materials = try filesystem.parsePath(ctx, materials_uri);
    var directory = filesystem.Directory.open(io, null, materials) catch |err| switch (err) {
        // There is no engine filesystem binding in the context yet. Record
        // the limitation instead of failing a load() over host plumbing.
        error.EngineNotBound => {
            try output.writeAll("game://materials: engine filesystem binding not available\n");
            return;
        },
        else => return err,
    };
    defer directory.close();

    // `entry.name` is only valid until the next `next()` call, so each
    // name is written immediately; directories are skipped to keep the
    // listing non-recursive.
    var name_buffer: [filesystem.max_engine_name_len]u8 = undefined;
    while (try directory.next(&name_buffer)) |entry| {
        if (entry.is_directory) continue;
        try output.writeAll(entry.name);
        try output.writeAll("\n");
    }
}

/// Sends one message through the logger the plugin manager configured.
/// Does nothing when the host could not provide one.
fn consolePrint(ctx: *abi.PluginContext, message: [:0]const u8) void {
    if (ctx.logger) |logger| {
        logger.print(logger.context, message.ptr);
    }
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

    const io = threaded_io.io();
    resolveRoots(io) catch |err| {
        std.debug.print("hello_plugin: could not resolve filesystem roots ({s})\n", .{@errorName(err)});
        return 1;
    };
    writeReport(io, ctx) catch |err| {
        std.debug.print("hello_plugin: could not write {s} ({s})\n", .{ report_uri, @errorName(err) });
        return 1;
    };

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

    const io = threaded_io.io();
    // load() already registered the roots; resolving again keeps unload()
    // self-contained (both calls are allocation-free).
    resolveRoots(io) catch |err| {
        std.debug.print("hello_plugin: could not resolve filesystem roots ({s})\n", .{@errorName(err)});
        return 1;
    };

    const report = filesystem.parsePath(ctx, report_uri) catch |err| {
        std.debug.print("hello_plugin: could not resolve {s} ({s})\n", .{ report_uri, @errorName(err) });
        return 1;
    };
    filesystem.File.remove(io, report) catch |err| {
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
