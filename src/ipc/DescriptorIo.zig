const std = @import("std");

/// Reads exactly `buffer.len` bytes from `fd`.
///
/// Errors: `error.PeerClosed` when the peer closed first; `error.ReadFailed`
/// for any other read failure (see `readAtMost`).
pub fn readExact(fd: std.os.linux.fd_t, buffer: []u8) !void {
    const read_len = try readAtMost(fd, buffer);
    if (read_len != buffer.len) return error.PeerClosed;
}

/// Reads from `fd` until `buffer` is full or the peer closes its end.
///
/// Returns the number of bytes read. Retries interrupted reads. Returns
/// `error.ReadFailed` for a non-`EINTR` read failure.
pub fn readAtMost(fd: std.os.linux.fd_t, buffer: []u8) !usize {
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
pub fn writeAll(fd: std.os.linux.fd_t, buffer: []const u8) !void {
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
