//! Dependency graph calculation for native plugins.
//!
//! The resolver is deliberately independent of the filesystem and of
//! dynamic-library loading: it only reads validated `PluginConfiguration`
//! values and returns which plugins may be loaded, in dependency-first
//! order, plus the plugins that must be skipped and why.
//!
//! The manager walks `Resolution.order` and loads each plugin; a plugin whose
//! dependency fails at runtime is rejected there and its dependents are
//! skipped by the manager. Static failures (missing dependency, version
//! mismatch, cycle) are already propagated transitively by this module.

const std = @import("std");
const PluginConfiguration = @import("plugin-configuration").PluginConfiguration;

/// Why a plugin will not be loaded.
pub const RejectReason = enum {
    /// A dependency id does not correspond to any valid manifest.
    missing_dependency,
    /// A dependency exists, but its manifest version does not satisfy the
    /// declared requirement.
    version_mismatch,
    /// A dependency was itself rejected, so this plugin cannot load either.
    dependency_rejected,
    /// The plugin is part of a dependency cycle or depends on one.
    cycle,

    /// Returns a short human-readable description for logs and events.
    ///
    /// Side effects: none.
    pub fn text(self: @This()) []const u8 {
        return switch (self) {
            .missing_dependency => "dependency not found",
            .version_mismatch => "dependency version mismatch",
            .dependency_rejected => "dependency was not loaded",
            .cycle => "dependency cycle",
        };
    }
};

/// One rejected plugin.
///
/// `plugin_index` indexes the `configs` slice passed to `resolve()`.
/// `dependency_id`, `required` and `found_version` borrow strings from those
/// configurations and remain valid as long as the configurations do.
pub const Rejection = struct {
    /// Index of the rejected plugin in the resolver's input slice.
    plugin_index: usize,
    /// Why the plugin was rejected.
    reason: RejectReason,
    /// Dependency involved in the rejection, when one applies.
    dependency_id: ?[]const u8 = null,
    /// Declared version requirement, for `.version_mismatch`.
    required: ?[]const u8 = null,
    /// Version found in the dependency's manifest, for `.version_mismatch`.
    found_version: ?[]const u8 = null,
};

/// Result of resolving one set of validated manifests.
///
/// Ownership: both slices are allocated with the allocator passed to
/// `resolve()` and released by `deinit()`. The strings referenced by
/// `Rejection` are not owned here; they belong to the input configurations.
pub const Resolution = struct {
    /// Indices into the input slice, in dependency-first load order.
    /// Rejected plugins are not included.
    order: []usize,
    /// Rejected plugins, in input order.
    rejected: []Rejection,

    /// Releases the slices owned by this resolution.
    ///
    /// `allocator` must be the allocator passed to `resolve()`.
    ///
    /// Side effects: frees `order` and `rejected`.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.order.len != 0) allocator.free(self.order);
        if (self.rejected.len != 0) allocator.free(self.rejected);
    }
};

/// Computes a dependency-first load order and the set of plugins to skip.
///
/// The graph is built from `configs[i].dependencies`. Edges whose target is
/// absent or whose version requirement is not satisfied reject the source
/// plugin; rejection then propagates to every transitive dependent. Among
/// the remaining plugins, Kahn's algorithm produces a stable topological
/// order (input order breaks ties). Plugins left after that pass are part of
/// a cycle or depend on one and are rejected with `.cycle`.
///
/// Parameters:
/// - `allocator`: owns the returned slices; `Resolution.deinit()` must be
///   called with the same allocator.
/// - `configs`: validated configurations. Their strings must outlive the
///   returned resolution because `Rejection` borrows them.
///
/// Errors: `error.DuplicatePluginId` when two configurations share an id
/// (normally prevented by `validateForDirectory`) and `error.OutOfMemory`
/// when allocation fails. Individual graph problems are reported through
/// `Resolution.rejected`, not as errors.
///
/// Side effects: none.
pub fn resolve(
    allocator: std.mem.Allocator,
    configs: []const PluginConfiguration,
) !Resolution {
    const count = configs.len;

    var id_to_index = std.StringHashMap(usize).init(allocator);
    defer id_to_index.deinit();
    try id_to_index.ensureTotalCapacity(@intCast(count));
    for (configs, 0..) |config, index| {
        const entry = try id_to_index.getOrPut(config.id);
        if (entry.found_existing) return error.DuplicatePluginId;
        entry.value_ptr.* = index;
    }

    const RejectionInfo = struct {
        reason: RejectReason,
        dependency_id: ?[]const u8 = null,
        required: ?[]const u8 = null,
        found_version: ?[]const u8 = null,
    };

    var rejected = try allocator.alloc(?RejectionInfo, count);
    defer allocator.free(rejected);
    for (rejected) |*slot| slot.* = null;

    // Validate every edge before propagating rejections.
    for (configs, 0..) |config, index| {
        for (config.dependencies) |dependency| {
            const dependency_index = id_to_index.get(dependency.id) orelse {
                rejected[index] = .{
                    .reason = .missing_dependency,
                    .dependency_id = dependency.id,
                };
                break;
            };
            if (!dependency.matches(configs[dependency_index].version)) {
                rejected[index] = .{
                    .reason = .version_mismatch,
                    .dependency_id = dependency.id,
                    .required = dependency.requirement,
                    .found_version = configs[dependency_index].version,
                };
                break;
            }
        }
    }

    // Propagate rejection to every transitive dependent. The loop is
    // quadratic in the worst case, which is fine for the bounded manifest
    // counts involved here.
    var changed = true;
    while (changed) {
        changed = false;
        for (configs, 0..) |config, index| {
            if (rejected[index] != null) continue;
            for (config.dependencies) |dependency| {
                const dependency_index = id_to_index.get(dependency.id) orelse continue;
                if (rejected[dependency_index] != null) {
                    rejected[index] = .{
                        .reason = .dependency_rejected,
                        .dependency_id = dependency.id,
                    };
                    changed = true;
                    break;
                }
            }
        }
    }

    var indegree = try allocator.alloc(usize, count);
    defer allocator.free(indegree);
    @memset(indegree, 0);

    var dependents = try allocator.alloc(std.ArrayList(usize), count);
    defer {
        for (dependents) |*list| list.deinit(allocator);
        allocator.free(dependents);
    }
    for (dependents) |*list| list.* = .empty;

    var ordered = try allocator.alloc(bool, count);
    defer allocator.free(ordered);
    @memset(ordered, false);

    for (configs, 0..) |config, index| {
        if (rejected[index] != null) continue;
        for (config.dependencies) |dependency| {
            const dependency_index = id_to_index.get(dependency.id) orelse continue;
            if (rejected[dependency_index] != null) continue;
            indegree[index] += 1;
            try dependents[dependency_index].append(allocator, index);
        }
    }

    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);
    for (indegree, 0..) |degree, index| {
        if (rejected[index] == null and degree == 0) {
            try queue.append(allocator, index);
        }
    }

    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(allocator);

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const index = queue.items[head];
        ordered[index] = true;
        try order.append(allocator, index);

        for (dependents[index].items) |dependent| {
            if (indegree[dependent] == 0) continue;
            indegree[dependent] -= 1;
            if (indegree[dependent] == 0) {
                try queue.append(allocator, dependent);
            }
        }
    }

    // Whatever remains is in a cycle or depends on one.
    for (configs, 0..) |_, index| {
        if (rejected[index] == null and !ordered[index]) {
            rejected[index] = .{ .reason = .cycle };
        }
    }

    var rejection_list: std.ArrayList(Rejection) = .empty;
    defer rejection_list.deinit(allocator);
    for (rejected, 0..) |info, index| {
        if (info) |rejection| {
            try rejection_list.append(allocator, .{
                .plugin_index = index,
                .reason = rejection.reason,
                .dependency_id = rejection.dependency_id,
                .required = rejection.required,
                .found_version = rejection.found_version,
            });
        }
    }

    const owned_order = try order.toOwnedSlice(allocator);
    errdefer if (owned_order.len != 0) allocator.free(owned_order);
    const owned_rejected = try rejection_list.toOwnedSlice(allocator);
    return .{
        .order = owned_order,
        .rejected = owned_rejected,
    };
}

fn makeConfig(
    id: []const u8,
    version_text: []const u8,
    dependencies: []const PluginConfiguration.Dependency,
) PluginConfiguration {
    return .{
        .id = id,
        .name = id,
        .version = version_text,
        .author = "test",
        .path = "./plugin.so",
        .dependencies = dependencies,
    };
}

fn findRejection(resolution: Resolution, plugin_index: usize) ?Rejection {
    for (resolution.rejected) |rejection| {
        if (rejection.plugin_index == plugin_index) return rejection;
    }
    return null;
}

test "plugins without dependencies keep input order" {
    const configs = [_]PluginConfiguration{
        makeConfig("first", "1.0.0", &.{}),
        makeConfig("second", "1.0.0", &.{}),
    };
    var resolution = try resolve(std.testing.allocator, &configs);
    defer resolution.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, resolution.order);
    try std.testing.expectEqual(@as(usize, 0), resolution.rejected.len);
}

test "dependencies load before dependents" {
    const configs = [_]PluginConfiguration{
        makeConfig("app", "1.0.0", &.{
            .{ .id = "core", .requirement = "^1.0.0" },
        }),
        makeConfig("core", "1.2.0", &.{
            .{ .id = "base", .requirement = "~0.4.0" },
        }),
        makeConfig("base", "0.4.2", &.{}),
    };
    var resolution = try resolve(std.testing.allocator, &configs);
    defer resolution.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, resolution.order);
    try std.testing.expectEqual(@as(usize, 0), resolution.rejected.len);
}

test "diamond dependencies produce a valid order" {
    const configs = [_]PluginConfiguration{
        makeConfig("app", "1.0.0", &.{
            .{ .id = "left", .requirement = "^1.0.0" },
            .{ .id = "right", .requirement = "^1.0.0" },
        }),
        makeConfig("left", "1.0.0", &.{
            .{ .id = "base", .requirement = "^1.0.0" },
        }),
        makeConfig("right", "1.0.0", &.{
            .{ .id = "base", .requirement = "^1.0.0" },
        }),
        makeConfig("base", "1.0.0", &.{}),
    };
    var resolution = try resolve(std.testing.allocator, &configs);
    defer resolution.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(usize, &.{ 3, 1, 2, 0 }, resolution.order);
    try std.testing.expectEqual(@as(usize, 0), resolution.rejected.len);
}

test "missing dependencies reject the dependent subtree" {
    const configs = [_]PluginConfiguration{
        makeConfig("app", "1.0.0", &.{
            .{ .id = "missing", .requirement = "^1.0.0" },
        }),
        makeConfig("dependent", "1.0.0", &.{
            .{ .id = "app", .requirement = "^1.0.0" },
        }),
        makeConfig("unrelated", "1.0.0", &.{}),
    };
    var resolution = try resolve(std.testing.allocator, &configs);
    defer resolution.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(usize, &.{2}, resolution.order);

    const app = findRejection(resolution, 0) orelse return error.TestExpectedRejection;
    try std.testing.expectEqual(RejectReason.missing_dependency, app.reason);
    try std.testing.expectEqualStrings("missing", app.dependency_id.?);

    const dependent = findRejection(resolution, 1) orelse return error.TestExpectedRejection;
    try std.testing.expectEqual(RejectReason.dependency_rejected, dependent.reason);
    try std.testing.expectEqualStrings("app", dependent.dependency_id.?);
}

test "version mismatches reject the dependent subtree" {
    const configs = [_]PluginConfiguration{
        makeConfig("app", "1.0.0", &.{
            .{ .id = "core", .requirement = "^2.0.0" },
        }),
        makeConfig("core", "1.5.0", &.{}),
        makeConfig("unrelated", "1.0.0", &.{}),
    };
    var resolution = try resolve(std.testing.allocator, &configs);
    defer resolution.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, resolution.order);

    const app = findRejection(resolution, 0) orelse return error.TestExpectedRejection;
    try std.testing.expectEqual(RejectReason.version_mismatch, app.reason);
    try std.testing.expectEqualStrings("core", app.dependency_id.?);
    try std.testing.expectEqualStrings("^2.0.0", app.required.?);
    try std.testing.expectEqualStrings("1.5.0", app.found_version.?);
}

test "cycles reject every member and their dependents" {
    const configs = [_]PluginConfiguration{
        makeConfig("a", "1.0.0", &.{
            .{ .id = "b", .requirement = "^1.0.0" },
        }),
        makeConfig("b", "1.0.0", &.{
            .{ .id = "a", .requirement = "^1.0.0" },
        }),
        makeConfig("dependent", "1.0.0", &.{
            .{ .id = "a", .requirement = "^1.0.0" },
        }),
        makeConfig("unrelated", "1.0.0", &.{}),
    };
    var resolution = try resolve(std.testing.allocator, &configs);
    defer resolution.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(usize, &.{3}, resolution.order);

    inline for (.{ 0, 1, 2 }) |index| {
        const rejection = findRejection(resolution, index) orelse
            return error.TestExpectedRejection;
        try std.testing.expectEqual(RejectReason.cycle, rejection.reason);
    }
}
