//! One frame read from the channel.
//!
//! The flags describe what arrived, not what was expected: a peer that sent a
//! marker and then closed can yield `framed == true` with no payload.

const std = @import("std");

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
pub fn asBytes(self: *const @This()) []const u8 {
    return self.payload[0..self.payload_len];
}

/// Reports whether the payload equals `expected`.
///
/// Returns false when a payload of a different length arrived.
pub fn matches(self: *const @This(), expected: []const u8) bool {
    return std.mem.eql(u8, self.text(), expected);
}

/// Reads one frame from `fd`.
///
/// The returned frame owns its payload bytes. A first byte that does not match
/// `frame_marker` yields `framed == false` and stops reading, because the rest
/// of the frame cannot be interpreted without the marker.
///
/// Errors: `error.PeerClosed` for a truncated frame, `error.PayloadTooLarge`
/// when the announced length exceeds `max_payload_len`, and `error.ReadFailed`
/// for a non-`EINTR` read failure.
pub fn read(fd: std.os.linux.fd_t) !@This() {
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
pub fn write(fd: std.os.linux.fd_t, payload: []const u8) !void {
    if (payload.len > max_payload_len) return error.PayloadTooLarge;

    var header: [5]u8 = undefined;
    header[0] = frame_marker;
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);

    try writeAll(fd, &header);
    try writeAll(fd, payload);
}
