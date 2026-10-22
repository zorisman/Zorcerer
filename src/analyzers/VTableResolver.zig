//! Finds a C++ class's vtable address at runtime, for the cases where
//! there's no CreateInterface-exposed singleton to call the hook library's
//! `VTableHook.vtableOf` on directly - e.g. entity classes like CTFPlayer,
//! which aren't reachable through any interface factory, only through a
//! live instance you may not have yet.
//!
//! Everything here returns exactly the `VTable` value that
//! `VTableHooks.VtableHook.install` consumes (the `hooks` build module,
//! extern/zig-hooks/src/hooks/VTableHook.zig): a pointer to the vtable's
//! function-pointer array (index 0 = first virtual method) - precisely what
//! an Itanium-ABI object's vptr holds. Never the raw `_ZTV` symbol base,
//! which sits `VTableHooks.header_words` words earlier in the vtable
//! group (offset-to-top, then the type_info pointer).
//!
//! Two strategies, tried in order by `resolve`:
//!
//!   1. Direct symbol lookup (`resolveViaSymbol`): dlsym the module for
//!      the mangled `_ZTV<class>` vtable symbol. Fast and exact when it
//!      works - several Source engine binaries (server.so in particular)
//!      still export plenty of class vtables with default visibility.
//!
//!   2. RTTI memory scan (`resolveViaRtti`), when the symbol isn't
//!      exported/visible: walks the Itanium C++ ABI's RTTI chain
//!      backwards, purely from bytes already sitting in the module's own
//!      mapped memory, with no reliance on its symbol table at all:
//!
//!          "<len><ClassName>\0"   (the typeinfo *name* string)
//!            ^
//!            | pointed to by (name field, 2nd word)
//!            |
//!          type_info object
//!            ^
//!            | pointed to by (vtable[-1])
//!            |
//!          the actual vtable  <-- what we want
//!
//!      This can turn up more than one candidate (name collisions,
//!      multiple inheritance sharing one type_info, false positives from
//!      unrelated bytes that happen to match). `resolveViaRtti` returns
//!      every candidate it finds rather than silently picking one -
//!      sanity-check the result yourself (e.g. that a candidate's early
//!      entries look like real code addresses inside the same module)
//!      before trusting it when there's more than one.
//!
//! Scope: plain, non-namespaced, non-templated class names only - the
//! Itanium mangling for "CTFPlayer" is simply "9CTFPlayer" (length +
//! name); namespaced/templated names mangle very differently and aren't
//! handled here.
//!
//! Status: compiles against the Zig 0.16.0 toolchain; its unit tests run
//! through the compile check in src/root.zig. Nothing in production code
//! calls it yet: before using it, pick the install site, and on the RTTI
//! path decide who performs the candidate validation described above.
//!
//! I/O shape of 0.16: reading /proc/self/maps (see `readProcSelfMaps`)
//! needs an explicit `std.Io` handle, exactly like the rest of the
//! project's runtime file I/O (src/PluginManager.zig threads one through
//! as `threaded_io`). Pass the caller's instance in rather than creating
//! another one.

const std = @import("std");
const VTableHooks = @import("hooks").VTableHook;

const RTLD_NOW: c_int = 2;
const RTLD_NOLOAD: c_int = 4;

// If you wonder, why AI used extern functions instead of std.c or std.DynLib, there are the reasons I faced before:
// 1. std.c requires a linkage with C standard library, which is not really needed since Source engine already links it. The less symbols library contains, the less size it has.
// 2. std.DynLib causes segfault. I think the reason hides somewhere in conflicts between GNU and LLVM ABI.
extern fn dlopen(path: ?[*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlclose(handle: ?*anyopaque) c_int;
extern fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

pub const ResolveError = error{
    ModuleNotFound,
    NameTooLong,
    NotFound,
} || std.mem.Allocator.Error;

pub const ReadProcSelfMapsError = std.Io.File.OpenError || std.Io.File.ReadPositionalError || error{
    /// /proc/self/maps did not fit into the supplied buffer; refused
    /// instead of returning a truncated maps text.
    MapDataTooLarge,
};

/// One of the module's mapped memory ranges, as listed in /proc/self/maps.
/// `start` is the first mapped byte (inclusive), `end` is one past the
/// last mapped byte (exclusive). Ranges are page-aligned in practice, so
/// every range is at least `@alignOf(usize)`-aligned. `executable` marks
/// ranges with the 'x' permission bit; the scanning helpers skip these
/// (vtables and RTTI data live in data segments, code references them
/// only through GOT/data indirection - scanning code pages finds only
/// stray immediates, and they're the largest segments, so excluding them
/// is both a speedup and a noise reduction).
///
/// Note the invariant implied by the parsing: ranges are per-VMA, not
/// merged across adjacent mappings that happen to be contiguous.
pub const MappedRange = struct {
    start: usize,
    end: usize,
    executable: bool,
};

/// Reads /proc/self/maps into `buf` (whole file, one syscall series) -
/// typically well over a hundred KB for a Source-engine process
/// (thousands of VMAs); size accordingly. Returns the slice of `buf`
/// actually filled. `io` is the `std.Io` instance the caller owns (see
/// the module doc-comment); this is the only function in this file doing
/// file I/O.
///
/// Refuses to truncate silently: if the whole file does not fit, `buf`
/// exactly fills and one further byte exists, `error.MapDataTooLarge` is
/// returned. File open/read/close failures surface through
/// `std.Io.File.OpenError` / `ReadPositionalError`.
pub fn readProcSelfMaps(io: std.Io, buf: []u8) ReadProcSelfMapsError![]const u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, "/proc/self/maps", .{});
    defer file.close(io);

    const total = try file.readPositionalAll(io, buf, 0);
    if (total == buf.len) {
        var probe = [1]u8{0};
        const more = try file.readPositional(io, &.{&probe}, total);
        if (more != 0) return error.MapDataTooLarge;
    }

    return buf[0..total];
}

/// Every mapped, readable range whose /proc/self/maps line names the
/// target: `module_substr` (e.g. "server.so") is matched against the
/// pathname token only, never against addresses/perms/offsets/inode
/// values, so a substring like "1048577" cannot match an inode field.
/// `maps_text` is the file's contents, however you obtained them (see
/// `readProcSelfMaps`).
///
/// Preconditions: `module_substr` must be non-empty (an empty string
/// matches every file-backed mapping). Anonymous and pseudo-file mappings
/// ([heap], [stack], ...) never match - they have no pathname token,
/// which is correct: the vtables we hunt live in the module's own
/// file-backed segments. Unreadable ranges (e.g. `---p` RELRO holes) are
/// skipped; vtables sit in readable data regardless.
pub fn moduleRanges(
    allocator: std.mem.Allocator,
    maps_text: []const u8,
    module_substr: []const u8,
) ResolveError![]MappedRange {
    var ranges: std.ArrayList(MappedRange) = .empty;
    errdefer ranges.deinit(allocator);

    var lines = std.mem.splitScalar(u8, maps_text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const address = fields.next() orelse continue;
        const perms = fields.next() orelse continue;
        // offset, device, inode precede the pathname; require them so
        // `fields.rest()` is never a shorter line's tail.
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;

        if (perms[0] != 'r') continue; // skip unreadable ranges

        // `rest()` skips only the leading spaces, so pathnames with
        // spaces (common in Steam install paths) arrive intact.
        const pathname = fields.rest();
        if (pathname.len == 0) continue;
        if (std.mem.find(u8, pathname, module_substr) == null) continue;

        const dash = std.mem.findScalar(u8, address, '-') orelse continue;
        const start = std.fmt.parseUnsigned(usize, address[0..dash], 16) catch continue;
        const end = std.fmt.parseUnsigned(usize, address[dash + 1 ..], 16) catch continue;
        if (end < start) continue; // nonsensical line; cannot fold into a range

        try ranges.append(allocator, .{
            .start = start,
            .end = end,
            .executable = std.mem.findScalar(u8, perms, 'x') != null,
        });
    }

    if (ranges.items.len == 0) return error.ModuleNotFound;
    return try ranges.toOwnedSlice(allocator);
}

/// "<decimal length><name>" - the Itanium mangling of a plain,
/// non-namespaced, non-templated class name ("CTFPlayer" -> "9CTFPlayer").
/// This is also exactly the byte *content* of the "typeinfo name for
/// ClassName" (_ZTS...) object, not just its mangled *symbol* name.
fn mangleSimpleName(buf: []u8, class_name: []const u8) ResolveError![]u8 {
    return std.fmt.bufPrint(buf, "{d}{s}", .{ class_name.len, class_name }) catch error.NameTooLong;
}

/// The non-executable counterpart of scanning work: the name string and
/// the pointer arrays this file chases all live in data segments (see
/// `MappedRange.executable`).
fn scanTarget(range: MappedRange) bool {
    return !range.executable;
}

/// Finds the address of every occurrence of `needle` within the ranges to
/// scan (see `scanTarget`). Failures are allocation failures only.
fn findAllOccurrences(
    allocator: std.mem.Allocator,
    ranges: []const MappedRange,
    needle: []const u8,
) !std.ArrayList(usize) {
    var found: std.ArrayList(usize) = .empty;
    errdefer found.deinit(allocator);

    for (ranges) |range| {
        if (!scanTarget(range)) continue;
        const len = range.end - range.start;
        if (len < needle.len) continue;

        const haystack: [*]const u8 = @ptrFromInt(range.start);
        var pos: usize = 0;
        while (std.mem.findPos(u8, haystack[0..len], pos, needle)) |at| {
            try found.append(allocator, range.start + at);
            pos = at + 1;
        }
    }

    return found;
}

/// Finds the address of every `@alignOf(usize)`-aligned pointer-sized
/// word in the ranges to scan (see `scanTarget`) that stores exactly
/// `target`. Range starts are page-aligned, so aligned dereferences are
/// always well-defined.
fn findAllPointersTo(
    allocator: std.mem.Allocator,
    ranges: []const MappedRange,
    target: usize,
) !std.ArrayList(usize) {
    var found: std.ArrayList(usize) = .empty;
    errdefer found.deinit(allocator);

    for (ranges) |range| {
        if (!scanTarget(range)) continue;

        var addr = std.mem.alignForward(usize, range.start, @alignOf(usize));
        while (addr + @sizeOf(usize) <= range.end) : (addr += @sizeOf(usize)) {
            const ptr: *const usize = @ptrFromInt(addr);
            if (ptr.* == target) try found.append(allocator, addr);
        }
    }

    return found;
}

/// Tries dlsym("_ZTV<mangled>") against an already-loaded module. Uses
/// RTLD_NOLOAD so this can only ever hand back a vtable from a module
/// that's genuinely already loaded into the process - it will not load a
/// fresh copy from disk (which would re-run that module's static
/// initializers mid-process, a bad time to discover a second one exists).
/// `module_name` should be the exact path/name the module was loaded
/// under - dlopen's NOLOAD lookup matches the load-time path, and a
/// differently-spelled variant (e.g. through a symlink) of the same file
/// may legitimately fail; the pathname shown for the module in
/// /proc/self/maps is the reliable choice.
///
/// Returns the vtable's function-pointer array (the address point):
/// the dlsym result is advanced by `VTableHooks.header_words` slots to
/// get there. Exact for classes without virtual bases / vcall offsets,
/// which covers the Source SDK classes this resolver targets; the RTTI
/// scan (`resolveViaRtti`) needs no such assumption, so both paths agree.
///
/// The dlopen handle is dropped immediately (dlclose) - with RTLD_NOLOAD
/// it only ever bumped a refcount on a module the process already keeps
/// loaded, so the returned pointer stays valid for the process lifetime.
///
/// Every failure - module not loaded, class name too long to mangle,
/// symbol not exported - collapses into `null` (this strategy is the
/// optional fast path; `resolve` simply falls through to the RTTI scan).
pub fn resolveViaSymbol(module_name: [:0]const u8, class_name: []const u8) ?VTableHooks.VTable {
    const handle = dlopen(module_name.ptr, RTLD_NOW | RTLD_NOLOAD) orelse return null;
    defer _ = dlclose(handle);

    var mangled_buf: [256]u8 = undefined;
    const mangled = mangleSimpleName(&mangled_buf, class_name) catch return null;

    var symbol_buf: [260]u8 = undefined;
    const symbol = std.fmt.bufPrintZ(&symbol_buf, "_ZTV{s}", .{mangled}) catch return null;

    const sym = dlsym(handle, symbol.ptr) orelse return null;
    return @ptrFromInt(@intFromPtr(sym) + VTableHooks.header_words * @sizeOf(VTableHooks.Slot));
}

/// Walks the RTTI chain by scanning already-mapped memory; see the module
/// doc-comment for the chain this follows and why there can be more than
/// one result. `ranges` should cover every VMA belonging to the target
/// module (see `moduleRanges`) - vtables and their RTTI data can land in
/// different segments (.rodata, .data.rel.ro, ...) depending on how the
/// module was built.
///
/// The scans have two known-harmless extra candidates that appear for
/// every resolution and are discarded by the chain itself, but cost a
/// wasted sweep each: the `_ZTS...` string's sibling copy in .dynstr,
/// and address-sized immediates/other pointer slots that alias a
/// candidate. Callers therefore must not assume the returned slice is
/// minimal - only that it contains the real vtable when one exists.
pub fn resolveViaRtti(
    allocator: std.mem.Allocator,
    ranges: []const MappedRange,
    class_name: []const u8,
) ResolveError![]VTableHooks.VTable {
    var mangled_buf: [256]u8 = undefined;
    const mangled = try mangleSimpleName(&mangled_buf, class_name);

    var name_buf: [258]u8 = undefined;
    const needle = std.fmt.bufPrint(&name_buf, "{s}\x00", .{mangled}) catch return error.NameTooLong;

    var name_hits = try findAllOccurrences(allocator, ranges, needle);
    defer name_hits.deinit(allocator);
    if (name_hits.items.len == 0) return error.NotFound;

    var typeinfo_addrs: std.ArrayList(usize) = .empty;
    defer typeinfo_addrs.deinit(allocator);
    for (name_hits.items) |name_addr| {
        var pointers_to_name = try findAllPointersTo(allocator, ranges, name_addr);
        defer pointers_to_name.deinit(allocator);
        for (pointers_to_name.items) |field_addr| {
            // `name` is type_info's second word, right after its own
            // vtable pointer at offset 0.
            try typeinfo_addrs.append(allocator, field_addr - @sizeOf(usize));
        }
    }
    if (typeinfo_addrs.items.len == 0) return error.NotFound;

    var vtables: std.ArrayList(VTableHooks.VTable) = .empty;
    errdefer vtables.deinit(allocator);
    for (typeinfo_addrs.items) |typeinfo_addr| {
        var pointers_to_typeinfo = try findAllPointersTo(allocator, ranges, typeinfo_addr);
        defer pointers_to_typeinfo.deinit(allocator);
        for (pointers_to_typeinfo.items) |slot_minus_one_addr| {
            // vtable[-1] holds &typeinfo; the actual vtable (the address
            // point an object's vptr would hold) is one word further on.
            const vtable_addr = slot_minus_one_addr + @sizeOf(usize);
            const vtable: VTableHooks.VTable = @ptrFromInt(vtable_addr);

            var already_have = false;
            for (vtables.items) |existing| {
                if (existing == vtable) {
                    already_have = true;
                    break;
                }
            }
            if (!already_have) try vtables.append(allocator, vtable);
        }
    }
    if (vtables.items.len == 0) return error.NotFound;
    return try vtables.toOwnedSlice(allocator);
}

/// Tries the fast, exact symbol route first; falls back to the RTTI scan
/// over `ranges` (see `moduleRanges` for how to get those) if that fails.
/// Returns every candidate the chosen path produced (a successful symbol
/// match is a freshly-allocated single-element slice, so owning the
/// result is uniform regardless of the path; free with `allocator.free`).
/// The caller owns `ranges`; this file never allocates into them.
///
/// `resolveViaSymbol` never errors (it null-falls back), so this
/// function's error set is dominated by the RTTI scan's: `NotFound`,
/// `NameTooLong` (both from mangling and the scan), `ModuleNotFound`
/// (only returned by `moduleRanges`, not this function), plus OOM.
pub fn resolve(
    allocator: std.mem.Allocator,
    module_name: [:0]const u8,
    ranges: []const MappedRange,
    class_name: []const u8,
) ResolveError![]VTableHooks.VTable {
    if (resolveViaSymbol(module_name, class_name)) |vtable| {
        const single = try allocator.alloc(VTableHooks.VTable, 1);
        single[0] = vtable;
        return single;
    }
    return resolveViaRtti(allocator, ranges, class_name);
}

const testing = std.testing;

test "mangleSimpleName prefixes the byte length, and rejects overflow" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("9CTFPlayer", try mangleSimpleName(&buf, "CTFPlayer"));

    var tiny: [8]u8 = undefined;
    try testing.expectError(error.NameTooLong, mangleSimpleName(&tiny, "CTFPlayer"));
}

test "moduleRanges keeps only the named module's readable ranges, flags code, and ignores the rest" {
    const maps_text =
        "00400000-00401000 r--p 00000000 08:01 1048577  /home/user/Team Fortress 2/tf/bin/server.so\n" ++
        "00401000-00402000 r-xp 00001000 08:01 1048577  /home/user/Team Fortress 2/tf/bin/server.so\n" ++
        "00402000-00403000 ---p 00002000 08:01 1048577  /home/user/Team Fortress 2/tf/bin/server.so\n" ++
        "7f0000002000-7f0000003000 r--p 00000000 08:01 1048661  /etc/ld.so.cache\n" ++
        "7f0000004000-7f0000005000 rw-p 00000000 00:00 0  [heap]\n" ++
        "7f0000006000-7f0000007000 rwxp 00000000 08:01 1048578  /home/user/other/game.so";

    const ranges = try moduleRanges(testing.allocator, maps_text, "server.so");
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 2), ranges.len);

    try testing.expectEqual(@as(usize, 0x00400000), ranges[0].start);
    try testing.expectEqual(@as(usize, 0x00401000), ranges[0].end);
    try testing.expect(!ranges[0].executable);

    try testing.expectEqual(@as(usize, 0x00401000), ranges[1].start);
    try testing.expectEqual(@as(usize, 0x00402000), ranges[1].end);
    try testing.expect(ranges[1].executable);

    // The unreadable module line is skipped despite matching the substring,
    // non-module pathnames ([heap], ld.so.cache) never match, and pathnames
    // with spaces survive intact:
    const other = try moduleRanges(testing.allocator, maps_text, "game.so");
    defer testing.allocator.free(other);
    try testing.expectEqual(@as(usize, 1), other.len);
    try testing.expectEqual(@as(usize, 0x7f0000006000), other[0].start);
    try testing.expect(other[0].executable);
}

test "moduleRanges reports ModuleNotFound when nothing matches" {
    const maps_text = "00400000-00401000 r--p 00000000 08:01 1048577  /tf/bin/server.so\n";
    try testing.expectError(
        error.ModuleNotFound,
        moduleRanges(testing.allocator, maps_text, "engine.so"),
    );
}

test "resolveViaSymbol fails cleanly (null) on a module the OS cannot resolve" {
    // RTLD_NOLOAD never touches the filesystem for real loads; requesting
    // an absent module is a pure in-process lookup that returns null.
    try testing.expect(resolveViaSymbol("definitely-not-a-module-zorcerer-test", "CTFPlayer") == null);
}
