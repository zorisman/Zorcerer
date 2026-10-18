//! Plugin manifests for PluginManager.zig: a small .toml file sitting next
//! to each plugin's .so, declaring its id/version/dependencies and which
//! file to actually dlopen. Schema:
//!
//!     id = "example_plugin"
//!     name = "Example Plugin"       # optional, defaults to id
//!     version = "1.2.0"
//!     author = "someone"             # optional, defaults to "unknown"
//!     file = "example_plugin.so"     # path to the .so, relative to this
//!                                     # manifest's own directory
//!
//!     [dependencies]
//!     other_plugin = ">=1.0.0"
//!     third_plugin = "*"             # any version
//!
//! This is NOT a general-purpose TOML parser - just enough of the syntax
//! for this exact, flat shape: top-level `key = "quoted string"` pairs,
//! one `[dependencies]` table of `id = "requirement"` pairs, `#` comments.
//! No arrays, no nested tables, no multi-line strings, no non-string
//! values. If you need more than this, this file is the place to extend,
//! not a sign something else is broken.
//!
//! Versions are plain `major.minor.patch` (missing parts default to 0).
//! Requirements are `*` (any), a bare version (exact match), or
//! `>=`/`>`/`<=`/`<`/`=` followed by a version - no caret/tilde ranges,
//! no OR'd requirement lists.
//!
//! *** UNVERIFIED, LIKELY THE WEAKEST PART OF THIS FILE ***
//! `readWholeFile` is the one function here doing blocking file I/O - see
//! the same caveat in VTableResolver.zig/PluginManager.zig about Zig
//! 0.16's std.Io rework. Everything else (TOML parsing, version
//! comparison, dependency graph resolution) only operates on in-memory
//! byte slices and doesn't care how you got the manifest's text.
//!
//! I could not compile-check this file myself (no Zig 0.16 toolchain
//! available here) - please verify against a handful of real manifests,
//! including a deliberately broken one (missing field, bad version
//! string, a circular dependency) before relying on it.

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(text: []const u8) !Version {
        var it = std.mem.splitScalar(u8, text, '.');
        const major_s = it.next() orelse return error.InvalidVersion;
        const minor_s = it.next() orelse "0";
        const patch_s = it.next() orelse "0";
        return .{
            .major = std.fmt.parseUnsigned(u32, major_s, 10) catch return error.InvalidVersion,
            .minor = std.fmt.parseUnsigned(u32, minor_s, 10) catch return error.InvalidVersion,
            .patch = std.fmt.parseUnsigned(u32, patch_s, 10) catch return error.InvalidVersion,
        };
    }

    pub fn order(self: Version, other: Version) std.math.Order {
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        return std.math.order(self.patch, other.patch);
    }
};

pub const Requirement = union(enum) {
    any,
    exact: Version,
    gte: Version,
    gt: Version,
    lte: Version,
    lt: Version,

    pub fn parse(text_in: []const u8) !Requirement {
        const text = std.mem.trim(u8, text_in, " \t");
        if (text.len == 0 or std.mem.eql(u8, text, "*")) return .any;
        if (std.mem.startsWith(u8, text, ">=")) return .{ .gte = try Version.parse(text[2..]) };
        if (std.mem.startsWith(u8, text, "<=")) return .{ .lte = try Version.parse(text[2..]) };
        if (std.mem.startsWith(u8, text, ">")) return .{ .gt = try Version.parse(text[1..]) };
        if (std.mem.startsWith(u8, text, "<")) return .{ .lt = try Version.parse(text[1..]) };
        if (std.mem.startsWith(u8, text, "=")) return .{ .exact = try Version.parse(text[1..]) };
        return .{ .exact = try Version.parse(text) }; // bare "1.2.0" = exact match
    }

    pub fn satisfiedBy(self: Requirement, version: Version) bool {
        return switch (self) {
            .any => true,
            .exact => |v| version.order(v) == .eq,
            .gte => |v| version.order(v) != .lt,
            .gt => |v| version.order(v) == .gt,
            .lte => |v| version.order(v) != .gt,
            .lt => |v| version.order(v) == .lt,
        };
    }
};

pub const Dependency = struct {
    id: []const u8,
    requirement: Requirement,
};

pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    version: Version,
    author: []const u8,
    /// Path to the .so, relative to `dir`.
    file: []const u8,
    /// The directory this manifest was found in - `file` is resolved
    /// relative to this.
    dir: []const u8,
    dependencies: []Dependency,

    pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.author);
        allocator.free(self.file);
        allocator.free(self.dir);
        for (self.dependencies) |dep| allocator.free(dep.id);
        allocator.free(self.dependencies);
    }
};

pub const ManifestError = error{
    MissingId,
    MissingVersion,
    MissingFile,
    InvalidVersion,
} || std.mem.Allocator.Error;

const RawEntry = struct {
    section: []const u8, // "" for top-level
    key: []const u8,
    value: []const u8, // unquoted string content
};

fn parseToml(allocator: std.mem.Allocator, text: []const u8) ![]RawEntry {
    var entries: std.ArrayList(RawEntry) = .empty;
    errdefer entries.deinit(allocator);

    var current_section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            current_section = std.mem.trim(u8, line[1..close], " \t");
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        } else if (std.mem.indexOfScalar(u8, value, '#')) |hash| {
            // an unquoted value with a trailing comment
            value = std.mem.trim(u8, value[0..hash], " \t");
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                value = value[1 .. value.len - 1];
            }
        }

        try entries.append(allocator, .{ .section = current_section, .key = key, .value = value });
    }

    return try entries.toOwnedSlice(allocator);
}

/// `dir` is the directory `text` (the manifest's raw contents) was found
/// in - stored on the result so `file` can later be resolved relative to
/// it. All returned strings are allocator-owned copies, independent of
/// `text`/`dir` - free with `Manifest.deinit`.
pub fn parseManifest(allocator: std.mem.Allocator, dir: []const u8, text: []const u8) ManifestError!Manifest {
    const raw = try parseToml(allocator, text);
    defer allocator.free(raw);

    var id: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var version_str: ?[]const u8 = null;
    var author: ?[]const u8 = null;
    var file: ?[]const u8 = null;

    var deps: std.ArrayList(Dependency) = .empty;
    errdefer {
        for (deps.items) |d| allocator.free(d.id);
        deps.deinit(allocator);
    }

    for (raw) |entry| {
        if (entry.section.len == 0) {
            if (std.mem.eql(u8, entry.key, "id")) id = entry.value;
            if (std.mem.eql(u8, entry.key, "name")) name = entry.value;
            if (std.mem.eql(u8, entry.key, "version")) version_str = entry.value;
            if (std.mem.eql(u8, entry.key, "author")) author = entry.value;
            if (std.mem.eql(u8, entry.key, "file")) file = entry.value;
        } else if (std.mem.eql(u8, entry.section, "dependencies")) {
            const requirement = Requirement.parse(entry.value) catch continue; // skip malformed
            try deps.append(allocator, .{
                .id = try allocator.dupe(u8, entry.key),
                .requirement = requirement,
            });
        }
    }

    const id_v = id orelse return error.MissingId;
    const version_v = version_str orelse return error.MissingVersion;
    const file_v = file orelse return error.MissingFile;
    const version = Version.parse(version_v) catch return error.InvalidVersion;

    return .{
        .id = try allocator.dupe(u8, id_v),
        .name = try allocator.dupe(u8, name orelse id_v),
        .version = version,
        .author = try allocator.dupe(u8, author orelse "unknown"),
        .file = try allocator.dupe(u8, file_v),
        .dir = try allocator.dupe(u8, dir),
        .dependencies = try deps.toOwnedSlice(allocator),
    };
}

/// Reads a whole file by path. See the module doc-comment: swap this out
/// first if anything in this file fails to compile.
pub fn readWholeFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(path, .{});
    defer file.close();

    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);

    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.read(buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

pub const DependencyError = error{
    MissingDependency,
    VersionMismatch,
    CircularDependency,
} || std.mem.Allocator.Error;

/// Returns `manifests` reordered so every dependency appears before
/// whatever depends on it - a valid load order. Validates up front that
/// every declared dependency actually exists among `manifests` and that
/// its version satisfies the requirement; a shared dependency (two
/// plugins depending on the same third one) appears exactly once in the
/// result, at the earliest point it's needed. Detects cycles.
///
/// The caller owns the returned slice (free with `allocator.free`) - it
/// contains the same `Manifest` values as `manifests`, just reordered,
/// so don't `deinit` both the input and the output.
pub fn resolveLoadOrder(allocator: std.mem.Allocator, manifests: []const Manifest) DependencyError![]const Manifest {
    var by_id = std.StringHashMap(usize).init(allocator);
    defer by_id.deinit();
    for (manifests, 0..) |m, i| try by_id.put(m.id, i);

    for (manifests) |m| {
        for (m.dependencies) |dep| {
            const dep_idx = by_id.get(dep.id) orelse return error.MissingDependency;
            if (!dep.requirement.satisfiedBy(manifests[dep_idx].version)) return error.VersionMismatch;
        }
    }

    const State = enum { unvisited, visiting, done };
    const state = try allocator.alloc(State, manifests.len);
    defer allocator.free(state);
    @memset(state, .unvisited);

    var order: std.ArrayList(Manifest) = .empty;
    errdefer order.deinit(allocator);

    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);

    var root: usize = 0;
    while (root < manifests.len) : (root += 1) {
        if (state[root] != .unvisited) continue;
        try stack.append(allocator, root);

        while (stack.items.len > 0) {
            const idx = stack.items[stack.items.len - 1];
            if (state[idx] == .unvisited) {
                state[idx] = .visiting;
                for (manifests[idx].dependencies) |dep| {
                    const dep_idx = by_id.get(dep.id).?; // validated above
                    if (state[dep_idx] == .visiting) return error.CircularDependency;
                    if (state[dep_idx] == .unvisited) try stack.append(allocator, dep_idx);
                }
            } else {
                stack.items.len -= 1;
                if (state[idx] == .visiting) {
                    state[idx] = .done;
                    try order.append(allocator, manifests[idx]);
                }
            }
        }
    }

    return try order.toOwnedSlice(allocator);
}
