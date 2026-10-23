//! Example plugin for the manager in src/PluginManager.zig.
//!
//! This file is built into zig-out/lib/hello_plugin.so (see build.zig) and
//! is placed into a plugin directory under tf/addons/zorcerer/plugins/,
//! e.g.:
//!
//!     tf/addons/zorcerer/plugins/hello/hello_plugin.so
//!
//! The plugin manager dlopen()s the .so, looks up the exported `load` and
//! `unload` symbols (ABI contract in src/PluginContext.zig) and calls them
//! with a *const HostApi.
//!
//! On load(), the plugin creates/overwrites `plugin://hello.txt` with a
//! report that lists the non-directory entries of `game://materials`, one
//! name per line. On unload(), it deletes that same file. Both operations
//! go through the host filesystem API in src/io/FileSystem.zig, which
//! routes `plugin://` URIs to std.Io and `game://` URIs to the Source
//! Engine filesystem.
//!
//! The plugin has to derive its own roots because the v1 HostApi carries
//! no path information: the manager treats its working directory as the
//! game directory and loads plugins from
//! `tf/addons/zorcerer/plugins/<id>/`, so the Zorcerer root is
//! `<cwd>/tf/addons/zorcerer` and the game root is `<cwd>/tf`.
//!
//! Enumerating `game://` needs an engine filesystem binding, which the v1
//! HostApi does not carry yet. Until the host supplies one, load() still
//! creates the report but records that the material listing is
//! unavailable instead of pretending it succeeded.
//!
//! Both entry points print progress via std.debug.print (stderr) - not the
//! host logger; the `consolePrint` helper below is the logger-based path
//! and is not called yet.

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

/// Builds the context `filesystem.parsePath()` needs. Only `lib_path`
/// affects URI resolution: it is relative to the Zorcerer root, so
/// `plugin://` resolves to this plugin's directory (`plugins/hello`).
fn pluginContext() filesystem.PluginContext {
    return .{
        .config = .{
            .plugin_id = "hello",
            .name = "Hello Example",
            .version = "0.1.0",
            .author = "Zorcerer",
            .lib_path = "plugins/hello/hello_plugin.so",
        },
    };
}

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
/// Errors: URI resolution failures (`filesystem.parsePath`), file opening
/// and writing failures, and directory enumeration failures. When the
/// engine filesystem is not bound (its v1 HostApi has no binding yet), the
/// function does not fail: it writes an explanatory line into the report.
///
/// Side effects: creates or truncates `hello.txt` in the plugin directory.
/// If anything fails after the file was created, the file is removed again
/// so a failed load() leaves no stray report (the manager never calls
/// unload() for a plugin whose load() failed).
fn writeReport(io: std.Io) !void {
    var ctx = pluginContext();
    const report = try filesystem.parsePath(&ctx, report_uri);

    var output = try filesystem.File.open(io, null, report, .write);
    errdefer filesystem.File.remove(io, report) catch {};
    defer output.close();

    const materials = try filesystem.parsePath(&ctx, materials_uri);
    var directory = filesystem.Directory.open(io, null, materials) catch |err| switch (err) {
        // There is no engine filesystem binding in the v1 HostApi. Record
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
fn consolePrint(host: *const abi.HostApi, message: [:0]const u8) void {
    if (host.logger) |logger| {
        logger.print(logger.context, message.ptr);
    }
}

export fn load(host: *const abi.HostApi) callconv(.c) c_int {
    if (host.abi_version != abi.abi_version) {
        std.debug.print(
            "hello_plugin: HostApi ABI mismatch, host {d} != plugin {d}\n",
            .{ host.abi_version, abi.abi_version },
        );
        return 1;
    }

    const io = threaded_io.io();
    resolveRoots(io) catch |err| {
        std.debug.print("hello_plugin: could not resolve filesystem roots ({s})\n", .{@errorName(err)});
        return 1;
    };
    writeReport(io) catch |err| {
        std.debug.print("hello_plugin: could not write {s} ({s})\n", .{ report_uri, @errorName(err) });
        return 1;
    };

    std.debug.print("Hello, Plugin Manager!\n", .{});
    return 0;
}

export fn unload(host: *const abi.HostApi) callconv(.c) c_int {
    _ = host;

    const io = threaded_io.io();
    // load() already registered the roots; resolving again keeps unload()
    // self-contained (both calls are allocation-free).
    resolveRoots(io) catch |err| {
        std.debug.print("hello_plugin: could not resolve filesystem roots ({s})\n", .{@errorName(err)});
        return 1;
    };

    var ctx = pluginContext();
    const report = filesystem.parsePath(&ctx, report_uri) catch |err| {
        std.debug.print("hello_plugin: could not resolve {s} ({s})\n", .{ report_uri, @errorName(err) });
        return 1;
    };
    filesystem.File.remove(io, report) catch |err| {
        std.debug.print("hello_plugin: could not remove {s} ({s})\n", .{ report_uri, @errorName(err) });
        return 1;
    };

    std.debug.print("Bye, Plugin Manager!\n", .{});
    return 0;
}
