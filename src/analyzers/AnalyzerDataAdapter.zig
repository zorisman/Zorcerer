const std = @import("std");
const toml = @import("../../extern/zig-toml/src/root.zig");

const Allocator = std.mem.Allocator;
const allocator = std.heap.page_allocator;

const max_analyzer_output_bytes = 64 * 1024 * 1024;

const RootConfig = struct {
    path: []const u8,
};

const ClassConfig = struct {
    header: []const u8,
    name: []const u8,
    methods: []const []const u8,
};

const AnalyzerConfig = struct {
    root: RootConfig,
    class: []const ClassConfig,
};

pub const QueryInfo = struct {
    header_path: []const u8,
    name: []const u8,
    is_const: bool,
};

/// Owns the prepared argv and query metadata for one analyzer invocation.
pub const PreparedAnalyzerArgs = struct {
    arena: std.heap.ArenaAllocator,
    args: []const []const u8,
    queries: []const QueryInfo,

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Owns one analyzer run's stdout, stderr, and query metadata.
pub const AnalyzerOutput = struct {
    arena: std.heap.ArenaAllocator,
    stdout: []const u8,
    stderr: []const u8,
    queries: []const QueryInfo,

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const TomlEntry = struct {
    key: []const u8,
    value: []const u8,
};

const TomlSection = struct {
    name: []const u8,
    entries: std.ArrayList(TomlEntry) = .empty,
};


fn appendSlice(list: *std.ArrayList(u8), alloc: Allocator, value: []const u8) !void {
    try list.appendSlice(alloc, value);
}

fn containsUnsupportedQueryChar(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, " \t\r\n{},") != null;
}

fn makeJoinedPath(alloc: Allocator, base: []const u8, child: []const u8) ![]const u8 {
    return try std.Io.Dir.path.join(alloc, &.{ base, child });
}

fn appendIncludeArg(
    args: *std.ArrayList([]const u8),
    alloc: Allocator,
    root_path: []const u8,
    subdir: []const u8,
) !void {
    const include_path = if (subdir.len == 0)
        try alloc.dupe(u8, root_path)
    else
        try makeJoinedPath(alloc, root_path, subdir);
    const arg = try std.fmt.allocPrint(alloc, "-I{s}", .{include_path});
    try args.append(alloc, arg);
}

/// Reads an analyzer TOML configuration and builds the argv and query metadata
/// required for one analyzer invocation. The returned value owns its memory and
/// must be released with `PreparedAnalyzerArgs.deinit()`.
pub fn prepareAnalyzerArgs(io: std.Io, toml_path: []const u8) !PreparedAnalyzerArgs {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var parser = toml.Parser(AnalyzerConfig).init(alloc);
    defer parser.deinit();

    var parsed = try parser.parseFile(io, toml_path);
    defer parsed.deinit();
    const config = parsed.value;

    if (config.root.path.len == 0) return error.EmptySdkRootPath;
    if (config.class.len == 0) return error.NoAnalyzerQueries;

    var query_text: std.ArrayList(u8) = .empty;
    var args: std.ArrayList([]const u8) = .empty;
    var queries: std.ArrayList(QueryInfo) = .empty;

    try query_text.append(alloc, '{');

    for (config.class, 0..) |query, index| {
        if (query.header.len == 0 or query.name.len == 0)
            return error.EmptyQueryField;
        if (query.methods.len == 0)
            return error.QueryHasNoMethods;

        const full_header_path = try makeJoinedPath(alloc, config.root.path, query.header);
        if (containsUnsupportedQueryChar(full_header_path) or containsUnsupportedQueryChar(query.name))
            return error.UnsupportedQueryToken;

        for (query.methods) |method| {
            if (method.len == 0 or containsUnsupportedQueryChar(method))
                return error.UnsupportedQueryToken;
        }

        const is_const = std.mem.eql(u8, query.name, "const!");
        if (!is_const and std.mem.eql(u8, query.name, "*"))
            return error.InvalidClassName;

        var has_wildcard = false;
        for (query.methods) |method| {
            if (std.mem.eql(u8, method, "*")) has_wildcard = true;
        }
        if (has_wildcard and query.methods.len != 1)
            return error.InvalidWildcardUsage;

        if (index != 0) try appendSlice(&query_text, alloc, ", ");
        try query_text.append(alloc, '{');
        try appendSlice(&query_text, alloc, full_header_path);
        try appendSlice(&query_text, alloc, " ");
        try appendSlice(&query_text, alloc, query.name);
        for (query.methods) |method| {
            try appendSlice(&query_text, alloc, " ");
            try appendSlice(&query_text, alloc, method);
        }
        try query_text.append(alloc, '}');

        try queries.append(alloc, .{
            .header_path = try alloc.dupe(u8, full_header_path),
            .name = try alloc.dupe(u8, query.name),
            .is_const = is_const,
        });
    }

    try query_text.append(alloc, '}');
    try args.append(alloc, try query_text.toOwnedSlice(alloc));
    try args.append(alloc, "--");

    // These include paths and defines match the Source SDK 2013 Linux setup
    // used by the analyzer. Keep them here rather than embedding SDK policy in C++.
    const include_dirs = [_][]const u8{
        "",
        "public",
        "public/engine",
        "public/tier0",
        "public/tier1",
        "public/mathlib",
        "game/server",
        "game/shared",
        "game/client",
        "common",
        "utils",
    };
    for (include_dirs) |subdir| {
        try appendIncludeArg(&args, alloc, config.root.path, subdir);
    }

    const compiler_args = [_][]const u8{
        "-DCOMPILER_GCC",
        "-DPOSIX",
        "-D_LINUX",
        "-DGNUC",
        "-std=gnu++14",
        "-m32",
    };
    for (compiler_args) |arg| try args.append(alloc, arg);

    const owned_args = try args.toOwnedSlice(alloc);
    const owned_queries = try queries.toOwnedSlice(alloc);
    return .{
        .arena = arena,
        .args = owned_args,
        .queries = owned_queries,
    };
}

/// Runs the analyzer with explicitly supplied prepared arguments. The returned
/// output owns its memory and must be released with `AnalyzerOutput.deinit()`.
pub fn beginAnalyze(
    io: std.Io,
    analyzer_path: []const u8,
    prepared: *const PreparedAnalyzerArgs,
) !AnalyzerOutput {
    if (prepared.args.len == 0) return error.AnalyzerArgumentsNotPrepared;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const argv = try alloc.alloc([]const u8, prepared.args.len + 1);
    argv[0] = analyzer_path;
    @memcpy(argv[1..], prepared.args);

    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_analyzer_output_bytes),
    });

    if (result.term != .exited or result.term.exited != 0) {
        if (result.stderr.len != 0) {
            std.debug.print("VTableIndexAnalyzer failed:\n{s}\n", .{result.stderr});
        }
        return error.AnalyzerFailed;
    }

    const queries = try alloc.alloc(QueryInfo, prepared.queries.len);
    for (prepared.queries, 0..) |query, index| {
        queries[index] = .{
            .header_path = try alloc.dupe(u8, query.header_path),
            .name = try alloc.dupe(u8, query.name),
            .is_const = query.is_const,
        };
    }

    return .{
        .arena = arena,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .queries = queries,
    };
}

fn appendTomlBasicString(list: *std.ArrayList(u8), alloc: Allocator, value: []const u8) !void {
    try list.append(alloc, '"');
    const hex = "0123456789abcdef";
    for (value) |byte| {
        switch (byte) {
            '"' => try appendSlice(list, alloc, "\\\""),
            '\\' => try appendSlice(list, alloc, "\\\\"),
            '\n' => try appendSlice(list, alloc, "\\n"),
            '\r' => try appendSlice(list, alloc, "\\r"),
            '\t' => try appendSlice(list, alloc, "\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                try appendSlice(list, alloc, "\\u00");
                try list.append(alloc, hex[byte >> 4]);
                try list.append(alloc, hex[byte & 0x0f]);
            },
            else => try list.append(alloc, byte),
        }
    }
    try list.append(alloc, '"');
}

fn findOrCreateSection(
    sections: *std.ArrayList(TomlSection),
    alloc: Allocator,
    name: []const u8,
) !*TomlSection {
    for (sections.items) |*section| {
        if (std.mem.eql(u8, section.name, name)) return section;
    }

    try sections.append(alloc, .{
        .name = try alloc.dupe(u8, name),
    });
    return &sections.items[sections.items.len - 1];
}

fn hasKey(section: *const TomlSection, key: []const u8) bool {
    for (section.entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return true;
    }
    return false;
}

fn addEntry(
    section: *TomlSection,
    alloc: Allocator,
    key: []const u8,
    value: []const u8,
) !void {
    var unique_key = key;
    if (hasKey(section, unique_key)) {
        var suffix: usize = section.entries.items.len;
        if (std.fmt.parseInt(usize, value, 0)) |parsed_index| {
            suffix = parsed_index;
        } else |_| {}

        while (true) {
            unique_key = try std.fmt.allocPrint(alloc, "{s}@{d}", .{ key, suffix });
            if (!hasKey(section, unique_key)) break;
            suffix += 1;
        }
    }

    try section.entries.append(alloc, .{
        .key = unique_key,
        .value = value,
    });
}

fn stripMethodAnnotation(value: []const u8) []const u8 {
    if (std.mem.startsWith(u8, value, "\"")) return value;

    const simple_annotations = [_][]const u8{
        "  (complete destructor)",
        "  (deleting destructor)",
    };
    for (simple_annotations) |annotation| {
        if (std.mem.endsWith(u8, value, annotation)) {
            return value[0 .. value.len - annotation.len];
        }
    }

    const virtual_annotation = "  (virtual destructor: also reserves the next slot, ";
    if (std.mem.indexOf(u8, value, virtual_annotation)) |start| {
        if (std.mem.endsWith(u8, value, ")")) return value[0..start];
    }
    return value;
}

fn addAnalyzerLine(queries: []const QueryInfo, sections: *std.ArrayList(TomlSection), alloc: Allocator, line: []const u8) !void {
    const separator = std.mem.indexOf(u8, line, " = ") orelse return error.UnexpectedAnalyzerOutput;
    const lhs = line[0..separator];
    const raw_value = std.mem.trim(u8, line[separator + 3 ..], " \t\r");
    if (lhs.len == 0 or raw_value.len == 0) return error.UnexpectedAnalyzerOutput;

    for (queries) |query| {
        if (!query.is_const) continue;
        const prefix = try std.fmt.allocPrint(alloc, "{s}::", .{query.header_path});
        if (!std.mem.startsWith(u8, lhs, prefix)) continue;

        const key = lhs[prefix.len..];
        if (key.len == 0) return error.UnexpectedAnalyzerOutput;
        const section_name = try std.fmt.allocPrint(alloc, "const::{s}", .{query.header_path});
        const section = try findOrCreateSection(sections, alloc, section_name);
        try addEntry(section, alloc, key, raw_value);
        return;
    }

    for (queries) |query| {
        if (query.is_const) continue;
        const prefix = try std.fmt.allocPrint(alloc, "{s}::", .{query.name});
        if (!std.mem.startsWith(u8, lhs, prefix)) continue;

        const key = lhs[prefix.len..];
        if (key.len == 0) return error.UnexpectedAnalyzerOutput;
        const value = stripMethodAnnotation(raw_value);
        const section_name = try std.fmt.allocPrint(alloc, "class::{s}", .{query.name});
        const section = try findOrCreateSection(sections, alloc, section_name);
        try addEntry(section, alloc, key, value);
        return;
    }

    return error.UnrecognizedAnalyzerOutput;
}

/// Converts one analyzer result into TOML and writes it to `toml_path`.
/// The result and its query metadata are passed explicitly; no global state is used.
pub fn intoToml(
    io: std.Io,
    toml_path: []const u8,
    analysis: *const AnalyzerOutput,
) !void {
    if (analysis.stdout.len == 0) return error.EmptyAnalyzerOutput;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var sections: std.ArrayList(TomlSection) = .empty;
    var lines = std.mem.splitScalar(u8, analysis.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        try addAnalyzerLine(analysis.queries, &sections, alloc, line);
    }

    if (sections.items.len == 0) return error.EmptyAnalyzerOutput;

    var output: std.ArrayList(u8) = .empty;
    for (sections.items) |section| {
        try output.append(alloc, '[');
        try appendTomlBasicString(&output, alloc, section.name);
        try appendSlice(&output, alloc, "]\n");

        for (section.entries.items) |entry| {
            try appendTomlBasicString(&output, alloc, entry.key);
            try appendSlice(&output, alloc, " = ");
            try appendSlice(&output, alloc, entry.value);
            try output.append(alloc, '\n');
        }
        try output.append(alloc, '\n');
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = toml_path,
        .data = output.items,
    });
}
