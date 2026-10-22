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
    /// Method/macro selector tokens, passed to the analyzer verbatim
    /// (a `const!` query's selectors are macro names, not methods).
    methods: []const []const u8,
    is_const: bool,
};

/// Content domain of an SDK query header, deciding which preamble header and
/// domain define the analyzer parses that query under. Determined empirically
/// by running the analyzer on every header listed in `config/raw_data.toml`
/// and mapping each analyzer error to its defining header:
///
/// - `server`: headers under `game/server/`, plus anything under `game/`
///   that is written from the server's point of view (`game/shared/`).
///   The SDK's entity headers form an include cycle (`baseentity.h`
///   <-> `entitylist.h`), so whichever side is wrapped while the other
///   side's guard is already set parses without any preamble at all,
///   producing errors like `unknown type name 'abstract_class'` (defined
///   in `public/tier0/platform.h`), `NULL` (`public/tier0/basetypes.h`),
///   `CUtlVector` (`public/tier1/utlvector.h`), and
///   `edict_t`/`CBaseHandle`/`IServerNetworkable` (`public/edict.h`,
///   `public/eiface.h`, `game/shared/ehandle.h`). In the real engine
///   build, a server translation unit starts with the prelude
///   `game/server/cbase.h`, which includes that tier0/tier1/tier2
///   preamble plus `const.h`/`edict.h`/`eiface.h` before any entity
///   header - so the analyzer force-includes the same prelude with
///   `-include`, together with `-DGAME_DLL`. `GAME_DLL` (or
///   `CLIENT_DLL`) is required because `public/networkvar.h` only
///   defines the `CNetworkVar`/`CNetworkHandle` member macros under
///   `#if defined( CLIENT_DLL ) || defined( GAME_DLL )`.
/// - `client`: headers under `game/client/`, parsed with the prelude
///   `game/client/cbase.h` and `-DCLIENT_DLL`. The client domain also
///   selects the `RecvTable`/`EXTERN_SEND_TABLE` variants in
///   `public/dt_common.h` instead of the server's `SendTable` ones.
/// - `interface`: self-contained interface/global headers (`public/`,
///   `common/`, `utils/`, ...) that need no prelude or domain define.
pub const AnalyzerDomain = enum {
    server,
    client,
    interface,
};

fn domainForHeaderPath(header: []const u8) AnalyzerDomain {
    if (std.mem.startsWith(u8, header, "game/client/")) return .client;
    // `game/server/` and `game/shared/` headers parse under the server
    // domain (verified for gamerules.h, usercmd.h, recipientfilter.h's
    // class family).
    if (std.mem.startsWith(u8, header, "game/")) return .server;
    return .interface;
}

/// Owns the prepared argv and query metadata for the analyzer invocations.
/// The analyzer parses each query as a separate translation unit but shares
/// the compiler arguments between them, while the domains above need
/// different preludes/defines - so queries are grouped into one invocation
/// (run) per domain. All runs borrow memory from this struct's arena and
/// must be released with `PreparedAnalyzerArgs.deinit()`.
pub const PreparedAnalyzerArgs = struct {
    arena: std.heap.ArenaAllocator,
    /// One entry per domain that has at least one query, in the fixed
    /// order: server, client, interface.
    runs: []const AnalyzerRun,

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const AnalyzerRun = struct {
    args: []const []const u8,
    queries: []const QueryInfo,
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

/// Reads an analyzer TOML configuration and prepares the analyzer's argv for
/// one invocation per query domain (see `AnalyzerDomain`). The returned value
/// owns its memory and must be released with `PreparedAnalyzerArgs.deinit()`.
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

    const domain_count = @typeInfo(AnalyzerDomain).@"enum".fields.len;
    var domain_indices: [domain_count]std.ArrayList(QueryInfo) = .{ .empty, .empty, .empty };

    // First pass: validate every query and bucket it into its domain.
    for (config.class) |query| {
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

        try domain_indices[@intFromEnum(domainForHeaderPath(query.header))].append(
            alloc,
            .{
                .header_path = full_header_path,
                .name = query.name,
                .methods = query.methods,
                .is_const = is_const,
            },
        );
    }

    var domain_runs: std.ArrayList(AnalyzerRun) = .empty;
    for (domain_indices, 0..) |queries, domain_index| {
        if (queries.items.len == 0) continue;
        const domain: AnalyzerDomain = @enumFromInt(domain_index);
        try domain_runs.append(
            alloc,
            try makeAnalyzerRun(alloc, io, config.root.path, domain, queries.items),
        );
    }

    if (domain_runs.items.len == 0) return error.NoAnalyzerQueries;

    const owned_runs = try domain_runs.toOwnedSlice(alloc);
    return .{
        .arena = arena,
        .runs = owned_runs,
    };
}

fn appendArgsFrom(
    args: *std.ArrayList([]const u8),
    alloc: Allocator,
    source: []const []const u8,
) !void {
    for (source) |arg| try args.append(alloc, arg);
}

/// Builds the argv for one domain's analyzer invocation: that domain's
/// queries (in the analyzer's brace-set syntax), the shared include dirs
/// and defines, clang's built-in-header resource dir, and the domain's
/// prelude header and define.
///
/// The clang resource dir must be passed explicitly: `clang::tooling`'s
/// builtin-header lookup normally derives it from the executable's own
/// path, which never matches for a custom-named tool (zig-out/bin/
/// vtable-index-analyzer), causing `stddef.h file not found` as soon as a
/// query touches system headers. It is resolved up front by asking
/// `clang -print-resource-dir`; when clang is not available the args are
/// still built (the analyzer will report missing basic headers itself).
fn makeAnalyzerRun(
    alloc: Allocator,
    io: std.Io,
    root_path: []const u8,
    domain: AnalyzerDomain,
    queries: []const QueryInfo,
) !AnalyzerRun {
    var query_text: std.ArrayList(u8) = .empty;
    var args: std.ArrayList([]const u8) = .empty;

    try query_text.append(alloc, '{');
    for (queries, 0..) |query, query_index| {
        if (query_index != 0) try appendSlice(&query_text, alloc, ", ");
        try query_text.append(alloc, '{');
        try appendSlice(&query_text, alloc, query.header_path);
        try appendSlice(&query_text, alloc, " ");
        try appendSlice(&query_text, alloc, query.name);
        for (query.methods) |method| {
            try appendSlice(&query_text, alloc, " ");
            try appendSlice(&query_text, alloc, method);
        }
        try query_text.append(alloc, '}');
    }
    try query_text.append(alloc, '}');
    try args.append(alloc, try query_text.toOwnedSlice(alloc));
    try args.append(alloc, "--");

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

    for (include_dirs) |subdir|
        try appendIncludeArg(&args, alloc, root_path, subdir);

    try appendArgsFrom(&args, alloc, &.{"-resource-dir"});
    if (try detectClangResourceDir(io, alloc)) |resource_dir|
        try args.append(alloc, resource_dir);

    // These defines match the Source SDK 2013 Linux setup used by the
    // analyzer. Keep them here rather than embedding SDK policy in C++.
    //
    // `-DLINUX` is required alongside `-D_LINUX`: `platform.h`'s platform
    // chain checks `defined(LINUX)` and hits its "Define a platform dir
    // for me!" `#error` otherwise.
    //
    // `-m32` was dropped: the analyzer only reads vtable slot indices, which
    // (for the single inheritance these SDK interfaces use) are identical
    // between 32- and 64-bit Itanium layouts, and `-m32` requires 32-bit
    // glibc headers (`gnu/stubs-32.h`) that not every host has.
    const compiler_args = [_][]const u8{
        "-DCOMPILER_GCC",
        "-DPOSIX",
        "-D_LINUX",
        "-DLINUX",
        "-DGNUC",
        "-std=gnu++14",
    };
    try appendArgsFrom(&args, alloc, &compiler_args);

    // Domain extras. Paths must stay relative to the SDK root (they are
    // probed with std::ifstream in the C++ tool) but separate argv elements,
    // so nothing here needs the UnsupportedQueryToken restrictions.
    switch (domain) {
        .server => try appendArgsFrom(&args, alloc, &.{
            "-DGAME_DLL",
            "-include",
            try makeJoinedPath(alloc, root_path, "game/server/cbase.h"),
        }),
        .client => try appendArgsFrom(&args, alloc, &.{
            "-DCLIENT_DLL",
            "-include",
            try makeJoinedPath(alloc, root_path, "game/client/cbase.h"),
        }),
        .interface => {}, // Self-contained headers need no prelude.
    }

    return .{
        .args = try args.toOwnedSlice(alloc),
        .queries = queries,
    };
}

fn detectClangResourceDir(io: std.Io, alloc: Allocator) !?[]const u8 {
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "clang", "-print-resource-dir" },
        .stdout_limit = .limited(4096),
    }) catch return null;

    if (result.term != .exited or result.term.exited != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfAny(u8, trimmed, " \t\r\n") != null) return null;
    return try alloc.dupe(u8, trimmed);
}

/// Runs the analyzer once per domain run with explicitly supplied prepared
/// arguments, aggregating their stdout/stderr and queries into one result.
/// The returned output owns its memory and must be released with
/// `AnalyzerOutput.deinit()`.
pub fn beginAnalyze(
    io: std.Io,
    analyzer_path: []const u8,
    prepared: *const PreparedAnalyzerArgs,
) !AnalyzerOutput {
    if (prepared.runs.len == 0) return error.AnalyzerArgumentsNotPrepared;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var stdout_list: std.ArrayList(u8) = .empty;
    var stderr_list: std.ArrayList(u8) = .empty;
    var queries: std.ArrayList(QueryInfo) = .empty;

    for (prepared.runs) |run| {
        const argv = try alloc.alloc([]const u8, run.args.len + 1);
        argv[0] = analyzer_path;
        @memcpy(argv[1..], run.args);

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

        try stdout_list.appendSlice(alloc, result.stdout);
        if (result.stderr.len != 0) {
            try stderr_list.appendSlice(alloc, result.stderr);
        }
        for (run.queries) |query| {
            try queries.append(alloc, .{
                .header_path = try alloc.dupe(u8, query.header_path),
                .name = try alloc.dupe(u8, query.name),
                .methods = try alloc.dupe([]const u8, query.methods),
                .is_const = query.is_const,
            });
        }
    }

    const queries_slice = try queries.toOwnedSlice(alloc);
    return .{
        .arena = arena,
        .stdout = try stdout_list.toOwnedSlice(alloc),
        .stderr = try stderr_list.toOwnedSlice(alloc),
        .queries = queries_slice,
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
