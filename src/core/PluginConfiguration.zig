//! Configuration of a single plugin as it appears in the plugin's `.toml`
//! manifest file. Provides `PluginConfiguration.parseConfig()` to turn the
//! raw TOML text of such a manifest into a validated, caller-owned
//! `PluginConfiguration`, and generic helpers to read arbitrary TOML (see
//! `readToml()`).
//!
//! Besides the required identity keys, a manifest may contain an optional
//! `[dependencies]` table. Its keys are plugin ids and its values are version
//! requirements; see `VersionRequirement` for the accepted grammar.
//!
//! A manifest also selects what the plugin directory provides: a native
//! library (`path`) or a Lua script (`script`). At least one of them must be
//! present. The optional `[network]` table carries the outbound network policy
//! that applies to whichever entry point the directory provides.

const std = @import("std");
const toml = @import("toml");
const VersionRequirement = @import("VersionRequirement.zig").VersionRequirement;

/// A single plugin's configuration, parsed from its manifest TOML file.
///
/// Invariant: every field must correspond to a top-level key of the
/// manifest, and every top-level manifest key must correspond to a field of
/// this struct; a superfluous key in the manifest is treated as an unknown
/// (not implemented) key.
///
/// Ownership: `parseConfig()` returns a configuration whose strings are
/// allocated with the caller's allocator. The caller must release them with
/// `deinit()`; a configuration built directly from literals does not need
/// `deinit()`.
pub const PluginConfiguration = struct {
    /// Hard upper limit on the raw TOML text size of a manifest that
    /// `parseConfig()` accepts: 4 KiB. Manifests that exceed it are
    /// rejected with `error.FileSizeOverflow`.
    pub const max_config_size: usize = 4 * 1024;

    /// Maximum accepted length of `id`, in bytes.
    pub const max_id_len: usize = 64;
    /// Maximum accepted length of `name`, in bytes.
    pub const max_name_len: usize = 128;
    /// Maximum accepted length of `version`, in bytes.
    pub const max_version_len: usize = 64;
    /// Maximum accepted length of `author`, in bytes.
    pub const max_author_len: usize = 128;
    /// Maximum accepted length of `path`, in bytes.
    pub const max_path_len: usize = 1024;

    /// Maximum number of entries accepted in the optional `[dependencies]`
    /// table.
    pub const max_dependencies: usize = 32;

    /// Maximum accepted length of `script`, in bytes.
    pub const max_script_len: usize = 1024;
    /// Maximum number of `allow` entries accepted in `[network]`.
    pub const max_network_rules: usize = 64;
    /// Maximum accepted host length in one `[network].allow` entry, in bytes.
    pub const max_network_host_len: usize = 255;
    /// Hard cap accepted for `[network].max_connections`.
    pub const max_network_connections: u16 = 32;
    /// Hard cap accepted for `[network].max_frame_bytes`.
    pub const max_network_frame_bytes: usize = 1024 * 1024;
    /// Hard cap accepted for every `[network]` timeout, in milliseconds.
    pub const max_network_timeout_ms: u32 = 30_000;

    /// One host or host:port entry of `[network].allow`.
    ///
    /// `host` is a literal host name or IP address. `port` is null when the
    /// rule allows every port on that host. A host that begins with `*.`
    /// matches the suffix and every subdomain of it.
    ///
    /// Ownership: in a parsed configuration, `host` is allocated with the
    /// configuration's allocator and freed by its `deinit()`.
    pub const NetworkRule = struct {
        /// Host name or IP address the rule applies to; may start with `*.`.
        host: []const u8,
        /// Port restriction, or null when every port is allowed.
        port: ?u16 = null,

        /// Returns whether this rule permits `host` and `port`.
        ///
        /// Host comparison is ASCII case-insensitive. A `*.` prefix matches
        /// the suffix with at least one subdomain label, so `*.example.com`
        /// matches `a.example.com` but not `example.com`. When the rule has a
        /// port, the requested port must equal it.
        ///
        /// Side effects: none.
        pub fn matches(self: @This(), host: []const u8, port: u16) bool {
            if (self.port) |allowed_port| {
                if (allowed_port != port) return false;
            }
            if (std.mem.startsWith(u8, self.host, "*.")) {
                const suffix = self.host[1..];
                if (host.len <= suffix.len) return false;
                return std.ascii.endsWithIgnoreCase(host, suffix);
            }
            return std.ascii.eqlIgnoreCase(host, self.host);
        }
    };

    /// Outbound network policy of one plugin.
    ///
    /// The policy is deny-by-default: an empty `rules` slice permits no
    /// connection. Limits bound the resources a plugin can consume through
    /// `NetworkApi`; values parsed from a manifest are additionally capped by
    /// the `max_network_*` constants.
    ///
    /// Ownership: when parsed from a manifest, `rules` and their host strings
    /// are owned by the configuration and released by `deinit()`. Literal
    /// policies borrow their strings and must not be passed to `deinit()`.
    pub const NetworkPolicy = struct {
        /// Ordered allowlist of accepted destinations. Order does not affect
        /// matching; the list is simply scanned linearly.
        rules: []const NetworkRule = &.{},
        /// Whether destinations in private, loopback, link-local, multicast,
        /// or unspecified address space may be contacted. Disabled by
        /// default so a hostname that resolves into the local network cannot
        /// bypass an allowlist accidentally.
        allow_private: bool = false,
        /// Maximum number of simultaneously open connections per plugin.
        max_connections: u16 = 4,
        /// Largest buffer accepted by one `NetworkApi.read`/`write` call.
        max_frame_bytes: usize = 64 * 1024,
        /// Deadline for the resolve plus connect phase of one connection.
        connect_timeout_ms: u32 = 3_000,
        /// Deadline for one `NetworkApi.read` or `write` call.
        io_timeout_ms: u32 = 3_000,
        /// Longest time a single `NetworkApi.poll` call may block.
        poll_timeout_ms: u32 = 10,

        /// Returns whether the policy permits contacting `host` on `port`.
        ///
        /// The host is matched against every rule with
        /// `NetworkRule.matches()`. Private address space is not checked here
        /// because the check needs the resolved address; see
        /// `addressIsPrivate()`.
        ///
        /// Side effects: none.
        pub fn allows(self: @This(), host: []const u8, port: u16) bool {
            for (self.rules) |rule| {
                if (rule.matches(host, port)) return true;
            }
            return false;
        }
    };

    /// One entry of the manifest's optional `[dependencies]` table.
    ///
    /// Ownership: when parsed from a manifest, both strings belong to the
    /// containing `PluginConfiguration` and are released by its `deinit()`.
    /// Literal configurations borrow them instead.
    pub const Dependency = struct {
        /// Plugin id of the dependency. Must satisfy the same identifier
        /// rules as `PluginConfiguration.id`.
        id: []const u8,
        /// Raw version requirement text from the manifest, for example
        /// `"^1.2.0"`. `VersionRequirement.parse()` validates it.
        requirement: []const u8,

        /// Returns whether `version` satisfies this dependency's requirement.
        ///
        /// Both the requirement and `version` are expected to have been
        /// validated by `parseConfig()`/`validateValues()`. Invalid text
        /// yields false rather than an error, so graph resolution can report
        /// a normal version mismatch.
        ///
        /// Side effects: none.
        pub fn matches(self: @This(), version: []const u8) bool {
            const parsed_version = std.SemanticVersion.parse(version) catch return false;
            const parsed_requirement = VersionRequirement.parse(self.requirement) catch return false;
            return parsed_requirement.matches(parsed_version);
        }
    };

    /// Every key that is allowed to appear (as a top-level key) inside a
    /// manifest's TOML file; each entry must correspond 1:1 to a field of
    /// this struct, see the struct's invariant above. Any parsed manifest
    /// that carries a key not listed here is rejected with
    /// `error.KeysNotImplemented`.
    pub const known_keys: []const []const u8 = &.{
        "id",
        "name",
        "version",
        "author",
        "path",
        "script",
        "dependencies",
        "network",
    };

    /// Unique identifier of the plugin, also the name of the directory the
    /// plugin is loaded from. Must match `[A-Za-z0-9_-]+` and the plugin's
    /// directory name.
    id: []const u8,
    /// Human-readable display name of the plugin.
    name: []const u8,
    /// Version string of the plugin in the author's chosen format.
    version: []const u8,
    /// Author string of the plugin, in the author's chosen format.
    author: []const u8,
    /// Path to the plugin's `.so` library, relative to the plugin directory.
    /// Null for a script-only manifest.
    path: ?[]const u8 = null,
    /// Path to the plugin's Lua script, relative to the plugin directory.
    /// Null for a native-only manifest. When both `path` and `script` are
    /// present, the manager loads both entry points from the same directory.
    script: ?[]const u8 = null,
    /// Optional dependencies declared under the manifest's `[dependencies]`
    /// table. Empty when the table is absent. When the configuration comes
    /// from `parseConfig()`, the strings are owned by the configuration.
    /// Configurations built directly from literals borrow their strings and
    /// must not be passed to `deinit()`.
    dependencies: []const Dependency = &.{},
    /// Optional outbound network policy from the manifest's `[network]`
    /// table. Empty (deny everything) when the table is absent.
    network: NetworkPolicy = .{},

    /// Parses and validates the raw TOML text of a plugin manifest into a
    /// `PluginConfiguration`.
    ///
    /// Every required top-level key must be a field of this struct and every
    /// required field must be a top-level string value; the values must
    /// additionally pass `validateValues()`. `path` and `script` are optional
    /// strings, but at least one must be present. The optional `[dependencies]`
    /// table maps plugin ids to version requirement strings and is parsed
    /// into `dependencies`; the optional `[network]` table is parsed into
    /// `network`. Otherwise an error is returned and the configuration cannot
    /// be used.
    ///
    /// Parameters:
    /// - `allocator`: owns every string of the returned configuration; the
    ///   caller must call `deinit()` with the same allocator.
    /// - `toml_text`: the complete manifest file contents.
    ///
    /// Errors:
    /// - `error.FileSizeOverflow` if the manifest text is larger than
    ///   `max_config_size` (4 KiB).
    /// - `error.KeysNotImplemented` if the manifest contains a top-level key
    ///   that has no corresponding field in this struct.
    /// - `error.WrongValueType` if a known key's value is not a TOML string,
    ///   or if `dependencies` is not a table of string values.
    /// - `error.MissingRequiredField` if a required key is absent entirely.
    /// - `error.InvalidValue` if a value is empty, too long, or fails the
    ///   identifier/path/version/dependency rules of `validateValues()`.
    /// - Any error the TOML parser itself can report for malformed input
    ///   (see `toml.Parser(Table).parseString`).
    /// - `error.OutOfMemory` if duplicating the parsed strings fails.
    ///
    /// Side effects: before failing with `error.KeysNotImplemented`, every
    /// unknown key is reported to the user with `std.log.warn`; the
    /// failure is not otherwise observable via `error_info` or the like,
    /// since keys are known only from the manifest text.
    ///
    /// Memory: the TOML parser's temporary arena and the manifest text are
    /// not retained. On success the returned strings are owned by
    /// `allocator`; on any error nothing is retained.
    pub fn parseConfig(allocator: std.mem.Allocator, toml_text: []const u8) !@This() {
        if (toml_text.len > max_config_size) {
            return error.FileSizeOverflow;
        }

        // Parsing into the raw table (`toml.Table`) is deliberate:
        // `toml.Parser(Table)` on a mapped struct silently drops
        // superfluous manifest keys, while `parseConfig` must reject them
        // with `error.KeysNotImplemented`.
        var parser = toml.Parser(toml.Table).init(allocator);
        defer parser.deinit();

        var parsed = try parser.parseString(toml_text);
        defer parsed.deinit();
        const table = parsed.value;

        // Reject every manifest key that the struct does not have a field
        // for; zig-toml's struct mapping would silently drop them. All
        // unknown keys are collected first so the user can be told about
        // every problem in one go, not only about the first one.
        var unknown_keys: std.ArrayList([]const u8) = .empty;
        defer unknown_keys.deinit(allocator);
        var it = table.iterator();
        while (it.next()) |entry| {
            var known = false;
            for (known_keys) |key| {
                if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                    known = true;
                    break;
                }
            }
            if (!known) try unknown_keys.append(allocator, entry.key_ptr.*);
        }
        if (unknown_keys.items.len != 0) {
            for (unknown_keys.items) |key| {
                std.log.warn("unknown manifest key: {s}", .{key});
            }
            return error.KeysNotImplemented;
        }

        // Bind the parser-owned string slices first. They stay valid until
        // `parsed.deinit()` at the end of this function; the validated
        // values are duplicated into `allocator` before then. `path` and
        // `script` are optional strings, while `dependencies` and `network`
        // carry tables and are parsed separately below.
        var parsed_values: @This() = undefined;
        inline for (std.meta.fields(@This())) |field| {
            if (comptime std.mem.eql(u8, field.name, "dependencies") or
                std.mem.eql(u8, field.name, "network"))
            {
                continue;
            }
            if (comptime std.mem.eql(u8, field.name, "path") or
                std.mem.eql(u8, field.name, "script"))
            {
                const optional_value = table.get(field.name);
                if (optional_value) |value| {
                    switch (value) {
                        .string => |str| @field(parsed_values, field.name) = str,
                        else => return error.WrongValueType,
                    }
                } else {
                    @field(parsed_values, field.name) = null;
                }
                continue;
            }
            const value = table.get(field.name) orelse return error.MissingRequiredField;
            switch (value) {
                .string => |str| @field(parsed_values, field.name) = str,
                else => return error.WrongValueType,
            }
        }

        const dependencies = try parseDependencies(allocator, table.get("dependencies"));
        errdefer freeDependencies(allocator, dependencies);
        parsed_values.dependencies = dependencies;

        const network = try parseNetwork(allocator, table.get("network"));
        errdefer freeNetwork(allocator, network);
        parsed_values.network = network;

        try parsed_values.validateValues();

        const id = try allocator.dupe(u8, parsed_values.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, parsed_values.name);
        errdefer allocator.free(name);
        const version = try allocator.dupe(u8, parsed_values.version);
        errdefer allocator.free(version);
        const author = try allocator.dupe(u8, parsed_values.author);
        errdefer allocator.free(author);

        const path: ?[]const u8 = if (parsed_values.path) |value| value: {
            const copy = try allocator.dupe(u8, value);
            errdefer allocator.free(copy);
            break :value copy;
        } else null;
        const script: ?[]const u8 = if (parsed_values.script) |value| value: {
            const copy = try allocator.dupe(u8, value);
            errdefer allocator.free(copy);
            break :value copy;
        } else null;

        return .{
            .id = id,
            .name = name,
            .version = version,
            .author = author,
            .path = path,
            .script = script,
            .dependencies = dependencies,
            .network = network,
        };
    }

    /// Checks the values of an already parsed configuration.
    ///
    /// At least one of `path` and `script` must be present. `id` must be
    /// non-empty, at most `max_id_len` bytes, and consist only of ASCII
    /// letters, digits, `_` and `-`. `name` and `author` must be non-empty and
    /// fit their length limits. `version` must be a semantic version. `path`,
    /// when present, must be a relative path that stays inside the plugin
    /// directory, is at most `max_path_len` bytes, and names a `.so` file.
    /// `script`, when present, follows the same containment rules and must
    /// name a `.lua` file. `dependencies` must contain at most
    /// `max_dependencies` entries; every entry needs a valid, unique id
    /// different from this plugin's own id, and a requirement accepted by
    /// `VersionRequirement.parse()`. `network` limits must stay within their
    /// hard caps.
    ///
    /// Errors: `error.InvalidValue` when any of the rules above is
    /// violated.
    ///
    /// Side effects: none.
    pub fn validateValues(self: @This()) !void {
        if (self.id.len == 0 or self.id.len > max_id_len or !isValidId(self.id)) {
            return error.InvalidValue;
        }
        if (self.name.len == 0 or self.name.len > max_name_len) {
            return error.InvalidValue;
        }
        if (self.version.len == 0 or self.version.len > max_version_len) {
            return error.InvalidValue;
        }
        _ = std.SemanticVersion.parse(self.version) catch return error.InvalidValue;
        if (self.author.len == 0 or self.author.len > max_author_len) {
            return error.InvalidValue;
        }
        if (self.path == null and self.script == null) return error.InvalidValue;
        if (self.path) |path| try validateLibraryPath(path);
        if (self.script) |script| try validateScriptPath(script);

        if (self.dependencies.len > max_dependencies) return error.InvalidValue;
        for (self.dependencies, 0..) |dependency, index| {
            if (dependency.id.len == 0 or dependency.id.len > max_id_len or
                !isValidId(dependency.id))
            {
                return error.InvalidValue;
            }
            if (std.mem.eql(u8, dependency.id, self.id)) return error.InvalidValue;
            for (self.dependencies[0..index]) |earlier| {
                if (std.mem.eql(u8, dependency.id, earlier.id)) return error.InvalidValue;
            }
            _ = VersionRequirement.parse(dependency.requirement) catch
                return error.InvalidValue;
        }

        if (self.network.rules.len > max_network_rules) return error.InvalidValue;
        if (self.network.max_connections > max_network_connections) {
            return error.InvalidValue;
        }
        if (self.network.max_frame_bytes == 0 or
            self.network.max_frame_bytes > max_network_frame_bytes)
        {
            return error.InvalidValue;
        }
        if (self.network.connect_timeout_ms == 0 or
            self.network.connect_timeout_ms > max_network_timeout_ms or
            self.network.io_timeout_ms == 0 or
            self.network.io_timeout_ms > max_network_timeout_ms or
            self.network.poll_timeout_ms > max_network_timeout_ms)
        {
            return error.InvalidValue;
        }
    }

    /// Returns whether this configuration provides a native library.
    ///
    /// Script-only manifests are still valid configurations, but they do not
    /// participate in native plugin dependency resolution or `dlopen()`.
    ///
    /// Side effects: none.
    pub fn isNative(self: @This()) bool {
        return self.path != null;
    }

    /// Checks the invariants that require the plugin's directory name.
    ///
    /// `id` is the plugin's directory name by contract, so it must match
    /// `dir_name` exactly. Directory-dependent validation is deliberately
    /// separate from `validateValues()` so a manifest can be validated
    /// before its location is known.
    ///
    /// Errors: `error.InvalidValue` when `id` and `dir_name` differ.
    ///
    /// Side effects: none.
    pub fn validateForDirectory(self: @This(), dir_name: []const u8) !void {
        if (!std.mem.eql(u8, self.id, dir_name)) {
            return error.InvalidValue;
        }
    }

    /// Releases every string owned by this configuration.
    ///
    /// `allocator` must be the allocator passed to `parseConfig()`.
    /// Configurations built from literals must not be passed here.
    ///
    /// Side effects: frees `id`, `name`, `version`, `author`, `path`,
    /// `script`, every dependency id and requirement string, and every
    /// `[network].allow` host.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.author);
        if (self.path) |path| allocator.free(path);
        if (self.script) |script| allocator.free(script);
        freeDependencies(allocator, self.dependencies);
        freeNetwork(allocator, self.network);
    }
};

/// Parses the manifest's optional `[dependencies]` table.
///
/// A missing table yields an empty slice. Each table value must be a string
/// accepted by `VersionRequirement.parse()`. The returned slice and all of
/// its strings are owned by `allocator`; the caller must release them with
/// `freeDependencies()`. Entries are sorted by dependency id so graph
/// processing and error reporting are deterministic.
///
/// Errors: `error.WrongValueType` when the value is not a table or an entry
/// is not a string, `error.InvalidValue` for an invalid requirement or too
/// many entries, and `error.OutOfMemory` when allocation fails.
fn parseDependencies(
    allocator: std.mem.Allocator,
    value: ?toml.Value,
) ![]const PluginConfiguration.Dependency {
    const table_value = value orelse return &.{};
    const dependency_table = switch (table_value) {
        .table => |table| table,
        else => return error.WrongValueType,
    };

    if (dependency_table.count() > PluginConfiguration.max_dependencies) {
        return error.InvalidValue;
    }
    if (dependency_table.count() == 0) return &.{};

    var dependencies = try allocator.alloc(
        PluginConfiguration.Dependency,
        dependency_table.count(),
    );
    var filled: usize = 0;
    errdefer {
        for (dependencies[0..filled]) |dependency| {
            allocator.free(dependency.id);
            allocator.free(dependency.requirement);
        }
        allocator.free(dependencies);
    }

    var iterator = dependency_table.iterator();
    while (iterator.next()) |entry| {
        const requirement = switch (entry.value_ptr.*) {
            .string => |text| text,
            else => return error.WrongValueType,
        };
        _ = VersionRequirement.parse(requirement) catch return error.InvalidValue;

        const id = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(id);
        const requirement_copy = try allocator.dupe(u8, requirement);
        errdefer allocator.free(requirement_copy);

        dependencies[filled] = .{
            .id = id,
            .requirement = requirement_copy,
        };
        filled += 1;
    }

    std.mem.sort(
        PluginConfiguration.Dependency,
        dependencies,
        {},
        dependencyLessThan,
    );
    return dependencies;
}

/// Releases a dependency slice produced by `parseDependencies()`.
///
/// The empty slice returned for a missing `[dependencies]` table carries no
/// allocation and is left untouched.
fn freeDependencies(
    allocator: std.mem.Allocator,
    dependencies: []const PluginConfiguration.Dependency,
) void {
    for (dependencies) |dependency| {
        allocator.free(dependency.id);
        allocator.free(dependency.requirement);
    }
    if (dependencies.len != 0) allocator.free(dependencies);
}

/// Orders dependencies by id for deterministic manifest output.
fn dependencyLessThan(
    _: void,
    left: PluginConfiguration.Dependency,
    right: PluginConfiguration.Dependency,
) bool {
    return std.mem.order(u8, left.id, right.id) == .lt;
}

/// Parses the manifest's optional `[network]` table into a policy.
///
/// A missing table yields the default deny-all policy. Unknown keys inside the
/// table are rejected with `error.KeysNotImplemented`, so a typo cannot
/// silently widen or narrow the policy. `allow` must be an array of strings;
/// `allow_private` must be a boolean; every limit must be an integer that
/// fits its field type and passes `validateValues()`.
///
/// The returned policy and its host strings are owned by `allocator`; release
/// them with `freeNetwork()`.
///
/// Errors: `error.WrongValueType` for a wrong TOML type,
/// `error.KeysNotImplemented` for an unknown key, `error.InvalidValue` for a
/// malformed rule or an out-of-range limit, and `error.OutOfMemory`.
fn parseNetwork(
    allocator: std.mem.Allocator,
    value: ?toml.Value,
) !PluginConfiguration.NetworkPolicy {
    const table_value = value orelse return .{};
    const network_table = switch (table_value) {
        .table => |table| table,
        else => return error.WrongValueType,
    };

    var iterator = network_table.iterator();
    while (iterator.next()) |entry| {
        const known = [_][]const u8{
            "allow",
            "allow_private",
            "max_connections",
            "max_frame_bytes",
            "connect_timeout_ms",
            "io_timeout_ms",
            "poll_timeout_ms",
        };
        var recognized = false;
        for (known) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) recognized = true;
        }
        if (!recognized) return error.KeysNotImplemented;
    }

    var policy: PluginConfiguration.NetworkPolicy = .{};
    errdefer freeNetwork(allocator, policy);

    if (network_table.get("allow")) |allow_value| {
        policy.rules = try parseNetworkRules(allocator, allow_value);
    }
    if (network_table.get("allow_private")) |private_value| {
        policy.allow_private = switch (private_value) {
            .boolean => |flag| flag,
            else => return error.WrongValueType,
        };
    }
    if (network_table.get("max_connections")) |limit_value| {
        policy.max_connections = try parseNetworkInteger(u16, limit_value);
    }
    if (network_table.get("max_frame_bytes")) |limit_value| {
        policy.max_frame_bytes = try parseNetworkInteger(usize, limit_value);
    }
    if (network_table.get("connect_timeout_ms")) |limit_value| {
        policy.connect_timeout_ms = try parseNetworkInteger(u32, limit_value);
    }
    if (network_table.get("io_timeout_ms")) |limit_value| {
        policy.io_timeout_ms = try parseNetworkInteger(u32, limit_value);
    }
    if (network_table.get("poll_timeout_ms")) |limit_value| {
        policy.poll_timeout_ms = try parseNetworkInteger(u32, limit_value);
    }
    return policy;
}

/// Reads one non-negative integer limit of `T`.
///
/// Errors: `error.WrongValueType` when the value is not an integer and
/// `error.InvalidValue` when it is negative or does not fit `T`.
fn parseNetworkInteger(comptime T: type, value: toml.Value) !T {
    const integer = switch (value) {
        .integer => |number| number,
        else => return error.WrongValueType,
    };
    if (integer < 0) return error.InvalidValue;
    return std.math.cast(T, integer) orelse error.InvalidValue;
}

/// Parses `[network].allow` into a rule slice.
///
/// An empty array yields an empty slice without an allocation. Each entry must
/// be a string containing a host, `host:port`, or `[ipv6]:port`, optionally
/// with a leading `*.` wildcard. The returned slice and host strings are owned
/// by `allocator`; release them with `freeNetwork()`.
///
/// Errors: `error.WrongValueType` for a non-array or non-string entry,
/// `error.InvalidValue` for more than `max_network_rules` entries or a
/// malformed rule, and `error.OutOfMemory`.
fn parseNetworkRules(
    allocator: std.mem.Allocator,
    value: toml.Value,
) ![]const PluginConfiguration.NetworkRule {
    const list = switch (value) {
        .array => |array| array,
        else => return error.WrongValueType,
    };
    if (list.items.len == 0) return &.{};
    if (list.items.len > PluginConfiguration.max_network_rules) {
        return error.InvalidValue;
    }

    var rules = try allocator.alloc(PluginConfiguration.NetworkRule, list.items.len);
    var filled: usize = 0;
    errdefer {
        for (rules[0..filled]) |rule| allocator.free(rule.host);
        allocator.free(rules);
    }

    for (list.items) |item| {
        const text = switch (item) {
            .string => |string| string,
            else => return error.WrongValueType,
        };
        const parsed = try parseNetworkRule(text);
        const host = try allocator.dupe(u8, parsed.host);
        errdefer allocator.free(host);
        rules[filled] = .{ .host = host, .port = parsed.port };
        filled += 1;
    }
    return rules;
}

/// Splits one allowlist entry into its host and optional port.
///
/// Supported forms are `host`, `host:port`, `[ipv6]`, and `[ipv6]:port`. A
/// bare IPv6 literal may contain several colons; it is only split when it is
/// bracketed. The returned `host` borrows `text`.
///
/// Errors: `error.InvalidValue` for an empty host, an oversized host, an empty
/// wildcard suffix, an invalid port, or characters that cannot be part of a
/// host name.
fn parseNetworkRule(text: []const u8) error{InvalidValue}!struct {
    host: []const u8,
    port: ?u16,
} {
    if (text.len == 0) return error.InvalidValue;

    var host = text;
    var port: ?u16 = null;

    if (text[0] == '[') {
        const closing = std.mem.indexOfScalar(u8, text, ']') orelse return error.InvalidValue;
        host = text[1..closing];
        const rest = text[closing + 1 ..];
        if (rest.len != 0) {
            if (rest[0] != ':') return error.InvalidValue;
            port = std.fmt.parseUnsigned(u16, rest[1..], 10) catch
                return error.InvalidValue;
        }
    } else {
        const colon_count = std.mem.count(u8, text, ":");
        if (colon_count == 1) {
            const colon = std.mem.indexOfScalar(u8, text, ':').?;
            host = text[0..colon];
            port = std.fmt.parseUnsigned(u16, text[colon + 1 ..], 10) catch
                return error.InvalidValue;
        }
    }

    if (host.len == 0 or host.len > PluginConfiguration.max_network_host_len) {
        return error.InvalidValue;
    }
    for (host) |byte| {
        if (byte == 0 or byte == '/' or byte == ' ' or byte == '\t' or byte == '\n') {
            return error.InvalidValue;
        }
    }
    if (std.mem.eql(u8, host, "*.")) return error.InvalidValue;
    return .{ .host = host, .port = port };
}

/// Releases a policy produced by `parseNetwork()`.
///
/// The default policy and an empty `allow` array carry no allocation and are
/// left untouched.
fn freeNetwork(allocator: std.mem.Allocator, policy: PluginConfiguration.NetworkPolicy) void {
    for (policy.rules) |rule| allocator.free(rule.host);
    if (policy.rules.len != 0) allocator.free(policy.rules);
}

/// Returns whether `id` consists only of ASCII letters, digits, `_` and `-`.
fn isValidId(id: []const u8) bool {
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') {
            return false;
        }
    }
    return true;
}

/// Validates a manifest library path that is relative to the plugin
/// directory.
///
/// The path must be non-empty, at most `PluginConfiguration.max_path_len`
/// bytes, relative (no leading `/`), free of `..` components, and end in
/// `.so`. A leading `./` is allowed.
///
/// Errors: `error.InvalidValue` when any rule is violated.
fn validateLibraryPath(path: []const u8) !void {
    if (path.len == 0 or path.len > PluginConfiguration.max_path_len) {
        return error.InvalidValue;
    }
    if (path[0] == '/' or !std.mem.endsWith(u8, path, ".so")) {
        return error.InvalidValue;
    }

    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) {
            return error.InvalidValue;
        }
    }
}

/// Validates a manifest Lua script path that is relative to the plugin
/// directory.
///
/// The path must be non-empty, at most `PluginConfiguration.max_script_len`
/// bytes, relative (no leading `/`), free of `..` components, and end in
/// `.lua`. A leading `./` is allowed.
///
/// Errors: `error.InvalidValue` when any rule is violated.
fn validateScriptPath(path: []const u8) !void {
    if (path.len == 0 or path.len > PluginConfiguration.max_script_len) {
        return error.InvalidValue;
    }
    if (path[0] == '/' or !std.mem.endsWith(u8, path, ".lua")) {
        return error.InvalidValue;
    }

    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) {
            return error.InvalidValue;
        }
    }
}

/// Reads all keys of a TOML text, starting at `node`, into a
/// callee-defined struct type.
///
/// The function parses `raw_toml` and maps the table addressed by `node`
/// into `T` via zig-toml's struct mapping, exactly like
/// `toml.Parser(T).parseString` maps a root table into `T`; the difference
/// is that with `node` set, the mapped table is the sub-table introduced
/// by that TOML header (for `node = "classes"` the body of a `[classes]`
/// header; only a single header path segment is supported), whereas
/// `node = null` maps the keys carried before any header declaration.
///
/// `T` must be a struct whose field names match the keys of the mapped
/// table and whose field types are supported by zig-toml's mapping
/// (strings, integers, floats, booleans, datetimes, arrays, nested
/// mappings; fields with a default value or of optional type may miss).
///
/// Parameters:
/// - `T`: the callee-defined struct type the selected keys are mapped into.
/// - `raw_toml`: the full TOML text to parse.
/// - `node`: the header whose body is mapped into `T`, or `null` for the
///   header-less part of the file (the "root" table).
///
/// Returns the mapped instance of `T`, or:
/// - `error.NodeNotFound` if `node` names no key of the parsed file, or
///   if the key it names does not introduce a table body to map into `T`.
/// - `error.MissingRequiredField`, `error.InvalidValueType`,
///   `error.OutOfMemory` and any other error zig-toml's struct mapping
///   or TOML parser can produce (see `toml.Parser(T).parseString` and
///   `toml.Parser(T).parseStringIntoNode`).
///
/// Memory: `T`'s mappings reference an arena kept (`Parsed(T).arena`)
/// intact on success so the returned value's slices stay valid for the rest
/// of the process' lifetime; on any error return, the arena is fully
/// released. The arena is therefore intentionally leaked, and callers must
/// keep using this helper only for the bounded set of startup-time files it
/// was written for. Use `PluginConfiguration.parseConfig()` when owned,
/// releasable strings are required.
pub fn readToml(comptime T: type, raw_toml: []const u8, node: ?[]const u8) !T {
    var parser = toml.Parser(T).init(std.heap.page_allocator);
    defer parser.deinit();

    const parsed = if (node) |node_key|
        try parser.parseStringIntoNode(raw_toml, node_key)
    else
        try parser.parseString(raw_toml);

    // `parsed.value`'s slices live in `parsed.arena`; the arena is never
    // deinit'd on this success path, see the memory note above.
    const result = parsed.value;
    return result;
}

test "parseConfig parses fully correct TOML" {
    const source =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
        \\
        \\# Both comments and blank lines are fine.
        \\# All exactly five keys must be present.
    ;
    var config = try PluginConfiguration.parseConfig(std.testing.allocator, source);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", config.id);
    try std.testing.expectEqualStrings("Hello Example", config.name);
    try std.testing.expectEqualStrings("0.1.0", config.version);
    try std.testing.expectEqualStrings("Zorcerer", config.author);
    try std.testing.expectEqualStrings("./hello_plugin.so", config.path.?);
    try std.testing.expectEqual(@as(usize, 0), config.dependencies.len);
}

test "parseConfig parses an optional dependency table" {
    const source =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "1.2.3"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
        \\
        \\[dependencies]
        \\util = "~0.4.3"
        \\core = "^1.2.0"
        \\anything = "*"
    ;
    var config = try PluginConfiguration.parseConfig(std.testing.allocator, source);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), config.dependencies.len);
    // Entries are sorted by id for deterministic processing.
    try std.testing.expectEqualStrings("anything", config.dependencies[0].id);
    try std.testing.expectEqualStrings("*", config.dependencies[0].requirement);
    try std.testing.expectEqualStrings("core", config.dependencies[1].id);
    try std.testing.expectEqualStrings("^1.2.0", config.dependencies[1].requirement);
    try std.testing.expectEqualStrings("util", config.dependencies[2].id);
    try std.testing.expectEqualStrings("~0.4.3", config.dependencies[2].requirement);
}

test "parseConfig rejects malformed dependency tables" {
    const wrong_type =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "1.2.3"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
        \\dependencies = ["core"]
    ;
    try std.testing.expectError(
        error.WrongValueType,
        PluginConfiguration.parseConfig(std.testing.allocator, wrong_type),
    );

    const wrong_entry_type =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "1.2.3"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
        \\
        \\[dependencies]
        \\core = 1
    ;
    try std.testing.expectError(
        error.WrongValueType,
        PluginConfiguration.parseConfig(std.testing.allocator, wrong_entry_type),
    );

    const invalid_requirement =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "1.2.3"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
        \\
        \\[dependencies]
        \\core = "not a version"
    ;
    try std.testing.expectError(
        error.InvalidValue,
        PluginConfiguration.parseConfig(std.testing.allocator, invalid_requirement),
    );

    const invalid_id =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "1.2.3"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
        \\
        \\[dependencies]
        \\"bad/id" = "1.0.0"
    ;
    try std.testing.expectError(
        error.InvalidValue,
        PluginConfiguration.parseConfig(std.testing.allocator, invalid_id),
    );

    const self_dependency =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "1.2.3"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
        \\
        \\[dependencies]
        \\hello = "1.0.0"
    ;
    try std.testing.expectError(
        error.InvalidValue,
        PluginConfiguration.parseConfig(std.testing.allocator, self_dependency),
    );
}

test "parseConfig requires semantic versions" {
    const source =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "1.2"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
    ;
    try std.testing.expectError(
        error.InvalidValue,
        PluginConfiguration.parseConfig(std.testing.allocator, source),
    );
}

test "validateValues rejects duplicate dependencies" {
    const config = PluginConfiguration{
        .id = "hello",
        .name = "Hello Example",
        .version = "1.2.3",
        .author = "Zorcerer",
        .path = "./hello_plugin.so",
        .dependencies = &.{
            .{ .id = "core", .requirement = "^1.0.0" },
            .{ .id = "core", .requirement = "^2.0.0" },
        },
    };
    try std.testing.expectError(error.InvalidValue, config.validateValues());
}

test "parseConfig fails on partially implemented keys" {
    // `parseConfig` warns about every unknown key before failing. That
    // warning is expected here; raise the log threshold so it does not reach
    // the test runner's stderr, where the build runner reports child output
    // even for otherwise successful steps.
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;

    // `plugin_id` and `name` are implemented, but `compression` is not a
    // field of `PluginConfiguration`.
    const source =
        \\id = "hello"
        \\name = "Hello Example"
        \\compression = "nope"
    ;
    try std.testing.expectError(
        error.KeysNotImplemented,
        PluginConfiguration.parseConfig(std.testing.allocator, source),
    );
}

test "parseConfig fails on wrong value types" {
    // `version` and `author` are implemented keys, but carry values that are
    // not TOML strings.
    const source =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = 1
        \\author = true
        \\path = "./hello_plugin.so"
    ;
    try std.testing.expectError(
        error.WrongValueType,
        PluginConfiguration.parseConfig(std.testing.allocator, source),
    );
}

test "parseConfig fails on missing keys" {
    // `name` is required; `path` and `script` are optional.
    const source =
        \\id = "hello"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
    ;
    try std.testing.expectError(
        error.MissingRequiredField,
        PluginConfiguration.parseConfig(std.testing.allocator, source),
    );
}

test "parseConfig rejects invalid values" {
    const allocator = std.testing.allocator;

    const empty_id =
        \\id = ""
        \\name = "Hello Example"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
    ;
    try std.testing.expectError(error.InvalidValue, PluginConfiguration.parseConfig(allocator, empty_id));

    const invalid_id =
        \\id = "hello/world"
        \\name = "Hello Example"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
    ;
    try std.testing.expectError(error.InvalidValue, PluginConfiguration.parseConfig(allocator, invalid_id));

    const empty_name =
        \\id = "hello"
        \\name = ""
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
    ;
    try std.testing.expectError(error.InvalidValue, PluginConfiguration.parseConfig(allocator, empty_name));

    const absolute_path =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "/absolute/hello_plugin.so"
    ;
    try std.testing.expectError(error.InvalidValue, PluginConfiguration.parseConfig(allocator, absolute_path));

    const parent_path =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "../hello_plugin.so"
    ;
    try std.testing.expectError(error.InvalidValue, PluginConfiguration.parseConfig(allocator, parent_path));

    const non_library_path =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.txt"
    ;
    try std.testing.expectError(error.InvalidValue, PluginConfiguration.parseConfig(allocator, non_library_path));
}

test "parseConfig rejects oversized manifests" {
    try std.testing.expectError(
        error.FileSizeOverflow,
        PluginConfiguration.parseConfig(
            std.testing.allocator,
            "a" ** (PluginConfiguration.max_config_size + 1),
        ),
    );
}

test "parseConfig accepts manifests up to max_config_size" {
    // A manifest consisting only of comments and exactly `max_config_size`
    // bytes long: the size check passes, then the manifest fails on its
    // missing required fields (not on its size).
    const source = "#" ++ "x" ** (PluginConfiguration.max_config_size - 2) ++ "\n";
    try std.testing.expectEqual(PluginConfiguration.max_config_size, source.len);
    try std.testing.expectError(
        error.MissingRequiredField,
        PluginConfiguration.parseConfig(std.testing.allocator, source),
    );
}

test "validateForDirectory requires the id to match the directory" {
    const source =
        \\id = "hello"
        \\name = "Hello Example"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./hello_plugin.so"
    ;
    var config = try PluginConfiguration.parseConfig(std.testing.allocator, source);
    defer config.deinit(std.testing.allocator);

    try config.validateForDirectory("hello");
    try std.testing.expectError(error.InvalidValue, config.validateForDirectory("other"));
}

test "known_keys covers every field of the struct" {
    // Every field must be exactly matched by one `known_keys` entry, and
    // the count must match too, so neither list can silently drift from
    // the other (guards the struct's invariant).
    inline for (std.meta.fields(PluginConfiguration), 0..) |field, ix| {
        var covered = false;
        inline for (PluginConfiguration.known_keys) |key| {
            covered = covered or std.mem.eql(u8, key, field.name);
        }
        try std.testing.expect(covered);

        // Every entry appears at most once, so this index search finds
        // exactly the field it corresponds to.
        inline for (PluginConfiguration.known_keys, 0..) |key, key_ix| {
            if (std.mem.eql(u8, key, field.name)) {
                try std.testing.expectEqual(ix, key_ix);
            }
        }
    }
    try std.testing.expectEqual(
        PluginConfiguration.known_keys.len,
        std.meta.fields(PluginConfiguration).len,
    );
}

test "readToml maps the keys under a header into the callee struct" {
    const Classes = struct {
        killer: []const u8,
        hp: i64,
    };
    const classes = try readToml(
        Classes,
        \\[classes]
        \\killer = "sniper"
        \\hp = 125
        \\
        \\[other]
        \\noise = true
    ,
        "classes",
    );
    try std.testing.expectEqualStrings("sniper", classes.killer);
    try std.testing.expectEqual(@as(i64, 125), classes.hp);
}

test "readToml maps header-less keys when node is null" {
    const Root = struct {
        a: []const u8,
        b: i64,
    };
    const root = try readToml(
        Root,
        \\a = "value"
        \\b = 7
        \\
        \\[later]
        \\ignored = true
    ,
        null,
    );
    try std.testing.expectEqualStrings("value", root.a);
    try std.testing.expectEqual(@as(i64, 7), root.b);
}

test "readToml fails on a missing or non-table node" {
    const Empty = struct {};
    try std.testing.expectError(
        error.NodeNotFound,
        readToml(Empty, "a = 1", "missing"),
    );
    try std.testing.expectError(
        error.NodeNotFound,
        readToml(Empty, "[t]\nx = 1\n", "a"),
    );
}

test "parseConfig accepts a script-only manifest" {
    const source =
        \\id = "scripted"
        \\name = "Scripted"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\script = "./main.lua"
    ;
    var config = try PluginConfiguration.parseConfig(std.testing.allocator, source);
    defer config.deinit(std.testing.allocator);

    try std.testing.expect(config.path == null);
    try std.testing.expectEqualStrings("./main.lua", config.script.?);
    try std.testing.expect(!config.isNative());
}

test "parseConfig requires path or script" {
    const source =
        \\id = "empty"
        \\name = "Empty"
        \\version = "0.1.0"
        \\author = "Zorcerer"
    ;
    try std.testing.expectError(
        error.InvalidValue,
        PluginConfiguration.parseConfig(std.testing.allocator, source),
    );
}

test "parseConfig rejects an invalid script path" {
    const source =
        \\id = "scripted"
        \\name = "Scripted"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\script = "../escape.lua"
    ;
    try std.testing.expectError(
        error.InvalidValue,
        PluginConfiguration.parseConfig(std.testing.allocator, source),
    );
}

test "parseConfig parses the optional network policy" {
    const source =
        \\id = "networked"
        \\name = "Networked"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\script = "./main.lua"
        \\
        \\[network]
        \\allow = ["example.com", "*.example.org", "127.0.0.1:27015", "[::1]:27016"]
        \\allow_private = true
        \\max_connections = 2
        \\max_frame_bytes = 4096
        \\connect_timeout_ms = 1500
        \\io_timeout_ms = 500
        \\poll_timeout_ms = 5
    ;
    var config = try PluginConfiguration.parseConfig(std.testing.allocator, source);
    defer config.deinit(std.testing.allocator);

    try std.testing.expect(config.network.allow_private);
    try std.testing.expectEqual(@as(u16, 2), config.network.max_connections);
    try std.testing.expectEqual(@as(usize, 4096), config.network.max_frame_bytes);
    try std.testing.expectEqual(@as(u32, 1500), config.network.connect_timeout_ms);
    try std.testing.expectEqual(@as(u32, 500), config.network.io_timeout_ms);
    try std.testing.expectEqual(@as(u32, 5), config.network.poll_timeout_ms);
    try std.testing.expectEqual(@as(usize, 4), config.network.rules.len);

    try std.testing.expect(config.network.allows("example.com", 80));
    try std.testing.expect(config.network.allows("EXAMPLE.COM", 443));
    try std.testing.expect(config.network.allows("a.example.org", 80));
    try std.testing.expect(!config.network.allows("example.org", 80));
    try std.testing.expect(config.network.allows("a.b.example.org", 80));
    try std.testing.expect(config.network.allows("127.0.0.1", 27015));
    try std.testing.expect(!config.network.allows("127.0.0.1", 27016));
}

test "parseConfig defaults to a deny-all network policy" {
    const source =
        \\id = "closed"
        \\name = "Closed"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./closed.so"
    ;
    var config = try PluginConfiguration.parseConfig(std.testing.allocator, source);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), config.network.rules.len);
    try std.testing.expect(!config.network.allow_private);
    try std.testing.expect(!config.network.allows("example.com", 80));
}

test "parseConfig rejects malformed network tables" {
    const unknown_key =
        \\id = "networked"
        \\name = "Networked"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./networked.so"
        \\
        \\[network]
        \\allow_all = true
    ;
    try std.testing.expectError(
        error.KeysNotImplemented,
        PluginConfiguration.parseConfig(std.testing.allocator, unknown_key),
    );

    const wrong_allow_type =
        \\id = "networked"
        \\name = "Networked"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./networked.so"
        \\
        \\[network]
        \\allow = "example.com"
    ;
    try std.testing.expectError(
        error.WrongValueType,
        PluginConfiguration.parseConfig(std.testing.allocator, wrong_allow_type),
    );

    const bad_rule =
        \\id = "networked"
        \\name = "Networked"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./networked.so"
        \\
        \\[network]
        \\allow = ["example.com:not-a-port"]
    ;
    try std.testing.expectError(
        error.InvalidValue,
        PluginConfiguration.parseConfig(std.testing.allocator, bad_rule),
    );

    const out_of_range =
        \\id = "networked"
        \\name = "Networked"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\path = "./networked.so"
        \\
        \\[network]
        \\max_connections = 1000
    ;
    try std.testing.expectError(
        error.InvalidValue,
        PluginConfiguration.parseConfig(std.testing.allocator, out_of_range),
    );
}
