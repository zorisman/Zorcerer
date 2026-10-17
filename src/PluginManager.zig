//! Zorcerer's plugin manager: the layer *above* SourcePlugin.zig. Where
//! SourcePlugin.zig is Zorcerer itself, loaded by the TF2 engine as a
//! Valve Server Plugin, this is what Zorcerer uses to load *its own*
//! plugins - plain .so files, each required to export exactly two
//! `extern "C"`-ABI functions:
//!
//!     bool load(void* engine);   // called once, right after dlopen
//!     void unload(void);         // called once, right before dlclose
//!
//! `engine` is whatever Zorcerer itself received (an IVEngineServer*) -
//! see ExamplePlugin.zig for the minimal contract a plugin author needs
//! to satisfy.
//!
//! Two ways to load a batch of plugins:
//!   - `loadDirectory`: every ".so" in a folder, in whatever order the
//!     filesystem happens to hand them back. No dependency awareness.
//!   - `loadDirectoryWithManifests`: every ".toml" manifest in a folder
//!     (see PluginManifest.zig for the schema), loaded in dependency
//!     order - a plugin's dependencies are guaranteed to already be
//!     loaded (and to have actually succeeded) before it is. Prefer this
//!     one once your plugins start depending on each other.
//!
//! Either way, a plugin that's missing a required symbol, or whose
//! load() returns false, is skipped (logged, not fatal) - one broken
//! plugin shouldn't take the rest down with it, same philosophy as the
//! engine's own VSP loading.
//!
//! *** UNVERIFIED, LIKELY THE WEAKEST PART OF THIS FILE ***
//! `listPluginFiles` is the one function here doing blocking directory
//! I/O, which is exactly the area Zig 0.16 reworked the most (the std.Io
//! interface) - same caveat as VTableResolver.zig/PluginManifest.zig. If
//! this doesn't compile against your toolchain, swap its body for
//! whatever directory-listing approach already works in your project and
//! hand `loadDirectory`/`loadDirectoryWithManifests` the resulting path
//! list; `loadOne` (the actual dlopen/dlsym/call machinery) only needs a
//! plain path string and doesn't care how you found it.
//!
//! dlopen/dlsym/dlclose aren't raw syscalls, so this needs libc linked in
//! - same as VTableResolver.zig, and for the same reason engine_adapter.cpp
//! already requires it (libstdc++ pulls libc in transitively), this
//! shouldn't be a new practical dependency.
//!
//! I could not compile-check this file myself (no Zig 0.16 toolchain, and
//! obviously no TF2 server, available here) - please build and load a
//! couple of test plugins - including a dependency chain and a
//! deliberately-broken one - before relying on it.

const std = @import("std");
const PluginManifest = @import("PluginManifest.zig");

const RTLD_NOW: c_int = 2;
extern fn dlopen(path: ?[*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn dlclose(handle: ?*anyopaque) c_int;

extern fn EngineAdapter_LogPrint(engine: *anyopaque, msg: [*:0]const u8) void;

const LoadFn = *const fn (engine: *anyopaque) callconv(.c) bool;
const UnloadFn = *const fn () callconv(.c) void;

pub const LoadPluginError = error{
    DlOpenFailed,
    MissingLoad,
    MissingUnload,
    PluginLoadRejected,
} || std.mem.Allocator.Error;

const LoadedPlugin = struct {
    handle: *anyopaque,
    unload_fn: UnloadFn,
    /// Allocator-owned, null-terminated; kept around for logging and so
    /// unloadAll can free it.
    path: [:0]const u8,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    engine: *anyopaque,
    plugins: std.ArrayList(LoadedPlugin),

    pub fn init(allocator: std.mem.Allocator, engine: *anyopaque) Manager {
        return .{ .allocator = allocator, .engine = engine, .plugins = .empty };
    }

    fn logLine(self: *const Manager, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const line: [:0]const u8 = if (std.fmt.bufPrintZ(&buf, fmt, args)) |formatted|
            formatted
        else |_|
            "[Zorcerer] (message too long to log)\n";
        EngineAdapter_LogPrint(self.engine, line.ptr);
    }

    /// dlopen()s `path`, requires both `load` and `unload` to be present,
    /// calls `load(engine)`, and - only if all of that succeeds - keeps
    /// the plugin tracked for later `unloadAll`. On any failure, nothing
    /// is left tracked and the dlopen handle (if any) is released; the
    /// specific error is also logged through the engine before being
    /// returned, so a caller that just wants to skip-and-continue over
    /// many plugins doesn't have to re-derive a message from the error
    /// value.
    pub fn loadOne(self: *Manager, path: []const u8) LoadPluginError!void {
        const path_z = try self.allocator.dupeZ(u8, path);
        errdefer self.allocator.free(path_z);

        const handle = dlopen(path_z.ptr, RTLD_NOW) orelse {
            self.logLine("[Zorcerer] dlopen failed: {s}\n", .{path});
            return error.DlOpenFailed;
        };
        errdefer _ = dlclose(handle);

        const load_sym = dlsym(handle, "load") orelse {
            self.logLine("[Zorcerer] {s}: no load() exported - skipping\n", .{path});
            return error.MissingLoad;
        };
        const unload_sym = dlsym(handle, "unload") orelse {
            self.logLine("[Zorcerer] {s}: no unload() exported - skipping\n", .{path});
            return error.MissingUnload;
        };

        const load_fn: LoadFn = @ptrCast(load_sym);
        const unload_fn: UnloadFn = @ptrCast(unload_sym);

        if (!load_fn(self.engine)) {
            self.logLine("[Zorcerer] {s}: load() returned false - not keeping it loaded\n", .{path});
            return error.PluginLoadRejected;
        }

        try self.plugins.append(self.allocator, .{
            .handle = handle,
            .unload_fn = unload_fn,
            .path = path_z,
        });
        self.logLine("[Zorcerer] loaded plugin: {s}\n", .{path});
    }

    /// Loads every ".so" file directly inside `dir_path`, in whatever
    /// order the filesystem returns them - no dependency awareness. See
    /// `loadDirectoryWithManifests` for dependency-ordered loading.
    /// Failures are logged and skipped, not propagated.
    pub fn loadDirectory(self: *Manager, dir_path: []const u8) !void {
        const paths = try listPluginFiles(self.allocator, dir_path, ".so");
        defer {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
        }

        for (paths) |path| {
            self.loadOne(path) catch continue; // loadOne already logged why
        }
    }

    /// Discovers every ".toml" manifest directly inside `dir_path` (see
    /// PluginManifest.zig for the schema), resolves a load order where
    /// every dependency comes before whatever depends on it, and loads
    /// each plugin's `file` in that order. A plugin whose load() fails,
    /// or whose own manifest fails to parse, is skipped and logged - and
    /// so is anything that (transitively) depends on it, since its
    /// dependency didn't actually end up loaded. A manifest error that
    /// makes a consistent load order impossible at all (a missing
    /// dependency, a version that can't be satisfied by what's present,
    /// a circular dependency) aborts the whole batch and is returned, not
    /// just logged - those aren't "this one plugin is broken" situations,
    /// they're "the dependency graph you described doesn't make sense".
    pub fn loadDirectoryWithManifests(self: *Manager, dir_path: []const u8) !void {
        const manifest_paths = try listPluginFiles(self.allocator, dir_path, ".toml");
        defer {
            for (manifest_paths) |p| self.allocator.free(p);
            self.allocator.free(manifest_paths);
        }

        var manifests: std.ArrayList(PluginManifest.Manifest) = .empty;
        defer {
            for (manifests.items) |m| m.deinit(self.allocator);
            manifests.deinit(self.allocator);
        }

        for (manifest_paths) |path| {
            const text = PluginManifest.readWholeFile(self.allocator, path) catch |err| {
                self.logLine("[Zorcerer] couldn't read manifest {s}: {s}\n", .{ path, @errorName(err) });
                continue;
            };
            defer self.allocator.free(text);

            const manifest_dir = std.Io.Dir.path.dirname(path) orelse dir_path;
            const manifest = PluginManifest.parseManifest(self.allocator, manifest_dir, text) catch |err| {
                self.logLine("[Zorcerer] bad manifest {s}: {s}\n", .{ path, @errorName(err) });
                continue;
            };
            try manifests.append(self.allocator, manifest);
        }

        const order = PluginManifest.resolveLoadOrder(self.allocator, manifests.items) catch |err| {
            self.logLine("[Zorcerer] dependency graph is invalid: {s}\n", .{@errorName(err)});
            return err;
        };
        defer self.allocator.free(order);

        // Tracks which manifest IDs in *this batch* actually finished
        // loading successfully - separate from `self.plugins`, which
        // tracks dlopen handles by path, not by the manifest's logical
        // id. A dependency only counts here if its own load() returned
        // true, not merely if its manifest parsed.
        var loaded_ids = std.StringHashMap(void).init(self.allocator);
        defer loaded_ids.deinit();

        for (order) |m| {
            var deps_ok = true;
            for (m.dependencies) |dep| {
                if (!loaded_ids.contains(dep.id)) {
                    deps_ok = false;
                    break;
                }
            }
            if (!deps_ok) {
                self.logLine("[Zorcerer] skipping {s}: a dependency failed to load\n", .{m.id});
                continue;
            }

            const so_path = try std.Io.Dir.path.join(self.allocator, &.{ m.dir, m.file });
            defer self.allocator.free(so_path);

            self.loadOne(so_path) catch continue; // loadOne already logged why
            try loaded_ids.put(m.id, {});
        }
    }

    /// Calls `unload()` and dlclose()s every currently-tracked plugin, in
    /// the reverse of the order they were loaded in - with
    /// `loadDirectoryWithManifests`, that's exactly "dependents before
    /// their dependencies". Call this from SourcePlugin.zig's own
    /// `unload`.
    pub fn unloadAll(self: *Manager) void {
        var i = self.plugins.items.len;
        while (i > 0) {
            i -= 1;
            const plugin = self.plugins.items[i];
            self.logLine("[Zorcerer] unloading plugin: {s}\n", .{plugin.path});
            plugin.unload_fn();
            _ = dlclose(plugin.handle);
            self.allocator.free(plugin.path);
        }
        self.plugins.deinit(self.allocator);
        self.plugins = .empty;
    }
};

/// Lists every regular file directly inside `dir_path` whose name ends
/// with `suffix` (e.g. ".so" or ".toml"), as allocator-owned,
/// null-terminated paths (dir_path joined with the entry name) - free
/// each one, then the slice itself.
pub fn listPluginFiles(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    suffix: []const u8,
) ![]const [:0]const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var paths: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;

        const full_path = try std.fs.path.joinZ(allocator, &.{ dir_path, entry.name });
        try paths.append(allocator, full_path);
    }

    return try paths.toOwnedSlice(allocator);
}
