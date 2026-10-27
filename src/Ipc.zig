//! Framed JSON messages for the IPC channel between `Entrypoint.zig` and the
//! forked plugin-manager process (`PluginManager.zig`).
//!
//! One message is one frame on the connected stream socket created for the
//! fork:
//!
//!     marker (1 byte, 0xA5) | length (u32, little-endian) | JSON payload
//!
//! Both processes use this module, so the framing and the JSON schemas cannot
//! drift apart. `writeAll` sends with `MSG_NOSIGNAL`, so a peer that already
//! exited yields `error.WriteFailed` instead of terminating the process with
//! SIGPIPE.

const std = @import("std");

/// Largest payload, in bytes, one frame may carry.
///
/// The length is read before the payload, so the receiver can reject an
/// oversized frame instead of blocking on a corrupt length.
pub const max_payload_len: usize = 4096;

/// First byte of every frame.
///
/// It distinguishes a frame from a truncated or desynchronized stream: without
/// it the following length bytes cannot be interpreted.
const frame_marker: u8 = 0xA5;

/// One frame read from the channel.
///
/// The flags describe what arrived, not what was expected: a peer that sent a
/// marker and then closed can yield `framed == true` with no payload.
pub const Frame = struct {
    /// True when the first byte was `frame_marker`.
    framed: bool = false,

    /// True when the frame carried at least one payload byte.
    received: bool = false,

    /// Raw payload bytes. Only the first `payload_len` entries are meaningful.
    payload: [max_payload_len]u8 = undefined,

    /// Number of valid bytes in `payload`; never exceeds `payload.len`.
    payload_len: usize = 0,

    /// Returns the received payload.
    ///
    /// The returned slice borrows this frame and remains valid for as long as
    /// the frame does.
    pub fn text(self: *const Frame) []const u8 {
        return self.payload[0..self.payload_len];
    }

    /// Reports whether the payload equals `expected`.
    ///
    /// Returns false when a payload of a different length arrived.
    pub fn matches(self: *const Frame, expected: []const u8) bool {
        return std.mem.eql(u8, self.text(), expected);
    }
};

/// Reads one frame from `fd`.
///
/// The returned frame owns its payload bytes. A first byte that does not match
/// `frame_marker` yields `framed == false` and stops reading, because the rest
/// of the frame cannot be interpreted without the marker.
///
/// Errors: `error.PeerClosed` for a truncated frame, `error.PayloadTooLarge`
/// when the announced length exceeds `max_payload_len`, and `error.ReadFailed`
/// for a non-`EINTR` read failure.
pub fn readFrame(fd: std.os.linux.fd_t) !Frame {
    var frame = Frame{};

    var marker: [1]u8 = undefined;
    try readExact(fd, &marker);
    frame.framed = marker[0] == frame_marker;
    if (!frame.framed) return frame;

    var length_bytes: [4]u8 = undefined;
    try readExact(fd, &length_bytes);
    const payload_len: usize = std.mem.readInt(u32, &length_bytes, .little);
    if (payload_len > max_payload_len) return error.PayloadTooLarge;

    try readExact(fd, frame.payload[0..payload_len]);
    frame.payload_len = payload_len;
    frame.received = payload_len > 0;
    return frame;
}

/// Writes one frame carrying `payload` to `fd`.
///
/// Precondition: `fd` is the connected stream socket used for the IPC channel.
///
/// Errors: `error.PayloadTooLarge` when `payload` exceeds `max_payload_len`,
/// and `error.WriteFailed` when the peer closed or any other write failed.
pub fn writeFrame(fd: std.os.linux.fd_t, payload: []const u8) !void {
    if (payload.len > max_payload_len) return error.PayloadTooLarge;

    var header: [5]u8 = undefined;
    header[0] = frame_marker;
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);

    try writeAll(fd, &header);
    try writeAll(fd, payload);
}

/// Reads exactly `buffer.len` bytes from `fd`.
///
/// Errors: `error.PeerClosed` when the peer closed first; `error.ReadFailed`
/// for any other read failure (see `readAtMost`).
fn readExact(fd: std.os.linux.fd_t, buffer: []u8) !void {
    const read_len = try readAtMost(fd, buffer);
    if (read_len != buffer.len) return error.PeerClosed;
}

/// Reads from `fd` until `buffer` is full or the peer closes its end.
///
/// Returns the number of bytes read. Retries interrupted reads. Returns
/// `error.ReadFailed` for a non-`EINTR` read failure.
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

/// Writes all of `buffer` to the connected socket `fd`.
///
/// Uses `MSG_NOSIGNAL` so a peer that already closed the channel produces an
/// error instead of SIGPIPE. Retries interrupted and partial writes.
///
/// Errors: `error.WriteFailed` on any write failure.
fn writeAll(fd: std.os.linux.fd_t, buffer: []const u8) !void {
    var written: usize = 0;
    while (written < buffer.len) {
        const rc = std.os.linux.sendto(
            fd,
            buffer[written..].ptr,
            buffer.len - written,
            std.os.linux.MSG.NOSIGNAL,
            null,
            0,
        );
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

/// Operations the Entrypoint's JSON listener understands.
pub const Operation = enum {
    /// Write `message` to the process' standard error stream.
    stderr,
};

/// One JSON message carrying an operation for the Entrypoint's listener.
///
/// Schema:
///
///     {"operation": "stderr", "message": "Event is pause"}
pub const Request = struct {
    /// What the receiver should do with `message`.
    operation: Operation,
    /// Payload for `operation`; for `.stderr` it is printed verbatim.
    message: []const u8,
};

/// Parses one JSON request or response.
///
/// Unknown operations and unknown keys are rejected, so a typo in the schema
/// cannot silently turn into a no-op. The returned value borrows `allocator`
/// until `deinit()`.
pub fn parseRequest(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(Request) {
    return std.json.parseFromSlice(Request, allocator, text, .{});
}

/// Serializes `value` to JSON into `buffer` and returns the written bytes.
///
/// Returns `error.WriteFailed` when the JSON does not fit `buffer`. The
/// returned slice borrows `buffer`.
fn stringify(value: anytype, buffer: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try std.json.Stringify.value(value, .{}, &writer);
    return writer.buffered();
}

/// Serializes `request` and sends it as one frame.
///
/// Errors: `error.WriteFailed` when the request does not fit the stack buffer
/// or the write fails, and `error.PayloadTooLarge` from `writeFrame`.
pub fn sendRequest(fd: std.os.linux.fd_t, request: Request) !void {
    var buffer: [max_payload_len]u8 = undefined;
    const payload = try stringify(request, &buffer);
    try writeFrame(fd, payload);
}

/// Callbacks whose occurrence the Entrypoint reports to the plugin manager.
pub const Event = enum {
    /// Entrypoint.pause() ran.
    pause,
    /// Entrypoint.unpause() ran.
    unpause,
    /// Entrypoint.levelInit() ran.
    levelInit,
    /// Entrypoint.serverActivate() ran.
    serverActivate,
    /// Entrypoint.levelShutdown() ran.
    levelShutdown,
};

/// One JSON event message: `{"event":"pause"}`.
pub const EventMessage = struct {
    /// Callback that fired.
    event: Event,
};

/// Parses one event message.
///
/// Unknown events and unknown keys are rejected. The returned value borrows
/// `allocator` until `deinit()`.
pub fn parseEvent(
    allocator: std.mem.Allocator,
    text: []const u8,
) !std.json.Parsed(EventMessage) {
    return std.json.parseFromSlice(EventMessage, allocator, text, .{});
}

/// Serializes `event` into `buffer` and returns the written bytes.
///
/// Errors: `error.WriteFailed` when the event does not fit `buffer`.
pub fn encodeEvent(buffer: []u8, event: Event) ![]const u8 {
    return stringify(EventMessage{ .event = event }, buffer);
}

/// Sends one `{"event":"X"}` frame.
///
/// Errors: `error.WriteFailed` when the event does not fit the stack buffer or
/// the write fails, and `error.PayloadTooLarge` from `writeFrame`.
pub fn sendEvent(fd: std.os.linux.fd_t, event: Event) !void {
    var buffer: [128]u8 = undefined;
    const payload = try encodeEvent(&buffer, event);
    try writeFrame(fd, payload);
}

/// Formats the message the manager answers `event` with: `"Event is X"`.
///
/// The returned slice borrows `buffer`.
///
/// Errors: `error.NoSpaceLeft` when `buffer` is too small.
pub fn eventResponseText(buffer: []u8, event: Event) ![]const u8 {
    return std.fmt.bufPrint(buffer, "Event is {s}", .{@tagName(event)});
}

/// Sends the stderr response for one received event.
///
/// Errors: `error.NoSpaceLeft` when the stack buffer is too small, plus the
/// errors of `sendRequest`.
pub fn sendEventResponse(fd: std.os.linux.fd_t, event: Event) !void {
    var buffer: [64]u8 = undefined;
    const message = try eventResponseText(&buffer, event);
    try sendRequest(fd, .{ .operation = .stderr, .message = message });
}
