//! Lifecycle owner for one Lua script loaded by the plugin manager.
//!
//! Script discovery, source reading, runtime setup, chunk loading, and the
//! Lua-visible `on_load`/`on_unload` events all live here. The embedding
//! process only supplies a `zostd.Host` implementation and asks the script to
//! dispatch engine events; it never configures a Lua state directly.
//!
//! A `Script` owns its plugin id, root directory, script path, and runtime.
//! Those slices stay valid until `deinit()` returns. Host callbacks and the
//! host context are borrowed and must outlive the script.

const std = @import("std");
const Runtime = @import("Runtime.zig").Runtime;
const zostd = @import("zostd.zig");

/// Inputs needed to load one `<plugins_directory>/<directory_name>/main.lua`.
pub const LoadOptions = struct {
    /// Directory that contains all plugin directories, for example
    /// `tf/addons/zorcerer/plugins`.
    plugins_directory: []const u8,
    /// Directory name of the script's plugin. Also used as the plugin id.
    directory_name: []const u8,
    /// Host callbacks backing the script's `zostd` functions. The context is
    /// borrowed and must stay valid until the script is destroyed.
    host: zostd.Host = .{},
};

/// One loaded Lua script and its independent Lua state.
pub const Script = struct {
    /// Allocator used for the owned strings and the Lua state.
    allocator: std.mem.Allocator,
    /// Plugin id returned by `zostd.plugin_id()`. Owned by the script.
    id: []u8,
    /// Absolute or caller-relative plugin directory passed to the runtime for
    /// its built-in `plugin://` fallback. Owned by the script.
    root_directory: []u8,
    /// Path of `main.lua`, used in diagnostics. Owned by the script.
    script_path: []u8,
    /// The Lua state and its `zostd` host binding.
    runtime: Runtime,

    /// Reads and loads one script.
    ///
    /// The script directory must already exist. A missing `main.lua` returns
    /// `error.FileNotFound` without logging, matching the manager's discovery
    /// behavior. Other failures are reported through `options.host.log` when
    /// one is configured.
    ///
    /// After the chunk runs successfully, `on_load` is dispatched. The
    /// returned script owns every allocation it made; release it with
    /// `deinit()`.
    ///
    /// Errors: filesystem errors from joining or reading `<directory>/main.lua`,
    /// `error.OutOfMemory`, Lua syntax/runtime errors from `Runtime.run`, and
    /// `error.NameTooLong` when the chunk name does not fit.
    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: LoadOptions,
    ) !Script {
        const script_path = std.Io.Dir.path.join(
            allocator,
            &.{ options.plugins_directory, options.directory_name, "main.lua" },
        ) catch |err| {
            logFailure(
                options.host,
                "{s}/{s}/main.lua: path join failed ({s}), script skipped",
                .{ options.plugins_directory, options.directory_name, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(script_path);

        const source = std.Io.Dir.cwd().readFileAlloc(
            io,
            script_path,
            allocator,
            .unlimited,
        ) catch |err| {
            if (err != error.FileNotFound) {
                logFailure(
                    options.host,
                    "{s}: read failed ({s}), script skipped",
                    .{ script_path, @errorName(err) },
                );
            }
            return err;
        };
        defer allocator.free(source);

        const plugin_id = allocator.dupe(u8, options.directory_name) catch |err| {
            logFailure(
                options.host,
                "{s}: could not duplicate plugin id ({s}), script skipped",
                .{ script_path, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(plugin_id);

        const plugin_root = std.Io.Dir.path.join(
            allocator,
            &.{ options.plugins_directory, options.directory_name },
        ) catch |err| {
            logFailure(
                options.host,
                "{s}: could not build plugin root ({s}), script skipped",
                .{ script_path, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(plugin_root);

        var runtime = Runtime.init(allocator) catch |err| {
            logFailure(
                options.host,
                "{s}: could not create Lua state ({s}), script skipped",
                .{ script_path, @errorName(err) },
            );
            return err;
        };
        errdefer runtime.deinit();

        // The runtime borrows these slices, so the script owns them for the
        // runtime's whole lifetime.
        runtime.setPluginId(plugin_id);
        runtime.setPluginRoot(plugin_root);
        runtime.setHost(options.host);
        runtime.openSafeLibs();
        runtime.installZostd();

        var chunk_name_buffer: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        const chunk_name = std.fmt.bufPrintZ(
            &chunk_name_buffer,
            "@{s}",
            .{script_path},
        ) catch {
            logFailure(
                options.host,
                "{s}: path is too long for a Lua chunk name, script skipped",
                .{script_path},
            );
            return error.NameTooLong;
        };

        runtime.run(source, chunk_name) catch |err| {
            const message = runtime.lua.toString(-1) catch "<non-string error>";
            logFailure(
                options.host,
                "{s}: {s}: {s}",
                .{ script_path, @errorName(err), std.mem.span(message) },
            );
            return err;
        };

        var script: Script = .{
            .allocator = allocator,
            .id = plugin_id,
            .root_directory = plugin_root,
            .script_path = script_path,
            .runtime = runtime,
        };

        logFailure(options.host, "loaded {s} as {s}", .{ script_path, plugin_id });
        script.dispatchEvent("on_load", null);
        return script;
    }

    /// Dispatches `on_unload`, closes the Lua state, and frees every owned
    /// string.
    ///
    /// Host callbacks and their context may be used during the `on_unload`
    /// dispatch and must therefore still be valid when this function is
    /// called.
    pub fn deinit(self: *Script) void {
        self.runtime.dispatchEvent("on_unload", null);
        self.runtime.deinit();
        self.allocator.free(self.id);
        self.allocator.free(self.root_directory);
        self.allocator.free(self.script_path);
        self.* = undefined;
    }

    /// Delivers one engine event to the script's registered callbacks.
    ///
    /// `payload` is optional JSON text and is passed as the callback's second
    /// argument. Callback failures are isolated and logged by the runtime.
    pub fn dispatchEvent(
        self: *Script,
        event: []const u8,
        payload: ?[]const u8,
    ) void {
        self.runtime.dispatchEvent(event, payload);
    }

    /// Returns the plugin id shown to the script. Valid until `deinit()`.
    pub fn pluginId(self: *const Script) []const u8 {
        return self.id;
    }

    /// Returns the path of `main.lua` used in diagnostics. Valid until
    /// `deinit()`.
    pub fn path(self: *const Script) []const u8 {
        return self.script_path;
    }
};

/// Formats one diagnostic line and passes it to the host logger.
///
/// Missing loggers and messages that do not fit the fixed buffer are ignored;
/// diagnostics must never turn a script failure into a different error.
fn logFailure(host: zostd.Host, comptime format: []const u8, args: anytype) void {
    const logger = host.log orelse return;
    var buffer: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format, args) catch return;
    logger(host.context, line);
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

/// Host context that records concatenated log messages for assertions.
const TestLog = struct {
    buffer: [2048]u8 = undefined,
    len: usize = 0,

    /// Appends one host log line to `buffer`.
    fn log(context: ?*anyopaque, message: []const u8) void {
        const self: *TestLog = @ptrCast(@alignCast(context.?));
        const count = @min(message.len, self.buffer.len - self.len);
        @memcpy(self.buffer[self.len..][0..count], message[0..count]);
        self.len += count;
    }

    /// Returns the recorded text.
    fn text(self: *const TestLog) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Builds a host table backed by this recorder.
    fn host(self: *TestLog) zostd.Host {
        return .{ .context = self, .log = log };
    }
};

test "Script loads, dispatches, and unloads a main.lua" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var plugin_dir = try tmp.dir.createDirPathOpen(testing.io, "demo", .{});
    plugin_dir.close(testing.io);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "demo/main.lua",
        .data =
        \\zostd.on("on_load", function() zostd.log("on_load;") end)
        \\zostd.on("ping", function() zostd.log("ping;") end)
        \\zostd.on("on_unload", function() zostd.log("on_unload;") end)
        ,
    });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &path_buffer);

    var log = TestLog{};
    var script = try Script.load(testing.allocator, testing.io, .{
        .plugins_directory = path_buffer[0..root_len],
        .directory_name = "demo",
        .host = log.host(),
    });
    var script_alive = true;
    defer if (script_alive) script.deinit();

    try testing.expectEqualStrings("demo", script.pluginId());
    try testing.expect(std.mem.endsWith(u8, script.path(), "demo/main.lua"));
    try testing.expect(std.mem.indexOf(u8, log.text(), "on_load;") != null);

    script.dispatchEvent("ping", null);
    try testing.expect(std.mem.indexOf(u8, log.text(), "ping;") != null);

    script.deinit();
    script_alive = false;
    try testing.expect(std.mem.indexOf(u8, log.text(), "on_unload;") != null);
}

test "Script reports a missing main.lua as FileNotFound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var plugin_dir = try tmp.dir.createDirPathOpen(testing.io, "empty", .{});
    plugin_dir.close(testing.io);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &path_buffer);

    var log = TestLog{};
    try testing.expectError(error.FileNotFound, Script.load(testing.allocator, testing.io, .{
        .plugins_directory = path_buffer[0..root_len],
        .directory_name = "empty",
        .host = log.host(),
    }));
}
