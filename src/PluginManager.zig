const std = @import("std");

/// Plugin directory relative to the process working directory.
/// If srcds is launched from the server root, this usually starts with "tf/".
const plugins_directory = "tf/addons/zorcerer/plugins";

/// Maximum size of a single TOML manifest: 1 MiB.
const max_config_size = 1024 * 1024;

/// Metadata described by a plugin manifest.
pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    author: []const u8,
    file: []const u8,
};

/// Minimal plugin manager.
/// readConfig() returns the raw text of each TOML manifest, one item per file.
/// The returned contents are owned by the manager and are freed by the next
/// readConfig() call or by deinit().
pub const Manager = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,

    // init() does not accept std.Io, so use the single-threaded adapter for this prototype.
    threaded_io: std.Io.Threaded = .init_single_threaded,

    config_result: ?[][]const u8 = null,

    pub fn init() @This() {
        return .{};
    }

    /// Frees all manifest contents retained by the manager.
    /// This can be called with defer.
    pub fn deinit(self: *@This()) void {
        self.clearConfigResult();
    }

    fn freeStringList(self: *@This(), strings: [][]const u8) void {
        for (strings) |string| {
            self.allocator.free(string);
        }
        self.allocator.free(strings);
    }

    fn clearConfigResult(self: *@This()) void {
        if (self.config_result) |configs| {
            self.freeStringList(configs);
            self.config_result = null;
        }
    }

    /// Finds and reads every .toml file under plugins_directory.
    /// Each result item contains the raw text of one TOML manifest. The order
    /// follows the filesystem traversal order and is not guaranteed.
    /// This does not parse TOML; comments, keys, and values are preserved as-is.
    /// The returned slice is owned by the manager and remains valid until the
    /// next readConfig() call or deinit().
    pub fn readConfig(self: *@This()) ![]const []const u8 {
        self.clearConfigResult();

        const io = self.threaded_io.io();
        var root = try std.Io.Dir.cwd().openDir(io, plugins_directory, .{ .iterate = true });
        defer root.close(io);

        var walker = try root.walk(self.allocator);
        defer walker.deinit();

        var configs: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (configs.items) |contents| {
                self.allocator.free(contents);
            }
            configs.deinit(self.allocator);
        }

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".toml")) {
                continue;
            }

            const full_path = try std.Io.Dir.path.join(
                self.allocator,
                &.{ plugins_directory, entry.path },
            );
            const contents = std.Io.Dir.cwd().readFileAlloc(
                io,
                full_path,
                self.allocator,
                .limited(max_config_size),
            ) catch |err| {
                self.allocator.free(full_path);
                return err;
            };
            self.allocator.free(full_path);

            configs.append(self.allocator, contents) catch |err| {
                self.allocator.free(contents);
                return err;
            };
        }

        const owned_result = try configs.toOwnedSlice(self.allocator);
        self.config_result = owned_result;
        return owned_result;
    }
};
