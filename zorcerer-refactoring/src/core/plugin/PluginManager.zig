const std = @import("std");
const Ipc = @import("../Ipc.zig");
const root = @import("zroot");
const abi = root.abi;
const Log = root.io.Log;
const PluginConfiguration = @import("plugin-configuration").PluginConfiguration;
const PluginDependency = @import("PluginDependency.zig");
const PluginLibrary = @import("plugin-library");
const FileService = @import("../FileService.zig");
const NetworkService = @import("../NetworkService.zig");
const LuaHost = @import("../LuaHost.zig");
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

/// Policy used for a Lua script whose directory has no valid manifest.
///
/// Scripts are discovered independently of manifests, so a directory without
/// one still runs; its network access is deny-by-default.
const default_network_policy: PluginConfiguration.NetworkPolicy = .{};

/// One plugin .so held in the manager's cache.
pub const Plugin = struct {
    /// Position of this plugin in the manager's lifecycle. Creation and
    /// initialization are separate phases; only an `initialized` plugin has
    /// had its load() hook called and must have unload() called.
    pub const State = enum {
        /// The library is open and the context exists, but load() has not
        /// run yet. Instances can stay in this state when a fatal error
        /// aborts the scan before the initialization pass.
        created,
        /// load() returned zero; the plugin participates in the runtime and
        /// its unload() must run.
        initialized,
        /// load() returned nonzero, or a dependency prevented
        /// initialization. The library and context are still owned by the
        /// manager until unloadAll(), but unload() is skipped.
        failed,
    };

    /// Path the library was opened with (joined from plugins_directory and
    /// the manifest's library path). Owned by the manager.
    path: []const u8,
    /// Open library with its resolved `load`/`unload` exports.
    library: PluginLibrary.Library,
    /// ABI context handed to load()/unload(). Owned by the manager; its
    /// `Text` fields borrow `manifest_result`.
    context: *abi.PluginContext,
    /// Filesystem context of this plugin, also referenced by
    /// `context.files`. Owned by the manager and destroyed after `unload()`
    /// returns. Null only for records built outside `loadPlugins()`.
    files: ?*FileService.PluginFiles = null,
    /// Network context of this plugin, also referenced by
    /// `context.network`. Owned by the manager and destroyed after
    /// `unload()` returns. Null only for records built outside
    /// `loadPlugins()`.
    network: ?*NetworkService.PluginNetwork = null,
    /// Current lifecycle state; see `State`.
    state: State = .created,
};

/// Bookkeeping entry for one plugin accepted by the creation pass.
///
/// The initialization pass walks these entries in the same dependency-first
/// order. `plugin_index` addresses the manager's `plugins` list and stays
/// valid because that list is not appended to between the two passes.
const CreatedPlugin = struct {
    /// Index into the validated configurations returned by readConfig().
    configuration_index: usize,
    /// Index into `Manager.plugins`.
    plugin_index: usize,
};

/// One loaded Lua script and the core resources it uses.
///
/// `zlua.Script` owns the Lua state, script strings, and Lua lifecycle. This
/// entry only pairs it with the filesystem context and host context that the
/// manager must release after the script's `on_unload` dispatch. The entry is
/// retained until `unloadAll()`.
const LuaScriptEntry = struct {
    /// Loaded script and its independent Lua state.
    script: zlua.Script,
    /// Filesystem context of this script's directory. Released after the
    /// script's `deinit()`.
    files: *FileService.PluginFiles,
    /// Network context of this script's directory. Released after the
    /// script's `deinit()`.
    network: *NetworkService.PluginNetwork,
    /// Host callback context borrowed by the script runtime.
    host: *LuaHost.Context,
    /// Owned copy of the script's directory name, used as its plugin id.
    /// Freed in `unloadAll()` after the script shuts down.
    plugin_id: []u8,
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
    /// The plugin's dynamic library was opened and its context was created.
    /// The instance remains cached until `unloadAll()`; initialization, and
    /// therefore the `load()` hook, happens afterwards.
    ///
    /// The carried context is owned by the manager and stays valid until the
    /// plugin is unloaded.
    instance_created: struct {
        /// Id of the plugin whose instance was created.
        plugin_id: []const u8,
        /// Library path the manager opened for this plugin.
        path: []const u8,
        /// Context that initialization will hand to `load()`.
        context: *const abi.PluginContext,
    },
    /// The manager is about to call the plugin's `load()` hook.
    initialization_started: struct {
        /// Id of the plugin being initialized.
        plugin_id: []const u8,
        /// Library path the manager opened for this plugin.
        path: []const u8,
    },
    /// The plugin's `load()` hook returned zero. The plugin is ready for the
    /// runtime and its `unload()` must run on teardown.
    initialization_finished: struct {
        /// Id of the initialized plugin.
        plugin_id: []const u8,
        /// Library path the manager opened for this plugin.
        path: []const u8,
        /// Context handed to `load()` and reserved for `unload()`.
        context: *const abi.PluginContext,
    },
    /// Every accepted plugin has finished its initialization pass, so the
    /// manager is entering the runtime phase. Emitted once per successful
    /// loadPlugins() call.
    runtime_entered,
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
/// `main.lua` (see zlua.Script) and its plugin libraries (see plugins_directory
/// and Plugin), resolves the native plugins' dependency graph, creates each
/// accepted instance in dependency-first order, then initializes them by
/// calling their load(). After the initialization pass it enters the runtime
/// phase; unloadAll() reverses that for every initialized plugin, then
/// releases the cache. Plugins only ever talk to the host through
/// src/core/plugin/PluginContext.zig,
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

    /// The child's end of the IPC channel to the engine process, captured by
    /// setIpcLogger(). Null means game queries, `game://` filesystem access,
    /// and client messages are unavailable.
    ipc_fd: ?std.os.linux.fd_t = null,

    /// Whether a `clientCommand` event is currently being dispatched. Set by
    /// `listenForEvents` around the fan-out so `zostd.client_print()` can
    /// reject calls made outside a client command.
    client_command_active: bool = false,

    /// Per-plugin filesystem service, created by `loadPlugins()` and
    /// destroyed by `deinit()`.
    ///
    /// Heap-allocated so every `PluginFiles` it hands out keeps a stable
    /// service pointer when the manager value moves.
    file_service: ?*FileService.Service = null,

    /// Per-plugin outbound network service, created by `loadPlugins()` and
    /// destroyed by `deinit()`. Heap-allocated so every `PluginNetwork` it
    /// hands out keeps a stable service pointer when the manager value moves.
    network_service: ?*NetworkService.Service = null,

    /// ABI table handed to plugins through `PluginContext.game` when
    /// `ipc_fd` is set. `context` is filled with this manager's address in
    /// `buildContext()`.
    game_api: abi.GameApi = .{
        .struct_size = @sizeOf(abi.GameApi),
        .context = null,
        .server_info = gameServerInfo,
        .player_info = gamePlayerInfo,
        .entity_info = gameEntityInfo,
        .server_cvar = gameServerCvar,
        .client_cvar = gameClientCvar,
    },

    /// Optional in-process observer for manager lifecycle events.
    /// When null, events are logged through the manager's logger.
    manager_listener: ?ManagerListener = null,

    /// Cached plugin libraries: filled by loadPlugins(), emptied and
    /// released by unloadAll().
    plugins: std.ArrayList(Plugin) = .empty,

    /// Lua scripts loaded directly by the manager: filled by loadPlugins(),
    /// emptied and released by unloadAll().
    lua_scripts: std.ArrayList(LuaScriptEntry) = .empty,

    pub fn init() @This() {
        return .{};
    }

    /// Unloads every plugin remembered by loadPlugins() and frees all
    /// validated manifests retained by the manager.
    /// This can be called with defer.
    pub fn deinit(self: *@This()) void {
        self.unloadAll();
        if (self.file_service) |service| {
            service.deinit();
            self.allocator.destroy(service);
            self.file_service = null;
        }
        if (self.network_service) |service| {
            service.deinit();
            self.network_service = null;
        }
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
        self.ipc_fd = fd;
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
    /// The returned value borrows `configuration` (for its identity strings),
    /// `self.logger`, `files`, and `network`. All must outlive the plugin's
    /// loaded lifetime; the caller stores the context on the heap so its
    /// address stays stable. `configuration.path` must be non-null, which
    /// holds because only native configurations reach `createPlugin()`.
    fn buildContext(
        self: *@This(),
        configuration: *const PluginConfiguration,
        files: *FileService.PluginFiles,
        network: *NetworkService.PluginNetwork,
    ) abi.PluginContext {
        self.game_api.context = self;
        return .{
            .abi_version = abi.abi_version,
            .struct_size = @sizeOf(abi.PluginContext),
            .logger = if (self.logger) |*logger| logger else null,
            .plugin = .{
                .id = abi.Text.fromSlice(configuration.id),
                .name = abi.Text.fromSlice(configuration.name),
                .version = abi.Text.fromSlice(configuration.version),
                .author = abi.Text.fromSlice(configuration.author),
                .library_path = abi.Text.fromSlice(configuration.path orelse ""),
            },
            .game = if (self.ipc_fd != null) &self.game_api else null,
            .files = &files.api,
            .network = &network.api,
        };
    }

    /// Loads every plugin discovered under plugins_directory.
    ///
    /// First, each directory's `main.lua` is loaded into its own ZLua
    /// runtime; Lua scripts do not require a manifest. Then every manifest
    /// is read and validated through readConfig(), the native dependency
    /// graph is resolved, and each accepted plugin passes through two
    /// dependency-first phases: creation (open the manifest's `path`, resolve
    /// its `load()`/`unload()` exports, build the per-plugin context) and
    /// initialization (call `load(ctx)`).
    ///
    /// After every accepted plugin has been initialized, the manager emits
    /// `runtime_entered` and dispatches `on_runtime_entered` to loaded Lua
    /// scripts.
    ///
    /// Manifests that fail validation are logged and skipped for native
    /// plugins. Plugins with a missing dependency, a version mismatch, a
    /// dependency cycle, a dependency that failed to create or initialize,
    /// or a rejected dynamic library are reported through the ManagerListener
    /// (or the log when no listener is installed) and skipped together with
    /// their transitive dependents. Other plugins are still loaded.
    /// Everything cached until then is unloaded on the way out if a fatal
    /// error aborts the scan.
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
        if (self.file_service == null) {
            const service = try self.allocator.create(FileService.Service);
            service.* = FileService.Service.init(
                self.allocator,
                io,
                self.ipc_fd,
                plugins_directory,
            ) catch |err| {
                self.allocator.destroy(service);
                return err;
            };
            self.file_service = service;
        }
        if (self.network_service == null) {
            self.network_service = try NetworkService.Service.init(self.allocator);
        }

        var plugin_root = try std.Io.Dir.cwd().openDir(io, plugins_directory, .{ .iterate = true });
        defer plugin_root.close(io);

        // Only directories with a valid manifest participate in native
        // plugin loading. readConfig() logs and skips every rejected
        // manifest, so failures here are per-plugin, not fatal.
        const configurations = try self.readConfig();

        // Lua scripts are independent of the native plugin ABI and do not
        // need a manifest. A directory may contain both a script and
        // managed .so plugins; when it has a valid manifest, that manifest's
        // `[network]` policy applies to its script as well.
        var script_policies = std.StringHashMap(*const PluginConfiguration.NetworkPolicy)
            .init(self.allocator);
        defer script_policies.deinit();
        for (configurations) |*configuration| {
            try script_policies.put(configuration.id, &configuration.network);
        }

        var dirs = plugin_root.iterate();
        while (try dirs.next(io)) |dir| {
            if (dir.kind != .directory) continue;
            const policy = script_policies.get(dir.name) orelse &default_network_policy;
            self.loadLuaScript(dir.name, policy);
        }

        // Script-only manifests are valid configurations but do not take part
        // in native dependency resolution or dlopen().
        var native_configs: std.ArrayList(PluginConfiguration) = .empty;
        defer native_configs.deinit(self.allocator);
        for (configurations) |configuration| {
            if (!configuration.isNative()) continue;
            try native_configs.append(self.allocator, configuration);
        }

        var resolution = try PluginDependency.resolve(self.allocator, native_configs.items);
        defer resolution.deinit(self.allocator);

        // Ids that must not satisfy dependents: statically rejected plugins,
        // plugins whose library could not be created, and plugins whose
        // initialization failed.
        var unavailable = std.StringHashMap(void).init(self.allocator);
        defer unavailable.deinit();

        // Static graph failures are known before any dynamic library is
        // opened, so report them first, in manifest order.
        for (resolution.rejected) |rejection| {
            const configuration = native_configs.items[rejection.plugin_index];
            self.notifyManagerEvent(.{ .dependency_rejected = .{
                .plugin_id = configuration.id,
                .rejection = rejection,
            } });
            try unavailable.put(configuration.id, {});
        }

        // Creation pass: open every accepted library and build its instance
        // in dependency-first order. load() is deliberately not called yet;
        // initialization is a separate phase so a creation failure and an
        // initialization failure remain distinguishable.
        var created: std.ArrayList(CreatedPlugin) = .empty;
        defer created.deinit(self.allocator);

        for (resolution.order) |configuration_index| {
            const configuration = native_configs.items[configuration_index];

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

            const plugin_index = try self.createPlugin(&configuration);
            if (plugin_index) |index| {
                try created.append(self.allocator, .{
                    .configuration_index = configuration_index,
                    .plugin_index = index,
                });
            } else {
                try unavailable.put(configuration.id, {});
            }
        }

        // Initialization pass: call each created plugin's load() in the same
        // dependency-first order. A failure here is reported after creation
        // and makes the plugin unavailable to its dependents.
        for (created.items) |entry| {
            const configuration = native_configs.items[entry.configuration_index];
            const plugin = &self.plugins.items[entry.plugin_index];

            var failed_dependency: ?[]const u8 = null;
            for (configuration.dependencies) |dependency| {
                if (unavailable.contains(dependency.id)) {
                    failed_dependency = dependency.id;
                    break;
                }
            }
            if (failed_dependency) |dependency_id| {
                plugin.state = .failed;
                self.notifyManagerEvent(.{ .dependency_rejected = .{
                    .plugin_id = configuration.id,
                    .rejection = .{
                        .plugin_index = entry.configuration_index,
                        .reason = .dependency_rejected,
                        .dependency_id = dependency_id,
                    },
                } });
                try unavailable.put(configuration.id, {});
                continue;
            }

            if (!self.initializePlugin(plugin)) {
                try unavailable.put(configuration.id, {});
            }
        }

        self.notifyManagerEvent(.runtime_entered);
        self.dispatchToLua("on_runtime_entered", null);
    }

    /// Opens one plugin's manifest library, builds its context, and adds the
    /// inactive instance to the cache.
    ///
    /// Only `configuration.path` is opened; other `.so` files in the same
    /// directory are ignored. A library that cannot be opened or lacks the
    /// required exports is reported through a `library_rejected` event and
    /// leaves no cached state. On success the instance starts in
    /// `.created`; its `load()` hook is run later by `initializePlugin()`.
    ///
    /// Returns the new plugin's index in `plugins`, or null when the library
    /// was rejected and nothing was cached.
    ///
    /// Errors: `error.OutOfMemory` when path construction, context
    /// allocation, or caching fails.
    fn createPlugin(self: *@This(), configuration: *const PluginConfiguration) !?usize {
        const path = try std.Io.Dir.path.join(
            self.allocator,
            &.{ plugins_directory, configuration.id, configuration.path.? },
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
                return null;
            },
            .loaded => |loaded| {
                var library = loaded;
                var library_owned = true;
                defer if (library_owned) library.close();

                const service = self.file_service orelse return error.FilesystemUnavailable;
                const files = try service.createPluginFiles(configuration.id);
                var files_owned = true;
                defer if (files_owned) service.destroyPluginFiles(files);

                const network_service = self.network_service orelse
                    return error.NetworkUnavailable;
                const network = try network_service.createPluginNetwork(&configuration.network);
                var network_owned = true;
                defer if (network_owned) network_service.destroyPluginNetwork(network);

                const context = try self.allocator.create(abi.PluginContext);
                var context_owned = true;
                defer if (context_owned) self.allocator.destroy(context);
                context.* = self.buildContext(configuration, files, network);

                const plugin_index = self.plugins.items.len;
                try self.plugins.append(self.allocator, .{
                    .path = path,
                    .library = library,
                    .context = context,
                    .files = files,
                    .network = network,
                });
                path_owned = true;
                library_owned = false;
                context_owned = false;
                files_owned = false;
                network_owned = false;

                self.notifyManagerEvent(.{ .instance_created = .{
                    .plugin_id = context.plugin.id.slice(),
                    .path = path,
                    .context = context,
                } });
                return plugin_index;
            },
        }
    }

    /// Runs one plugin's initialization phase by calling its load() hook.
    ///
    /// Returns true when the plugin returned zero and reached `.initialized`.
    /// A nonzero status leaves it `.failed` so unloadAll() skips its unload()
    /// hook but still closes the library and frees the context. The failure
    /// is reported as `.invalid_configuration`, the closest structured
    /// category for a plugin that rejects the host or cannot initialize.
    fn initializePlugin(self: *@This(), plugin: *Plugin) bool {
        self.notifyManagerEvent(.{ .initialization_started = .{
            .plugin_id = plugin.context.plugin.id.slice(),
            .path = plugin.path,
        } });

        const status = plugin.library.load(plugin.context);
        if (status != 0) {
            plugin.state = .failed;
            self.notifyManagerEvent(.{ .library_rejected = .{
                .plugin_id = plugin.context.plugin.id.slice(),
                .path = plugin.path,
                .reason = .invalid_configuration,
            } });
            return false;
        }

        plugin.state = .initialized;
        self.notifyManagerEvent(.{ .initialization_finished = .{
            .plugin_id = plugin.context.plugin.id.slice(),
            .path = plugin.path,
            .context = plugin.context,
        } });
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
            .instance_created => |created| {
                Log.logLine(
                    "[zorcerer] {s}: instance created ({s})\n",
                    .{ created.plugin_id, created.path },
                );
            },
            .initialization_started => |started| {
                Log.logLine(
                    "[zorcerer] {s}: initializing ({s})\n",
                    .{ started.plugin_id, started.path },
                );
            },
            .initialization_finished => |finished| {
                Log.logLine(
                    "[zorcerer] {s}: initialized\n",
                    .{finished.plugin_id},
                );
            },
            .runtime_entered => {
                Log.logLine("[zorcerer] initialization complete, entering runtime\n", .{});
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

    /// Runs every initialized native plugin's unload() in reverse load order
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

            if (plugin.state == .initialized) {
                const status = plugin.library.unload(plugin.context);
                if (status != 0) {
                    Log.logLine("[zorcerer] {s}: unload() returned {d}\n", .{ plugin.path, status });
                }
            }

            plugin.library.close();
            if (plugin.files) |files| {
                if (self.file_service) |service| service.destroyPluginFiles(files);
                plugin.files = null;
            }
            self.allocator.destroy(plugin.context);
            if (plugin.network) |network| {
                if (self.network_service) |service| service.destroyPluginNetwork(network);
                plugin.network = null;
            }
            self.allocator.free(plugin.path);
        }

        self.plugins.clearRetainingCapacity();

        var remaining_scripts = self.lua_scripts.items.len;
        while (remaining_scripts > 0) {
            remaining_scripts -= 1;
            const entry = &self.lua_scripts.items[remaining_scripts];

            // `deinit()` dispatches `on_unload` before closing the state, so
            // the script can still use its host callbacks and files.
            entry.script.deinit();
            if (self.file_service) |service| service.destroyPluginFiles(entry.files);
            if (self.network_service) |service| service.destroyPluginNetwork(entry.network);
            self.allocator.destroy(entry.host);
            self.allocator.free(entry.plugin_id);
        }

        self.lua_scripts.clearRetainingCapacity();
    }

    /// Loads `<plugins_directory>/<dir_name>/main.lua` through `zlua.Script`.
    ///
    /// A missing script leaves the manager unchanged. `zlua.Script` owns
    /// discovery, runtime setup, `on_load`, and diagnostics; this function
    /// only creates the core resources the script's host callbacks need and
    /// retains them for `unloadAll()`.
    fn loadLuaScript(
        self: *@This(),
        dir_name: []const u8,
        policy: *const PluginConfiguration.NetworkPolicy,
    ) void {
        const service = self.file_service orelse {
            Log.logLine(
                "[zlua] {s}/{s}/main.lua: filesystem service is not initialized, script skipped\n",
                .{ plugins_directory, dir_name },
            );
            return;
        };
        const network_service = self.network_service orelse {
            Log.logLine(
                "[zlua] {s}/{s}/main.lua: network service is not initialized, script skipped\n",
                .{ plugins_directory, dir_name },
            );
            return;
        };

        const files = service.createPluginFiles(dir_name) catch |err| {
            Log.logLine(
                "[zlua] {s}/{s}/main.lua: could not create filesystem context ({s}), script skipped\n",
                .{ plugins_directory, dir_name, @errorName(err) },
            );
            return;
        };
        var files_alive = true;
        defer if (files_alive) service.destroyPluginFiles(files);

        const network = network_service.createPluginNetwork(policy) catch |err| {
            Log.logLine(
                "[zlua] {s}/{s}/main.lua: could not create network context ({s}), script skipped\n",
                .{ plugins_directory, dir_name, @errorName(err) },
            );
            return;
        };
        var network_alive = true;
        defer if (network_alive) network_service.destroyPluginNetwork(network);

        const host_context = self.allocator.create(LuaHost.Context) catch |err| {
            Log.logLine(
                "[zlua] {s}/{s}/main.lua: could not create host context ({s}), script skipped\n",
                .{ plugins_directory, dir_name, @errorName(err) },
            );
            return;
        };
        var host_alive = true;
        defer if (host_alive) self.allocator.destroy(host_context);

        // The iterator reuses its name buffer on the next entry, so the id the
        // script keeps for audit logging must be copied.
        const plugin_id = self.allocator.dupe(u8, dir_name) catch |err| {
            Log.logLine(
                "[zlua] {s}/{s}/main.lua: could not store plugin id ({s}), script skipped\n",
                .{ plugins_directory, dir_name, @errorName(err) },
            );
            return;
        };
        var plugin_id_alive = true;
        defer if (plugin_id_alive) self.allocator.free(plugin_id);

        host_context.* = .{
            .manager = self,
            .files = files,
            .network = network,
            .plugin_id = plugin_id,
        };

        var script = zlua.Script.load(
            self.allocator,
            self.threaded_io.io(),
            .{
                .plugins_directory = plugins_directory,
                .directory_name = dir_name,
                .host = LuaHost.host(host_context),
            },
        ) catch return;
        var script_alive = true;
        defer if (script_alive) script.deinit();

        self.lua_scripts.append(self.allocator, .{
            .script = script,
            .files = files,
            .network = network,
            .host = host_context,
            .plugin_id = plugin_id,
        }) catch |err| {
            Log.logLine(
                "[zlua] {s}: could not retain script ({s}), script skipped\n",
                .{ script.path(), @errorName(err) },
            );
            return;
        };

        script_alive = false;
        files_alive = false;
        network_alive = false;
        host_alive = false;
        plugin_id_alive = false;
    }

    /// Delivers one engine event to every loaded Lua script and every
    /// initialized native plugin.
    ///
    /// `event` is the `Ipc.Event` method name, for example `"pause"`.
    /// `payload` is optional JSON text; Lua receives it as the callback's
    /// second argument and native plugins receive it in `abi.Event`.
    ///
    /// Lua dispatch isolates and logs callback failures, so one script cannot
    /// stop delivery to the rest. Native dispatch runs in load order and stops
    /// early only when a plugin returns something other than
    /// `abi.plugin_continue`; that matches Source's `PLUGIN_STOP` convention
    /// within the plugin fan-out and cannot cancel the engine action.
    pub fn dispatchEvent(self: *@This(), event: []const u8, payload: ?[]const u8) void {
        self.dispatchToLua(event, payload);
        self.dispatchToPlugins(event, payload);
    }

    /// Delivers one event to every loaded Lua script.
    fn dispatchToLua(self: *@This(), event: []const u8, payload: ?[]const u8) void {
        for (self.lua_scripts.items) |*entry| {
            entry.script.dispatchEvent(event, payload);
        }
    }

    /// Delivers one event to every initialized native plugin that resolved an
    /// `onEvent` export.
    fn dispatchToPlugins(self: *@This(), event: []const u8, payload: ?[]const u8) void {
        dispatchEventToPlugins(self.plugins.items, event, payload);
    }

    /// Sends one query over the IPC channel and returns the result document.
    ///
    /// The returned text is allocated with the manager's allocator and owned
    /// by the caller. The exchange is synchronous: the parent answers while it
    /// is already waiting for readiness or an event response.
    ///
    /// Errors: `error.QueryUnavailable` when no IPC channel is configured,
    /// plus the framing, JSON, and response errors of `Ipc.sendQuery` and
    /// `Ipc.receiveQueryResult`.
    fn fetchQuery(self: *@This(), request: Ipc.QueryRequest) ![]u8 {
        const fd = self.ipc_fd orelse return error.QueryUnavailable;
        try Ipc.sendQuery(fd, request);
        return Ipc.receiveQueryResult(fd, self.allocator);
    }

    /// Sends one command to the engine process and waits for its acceptance.
    ///
    /// `plugin_id` is advisory attribution for the Entrypoint's audit log. The
    /// command is validated locally first, then validated again by the
    /// Entrypoint, which is the actual trust boundary.
    ///
    /// Errors: `Ipc.CommandError` when the text is empty, too long, contains a
    /// NUL byte, or spans multiple lines; `error.CommandUnavailable` when no
    /// IPC channel is configured; `error.CommandRejected` when the parent did
    /// not accept the command; plus the framing, JSON, and response errors of
    /// `Ipc.sendServerCommand` and `Ipc.receiveServerCommandResult`.
    pub fn executeServerCommand(
        self: *@This(),
        plugin_id: []const u8,
        command: []const u8,
    ) !void {
        try Ipc.validateCommand(command);
        const fd = self.ipc_fd orelse return error.CommandUnavailable;
        try Ipc.sendServerCommand(fd, .{
            .command = command,
            .plugin_id = plugin_id,
        });
        const result = try Ipc.receiveServerCommandResult(fd, self.allocator);
        if (!result.accepted) return error.CommandRejected;
    }

    /// Marks the start of one `clientCommand` fan-out.
    ///
    /// The manager brackets event dispatch with this method and
    /// `endClientCommand()` so Lua's `zostd.client_print()` can only target the
    /// client whose command is being handled.
    pub fn beginClientCommand(self: *@This()) void {
        self.client_command_active = true;
    }

    /// Marks the end of one `clientCommand` fan-out.
    ///
    /// After this returns, `zostd.client_print()` fails until the next
    /// `clientCommand` event.
    pub fn endClientCommand(self: *@This()) void {
        self.client_command_active = false;
    }

    /// Sends one console message to the client whose `clientCommand` is being
    /// handled and waits for the engine's acknowledgement.
    ///
    /// `plugin_id` is advisory attribution for the Entrypoint's audit log. The
    /// message is validated locally first, then validated again by the
    /// Entrypoint, which is the actual trust boundary.
    ///
    /// Errors: `error.NoActiveClientCommand` when called outside a
    /// `clientCommand` event; `Ipc.ClientPrintError` when the text is empty,
    /// too long, contains a NUL byte, or spans multiple lines;
    /// `error.ClientPrintUnavailable` when no IPC channel is configured;
    /// `error.ClientPrintRejected` when the parent did not print the message;
    /// plus the framing, JSON, and response errors of `Ipc.sendClientPrint`
    /// and `Ipc.receiveClientPrintResult`.
    pub fn executeClientPrint(
        self: *@This(),
        plugin_id: []const u8,
        message: []const u8,
    ) !void {
        if (!self.client_command_active) return error.NoActiveClientCommand;
        try Ipc.validateClientPrint(message);
        const fd = self.ipc_fd orelse return error.ClientPrintUnavailable;
        try Ipc.sendClientPrint(fd, .{
            .message = message,
            .plugin_id = plugin_id,
        });
        const result = try Ipc.receiveClientPrintResult(fd, self.allocator);
        if (!result.printed) return error.ClientPrintRejected;
    }

    /// Translates a query failure into an ABI status.
    fn queryStatus(err: anyerror) c_int {
        return switch (err) {
            error.QueryUnavailable => abi.query_unavailable,
            else => abi.query_transport_error,
        };
    }

    /// Executes the `server_info` query into `out`.
    ///
    /// Public so the Lua host adapter can answer `zostd.game.server_info()`.
    pub fn queryServerInfo(self: *@This(), out: *abi.ServerInfo) c_int {
        const text = self.fetchQuery(.{ .query = .server_info }) catch |err|
            return queryStatus(err);
        defer self.allocator.free(text);

        var parsed = std.json.parseFromSlice(
            Ipc.ServerInfo,
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
    pub fn queryPlayerInfo(self: *@This(), index: c_int, out: *abi.PlayerInfo) c_int {
        const text = self.fetchQuery(.{ .query = .player_info, .index = index }) catch |err|
            return queryStatus(err);
        defer self.allocator.free(text);

        var parsed = std.json.parseFromSlice(
            Ipc.PlayerInfo,
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
    pub fn queryEntityInfo(self: *@This(), index: c_int, out: *abi.EntityInfo) c_int {
        const text = self.fetchQuery(.{ .query = .entity_exists, .index = index }) catch |err|
            return queryStatus(err);
        defer self.allocator.free(text);

        var parsed = std.json.parseFromSlice(
            Ipc.EntityInfo,
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
    pub fn queryServerCvar(self: *@This(), name: []const u8, out: *abi.CvarValue) c_int {
        const text = self.fetchQuery(.{ .query = .server_cvar, .name = name }) catch |err|
            return queryStatus(err);
        defer self.allocator.free(text);

        var parsed = std.json.parseFromSlice(
            Ipc.CvarValue,
            self.allocator,
            text,
            .{},
        ) catch return abi.query_transport_error;
        defer parsed.deinit();

        return fillCvarValue(parsed.value, out);
    }

    /// Executes the `client_cvar` query for client `index` into `out`.
    pub fn queryClientCvar(
        self: *@This(),
        index: c_int,
        name: []const u8,
        out: *abi.CvarValue,
    ) c_int {
        const text = self.fetchQuery(.{
            .query = .client_cvar,
            .index = index,
            .name = name,
        }) catch |err| return queryStatus(err);
        defer self.allocator.free(text);

        var parsed = std.json.parseFromSlice(
            Ipc.CvarValue,
            self.allocator,
            text,
            .{},
        ) catch return abi.query_transport_error;
        defer parsed.deinit();

        return fillCvarValue(parsed.value, out);
    }
};

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
fn fillCvarValue(value: Ipc.CvarValue, out: *abi.CvarValue) c_int {
    out.* = std.mem.zeroes(abi.CvarValue);
    out.struct_size = @sizeOf(abi.CvarValue);
    out.found = @intFromBool(value.found);
    out.int_value = value.int_value;
    out.float_value = value.float_value;

    const text = storeText(&out.text, value.text);
    out.text_len = text.len;
    return if (text.truncated) abi.query_truncated else abi.query_ok;
}

/// `GameApi.server_info` implementation handed to native plugins.
fn gameServerInfo(context: ?*anyopaque, out: *abi.ServerInfo) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(context orelse return abi.query_unavailable));
    if (out.struct_size < @sizeOf(abi.ServerInfo)) return abi.query_unavailable;
    return self.queryServerInfo(out);
}

/// `GameApi.player_info` implementation handed to native plugins.
fn gamePlayerInfo(
    context: ?*anyopaque,
    index: c_int,
    out: *abi.PlayerInfo,
) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(context orelse return abi.query_unavailable));
    if (out.struct_size < @sizeOf(abi.PlayerInfo)) return abi.query_unavailable;
    return self.queryPlayerInfo(index, out);
}

/// `GameApi.entity_info` implementation handed to native plugins.
fn gameEntityInfo(
    context: ?*anyopaque,
    index: c_int,
    out: *abi.EntityInfo,
) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(context orelse return abi.query_unavailable));
    if (out.struct_size < @sizeOf(abi.EntityInfo)) return abi.query_unavailable;
    return self.queryEntityInfo(index, out);
}

/// `GameApi.server_cvar` implementation handed to native plugins.
fn gameServerCvar(
    context: ?*anyopaque,
    name: abi.Text,
    out: *abi.CvarValue,
) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(context orelse return abi.query_unavailable));
    if (out.struct_size < @sizeOf(abi.CvarValue)) return abi.query_unavailable;
    return self.queryServerCvar(name.slice(), out);
}

/// `GameApi.client_cvar` implementation handed to native plugins.
fn gameClientCvar(
    context: ?*anyopaque,
    index: c_int,
    name: abi.Text,
    out: *abi.CvarValue,
) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(context orelse return abi.query_unavailable));
    if (out.struct_size < @sizeOf(abi.CvarValue)) return abi.query_unavailable;
    return self.queryClientCvar(index, name.slice(), out);
}

/// Delivers one event to the initialized plugins in `plugins`, in slice order.
///
/// The event and its texts are stack values that stay valid for the whole
/// fan-out; plugins must not retain them. Delivery stops at the first plugin
/// whose return value differs from `abi.plugin_continue`, matching Source's
/// `PLUGIN_STOP` convention within the plugin fan-out.
fn dispatchEventToPlugins(plugins: []Plugin, event: []const u8, payload: ?[]const u8) void {
    const native_event = abi.Event{
        .struct_size = @sizeOf(abi.Event),
        .name = abi.Text.fromSlice(event),
        .payload = abi.Text.fromSlice(payload orelse ""),
    };

    for (plugins) |*plugin| {
        if (plugin.state != .initialized) continue;
        const on_event = plugin.library.on_event orelse continue;

        const status = on_event(plugin.context, &native_event);
        if (status == abi.plugin_continue) continue;

        Log.logLine(
            "[zorcerer] {s}: onEvent({s}) returned {d}; stopping delivery\n",
            .{ plugin.context.plugin.id.slice(), event, status },
        );
        return;
    }
}

/// Manager whose Lua scripts receive IPC events.
///
/// `loadPlugins()` sets this to the manager that owns the loaded scripts and
/// `deinit()` clears it. The listener is a free function without a manager
/// parameter, so it reaches the manager through this process-global pointer.
/// The manager is single-threaded and lives in the forked child for the whole
/// lifetime of the listener.
var event_manager: ?*Manager = null;

/// Serves the Entrypoint's callback events on the manager's end of the IPC
/// channel until the Entrypoint requests shutdown or closes it.
///
/// The channel is the socket pair created for the fork; after the fork, the
/// manager process owns this end and turns it into its JSON listener. The
/// Entrypoint holds the other end.
///
/// Each received frame must carry a JSON-RPC request whose method is one of
/// `Ipc.Event`'s callbacks, for example `{"jsonrpc":"2.0","method":"pause",
/// "id":1}`. Every valid event is delivered to the loaded Lua scripts and
/// initialized native plugins before any response is sent. Every request
/// carrying an ID is answered with exactly one JSON-RPC result or error
/// response carrying that ID, so the Entrypoint's synchronous event exchange
/// never waits for a reply that will not come.
/// Notifications (requests without an ID) are served without a response,
/// as JSON-RPC requires. A message that cannot be decoded is answered with a
/// JSON-RPC error and the message "Event is invalid".
///
/// The `shutdown` method (`Ipc.shutdown_method`) unloads every plugin before
/// the reply is sent, so plugin `unload()` hooks keep access to the
/// filesystem service and to the engine process over the still-open channel.
/// The listener returns after that reply.
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

        if (Ipc.parseShutdown(std.heap.page_allocator, frame.text())) |shutdown| {
            defer shutdown.deinit();
            const request_id = shutdown.id();

            if (event_manager) |manager| manager.unloadAll();

            if (!request_id.isNotification()) {
                Ipc.sendResultResponse(fd, request_id, "\"OK\"") catch |err| {
                    Log.logLine(
                        "[zorcerer] event listener: replying to shutdown failed: {s}\n",
                        .{@errorName(err)},
                    );
                    return;
                };
            }
            return;
        } else |err| switch (err) {
            error.UnknownMethod, error.NotRpcRequest => {},
            else => {
                Log.logLine(
                    "[zorcerer] event listener: invalid shutdown request ({s})\n",
                    .{@errorName(err)},
                );
                if (!respondInvalidEvent(fd, frame.text())) return;
                continue;
            },
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
            const is_client_command = parsed.value.event == .clientCommand;
            if (is_client_command) manager.beginClientCommand();
            manager.dispatchEvent(@tagName(parsed.value.event), parsed.value.payload);
            if (is_client_command) manager.endClientCommand();
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

// --- Tests -------------------------------------------------------------------

/// Captures the manager events a test cares about. Borrowed payloads are
/// inspected inside the callback and only stable values are retained.
const TestEventCollector = struct {
    /// Whether `.initialization_started` was observed.
    saw_initialization_started: bool = false,
    /// Whether `.initialization_finished` was observed.
    saw_initialization_finished: bool = false,
    /// Whether `.runtime_entered` was observed.
    saw_runtime_entered: bool = false,
    /// Whether `.library_rejected` with `.invalid_configuration` was observed.
    saw_invalid_configuration: bool = false,
    /// Plugin id carried by the last initialization event.
    plugin_id: []const u8 = "",
    /// Context carried by the last `.initialization_finished` event.
    context: ?*const abi.PluginContext = null,

    /// `ManagerListener.notify` implementation that records the event.
    fn notify(raw_context: ?*anyopaque, event: ManagerEvent) void {
        const self: *@This() = @ptrCast(@alignCast(raw_context.?));
        switch (event) {
            .initialization_started => |started| {
                self.saw_initialization_started = true;
                self.plugin_id = started.plugin_id;
            },
            .initialization_finished => |finished| {
                self.saw_initialization_finished = true;
                self.plugin_id = finished.plugin_id;
                self.context = finished.context;
            },
            .runtime_entered => {
                self.saw_runtime_entered = true;
            },
            .library_rejected => |rejected| {
                if (rejected.reason == .invalid_configuration) {
                    self.saw_invalid_configuration = true;
                }
            },
            else => {},
        }
    }
};

/// Plugin load() that succeeds.
fn testLoadSuccess(_: *abi.PluginContext) callconv(.c) c_int {
    return 0;
}

/// Plugin load() that reports a rejected instance.
fn testLoadFailure(_: *abi.PluginContext) callconv(.c) c_int {
    return 1;
}

/// Plugin unload() used by the fake library.
fn testUnload(_: *abi.PluginContext) callconv(.c) c_int {
    return 0;
}

/// Builds a plugin record whose library exports the test callbacks.
///
/// The handle is never used because the tests call only `load()` through
/// `initializePlugin`.
fn testPlugin(context: *abi.PluginContext, load: abi.LoadFn) Plugin {
    return .{
        .path = "test-plugin.so",
        .library = .{
            .handle = undefined,
            .load = load,
            .unload = testUnload,
            .on_event = null,
        },
        .context = context,
    };
}

/// Builds the minimal context `initializePlugin` needs.
fn testPluginContext() abi.PluginContext {
    return .{
        .abi_version = abi.abi_version,
        .struct_size = @sizeOf(abi.PluginContext),
        .logger = null,
        .plugin = .{
            .id = abi.Text.fromSlice("test-plugin"),
            .name = abi.Text.fromSlice("Test Plugin"),
            .version = abi.Text.fromSlice("1.0.0"),
            .author = abi.Text.fromSlice("Zorcerer"),
            .library_path = abi.Text.fromSlice("test-plugin.so"),
        },
        .game = null,
        .files = null,
        .network = null,
    };
}

test "initializePlugin reports started and finished events on success" {
    var manager = Manager.init();
    defer manager.deinit();

    var collector = TestEventCollector{};
    manager.setManagerListener(.{ .context = &collector, .notify = TestEventCollector.notify });

    var context = testPluginContext();
    var plugin = testPlugin(&context, testLoadSuccess);

    try std.testing.expect(manager.initializePlugin(&plugin));
    try std.testing.expectEqual(Plugin.State.initialized, plugin.state);
    try std.testing.expect(collector.saw_initialization_started);
    try std.testing.expect(collector.saw_initialization_finished);
    try std.testing.expectEqualStrings("test-plugin", collector.plugin_id);
    try std.testing.expect(collector.context == &context);
}

test "initializePlugin reports a failed initialization when load fails" {
    var manager = Manager.init();
    defer manager.deinit();

    var collector = TestEventCollector{};
    manager.setManagerListener(.{ .context = &collector, .notify = TestEventCollector.notify });

    var context = testPluginContext();
    var plugin = testPlugin(&context, testLoadFailure);

    try std.testing.expect(!manager.initializePlugin(&plugin));
    try std.testing.expectEqual(Plugin.State.failed, plugin.state);
    try std.testing.expect(collector.saw_initialization_started);
    try std.testing.expect(!collector.saw_initialization_finished);
    try std.testing.expect(collector.saw_invalid_configuration);
}

test "runtime_entered reaches the manager listener" {
    var manager = Manager.init();
    defer manager.deinit();

    var collector = TestEventCollector{};
    manager.setManagerListener(.{ .context = &collector, .notify = TestEventCollector.notify });

    manager.notifyManagerEvent(.runtime_entered);
    try std.testing.expect(collector.saw_runtime_entered);
}

/// Records the last event handed to a fake plugin callback.
///
/// The borrows are copied immediately because the manager only guarantees
/// them for the duration of the callback.
const TestEventCapture = struct {
    /// Number of callbacks that ran.
    calls: usize = 0,
    /// Copy of the last event name.
    name: [32]u8 = undefined,
    /// Number of valid bytes in `name`.
    name_len: usize = 0,
    /// Copy of the last payload.
    payload: [64]u8 = undefined,
    /// Number of valid bytes in `payload`.
    payload_len: usize = 0,
};

/// Storage for the fake plugin callbacks below; reset by each test that uses
/// them.
var test_event_capture: TestEventCapture = .{};

/// Copies one event into `test_event_capture`, truncating oversized fields.
fn recordTestEvent(event: *const abi.Event) void {
    test_event_capture.calls += 1;

    const name = event.name.slice();
    test_event_capture.name_len = @min(name.len, test_event_capture.name.len);
    @memcpy(
        test_event_capture.name[0..test_event_capture.name_len],
        name[0..test_event_capture.name_len],
    );

    const payload = event.payload.slice();
    test_event_capture.payload_len = @min(payload.len, test_event_capture.payload.len);
    @memcpy(
        test_event_capture.payload[0..test_event_capture.payload_len],
        payload[0..test_event_capture.payload_len],
    );
}

/// Fake plugin `onEvent` that keeps the fan-out going.
fn testOnEventContinue(_: *abi.PluginContext, event: *const abi.Event) callconv(.c) c_int {
    recordTestEvent(event);
    return abi.plugin_continue;
}

/// Fake plugin `onEvent` that stops later plugins from receiving the event.
fn testOnEventStop(_: *abi.PluginContext, event: *const abi.Event) callconv(.c) c_int {
    recordTestEvent(event);
    return abi.plugin_stop;
}

test "dispatchEventToPlugins forwards the event name and payload" {
    test_event_capture = .{};

    var context = testPluginContext();
    var plugin = testPlugin(&context, testLoadSuccess);
    plugin.state = .initialized;
    plugin.library.on_event = testOnEventContinue;

    var plugins = [_]Plugin{plugin};
    dispatchEventToPlugins(&plugins, "levelInit", "{\"map\":\"de_dust2\"}");

    try std.testing.expectEqual(@as(usize, 1), test_event_capture.calls);
    try std.testing.expectEqualStrings(
        "levelInit",
        test_event_capture.name[0..test_event_capture.name_len],
    );
    try std.testing.expectEqualStrings(
        "{\"map\":\"de_dust2\"}",
        test_event_capture.payload[0..test_event_capture.payload_len],
    );
}

test "dispatchEventToPlugins skips plugins that did not initialize" {
    test_event_capture = .{};

    var context = testPluginContext();
    var plugin = testPlugin(&context, testLoadSuccess);
    plugin.state = .created;
    plugin.library.on_event = testOnEventContinue;

    var plugins = [_]Plugin{plugin};
    dispatchEventToPlugins(&plugins, "pause", null);

    try std.testing.expectEqual(@as(usize, 0), test_event_capture.calls);
}

test "dispatchEventToPlugins stops after plugin_stop" {
    test_event_capture = .{};

    var first_context = testPluginContext();
    var first = testPlugin(&first_context, testLoadSuccess);
    first.state = .initialized;
    first.library.on_event = testOnEventStop;

    var second_context = testPluginContext();
    var second = testPlugin(&second_context, testLoadSuccess);
    second.state = .initialized;
    second.library.on_event = testOnEventContinue;

    var plugins = [_]Plugin{ first, second };
    dispatchEventToPlugins(&plugins, "pause", null);

    try std.testing.expectEqual(@as(usize, 1), test_event_capture.calls);
    try std.testing.expectEqualStrings(
        "pause",
        test_event_capture.name[0..test_event_capture.name_len],
    );
}
