//! Build-time generator for EngineIndexes.generated.zig.
//!
//! Supported TOML-like forms:
//!
//!   ["class::IVEngineServer"]
//!   ChangeTeam = 97
//!
//! or flat keys:
//!
//!   "IVEngineServer::ChangeTeam" = 97
//!
//! Global constants use:
//!
//!   ["global::Variables"]
//!   CVAR_INTERFACE_VERSION = "VEngineCvar004"
//!
//! Global values are emitted as top-level Zig constants, not as a struct.
//! The flat-key parser also accepts unquoted keys, even though TOML keys
//! containing ':' should be quoted by a TOML parser.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Method = struct {
    name: []const u8,
    index: usize,
};

const Class = struct {
    name: []const u8,
    methods: ArrayList(Method) = .empty,
};

const GlobalVariable = struct {
    name: []const u8,
    value: []const u8,
    is_string: bool,
};

const whitespace = " \t\r\n";

/// Parse the supported index-file format and return Zig source code.
/// The caller owns the returned slice.
pub fn generate(allocator: Allocator, source: []const u8) ![]u8 {
    var classes: ArrayList(Class) = .empty;
    defer {
        for (classes.items) |*class| class.methods.deinit(allocator);
        classes.deinit(allocator);
    }

    var global_variables: ArrayList(GlobalVariable) = .empty;
    defer global_variables.deinit(allocator);

    var current_class: ?[]const u8 = null;
    var current_section_is_global = false;
    var lines = std.mem.splitScalar(u8, source, '\n');

    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, whitespace);
        if (line.len == 0) continue;

        // The input format only uses '#' for comments, not inside names/values.
        if (std.mem.indexOfScalar(u8, line, '#')) |comment_at| {
            line = std.mem.trim(u8, line[0..comment_at], whitespace);
            if (line.len == 0) continue;
        }

        if (line[0] == '[' and line[line.len - 1] == ']') {
            var section = std.mem.trim(u8, line[1 .. line.len - 1], whitespace);
            section = unquote(section);
            if (std.mem.startsWith(u8, section, "class::")) {
                section = section["class::".len..];
                if (!isZigIdentifier(section)) return error.InvalidClassName;
                current_class = section;
                current_section_is_global = false;
                try ensureClass(allocator, &classes, section);
            } else if (std.mem.startsWith(u8, section, "global::")) {
                current_class = null;
                current_section_is_global = true;
            } else {
                if (!isZigIdentifier(section)) return error.InvalidClassName;
                current_class = section;
                current_section_is_global = false;
                try ensureClass(allocator, &classes, section);
            }
            continue;
        }

        const equals_at = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.InvalidAssignment;
        var key = std.mem.trim(u8, line[0..equals_at], whitespace);
        const value_text = std.mem.trim(u8, line[equals_at + 1 ..], whitespace);
        key = unquote(key);
        if (key.len == 0 or value_text.len == 0) return error.InvalidAssignment;

        var class_name: ?[]const u8 = null;
        var member_name: []const u8 = undefined;
        var is_global = current_section_is_global;
        if (std.mem.indexOf(u8, key, "::")) |separator| {
            class_name = std.mem.trim(u8, key[0..separator], whitespace);
            member_name = std.mem.trim(u8, key[separator + 2 ..], whitespace);
            class_name = unquote(class_name.?);
            member_name = unquote(member_name);
            if (std.mem.eql(u8, class_name.?, "global")) {
                is_global = true;
            } else {
                is_global = false;
            }
        } else {
            member_name = key;
            if (!is_global) class_name = current_class orelse return error.MethodWithoutClass;
        }

        if (!isZigIdentifier(member_name)) return error.InvalidMethodName;
        const snake_name = try toSnakeCase(allocator, member_name);
        defer allocator.free(snake_name);
        if (!isZigIdentifier(snake_name)) {
            if (is_global) return error.InvalidGeneratedGlobalName;
            return error.InvalidGeneratedMethodName;
        }

        if (is_global) {
            const is_string = value_text.len >= 2 and
                value_text[0] == '"' and value_text[value_text.len - 1] == '"';
            const value = if (is_string) unquote(value_text) else value_text;
            if (!is_string) {
                _ = std.fmt.parseInt(usize, value, 10) catch return error.InvalidGlobalValue;
            }
            try putGlobalVariable(allocator, &global_variables, member_name, value, is_string);
            continue;
        }

        const index = std.fmt.parseInt(usize, value_text, 10) catch
            return error.InvalidIndex;
        const actual_class_name = class_name orelse return error.MethodWithoutClass;
        if (!isZigIdentifier(actual_class_name)) return error.InvalidClassName;
        try putMethod(allocator, &classes, actual_class_name, member_name, index);
    }

    var output: ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator,
        "// Generated by EngineIndexesGenerator.zig. Do not edit manually.\n\n",
    );

    for (global_variables.items, 0..) |variable, variable_index| {
        const snake_name = try toSnakeCase(allocator, variable.name);
        defer allocator.free(snake_name);

        for (global_variables.items[0..variable_index]) |previous| {
            const previous_snake = try toSnakeCase(allocator, previous.name);
            defer allocator.free(previous_snake);
            if (std.mem.eql(u8, snake_name, previous_snake)) {
                return error.DuplicateGeneratedGlobalName;
            }
        }

        if (variable.is_string) {
            try appendFmt(allocator, &output,
                "pub const {s}: []const u8 = \"", .{snake_name});
            try appendZigEscapedString(allocator, &output, variable.value);
            try output.appendSlice(allocator, "\";\n");
        } else {
            try appendFmt(allocator, &output,
                "pub const {s}: usize = {s};\n", .{ snake_name, variable.value });
        }
    }
    if (global_variables.items.len != 0) try output.append(allocator, '\n');

    for (classes.items) |class| {
        try appendFmt(allocator, &output, "pub const {s} = struct {{\n", .{class.name});

        for (class.methods.items, 0..) |method, method_index| {
            const snake_name = try toSnakeCase(allocator, method.name);
            defer allocator.free(snake_name);

            // Prevent two source names such as "ChangeTeam" and "change_team"
            // from silently producing duplicate Zig declarations.
            for (class.methods.items[0..method_index]) |previous| {
                const previous_snake = try toSnakeCase(allocator, previous.name);
                defer allocator.free(previous_snake);
                if (std.mem.eql(u8, snake_name, previous_snake)) {
                    return error.DuplicateGeneratedMethodName;
                }
            }

            try appendFmt(
                allocator,
                &output,
                "    pub const {s}: usize = {d};\n",
                .{ snake_name, method.index },
            );
        }

        try output.appendSlice(allocator, "};\n\n");
    }

    return output.toOwnedSlice(allocator);
}

fn ensureClass(
    allocator: Allocator,
    classes: *ArrayList(Class),
    class_name: []const u8,
) !void {
    for (classes.items) |class| {
        if (std.mem.eql(u8, class.name, class_name)) return;
    }
    try classes.append(allocator, .{ .name = class_name });
}

fn putMethod(
    allocator: Allocator,
    classes: *ArrayList(Class),
    class_name: []const u8,
    method_name: []const u8,
    index: usize,
) !void {
    var class_index: ?usize = null;
    for (classes.items, 0..) |class, i| {
        if (std.mem.eql(u8, class.name, class_name)) {
            class_index = i;
            break;
        }
    }

    if (class_index == null) {
        try classes.append(allocator, .{ .name = class_name });
        class_index = classes.items.len - 1;
    }

    const class = &classes.items[class_index.?];
    for (class.methods.items) |*method| {
        if (std.mem.eql(u8, method.name, method_name)) {
            // Last value wins if the same method appears more than once.
            method.index = index;
            return;
        }
    }

    try class.methods.append(allocator, .{ .name = method_name, .index = index });
}

fn putGlobalVariable(
    allocator: Allocator,
    variables: *ArrayList(GlobalVariable),
    name: []const u8,
    value: []const u8,
    is_string: bool,
) !void {
    for (variables.items) |*variable| {
        if (std.mem.eql(u8, variable.name, name)) {
            variable.value = value;
            variable.is_string = is_string;
            return;
        }
    }
    try variables.append(allocator, .{
        .name = name,
        .value = value,
        .is_string = is_string,
    });
}

fn appendZigEscapedString(
    allocator: Allocator,
    output: *ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |character| {
        switch (character) {
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '"' => try output.appendSlice(allocator, "\\\""),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            else => try output.append(allocator, character),
        }
    }
}

fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
        return text[1 .. text.len - 1];
    }
    return text;
}

fn isZigIdentifier(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, "_")) return false;

    for (name, 0..) |character, i| {
        const is_alpha = (character >= 'a' and character <= 'z') or
            (character >= 'A' and character <= 'Z') or character == '_';
        const is_digit = character >= '0' and character <= '9';
        if (i == 0) {
            if (!is_alpha) return false;
        } else if (!is_alpha and !is_digit) {
            return false;
        }
    }

    return !isKeyword(name);
}

fn isKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "addrspace", "align", "allowzero", "and", "anyframe", "anytype",
        "asm", "async", "await", "break", "callconv", "catch", "comptime",
        "const", "continue", "defer", "else", "enum", "errdefer", "error",
        "export", "extern", "false", "fn", "for", "if", "inline", "linksection",
        "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed",
        "pub", "resume", "return", "struct", "suspend", "switch", "test",
        "threadlocal", "true", "try", "undefined", "unreachable", "usingnamespace",
        "var", "volatile", "while",
    };

    inline for (keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return true;
    }
    return false;
}

fn toSnakeCase(allocator: Allocator, name: []const u8) ![]u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (name, 0..) |character, i| {
        const previous = if (i == 0) 0 else name[i - 1];
        const next = if (i + 1 == name.len) 0 else name[i + 1];
        const is_upper = character >= 'A' and character <= 'Z';
        const previous_is_lower_or_digit =
            (previous >= 'a' and previous <= 'z') or
            (previous >= '0' and previous <= '9');
        const acronym_boundary =
            previous >= 'A' and previous <= 'Z' and
            next >= 'a' and next <= 'z';

        if (i != 0 and is_upper and (previous_is_lower_or_digit or acronym_boundary)) {
            try result.append(allocator, '_');
        }

        const lower = if (is_upper) character + ('a' - 'A') else character;
        try result.append(allocator, lower);
    }

    return result.toOwnedSlice(allocator);
}

fn appendFmt(
    allocator: Allocator,
    output: *ArrayList(u8),
    comptime format: []const u8,
    args: anytype,
) !void {
    const formatted = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(formatted);
    try output.appendSlice(allocator, formatted);
}

// The parser deliberately supports only the small subset used by the index file.
test "generate from a class table" {
    const source =
        "[\"class::IVEngineServer\"]\n" ++
        "ChangeTeam = 97\n" ++
        "GetURL = 12\n";

    const generated = try generate(std.testing.allocator, source);
    defer std.testing.allocator.free(generated);

    try std.testing.expect(std.mem.indexOf(u8, generated,
        "pub const IVEngineServer = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated,
        "pub const change_team: usize = 97;") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated,
        "pub const get_url: usize = 12;") != null);
}

test "generate from flat keys" {
    const source = "\"IVEngineServer::ChangeTeam\" = 97\n";
    const generated = try generate(std.testing.allocator, source);
    defer std.testing.allocator.free(generated);

    try std.testing.expect(std.mem.indexOf(u8, generated,
        "pub const change_team: usize = 97;") != null);
}


test "generate global string constants" {
    const source =
        "[\"global::Variables\"]\n" ++
        "CVAR_INTERFACE_VERSION = \"VEngineCvar004\"\n";

    const generated = try generate(std.testing.allocator, source);
    defer std.testing.allocator.free(generated);

    try std.testing.expect(std.mem.indexOf(u8, generated,
        "pub const cvar_interface_version: []const u8 = \"VEngineCvar004\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated,
        "pub const Variables = struct {") == null);
}

test "generate flat global keys" {
    const source = "\"global::CVAR_INTERFACE_VERSION\" = \"VEngineCvar004\"\n";
    const generated = try generate(std.testing.allocator, source);
    defer std.testing.allocator.free(generated);

    try std.testing.expect(std.mem.indexOf(u8, generated,
        "pub const cvar_interface_version: []const u8 = \"VEngineCvar004\";") != null);
}
