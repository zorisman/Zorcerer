//! Build-time generator for src/codegen_generated/engine_indexes.zig.
//! `build.zig` invokes it through `AnalyzerDataAdapter.intoEngineIndexes`
//! after the C++ analyzer reports its results; no intermediate TOML file
//! is involved. `generateFromAnalysis` accepts typed analyzer rows and
//! renders them into the flat-key form parsed by `generate`.
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
//! Enumerator tables use:
//!
//!   [enum::IN_BUTTONS]
//!   FIRST = 1
//!
//! and emit an `isize` member inside a struct named after the enum.
//! Global values are emitted as top-level Zig constants, not as a struct.
//! The flat-key parser also accepts unquoted keys, even though TOML keys
//! containing ':' should be quoted by a TOML parser.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Method = struct {
    name: []const u8,
    /// Slot index for class methods (non-negative) or enumerator value
    /// (possibly negative).
    value: i64,
    /// Whether to emit `isize` (enum values) instead of `usize`
    /// (class vtable indices).
    is_signed: bool = false,
    quoted_name: bool = false,
};

const Class = struct {
    name: []const u8,
    methods: ArrayList(Method) = .empty,
};

/// Zig type used for one generated global constant.
const GlobalKind = enum {
    /// A quoted literal, emitted as `[]const u8`.
    string,
    /// An unsigned decimal, emitted as `usize`.
    integer,
    /// A negative decimal, emitted as `isize`.
    signed_integer,
    /// `true` or `false`, emitted as `bool`.
    boolean,
    /// Any other float literal, emitted as `f64`.
    float,
};

const GlobalVariable = struct {
    name: []const u8,
    value: []const u8,
    kind: GlobalKind,
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
    var current_section_is_enum = false;
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
                current_section_is_enum = false;
                try ensureClass(allocator, &classes, section);
            } else if (std.mem.startsWith(u8, section, "enum::")) {
                section = section["enum::".len..];
                if (!isZigIdentifier(section)) return error.InvalidClassName;
                current_class = section;
                current_section_is_global = false;
                current_section_is_enum = true;
                try ensureClass(allocator, &classes, section);
            } else if (std.mem.startsWith(u8, section, "global::")) {
                current_class = null;
                current_section_is_global = true;
                current_section_is_enum = false;
            } else {
                if (!isZigIdentifier(section)) return error.InvalidClassName;
                current_class = section;
                current_section_is_global = false;
                current_section_is_enum = false;
                try ensureClass(allocator, &classes, section);
            }
            continue;
        }

        const equals_at = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.InvalidAssignment;
        var key = std.mem.trim(u8, line[0..equals_at], whitespace);
        const key_was_quoted = isQuotedTomlKey(key);
        const value_text = std.mem.trim(u8, line[equals_at + 1 ..], whitespace);
        key = unquote(key);
        if (key.len == 0 or value_text.len == 0) return error.InvalidAssignment;

        var class_name: ?[]const u8 = null;
        var member_name: []const u8 = undefined;
        var member_name_is_quoted = false;
        var is_global = current_section_is_global;
        if (std.mem.indexOf(u8, key, "::")) |separator| {
            // A composite key names its own owner, so it is never part of
            // an enum section that may still be active.
            current_section_is_enum = false;
            class_name = std.mem.trim(u8, key[0..separator], whitespace);
            member_name = std.mem.trim(u8, key[separator + 2 ..], whitespace);
            class_name = unquote(class_name.?);
            member_name = unquote(member_name);
            // Composite keys are quoted in TOML because they contain ':'.
            // Use a Zig quoted identifier only when the member name itself
            // cannot be represented as a normal Zig identifier.
            member_name_is_quoted = key_was_quoted and !isZigIdentifier(member_name);
            if (std.mem.eql(u8, class_name.?, "global")) {
                is_global = true;
            } else {
                is_global = false;
            }
        } else {
            member_name = key;
            member_name_is_quoted = key_was_quoted;
            if (!is_global) class_name = current_class orelse return error.MethodWithoutClass;
        }

        if (is_global or !member_name_is_quoted) {
            if (!isZigIdentifier(member_name)) return error.InvalidMethodName;
        } else if (!isValidQuotedIdentifier(member_name)) {
            return error.InvalidQuotedMethodName;
        }
        const snake_name = try toSnakeCase(allocator, member_name);
        defer allocator.free(snake_name);
        if (!is_global and !member_name_is_quoted and !isZigIdentifier(snake_name)) {
            return error.InvalidGeneratedMethodName;
        }
        if (is_global and !isZigIdentifier(snake_name)) return error.InvalidGeneratedGlobalName;

        if (is_global) {
            const kind = classifyGlobalValue(value_text) orelse
                return error.InvalidGlobalValue;
            const value = if (kind == .string) unquote(value_text) else value_text;
            try putGlobalVariable(allocator, &global_variables, member_name, value, kind);
            continue;
        }

        const actual_class_name = class_name orelse return error.MethodWithoutClass;
        if (!isZigIdentifier(actual_class_name)) return error.InvalidClassName;

        if (current_section_is_enum) {
            const value = std.fmt.parseInt(i64, value_text, 10) catch
                return error.InvalidIndex;
            try putMethod(
                allocator,
                &classes,
                actual_class_name,
                member_name,
                value,
                true,
                member_name_is_quoted,
            );
        } else {
            const index = std.fmt.parseInt(usize, value_text, 10) catch
                return error.InvalidIndex;
            const value = std.math.cast(i64, index) orelse return error.InvalidIndex;
            try putMethod(
                allocator,
                &classes,
                actual_class_name,
                member_name,
                value,
                false,
                member_name_is_quoted,
            );
        }
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

        switch (variable.kind) {
            .string => {
                try appendFmt(allocator, &output,
                    "pub const {s}: []const u8 = \"", .{snake_name});
                try appendZigEscapedString(allocator, &output, variable.value);
                try output.appendSlice(allocator, "\";\n");
            },
            .integer => try appendFmt(allocator, &output,
                "pub const {s}: usize = {s};\n", .{ snake_name, variable.value }),
            .signed_integer => try appendFmt(allocator, &output,
                "pub const {s}: isize = {s};\n", .{ snake_name, variable.value }),
            .boolean => try appendFmt(allocator, &output,
                "pub const {s}: bool = {s};\n", .{ snake_name, variable.value }),
            .float => try appendFmt(allocator, &output,
                "pub const {s}: f64 = {s};\n", .{ snake_name, variable.value }),
        }
    }
    if (global_variables.items.len != 0) try output.append(allocator, '\n');

    for (classes.items) |class| {
        try appendFmt(allocator, &output, "pub const {s} = struct {{\n", .{class.name});

        for (class.methods.items, 0..) |method, method_index| {
            const snake_name = try toSnakeCase(allocator, method.name);
            defer allocator.free(snake_name);
            const generated_name = if (method.quoted_name) method.name else snake_name;

            // Compare actual generated names, including escaped identifiers.
            for (class.methods.items[0..method_index]) |previous| {
                const previous_snake = try toSnakeCase(allocator, previous.name);
                defer allocator.free(previous_snake);
                const previous_generated_name = if (previous.quoted_name)
                    previous.name
                else
                    previous_snake;
                if (std.mem.eql(u8, generated_name, previous_generated_name)) {
                    return error.DuplicateGeneratedMethodName;
                }
            }

            const type_name = if (method.is_signed) "isize" else "usize";
            if (method.quoted_name) {
                try output.appendSlice(allocator, "    pub const @\"");
                try appendZigEscapedString(allocator, &output, method.name);
                try appendFmt(
                    allocator,
                    &output,
                    "\": {s} = {d};\n",
                    .{ type_name, method.value },
                );
            } else {
                try appendFmt(
                    allocator,
                    &output,
                    "    pub const {s}: {s} = {d};\n",
                    .{ snake_name, type_name, method.value },
                );
            }
        }

        try output.appendSlice(allocator, "};\n\n");
    }

    return output.toOwnedSlice(allocator);
}

/// What one analysis row represents, which decides the flat-key prefix
/// `generateFromAnalysis` gives it.
pub const AnalysisKind = enum {
    /// A virtual-method vtable slot index; `owner` is the class name.
    method,
    /// A namespace-scope or macro constant emitted at file scope.
    global,
    /// An enum enumerator; `owner` is the enum type name. Enumerator
    /// values are emitted as `isize` because C++ enums may be negative.
    enumerator,
};

/// One analyzer result handed directly to the generator, without an
/// intermediate TOML document.
pub const AnalysisRow = struct {
    /// Interpretation of `owner` and `value`.
    kind: AnalysisKind,
    /// Class name for `.method`, enum type name for `.enumerator`.
    /// Ignored for `.global`, which always emits at file scope.
    owner: []const u8 = "",
    /// Method, enumerator, or constant name, verbatim.
    name: []const u8,
    /// Decimal slot/enumerator value for `.method` and `.enumerator`;
    /// a literal (quoted string, integer, boolean, or float) for
    /// `.global`.
    value: []const u8,
};

/// Renders analyzer result rows as the flat-key format accepted by
/// `generate` and returns the generated Zig source.
///
/// Rows are rendered in input order; classes accumulate into structs of
/// `usize` vtable indices, enum types into structs of `isize` values,
/// and global constants stay top-level. Duplicate names keep the last
/// value, matching `generate`'s regular behavior. The caller owns the
/// returned slice.
///
/// Errors are those of `generate`, including invalid names, non-decimal
/// method values, and unsupported global literals.
pub fn generateFromAnalysis(
    allocator: Allocator,
    rows: []const AnalysisRow,
) ![]u8 {
    var source: ArrayList(u8) = .empty;
    defer source.deinit(allocator);

    for (rows) |row| {
        switch (row.kind) {
            .method => try appendFmt(
                allocator,
                &source,
                "\"{s}::{s}\" = {s}\n",
                .{ row.owner, row.name, row.value },
            ),
            .enumerator => try appendFmt(
                allocator,
                &source,
                "[enum::{s}]\n{s} = {s}\n",
                .{ row.owner, row.name, row.value },
            ),
            .global => try appendFmt(
                allocator,
                &source,
                "\"global::{s}\" = {s}\n",
                .{ row.name, row.value },
            ),
        }
    }

    return generate(allocator, source.items);
}

/// Classifies a global constant literal from the flat-key format.
///
/// Quoted text is a string, `true`/`false` is a boolean, an unsigned
/// decimal is an integer, a negative decimal is a signed integer, and
/// any other float-parsable text is a float.
///
/// \returns the kind, or null when the literal is not supported.
fn classifyGlobalValue(value_text: []const u8) ?GlobalKind {
    if (value_text.len >= 2 and value_text[0] == '"' and
        value_text[value_text.len - 1] == '"') return .string;
    if (std.mem.eql(u8, value_text, "true") or
        std.mem.eql(u8, value_text, "false")) return .boolean;
    if (std.fmt.parseInt(usize, value_text, 0)) |_| {
        return .integer;
    } else |_| {}
    if (std.fmt.parseInt(isize, value_text, 0)) |_| {
        return .signed_integer;
    } else |_| {}
    if (std.fmt.parseFloat(f64, value_text)) |_| {
        return .float;
    } else |_| {}
    return null;
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
    value: i64,
    is_signed: bool,
    quoted_name: bool,
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
            method.value = value;
            method.is_signed = is_signed;
            method.quoted_name = quoted_name;
            return;
        }
    }

    try class.methods.append(allocator, .{
        .name = method_name,
        .value = value,
        .is_signed = is_signed,
        .quoted_name = quoted_name,
    });
}

fn putGlobalVariable(
    allocator: Allocator,
    variables: *ArrayList(GlobalVariable),
    name: []const u8,
    value: []const u8,
    kind: GlobalKind,
) !void {
    for (variables.items) |*variable| {
        if (std.mem.eql(u8, variable.name, name)) {
            variable.value = value;
            variable.kind = kind;
            return;
        }
    }
    try variables.append(allocator, .{
        .name = name,
        .value = value,
        .kind = kind,
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

fn isQuotedTomlKey(text: []const u8) bool {
    return text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"';
}

fn isValidQuotedIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |character| {
        if (character == '"' or character == '\\' or character == '\n' or character == '\r') {
            return false;
        }
    }
    return true;
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

test "quoted TOML method key becomes escaped Zig identifier" {
    const source =
        "[\"class::ICvar\"]\n" ++
        "\"GetCommands@17\" = 17\n";

    const generated = try generate(std.testing.allocator, source);
    defer std.testing.allocator.free(generated);

    try std.testing.expect(std.mem.indexOf(u8, generated,
        "pub const @\"GetCommands@17\": usize = 17;") != null);
}
