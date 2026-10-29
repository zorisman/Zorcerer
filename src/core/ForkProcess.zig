const std = @import("std");

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
