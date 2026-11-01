//! Plugin-facing outbound network service used inside the forked plugin
//! manager.
//!
//! Each native plugin and each Lua script receives its own `PluginNetwork`
//! instance. It owns a handle table and borrows the plugin's manifest
//! `[network]` policy, so a handle opened by one plugin is never visible to
//! another and the deny-by-default allowlist is enforced per plugin.
//!
//! Only outbound TCP connections are implemented. Sockets are non-blocking;
//! connect, read, and write wait through bounded `std.posix.poll` slices until
//! the policy deadline elapses. Host names are resolved on a dedicated
//! resolver thread, so `getaddrinfo`-class work never runs on the plugin
//! manager's event thread.
//!
//! Handles are opaque non-zero integers valid only in the owning plugin's
//! table. `closeAll()` closes everything the plugin left open and is called
//! after its `unload()` hook returns, which keeps connections usable during
//! unload. No engine pointer or engine-side socket is involved.

const std = @import("std");
const abi = @import("plugin-context");
const PluginConfiguration = @import("plugin-configuration").PluginConfiguration;

/// Longest single `poll` slice, in milliseconds.
///
/// Longer waits are split into slices so a plugin cannot stall the manager's
/// event thread for an unbounded time and so cancellation points stay
/// frequent. The configured policy timeouts are still enforced as the overall
/// deadline.
const max_poll_slice_ms: u32 = 10;

/// Maximum accepted host length, matching `std.Io.net.HostName.max_len`.
const max_host_len: usize = 255;

/// Host-side network service shared by every plugin in the manager process.
///
/// The service owns the resolver thread. It must outlive every
/// `PluginNetwork` it creates.
pub const Service = struct {
    /// Allocator used for plugin network contexts and handle tables.
    allocator: std.mem.Allocator,
    /// Dedicated host-name resolver. Every connection that names a host rather
    /// than an IP literal is resolved here. Heap-allocated so the resolver
    /// thread keeps a stable `self` pointer after `init()` returns.
    resolver: *Resolver,

    /// Creates the service and starts its resolver thread.
    ///
    /// The returned pointer is owned by the caller and released with
    /// `deinit()`.
    ///
    /// Errors: `error.OutOfMemory`, pipe creation errors, and
    /// `error.ThreadQuotaExceeded`/`error.SystemResources` from the resolver
    /// thread.
    pub fn init(allocator: std.mem.Allocator) !*Service {
        const service = try allocator.create(Service);
        errdefer allocator.destroy(service);

        service.* = .{
            .allocator = allocator,
            .resolver = try Resolver.init(allocator),
        };
        return service;
    }

    /// Stops the resolver thread and frees the service.
    ///
    /// Every `PluginNetwork` created by the service must have been destroyed
    /// first; `PluginManager` enforces that by unloading plugins before
    /// releasing the service.
    pub fn deinit(self: *Service) void {
        self.resolver.deinit();
        self.allocator.destroy(self);
    }

    /// Creates the network context for one plugin.
    ///
    /// `policy` is borrowed and must stay valid until `destroyPluginNetwork()`
    /// is called. In the manager that means the validated manifest must
    /// outlive the plugin, which `unloadAll()` guarantees.
    ///
    /// The returned pointer is owned by the caller and released with
    /// `destroyPluginNetwork()`.
    ///
    /// Errors: `error.OutOfMemory`.
    pub fn createPluginNetwork(
        self: *Service,
        policy: *const PluginConfiguration.NetworkPolicy,
    ) !*PluginNetwork {
        const network = try self.allocator.create(PluginNetwork);
        errdefer self.allocator.destroy(network);

        network.* = .{
            .service = self,
            .policy = policy,
            .handles = std.AutoHashMap(u64, *Handle).init(self.allocator),
            .api = .{
                .struct_size = @sizeOf(abi.NetworkApi),
                .context = network,
                .connect = apiConnect,
                .close = apiClose,
                .read = apiRead,
                .write = apiWrite,
                .poll = apiPoll,
            },
        };
        return network;
    }

    /// Closes every handle still open in `network` and releases it.
    pub fn destroyPluginNetwork(self: *Service, network: *PluginNetwork) void {
        network.deinit();
        self.allocator.destroy(network);
    }
};

/// Network context of one plugin.
///
/// `api` is the ABI table handed to native plugins through
/// `PluginContext.network`; its `context` points back to this value. The Lua
/// bridge uses the same value directly through the public helpers. All fields
/// are owned by the manager and remain valid until `PluginManager` destroys the
/// context after the plugin's `unload()` returned.
pub const PluginNetwork = struct {
    /// Service that owns the allocator and resolver.
    service: *Service,
    /// Manifest policy borrowed from the validated configuration.
    policy: *const PluginConfiguration.NetworkPolicy,
    /// Open connections owned by this plugin, keyed by the ABI-visible ID.
    handles: std.AutoHashMap(u64, *Handle),
    /// Next ABI-visible handle ID; never zero.
    next_handle: u64 = 1,
    /// ABI table handed to native plugin code.
    api: abi.NetworkApi,

    /// Closes every remaining handle and releases the handle table.
    pub fn deinit(self: *PluginNetwork) void {
        self.closeAll();
        self.handles.deinit();
    }

    /// Closes every open connection owned by the plugin.
    ///
    /// Idempotent: the table is emptied. Socket close errors are ignored
    /// because teardown cannot report them.
    pub fn closeAll(self: *PluginNetwork) void {
        var handles = self.handles.valueIterator();
        while (handles.next()) |stored| {
            _ = std.os.linux.close(stored.*.fd);
            self.service.allocator.destroy(stored.*);
        }
        self.handles.clearRetainingCapacity();
    }

    /// Opens a TCP connection to `host`:`port` and registers its handle.
    ///
    /// The destination must match one `[network].allow` rule; otherwise
    /// `error.PermissionDenied` is returned before any socket is created. An
    /// IP literal is used directly; a host name is resolved on the service's
    /// resolver thread. The resolved address is refused with
    /// `error.PermissionDenied` when it lies in private, loopback, link-local,
    /// multicast, or unspecified address space and the policy did not set
    /// `allow_private`.
    ///
    /// The socket is non-blocking; the connect phase waits through bounded
    /// poll slices up to the policy's `connect_timeout_ms`.
    ///
    /// Errors: `error.InvalidArgument` for an unsupported protocol or a
    /// malformed host, `error.PermissionDenied`, `error.ResourceLimit` when
    /// `max_connections` is reached, `error.ResolutionFailed`,
    /// `error.ConnectFailed`, `error.Timeout`, `error.IoFailed`, and
    /// `error.OutOfMemory`.
    pub fn connect(
        self: *PluginNetwork,
        host: []const u8,
        port: u16,
        protocol: abi.NetworkProtocol,
        out_handle: *u64,
    ) NetworkError!void {
        if (protocol != .tcp) return error.InvalidArgument;
        if (host.len == 0 or host.len > max_host_len) return error.InvalidArgument;
        if (std.mem.indexOfScalar(u8, host, 0) != null) return error.InvalidArgument;
        if (!self.policy.allows(host, port)) return error.PermissionDenied;
        if (self.handles.count() >= self.policy.max_connections) {
            return error.ResourceLimit;
        }

        const literal: ?std.Io.net.IpAddress = std.Io.net.IpAddress.parse(host, port) catch null;
        const address = literal orelse try self.service.resolver.resolve(host, port);

        if (!self.policy.allow_private and addressIsPrivate(address)) {
            return error.PermissionDenied;
        }

        const fd = try connectTcp(address, port, self.policy.connect_timeout_ms);
        errdefer _ = std.os.linux.close(fd);

        out_handle.* = try self.addHandle(fd);
    }

    /// Closes one connection.
    ///
    /// Errors: `error.InvalidHandle` when `handle` is unknown.
    pub fn close(self: *PluginNetwork, handle: u64) NetworkError!void {
        const stored = try self.getHandle(handle);
        _ = std.os.linux.close(stored.fd);
        if (self.handles.fetchRemove(handle)) |entry| {
            self.service.allocator.destroy(entry.value);
        }
    }

    /// Reads at most `destination.len` bytes from `handle`.
    ///
    /// The call returns as soon as any bytes are available. It returns 0 at
    /// end of stream and waits through bounded poll slices up to the policy's
    /// `io_timeout_ms` for the first byte.
    ///
    /// Errors: `error.InvalidHandle`, `error.Closed`, `error.Timeout`, and
    /// `error.IoFailed`.
    pub fn read(self: *PluginNetwork, handle: u64, destination: []u8) NetworkError!usize {
        const stored = try self.getHandle(handle);
        if (destination.len == 0) return 0;

        const deadline = nowMs() + @as(i128, self.policy.io_timeout_ms);
        while (true) {
            const received = std.os.linux.recvfrom(
                stored.fd,
                destination.ptr,
                destination.len,
                0,
                null,
                null,
            );
            switch (syscallErrno(received)) {
                .SUCCESS => return received,
                .AGAIN => {},
                .TIMEDOUT => return error.Timeout,
                .CONNRESET, .CONNABORTED, .NOTCONN, .SHUTDOWN => return error.Closed,
                else => return error.IoFailed,
            }

            const remaining = deadline - nowMs();
            if (remaining <= 0) return error.Timeout;
            _ = try pollOnce(stored.fd, std.os.linux.POLL.IN, remaining);
        }
    }

    /// Writes at most `source.len` bytes to `handle`.
    ///
    /// The call returns as soon as any bytes are accepted by the socket and
    /// waits through bounded poll slices up to the policy's `io_timeout_ms`.
    /// Callers must loop for whole-message writes.
    ///
    /// Errors: `error.InvalidHandle`, `error.Closed`, `error.Timeout`,
    /// `error.IoFailed`, and `error.InvalidArgument` when `source` exceeds
    /// `max_frame_bytes`.
    pub fn write(self: *PluginNetwork, handle: u64, source: []const u8) NetworkError!usize {
        const stored = try self.getHandle(handle);
        if (source.len == 0) return 0;
        if (source.len > self.policy.max_frame_bytes) return error.InvalidArgument;

        const deadline = nowMs() + @as(i128, self.policy.io_timeout_ms);
        while (true) {
            const sent = std.os.linux.sendto(stored.fd, source.ptr, source.len, 0, null, 0);
            switch (syscallErrno(sent)) {
                .SUCCESS => return sent,
                .AGAIN => {},
                .TIMEDOUT => return error.Timeout,
                .CONNRESET, .CONNABORTED, .NOTCONN, .SHUTDOWN => return error.Closed,
                else => return error.IoFailed,
            }

            const remaining = deadline - nowMs();
            if (remaining <= 0) return error.Timeout;
            _ = try pollOnce(stored.fd, std.os.linux.POLL.OUT, remaining);
        }
    }

    /// Waits until `handle` reports one of the requested event bits.
    ///
    /// `events` is a combination of `abi.network_poll_in` and
    /// `abi.network_poll_out`; at least one bit is required. The effective
    /// timeout is the smaller of `timeout_ms` and the policy's
    /// `poll_timeout_ms`, further capped to one bounded poll slice. A zero
    /// result means the timeout elapsed.
    ///
    /// Errors: `error.InvalidHandle`, `error.InvalidArgument` when `events`
    /// has no supported bit, and `error.IoFailed`.
    pub fn poll(
        self: *PluginNetwork,
        handle: u64,
        events: u8,
        timeout_ms: u32,
        out_events: *u8,
    ) NetworkError!void {
        const stored = try self.getHandle(handle);

        var requested: i16 = 0;
        if (events & abi.network_poll_in != 0) requested |= std.os.linux.POLL.IN;
        if (events & abi.network_poll_out != 0) requested |= std.os.linux.POLL.OUT;
        if (requested == 0) return error.InvalidArgument;

        const configured: u32 = @min(self.policy.poll_timeout_ms, max_poll_slice_ms);
        const timeout: u32 = @min(timeout_ms, configured);
        const revents = try pollOnce(stored.fd, requested, timeout);
        out_events.* = pollBits(revents);
    }

    /// Registers `fd` under a fresh ABI-visible ID.
    ///
    /// The value is heap-allocated so its address stays stable while the hash
    /// map grows; the ID is never zero.
    ///
    /// Errors: `error.OutOfMemory`.
    fn addHandle(self: *PluginNetwork, fd: i32) NetworkError!u64 {
        const allocator = self.service.allocator;
        const stored = allocator.create(Handle) catch return error.OutOfMemory;
        stored.* = .{ .fd = fd };

        const id = self.next_handle;
        self.next_handle +%= 1;
        if (self.next_handle == 0) self.next_handle = 1;

        self.handles.put(id, stored) catch {
            allocator.destroy(stored);
            return error.OutOfMemory;
        };
        return id;
    }

    /// Returns the stored handle for `id`.
    ///
    /// Errors: `error.InvalidHandle` when the plugin does not own `id`.
    fn getHandle(self: *PluginNetwork, id: u64) NetworkError!*Handle {
        return self.handles.get(id) orelse error.InvalidHandle;
    }
};

/// One open connection owned by a plugin.
const Handle = struct {
    /// Non-blocking TCP socket descriptor.
    fd: i32,
};

/// Errors reported by `PluginNetwork`; each maps to an `abi.network_*` status.
const NetworkError = error{
    /// The network service or resolver is unavailable.
    Unavailable,
    /// The destination is not permitted by the policy or private-address
    /// guard.
    PermissionDenied,
    /// An argument is malformed.
    InvalidArgument,
    /// The host name did not resolve.
    ResolutionFailed,
    /// The resolved address could not be connected.
    ConnectFailed,
    /// A connect, read, write, or poll deadline elapsed.
    Timeout,
    /// The operation would block but the caller asked not to wait.
    WouldBlock,
    /// The peer closed the connection.
    Closed,
    /// The plugin reached its connection limit.
    ResourceLimit,
    /// An I/O operation after a successful open failed.
    IoFailed,
    /// The handle is unknown.
    InvalidHandle,
    /// Allocation failed.
    OutOfMemory,
};

/// Translates a `NetworkError` into its ABI status.
fn statusOf(err: NetworkError) c_int {
    return switch (err) {
        error.Unavailable => abi.network_unavailable,
        error.PermissionDenied => abi.network_permission_denied,
        error.InvalidArgument => abi.network_invalid_argument,
        error.ResolutionFailed => abi.network_resolution_failed,
        error.ConnectFailed => abi.network_connect_failed,
        error.Timeout => abi.network_timeout,
        error.WouldBlock => abi.network_would_block,
        error.Closed => abi.network_closed,
        error.ResourceLimit => abi.network_resource_limit,
        error.IoFailed => abi.network_io_error,
        error.InvalidHandle => abi.network_invalid_handle,
        error.OutOfMemory => abi.network_io_error,
    };
}

/// Decodes the error number of a raw `std.os.linux` syscall result.
///
/// `std.posix.errno()` reads the C `errno` variable when libc is linked, but
/// raw Linux syscalls return their error as a negative value instead. This
/// helper applies the raw-syscall convention regardless of libc linkage.
///
/// Returns `.SUCCESS` for a non-negative result.
fn syscallErrno(result: usize) std.os.linux.E {
    const signed: isize = @bitCast(result);
    if (signed >= 0) return .SUCCESS;
    return @enumFromInt(@as(std.meta.Tag(std.os.linux.E), @intCast(-signed)));
}

/// Returns the monotonic clock in milliseconds.
///
/// The returned value is only meaningful for comparing deadlines within this
/// process. A clock failure yields 0, which makes the next deadline check
/// expire immediately rather than block.
fn nowMs() i128 {
    var timespec: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &timespec);
    if (syscallErrno(result) != .SUCCESS) return 0;
    return @as(i128, timespec.sec) * 1000 +
        @divTrunc(@as(i128, timespec.nsec), std.time.ns_per_ms);
}

/// Polls one socket for `events` for at most `timeout_ms`, capped to one
/// bounded slice, and returns the raw `revents` bits.
///
/// The effective timeout is `min(timeout_ms, max_poll_slice_ms)`, so callers
/// that need a longer deadline loop and recompute it. A timeout returns 0.
///
/// Errors: `error.IoFailed` when the poll itself fails.
fn pollOnce(fd: i32, events: i16, timeout_ms: i128) NetworkError!i16 {
    const capped: i128 = @min(timeout_ms, @as(i128, max_poll_slice_ms));
    const timeout: i32 = @intCast(@max(capped, 0));

    var fds = [_]std.os.linux.pollfd{.{
        .fd = fd,
        .events = events,
        .revents = 0,
    }};
    const count = std.posix.poll(&fds, timeout) catch return error.IoFailed;
    if (count == 0) return 0;
    return fds[0].revents;
}

/// Converts raw poll bits into `abi.network_poll_*` bits.
fn pollBits(revents: i16) u8 {
    var bits: u8 = 0;
    if (revents & std.os.linux.POLL.IN != 0) bits |= abi.network_poll_in;
    if (revents & std.os.linux.POLL.OUT != 0) bits |= abi.network_poll_out;
    if (revents & (std.os.linux.POLL.ERR | std.os.linux.POLL.NVAL) != 0) {
        bits |= abi.network_poll_error;
    }
    if (revents & std.os.linux.POLL.HUP != 0) bits |= abi.network_poll_hup;
    return bits;
}

/// Platform-independent sockaddr storage for one resolved address.
const SockAddr = union(enum) {
    /// IPv4 address in `sockaddr.in` form.
    ip4: std.os.linux.sockaddr.in,
    /// IPv6 address in `sockaddr.in6` form.
    ip6: std.os.linux.sockaddr.in6,
};

/// Builds the kernel sockaddr for `address` on `port`.
fn toSockAddr(address: std.Io.net.IpAddress, port: u16) SockAddr {
    switch (address) {
        .ip4 => |ip4| {
            var result: std.os.linux.sockaddr.in = .{
                .family = std.os.linux.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = 0,
                .zero = [_]u8{0} ** 8,
            };
            @memcpy(std.mem.asBytes(&result.addr), &ip4.bytes);
            return .{ .ip4 = result };
        },
        .ip6 => |ip6| return .{ .ip6 = .{
            .family = std.os.linux.AF.INET6,
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = 0,
            .addr = ip6.bytes,
            .scope_id = 0,
        } },
    }
}

/// Creates a non-blocking TCP socket, connects it to `address`, and returns
/// its descriptor.
///
/// The connect phase waits through bounded poll slices until
/// `timeout_ms` elapses. On any failure the socket is closed before the error
/// is returned.
///
/// Errors: `error.ResourceLimit` when the process or plugin cannot allocate a
/// descriptor, `error.ConnectFailed` for connection refusals and unreachable
/// addresses, `error.Timeout`, and `error.IoFailed` for other socket errors.
fn connectTcp(
    address: std.Io.net.IpAddress,
    port: u16,
    timeout_ms: u32,
) NetworkError!i32 {
    const storage = toSockAddr(address, port);

    const family: u32 = switch (storage) {
        .ip4 => std.os.linux.AF.INET,
        .ip6 => std.os.linux.AF.INET6,
    };
    const socket_type: u32 = std.posix.SOCK.STREAM |
        std.posix.SOCK.NONBLOCK |
        std.posix.SOCK.CLOEXEC;
    const raw_fd = std.os.linux.socket(family, socket_type, 0);
    if (syscallErrno(raw_fd) != .SUCCESS) {
        return socketErrno(syscallErrno(raw_fd));
    }
    const fd: i32 = @intCast(raw_fd);
    errdefer _ = std.os.linux.close(fd);

    const address_size: u32 = switch (storage) {
        .ip4 => @sizeOf(std.os.linux.sockaddr.in),
        .ip6 => @sizeOf(std.os.linux.sockaddr.in6),
    };
    const sockaddr_pointer: *const std.os.linux.sockaddr = switch (storage) {
        .ip4 => @ptrCast(&storage.ip4),
        .ip6 => @ptrCast(&storage.ip6),
    };

    const connected = std.os.linux.connect(fd, sockaddr_pointer, address_size);
    switch (syscallErrno(connected)) {
        .SUCCESS => return fd,
        .INPROGRESS, .AGAIN => {},
        .CONNREFUSED, .NETUNREACH, .HOSTUNREACH, .ADDRNOTAVAIL => {
            return error.ConnectFailed;
        },
        .TIMEDOUT => return error.Timeout,
        else => |errno_code| return socketErrno(errno_code),
    }

    const deadline = nowMs() + @as(i128, timeout_ms);
    while (true) {
        const remaining = deadline - nowMs();
        if (remaining <= 0) return error.Timeout;

        const revents = try pollOnce(fd, std.os.linux.POLL.OUT, remaining);
        if (revents == 0) continue;
        if (revents & (std.os.linux.POLL.ERR | std.os.linux.POLL.HUP | std.os.linux.POLL.NVAL) != 0) {
            return error.ConnectFailed;
        }
        if (revents & std.os.linux.POLL.OUT == 0) continue;

        // A writable socket can still carry a pending asynchronous error;
        // SO_ERROR is the authoritative result.
        var code: i32 = 0;
        var length: u32 = @sizeOf(i32);
        const result = std.os.linux.getsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.os.linux.SO.ERROR,
            std.mem.asBytes(&code),
            &length,
        );
        if (syscallErrno(result) != .SUCCESS) return error.IoFailed;
        if (code != 0) return error.ConnectFailed;
        return fd;
    }
}

/// Maps a socket-creation errno to a `NetworkError`.
fn socketErrno(errno_code: std.os.linux.E) NetworkError {
    return switch (errno_code) {
        .NFILE, .MFILE, .NOMEM, .NOBUFS => error.ResourceLimit,
        .AFNOSUPPORT, .INVAL => error.InvalidArgument,
        .TIMEDOUT => error.Timeout,
        else => error.IoFailed,
    };
}

/// Returns whether `address` lies in address space a plugin must not reach
/// without the manifest's `allow_private` flag.
///
/// This blocks loopback, RFC 1918, link-local, ULA, multicast, unspecified,
/// and IPv4-mapped private addresses. It is a policy guard, not a network
/// filter: the operating system still applies its own routing rules.
fn addressIsPrivate(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| ip4IsPrivate(ip4.bytes),
        .ip6 => |ip6| ip6IsPrivate(ip6.bytes),
    };
}

/// Returns whether an IPv4 address is private, loopback, link-local,
/// multicast, unspecified, or reserved.
fn ip4IsPrivate(bytes: [4]u8) bool {
    const first = bytes[0];
    const second = bytes[1];

    if (first == 0 or first == 10 or first == 127) return true;
    if (first == 169 and second == 254) return true;
    if (first == 172 and second >= 16 and second <= 31) return true;
    if (first == 192 and second == 168) return true;
    if (first >= 224) return true;
    return false;
}

/// Returns whether an IPv6 address is loopback, unspecified, ULA, link-local,
/// multicast, or an IPv4-mapped private address.
fn ip6IsPrivate(bytes: [16]u8) bool {
    var all_zero = true;
    for (bytes[0..15]) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero and (bytes[15] == 0 or bytes[15] == 1)) return true;

    if (bytes[0] & 0xfe == 0xfc) return true;
    if (bytes[0] == 0xfe and bytes[1] & 0xc0 == 0x80) return true;
    if (bytes[0] == 0xff) return true;

    const ipv4_mapped = all_zero and bytes[10] == 0xff and bytes[11] == 0xff;
    if (ipv4_mapped) return ip4IsPrivate(.{ bytes[12], bytes[13], bytes[14], bytes[15] });
    return false;
}

/// Dedicated host-name resolver.
///
/// Requests and answers travel over two pipes. `resolve()` writes one fixed
/// request and blocks until the resolver thread answers; the manager's event
/// thread therefore never performs the resolver's blocking work itself. Only
/// one request is outstanding at a time, which matches the manager's
/// single-threaded plugin callbacks.
const Resolver = struct {
    /// Allocator used for the thread's `std.Io` instance.
    allocator: std.mem.Allocator,
    /// Read end of the request pipe (resolver side).
    request_read_fd: i32,
    /// Write end of the request pipe (manager side). Closing it stops the
    /// thread.
    request_write_fd: i32,
    /// Read end of the response pipe (manager side).
    response_read_fd: i32,
    /// Write end of the response pipe (resolver side).
    response_write_fd: i32,
    /// Worker thread blocked on the request pipe.
    thread: std.Thread,

    /// One fixed-size resolve request.
    const Request = extern struct {
        /// Number of valid bytes in `host`.
        host_len: u16,
        /// Port to embed in the answer.
        port: u16,
        /// NUL-padded host name.
        host: [max_host_len]u8,
    };

    /// One fixed-size resolve response.
    const Response = extern struct {
        /// `0` success, `1` invalid host, `2` lookup failure.
        kind: u8 = 0,
        /// `4` or `6` when `kind == 0`.
        family: u8 = 0,
        /// Port copied from the request.
        port: u16 = 0,
        /// Raw address bytes; only the first 4 or 16 are meaningful.
        address: [16]u8 = [_]u8{0} ** 16,
    };

    /// Creates both pipes and starts the resolver thread.
    ///
    /// The resolver is heap-allocated before the thread starts so the worker's
    /// `self` pointer stays valid after this function returns. The returned
    /// pointer is owned by the caller and released with `deinit()`.
    ///
    /// Errors: `error.OutOfMemory`, pipe creation errors, and thread-spawn
    /// errors. On failure every descriptor and allocation created so far is
    /// released.
    fn init(allocator: std.mem.Allocator) !*Resolver {
        const self = try allocator.create(Resolver);
        errdefer allocator.destroy(self);

        var request_pipe: [2]i32 = undefined;
        const request_result = std.os.linux.pipe2(&request_pipe, .{ .CLOEXEC = true });
        if (syscallErrno(request_result) != .SUCCESS) return error.PipeFailed;
        errdefer {
            _ = std.os.linux.close(request_pipe[0]);
            _ = std.os.linux.close(request_pipe[1]);
        }

        var response_pipe: [2]i32 = undefined;
        const response_result = std.os.linux.pipe2(&response_pipe, .{ .CLOEXEC = true });
        if (syscallErrno(response_result) != .SUCCESS) return error.PipeFailed;
        errdefer {
            _ = std.os.linux.close(response_pipe[0]);
            _ = std.os.linux.close(response_pipe[1]);
        }

        self.* = .{
            .allocator = allocator,
            .request_read_fd = request_pipe[0],
            .request_write_fd = request_pipe[1],
            .response_read_fd = response_pipe[0],
            .response_write_fd = response_pipe[1],
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(
            .{ .allocator = allocator },
            run,
            .{self},
        );
        return self;
    }

    /// Stops the resolver thread, closes every pipe, and frees the resolver.
    ///
    /// Closing the request write end makes the thread's blocking read return
    /// 0, which ends its loop. The thread is joined before the remaining
    /// descriptors are released.
    fn deinit(self: *Resolver) void {
        _ = std.os.linux.close(self.request_write_fd);
        self.thread.join();
        _ = std.os.linux.close(self.request_read_fd);
        _ = std.os.linux.close(self.response_read_fd);
        _ = std.os.linux.close(self.response_write_fd);
        self.allocator.destroy(self);
    }

    /// Resolves `host` on the worker thread and returns its first address.
    ///
    /// The caller blocks until the worker answers. This is deliberate: the
    /// ABI is synchronous, but the blocking lookup work happens off the
    /// manager's event thread.
    ///
    /// Errors: `error.Unavailable` when the pipes fail, `error.InvalidArgument`
    /// for a malformed host, and `error.ResolutionFailed` for a lookup failure.
    fn resolve(self: *Resolver, host: []const u8, port: u16) NetworkError!std.Io.net.IpAddress {
        if (host.len > max_host_len) return error.InvalidArgument;

        var request: Request = .{
            .host_len = @intCast(host.len),
            .port = port,
            .host = [_]u8{0} ** max_host_len,
        };
        @memcpy(request.host[0..host.len], host);

        try writeAll(self.request_write_fd, std.mem.asBytes(&request));

        var response: Response = undefined;
        try readAll(self.response_read_fd, std.mem.asBytes(&response));

        return switch (response.kind) {
            0 => switch (response.family) {
                4 => .{ .ip4 = .{
                    .bytes = response.address[0..4].*,
                    .port = response.port,
                } },
                6 => .{ .ip6 = .{
                    .bytes = response.address[0..16].*,
                    .port = response.port,
                    .flow = 0,
                    .interface = .{ .index = 0 },
                } },
                else => error.ResolutionFailed,
            },
            1 => error.InvalidArgument,
            else => error.ResolutionFailed,
        };
    }

    /// Worker loop: read one request, resolve it, write one response.
    ///
    /// The thread owns a multi-threaded `std.Io` instance for the whole loop
    /// so DNS lookups can block without affecting the manager. It exits when
    /// the request pipe reaches EOF.
    fn run(self: *Resolver) void {
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        while (true) {
            var request: Request = undefined;
            readAll(self.request_read_fd, std.mem.asBytes(&request)) catch return;
            if (request.host_len > max_host_len) {
                self.writeResponse(.{ .kind = 1 });
                continue;
            }

            const host_text = request.host[0..request.host_len];
            const host_name = std.Io.net.HostName.init(host_text) catch {
                self.writeResponse(.{ .kind = 1 });
                continue;
            };

            var buffer: [8]std.Io.net.HostName.LookupResult = undefined;
            var queue = std.Io.Queue(std.Io.net.HostName.LookupResult).init(buffer[0..]);
            host_name.lookup(io, &queue, .{ .port = request.port }) catch {
                self.writeResponse(.{ .kind = 2 });
                continue;
            };
            const result = queue.getOne(io) catch {
                self.writeResponse(.{ .kind = 2 });
                continue;
            };

            var response: Response = .{ .kind = 0, .port = request.port };
            switch (result.address) {
                .ip4 => |ip4| {
                    response.family = 4;
                    @memcpy(response.address[0..4], &ip4.bytes);
                },
                .ip6 => |ip6| {
                    response.family = 6;
                    @memcpy(response.address[0..16], &ip6.bytes);
                },
            }
            self.writeResponse(response);
        }
    }

    /// Writes one response to the manager. A closed pipe is ignored.
    fn writeResponse(self: *Resolver, response: Response) void {
        writeAll(self.response_write_fd, std.mem.asBytes(&response)) catch {};
    }
};

/// Writes every byte of `bytes` to `fd`.
///
/// Retries on interruption and short writes. A zero-byte write or a closed
/// descriptor yields `error.Unavailable`.
fn writeAll(fd: i32, bytes: []const u8) NetworkError!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = std.os.linux.write(fd, bytes.ptr + written, bytes.len - written);
        switch (syscallErrno(result)) {
            .SUCCESS => {
                if (result == 0) return error.Unavailable;
                written += result;
            },
            .INTR => continue,
            else => return error.Unavailable,
        }
    }
}

/// Reads exactly `destination.len` bytes from `fd`.
///
/// Retries on interruption and short reads. EOF or a closed descriptor yields
/// `error.Unavailable`.
fn readAll(fd: i32, destination: []u8) NetworkError!void {
    var read_bytes: usize = 0;
    while (read_bytes < destination.len) {
        const result = std.os.linux.read(fd, destination.ptr + read_bytes, destination.len - read_bytes);
        switch (syscallErrno(result)) {
            .SUCCESS => {
                if (result == 0) return error.Unavailable;
                read_bytes += result;
            },
            .INTR => continue,
            else => return error.Unavailable,
        }
    }
}

/// Returns the plugin context behind an ABI `context` pointer.
fn pluginNetwork(raw: ?*anyopaque) ?*PluginNetwork {
    const context = raw orelse return null;
    return @ptrCast(@alignCast(context));
}

/// `NetworkApi.connect` implementation.
fn apiConnect(
    raw: ?*anyopaque,
    host: abi.Text,
    port: u16,
    protocol: abi.NetworkProtocol,
    out_handle: *u64,
) callconv(.c) c_int {
    const self = pluginNetwork(raw) orelse return abi.network_unavailable;
    out_handle.* = 0;
    self.connect(host.slice(), port, protocol, out_handle) catch |err| return statusOf(err);
    return abi.network_ok;
}

/// `NetworkApi.close` implementation.
fn apiClose(raw: ?*anyopaque, handle: u64) callconv(.c) c_int {
    const self = pluginNetwork(raw) orelse return abi.network_unavailable;
    self.close(handle) catch |err| return statusOf(err);
    return abi.network_ok;
}

/// `NetworkApi.read` implementation.
fn apiRead(
    raw: ?*anyopaque,
    handle: u64,
    destination: [*]u8,
    destination_len: usize,
) callconv(.c) isize {
    const self = pluginNetwork(raw) orelse return -@as(isize, abi.network_unavailable);
    const count = self.read(handle, destination[0..destination_len]) catch |err|
        return -@as(isize, statusOf(err));
    return @intCast(count);
}

/// `NetworkApi.write` implementation.
fn apiWrite(
    raw: ?*anyopaque,
    handle: u64,
    source: [*]const u8,
    source_len: usize,
) callconv(.c) isize {
    const self = pluginNetwork(raw) orelse return -@as(isize, abi.network_unavailable);
    const count = self.write(handle, source[0..source_len]) catch |err|
        return -@as(isize, statusOf(err));
    return @intCast(count);
}

/// `NetworkApi.poll` implementation.
fn apiPoll(
    raw: ?*anyopaque,
    handle: u64,
    events: u8,
    timeout_ms: u32,
    out_events: *u8,
) callconv(.c) c_int {
    const self = pluginNetwork(raw) orelse return abi.network_unavailable;
    out_events.* = 0;
    self.poll(handle, events, timeout_ms, out_events) catch |err| return statusOf(err);
    return abi.network_ok;
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

/// Loopback TCP echo server used by the service tests.
///
/// Binds an ephemeral port on 127.0.0.1 and accepts exactly one connection.
/// The server copies input back to the peer until the peer closes. `port`
/// receives the bound port. The caller starts it with `start()` and must
/// release it with `stop()`.
const EchoServer = struct {
    /// Listening socket descriptor.
    listener: i32,
    /// Bound TCP port.
    port: u16,
    /// Accept-and-echo worker.
    thread: std.Thread,
    /// Allocator that owns the server value.
    allocator: std.mem.Allocator,
    /// Transport failure reported by the worker.
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Binds 127.0.0.1:0, listens, and starts the worker.
    ///
    /// The server is heap-allocated so the worker's `self` pointer stays valid
    /// after `start()` returns. `stop()` releases it.
    fn start() !*EchoServer {
        const raw_fd = std.os.linux.socket(
            std.os.linux.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            0,
        );
        if (syscallErrno(raw_fd) != .SUCCESS) return error.SocketFailed;
        const listener: i32 = @intCast(raw_fd);
        errdefer _ = std.os.linux.close(listener);

        var address: std.os.linux.sockaddr.in = .{
            .family = std.os.linux.AF.INET,
            .port = 0,
            .addr = 0,
            .zero = [_]u8{0} ** 8,
        };
        @memcpy(std.mem.asBytes(&address.addr), &[_]u8{ 127, 0, 0, 1 });

        const bound = std.os.linux.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address)));
        if (syscallErrno(bound) != .SUCCESS) return error.BindFailed;

        const listened = std.os.linux.listen(listener, 1);
        if (syscallErrno(listened) != .SUCCESS) return error.ListenFailed;

        var resolved: std.os.linux.sockaddr.in = undefined;
        var resolved_len: u32 = @sizeOf(@TypeOf(resolved));
        const named = std.os.linux.getsockname(listener, @ptrCast(&resolved), &resolved_len);
        if (syscallErrno(named) != .SUCCESS) return error.SocketFailed;

        const server = try testing.allocator.create(EchoServer);
        errdefer testing.allocator.destroy(server);
        server.* = .{
            .listener = listener,
            .port = std.mem.bigToNative(u16, resolved.port),
            .thread = undefined,
            .allocator = testing.allocator,
        };
        server.thread = try std.Thread.spawn(.{}, echo, .{server});
        return server;
    }

    /// Accepts one connection and echoes it until EOF.
    fn echo(self: *EchoServer) void {
        const raw_peer = std.os.linux.accept(self.listener, null, null);
        if (syscallErrno(raw_peer) != .SUCCESS) {
            self.failed.store(true, .seq_cst);
            return;
        }
        const peer: i32 = @intCast(raw_peer);
        defer _ = std.os.linux.close(peer);

        var buffer: [256]u8 = undefined;
        while (true) {
            const received = std.os.linux.recvfrom(peer, &buffer, buffer.len, 0, null, null);
            if (syscallErrno(received) != .SUCCESS or received == 0) return;
            var sent: usize = 0;
            while (sent < received) {
                const result = std.os.linux.sendto(
                    peer,
                    buffer[sent..].ptr,
                    received - sent,
                    0,
                    null,
                    0,
                );
                if (syscallErrno(result) != .SUCCESS or result == 0) {
                    self.failed.store(true, .seq_cst);
                    return;
                }
                sent += result;
            }
        }
    }

    /// Closes the listener, joins the worker, and frees the server.
    ///
    /// `shutdown()` wakes a worker blocked in `accept()` even when no client
    /// ever connected; a plain `close()` does not reliably do that.
    fn stop(self: *EchoServer) void {
        _ = std.os.linux.shutdown(self.listener, std.os.linux.SHUT.RDWR);
        _ = std.os.linux.close(self.listener);
        self.thread.join();
        self.allocator.destroy(self);
    }
};

test "network service connects and echoes over loopback" {
    var server = try EchoServer.start();
    defer server.stop();

    var policy: PluginConfiguration.NetworkPolicy = .{
        .allow_private = true,
        .rules = &.{
            .{ .host = "127.0.0.1", .port = server.port },
        },
    };
    var service = try Service.init(testing.allocator);
    defer service.deinit();
    const network = try service.createPluginNetwork(&policy);
    defer service.destroyPluginNetwork(network);

    var handle: u64 = 0;
    try network.connect("127.0.0.1", server.port, .tcp, &handle);

    const message = "ping";
    try testing.expectEqual(message.len, try network.write(handle, message));

    var buffer: [16]u8 = undefined;
    var received: usize = 0;
    while (received < message.len) {
        received += try network.read(handle, buffer[received..message.len]);
    }
    try testing.expectEqualStrings(message, buffer[0..received]);

    try network.close(handle);
    try testing.expectError(error.InvalidHandle, network.close(handle));
}

test "network service resolves host names on its resolver thread" {
    var server = try EchoServer.start();
    defer server.stop();

    var policy: PluginConfiguration.NetworkPolicy = .{
        .allow_private = true,
        .rules = &.{
            .{ .host = "localhost", .port = server.port },
        },
    };
    var service = try Service.init(testing.allocator);
    defer service.deinit();
    const network = try service.createPluginNetwork(&policy);
    defer service.destroyPluginNetwork(network);

    var handle: u64 = 0;
    try network.connect("localhost", server.port, .tcp, &handle);

    try testing.expectEqual(@as(usize, 2), try network.write(handle, "hi"));
    var buffer: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try network.read(handle, &buffer));
    try testing.expectEqualStrings("hi", &buffer);
}

test "network service enforces the manifest allowlist" {
    var policy: PluginConfiguration.NetworkPolicy = .{
        .rules = &.{
            .{ .host = "example.com", .port = 80 },
        },
    };
    var service = try Service.init(testing.allocator);
    defer service.deinit();
    const network = try service.createPluginNetwork(&policy);
    defer service.destroyPluginNetwork(network);

    var handle: u64 = 0;
    try testing.expectError(
        error.PermissionDenied,
        network.connect("example.com", 81, .tcp, &handle),
    );
    try testing.expectError(
        error.PermissionDenied,
        network.connect("other.example.com", 80, .tcp, &handle),
    );
    try testing.expectError(
        error.InvalidArgument,
        network.connect("", 80, .tcp, &handle),
    );
}

test "private address guard requires allow_private" {
    // No server is needed: the guard rejects the destination before any
    // socket is created, so the test cannot block in accept().
    var policy: PluginConfiguration.NetworkPolicy = .{
        .rules = &.{
            .{ .host = "127.0.0.1", .port = 1 },
        },
    };
    var service = try Service.init(testing.allocator);
    defer service.deinit();
    const network = try service.createPluginNetwork(&policy);
    defer service.destroyPluginNetwork(network);

    var handle: u64 = 0;
    try testing.expectError(
        error.PermissionDenied,
        network.connect("127.0.0.1", 1, .tcp, &handle),
    );
}

test "network service enforces the connection limit" {
    var server = try EchoServer.start();
    defer server.stop();

    var policy: PluginConfiguration.NetworkPolicy = .{
        .allow_private = true,
        .max_connections = 1,
        .rules = &.{
            .{ .host = "127.0.0.1", .port = server.port },
        },
    };
    var service = try Service.init(testing.allocator);
    defer service.deinit();
    const network = try service.createPluginNetwork(&policy);
    defer service.destroyPluginNetwork(network);

    var handle: u64 = 0;
    try network.connect("127.0.0.1", server.port, .tcp, &handle);

    // The echo server accepts only one connection, but the limit is checked
    // before any socket work, so this fails without involving the server.
    var second: u64 = 0;
    try testing.expectError(
        error.ResourceLimit,
        network.connect("127.0.0.1", server.port, .tcp, &second),
    );
}

test "private address classification" {
    try testing.expect(ip4IsPrivate(.{ 127, 0, 0, 1 }));
    try testing.expect(ip4IsPrivate(.{ 10, 1, 2, 3 }));
    try testing.expect(ip4IsPrivate(.{ 172, 16, 0, 1 }));
    try testing.expect(ip4IsPrivate(.{ 192, 168, 1, 1 }));
    try testing.expect(ip4IsPrivate(.{ 169, 254, 1, 1 }));
    try testing.expect(ip4IsPrivate(.{ 224, 0, 0, 1 }));
    try testing.expect(!ip4IsPrivate(.{ 8, 8, 8, 8 }));

    try testing.expect(ip6IsPrivate(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    try testing.expect(ip6IsPrivate(.{ 0xfc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    try testing.expect(ip6IsPrivate(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    try testing.expect(!ip6IsPrivate(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
}

test "network allowlist wildcard matching" {
    const rule: PluginConfiguration.NetworkRule = .{ .host = "*.example.org" };
    try testing.expect(rule.matches("a.example.org", 1));
    try testing.expect(rule.matches("A.B.EXAMPLE.ORG", 1));
    try testing.expect(!rule.matches("example.org", 1));
    try testing.expect(!rule.matches("badexample.org", 1));

    const port_rule: PluginConfiguration.NetworkRule = .{ .host = "example.com", .port = 80 };
    try testing.expect(port_rule.matches("Example.COM", 80));
    try testing.expect(!port_rule.matches("example.com", 81));
}
