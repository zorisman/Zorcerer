//! Finds a C++ class's vtable address at runtime, for the cases where
//! there's no CreateInterface-exposed singleton to call
//! VTableHooks.vtableOf on directly - e.g. entity classes like CTFPlayer,
//! which aren't reachable through any interface factory, only through a
//! live instance you may not have yet. The result is exactly the `vtable:
//! VTableHooks.VTable` value VtableHook.install needs.
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
//! *** UNVERIFIED, LIKELY THE WEAKEST PART OF THIS FILE ***
//! `readProcSelfMaps` is the one piece of this file that does blocking
//! file I/O, which is exactly the area Zig 0.16 reworked most (the
//! std.Io interface). I could not compile-check this against a real 0.16
//! toolchain, so if something here doesn't build, start by looking at
//! that one function - the actual RTTI-chasing logic in `resolveViaRtti`
//! only operates on plain byte slices and raw addresses, and doesn't
//! depend on how you got the maps text into memory. If
//! `std.fs.openFileAbsolute`/`File.read` don't match your toolchain,
//! swap `readProcSelfMaps`'s body for whatever your project already uses
//! to read a file, or for a raw `std.os.linux.read`-based loop - either
//! way, just hand `moduleRanges` the resulting text.
//!
//! Also note: dlsym/dlopen aren't raw syscalls (there's no such thing as
//! a "dlopen syscall" - the dynamic linker implements them), so this file
//! needs libc linked in, unlike the rest of this project so far. Since
//! engine_adapter.cpp already pulls in libstdc++ (and transitively libc)
//! for the C++ runtime, this shouldn't add a new practical dependency.

const std = @import("std");
const VTableHooks = @import("VTableHooks.zig");

const RTLD_NOW: c_int = 2;
const RTLD_NOLOAD: c_int = 4;

// If you wonder, why AI used extern functions instead of std.c or std.DynLib, there are the reasons I faced before:
// 1. std.c requires a linkage with C standard library, which is not really needed since Source engine already links it. The less symbols library contains, the less size it has.
// 2. std.DynLib causes segfault. I think the reason hides somewhere in conflicts between GNU and LLVM ABI.
extern fn dlopen(path: ?[*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

pub const ResolveError = error{
    ModuleNotFound,
    NameTooLong,
    NotFound,
} || std.mem.Allocator.Error;

pub const MappedRange = struct {
    start: usize,
    end: usize,
};

/// Reads /proc/self/maps into `buf` (whole file, must fit - a few hundred
/// KB is typical even for a large process; size accordingly). See the
/// module doc-comment: this is the one function most likely to need
/// adapting to your exact Zig version.
pub fn readProcSelfMaps(buf: []u8) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute("/proc/self/maps", .{});
    defer file.close();

    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.read(buf[total..]);
        if (n == 0) break;
        total += n;
    }

    return buf[0..total];
}

/// Every mapped, readable range whose /proc/self/maps line contains
/// `module_substr` (e.g. "server.so"). `maps_text` is the file's contents,
/// however you obtained them (see `readProcSelfMaps`).
pub fn moduleRanges(
    allocator: std.mem.Allocator,
    maps_text: []const u8,
    module_substr: []const u8,
) ResolveError![]MappedRange {
    var ranges: std.ArrayList(MappedRange) = .empty;
    errdefer ranges.deinit(allocator);

    var lines = std.mem.splitScalar(u8, maps_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, module_substr) == null) continue;

        const dash = std.mem.indexOfScalar(u8, line, '-') orelse continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (space <= dash) continue;

        const start = std.fmt.parseUnsigned(usize, line[0..dash], 16) catch continue;
        const end = std.fmt.parseUnsigned(usize, line[dash + 1 .. space], 16) catch continue;

        const perms_start = space + 1;
        if (perms_start >= line.len or line[perms_start] != 'r') continue; // skip unreadable ranges

        try ranges.append(allocator, .{ .start = start, .end = end });
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

fn findAllOccurrences(
    allocator: std.mem.Allocator,
    ranges: []const MappedRange,
    needle: []const u8,
) !std.ArrayList(usize) {
    var found: std.ArrayList(usize) = .empty;
    errdefer found.deinit(allocator);

    for (ranges) |range| {
        const len = range.end - range.start;
        if (len < needle.len) continue;
        const haystack: [*]const u8 = @ptrFromInt(range.start);

        var i: usize = 0;
        while (i <= len - needle.len) : (i += 1) {
            if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
                try found.append(allocator, range.start + i);
            }
        }
    }

    return found;
}

fn findAllPointersTo(
    allocator: std.mem.Allocator,
    ranges: []const MappedRange,
    target: usize,
) !std.ArrayList(usize) {
    var found: std.ArrayList(usize) = .empty;
    errdefer found.deinit(allocator);

    for (ranges) |range| {
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
/// `module_name` should be the same name/path the module already appears
/// under - whatever string shows up for it in /proc/self/maps is a safe
/// choice, since that's what this is cross-checked against anyway.
pub fn resolveViaSymbol(module_name: [:0]const u8, class_name: []const u8) ?VTableHooks.VTable {
    const handle = dlopen(module_name.ptr, RTLD_NOW | RTLD_NOLOAD) orelse return null;

    var mangled_buf: [256]u8 = undefined;
    const mangled = mangleSimpleName(&mangled_buf, class_name) catch return null;

    var symbol_buf: [260]u8 = undefined;
    const symbol = std.fmt.bufPrintZ(&symbol_buf, "_ZTV{s}", .{mangled}) catch return null;

    const sym = dlsym(handle, symbol.ptr) orelse return null;
    return @ptrCast(@alignCast(sym));
}

/// Walks the RTTI chain by scanning already-mapped memory; see the module
/// doc-comment for the chain this follows and why there can be more than
/// one result. `ranges` should cover every VMA belonging to the target
/// module (see `moduleRanges`) - vtables and their RTTI data can land in
/// different segments (.rodata, .data.rel.ro, ...) depending on how the
/// module was built.
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
/// The caller owns the returned slice either way (free with
/// `allocator.free`) - a successful symbol match is still wrapped in a
/// freshly-allocated single-element slice, so freeing is uniform
/// regardless of which path actually resolved it.
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
