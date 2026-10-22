const std = @import("std");
const toml = @import("toml");
const abi = @import("plugin-abi");
const Log = @import("log");

/// Plugin directory relative to the process working directory.
/// If srcds is launched from the server root, this usually starts with "tf/".
///
/// The manager treats each directory inside plugins_directory as one plugin slot:
///
///     tf/addons/zorcerer/plugins/<dir>/<name>.so
///
/// Only .so files placed directly inside such a directory are picked up;
/// files at the top of plugins_directory, deeper nesting and symlinked
/// directories (readdir reports them as sym_link entries) are not scanned.
const plugins_directory = "tf/addons/zorcerer/plugins";

/// Metadata described by a plugin manifest.
pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    author: []const u8,
    file: []const u8,
};

/// One plugin .so held in the manager's cache.
pub const Plugin = struct {
    /// Path the library was opened with (joined from plugins_directory).
    /// Owned by the manager.
    path: []const u8,
    /// dlopen() handle of the plugin library.
    lib: std.DynLib,
    /// `load` export of the lib; both exports exist by construction.
    load: abi.LoadFn,
    /// `unload` export of the lib.
    unload: abi.UnloadFn,
    /// Whether load() succeeded, i.e. whether unload() must still be run.
    active: bool = false,
};

/// Minimal plugin manager.
/// readConfig() returns parsed manifests owned by the manager. The returned
/// data remains valid until the next readConfig() call or deinit().
///
/// Independently of manifests, loadPlugins() discovers plugin libraries
/// (see plugins_directory and Plugin), caches them and calls each plugin's
/// load(); unloadAll() reverses that for every plugin that became active,
/// then releases the cache. Plugins only ever talk to the host through
/// src/PluginAbi.zig, so no plugin-defined code needs direct links into the
/// process. A plugin is skipped (with a log line through the logger) when
/// its directory cannot be opened, dlopen() fails or an export is missing.
pub const Manager = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,

    // init() does not accept std.Io, so use the single-threaded adapter for this prototype.
    threaded_io: std.Io.Threaded = .init_single_threaded,

    manifest_result: ?[]Manifest = null,

    /// How to print into the server console, captured by setLogger() and
    /// handed to every plugin inside HostApi. Null until setLogger().
    logger: ?abi.Logger = null,

    /// Cached plugin libraries: filled by loadPlugins(), emptied and
    /// released by unloadAll().
    plugins: std.ArrayList(Plugin) = .empty,

    pub fn init() @This() {
        return .{};
    }

    /// Unloads every plugin remembered by loadPlugins() and frees all
    /// parsed manifests retained by the manager.
    /// This can be called with defer.
    pub fn deinit(self: *@This()) void {
        self.unloadAll();
        self.plugins.deinit(self.allocator);
        self.clearManifestResult();
    }

    fn freeManifest(self: *@This(), manifest: Manifest) void {
        self.allocator.free(manifest.id);
        self.allocator.free(manifest.name);
        self.allocator.free(manifest.version);
        self.allocator.free(manifest.author);
        self.allocator.free(manifest.file);
    }

    fn clearManifestResult(self: *@This()) void {
        if (self.manifest_result) |manifests| {
            for (manifests) |manifest| {
                self.freeManifest(manifest);
            }
            self.allocator.free(manifests);
            self.manifest_result = null;
        }
    }

    fn duplicateManifest(self: *@This(), manifest: Manifest) !Manifest {
        const id = try self.allocator.dupe(u8, manifest.id);
        errdefer self.allocator.free(id);

        const name = try self.allocator.dupe(u8, manifest.name);
        errdefer self.allocator.free(name);

        const version = try self.allocator.dupe(u8, manifest.version);
        errdefer self.allocator.free(version);

        const author = try self.allocator.dupe(u8, manifest.author);
        errdefer self.allocator.free(author);

        const file = try self.allocator.dupe(u8, manifest.file);
        errdefer self.allocator.free(file);

        return .{
            .id = id,
            .name = name,
            .version = version,
            .author = author,
            .file = file,
        };
    }

    /// Finds and parses every .toml file under plugins_directory into Manifest.
    /// The order follows filesystem traversal order and is not guaranteed.
    /// The returned slice and its strings are owned by the manager and remain
    /// valid until the next readConfig() call or deinit().
    pub fn readConfig(self: *@This()) ![]const Manifest {
        self.clearManifestResult();

        const io = self.threaded_io.io();
        var root = try std.Io.Dir.cwd().openDir(io, plugins_directory, .{ .iterate = true });
        defer root.close(io);

        var walker = try root.walk(self.allocator);
        defer walker.deinit();

        var manifests: std.ArrayList(Manifest) = .empty;
        errdefer {
            for (manifests.items) |manifest| {
                self.freeManifest(manifest);
            }
            manifests.deinit(self.allocator);
        }

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".toml")) {
                continue;
            }

            const full_path = try std.Io.Dir.path.join(
                self.allocator,
                &.{ plugins_directory, entry.path },
            );
            defer self.allocator.free(full_path);

            var parser = toml.Parser(Manifest).init(self.allocator);
            defer parser.deinit();

            var parsed = try parser.parseFile(io, full_path);
            defer parsed.deinit();

            const manifest = try self.duplicateManifest(parsed.value);
            manifests.append(self.allocator, manifest) catch |err| {
                self.freeManifest(manifest);
                return err;
            };
        }

        const owned_result = try manifests.toOwnedSlice(self.allocator);
        self.manifest_result = owned_result;
        return owned_result;
    }

    /// Captures how the manager and every plugin send messages into the
    /// server console: an opaque host context is paired with the print
    /// function that consumes it (for Entrypoint.zig: the engine's
    /// IVEngineServer pointer together with its LogPrint vtable entry).
    /// The same sink is handed to the Log module for the manager's own
    /// messages. Must be called before loadPlugins() for the scanned
    /// plugins to receive a logger.
    pub fn setLogger(self: *@This(), context: *anyopaque, print: abi.Logger.PrintFn) void {
        self.logger = .{ .context = context, .print = print };
        Log.setup(self.logger.?);
    }

    /// Builds the HostApi handed to plugin entry points. The returned
    /// value borrows self.logger and is only valid while self lives.
    fn hostApi(self: *@This()) abi.HostApi {
        return .{ .logger = if (self.logger) |*logger| logger else null };
    }

    /// Iterates the directories inside plugins_directory, opens every .so
    /// file directly inside them, looks up the plugin ABI's load()/unload()
    /// exports (src/PluginAbi.zig), adds the library into the cache and
    /// calls its load(). Sketchy entities are skipped with a log line
    /// instead of aborting the whole scan; everything cached until then is
    /// unloaded on the way out if a fatal error aborts the scan.
    pub fn loadPlugins(self: *@This()) !void {
        if (self.plugins.items.len != 0) {
            return error.AlreadyLoaded;
        }

        errdefer self.unloadAll();

        const io = self.threaded_io.io();
        var root = try std.Io.Dir.cwd().openDir(io, plugins_directory, .{ .iterate = true });
        defer root.close(io);

        var dirs = root.iterate();
        while (try dirs.next(io)) |dir| {
            if (dir.kind != .directory) {
                continue;
            }

            var plugin_dir = root.openDir(io, dir.name, .{ .iterate = true }) catch |err| {
                Log.logLine("[zorcerer] {s}/{s}: openDir failed ({s}), skipping\n", .{ plugins_directory, dir.name, @errorName(err) });
                continue;
            };
            defer plugin_dir.close(io);

            var files = plugin_dir.iterate();
            while (try files.next(io)) |file| {
                if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".so")) {
                    continue;
                }

                try self.cachePlugin(dir.name, file.name);
            }
        }
    }

    /// Opens one .so file, resolves its exports, adds it into the cache and
    /// activates it. Failures remove the plugin from the scan (and free
    /// everything attached to it) instead of failing loadPlugins().
    fn cachePlugin(self: *@This(), dir_name: []const u8, file_name: []const u8) !void {
        const path = try std.Io.Dir.path.join(self.allocator, &.{ plugins_directory, dir_name, file_name });
        errdefer self.allocator.free(path);

        var lib = std.DynLib.open(path) catch |err| {
            Log.logLine("[zorcerer] {s}: dlopen failed ({s}), skipping\n", .{ path, @errorName(err) });
            return;
        };

        // Both exports are required: load() binds the plugin, and unload()
        // is what lets the manager ever release it again.
        const load_fn = lib.lookup(abi.LoadFn, "load") orelse {
            Log.logLine("[zorcerer] {s}: missing load() export, skipping\n", .{path});
            lib.close();
            return;
        };

        const unload_fn = lib.lookup(abi.UnloadFn, "unload") orelse {
            Log.logLine("[zorcerer] {s}: missing unload() export, skipping\n", .{path});
            lib.close();
            return;
        };

        try self.plugins.append(self.allocator, .{
            .path = path,
            .lib = lib,
            .load = load_fn,
            .unload = unload_fn,
        });

        self.activatePlugin(&self.plugins.items[self.plugins.items.len - 1]);
    }

    /// Calls the plugin's load() with the host API; a nonzero status marks
    /// it inactive so unloadAll() leaves it (and its unload()) alone.
    fn activatePlugin(self: *@This(), plugin: *Plugin) void {
        var host = self.hostApi();
        const status = plugin.load(&host);
        if (status != 0) {
            Log.logLine("[zorcerer] {s}: load() returned {d}, not marked active\n", .{ plugin.path, status });
            return;
        }

        plugin.active = true;
    }

    /// Runs everyone's unload() in reverse discovery order (last loaded
    /// unloads first), dlcloses every cached library and releases the
    /// cache. loadPlugins() can be used again afterwards.
    pub fn unloadAll(self: *@This()) void {
        const host = self.hostApi();

        var remaining = self.plugins.items.len;
        while (remaining > 0) {
            remaining -= 1;
            const plugin = &self.plugins.items[remaining];

            if (plugin.active) {
                plugin.active = false;
                const status = plugin.unload(&host);
                if (status != 0) {
                    Log.logLine("[zorcerer] {s}: unload() returned {d}\n", .{ plugin.path, status });
                }
            }

            plugin.lib.close();
            self.allocator.free(plugin.path);
        }

        self.plugins.clearRetainingCapacity();
    }
};
