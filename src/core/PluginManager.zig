const std = @import("std");
const Ipc = @import("Ipc.zig");
const root = @import("../root.zig");
const abi = root.abi;
const Log = root.io.Log;
const PluginConfiguration = @import("plugin-configuration").PluginConfiguration;
const PluginDependency = @import("PluginDependency.zig");
const PluginLibrary = @import("plugin-library");
const zlua = @import("zlua");

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

/// Name of the manifest file inside every plugin directory.
const manifest_name = "manifest.toml";

/// One plugin .so held in the manager's cache.
pub const Plugin = struct {
    /// Path the library was opened with (joined from plugins_directory and
    /// the manifest's library path). Owned by the manager.
    path: []const u8,
    /// Open library with its resolved `load`/`unload` exports.
    library: PluginLibrary.Library,
    /// ABI context handed to load()/unload(). Owned by the manager; its
    /// `Text` fields borrow `manifest_result`.
    context: *abi.PluginContext,
    /// Whether load() succeeded, i.e. whether unload() must still be run.
    active: bool = false,
};

/// One Lua script loaded directly by the manager.
///
/// A script is discovered as `main.lua` inside a plugin directory. It runs in
/// its own `zlua` state, registers callbacks through `zostd.on`, and is called
/// directly by the manager on the existing IPC events. This is the prototype
/// path for ZLua; it does not use the native `.so` plugin ABI.
pub const LuaScript = struct {
    /// Plugin id shown to the script through `zostd.plugin_id()`.
    /// Owned by the manager.
    plugin_id: []const u8,
    /// Root directory used by `plugin://` file access. Owned by the manager.
    root: []const u8,
    /// Script path used in error messages. Owned by the manager.
    path: []const u8,
    /// Independent Lua state for this script.
    runtime: zlua.runtime.Runtime,
};

/// One lifecycle event emitted by the manager while loading plugins.
///
/// Payload slices borrow the manager's validated configurations and library
/// paths and are only valid for the duration of the listener callback. A
/// listener that needs to retain them must copy the data.
pub const ManagerEvent = union(enum) {
    /// The manager reached a plugin that declares dependencies and passed
    /// graph validation. The event is delivered immediately before its
    /// dynamic library is opened.
    awaiting_dependencies: struct {
        /// Id of the plugin whose dependencies are being processed.
        plugin_id: []const u8,
        /// Dependencies declared by that plugin, sorted by id.
        dependencies: []const PluginConfiguration.Dependency,
    },
    /// The plugin will not be loaded because a dependency is missing,
    /// mismatched, part of a cycle, or failed to load.
    dependency_rejected: struct {
        /// Id of the plugin that will be skipped.
        plugin_id: []const u8,
        /// Details about the rejected dependency edge or cycle.
        rejection: PluginDependency.Rejection,
    },
    /// The plugin's dynamic library could not be opened, loaded, or did not
    /// expose the required ABI symbols. The plugin and its transitively
    /// dependent plugins are skipped.
    library_rejected: struct {
        /// Id of the plugin that will be skipped.
        plugin_id: []const u8,
        /// Library path the manager tried to open.
        path: []const u8,
        /// Structured failure category.
        reason: PluginLibrary.RejectionReason,
        /// Underlying loader error when one applies; null for missing
        /// symbols and for nonzero plugin load() returns.
        detail: ?anyerror = null,
    },
};

/// In-process sink for manager lifecycle events.
///
/// The manager and the loaded plugins live in the same process, so this is a
/// direct Zig callback rather than an IPC message. The plugin itself cannot
/// receive `awaiting_dependencies`: dependency resolution happens before its
/// dynamic library is opened.
pub const ManagerListener = struct {
    /// Opaque value passed back to `notify`; may be null.
    context: ?*anyopaque,
    /// Called synchronously for every manager event.
    notify: *const fn (context: ?*anyopaque, event: ManagerEvent) void,
};

/// Minimal plugin manager.
///
/// readConfig() returns validated plugin configurations owned by the
/// manager. The returned data remains valid until the next readConfig()
/// call or deinit().
///
/// Independently of manifests, loadPlugins() discovers each directory's
/// `main.lua` (see LuaScript) and its plugin libraries (see plugins_directory
/// and Plugin), resolves the native plugins' dependency graph, caches them
/// in dependency-first order and calls each plugin's load(); unloadAll()
/// reverses that for every plugin that became active, then releases the
/// cache. Plugins only ever talk to the host through src/core/PluginContext.zig,
/// so no plugin-defined code needs direct links into the process. A plugin is
/// skipped (with a log line through the logger, or a ManagerListener event)
/// when its directory cannot be opened, its manifest is missing or invalid,
/// a dependency cannot be satisfied, its manifest library cannot be opened,
/// an export is missing, or its load() returns nonzero.
pub const Manager = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,

    // init() does not accept std.Io, so use the single-threaded adapter for this prototype.
    threaded_io: std.Io.Threaded = .init_single_threaded,

    /// Validated manifests retained by readConfig()/loadPlugins(). Owned by
    /// the manager; released by clearManifestResult().
    manifest_result: ?[]PluginConfiguration = null,

    /// How to print into the server console, captured by setLogger() and
    /// handed to every plugin inside its PluginContext. Null until setLogger().
    logger: ?abi.Logger = null,

    /// Optional in-process observer for manager lifecycle events.
    /// When null, events are logged through the manager's logger.
    manager_listener: ?ManagerListener = null,

    /// Cached plugin libraries: filled by loadPlugins(), emptied and
    /// released by unloadAll().
    plugins: std.ArrayList(Plugin) = .empty,

    /// Lua scripts loaded directly by the manager: filled by loadPlugins(),
    /// emptied and released by unloadAll().
    lua_scripts: std.ArrayList(LuaScript) = .empty,

    pub fn init() @This() {
        return .{};
    }

    /// Unloads every plugin remembered by loadPlugins() and frees all
    /// validated manifests retained by the manager.
    /// This can be called with defer.
    pub fn deinit(self: *@This()) void {
        self.unloadAll();
        self.plugins.deinit(self.allocator);
        self.lua_scripts.deinit(self.allocator);
        if (event_manager == self) event_manager = null;
        self.clearManifestResult();
    }

    /// Releases every configuration retained by readConfig() and clears the
    /// cached slice.
    ///
    /// Side effects: deinitializes every configuration's strings and frees
    /// the slice.
    fn clearManifestResult(self: *@This()) void {
        if (self.manifest_result) |manifests| {
            for (manifests) |*manifest| {
                manifest.deinit(self.allocator);
            }
            self.allocator.free(manifests);
            self.manifest_result = null;
        }
    }

    /// Reads and validates the manifest of every plugin directory directly
    /// inside plugins_directory.
    ///
    /// Directories with an unreadable manifest or invalid contents are
    /// logged and skipped; so is a directory that provides native libraries
    /// but no manifest. Lua-only directories without a manifest are skipped
    /// silently. The remaining directories are still returned. The order
    /// follows filesystem iteration order and is not guaranteed.
    ///
    /// Returns a slice owned by the manager whose strings remain valid until
    /// the next readConfig() call or deinit().
    ///
    /// Precondition: no plugin may be loaded, because every loaded plugin's
    /// PluginContext borrows these strings. Calling this while plugins are
    /// cached returns `error.PluginsLoaded` without changing any state.
    ///
    /// Errors: `error.PluginsLoaded` when loadPlugins() has cached a native
    /// plugin, `error.FileNotFound` when plugins_directory itself does not
    /// exist, `error.AccessDenied` and other I/O errors when it cannot be
    /// opened, and `error.OutOfMemory` when retaining the result fails. A
    /// broken individual manifest never fails the whole read.
    pub fn readConfig(self: *@This()) ![]const PluginConfiguration {
        if (self.plugins.items.len != 0) return error.PluginsLoaded;
        self.clearManifestResult();

        const io = self.threaded_io.io();
        var plugin_root = try std.Io.Dir.cwd().openDir(io, plugins_directory, .{ .iterate = true });
        defer plugin_root.close(io);

        var configurations: std.ArrayList(PluginConfiguration) = .empty;
        errdefer {
            for (configurations.items) |*configuration| {
                configuration.deinit(self.allocator);
            }
            configurations.deinit(self.allocator);
        }

        var dirs = plugin_root.iterate();
        while (try dirs.next(io)) |dir| {
            if (dir.kind != .directory) continue;

            var configuration = self.readPluginManifest(dir.name) catch |err| {
                if (err == error.OutOfMemory) return err;

                // A directory without a manifest is only an error when it
                // actually provides native libraries. Lua-only directories
                // are legitimate and must stay silent.
                if (err == error.FileNotFound) {
                    const has_native = self.directoryHasNativeLibrary(dir.name) catch |scan_err| {
                        if (scan_err == error.OutOfMemory) return scan_err;
                        Log.logLine(
                            "[zorcerer] {s}/{s}: could not inspect directory ({s}), skipping\n",
                            .{ plugins_directory, dir.name, @errorName(scan_err) },
                        );
                        continue;
                    };
                    if (!has_native) continue;
                }

                logManifestFailure(dir.name, err);
                continue;
            };
            configurations.append(self.allocator, configuration) catch |err| {
                configuration.deinit(self.allocator);
                return err;
            };
        }

        const owned_result = try configurations.toOwnedSlice(self.allocator);
        self.manifest_result = owned_result;
        return owned_result;
    }

    /// Reads, parses, and validates `<plugins_directory>/<dir_name>/manifest.toml`.
    ///
    /// Returns a configuration owned by the manager's allocator. Any error
    /// leaves no allocated state behind.
    ///
    /// Errors: filesystem errors from reading the manifest,
    /// `error.FileSizeOverflow`, `error.KeysNotImplemented`,
    /// `error.MissingRequiredField`, `error.WrongValueType`,
    /// `error.InvalidValue` from validation, `error.OutOfMemory`, and any
    /// TOML parser error.
    fn readPluginManifest(self: *@This(), dir_name: []const u8) !PluginConfiguration {
        const io = self.threaded_io.io();
        const path = try std.Io.Dir.path.join(
            self.allocator,
            &.{ plugins_directory, dir_name, manifest_name },
        );
        defer self.allocator.free(path);

        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .unlimited);
        defer self.allocator.free(raw);

        var configuration = try PluginConfiguration.parseConfig(self.allocator, raw);
        errdefer configuration.deinit(self.allocator);
        try configuration.validateForDirectory(dir_name);
        return configuration;
    }

    /// Reports whether `<plugins_directory>/<dir_name>` contains at least
    /// one `.so` file directly inside it.
    ///
    /// Used to distinguish a Lua-only directory (no manifest required) from
    /// a native plugin directory whose manifest is missing.
    ///
    /// Errors: filesystem errors from opening or iterating the directory and
    /// `error.OutOfMemory` when building the path.
    fn directoryHasNativeLibrary(self: *@This(), dir_name: []const u8) !bool {
        const io = self.threaded_io.io();
        const path = try std.Io.Dir.path.join(
            self.allocator,
            &.{ plugins_directory, dir_name },
        );
        defer self.allocator.free(path);

        var plugin_dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer plugin_dir.close(io);

        var files = plugin_dir.iterate();
        while (try files.next(io)) |file| {
            if (file.kind == .file and std.mem.endsWith(u8, file.name, ".so")) {
                return true;
            }
        }
        return false;
    }

    /// Logs why one plugin directory's manifest was rejected. Keeps the
    /// scenario names from docs/architecture/plugin-context.md visible in
    /// the server console.
    fn logManifestFailure(dir_name: []const u8, err: anyerror) void {
        const reason: []const u8 = switch (err) {
            error.FileNotFound => "manifest.toml not found",
            error.MissingRequiredField => "manifest is missing required keys",
            error.KeysNotImplemented => "manifest has unknown keys",
            error.WrongValueType,
            error.InvalidValue,
            error.FileSizeOverflow,
            => "manifest has invalid values",
            else => "manifest could not be read or parsed",
        };
        Log.logLine(
            "[zorcerer] {s}/{s}/{s}: {s} ({s}), native plugins skipped\n",
            .{ plugins_directory, dir_name, manifest_name, reason, @errorName(err) },
        );
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

    /// Replaces the engine logger with the IPC channel to the parent.
    ///
    /// Intended for the forked plugin-manager process before loadPlugins():
    /// manager and plugin messages then travel to the parent as `stderr`
    /// notifications instead of calling the inherited engine LogPrint after
    /// the fork. `fd` is the child's end of the fork's socket pair.
    pub fn setIpcLogger(self: *@This(), fd: std.os.linux.fd_t) void {
        Log.setupIpc(fd);
        self.logger = .{ .context = self, .print = Log.pluginPrint };
    }

    /// Installs the in-process observer for manager lifecycle events.
    ///
    /// Passing a listener replaces any previous one; there is no separate
    /// clear function because the caller can keep its own lifetime and stop
    /// observing by installing a no-op listener. The listener is called
    /// synchronously from loadPlugins() on the manager's thread, and its
    /// event payload borrows the manager's manifests and paths.
    pub fn setManagerListener(self: *@This(), listener: ManagerListener) void {
        self.manager_listener = listener;
    }

    /// Builds the ABI context handed to one plugin entry point.
    ///
    /// The returned value borrows `configuration` (for its identity strings)
    /// and self.logger. Both must outlive the plugin's loaded lifetime; the
    /// caller stores the context on the heap so its address stays stable.
    fn buildContext(
        self: *@This(),
        configuration: *const PluginConfiguration,
    ) abi.PluginContext {
        return .{
            .abi_version = abi.abi_version,
            .struct_size = @sizeOf(abi.PluginContext),
            .logger = if (self.logger) |*logger| logger else null,
            .plugin = .{
                .id = abi.Text.fromSlice(configuration.id),
                .name = abi.Text.fromSlice(configuration.name),
                .version = abi.Text.fromSlice(configuration.version),
                .author = abi.Text.fromSlice(configuration.author),
                .library_path = abi.Text.fromSlice(configuration.path),
            },
        };
    }

    /// Loads every plugin discovered under plugins_directory.
    ///
    /// First, each directory's `main.lua` is loaded into its own ZLua
    /// runtime; Lua scripts do not require a manifest. Then every manifest
    /// is read and validated through readConfig(), the native dependency
    /// graph is resolved, and each accepted plugin is loaded in
    /// dependency-first order: only the library named by the manifest's
    /// `path` is opened, its `load()`/`unload()` exports
    /// (src/core/PluginContext.zig) are resolved, a per-plugin context is
    /// stored, and its `load(ctx)` is called.
    ///
    /// Manifests that fail validation are logged and skipped for native
    /// plugins. Plugins with a missing dependency, a version mismatch, a
    /// dependency cycle, a dependency that failed to load, or a rejected
    /// dynamic library are reported through the ManagerListener (or the log
    /// when no listener is installed) and skipped together with their
    /// transitive dependents. Other plugins are still loaded. Everything
    /// cached until then is unloaded on the way out if a fatal error aborts
    /// the scan.
    ///
    /// Individual plugin rejections are not fatal: loadPlugins() returns
    /// successfully even when every native plugin is skipped. Only global
    /// failures such as `error.OutOfMemory` or an unreadable plugin root
    /// propagate.
    ///
    /// Precondition: no native plugin is cached. Use unloadAll() before
    /// loading again.
    ///
    /// Errors: `error.AlreadyLoaded` when a previous loadPlugins() still has
    /// cached plugins or Lua scripts, plus global filesystem and allocation
    /// errors. Per-plugin failures are reported as events instead.
    pub fn loadPlugins(self: *@This()) !void {
        if (self.plugins.items.len != 0 or self.lua_scripts.items.len != 0) {
            return error.AlreadyLoaded;
        }

        event_manager = self;
        errdefer self.unloadAll();

        const io = self.threaded_io.io();
        var plugin_root = try std.Io.Dir.cwd().openDir(io, plugins_directory, .{ .iterate = true });
        defer plugin_root.close(io);

        // Lua scripts are independent of the native plugin ABI and do not
        // need a manifest. A directory may contain both a script and
        // managed .so plugins.
        var dirs = plugin_root.iterate();
        while (try dirs.next(io)) |dir| {
            if (dir.kind != .directory) continue;
            self.loadLuaScript(dir.name);
        }

        // Only directories with a valid manifest participate in native
        // plugin loading. readConfig() logs and skips every rejected
        // manifest, so failures here are per-plugin, not fatal.
        const configurations = try self.readConfig();

        var resolution = try PluginDependency.resolve(self.allocator, configurations);
        defer resolution.deinit(self.allocator);

        // Ids that must not satisfy dependents: statically rejected plugins
        // and plugins that fail while their library is loaded.
        var unavailable = std.StringHashMap(void).init(self.allocator);
        defer unavailable.deinit();

        // Static graph failures are known before any dynamic library is
        // opened, so report them first, in manifest order.
        for (resolution.rejected) |rejection| {
            const configuration = configurations[rejection.plugin_index];
            self.notifyManagerEvent(.{ .dependency_rejected = .{
                .plugin_id = configuration.id,
                .rejection = rejection,
            } });
            try unavailable.put(configuration.id, {});
        }

        for (resolution.order) |configuration_index| {
            const configuration = configurations[configuration_index];

            if (configuration.dependencies.len != 0) {
                self.notifyManagerEvent(.{ .awaiting_dependencies = .{
                    .plugin_id = configuration.id,
                    .dependencies = configuration.dependencies,
                } });
            }

            var failed_dependency: ?[]const u8 = null;
            for (configuration.dependencies) |dependency| {
                if (unavailable.contains(dependency.id)) {
                    failed_dependency = dependency.id;
                    break;
                }
            }
            if (failed_dependency) |dependency_id| {
                self.notifyManagerEvent(.{ .dependency_rejected = .{
                    .plugin_id = configuration.id,
                    .rejection = .{
                        .plugin_index = configuration_index,
                        .reason = .dependency_rejected,
                        .dependency_id = dependency_id,
                    },
                } });
                try unavailable.put(configuration.id, {});
                continue;
            }

            const loaded = try self.loadPlugin(&configuration);
            if (!loaded) try unavailable.put(configuration.id, {});
        }
    }

    /// Opens one plugin's manifest library, builds its context, adds it to
    /// the cache and activates it.
    ///
    /// Only `configuration.path` is opened; other `.so` files in the same
    /// directory are ignored. A library that cannot be opened or lacks the
    /// required exports is reported through a `library_rejected` event and
    /// leaves no cached state. A library whose `load()` returns nonzero stays
    /// cached as inactive so unloadAll() can still close it and release its
    /// context, but it is reported through the same event and makes the
    /// plugin unavailable to dependents.
    ///
    /// Errors: `error.OutOfMemory` when path construction, context
    /// allocation, or caching fails.
    fn loadPlugin(self: *@This(), configuration: *const PluginConfiguration) !bool {
        const path = try std.Io.Dir.path.join(
            self.allocator,
            &.{ plugins_directory, configuration.id, configuration.path },
        );
        var path_owned = false;
        defer if (!path_owned) self.allocator.free(path);

        const opened = PluginLibrary.open(path);
        switch (opened) {
            .rejected => |rejection| {
                self.notifyManagerEvent(.{ .library_rejected = .{
                    .plugin_id = configuration.id,
                    .path = path,
                    .reason = rejection.reason,
                    .detail = rejection.detail,
                } });
                return false;
            },
            .loaded => |loaded| {
                var library = loaded;
                var library_owned = true;
                defer if (library_owned) library.close();

                const context = try self.allocator.create(abi.PluginContext);
                var context_owned = true;
                defer if (context_owned) self.allocator.destroy(context);
                context.* = self.buildContext(configuration);

                try self.plugins.append(self.allocator, .{
                    .path = path,
                    .library = library,
                    .context = context,
                });
                path_owned = true;
                library_owned = false;
                context_owned = false;

                return self.activatePlugin(&self.plugins.items[self.plugins.items.len - 1]);
            },
        }
    }

    /// Calls the plugin's load() with its context.
    ///
    /// Returns true when the plugin returned zero and was marked active. A
    /// nonzero status leaves it inactive so unloadAll() skips its unload()
    /// hook but still closes the library and frees the context. The failure
    /// is reported as `.invalid_configuration`, the closest structured
    /// category for a plugin that rejects the host or cannot initialize.
    fn activatePlugin(self: *@This(), plugin: *Plugin) bool {
        const status = plugin.library.load(plugin.context);
        if (status != 0) {
            self.notifyManagerEvent(.{ .library_rejected = .{
                .plugin_id = plugin.context.plugin.id.slice(),
                .path = plugin.path,
                .reason = .invalid_configuration,
            } });
            return false;
        }

        plugin.active = true;
        return true;
    }

    /// Delivers one manager event to the installed listener, or logs it when
    /// no listener is installed.
    ///
    /// The default logging path keeps loading decisions visible in the
    /// server console without requiring an observer. When a listener is
    /// installed, it owns presentation; the manager does not log in addition.
    fn notifyManagerEvent(self: *@This(), event: ManagerEvent) void {
        if (self.manager_listener) |listener| {
            listener.notify(listener.context, event);
            return;
        }

        switch (event) {
            .awaiting_dependencies => |awaiting| {
                Log.logLine(
                    "[zorcerer] {s}: awaiting dependencies\n",
                    .{awaiting.plugin_id},
                );
                for (awaiting.dependencies) |dependency| {
                    Log.logLine(
                        "[zorcerer]   {s} {s}\n",
                        .{ dependency.id, dependency.requirement },
                    );
                }
            },
            .dependency_rejected => |rejected| {
                if (rejected.rejection.dependency_id) |dependency_id| {
                    if (rejected.rejection.required) |required| {
                        if (rejected.rejection.found_version) |found| {
                            Log.logLine(
                                "[zorcerer] {s}: {s} requires {s}, found {s}\n",
                                .{ rejected.plugin_id, dependency_id, required, found },
                            );
                            return;
                        }
                    }
                    Log.logLine(
                        "[zorcerer] {s}: {s} ({s})\n",
                        .{ rejected.plugin_id, dependency_id, rejected.rejection.reason.text() },
                    );
                } else {
                    Log.logLine(
                        "[zorcerer] {s}: {s}\n",
                        .{ rejected.plugin_id, rejected.rejection.reason.text() },
                    );
                }
            },
            .library_rejected => |rejected| {
                if (rejected.detail) |detail| {
                    Log.logLine(
                        "[zorcerer] {s}: {s}: {s} ({s}), skipping\n",
                        .{
                            rejected.plugin_id,
                            rejected.path,
                            rejected.reason.text(),
                            @errorName(detail),
                        },
                    );
                } else {
                    Log.logLine(
                        "[zorcerer] {s}: {s} ({s}), skipping\n",
                        .{ rejected.plugin_id, rejected.path, rejected.reason.text() },
                    );
                }
            },
        }
    }

    /// Runs every active native plugin's unload() in reverse load order
    /// (last loaded unloads first, so dependents unload before their
    /// dependencies), dlcloses every cached library and releases the cache.
    /// Lua scripts are notified with `on_unload` in reverse load order, then
    /// their runtimes and owned strings are released.
    /// loadPlugins() can be used again afterwards.
    pub fn unloadAll(self: *@This()) void {
        var remaining = self.plugins.items.len;
        while (remaining > 0) {
            remaining -= 1;
            const plugin = &self.plugins.items[remaining];

            if (plugin.active) {
                plugin.active = false;
                const status = plugin.library.unload(plugin.context);
                if (status != 0) {
                    Log.logLine("[zorcerer] {s}: unload() returned {d}\n", .{ plugin.path, status });
                }
            }

            plugin.library.close();
            self.allocator.destroy(plugin.context);
            self.allocator.free(plugin.path);
        }

        self.plugins.clearRetainingCapacity();

        var remaining_scripts = self.lua_scripts.items.len;
        while (remaining_scripts > 0) {
            remaining_scripts -= 1;
            const script = &self.lua_scripts.items[remaining_scripts];

            script.runtime.dispatchEvent("on_unload", null);
            script.runtime.deinit();
            self.allocator.free(script.plugin_id);
            self.allocator.free(script.root);
            self.allocator.free(script.path);
        }

        self.lua_scripts.clearRetainingCapacity();
    }

    /// Loads `<plugins_directory>/<dir_name>/main.lua` into its own runtime.
    ///
    /// A missing script leaves the manager unchanged. Read, compile, and
    /// runtime failures are logged and the partially initialized state is
    /// released, matching how invalid native plugins are skipped. On success,
    /// the script receives the `on_load` event and is retained until
    /// `unloadAll()`.
    fn loadLuaScript(self: *@This(), dir_name: []const u8) void {
        const io = self.threaded_io.io();

        const script_path = std.Io.Dir.path.join(
            self.allocator,
            &.{ plugins_directory, dir_name, "main.lua" },
        ) catch |err| {
            Log.logLine(
                "[zlua] {s}/{s}/main.lua: path join failed ({s}), script skipped\n",
                .{ plugins_directory, dir_name, @errorName(err) },
            );
            return;
        };
        var keep_path = false;
        defer if (!keep_path) self.allocator.free(script_path);

        const source = std.Io.Dir.cwd().readFileAlloc(
            io,
            script_path,
            self.allocator,
            .unlimited,
        ) catch |err| {
            if (err != error.FileNotFound) {
                Log.logLine(
                    "[zlua] {s}: read failed ({s}), script skipped\n",
                    .{ script_path, @errorName(err) },
                );
            }
            return;
        };
        defer self.allocator.free(source);

        const plugin_id = self.allocator.dupe(u8, dir_name) catch |err| {
            Log.logLine(
                "[zlua] {s}: could not duplicate plugin id ({s}), script skipped\n",
                .{ script_path, @errorName(err) },
            );
            return;
        };
        var keep_plugin_id = false;
        defer if (!keep_plugin_id) self.allocator.free(plugin_id);

        const plugin_root = std.Io.Dir.path.join(
            self.allocator,
            &.{ plugins_directory, dir_name },
        ) catch |err| {
            Log.logLine(
                "[zlua] {s}: could not build plugin root ({s}), script skipped\n",
                .{ script_path, @errorName(err) },
            );
            return;
        };
        var keep_root = false;
        defer if (!keep_root) self.allocator.free(plugin_root);

        var runtime = zlua.runtime.Runtime.init(self.allocator) catch |err| {
            Log.logLine(
                "[zlua] {s}: could not create Lua state ({s}), script skipped\n",
                .{ script_path, @errorName(err) },
            );
            return;
        };
        var runtime_alive = true;
        defer if (runtime_alive) runtime.deinit();

        // The runtime borrows these slices, so they must outlive it. They are
        // moved into the manager's LuaScript entry on success.
        runtime.setPluginId(plugin_id);
        runtime.setPluginRoot(plugin_root);
        runtime.setHost(.{ .context = self, .log = luaLog });
        runtime.openSafeLibs();
        runtime.installZostd();

        var chunk_name_buffer: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        const chunk_name = std.fmt.bufPrintZ(
            &chunk_name_buffer,
            "@{s}",
            .{script_path},
        ) catch {
            Log.logLine(
                "[zlua] {s}: path is too long for a Lua chunk name, script skipped\n",
                .{script_path},
            );
            return;
        };

        runtime.run(source, chunk_name) catch |err| {
            const message = runtime.lua.toString(-1) catch "<non-string error>";
            Log.logLine(
                "[zlua] {s}: {s}: {s}\n",
                .{ script_path, @errorName(err), std.mem.span(message) },
            );
            return;
        };

        self.lua_scripts.append(self.allocator, .{
            .plugin_id = plugin_id,
            .root = plugin_root,
            .path = script_path,
            .runtime = runtime,
        }) catch |err| {
            Log.logLine(
                "[zlua] {s}: could not retain script ({s}), script skipped\n",
                .{ script_path, @errorName(err) },
            );
            return;
        };

        keep_path = true;
        keep_plugin_id = true;
        keep_root = true;
        runtime_alive = false;

        const script = &self.lua_scripts.items[self.lua_scripts.items.len - 1];
        Log.logLine("[zlua] loaded {s} as {s}\n", .{ script_path, plugin_id });
        script.runtime.dispatchEvent("on_load", null);
    }

    /// Delivers one manager event to every loaded Lua script.
    ///
    /// `event` is the `Ipc.Event` method name, for example `"pause"`. Runtime
    /// dispatch isolates and logs callback failures, so one script cannot stop
    /// delivery to the rest.
    pub fn dispatchEvent(self: *@This(), event: []const u8) void {
        for (self.lua_scripts.items) |*script| {
            script.runtime.dispatchEvent(event, null);
        }
    }
};

/// Manager whose Lua scripts receive IPC events.
///
/// `loadPlugins()` sets this to the manager that owns the loaded scripts and
/// `deinit()` clears it. The listener is a free function without a manager
/// parameter, so it reaches the manager through this process-global pointer.
/// The manager is single-threaded and lives in the forked child for the whole
/// lifetime of the listener.
var event_manager: ?*Manager = null;

/// Forwards one `zostd.log()` message from a Lua script to the manager's log.
///
/// `context` is the owning manager; the log sink itself is process-global
/// (see src/io/Log.zig), so the context is not used.
fn luaLog(context: ?*anyopaque, message: []const u8) void {
    _ = context;
    Log.logLine("[zlua] {s}\n", .{message});
}

/// Serves the Entrypoint's callback events on the manager's end of the IPC
/// channel until the Entrypoint closes it.
///
/// The channel is the socket pair created for the fork; after the fork, the
/// manager process owns this end and turns it into its JSON listener. The
/// Entrypoint holds the other end.
///
/// Each received frame must carry a JSON-RPC request whose method is one of
/// `Ipc.Event`'s callbacks, for example `{"jsonrpc":"2.0","method":"pause",
/// "id":1}`. Every valid event is delivered to the loaded Lua scripts before
/// any response is sent. Every request carrying an ID is answered with exactly
/// one JSON-RPC result or error response carrying that ID, so the Entrypoint's
/// synchronous event exchange never waits for a reply that will not come.
/// Notifications (requests without an ID) are served without a response,
/// as JSON-RPC requires. A message that cannot be decoded is answered with a
/// JSON-RPC error and the message "Event is invalid".
///
/// A frame that cannot be read, or whose marker is wrong, ends the listener:
/// the stream can no longer be resynchronized. The caller keeps ownership of
/// the manager and must still call `deinit()`.
///
/// Precondition: `fd` is the manager process' end of the socket pair created
/// for the fork. This runs in the forked child, not in the engine process.
pub fn listenForEvents(fd: std.os.linux.fd_t) void {
    while (true) {
        const frame = Ipc.readFrame(fd) catch |err| {
            if (err != error.PeerClosed) {
                Log.logLine(
                    "[zorcerer] event listener stopped: {s}\n",
                    .{@errorName(err)},
                );
            }
            return;
        };

        if (!frame.framed) {
            Log.logLine("[zorcerer] event listener: frame marker mismatch\n", .{});
            return;
        }

        if (!frame.received) {
            Log.logLine("[zorcerer] event listener: empty event frame\n", .{});
            if (!respondInvalidEvent(fd, frame.text())) return;
            continue;
        }

        const parsed = Ipc.parseEvent(std.heap.page_allocator, frame.text()) catch |err| {
            Log.logLine(
                "[zorcerer] event listener: invalid event ({s})\n",
                .{@errorName(err)},
            );
            if (!respondInvalidEvent(fd, frame.text())) return;
            continue;
        };
        defer parsed.deinit();

        if (event_manager) |manager| {
            manager.dispatchEvent(@tagName(parsed.value.event));
        }

        const request_id = parsed.id();
        if (request_id.isNotification()) continue;

        Ipc.sendEventResponse(fd, parsed.value.event, request_id) catch |err| {
            Log.logLine(
                "[zorcerer] event listener: replying to {s} failed: {s}\n",
                .{ @tagName(parsed.value.event), @errorName(err) },
            );
            return;
        };
    }
}

/// Answers an event that could not be decoded.
///
/// `request_json` is the original frame payload. When it is structurally a
/// JSON-RPC request, its ID is recovered so the error response can be matched
/// to the request. Keeping the answer count at exactly one per received frame
/// is what lets the Entrypoint stay synchronous even when a peer sends a
/// malformed event.
///
/// Returns true when the reply was sent. Returns false when the write failed,
/// which means the channel is gone and the listener should stop.
fn respondInvalidEvent(fd: std.os.linux.fd_t, request_json: []const u8) bool {
    Ipc.sendInvalidEventResponse(fd, request_json) catch |err| {
        Log.logLine(
            "[zorcerer] event listener: sending the invalid-event reply failed: {s}\n",
            .{@errorName(err)},
        );
        return false;
    };
    return true;
}
