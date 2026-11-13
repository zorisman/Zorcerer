//! Client-console messages requested by the forked plugin-manager process.
//!
//! The child never dereferences an engine pointer. When a Lua script calls
//! `zostd.client_print()` while handling a `clientCommand` event, the manager
//! sends an `ClientPrint.ClientPrintRequest` to this process and blocks until the
//! Entrypoint answers. `Binding.handle` validates the text again and prints it
//! through the typed `IVEngineServer::ClientPrintf` binding.
//!
//! The target is not carried over IPC: the Entrypoint records the edict passed
//! to `IServerPluginCallbacks::ClientCommand` for the duration of that
//! callback, so a print request can only reach the client whose command is
//! currently being handled. This keeps engine pointers inside the engine
//! process.

const std = @import("std");
const ClientPrint = @import("../ipc/ClientPrint.zig");
const Vtable = @import("Vtable.zig");
const root = @import("zroot");
const Indexes = root.codegen.indexes;
const Log = root.io.Log;

/// The `IVEngineServer` virtuals this binding calls.
///
/// The signature comes from `eiface.h`: `ClientPrintf(edict_t*, const char*)`
/// writes one message to the specified client's console.
pub const EngineOps = struct {
    /// `IVEngineServer::ClientPrintf` at the codegen-recorded slot.
    client_printf: *const fn (
        engine: *anyopaque,
        entity: *anyopaque,
        message: [*:0]const u8,
    ) callconv(.c) void,
};

/// Returns `id` for the audit log when it is a plausible plugin id, or
/// `"unknown"` otherwise.
///
/// Attribution is advisory and comes from the child, so it is never used for
/// access decisions. Bounding its length and rejecting control characters
/// keeps a malformed id from corrupting or inflating the log line.
fn displayPluginId(id: []const u8) []const u8 {
    if (id.len == 0 or id.len > 64) return "unknown";
    for (id) |byte| {
        if (byte < 0x20 or byte == 0x7f) return "unknown";
    }
    return id;
}

/// The engine-facing side of client-console messages.
///
/// One instance lives in the engine process. It is filled by the Entrypoint
/// while the engine interfaces are available and cleared during unload.
/// `context` handed to the JSON-RPC listener is a pointer to this value, so it
/// must not move while the listener is running.
pub const Binding = struct {
    /// Bound `IVEngineServer`, or null before `load()` and after `unload()`.
    engine: ?*anyopaque = null,
    /// Resolved engine virtuals, or null while unbound.
    ops: ?EngineOps = null,
    /// Edict that issued the client command currently being handled, or null
    /// outside a `ClientCommand` callback.
    active_edict: ?*anyopaque = null,
    /// Whether `ClientPrintf` ran for the current client command. The
    /// Entrypoint uses this to decide between `PLUGIN_STOP` and
    /// `PLUGIN_CONTINUE`.
    printed: bool = false,
    /// Whether a print is currently being handed to the engine. Guards against
    /// re-entering the print path if `ClientPrintf` triggers an engine callback
    /// that reaches this module again.
    printing: bool = false,

    /// Resolves the client-print virtual from `engine`.
    ///
    /// Precondition: `engine` is a live `IVEngineServer` of the build the
    /// codegen indices were generated for. The Entrypoint's version gate
    /// enforces that before calling this function.
    pub fn bind(self: *Binding, engine: *anyopaque) void {
        self.engine = engine;
        self.ops = .{
            .client_printf = @ptrCast(Vtable.slot(
                engine,
                Indexes.IVEngineServer.client_printf,
            )),
        };
    }

    /// Forgets the engine binding and any client-command state. Called from the
    /// VSP `unload` callback.
    pub fn clear(self: *Binding) void {
        self.engine = null;
        self.ops = null;
        self.active_edict = null;
        self.printed = false;
        self.printing = false;
    }

    /// Starts one `ClientCommand` exchange.
    ///
    /// `edict` is the issuing player and is borrowed only for the duration of
    /// the callback. Precondition: the previous exchange has finished; VSP
    /// callbacks are not reentrant.
    pub fn beginCommand(self: *Binding, edict: *anyopaque) void {
        self.active_edict = edict;
        self.printed = false;
    }

    /// Finishes one `ClientCommand` exchange.
    ///
    /// Returns whether a message was printed to the active client and clears
    /// the active edict. The returned value selects `PLUGIN_STOP` or
    /// `PLUGIN_CONTINUE` in the Entrypoint.
    pub fn endCommand(self: *Binding) bool {
        const printed = self.printed;
        self.active_edict = null;
        self.printed = false;
        return printed;
    }

    /// Validates one client-print request, prints it to the active client, and
    /// returns a JSON result document.
    ///
    /// `context` is a pointer to the `Binding` kept by the Entrypoint. The
    /// returned text is allocated with `allocator` and owned by the caller.
    ///
    /// The message is accepted, not confirmed: `ClientPrintf` returns no status,
    /// so an undisplayed message is only observable through the client's
    /// console. The client receives the message while the engine is inside
    /// `ClientCommand`, so no pointer outlives the callback.
    ///
    /// Errors: `error.ClientPrintUnavailable` when no engine binding is
    /// present, `error.ClientPrintNoActiveClient` when no `ClientCommand`
    /// exchange is active, `error.ClientPrintReentered` for a nested print
    /// request, the `ClientPrint.ClientPrintError` variants from
    /// `ClientPrint.validate`, and `error.OutOfMemory` while building the
    /// result document.
    pub fn handle(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: ClientPrint.ClientPrintRequest,
    ) anyerror![]u8 {
        const raw_context = context orelse return error.ClientPrintUnavailable;
        const self: *Binding = @ptrCast(@alignCast(raw_context));
        const engine = self.engine orelse return error.ClientPrintUnavailable;
        const ops = self.ops orelse return error.ClientPrintUnavailable;
        const entity = self.active_edict orelse return error.ClientPrintNoActiveClient;

        if (self.printing) return error.ClientPrintReentered;
        try ClientPrint.validate(request.message);

        // `ClientPrintf` takes a C string, so the message must be terminated.
        var buffer: [ClientPrint.max_client_print_len + 1]u8 = undefined;
        @memcpy(buffer[0..request.message.len], request.message);
        buffer[request.message.len] = 0;

        Log.logLine("[Zorcerer] client print from {s}: {s}\n", .{
            displayPluginId(request.plugin_id),
            request.message,
        });

        self.printing = true;
        defer self.printing = false;
        ops.client_printf(engine, entity, @ptrCast(buffer[0..].ptr));
        self.printed = true;

        return std.json.Stringify.valueAlloc(
            allocator,
            ClientPrint.ClientPrintResult{ .printed = true },
            .{},
        );
    }
};

test "client print binding forwards one message to the active client" {
    var sink = PrintSink{};
    var binding = Binding{
        .engine = &sink,
        .ops = .{ .client_printf = PrintSink.print },
    };

    var edict: u8 = 0;
    binding.beginCommand(&edict);
    const text = try Binding.handle(
        &binding,
        std.testing.allocator,
        .{ .message = "Pong!", .plugin_id = "demo" },
    );
    defer std.testing.allocator.free(text);

    var parsed = try std.json.parseFromSlice(
        ClientPrint.ClientPrintResult,
        std.testing.allocator,
        text,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.value.printed);
    try std.testing.expectEqualStrings("Pong!", sink.message());
    try std.testing.expect(sink.edict == @as(?*anyopaque, &edict));
    try std.testing.expect(binding.endCommand());
}

test "client print binding rejects requests without an active client" {
    var sink = PrintSink{};
    var binding = Binding{
        .engine = &sink,
        .ops = .{ .client_printf = PrintSink.print },
    };

    try std.testing.expectError(
        error.ClientPrintNoActiveClient,
        Binding.handle(&binding, std.testing.allocator, .{ .message = "Pong!" }),
    );
    try std.testing.expect(sink.len == 0);
}

test "client print binding rejects invalid text before the engine call" {
    var sink = PrintSink{};
    var binding = Binding{
        .engine = &sink,
        .ops = .{ .client_printf = PrintSink.print },
    };

    var edict: u8 = 0;
    binding.beginCommand(&edict);

    try std.testing.expectError(
        error.EmptyClientPrint,
        Binding.handle(&binding, std.testing.allocator, .{ .message = " \t" }),
    );
    try std.testing.expectError(
        error.MultilineClientPrint,
        Binding.handle(&binding, std.testing.allocator, .{ .message = "one\ntwo" }),
    );
    try std.testing.expect(sink.len == 0);
    try std.testing.expect(!binding.endCommand());
}

/// Records calls to a fake `IVEngineServer::ClientPrintf`.
const PrintSink = struct {
    /// Edict pointer passed by the binding.
    edict: ?*anyopaque = null,
    /// Message bytes without the terminating NUL.
    buffer: [ClientPrint.max_client_print_len]u8 = undefined,
    /// Number of valid bytes in `buffer`.
    len: usize = 0,

    /// Copies one message. The signature matches
    /// `EngineOps.client_printf`.
    fn print(
        engine: *anyopaque,
        entity: *anyopaque,
        text_z: [*:0]const u8,
    ) callconv(.c) void {
        const self: *PrintSink = @ptrCast(@alignCast(engine));
        self.edict = entity;
        const text = std.mem.span(text_z);
        @memcpy(self.buffer[0..text.len], text);
        self.len = text.len;
    }

    /// Returns the recorded message.
    fn message(self: *const PrintSink) []const u8 {
        return self.buffer[0..self.len];
    }
};
