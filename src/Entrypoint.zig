//! Foundation for loading our plugin loader into a TF2 dedicated server as
//! a Valve Server Plugin (VSP) - the same, Valve-documented mechanism
//! Metamod:Source itself uses to get loaded, rather than substituting or
//! LD_PRELOAD-wrapping server.so/engine.so.
//!
//! Engine-side indices and version strings come from exactly one place:
//! codegen_generated/engine_indexes.zig. That file is committed by hand;
//! its producer, build/EngineIndexesGenerator.zig, is not wired into the
//! build yet. Nothing in this file hand-maintains an index or a version
//! string of its own.
//!
//! Engine version handling in `load` no longer needs the removed
//! src/analyzers/EngineVersions.zig: the engine server interface is
//! probed directly against the version strings the codegen module knows
//! (see engine_interface_versions), and the version check in load()
//! refuses every build whose answered string does not equal the one the
//! codegen indices were generated for. That leaves the version probe
//! reduced to "which string answered" - the part the removed module used
//! to own.
//!
//! The plugin manager itself runs in a forked child process. `load` forks it
//! through `forkChild`, the child loads the plugins (`pluginManagerChild`) and
//! reports over a socket pair, and this process consumes that report through
//! `jsonListener`. Reports are JSON objects: `{"operation": "stderr",
//! "message": "..."}` currently means "write message to stderr". `unload`
//! closes the parent's socket end, which tells the child to unload its plugins
//! and exit, then reaps it.
//!
//! *** VERIFY BEFORE USE ***
//! The IServerPluginCallbacks method list below follows the Valve
//! Developer Wiki (https://developer.valvesoftware.com/wiki/IServerPluginCallbacks)
//! and the historical public/engine/iserverplugin.h header. The first
//! nine methods (Load through LevelShutdown) have been stable across
//! every version of this interface I could find and are implemented for
//! real. Everything after that - the client/command callbacks added in
//! later interface versions (ClientConnect, ClientCommand,
//! NetworkIDValidated, OnQueryCvarValueFinished, OnEdictAllocated/Freed,
//! ...) - is backed by `genericStub`, a placeholder that safely ignores
//! whatever arguments it's called with and returns 0 (== false ==
//! PLUGIN_CONTINUE == null, a safe default for all of them).
//!
//! This padding exists so that if your exact TF2 build's interface has a
//! few more trailing methods than the nine implemented here, the engine
//! calling into one of them lands on a harmless no-op instead of jumping
//! into unmapped memory. It is NOT a substitute for implementing the
//! callbacks you actually want to act on - look up their real position
//! in your hl2sdk-tf2 checkout (public/engine/iserverplugin.h) and
//! replace the matching stub slot. `stub_count` is a guess at "more than
//! enough"; too large is harmless (an unindexed stub is simply never
//! called), but too *small* for your build's real interface means a call
//! past the end of the array - a crash. When in doubt, raise it.
//!
//! `plugin_interface_versions` - the versions of *our own*
//! IServerPluginCallbacks *we* claim to implement - is a separate concern
//! from engine-side detection: a wrong entry there just means
//! CreateInterface returns null for it and the engine tries the next one
//! (or logs an error and moves on) - it can't crash anything the way a
//! wrong engine-side vtable index can, so it doesn't need the same
//! verified-match treatment, even though it now comes from the codegen
//! too (consistency, not safety).
//!
//! Build with `zig build`: the result is zig-out/lib/zorcerer.so, built
//! for the x86_64-linux-gnu target configured in build.zig. Drop the .so
//! at `<mod>/addons/<name>.so` alongside a matching .vdf, e.g.
//! `tf/addons/zorcerer.so` + `tf/addons/zorcerer.vdf`. For fast iteration
//! without restarting the server, the engine also supports
//! loading/unloading a VSP interactively from the server console:
//! `plugin_load addons/zorcerer` / `plugin_unload <index>` (index shown
//! by `plugin_print`) - no .vdf needed while testing. Note `plugin_load`
//! only works before a map is running (see the console-command discussion
//! earlier) - the .vdf route is what actually loads this on a live server.

const std = @import("std");
const VTableHooks = @import("hooks").VTableHook;
const Indexes = @import("codegen_generated/engine_indexes.zig");
const Manager = @import("PluginManager.zig");
const Log = @import("root.zig").Log;
const abi = @import("root.zig").abi;

pub const CreateInterfaceFn = *const fn (name: [*:0]const u8, return_code: ?*c_int) callconv(.c) ?*anyopaque;

const iface_ok: c_int = 0;
const iface_failed: c_int = 1;

/// Version strings this plugin answers to, newest first. All of them get
/// the same vtable - the padding described above is what makes that safe.
const plugin_interface_versions = [_][]const u8{
    Indexes.interfaceversion_iserverplugincallbacks,
    Indexes.interfaceversion_iserverplugincallbacks_version_2,
    Indexes.interfaceversion_iserverplugincallbacks_version_1,
};

const Slot = ?*const anyopaque;

/// IVEngineServer interface version strings the engine module might
/// answer with, newest first. Both these strings and the LogPrint slot
/// index that logPrintOf() consumes come from the same codegen module,
/// so engine probing and index use agree on which engine build the slot
/// layout was recorded for. Order: the current build answers with the
/// exact string the codegen generated for, while older recognized builds
/// surface only through the fallback constants.
const engine_interface_versions = [_][]const u8{
    Indexes.interfaceversion_vengineserver,
    Indexes.interfaceversion_vengineserver_version_22,
    Indexes.interfaceversion_vengineserver_version_21,
};

/// An IServerPluginCallbacks instance is just a vptr as far as the engine
/// is concerned - no RTTI header to worry about, since nothing does
/// dynamic_cast/typeid on a plugin interface the engine loaded generically.
const PluginObject = extern struct {
    vptr: [*]const Slot,
};

var plugin_instance = PluginObject{ .vptr = &vtable };
var engine: ?*anyopaque = null;

/// Plugin manager singleton. The forked child (`pluginManagerChild`) uses it to
/// discover/cache the plugin .so files under tf/addons/zorcerer/plugins/ and
/// run each plugin's load() hook. The parent only wires the engine logger into
/// its copy before forking and keeps the manifests from `readConfig()`; the
/// child's own copy is released when it exits (see src/PluginManager.zig).
var plugin_manager = Manager.Manager.init();

/// The forked plugin-manager process, or null while none runs.
var manager_child: ?ForkedChild = null;

/// Pulls the engine's Source SDK console logging function out of a live
/// IVEngineServer instance. `engine_interface` is the interface pointer
/// the engine module factory probe in load() resolved; zig-hooks reads
/// the virtual method table behind it, the slot that
/// codegen_generated/engine_indexes.zig records under
/// `IVEngineServer.log_print` is selected, and its contents are
/// reinterpreted as `abi.Logger.PrintFn` - the signature that matches
/// the LogPrint ABI that index was produced for (this pointer first, then
/// one zero-terminated line).
/// Returns the print function, or null when the recorded slot holds no
/// entry: the running engine then does not match the index layout that
/// every hook installation further down load() relies on.
fn logPrintOf(engine_interface: *anyopaque) ?abi.Logger.PrintFn {
    const slot = VTableHooks.vtableOf(engine_interface)[Indexes.IVEngineServer.log_print];
    return @ptrCast(slot orelse return null);
}

test "logPrintOf resolves the slot the codegen recorded for LogPrint" {
    const fake_log_print: abi.Logger.PrintFn = struct {
        fn print(context: *anyopaque, message: [*:0]const u8) callconv(.c) void {
            _ = context;
            _ = message;
        }
    }.print;

    // A fake IVEngineServer-shaped object: the first member is the vtable
    // pointer, and enough trailing slots exist to reach the recorded
    // LogPrint index.
    var slots = [_]Slot{null} ** (Indexes.IVEngineServer.log_print + 1);
    slots[Indexes.IVEngineServer.log_print] = @ptrCast(fake_log_print);
    var fake = extern struct { vptr: [*]const Slot }{ .vptr = &slots };

    const resolved = logPrintOf(@ptrCast(&fake)).?;
    try std.testing.expectEqual(@intFromPtr(fake_log_print), @intFromPtr(resolved));
}

test "logPrintOf reports a recorded-but-empty LogPrint slot as null" {
    var slots = [_]Slot{null} ** (Indexes.IVEngineServer.log_print + 1);
    var fake = extern struct { vptr: [*]const Slot }{ .vptr = &slots };

    try std.testing.expect(logPrintOf(@ptrCast(&fake)) == null);
}

/// First byte of a child's report. Its presence tells the parent that the
/// child reached the point where it reports; the payload bytes alone are not
/// treated as an initialization signal.
const child_ready_marker: u8 = 0xA5;

/// Maximum payload size, in bytes, that one report can carry.
///
/// Reports are length-framed, so the receiver can reject an oversized frame
/// instead of blocking on a corrupt length.
pub const max_payload_len: usize = 4096;

/// Everything the parent observed while reading one child report.
///
/// The flags are not all-or-nothing: a child that reported readiness and then
/// died can yield `child_initialized == true` with no payload.
pub const ChildReport = struct {
    /// True only when the report started with `child_ready_marker`.
    child_initialized: bool = false,

    /// True when the report carried at least one payload byte. This
    /// distinguishes "some message arrived" from the stronger exact-content
    /// check in `matchesMessage()`.
    message_received: bool = false,

    /// Raw payload bytes. Only the first `message_len` entries are meaningful.
    message: [max_payload_len]u8 = undefined,

    /// Number of valid payload bytes; never exceeds `message.len`.
    message_len: usize = 0,

    /// Returns the received payload.
    ///
    /// The returned slice borrows this report and remains valid for as long as
    /// the report does.
    pub fn text(self: *const ChildReport) []const u8 {
        return self.message[0..self.message_len];
    }

    /// Reports whether the received payload equals `expected`.
    ///
    /// Returns false when a payload of a different length arrived.
    pub fn matchesMessage(self: *const ChildReport, expected: []const u8) bool {
        return std.mem.eql(u8, self.text(), expected);
    }
};

/// Reads exactly `buffer.len` bytes from `fd`.
///
/// Errors: `error.PeerClosed` when the peer closed the socket first;
/// `error.ReadFailed` for any other read failure (see `readAtMost`).
fn readExact(fd: std.os.linux.fd_t, buffer: []u8) !void {
    const read_len = try readAtMost(fd, buffer);
    if (read_len != buffer.len) return error.PeerClosed;
}

/// Reads one framed report: the readiness marker, a little-endian `u32`
/// payload length, and exactly that many payload bytes.
///
/// The returned report owns its payload bytes. A marker that does not match
/// `child_ready_marker` yields `child_initialized == false` and stops reading,
/// because the rest of the frame cannot be interpreted without the marker.
///
/// Errors: `error.PeerClosed` for a truncated frame,
/// `error.PayloadTooLarge` when the announced length exceeds
/// `max_payload_len`, and the read errors documented on `readExact`.
fn readReport(fd: std.os.linux.fd_t) !ChildReport {
    var report = ChildReport{};

    var marker: [1]u8 = undefined;
    try readExact(fd, &marker);
    report.child_initialized = marker[0] == child_ready_marker;
    if (!report.child_initialized) return report;

    var length_bytes: [4]u8 = undefined;
    try readExact(fd, &length_bytes);
    const payload_len: usize = std.mem.readInt(u32, &length_bytes, .little);
    if (payload_len > max_payload_len) return error.PayloadTooLarge;

    try readExact(fd, report.message[0..payload_len]);
    report.message_len = payload_len;
    report.message_received = payload_len > 0;
    return report;
}

/// Writes one framed report to `fd`: the readiness marker, a little-endian
/// `u32` payload length, and the payload itself.
///
/// Writing this frame is the child's signal that it finished initializing, so
/// it must only be called once the child is ready to be observed.
///
/// Errors: `error.PayloadTooLarge` when `payload` exceeds `max_payload_len`,
/// and `error.WriteFailed` (see `writeAll`).
fn writeReport(fd: std.os.linux.fd_t, payload: []const u8) !void {
    if (payload.len > max_payload_len) return error.PayloadTooLarge;

    var header: [5]u8 = undefined;
    header[0] = child_ready_marker;
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);

    try writeAll(fd, &header);
    try writeAll(fd, payload);
}

/// Reads from `fd` until `buffer` is full or the peer closes its end.
///
/// Returns the number of bytes read. Retries interrupted reads. Returns
/// `error.ReadFailed` for any non-`EINTR` read failure.
fn readAtMost(fd: std.os.linux.fd_t, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const rc = std.os.linux.read(fd, buffer[total..].ptr, buffer.len - total);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                total += rc;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
    return total;
}

/// Writes all of `buffer` to `fd`, retrying interrupted and partial writes.
///
/// Returns `error.WriteFailed` when the peer closes the socket or any other
/// write error occurs.
fn writeAll(fd: std.os.linux.fd_t, buffer: []const u8) !void {
    var written: usize = 0;
    while (written < buffer.len) {
        const rc = std.os.linux.write(fd, buffer[written..].ptr, buffer.len - written);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.WriteFailed;
                written += rc;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

/// Waits for `pid` to exit and verifies a successful exit status.
///
/// Retries interrupted waits. Returns `error.WaitFailed` when the wait itself
/// fails and `error.ChildFailed` when the child exited abnormally or with a
/// non-zero status.
fn waitForChild(pid: std.os.linux.pid_t) !void {
    var status: u32 = undefined;
    while (true) {
        const rc = std.os.linux.waitpid(pid, &status, 0);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (!std.os.linux.W.IFEXITED(status) or
                    std.os.linux.W.EXITSTATUS(status) != 0)
                {
                    return error.ChildFailed;
                }
                return;
            },
            .INTR => continue,
            else => return error.WaitFailed,
        }
    }
}

/// Entry point of a forked child. `fd` is the child's end of the IPC socket
/// pair; the parent holds the other end.
///
/// Returning from a child entry point is allowed: `forkChild` exits the child
/// process afterwards, so the child never returns into the parent's stack.
pub const ChildMain = *const fn (fd: std.os.linux.fd_t) void;

/// A forked child plus the parent's end of the IPC socket pair.
pub const ForkedChild = struct {
    /// Process id of the child.
    pid: std.os.linux.pid_t,
    /// Parent's end of the socket pair; see `close`.
    socket: std.os.linux.fd_t,
    /// Whether `socket` is still open; keeps `close` idempotent.
    socket_open: bool = true,

    /// Closes the parent's end of the socket pair, if still open.
    ///
    /// Closing is also how the parent asks a long-lived child to shut down:
    /// the child's read returns EOF and it exits.
    pub fn close(self: *ForkedChild) void {
        if (!self.socket_open) return;
        _ = std.os.linux.close(self.socket);
        self.socket_open = false;
    }

    /// Waits for the child to exit and verifies a zero exit status.
    ///
    /// Does not close `socket`. Use `finish` for the usual shutdown order.
    pub fn wait(self: ForkedChild) !void {
        try waitForChild(self.pid);
    }

    /// Closes the socket (signalling shutdown) and waits for the child.
    ///
    /// The socket is closed even when waiting fails.
    ///
    /// Errors: see `wait`.
    pub fn finish(self: *ForkedChild) !void {
        self.close();
        try waitForChild(self.pid);
    }
};

/// Forks a child that runs `child_main` and returns the parent's handle to it.
///
/// The parent creates a connected `AF_UNIX`/`SOCK_STREAM` pair before forking;
/// the child gets one end, the parent keeps the other in the returned handle.
/// The child exits once `child_main` returns, so a child that should stay alive
/// must block in `child_main`.
///
/// Errors: `error.SocketPairFailed`, `error.ForkUnsupported`, and
/// `error.ForkFailed`. No child exists when one of these is returned.
pub fn forkChild(child_main: ChildMain) !ForkedChild {
    var fds: [2]std.os.linux.fd_t = undefined;
    switch (std.os.linux.errno(std.os.linux.socketpair(
        std.os.linux.AF.UNIX,
        std.os.linux.SOCK.STREAM,
        0,
        &fds,
    ))) {
        .SUCCESS => {},
        else => return error.SocketPairFailed,
    }

    const fork_result = std.os.linux.fork();
    switch (std.os.linux.errno(fork_result)) {
        .SUCCESS => {},
        .NOSYS => {
            _ = std.os.linux.close(fds[0]);
            _ = std.os.linux.close(fds[1]);
            return error.ForkUnsupported;
        },
        else => {
            _ = std.os.linux.close(fds[0]);
            _ = std.os.linux.close(fds[1]);
            return error.ForkFailed;
        },
    }

    const pid: std.os.linux.pid_t = @intCast(fork_result);
    if (pid == 0) {
        _ = std.os.linux.close(fds[0]);
        child_main(fds[1]);
        _ = std.os.linux.close(fds[1]);
        std.os.linux.exit_group(0);
    }

    _ = std.os.linux.close(fds[1]);
    return .{ .pid = pid, .socket = fds[0] };
}

/// Operations the parent's IPC listener understands.
const Operation = enum {
    /// Write `message` to the process' standard error stream.
    stderr,
};

/// One request sent by a child over the IPC socket.
///
/// This is the JSON schema spoken over the socket:
///
///     {"operation": "stderr", "message": "Hello from fork"}
const Request = struct {
    /// What the parent should do with `message`.
    operation: Operation,
    /// Payload for `operation`; for `.stderr` it is printed verbatim.
    message: []const u8,
};

/// Parses one JSON request.
///
/// Unknown operations and unknown keys are rejected, so a typo in the schema
/// cannot silently turn into a no-op. The returned value borrows `allocator`
/// until `deinit()`.
fn parseRequest(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(Request) {
    return std.json.parseFromSlice(Request, allocator, text, .{});
}

/// Executes one request received from a child.
fn handleRequest(request: Request) void {
    switch (request.operation) {
        .stderr => std.debug.print("{s}", .{request.message}),
    }
}

/// Parent-side listener: reads one framed report from `socket`, decodes the
/// JSON request it carries, and executes it.
///
/// Errors: the framing errors of `readReport`, `error.ChildNotInitialized`
/// when the child never reached its report, `error.EmptyMessage` for a
/// zero-length report, and the JSON errors of `parseRequest`.
fn jsonListener(socket: std.os.linux.fd_t) !void {
    const report = try readReport(socket);
    if (!report.child_initialized) return error.ChildNotInitialized;
    if (!report.message_received) return error.EmptyMessage;

    const request = try parseRequest(std.heap.page_allocator, report.text());
    defer request.deinit();
    handleRequest(request.value);
}

/// Serializes `request` to JSON and sends it to the parent as one framed
/// report.
///
/// Errors: `error.PayloadTooLarge` or `error.WriteFailed` from `writeReport`,
/// and `error.WriteFailed` when the request does not fit the stack buffer.
fn sendRequest(fd: std.os.linux.fd_t, request: Request) !void {
    var buffer: [max_payload_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(request, .{}, &writer);
    try writeReport(fd, writer.buffered());
}

/// Message the plugin-manager child reports once it has loaded its plugins.
const manager_ready_message = "Hello from fork";

/// Child body: loads the plugin manager, reports readiness to the parent, and
/// waits for the parent to close the socket before unloading the plugins.
///
/// The report is sent after the load attempt finishes, whether or not any
/// plugins were found: it is a readiness signal for the parent, not a success
/// report. A failed attempt is appended to the same message so the parent sees
/// both the readiness line and the reason the plugin set may be empty.
///
/// Unlike a minimal reporting child, this one allocates and performs file and
/// dynamic-library I/O while loading plugins. That is safe only as long as the
/// parent is effectively single-threaded when `forkChild` is called, which
/// holds for the engine's VSP `Load` call.
fn pluginManagerChild(fd: std.os.linux.fd_t) void {
    // `message` borrows `failure`, so the buffer lives until the send below.
    var failure: [256]u8 = undefined;
    const message: []const u8 = load: {
        plugin_manager.loadPlugins() catch |err| {
            break :load std.fmt.bufPrint(
                &failure,
                "Hello from fork\nplugin loading failed: {s}",
                .{@errorName(err)},
            ) catch manager_ready_message;
        };
        break :load manager_ready_message;
    };

    sendRequest(fd, .{ .operation = .stderr, .message = message }) catch {};
    waitForShutdown(fd);
    plugin_manager.deinit();
}

/// Blocks until the parent closes its end of the socket pair.
///
/// Anything the parent sends is discarded for now; the supported direction of
/// the protocol is child to parent.
fn waitForShutdown(fd: std.os.linux.fd_t) void {
    var scratch: [64]u8 = undefined;
    while (true) {
        const received = readAtMost(fd, &scratch) catch return;
        if (received == 0) return;
    }
}

/// Child used by the IPC tests: sends the same JSON request the plugin-manager
/// child sends once it is ready.
fn testReportChild(fd: std.os.linux.fd_t) void {
    sendRequest(fd, .{ .operation = .stderr, .message = manager_ready_message }) catch {};
}

test "forked child reports that it initialized" {
    var child = try forkChild(testReportChild);
    defer child.finish() catch {};

    const report = try readReport(child.socket);
    try std.testing.expect(report.child_initialized);
}

test "parent receives a JSON message from the child" {
    var child = try forkChild(testReportChild);
    defer child.finish() catch {};

    const report = try readReport(child.socket);
    try std.testing.expect(report.message_received);

    const request = try parseRequest(std.testing.allocator, report.text());
    defer request.deinit();
    try std.testing.expectEqual(Operation.stderr, request.value.operation);
    try std.testing.expectEqualStrings(manager_ready_message, request.value.message);
}

test "child payload matches the serialized request" {
    var child = try forkChild(testReportChild);
    defer child.finish() catch {};

    const report = try readReport(child.socket);
    try std.testing.expect(report.matchesMessage(
        "{\"operation\":\"stderr\",\"message\":\"Hello from fork\"}",
    ));
}

test "listener schema decodes the stderr operation" {
    const request = try parseRequest(
        std.testing.allocator,
        "{\"operation\": \"stderr\", \"message\": \"Hello from fork\"}",
    );
    defer request.deinit();

    try std.testing.expectEqual(Operation.stderr, request.value.operation);
    try std.testing.expectEqualStrings("Hello from fork", request.value.message);
}

test "listener schema rejects an unknown operation" {
    try std.testing.expectError(
        error.InvalidEnumTag,
        parseRequest(std.testing.allocator, "{\"operation\": \"stdout\", \"message\": \"x\"}"),
    );
}

test "listener schema rejects an unknown field" {
    try std.testing.expectError(
        error.UnknownField,
        parseRequest(
            std.testing.allocator,
            "{\"operation\": \"stderr\", \"message\": \"x\", \"unexpected\": 1}",
        ),
    );
}

fn load(
    this: *anyopaque,
    interface_factory: CreateInterfaceFn,
    game_server_factory: CreateInterfaceFn,
) callconv(.c) bool {
    _ = this;
    _ = game_server_factory;

    // Extracting the Source engine's console logging function, in three
    // steps:
    //   1. Get the engine interface itself out of the engine: probe the
    //      engine module's CreateInterface factory with the IVEngineServer
    //      version strings the codegen knows (newest first) and remember
    //      the string that actually answered.
    //   2. Receive the LogPrint pointer out of that interface via
    //      logPrintOf(), which picks the virtual method table slot the
    //      codegen recorded under IVEngineServer.log_print.
    //   3. Capture both in the Log module as its Source SDK logging sink,
    //      before any load decision is made, so even the refusal messages
    //      below reach the server console. The same print function is
    //      handed to the plugin manager further down.
    //
    // Only a matching engine build is fully trustworthy: for any refused
    // build the single log call in the refusal path may go through a slot
    // whose meaning shifted with the engine version - the accepted
    // trade-off for being able to report the refusal at all. Without any
    // answered engine build there is nothing to extract the logger from
    // and no working channel to report that fact through; the load is
    // refused immediately.
    var probe_version_buf: [32]u8 = undefined;
    const engine_version: []const u8 = version: {
        for (engine_interface_versions) |requested_version| {
            const engine_module_name = std.fmt.bufPrintZ(
                &probe_version_buf,
                "{s}",
                .{requested_version},
            ) catch break :version "";
            engine = interface_factory(engine_module_name.ptr, null);

            if (engine != null) {
                break :version requested_version;
            }
        }
        break :version "";
    };
    if (engine_version.len == 0) {
        return false;
    }

    const print_fn = logPrintOf(engine.?) orelse return false;
    Log.setup(.{ .context = engine.?, .print = print_fn });

    if (!std.mem.eql(u8, engine_version, Indexes.interfaceversion_vengineserver)) {
        Log.logLine(
            "[MyLoader] engine version mismatch: indices are for {s}, engine answered as {s} - refusing to install hooks\n",
            .{ Indexes.interfaceversion_vengineserver, engine_version },
        );
        return false;
    }

    Log.logLine("[MyLoader] Load() reached, engine version confirmed: {s}\n", .{engine_version});

    plugin_manager.setLogger(engine.?, print_fn);

    if (manager_child != null) {
        Log.logLine("[MyLoader] plugin manager is already running; refusing a second one\n", .{});
        return false;
    }

    manager_child = forkChild(pluginManagerChild) catch |err| {
        Log.logLine("[MyLoader] forking the plugin manager failed: {s}\n", .{@errorName(err)});
        return false;
    };

    // Reads the child's first report and executes the JSON request it carries.
    // The child keeps running (and the socket open) afterwards; unload() is
    // what closes the socket and reaps it.
    jsonListener(manager_child.?.socket) catch |err| {
        Log.logLine("[MyLoader] plugin manager startup failed: {s}\n", .{@errorName(err)});
        if (manager_child) |*child| child.finish() catch {};
        manager_child = null;
        return false;
    };

    const manifests: ?[]const Manager.Manifest = plugin_manager.readConfig() catch null;
    if (manifests) |m| {
        for (m) |manifest| {
            std.debug.print("\n{s}: {s}\n", .{ manifest.id, manifest.version });
        }
    }

    return true;
}

fn unload(this: *anyopaque) callconv(.c) void {
    _ = this;
    Log.logLine("[MyLoader] unloading, removing demo hooks.\n", .{});

    if (manager_child) |*child| {
        // Closing our end is the shutdown signal: the child's waitForShutdown
        // sees EOF, unloads its plugins and exits, so finish() can reap it.
        child.finish() catch |err| {
            Log.logLine("[MyLoader] plugin manager shutdown failed: {s}\n", .{@errorName(err)});
        };
        manager_child = null;
    }

    // Releases the manifests the parent parsed in load(). The child's plugin
    // state lived in its own copy of the manager and is already gone.
    plugin_manager.deinit();
    engine = null;
    // The Log module keeps the captured sink: the engine interface stays
    // resident for the whole process lifetime, so it remains valid, and
    // plugin_load/reload re-captures it in load() anyway.
}

fn pause(this: *anyopaque) callconv(.c) void {
    _ = this;
}

fn unpause(this: *anyopaque) callconv(.c) void {
    _ = this;
}

fn getPluginDescription(this: *anyopaque) callconv(.c) [*:0]const u8 {
    _ = this;
    return "MyLoader foundation (Zig)";
}

fn levelInit(this: *anyopaque, map_name: [*:0]const u8) callconv(.c) void {
    _ = this;
    Log.logLine("[MyLoader] LevelInit: {s}\n", .{std.mem.span(map_name)});
}

fn serverActivate(
    this: *anyopaque,
    edict_list: *anyopaque,
    edict_count: c_int,
    client_max: c_int,
) callconv(.c) void {
    _ = this;
    _ = edict_list;
    Log.logLine("[MyLoader] ServerActivate: {d} edicts, {d} max clients\n", .{ edict_count, client_max });
}

fn gameFrame(this: *anyopaque, simulating: bool) callconv(.c) void {
    _ = this;
    _ = simulating;
}

fn levelShutdown(this: *anyopaque) callconv(.c) void {
    _ = this;
    Log.logLine("[MyLoader] LevelShutdown\n", .{});
}

/// Placeholder for every method this foundation doesn't implement yet.
/// Declared with zero parameters on purpose: the calling convention
/// doesn't validate argument count on entry, so this safely ignores
/// whatever registers/stack the real call set up and returns 0 in the
/// return register - false / PLUGIN_CONTINUE / null, whichever the real
/// signature expected. Replace the corresponding slot below once you
/// actually need that callback to do something.
fn genericStub() callconv(.c) usize {
    return 0;
}

/// "More than enough" trailing slots for interface versions newer than
/// what's implemented above. Raise this if your SDK header has more
/// methods than this accounts for; see the module doc-comment.
const stub_count = 20;

const vtable = [_]Slot{
    @ptrCast(&load),
    @ptrCast(&unload),
    @ptrCast(&pause),
    @ptrCast(&unpause),
    @ptrCast(&getPluginDescription),
    @ptrCast(&levelInit),
    @ptrCast(&serverActivate),
    @ptrCast(&gameFrame),
    @ptrCast(&levelShutdown),
} ++ ([_]Slot{@ptrCast(&genericStub)} ** stub_count);

export fn CreateInterface(name: [*:0]const u8, return_code: ?*c_int) callconv(.c) ?*anyopaque {
    const requested = std.mem.span(name);
    for (plugin_interface_versions) |version| {
        if (std.mem.eql(u8, requested, version)) {
            if (return_code) |rc| rc.* = iface_ok;
            return @ptrCast(&plugin_instance);
        }
    }
    if (return_code) |rc| rc.* = iface_failed;
    return null;
}
