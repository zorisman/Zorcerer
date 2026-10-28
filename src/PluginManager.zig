const std = @import("std");
const zjr = @import("zjr");
const Ipc = @import("Ipc.zig");
const toml = @import("toml");
const abi = @import("root.zig").abi;
const Log = @import("root.zig").Log;
const PluginConfiguration = @import("plugin-configuration").PluginConfiguration;

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
/// src/PluginContext.zig, so no plugin-defined code needs direct links into the
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

    /// Builds the HostApi handed to plugin entry points. The returned
    /// value borrows self.logger and is only valid while self lives.
    fn hostApi(self: *@This()) abi.HostApi {
        return .{ .logger = if (self.logger) |*logger| logger else null };
    }

    /// Iterates the directories inside plugins_directory, opens every .so
    /// file directly inside them, looks up the plugin ABI's load()/unload()
    /// exports (src/PluginContext.zig), adds the library into the cache and
    /// calls its load(). Sketchy entities are skipped with a log line
    /// instead of aborting the whole scan; everything cached until then is
    /// unloaded on the way out if a fatal error aborts the scan.
    pub fn loadPlugins(self: *@This()) !void {
        if (self.plugins.items.len != 0) {
            return error.AlreadyLoaded;
        }

        errdefer self.unloadAll();

        // Plugin configurations parsed from each plugin directory's
        // manifest.toml, in filesystem discovery order. The list holds
        // owner-allocated pointers, but their manifest strings are owned by
        // PluginConfiguration.parseConfig()'s internal arena, which stays
        // valid for the process' lifetime.
        // TODO: retain this list on the manager and release it in unloadAll()/
        // deinit(); for now it is only filled so the manifest state is read.
        var managed_plugins: std.ArrayList(*PluginConfiguration) = .empty;

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

            // Plugins that carry a manifest.toml are managed: parse the
            // manifest and remember its configuration. A directory without
            // a readable manifest stays unmanaged and is only picked up
            // through its .so file(s).
            const manifest_name = "manifest.toml";

            const manifest_toml = plugin_dir.readFileAlloc(io, manifest_name, self.allocator, .unlimited) catch {
                Log.logLine("[Zorcerer] Failed to load manifest for {s}, skipping.\n", .{dir.name});
                continue;
            };
            defer self.allocator.free(manifest_toml);

            const configuration = PluginConfiguration.parseConfig(manifest_toml) catch |err| {
                Log.logLine("[zorcerer] {s}/{s}: {s} parse failed ({s}), plugin skipped\n", .{ plugins_directory, dir.name, manifest_name, @errorName(err) });
                continue;
            };

            const configuration_ptr = try self.allocator.create(PluginConfiguration);
            configuration_ptr.* = configuration;

            try managed_plugins.append(self.allocator, configuration_ptr);

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

/// Serves the Entrypoint's JSON-RPC calls on the manager's end of the IPC
/// channel until the Entrypoint closes it.
///
/// The channel is the socket pair created for the fork; after the fork, the
/// manager process owns this end and turns it into its JSON listener. The
/// Entrypoint holds the other end.
///
/// Two kinds of requests are served:
///
///   * VSP callback events, for example `{"jsonrpc":"2.0","method":"pause",
///     "id":1}`. They are answered with the `"Event is X"` result.
///   * The test `serverCommand` engine-call request. Until real plugins exist,
///     this function itself decides that `"zorcerer ping"` must make the
///     Entrypoint execute `echo "Pong!"`.
///
/// Every request carrying an ID is answered with exactly one JSON-RPC result
/// or error response carrying that ID, so the Entrypoint's synchronous
/// exchange never waits for a reply that will not come. Notifications
/// (requests without an ID) are served without a response, as JSON-RPC
/// requires. A message that cannot be decoded is answered with a JSON-RPC
/// error.
///
/// JSON request and response text is printed with `std.debug.print` so the
/// test exchange is visible in the server console.
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

        var parsed = Ipc.parseManagerRequest(std.heap.page_allocator, frame.text()) catch |err| {
            Log.logLine(
                "[zorcerer] event listener: invalid request ({s})\n",
                .{@errorName(err)},
            );
            if (!respondInvalidEvent(fd, frame.text())) return;
            continue;
        };
        defer parsed.deinit();

        const request_id = parsed.id();
        if (request_id.isNotification()) continue;

        switch (parsed) {
            .event => |event| {
                Ipc.sendEventResponse(fd, event.value.event, request_id) catch |err| {
                    Log.logLine(
                        "[zorcerer] event listener: replying to {s} failed: {s}\n",
                        .{ @tagName(event.value.event), @errorName(err) },
                    );
                    return;
                };
            },
            .server_command => |request| {
                std.debug.print("[zorcerer] JSON-RPC request: {s}\n", .{frame.text()});
                if (!serveServerCommandTest(fd, request_id, request.command)) return;
            },
        }
    }
}

/// Console command name the test scenario registers with the engine.
///
/// Source console command names cannot contain whitespace, so the engine
/// looks up `zorcerer` and passes `ping` as its first argument.
pub const test_command_name = "zorcerer";

/// First argument that selects the ping scenario on `test_command_name`.
pub const test_ping_argument = "ping";

/// RCON line the ServerCommand test scenario reacts to.
///
/// Real plugin dispatch will replace this hard-coded decision; the entrypoint
/// uses the same constants so the trigger cannot drift between both processes.
/// The test at the end of this file keeps this literal in sync with the name
/// and argument above.
pub const test_ping_command = "zorcerer ping";

/// Command the Entrypoint executes in response to `test_ping_command`.
pub const test_ping_reply = "echo \"Pong!\"";

/// Returns the command the Entrypoint must execute for a test ServerCommand
/// request, or null when the request is not part of the test scenario.
///
/// Kept separate from the listener so the hard-coded test decision is
/// unit-testable without a socket.
fn testServerCommandReply(command: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, command, test_ping_command)) return test_ping_reply;
    return null;
}

/// Answers one test `serverCommand` request.
///
/// Prints the composed JSON-RPC response with `std.debug.print` and sends it
/// as one frame. Returns false when the channel failed and the listener must
/// stop.
fn serveServerCommandTest(
    fd: std.os.linux.fd_t,
    request_id: zjr.RpcId,
    command: []const u8,
) bool {
    const reply = testServerCommandReply(command) orelse {
        Ipc.sendErrorResponse(
            fd,
            request_id,
            .InvalidParams,
            "unsupported ServerCommand test command",
        ) catch |err| {
            Log.logLine(
                "[zorcerer] event listener: replying to serverCommand failed: {s}\n",
                .{@errorName(err)},
            );
            return false;
        };
        return true;
    };

    const allocator = std.heap.page_allocator;
    const response_json = Ipc.makeServerCommandResponse(allocator, request_id, reply) catch |err| {
        Log.logLine(
            "[zorcerer] event listener: composing the serverCommand reply failed: {s}\n",
            .{@errorName(err)},
        );
        return false;
    };
    defer allocator.free(response_json);

    std.debug.print("[zorcerer] JSON-RPC response: {s}\n", .{response_json});
    Ipc.writeFrame(fd, response_json) catch |err| {
        Log.logLine(
            "[zorcerer] event listener: sending the serverCommand reply failed: {s}\n",
            .{@errorName(err)},
        );
        return false;
    };
    return true;
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

test "the test ServerCommand bridge answers ping with echo" {
    try std.testing.expectEqualStrings(
        test_ping_reply,
        testServerCommandReply(test_ping_command).?,
    );
    try std.testing.expect(testServerCommandReply("something else") == null);
}

test "the test ping command is composed from its name and argument" {
    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &buffer,
        "{s} {s}",
        .{ test_command_name, test_ping_argument },
    );
    try std.testing.expectEqualStrings(test_ping_command, expected);
}
