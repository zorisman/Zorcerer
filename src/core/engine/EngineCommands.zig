//! Engine commands requested by the forked plugin-manager process.
//!
//! The child never dereferences an engine pointer. When a Lua script calls
//! `zostd.server_command()`, the manager sends an `ServerCommand.ServerCommandRequest` to
//! this process and blocks until the Entrypoint answers. `Binding.handle`
//! validates the text again and queues it in the engine command buffer through
//! the typed `IVEngineServer::ServerCommand` binding.
//!
//! Commands are write operations, so this module is deliberately separate from
//! the read-only `GameQueries` module. The Entrypoint remains the trust
//! boundary: the child's validation is only an early diagnostic, and every
//! request is revalidated here before the engine sees it.

const std = @import("std");
const ServerCommand = root.ipc.ServerCommand;
const Vtable = root.core.Vtable;
const root = @import("zroot");
const Indexes = root.codegen.indexes;
const Log = root.io.Log;

/// The `IVEngineServer` virtuals this binding calls.
///
/// The signature comes from `eiface.h`: `ServerCommand(const char *str)` queues
/// one command line in the engine command buffer.
pub const EngineOps = struct {
    /// `IVEngineServer::ServerCommand` at the codegen-recorded slot.
    server_command: *const fn (engine: *anyopaque, command: [*:0]const u8) callconv(.c) void,
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

/// The engine-facing side of command execution.
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
    /// Whether a command is currently being handed to the engine. Guards
    /// against re-entering the command path if `ServerCommand` triggers an
    /// engine callback that reaches this module again.
    executing: bool = false,

    /// Resolves the command virtual from `engine`.
    ///
    /// Precondition: `engine` is a live `IVEngineServer` of the build the
    /// codegen indices were generated for. The Entrypoint's version gate
    /// enforces that before calling this function.
    pub fn bind(self: *Binding, engine: *anyopaque) void {
        self.engine = engine;
        self.ops = .{
            .server_command = @ptrCast(Vtable.slot(
                engine,
                Indexes.IVEngineServer.server_command,
            )),
        };
    }

    /// Forgets the engine binding. Called from the VSP `unload` callback.
    pub fn clear(self: *Binding) void {
        self.engine = null;
        self.ops = null;
        self.executing = false;
    }

    /// Validates one command request, queues it in the engine, and returns a
    /// JSON result document.
    ///
    /// `context` is a pointer to the `Binding` kept by the Entrypoint. The
    /// returned text is allocated with `allocator` and owned by the caller.
    ///
    /// The command is accepted, not confirmed: `IVEngineServer::ServerCommand`
    /// returns no status, so an unknown or rejected engine command is only
    /// reported by the engine console. The engine executes the queued line at
    /// its normal command-buffer point, which avoids re-entering command
    /// handling from inside a VSP callback.
    ///
    /// Errors: `error.CommandUnavailable` when no engine binding is present,
    /// `error.CommandReentered` for a nested command request, the
    /// `ServerCommand.CommandError` variants from `ServerCommand.validate`, and
    /// `error.OutOfMemory` while building the result document.
    pub fn handle(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: ServerCommand.ServerCommandRequest,
    ) anyerror![]u8 {
        const raw_context = context orelse return error.CommandUnavailable;
        const self: *Binding = @ptrCast(@alignCast(raw_context));
        const engine = self.engine orelse return error.CommandUnavailable;
        const ops = self.ops orelse return error.CommandUnavailable;

        if (self.executing) return error.CommandReentered;
        try ServerCommand.validate(request.command);

        // `ServerCommand` appends to the engine's command buffer, so every
        // request must carry its own line terminator; otherwise two commands
        // could run together as one line.
        var buffer: [ServerCommand.max_command_len + 2]u8 = undefined;
        @memcpy(buffer[0..request.command.len], request.command);
        buffer[request.command.len] = '\n';
        buffer[request.command.len + 1] = 0;

        Log.logLine("[Zorcerer] server command from {s}: {s}\n", .{
            displayPluginId(request.plugin_id),
            request.command,
        });

        self.executing = true;
        defer self.executing = false;
        ops.server_command(engine, @ptrCast(buffer[0..].ptr));

        return std.json.Stringify.valueAlloc(
            allocator,
            ServerCommand.ServerCommandResult{ .accepted = true },
            .{},
        );
    }
};
