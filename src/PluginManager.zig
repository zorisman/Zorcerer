const std = @import("std");
const toml = @import("toml");

/// Plugin directory relative to the process working directory.
/// If srcds is launched from the server root, this usually starts with "tf/".
const plugins_directory = "tf/addons/zorcerer/plugins";

/// Metadata described by a plugin manifest.
pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    author: []const u8,
    file: []const u8,
};

/// Minimal plugin manager.
/// readConfig() returns parsed manifests owned by the manager. The returned
/// data remains valid until the next readConfig() call or deinit().
pub const Manager = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,

    // init() does not accept std.Io, so use the single-threaded adapter for this prototype.
    threaded_io: std.Io.Threaded = .init_single_threaded,

    manifest_result: ?[]Manifest = null,

    pub fn init() @This() {
        return .{};
    }

    /// Frees all parsed manifests retained by the manager.
    /// This can be called with defer.
    pub fn deinit(self: *@This()) void {
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
};
