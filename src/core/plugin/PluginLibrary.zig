//! Dynamic-library loading for native plugins.
//!
//! The loader is deliberately independent of the plugin manager's filesystem
//! scan and dependency graph: it opens exactly one library path, resolves the
//! ABI exports declared in the shared `plugin-context` module, and reports
//! failures as structured reasons instead of log messages. The manager turns
//! those reasons into its `ManagerEvent` notifications and decides which
//! dependent plugins must be skipped.

const std = @import("std");
const abi = @import("plugin-context");

/// Why a dynamic library was rejected before its plugin could be activated.
pub const RejectionReason = enum {
    /// The library path does not name an existing file.
    library_not_found,
    /// The host found the file but could not load it as a usable dynamic
    /// library (for example an invalid ELF image or a missing dependency).
    invalid_configuration,
    /// The library loaded, but one of the required ABI exports is absent.
    missing_symbol,

    /// Returns a short human-readable description for logs and events.
    ///
    /// Side effects: none.
    pub fn text(self: @This()) []const u8 {
        return switch (self) {
            .library_not_found => "dynamic library not found",
            .invalid_configuration => "invalid dynamic library configuration",
            .missing_symbol => "missing load() or unload() symbol",
        };
    }
};

/// A successfully opened plugin library.
///
/// Invariants: `handle` is an open system library handle and both required
/// function pointers were resolved from it. `on_event` is null when the
/// plugin does not subscribe to runtime events. The pointers remain valid
/// until `close()` and must only be called with a compatible
/// `*abi.PluginContext`.
///
/// Ownership: the value owns the underlying dlopen() handle. Every successful
/// `open()` must be paired with exactly one `close()`.
pub const Library = struct {
    /// Open system handle returned by std.DynLib.open().
    handle: std.DynLib,
    /// Resolved `load` export.
    load: abi.LoadFn,
    /// Resolved `unload` export.
    unload: abi.UnloadFn,
    /// Optional resolved `onEvent` export; null when the plugin omits it.
    on_event: ?abi.OnEventFn,

    /// Closes the underlying library handle.
    ///
    /// After this call every function pointer in this value is stale and the
    /// value must not be closed again.
    pub fn close(self: *@This()) void {
        self.handle.close();
    }
};

/// Details of a library that could not be opened or prepared for loading.
pub const Rejection = struct {
    /// Machine-readable rejection category.
    reason: RejectionReason,
    /// Underlying error when the system loader reported one; null for
    /// missing-symbol rejections, which have no system error.
    detail: ?anyerror = null,
};

/// Result of `open()`.
pub const OpenResult = union(enum) {
    /// The library is open and both ABI exports were resolved.
    loaded: Library,
    /// The library was not opened, or was closed again after a missing
    /// export. The caller keeps no library state.
    rejected: Rejection,
};

/// Opens one plugin library and resolves its `load`/`unload` exports plus the
/// optional `onEvent` export.
///
/// `path` is the exact library path named by the plugin manifest; this
/// function never scans a directory. The returned library owns the dlopen()
/// handle and must be closed by the caller with `Library.close()`.
///
/// Errors are reported through `OpenResult.rejected` rather than Zig errors:
/// - `.library_not_found` when the path does not exist.
/// - `.invalid_configuration` when the system loader refused the file for
///   any other reason.
/// - `.missing_symbol` when the file is usable but lacks `load` or `unload`.
///
/// A rejected result retains no handle and no allocated state.
pub fn open(path: []const u8) OpenResult {
    const handle = std.DynLib.open(path) catch |err| {
        return .{ .rejected = .{
            .reason = switch (err) {
                error.FileNotFound => .library_not_found,
                else => .invalid_configuration,
            },
            .detail = err,
        } };
    };

    var library = Library{
        .handle = handle,
        .load = undefined,
        .unload = undefined,
        .on_event = null,
    };

    library.load = library.handle.lookup(abi.LoadFn, "load") orelse {
        library.close();
        return .{ .rejected = .{ .reason = .missing_symbol } };
    };

    library.unload = library.handle.lookup(abi.UnloadFn, "unload") orelse {
        library.close();
        return .{ .rejected = .{ .reason = .missing_symbol } };
    };

    // Runtime-event delivery is opt-in: a plugin without `onEvent` still
    // loads normally and simply receives no events.
    library.on_event = library.handle.lookup(abi.OnEventFn, "onEvent");

    return .{ .loaded = library };
}

// --- Tests -------------------------------------------------------------------

const build_options = @import("build_options");

/// Builds the smallest valid context for calling a fixture's exports.
fn testContext() abi.PluginContext {
    return .{
        .abi_version = abi.abi_version,
        .struct_size = @sizeOf(abi.PluginContext),
        .logger = null,
        .plugin = .{
            .id = abi.Text.fromSlice("fixture"),
            .name = abi.Text.fromSlice("Loader Fixture"),
            .version = abi.Text.fromSlice("1.0.0"),
            .author = abi.Text.fromSlice("Zorcerer"),
            .library_path = abi.Text.fromSlice("./fixture.so"),
        },
        .game = null,
        .files = null,
        .network = null,
    };
}

test "open reports a missing library as library_not_found" {
    const result = open("this-library-does-not-exist.so");
    try std.testing.expect(result == .rejected);
    try std.testing.expectEqual(RejectionReason.library_not_found, result.rejected.reason);
    try std.testing.expectEqual(@as(?anyerror, error.FileNotFound), result.rejected.detail);
}

test "open rejects a file that is not a usable dynamic library" {
    const result = open(build_options.invalid_library);
    try std.testing.expect(result == .rejected);
    try std.testing.expectEqual(RejectionReason.invalid_configuration, result.rejected.reason);
    try std.testing.expect(result.rejected.detail != null);
}

test "open loads a library exporting load and unload" {
    var result = open(build_options.valid_library);
    try std.testing.expect(result == .loaded);
    try std.testing.expect(result.loaded.on_event == null);

    var ctx = testContext();
    try std.testing.expectEqual(@as(c_int, 0), result.loaded.load(&ctx));
    try std.testing.expectEqual(@as(c_int, 0), result.loaded.unload(&ctx));
    result.loaded.close();
}

test "open resolves the optional onEvent export" {
    var result = open(build_options.event_library);
    try std.testing.expect(result == .loaded);
    const on_event = result.loaded.on_event orelse return error.MissingOnEvent;

    var ctx = testContext();
    var event = abi.Event{
        .struct_size = @sizeOf(abi.Event),
        .name = abi.Text.fromSlice("pause"),
        .payload = abi.Text.fromSlice(""),
    };
    try std.testing.expectEqual(abi.plugin_continue, on_event(&ctx, &event));
    result.loaded.close();
}

test "open rejects a library missing a required export" {
    const result = open(build_options.missing_symbol_library);
    try std.testing.expect(result == .rejected);
    try std.testing.expectEqual(RejectionReason.missing_symbol, result.rejected.reason);
    try std.testing.expect(result.rejected.detail == null);
}
