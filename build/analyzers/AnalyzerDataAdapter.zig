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

/// One `[[const]]` query: resolves selector constants from one header.
/// Each entry in `names` names either an object-like `#define` macro or a
/// namespace-scope const/constexpr variable whose definition lives in
/// `header` itself; a lone `"*"` selects every constant of the header.
const ConstConfig = struct {
    header: []const u8,
    names: []const []const u8,
};

/// One `[[enum]]` query: resolves enumerator values of one enum type
/// found under `header` (possibly nested; `name` may be a qualified
/// name like `Outer::Kind`). Each entry in `enumerators` names one
/// enumerator of that enum; a lone `"*"` selects all of them.
const EnumConfig = struct {
    header: []const u8,
    /// Plain enum type name, without the `enum::` target decoration
    /// (the adapter adds it when building the analyzer target token).
    name: []const u8,
    enumerators: []const []const u8,
};

const AnalyzerConfig = struct {
    root: RootConfig,
    class: []const ClassConfig = &.{},
    @"const": []const ConstConfig = &.{},
    @"enum": []const EnumConfig = &.{},
};

pub const QueryInfo = struct {
    header_path: []const u8,
    /// Analyzer target token, verbatim: a class name, `"enum::<Enum>"`,
    /// or the bare `"const::"`.
    name: []const u8,
    /// Selector tokens (methods or enumerator names, macro names, or a
    /// lone `*`), passed to the analyzer verbatim.
    methods: []const []const u8,
    /// Whether the query is a `const::` constants query (its selectors
    /// are macro/constant names, not methods or enumerators).
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

/// One `key = value` pair in a generated `[[...]]` row's body. `value`
/// is already a TOML literal, classified or quoted by the row builder.
const TomlField = struct {
    key: []const u8,
    value: []const u8,
};

/// One generated `[[<header>]]` array-of-tables row of `intoToml`'s
/// output. Consecutive rows sharing a header accumulate into the same
/// TOML array element sequence, so output rows never need key-renaming
/// deduplication.
///
/// Rows are typed by the query they were built from:
/// - class vtable index rows: `usize` value, `[[<class>::<method>]]`.
/// - constants: `integer`, `boolean`, `float`, or `string` value,
///   `[[<header-path>::<const-name>]]`.
/// - enumerators: one row per enumerator under `[[<enum-name>]]`, the
///   `name` field carrying the enumerator, the value an `integer`.
const TomlRow = struct {
    /// Table-array header without brackets, e.g. `CBaseEntity::Spawn`,
    /// `public/eiface.h::INTERFACEVERSION_VENGINESERVER`, or a plain
    /// enum type name (`IN_BUTTONS`).
    header: []const u8,
    /// Ordered body fields (`type`, `value`, and for enumerators
    /// `name` first).
    fields: std.ArrayList(TomlField) = .empty,
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
/// one invocation per query domain (see `AnalyzerDomain`). The configuration
/// carries a `[[root]]` table with the SDK path plus `[[class]]`, `[[const]]`,
/// and `[[enum]]` query tables; all of them are optional but at least one
/// query must be present.
///
/// The returned value owns its memory and must be released with
/// `PreparedAnalyzerArgs.deinit()`.
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
    if (config.class.len == 0 and config.@"const".len == 0 and
        config.@"enum".len == 0) return error.NoAnalyzerQueries;

    const domain_count = @typeInfo(AnalyzerDomain).@"enum".fields.len;
    var domain_indices: [domain_count]std.ArrayList(QueryInfo) = .{ .empty, .empty, .empty };

    // First pass: validate every query and bucket it into its domain.
    // `[[class]]` targets are taken verbatim; `[[const]]` queries share
    // the bare `const::` target whose selectors each name their own
    // constant; `[[enum]]` target names get the `enum::` decoration here.
    for (config.class) |query| {
        if (std.mem.eql(u8, query.name, "*"))
            return error.InvalidClassName;
        // The pre-enum-grammar sentinel; sending it would now make the
        // analyzer parse it as a literal class name.
        if (std.mem.eql(u8, query.name, "const!"))
            return error.InvalidClassName;
        try bucketQuery(alloc, config.root.path, &domain_indices,
            query.header, query.name, query.methods, false);
    }

    for (config.@"const") |query|
        try bucketQuery(alloc, config.root.path, &domain_indices,
            query.header, "const::", query.names, true);

    for (config.@"enum") |query| {
        // `enum::` is added by this adapter; a name that already carries
        // it would double-decorate the analyzer target token.
        if (std.mem.startsWith(u8, query.name, "enum::") or
            std.mem.eql(u8, query.name, "*")) return error.InvalidEnumName;
        const target = try std.fmt.allocPrint(alloc, "enum::{s}", .{query.name});
        try bucketQuery(alloc, config.root.path, &domain_indices,
            query.header, target, query.enumerators, false);
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

/// Validates one query table and appends it to the bucket of the domain
/// its header belongs to (see `AnalyzerDomain`).
///
/// The same validation applies to every query kind: non-empty header and
/// target, at least one selector, no selector/target/header token that
/// the analyzer's brace-set grammar cannot carry (`QueryInfo.methods`
/// holds the selectors regardless of kind), and `"*"` accepted only as
/// the sole selector.
///
/// \param alloc arena allocator the appended `QueryInfo` borrows from.
/// \param root_path SDK root the `header` is resolved against.
/// \param domain_indices one bucket per `AnalyzerDomain` value, filled
///                       in `@intFromEnum` order.
/// \param header SDK-relative header path of the query.
/// \param target analyzer target token, already decorated (`enum::<Name>`
///               or bare `const::`) where applicable.
/// \param selectors method/constant/enumerator selectors, verbatim.
/// \param is_const true for `const::` queries.
/// \returns query errors (`error.EmptyQueryField`,
///          `error.QueryHasNoMethods`, `error.UnsupportedQueryToken`,
///          `error.InvalidWildcardUsage`) on invalid input; allocation
///          errors propagate.
fn bucketQuery(
    alloc: Allocator,
    root_path: []const u8,
    domain_indices: *[3]std.ArrayList(QueryInfo),
    header: []const u8,
    target: []const u8,
    selectors: []const []const u8,
    is_const: bool,
) !void {
    if (header.len == 0 or target.len == 0)
        return error.EmptyQueryField;
    if (selectors.len == 0)
        return error.QueryHasNoMethods;

    const full_header_path = try makeJoinedPath(alloc, root_path, header);
    if (containsUnsupportedQueryChar(full_header_path) or containsUnsupportedQueryChar(target))
        return error.UnsupportedQueryToken;

    for (selectors) |selector| {
        if (selector.len == 0 or containsUnsupportedQueryChar(selector))
            return error.UnsupportedQueryToken;
    }

    var has_wildcard = false;
    for (selectors) |selector| {
        if (std.mem.eql(u8, selector, "*")) has_wildcard = true;
    }
    if (has_wildcard and selectors.len != 1)
        return error.InvalidWildcardUsage;

    try domain_indices[@intFromEnum(domainForHeaderPath(header))].append(
        alloc,
        .{
            .header_path = full_header_path,
            .name = target,
            .methods = selectors,
            .is_const = is_const,
        },
    );
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

/// Representative data types of constant values, as recorded in each
/// row's `type` field.
const ConstantKind = enum {
    integer,
    boolean,
    float,
    string,
};

/// Classifies one analyzer-reported constant literal (`macroValueAsToml`
/// or `apValueAsToml` output) into its representative data type.
///
/// Quoted text is a `string`, `true`/`false` is `boolean`, anything that
/// parses as an integer (including TOML's `0x`/`0o`/`0b` prefixes) is
/// `integer`, anything else that parses as a float is `float`.
///
/// \param literal the analyzer's RHS text, trimmed.
/// \returns the kind, or null when the literal is not a recognisable
///          TOML value (the caller must fail with
///          `error.UnexpectedAnalyzerOutput`).
///
/// Limitation: a whole-number float (e.g. `4.0` printed as `4` by
/// `apValueAsToml`) is indistinguishable from an integer constant once
/// printed, and is reported as `integer`.
fn constantLiteralKind(literal: []const u8) ?ConstantKind {
    if (literal.len >= 2 and literal[0] == '"' and literal[literal.len - 1] == '"') {
        return .string;
    }
    if (std.mem.eql(u8, literal, "true") or std.mem.eql(u8, literal, "false")) {
        return .boolean;
    }
    if (std.fmt.parseInt(i128, literal, 0)) |parsed_int| {
        _ = parsed_int;
        return .integer;
    } else |_| {}
    if (std.fmt.parseFloat(f64, literal)) |parsed_float| {
        _ = parsed_float;
        return .float;
    } else |_| {}
    return null;
}

/// Wraps \p value as a TOML basic string literal.
///
/// \returns the quoted text, allocated by \p alloc.
fn tomlBasicString(alloc: Allocator, value: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    try appendTomlBasicString(&list, alloc, value);
    return list.toOwnedSlice(alloc);
}

/// Appends one typed row's body field (`\p value_kind` records the
/// representative data type next to the TOML literal in \p value; both
/// are emitted as TOML basic strings).
fn appendTypedRow(
    rows: *std.ArrayList(TomlRow),
    alloc: Allocator,
    header: []const u8,
    value_kind: []const u8,
    value: []const u8,
) !void {
    var row = TomlRow{ .header = header };
    try row.fields.append(alloc, .{
        .key = "type",
        .value = try tomlBasicString(alloc, value_kind),
    });
    try row.fields.append(alloc, .{ .key = "value", .value = value });
    try rows.append(alloc, row);
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

/// Converts one analyzer stdout report line into a typed output row
/// (see `TomlRow`) and appends it to \p rows.
///
/// Routing, first matching query wins:
/// 1. `const::` queries (`is_const`): a
///    `<header-path>::<Name> = <literal>` line becomes the row
///    `[["<header-path>::<Name>"]]` whose `value` is the constant's
///    TOML literal and whose `type` is its representative data type
///    (see `constantLiteralKind`).
/// 2. `enum::<Enum>` queries: `<Enum>::<Enumerator> = <value>` becomes
///    one `[[<Enum>]]` row per enumerator; the `name` field carries
///    the enumerator, the `value` an integer (the analyzer reports
///    signed decimal values). Enumerator rows repeat under the same
///    header and accumulate as array-of-tables entries.
/// 3. class queries: `<Class>::<Method> = <index>` becomes
///    `[["<Class>::<Method>"]]` with `type = "usize"`; destructor
///    report annotations are stripped, and the analyzer has already
///    renamed duplicate slot keys with an `@<index>` suffix.
///
/// \param queries metadata of the queries the analyzed output belongs
///                to; a line is routed by the `::`-prefixed forms above.
/// \param rows destination list, allocated by \p alloc.
/// \param line one trimmed non-empty analyzer stdout line.
/// \returns `error.UnrecognizedAnalyzerOutput` when no query owns the
///          line and `error.UnexpectedAnalyzerOutput` when the owner's
///          value is not a classifiable TOML value or a report word
///          is empty.
fn addAnalyzerLine(
    queries: []const QueryInfo,
    rows: *std.ArrayList(TomlRow),
    alloc: Allocator,
    line: []const u8,
) !void {
    const separator = std.mem.indexOf(u8, line, " = ") orelse return error.UnexpectedAnalyzerOutput;
    const lhs = line[0..separator];
    const raw_value = std.mem.trim(u8, line[separator + 3 ..], " \t\r");
    if (lhs.len == 0 or raw_value.len == 0) return error.UnexpectedAnalyzerOutput;

    // 1. Constants: "<header-path>::<Name> = <toml literal>".
    for (queries) |query| {
        if (!query.is_const) continue;
        const prefix = try std.fmt.allocPrint(alloc, "{s}::", .{query.header_path});
        if (!std.mem.startsWith(u8, lhs, prefix)) continue;

        const name = lhs[prefix.len..];
        if (name.len == 0) return error.UnexpectedAnalyzerOutput;
        const kind = constantLiteralKind(raw_value) orelse
            return error.UnexpectedAnalyzerOutput;
        const header = try std.fmt.allocPrint(alloc, "{s}::{s}", .{ query.header_path, name });
        try appendTypedRow(rows, alloc, header, @tagName(kind), raw_value);
        return;
    }

    // 2. Enumerators: "<Enum>::<Enumerator> = <value>"; one row per
    //    enumerator, all sharing the plain enum name header.
    for (queries) |query| {
        if (query.is_const or !std.mem.startsWith(u8, query.name, "enum::")) continue;
        const enum_name = query.name["enum::".len..];
        if (enum_name.len == 0) return error.UnexpectedAnalyzerOutput;
        const prefix = try std.fmt.allocPrint(alloc, "{s}::", .{enum_name});
        if (!std.mem.startsWith(u8, lhs, prefix)) continue;

        const enumerator = lhs[prefix.len..];
        if (enumerator.len == 0) return error.UnexpectedAnalyzerOutput;
        // The analyzer prints enumerator values as signed decimals.
        _ = std.fmt.parseInt(i128, raw_value, 10) catch
            return error.UnexpectedAnalyzerOutput;
        var row = TomlRow{ .header = try alloc.dupe(u8, enum_name) };
        try row.fields.append(alloc, .{
            .key = "name",
            .value = try tomlBasicString(alloc, enumerator),
        });
        try row.fields.append(alloc, .{
            .key = "type",
            .value = try tomlBasicString(alloc, "integer"),
        });
        try row.fields.append(alloc, .{ .key = "value", .value = raw_value });
        try rows.append(alloc, row);
        return;
    }

    // 3. Vtable indexes: "<Class>::<Method> = <slot index>".
    for (queries) |query| {
        if (query.is_const or std.mem.startsWith(u8, query.name, "enum::")) continue;
        const prefix = try std.fmt.allocPrint(alloc, "{s}::", .{query.name});
        if (!std.mem.startsWith(u8, lhs, prefix)) continue;

        const method = lhs[prefix.len..];
        if (method.len == 0) return error.UnexpectedAnalyzerOutput;
        const index = stripMethodAnnotation(raw_value);
        // Slot indices are plain decimals.
        _ = std.fmt.parseInt(u64, index, 10) catch
            return error.UnexpectedAnalyzerOutput;
        const header = try std.fmt.allocPrint(alloc, "{s}::{s}", .{ query.name, method });
        try appendTypedRow(rows, alloc, header, "usize", index);
        return;
    }

    return error.UnrecognizedAnalyzerOutput;
}

/// Converts one analyzer result into TOML and writes it to `toml_path`.
/// The result and its query metadata are passed explicitly; no global
/// state is used.
///
/// Every analyzer line becomes a typed array-of-tables row (see
/// `TomlRow` and `addAnalyzerLine`):
///
///     [["CBaseEntity::~CBaseEntity"]]
///     type = "usize"
///     value = 0
///
///     [["public/eiface.h::INTERFACEVERSION_VENGINESERVER"]]
///     type = "string"
///     value = "VEngineCvar004"
///
///     [["IN_BUTTONS"]]
///     name = "FIRST"
///     type = "integer"
///     value = 1
///
/// Headers carrying a literal `<class>::<method>` or
/// `<header-path>::<const-name>` composite are emitted quoted, since
/// `:` is not a TOML bare-key character. All emitted row names are
/// unique, so plain `[<name>]` and `[[<name>]]` tables never collide.
pub fn intoToml(
    io: std.Io,
    toml_path: []const u8,
    analysis: *const AnalyzerOutput,
) !void {
    if (analysis.stdout.len == 0) return error.EmptyAnalyzerOutput;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var rows: std.ArrayList(TomlRow) = .empty;
    var lines = std.mem.splitScalar(u8, analysis.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        try addAnalyzerLine(analysis.queries, &rows, alloc, line);
    }

    if (rows.items.len == 0) return error.EmptyAnalyzerOutput;

    var output: std.ArrayList(u8) = .empty;
    for (rows.items) |*row| {
        try output.appendSlice(alloc, "[[");
        try appendTomlBasicString(&output, alloc, row.header);
        try appendSlice(&output, alloc, "]]\n");

        for (row.fields.items) |field| {
            try appendSlice(&output, alloc, field.key);
            try appendSlice(&output, alloc, " = ");
            try appendSlice(&output, alloc, field.value);
            try output.append(alloc, '\n');
        }
        try output.append(alloc, '\n');
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = toml_path,
        .data = output.items,
    });
}
