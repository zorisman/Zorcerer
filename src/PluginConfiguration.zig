//! Configuration of a single plugin as it appears in the plugin's `.toml`
//! manifest file. Provides `PluginConfiguration.parseConfig()` to turn the
//! raw TOML text of such a manifest into a validated `PluginConfiguration`,
//! and generic helpers to read arbitrary TOML (see `readToml()`).

const std = @import("std");
const toml = @import("toml");

/// A single plugin's configuration, parsed from its manifest TOML file.
///
/// Invariant: every field must correspond to a top-level key of the
/// manifest, and every top-level manifest key must correspond to a field of
/// this struct; a superfluous key in the manifest is treated as an unknown
/// (not implemented) key.
///
/// Slices: each field points into memory parsed and owned by
/// `parseConfig()`, see its documentation for lifetime details.
pub const PluginConfiguration = struct {
    /// Hard upper limit on the raw TOML text size of a manifest that
    /// `parseConfig()` accepts: 4 KiB. Manifests that exceed it are
    /// rejected with `error.FileSizeOverflow`.
    pub const max_config_size: usize = 4 * 1024;

    /// Every key that is allowed to appear (as a top-level key) inside a
    /// manifest's TOML file; each entry must correspond 1:1 to a field of
    /// this struct, see the struct's invariant above. Any parsed manifest
    /// that carries a key not listed here is rejected with
    /// `error.KeysNotImplemented`.
    pub const known_keys: []const []const u8 = &.{
        "plugin_id",
        "name",
        "version",
        "author",
        "lib_path",
    };

    /// Unique identifier of the plugin, also the name of the directory the
    /// plugin is loaded from.
    plugin_id: []const u8,
    /// Human-readable display name of the plugin.
    name: []const u8,
    /// Version string of the plugin in the author's chosen format.
    version: []const u8,
    /// Author string of the plugin, in the author's chosen format.
    author: []const u8,
    /// Path to the plugin's `.so` library, relative to the plugin directory.
    lib_path: []const u8,

    /// Parses the raw TOML text of a plugin manifest into a
    /// `PluginConfiguration`.
    ///
    /// Every top-level key must be a field of this struct and every field
    /// must be a top-level string value; otherwise an error is returned and
    /// the configuration cannot be used.
    ///
    /// Errors:
    /// - `error.FileSizeOverflow` if the manifest text is larger than
    ///   `max_config_size` (4 KiB).
    /// - `error.KeysNotImplemented` if the manifest contains a top-level key
    ///   that has no corresponding field in this struct.
    /// - `error.WrongValueType` if a known key's value is not a TOML string.
    /// - `error.MissingRequiredField` if a known key is absent entirely.
    /// - Any error the TOML parser itself can report for malformed input
    ///   (see `toml.Parser(Table).parseString`).
    ///
    /// Side effects: before failing with `error.KeysNotImplemented`, every
    /// unknown key is reported to the user with `std.log.warn`; the
    /// failure is not otherwise observable via `error_info` or the like,
    /// since keys are known only from the manifest text.
    ///
    /// No allocator is passed: `parseConfig` parses into an arena whose
    /// memory is intentionally retained on success so that the returned
    /// strings stay valid for the rest of the process' lifetime. Plugin
    /// configuration is read once at startup, so this trade is deemed
    /// appropriate; on error the arena is fully released.
    pub fn parseConfig(toml_text: []const u8) !@This() {
        if (toml_text.len > max_config_size) {
            return error.FileSizeOverflow;
        }

        // Parsing into the raw table (`toml.Table`) is deliberate:
        // `toml.Parser(Table)` on a mapped struct silently drops
        // superfluous manifest keys, while `parseConfig` must reject them
        // with `error.KeysNotImplemented`.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();

        var parser = toml.Parser(toml.Table).init(arena.allocator());
        defer parser.deinit();

        const parsed = try parser.parseString(toml_text);
        const table = parsed.value;

        // Reject every manifest key that the struct does not have a field
        // for; zig-toml's struct mapping would silently drop them. All
        // unknown keys are collected first so the user can be told about
        // every problem in one go, not only about the first one.
        var unknown_keys: std.ArrayList([]const u8) = .empty;
        var it = table.iterator();
        while (it.next()) |entry| {
            var known = false;
            for (known_keys) |key| {
                if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                    known = true;
                    break;
                }
            }
            if (!known) try unknown_keys.append(arena.allocator(), entry.key_ptr.*);
        }
        if (unknown_keys.items.len != 0) {
            for (unknown_keys.items) |key| {
                std.log.warn("unknown manifest key: {s}", .{key});
            }
            return error.KeysNotImplemented;
        }

        var result: @This() = undefined;
        inline for (std.meta.fields(@This())) |field| {
            const value = table.get(field.name) orelse return error.MissingRequiredField;
            switch (value) {
                .string => |str| @field(result, field.name) = str,
                else => return error.WrongValueType,
            }
        }
        return result;
    }
};

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
/// Memory: like `parseConfig()`, `T`'s mappings reference an arena kept
/// (`Parsed(T).arena`) intact on success so the returned value's slices
/// stay valid for the rest of the process' lifetime; on any error return,
/// the arena is fully released. This is the same trade `parseConfig()`
/// makes and expects bounded callers accordingly (config is read once at
/// startup).
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
    const config = try PluginConfiguration.parseConfig(
        \\plugin_id = "hello"
        \\name = "Hello Example"
        \\version = "0.1.0"
        \\author = "Zorcerer"
        \\lib_path = "plugins/hello/hello_plugin.so"
        \\
        \\# Both comments and blank lines are fine.
        \\# All exactly five keys must be present.
    );

    try std.testing.expectEqualStrings("hello", config.plugin_id);
    try std.testing.expectEqualStrings("Hello Example", config.name);
    try std.testing.expectEqualStrings("0.1.0", config.version);
    try std.testing.expectEqualStrings("Zorcerer", config.author);
    try std.testing.expectEqualStrings("plugins/hello/hello_plugin.so", config.lib_path);
}

test "parseConfig fails on partially implemented keys" {
    // `plugin_id` and `name` are implemented, but `compression` is not a
    // field of `PluginConfiguration`.
    const source =
        \\plugin_id = "hello"
        \\name = "Hello Example"
        \\compression = "nope"
    ;
    try std.testing.expectError(error.KeysNotImplemented, PluginConfiguration.parseConfig(source));
}

test "parseConfig fails on wrong value types" {
    // `version` and `author` are implemented keys, but carry values that are
    // not TOML strings.
    const source =
        \\plugin_id = "hello"
        \\name = "Hello Example"
        \\version = 1
        \\author = true
        \\lib_path = "plugins/hello/hello_plugin.so"
    ;
    try std.testing.expectError(error.WrongValueType, PluginConfiguration.parseConfig(source));
}

test "parseConfig rejects oversized manifests" {
    try std.testing.expectError(
        error.FileSizeOverflow,
        PluginConfiguration.parseConfig("a" ** (PluginConfiguration.max_config_size + 1)),
    );
}

test "parseConfig accepts manifests up to max_config_size" {
    // A manifest consisting only of comments and exactly `max_config_size`
    // bytes long: the size check passes, then the manifest fails on its
    // missing required fields (not on its size).
    const source = "#" ++ "x" ** (PluginConfiguration.max_config_size - 2) ++ "\n";
    try std.testing.expectEqual(PluginConfiguration.max_config_size, source.len);
    try std.testing.expectError(error.MissingRequiredField, PluginConfiguration.parseConfig(source));
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
