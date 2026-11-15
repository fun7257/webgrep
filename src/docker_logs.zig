const std = @import("std");
const builtin = @import("builtin");
const libwebgrep = @import("libwebgrep");
const file_api = @import("file_api.zig");
const time_parser = @import("time_parser.zig");

pub const CONTAINER_FILTER_SEP = "::";

pub const DEFAULT_PING_TIMEOUT_MS: u32 = 1200;
pub const DEFAULT_CONNECT_TIMEOUT_MS: u32 = 2500;
pub const DEFAULT_HEAD_READ_TIMEOUT_MS: u32 = 3000;
pub const DEFAULT_STREAM_READ_TIMEOUT_MS: u32 = 8000;

pub const DockerError = error{
    DockerUnavailable,
    InvalidDockerEndpoint,
    ContainerNotFound,
    HttpProtocolError,
    HttpStatusError,
    CorruptDockerFrame,
    StreamTooLarge,
    Timeout,
    Canceled,
};

pub const StopCheck = struct {
    cancel_flag: ?*const std.atomic.Value(bool) = null,
    stop_ctx: ?*const anyopaque = null,
    stop_fn: ?*const fn (*const anyopaque) bool = null,

    pub fn shouldStop(self: StopCheck) bool {
        if (self.cancel_flag) |cf| {
            if (cf.load(.acquire)) return true;
        }
        if (self.stop_fn) |f| {
            if (self.stop_ctx) |ctx| {
                if (f(ctx)) return true;
            }
        }
        return false;
    }
};

pub const DockerEnv = struct {
    home_dir: ?[]const u8 = null,
    docker_host: ?[]const u8 = null,
    xdg_runtime_dir: ?[]const u8 = null,
};

pub const Transport = union(enum) {
    unix_socket: []const u8,
    tcp: struct {
        host: []const u8,
        port: u16,
    },
    containers_dir: []const u8,

    pub fn formatSummaryAlloc(self: Transport, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .unix_socket => |p| std.fmt.allocPrint(allocator, "unix://{s}", .{p}),
            .tcp => |t| if (std.mem.indexOfScalar(u8, t.host, ':') != null)
                std.fmt.allocPrint(allocator, "tcp://[{s}]:{d}", .{ t.host, t.port })
            else
                std.fmt.allocPrint(allocator, "tcp://{s}:{d}", .{ t.host, t.port }),
            .containers_dir => |d| allocator.dupe(u8, d),
        };
    }
};

pub const EndpointSpec = struct {
    base_endpoint: []const u8,
    container_filter: ?[]const u8 = null,
    is_auto: bool = false,
};

pub const ContainerInfo = struct {
    id: []const u8,
    short_id: []const u8,
    display_name: []const u8,
    raw_name: []const u8,
    image: []const u8,
    state: []const u8,
    status: []const u8,
    created_ns: i96,
    running: bool,
};

pub const DaemonProbeSummary = struct {
    ready: bool,
    transport_label: []const u8,
    total_containers: usize,
    running_containers: usize,
    summary_text: []const u8,
};

/// Splits an endpoint string into `(base_endpoint, optional_container_filter)`.
/// Safely ignores `://` scheme separators and `::` inside bracketed IPv6 literals (`[::1]`).
pub fn parseEndpointSpec(raw_input: []const u8) EndpointSpec {
    const trimmed = std.mem.trim(u8, raw_input, " \t\r\n");
    if (trimmed.len == 0 or
        std.ascii.eqlIgnoreCase(trimmed, "auto") or
        std.ascii.eqlIgnoreCase(trimmed, "docker") or
        std.ascii.eqlIgnoreCase(trimmed, "docker://auto") or
        std.ascii.eqlIgnoreCase(trimmed, "docker://"))
    {
        return .{
            .base_endpoint = "auto",
            .container_filter = null,
            .is_auto = true,
        };
    }

    var search_start: usize = 0;
    if (std.mem.indexOf(u8, trimmed, "://")) |scheme_idx| {
        search_start = scheme_idx + 3;
    }

    var in_brackets = false;
    var split_at: ?usize = null;
    var i: usize = search_start;
    while (i + 1 < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (c == '[') {
            in_brackets = true;
        } else if (c == ']') {
            in_brackets = false;
        } else if (!in_brackets and c == ':' and trimmed[i + 1] == ':') {
            split_at = i;
            break;
        }
    }

    if (split_at) |idx| {
        const head = std.mem.trim(u8, trimmed[0..idx], " \t");
        const tail = std.mem.trim(u8, trimmed[idx + 2 ..], " \t/");
        const is_auto_head = head.len == 0 or
            std.ascii.eqlIgnoreCase(head, "auto") or
            std.ascii.eqlIgnoreCase(head, "docker") or
            std.ascii.eqlIgnoreCase(head, "docker://auto");
        return .{
            .base_endpoint = if (is_auto_head) "auto" else head,
            .container_filter = if (tail.len > 0) tail else null,
            .is_auto = is_auto_head,
        };
    }

    return .{
        .base_endpoint = trimmed,
        .container_filter = null,
        .is_auto = false,
    };
}

pub fn normalizeStoredEndpointAlloc(
    allocator: std.mem.Allocator,
    env: DockerEnv,
    raw_input: []const u8,
) ![]u8 {
    const spec = parseEndpointSpec(raw_input);
    const norm_base: []const u8 = if (spec.is_auto)
        "auto"
    else if (std.ascii.startsWithIgnoreCase(spec.base_endpoint, "unix://")) blk: {
        const sock_raw = spec.base_endpoint["unix://".len..];
        const expanded = try expandTildeWithHomeAlloc(allocator, env.home_dir, sock_raw);
        defer allocator.free(expanded);
        break :blk try std.fmt.allocPrint(allocator, "unix://{s}", .{expanded});
    } else if (std.ascii.startsWithIgnoreCase(spec.base_endpoint, "tcp://") or
        std.ascii.startsWithIgnoreCase(spec.base_endpoint, "http://"))
        try allocator.dupe(u8, spec.base_endpoint)
    else
        try expandTildeWithHomeAlloc(allocator, env.home_dir, spec.base_endpoint);

    if (spec.container_filter) |cf| {
        defer if (!spec.is_auto) allocator.free(norm_base);
        return std.fmt.allocPrint(allocator, "{s}::{s}", .{ norm_base, cf });
    }
    if (spec.is_auto) {
        return allocator.dupe(u8, "auto");
    }
    return @constCast(norm_base);
}

fn expandTildeWithHomeAlloc(
    allocator: std.mem.Allocator,
    home_dir: ?[]const u8,
    raw_path: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    if (trimmed[0] == '~') {
        if (home_dir) |home| {
            if (trimmed.len == 1) return allocator.dupe(u8, home);
            if (trimmed[1] == '/') return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, trimmed[1..] });
        }
    }
    return allocator.dupe(u8, trimmed);
}

fn parseHostPort(raw_authority: []const u8, default_port: u16) !struct { host: []const u8, port: u16 } {
    var authority = std.mem.trim(u8, raw_authority, " \t/");
    if (std.mem.indexOfScalar(u8, authority, '/')) |slash| {
        authority = authority[0..slash];
    }
    if (authority.len == 0) return error.InvalidDockerEndpoint;

    if (authority[0] == '[') {
        const close_idx = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidDockerEndpoint;
        const ipv6_host = authority[1..close_idx];
        if (ipv6_host.len == 0) return error.InvalidDockerEndpoint;
        const rest = authority[close_idx + 1 ..];
        if (rest.len == 0) return .{ .host = ipv6_host, .port = default_port };
        if (rest[0] != ':') return error.InvalidDockerEndpoint;
        const port = std.fmt.parseInt(u16, rest[1..], 10) catch return error.InvalidDockerEndpoint;
        if (port == 0) return error.InvalidDockerEndpoint;
        return .{ .host = ipv6_host, .port = port };
    }

    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon_idx| {
        const host_part = authority[0..colon_idx];
        const port_part = authority[colon_idx + 1 ..];
        if (host_part.len == 0 or port_part.len == 0) return error.InvalidDockerEndpoint;
        const port = std.fmt.parseInt(u16, port_part, 10) catch return error.InvalidDockerEndpoint;
        if (port == 0) return error.InvalidDockerEndpoint;
        return .{ .host = host_part, .port = port };
    }

    return .{ .host = authority, .port = default_port };
}

const ResolveTransportError = error{
    OutOfMemory,
    InvalidDockerEndpoint,
    DockerUnavailable,
};

fn parseExplicitTransportAlloc(
    arena: std.mem.Allocator,
    io: std.Io,
    env: DockerEnv,
    base_endpoint: []const u8,
) ResolveTransportError!Transport {
    if (std.ascii.startsWithIgnoreCase(base_endpoint, "unix://")) {
        const raw_sock = base_endpoint["unix://".len..];
        const sock_path = try expandTildeWithHomeAlloc(arena, env.home_dir, raw_sock);
        if (sock_path.len == 0) return error.InvalidDockerEndpoint;
        return .{ .unix_socket = sock_path };
    }
    if (std.ascii.startsWithIgnoreCase(base_endpoint, "tcp://")) {
        const hp = try parseHostPort(base_endpoint["tcp://".len..], 2375);
        return .{ .tcp = .{ .host = try arena.dupe(u8, hp.host), .port = hp.port } };
    }
    if (std.ascii.startsWithIgnoreCase(base_endpoint, "http://")) {
        const hp = try parseHostPort(base_endpoint["http://".len..], 2375);
        return .{ .tcp = .{ .host = try arena.dupe(u8, hp.host), .port = hp.port } };
    }
    if (std.ascii.startsWithIgnoreCase(base_endpoint, "docker://")) {
        const rest = base_endpoint["docker://".len..];
        if (rest.len == 0 or std.ascii.eqlIgnoreCase(rest, "auto")) {
            return resolveAutoTransportAlloc(arena, io, env);
        }
        const hp = try parseHostPort(rest, 2375);
        return .{ .tcp = .{ .host = try arena.dupe(u8, hp.host), .port = hp.port } };
    }

    const expanded = try expandTildeWithHomeAlloc(arena, env.home_dir, base_endpoint);
    if (expanded.len == 0) return error.InvalidDockerEndpoint;

    // Check if it is an existing directory (e.g., `/var/lib/docker/containers`)
    if (std.Io.Dir.cwd().openDir(io, expanded, .{ .iterate = true })) |d_val| {
        var d = d_val;
        defer d.close(io);
        return .{ .containers_dir = expanded };
    } else |_| {}

    return .{ .unix_socket = expanded };
}

pub fn candidateSocketPathsAlloc(arena: std.mem.Allocator, env: DockerEnv) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const appendUnique = struct {
        fn call(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), path: []const u8) !void {
            if (path.len == 0 or path.len > std.Io.net.UnixAddress.max_len) return;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, path)) return;
            }
            try out.append(alloc, path);
        }
    }.call;

    if (env.docker_host) |dh_raw| {
        const dh = std.mem.trim(u8, dh_raw, " \t\r\n");
        if (std.ascii.startsWithIgnoreCase(dh, "unix://")) {
            const p = try expandTildeWithHomeAlloc(arena, env.home_dir, dh["unix://".len..]);
            try appendUnique(arena, &list, p);
        } else if (dh.len > 0 and std.mem.indexOf(u8, dh, "://") == null and dh[0] == '/') {
            try appendUnique(arena, &list, try arena.dupe(u8, dh));
        }
    }

    try appendUnique(arena, &list, "/var/run/docker.sock");
    if (env.home_dir) |home| {
        if (home.len > 0) {
            const rels = [_][]const u8{
                ".docker/run/docker.sock",
                ".orbstack/run/docker.sock",
                ".colima/default/docker.sock",
                ".colima/docker.sock",
                ".rd/docker.sock",
            };
            for (rels) |rel| {
                const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, home, "/"), rel });
                try appendUnique(arena, &list, p);
            }
        }
    }
    if (env.xdg_runtime_dir) |xdg| {
        if (xdg.len > 0) {
            const clean_xdg = std.mem.trimEnd(u8, xdg, "/");
            try appendUnique(arena, &list, try std.fmt.allocPrint(arena, "{s}/docker.sock", .{clean_xdg}));
            try appendUnique(arena, &list, try std.fmt.allocPrint(arena, "{s}/podman/podman.sock", .{clean_xdg}));
        }
    }
    try appendUnique(arena, &list, "/run/docker.sock");
    try appendUnique(arena, &list, "/run/podman/podman.sock");

    return list.toOwnedSlice(arena);
}

fn resolveAutoTransportAlloc(
    arena: std.mem.Allocator,
    io: std.Io,
    env: DockerEnv,
) ResolveTransportError!Transport {
    if (env.docker_host) |dh_raw| {
        const dh = std.mem.trim(u8, dh_raw, " \t\r\n");
        if (dh.len > 0 and !std.ascii.eqlIgnoreCase(dh, "auto")) {
            if (parseExplicitTransportAlloc(arena, io, env, dh)) |tr| {
                if (pingTransport(io, tr)) return tr;
            } else |_| {}
        }
    }

    const candidates = try candidateSocketPathsAlloc(arena, env);
    for (candidates) |sock_path| {
        const tr = Transport{ .unix_socket = sock_path };
        if (pingTransport(io, tr)) return tr;
    }

    if (std.Io.Dir.cwd().openDir(io, "/var/lib/docker/containers", .{ .iterate = true })) |d_val| {
        var d = d_val;
        defer d.close(io);
        return .{ .containers_dir = "/var/lib/docker/containers" };
    } else |_| {}

    return error.DockerUnavailable;
}

pub fn resolveTransportAlloc(
    arena: std.mem.Allocator,
    io: std.Io,
    env: DockerEnv,
    raw_endpoint: []const u8,
) !struct { transport: Transport, container_filter: ?[]const u8 } {
    const spec = parseEndpointSpec(raw_endpoint);
    const transport = if (spec.is_auto)
        try resolveAutoTransportAlloc(arena, io, env)
    else
        try parseExplicitTransportAlloc(arena, io, env, spec.base_endpoint);
    return .{
        .transport = transport,
        .container_filter = spec.container_filter,
    };
}

fn connectIpWithTimeoutPosix(ip_addr: std.Io.net.IpAddress, timeout_ms: u32) !std.Io.net.Stream {
    const PosixSockAddr = extern union {
        any: std.posix.sockaddr,
        in: std.posix.sockaddr.in,
        in6: std.posix.sockaddr.in6,
    };
    var storage: PosixSockAddr = undefined;
    var family: std.posix.sa_family_t = undefined;
    var addr_len: std.posix.socklen_t = undefined;

    switch (ip_addr) {
        .ip4 => |v4| {
            family = std.posix.AF.INET;
            addr_len = @sizeOf(std.posix.sockaddr.in);
            storage.in = .{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, v4.port),
                .addr = @bitCast(v4.bytes),
            };
            if (@hasField(std.posix.sockaddr.in, "len")) {
                storage.in.len = @intCast(addr_len);
            }
        },
        .ip6 => |v6| {
            family = std.posix.AF.INET6;
            addr_len = @sizeOf(std.posix.sockaddr.in6);
            storage.in6 = .{
                .family = std.posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, v6.port),
                .flowinfo = v6.flow,
                .addr = v6.bytes,
                .scope_id = v6.interface.index,
            };
            if (@hasField(std.posix.sockaddr.in6, "len")) {
                storage.in6.len = @intCast(addr_len);
            }
        },
    }

    const rc_sock = std.posix.system.socket(family, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(rc_sock) != .SUCCESS) return error.DockerUnavailable;
    const fd: std.posix.socket_t = @intCast(rc_sock);
    errdefer _ = std.posix.system.close(fd);

    _ = std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(usize, std.posix.FD_CLOEXEC));

    if (timeout_ms > 0) {
        const orig_fl_rc = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
        if (std.posix.errno(orig_fl_rc) == .SUCCESS) {
            const orig_fl: usize = @intCast(orig_fl_rc);
            const nonblock_bit: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
            _ = std.posix.system.fcntl(fd, std.posix.F.SETFL, orig_fl | nonblock_bit);
            defer _ = std.posix.system.fcntl(fd, std.posix.F.SETFL, orig_fl);

            while (true) {
                switch (std.posix.errno(std.posix.system.connect(fd, &storage.any, addr_len))) {
                    .SUCCESS => break,
                    .INTR => continue,
                    .INPROGRESS, .AGAIN => {
                        var pfd = [1]std.posix.pollfd{.{
                            .fd = fd,
                            .events = std.posix.POLL.OUT,
                            .revents = 0,
                        }};
                        const ready = std.posix.poll(&pfd, @intCast(timeout_ms)) catch return error.DockerUnavailable;
                        if (ready == 0) return error.DockerUnavailable;
                        var so_err: c_int = 0;
                        var opt_len: std.posix.socklen_t = @sizeOf(c_int);
                        if (std.posix.errno(std.posix.system.getsockopt(
                            fd,
                            std.posix.SOL.SOCKET,
                            std.posix.SO.ERROR,
                            @ptrCast(&so_err),
                            &opt_len,
                        )) != .SUCCESS or so_err != 0) {
                            return error.DockerUnavailable;
                        }
                        break;
                    },
                    else => return error.DockerUnavailable,
                }
            }
            return .{ .socket = .{ .handle = fd, .address = ip_addr } };
        }
    }

    while (true) {
        switch (std.posix.errno(std.posix.system.connect(fd, &storage.any, addr_len))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.DockerUnavailable,
        }
    }
    return .{ .socket = .{ .handle = fd, .address = ip_addr } };
}

fn connectTransportStreamWithTimeout(io: std.Io, transport: Transport, timeout_ms: u32) !std.Io.net.Stream {
    switch (transport) {
        .unix_socket => |sock_path| {
            const ua = std.Io.net.UnixAddress.init(sock_path) catch return error.InvalidDockerEndpoint;
            return ua.connect(io) catch return error.DockerUnavailable;
        },
        .tcp => |t| {
            if (std.Io.net.IpAddress.parse(t.host, t.port)) |ip_addr| {
                if (comptime (builtin.os.tag != .windows and builtin.os.tag != .wasi)) {
                    return connectIpWithTimeoutPosix(ip_addr, timeout_ms);
                }
                return ip_addr.connect(io, .{ .mode = .stream }) catch return error.DockerUnavailable;
            } else |_| {
                if (comptime (builtin.os.tag != .windows and builtin.os.tag != .wasi)) {
                    if (std.ascii.eqlIgnoreCase(t.host, "localhost")) {
                        if (connectIpWithTimeoutPosix(.{ .ip4 = .loopback(t.port) }, timeout_ms)) |s| return s else |_| {}
                        if (connectIpWithTimeoutPosix(.{ .ip6 = .loopback(t.port) }, timeout_ms)) |s| return s else |_| {}
                        return error.DockerUnavailable;
                    }
                }
                // Note: Zig 0.17.1 `Threaded.netConnectIpPosix` panics if `ConnectOptions.timeout != .none`.
                const hn = std.Io.net.HostName.init(t.host) catch return error.InvalidDockerEndpoint;
                return hn.connect(io, t.port, .{ .mode = .stream }) catch return error.DockerUnavailable;
            }
        },
        .containers_dir => return error.InvalidDockerEndpoint,
    }
}

fn connectTransportStream(io: std.Io, transport: Transport) !std.Io.net.Stream {
    return connectTransportStreamWithTimeout(io, transport, DEFAULT_CONNECT_TIMEOUT_MS);
}

fn waitSocketReadable(
    net_stream: std.Io.net.Stream,
    timeout_ms: u32,
    stop_check: StopCheck,
) !void {
    if (stop_check.shouldStop()) return error.Canceled;
    if (comptime (builtin.os.tag == .windows or builtin.os.tag == .wasi)) return;

    const has_stop = (stop_check.cancel_flag != null or stop_check.stop_fn != null);
    var remaining_ms: u32 = timeout_ms;
    while (true) {
        if (stop_check.shouldStop()) return error.Canceled;
        const slice_ms: i32 = if (timeout_ms == 0)
            (if (has_stop) 50 else -1)
        else
            @intCast(@min(remaining_ms, if (has_stop) @as(u32, 50) else remaining_ms));

        var pfd = [1]std.posix.pollfd{.{
            .fd = net_stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfd, slice_ms) catch return error.HttpProtocolError;
        if (ready > 0) return;
        if (stop_check.shouldStop()) return error.Canceled;
        if (timeout_ms > 0) {
            const waited: u32 = @intCast(slice_ms);
            if (remaining_ms <= waited) return error.Timeout;
            remaining_ms -= waited;
        }
    }
}

fn readSocketSome(
    io: std.Io,
    net_stream: std.Io.net.Stream,
    dest: []u8,
    timeout_ms: u32,
    stop_check: StopCheck,
) !usize {
    if (dest.len == 0) return 0;
    if (stop_check.shouldStop()) return error.Canceled;

    if (comptime (builtin.os.tag != .windows and builtin.os.tag != .wasi and @hasDecl(std.posix.MSG, "DONTWAIT"))) {
        while (true) {
            const rc = std.posix.system.recvfrom(
                net_stream.socket.handle,
                @ptrCast(dest.ptr),
                dest.len,
                std.posix.MSG.DONTWAIT,
                null,
                null,
            );
            switch (std.posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => break,
                else => return error.HttpProtocolError,
            }
        }
    }

    try waitSocketReadable(net_stream, timeout_ms, stop_check);
    var vecs: [1][]u8 = .{dest};
    return net_stream.read(io, &vecs) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.HttpProtocolError,
    };
}

const StreamFormat = enum {
    auto_detect,
    multiplexed,
    raw,
};

const HttpHeadInfo = struct {
    status_code: u16,
    is_chunked: bool,
    content_length: ?u64,
    stream_format: StreamFormat,
    initial_body: []const u8,
};

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub const HeaderBounds = struct { head_end: usize, body_start: usize };

pub fn findHeaderEnd(buf: []const u8) ?HeaderBounds {
    if (std.mem.indexOf(u8, buf, "\r\n\r\n")) |idx| {
        return .{ .head_end = idx, .body_start = idx + 4 };
    }
    if (std.mem.indexOf(u8, buf, "\n\n")) |idx| {
        return .{ .head_end = idx, .body_start = idx + 2 };
    }
    return null;
}

pub fn readReaderSome(r: *std.Io.Reader, dest: []u8) !usize {
    if (dest.len == 0) return 0;
    const avail = r.peekGreedy(1) catch |err| switch (err) {
        error.EndOfStream => return 0,
        else => return err,
    };
    const n = @min(dest.len, avail.len);
    @memcpy(dest[0..n], avail[0..n]);
    r.toss(n);
    return n;
}

fn sendHttpGetAndReadHead(
    io: std.Io,
    net_stream: std.Io.net.Stream,
    target_uri: []const u8,
    host_header: []const u8,
    head_storage: []u8,
    read_timeout_ms: u32,
    stop_check: StopCheck,
) !HttpHeadInfo {
    var wbuf: [1024]u8 = undefined;
    var writer = net_stream.writer(io, &wbuf);
    writer.interface.print(
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: webgrep/0.5\r\nAccept: */*\r\nConnection: close\r\n\r\n",
        .{ target_uri, host_header },
    ) catch return error.HttpProtocolError;
    writer.interface.flush() catch return error.HttpProtocolError;

    var total_read: usize = 0;
    var header_bounds: ?HeaderBounds = null;

    while (total_read < head_storage.len) {
        const chunk_cap = @min(@as(usize, 4096), head_storage.len - total_read);
        const n = try readSocketSome(
            io,
            net_stream,
            head_storage[total_read .. total_read + chunk_cap],
            read_timeout_ms,
            stop_check,
        );
        if (n == 0) break;
        total_read += n;
        if (findHeaderEnd(head_storage[0..total_read])) |hb| {
            header_bounds = hb;
            break;
        }
    }

    const hb = header_bounds orelse return error.HttpProtocolError;
    const raw_head = head_storage[0..hb.head_end];

    var lines_it = std.mem.splitScalar(u8, raw_head, '\n');
    const status_line_raw = lines_it.next() orelse return error.HttpProtocolError;
    const status_line = std.mem.trimEnd(u8, status_line_raw, "\r");
    // Expected: `HTTP/1.x NNN ...`
    if (!std.mem.startsWith(u8, status_line, "HTTP/")) return error.HttpProtocolError;
    const sp1 = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.HttpProtocolError;
    const after_sp1 = std.mem.trimStart(u8, status_line[sp1 + 1 ..], " ");
    if (after_sp1.len < 3) return error.HttpProtocolError;
    const status_code = std.fmt.parseInt(u16, after_sp1[0..3], 10) catch return error.HttpProtocolError;

    var is_chunked = false;
    var content_length: ?u64 = null;
    var stream_format: StreamFormat = .auto_detect;

    while (lines_it.next()) |raw_hdr| {
        const hdr = std.mem.trim(u8, raw_hdr, " \t\r");
        if (hdr.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, hdr, ':') orelse continue;
        const name = std.mem.trim(u8, hdr[0..colon], " \t");
        const val = std.mem.trim(u8, hdr[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (containsAsciiIgnoreCase(val, "chunked")) is_chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(u64, val, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            if (containsAsciiIgnoreCase(val, "multiplexed-stream")) {
                stream_format = .multiplexed;
            }
            // Intentionally keep `.auto_detect` for `application/vnd.docker.raw-stream` / `text/plain`:
            // Docker Engine < v23 (API < v1.42) and compatible daemons send `raw-stream` even when
            // `Tty: false` and the body is framed with 8-byte multiplexed headers `[0..2, 0, 0, 0, len]`.
        }
    }

    return .{
        .status_code = status_code,
        .is_chunked = is_chunked,
        .content_length = content_length,
        .stream_format = stream_format,
        .initial_body = head_storage[hb.body_start..total_read],
    };
}

/// Stateful HTTP/1.1 response body decoder supporting `Transfer-Encoding: chunked`,
/// `Content-Length`, and connection-close EOF bodies over a `std.Io.net.Stream`.
const HttpBodyDecoder = struct {
    const ChunkState = enum {
        size_line,
        data,
        post_data_lf,
        trailers,
        eof,
    };

    io: std.Io,
    net_stream: std.Io.net.Stream,
    read_timeout_ms: u32 = DEFAULT_STREAM_READ_TIMEOUT_MS,
    stop_check: StopCheck = .{},
    net_rbuf: [16384]u8 = undefined,
    net_rpos: usize = 0,
    net_rlen: usize = 0,

    is_chunked: bool = false,
    content_remaining: ?u64 = null,
    chunk_state: ChunkState = .size_line,
    chunk_remaining: u64 = 0,
    line_scratch: [256]u8 = undefined,
    line_len: usize = 0,
    reached_eof: bool = false,

    fn initInPlace(
        self: *HttpBodyDecoder,
        io: std.Io,
        net_stream: std.Io.net.Stream,
        head: HttpHeadInfo,
        read_timeout_ms: u32,
        stop_check: StopCheck,
    ) void {
        self.io = io;
        self.net_stream = net_stream;
        self.read_timeout_ms = read_timeout_ms;
        self.stop_check = stop_check;
        self.net_rpos = 0;
        self.net_rlen = 0;
        if (head.initial_body.len > 0) {
            const copy_n = @min(head.initial_body.len, self.net_rbuf.len);
            @memcpy(self.net_rbuf[0..copy_n], head.initial_body[0..copy_n]);
            self.net_rlen = copy_n;
        }
        self.is_chunked = head.is_chunked;
        self.content_remaining = if (head.is_chunked) null else head.content_length;
        self.chunk_state = .size_line;
        self.chunk_remaining = 0;
        self.line_len = 0;
        self.reached_eof = false;
    }

    fn ensureWireBuffered(self: *HttpBodyDecoder) ![]const u8 {
        if (self.net_rpos < self.net_rlen) {
            return self.net_rbuf[self.net_rpos..self.net_rlen];
        }
        self.net_rpos = 0;
        self.net_rlen = 0;
        const filled = try readSocketSome(
            self.io,
            self.net_stream,
            &self.net_rbuf,
            self.read_timeout_ms,
            self.stop_check,
        );
        self.net_rlen = filled;
        return self.net_rbuf[0..filled];
    }

    fn readWireSome(self: *HttpBodyDecoder, dest: []u8) !usize {
        if (dest.len == 0) return 0;
        if (self.net_rpos < self.net_rlen) {
            const avail = self.net_rlen - self.net_rpos;
            const n = @min(avail, dest.len);
            @memcpy(dest[0..n], self.net_rbuf[self.net_rpos .. self.net_rpos + n]);
            self.net_rpos += n;
            return n;
        }
        self.net_rpos = 0;
        self.net_rlen = 0;
        if (dest.len >= self.net_rbuf.len) {
            return readSocketSome(self.io, self.net_stream, dest, self.read_timeout_ms, self.stop_check);
        }
        const filled = try readSocketSome(self.io, self.net_stream, &self.net_rbuf, self.read_timeout_ms, self.stop_check);
        if (filled == 0) return 0;
        const n = @min(filled, dest.len);
        @memcpy(dest[0..n], self.net_rbuf[0..n]);
        self.net_rpos = n;
        self.net_rlen = filled;
        return n;
    }

    pub fn readBodySome(self: *HttpBodyDecoder, dest: []u8) !usize {
        if (dest.len == 0 or self.reached_eof) return 0;

        if (!self.is_chunked) {
            if (self.content_remaining) |rem| {
                if (rem == 0) {
                    self.reached_eof = true;
                    return 0;
                }
                const cap: usize = @intCast(@min(@as(u64, dest.len), rem));
                const n = try self.readWireSome(dest[0..cap]);
                if (n == 0) {
                    self.reached_eof = true;
                    return 0;
                }
                self.content_remaining = rem - n;
                if (self.content_remaining.? == 0) self.reached_eof = true;
                return n;
            }
            const n = try self.readWireSome(dest);
            if (n == 0) self.reached_eof = true;
            return n;
        }

        while (true) {
            switch (self.chunk_state) {
                .eof => {
                    self.reached_eof = true;
                    return 0;
                },
                .size_line => {
                    while (true) {
                        const avail = try self.ensureWireBuffered();
                        if (avail.len == 0) {
                            self.chunk_state = .eof;
                            self.reached_eof = true;
                            return 0;
                        }
                        if (std.mem.indexOfScalar(u8, avail, '\n')) |nl_idx| {
                            const part = avail[0..nl_idx];
                            self.net_rpos += nl_idx + 1;
                            var line: []const u8 = if (self.line_len == 0)
                                part
                            else blk_line: {
                                if (self.line_len + part.len > self.line_scratch.len) return error.HttpProtocolError;
                                @memcpy(self.line_scratch[self.line_len .. self.line_len + part.len], part);
                                const total_len = self.line_len + part.len;
                                self.line_len = 0;
                                break :blk_line self.line_scratch[0..total_len];
                            };
                            line = std.mem.trim(u8, line, " \t\r");
                            if (line.len == 0) continue; // tolerate stray CRLF
                            if (std.mem.indexOfScalar(u8, line, ';')) |semi| {
                                line = std.mem.trim(u8, line[0..semi], " \t");
                            }
                            const sz = std.fmt.parseInt(u64, line, 16) catch return error.HttpProtocolError;
                            if (sz == 0) {
                                self.chunk_state = .trailers;
                            } else {
                                self.chunk_remaining = sz;
                                self.chunk_state = .data;
                            }
                            break;
                        } else {
                            if (self.line_len + avail.len > self.line_scratch.len) return error.HttpProtocolError;
                            @memcpy(self.line_scratch[self.line_len .. self.line_len + avail.len], avail);
                            self.line_len += avail.len;
                            self.net_rpos += avail.len;
                        }
                    }
                },
                .data => {
                    const want: usize = @intCast(@min(@as(u64, dest.len), self.chunk_remaining));
                    const n = try self.readWireSome(dest[0..want]);
                    if (n == 0) return error.HttpProtocolError;
                    self.chunk_remaining -= n;
                    if (self.chunk_remaining == 0) {
                        self.chunk_state = .post_data_lf;
                    }
                    return n;
                },
                .post_data_lf => {
                    const avail = try self.ensureWireBuffered();
                    if (avail.len == 0) return error.HttpProtocolError;
                    if (avail[0] == '\r') {
                        if (avail.len >= 2) {
                            if (avail[1] != '\n') return error.HttpProtocolError;
                            self.net_rpos += 2;
                        } else {
                            self.net_rpos += 1;
                            const next_avail = try self.ensureWireBuffered();
                            if (next_avail.len == 0 or next_avail[0] != '\n') return error.HttpProtocolError;
                            self.net_rpos += 1;
                        }
                    } else if (avail[0] == '\n') {
                        self.net_rpos += 1;
                    } else {
                        return error.HttpProtocolError;
                    }
                    self.chunk_state = .size_line;
                },
                .trailers => {
                    // Consume trailer lines until empty line (`\r\n` or `\n`) or EOF
                    self.line_len = 0;
                    while (true) {
                        const avail = try self.ensureWireBuffered();
                        if (avail.len == 0) {
                            self.chunk_state = .eof;
                            self.reached_eof = true;
                            return 0;
                        }
                        if (std.mem.indexOfScalar(u8, avail, '\n')) |nl_idx| {
                            const part = avail[0..nl_idx];
                            self.net_rpos += nl_idx + 1;
                            const line = if (self.line_len == 0)
                                part
                            else blk_tr: {
                                const take = @min(part.len, self.line_scratch.len - self.line_len);
                                @memcpy(self.line_scratch[self.line_len .. self.line_len + take], part[0..take]);
                                const total_len = self.line_len + take;
                                self.line_len = 0;
                                break :blk_tr self.line_scratch[0..total_len];
                            };
                            const trimmed = std.mem.trim(u8, line, "\r");
                            if (trimmed.len == 0) {
                                self.chunk_state = .eof;
                                self.reached_eof = true;
                                return 0;
                            }
                        } else {
                            const take = @min(avail.len, self.line_scratch.len - self.line_len);
                            if (take > 0) {
                                @memcpy(self.line_scratch[self.line_len .. self.line_len + take], avail[0..take]);
                                self.line_len += take;
                            }
                            self.net_rpos += avail.len;
                        }
                    }
                },
            }
        }
    }

    pub fn readBodyExact(self: *HttpBodyDecoder, dest: []u8) !usize {
        var filled: usize = 0;
        while (filled < dest.len) {
            const n = try self.readBodySome(dest[filled..]);
            if (n == 0) break;
            filled += n;
        }
        return filled;
    }

    pub fn allocAllBody(self: *HttpBodyDecoder, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var tmp: [8192]u8 = undefined;
        while (true) {
            const n = try self.readBodySome(&tmp);
            if (n == 0) break;
            if (out.items.len + n > max_bytes) return error.StreamTooLarge;
            try out.appendSlice(allocator, tmp[0..n]);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub fn pingTransport(io: std.Io, transport: Transport) bool {
    switch (transport) {
        .containers_dir => |dir_path| {
            var d = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return false;
            d.close(io);
            return true;
        },
        .unix_socket, .tcp => {
            const net_stream = connectTransportStreamWithTimeout(io, transport, DEFAULT_PING_TIMEOUT_MS) catch return false;
            defer net_stream.close(io);

            const host_hdr = switch (transport) {
                .tcp => |t| t.host,
                else => "localhost",
            };
            var head_buf: [4096]u8 = undefined;
            const head = sendHttpGetAndReadHead(
                io,
                net_stream,
                "/_ping",
                host_hdr,
                &head_buf,
                DEFAULT_PING_TIMEOUT_MS,
                .{},
            ) catch return false;
            return head.status_code >= 200 and head.status_code < 300;
        },
    }
}

/// Sanitizes a Docker container name into a safe single virtual-path segment (never `.` or `..` or containing `/`).
pub fn sanitizeContainerNameAlloc(allocator: std.mem.Allocator, raw_name: []const u8, fallback_short_id: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, raw_name, " \t\r\n/");
    if (trimmed.len == 0) trimmed = fallback_short_id;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (trimmed) |ch| {
        if (ch == '/' or ch == '\\' or ch == 0 or ch == ':' or std.ascii.isControl(ch) or std.ascii.isWhitespace(ch)) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '_') {
                try out.append(allocator, '_');
            }
        } else {
            try out.append(allocator, ch);
        }
        if (out.items.len >= 96) break;
    }

    const res = std.mem.trim(u8, out.items, "._ ");
    if (res.len == 0 or std.mem.eql(u8, res, ".") or std.mem.eql(u8, res, "..")) {
        out.deinit(allocator);
        return allocator.dupe(u8, if (fallback_short_id.len > 0) fallback_short_id else "container");
    }
    if (res.ptr != out.items.ptr or res.len != out.items.len) {
        const copy = try allocator.dupe(u8, res);
        out.deinit(allocator);
        return copy;
    }
    return out.toOwnedSlice(allocator);
}

fn isSafeContainerId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    }
    return true;
}

pub fn containerMatchesTargetFilter(c: ContainerInfo, filter: []const u8) bool {
    const clean = std.mem.trim(u8, filter, " \t/");
    if (clean.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(c.display_name, clean)) return true;
    if (std.ascii.eqlIgnoreCase(c.raw_name, clean)) return true;
    if (std.ascii.eqlIgnoreCase(c.id, clean)) return true;
    if (std.ascii.eqlIgnoreCase(c.short_id, clean)) return true;
    if (clean.len >= 4 and c.id.len >= clean.len and std.ascii.eqlIgnoreCase(c.id[0..clean.len], clean)) {
        return true;
    }
    return false;
}

pub fn deduplicateDisplayNamesInPlace(arena: std.mem.Allocator, list: []ContainerInfo) !void {
    if (list.len <= 1) return;

    if (list.len <= 8) {
        var dup_flags: [8]bool = .{ false, false, false, false, false, false, false, false };
        for (list, 0..) |c, i| {
            if (dup_flags[i]) continue;
            for (i + 1..list.len) |j| {
                if (std.ascii.eqlIgnoreCase(c.display_name, list[j].display_name)) {
                    dup_flags[i] = true;
                    dup_flags[j] = true;
                }
            }
        }
        for (list, 0..) |c, i| {
            if (dup_flags[i] and c.short_id.len > 0) {
                list[i].display_name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ c.display_name, c.short_id });
            }
        }
        return;
    }

    const lowers = try arena.alloc([]const u8, list.len);
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    try counts.ensureTotalCapacity(arena, @intCast(list.len));

    for (list, 0..) |c, i| {
        const low = try arena.alloc(u8, c.display_name.len);
        for (c.display_name, 0..) |ch, k| low[k] = std.ascii.toLower(ch);
        lowers[i] = low;
        const gop = counts.getOrPutAssumeCapacity(low);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.value_ptr.* = 1;
        }
    }

    for (list, 0..) |c, i| {
        if (c.short_id.len > 0 and (counts.get(lowers[i]) orelse 0) > 1) {
            list[i].display_name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ c.display_name, c.short_id });
        }
    }
}

fn sortContainersRunningFirst(items: []ContainerInfo) void {
    const SortCtx = struct {
        pub fn lessThan(_: void, a: ContainerInfo, b: ContainerInfo) bool {
            if (a.running != b.running) return a.running;
            if (a.created_ns != b.created_ns) return a.created_ns > b.created_ns;
            return std.mem.order(u8, a.display_name, b.display_name) == .lt;
        }
    };
    std.mem.sort(ContainerInfo, items, {}, SortCtx.lessThan);
}

const HttpContainerDto = struct {
    Id: []const u8 = "",
    Names: ?[]const []const u8 = null,
    Name: ?[]const u8 = null,
    Image: []const u8 = "",
    State: []const u8 = "",
    Status: []const u8 = "",
    Created: ?std.json.Value = null,
};

fn listContainersFromHttpAlloc(
    arena: std.mem.Allocator,
    io: std.Io,
    transport: Transport,
) ![]ContainerInfo {
    const net_stream = try connectTransportStreamWithTimeout(io, transport, DEFAULT_CONNECT_TIMEOUT_MS);
    defer net_stream.close(io);

    const host_hdr = switch (transport) {
        .tcp => |t| t.host,
        else => "localhost",
    };

    var head_buf: [16384]u8 = undefined;
    const head = try sendHttpGetAndReadHead(
        io,
        net_stream,
        "/containers/json?all=1",
        host_hdr,
        &head_buf,
        DEFAULT_HEAD_READ_TIMEOUT_MS,
        .{},
    );
    if (head.status_code < 200 or head.status_code >= 300) {
        return error.HttpStatusError;
    }

    const decoder_ptr = try arena.create(HttpBodyDecoder);
    decoder_ptr.* = .{ .io = io, .net_stream = net_stream };
    decoder_ptr.initInPlace(io, net_stream, head, DEFAULT_HEAD_READ_TIMEOUT_MS, .{});
    const json_bytes = try decoder_ptr.allocAllBody(arena, 32 * 1024 * 1024);

    const parsed = std.json.parseFromSlice([]const HttpContainerDto, arena, json_bytes, .{
        .ignore_unknown_fields = true,
    }) catch {
        return error.HttpProtocolError;
    };

    var out: std.ArrayList(ContainerInfo) = .empty;
    try out.ensureTotalCapacity(arena, parsed.value.len);

    var auto_tp = time_parser.CompiledTimeParser{};

    for (parsed.value) |item| {
        if (!isSafeContainerId(item.Id)) continue;

        const id_copy = try arena.dupe(u8, item.Id);
        const short_id = id_copy[0..@min(id_copy.len, 12)];

        var raw_name: []const u8 = "";
        if (item.Names) |names| {
            for (names) |nv| {
                const stripped = std.mem.trimStart(u8, nv, "/");
                if (stripped.len > 0) {
                    // Prefer top-level container name without `/` link aliases
                    raw_name = stripped;
                    if (std.mem.indexOfScalar(u8, stripped, '/') == null) break;
                }
            }
        }
        if (raw_name.len == 0) {
            if (item.Name) |nv| {
                raw_name = std.mem.trimStart(u8, nv, "/");
            }
        }
        const raw_name_copy = try arena.dupe(u8, if (raw_name.len > 0) raw_name else short_id);
        const display_name = try sanitizeContainerNameAlloc(arena, raw_name_copy, short_id);

        var created_ns: i96 = 0;
        if (item.Created) |cv| {
            switch (cv) {
                .integer => |sec| {
                    if (sec > 0) created_ns = @as(i96, sec) * std.time.ns_per_s;
                },
                .string => |s| {
                    if (auto_tp.parseLine(s, .{}, null, null)) |ns| {
                        created_ns = @intCast(ns);
                    }
                },
                else => {},
            }
        }

        const running = std.ascii.eqlIgnoreCase(item.State, "running") or
            std.ascii.startsWithIgnoreCase(item.Status, "Up");

        out.appendAssumeCapacity(.{
            .id = id_copy,
            .short_id = short_id,
            .display_name = display_name,
            .raw_name = raw_name_copy,
            .image = try arena.dupe(u8, item.Image),
            .state = try arena.dupe(u8, item.State),
            .status = try arena.dupe(u8, item.Status),
            .created_ns = created_ns,
            .running = running,
        });
    }

    try deduplicateDisplayNamesInPlace(arena, out.items);
    sortContainersRunningFirst(out.items);
    return out.toOwnedSlice(arena);
}

const DirConfigV2Dto = struct {
    Name: ?[]const u8 = null,
    Created: ?[]const u8 = null,
    Config: ?struct {
        Image: ?[]const u8 = null,
    } = null,
    State: ?struct {
        Running: ?bool = null,
    } = null,
};

fn readSmallFileAlloc(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    max_bytes: usize,
) ?[]u8 {
    var f = dir.openFile(io, sub_path, .{ .allow_directory = false }) catch return null;
    defer f.close(io);
    var rbuf: [4096]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    return fr.interface.allocRemaining(arena, .limited(max_bytes)) catch null;
}

fn listContainersFromDirAlloc(
    arena: std.mem.Allocator,
    io: std.Io,
    containers_dir_path: []const u8,
) ![]ContainerInfo {
    var root_dir = std.Io.Dir.cwd().openDir(io, containers_dir_path, .{ .iterate = true }) catch {
        return error.DockerUnavailable;
    };
    defer root_dir.close(io);

    var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
    var lister = libwebgrep.walk_list.Lister.init(root_dir, &scratch);
    var batch: [64]std.Io.Dir.Entry = undefined;

    var out: std.ArrayList(ContainerInfo) = .empty;
    var auto_tp = time_parser.CompiledTimeParser{};
    var cfg_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer cfg_arena_state.deinit();

    while (true) {
        const count = lister.fill(io, &batch) catch break;
        if (count == 0) break;

        for (batch[0..count]) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            var is_dir = (entry.kind == .directory);
            if (entry.kind == .sym_link or entry.kind == .unknown) {
                const st = root_dir.statFile(io, entry.name, .{}) catch continue;
                is_dir = (st.kind == .directory);
            }
            if (!is_dir or !isSafeContainerId(entry.name)) continue;

            var cdir = root_dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer cdir.close(io);

            const id_copy = try arena.dupe(u8, entry.name);
            const short_id = id_copy[0..@min(id_copy.len, 12)];
            const main_log_name = try std.fmt.allocPrint(arena, "{s}-json.log", .{id_copy});

            _ = cfg_arena_state.reset(.retain_capacity);
            const cfg_alloc = cfg_arena_state.allocator();

            const cfg_bytes = readSmallFileAlloc(cfg_alloc, io, cdir, "config.v2.json", 1024 * 1024);
            const log_stat = cdir.statFile(io, main_log_name, .{}) catch null;
            if (cfg_bytes == null and log_stat == null) continue;

            var raw_name: []const u8 = short_id;
            var image_str: []const u8 = "";
            var running = false;
            var created_ns: i96 = if (log_stat) |st| st.mtime.nanoseconds else 0;

            if (cfg_bytes) |cb| {
                if (std.json.parseFromSlice(DirConfigV2Dto, cfg_alloc, cb, .{
                    .ignore_unknown_fields = true,
                })) |parsed_cfg| {
                    const dto = parsed_cfg.value;
                    if (dto.Name) |nv| {
                        const stripped = std.mem.trimStart(u8, nv, "/");
                        if (stripped.len > 0) raw_name = try arena.dupe(u8, stripped);
                    }
                    if (dto.Created) |cv| {
                        if (auto_tp.parseLine(cv, .{}, null, null)) |ns| {
                            created_ns = @intCast(ns);
                        }
                    }
                    if (dto.Config) |cfg_sub| {
                        if (cfg_sub.Image) |iv| {
                            image_str = try arena.dupe(u8, iv);
                        }
                    }
                    if (dto.State) |st_sub| {
                        if (st_sub.Running) |rv| {
                            running = rv;
                        }
                    }
                } else |_| {}
            }

            if (log_stat) |st| {
                if (st.mtime.nanoseconds > created_ns) {
                    created_ns = st.mtime.nanoseconds;
                }
            }

            const display_name = try sanitizeContainerNameAlloc(arena, raw_name, short_id);
            try out.append(arena, .{
                .id = id_copy,
                .short_id = short_id,
                .display_name = display_name,
                .raw_name = raw_name,
                .image = image_str,
                .state = if (running) "running" else "exited",
                .status = if (running) "Up" else "Exited",
                .created_ns = created_ns,
                .running = running,
            });
        }
    }

    try deduplicateDisplayNamesInPlace(arena, out.items);
    sortContainersRunningFirst(out.items);
    return out.toOwnedSlice(arena);
}

pub fn listContainersForTransportAlloc(
    arena: std.mem.Allocator,
    io: std.Io,
    transport: Transport,
    container_filter: ?[]const u8,
) ![]ContainerInfo {
    const all = switch (transport) {
        .unix_socket, .tcp => try listContainersFromHttpAlloc(arena, io, transport),
        .containers_dir => |d| try listContainersFromDirAlloc(arena, io, d),
    };
    const cf = container_filter orelse return all;
    const clean_cf = std.mem.trim(u8, cf, " \t/");
    if (clean_cf.len == 0) return all;

    var filtered: std.ArrayList(ContainerInfo) = .empty;
    for (all) |c| {
        if (containerMatchesTargetFilter(c, clean_cf)) {
            try filtered.append(arena, c);
        }
    }
    return filtered.toOwnedSlice(arena);
}

pub const ListedDocker = struct {
    transport: Transport,
    containers: []ContainerInfo,
    running_count: usize,
    summary_endpoint: []const u8,
};

pub fn listContainersAlloc(
    arena: std.mem.Allocator,
    io: std.Io,
    env: DockerEnv,
    raw_endpoint: []const u8,
) !ListedDocker {
    const resolved = try resolveTransportAlloc(arena, io, env, raw_endpoint);
    const containers = try listContainersForTransportAlloc(arena, io, resolved.transport, resolved.container_filter);
    var running_count: usize = 0;
    for (containers) |c| {
        if (c.running) running_count += 1;
    }
    const summary_ep = try resolved.transport.formatSummaryAlloc(arena);
    return .{
        .transport = resolved.transport,
        .containers = containers,
        .running_count = running_count,
        .summary_endpoint = summary_ep,
    };
}

pub fn unavailableProbeSummaryAlloc(
    arena: std.mem.Allocator,
    raw_endpoint: []const u8,
) !DaemonProbeSummary {
    const fallback_label = if (raw_endpoint.len > 0) raw_endpoint else "auto";
    return .{
        .ready = false,
        .transport_label = fallback_label,
        .total_containers = 0,
        .running_containers = 0,
        .summary_text = try std.fmt.allocPrint(arena, "{s} · Docker unreachable", .{fallback_label}),
    };
}

pub fn summarizeListedDockerAlloc(
    arena: std.mem.Allocator,
    res: ListedDocker,
    raw_endpoint: []const u8,
) !DaemonProbeSummary {
    const spec = parseEndpointSpec(raw_endpoint);
    if (spec.container_filter != null and res.containers.len == 0) {
        const t_label = try res.transport.formatSummaryAlloc(arena);
        return .{
            .ready = false,
            .transport_label = t_label,
            .total_containers = 0,
            .running_containers = 0,
            .summary_text = try std.fmt.allocPrint(arena, "{s}::{s} · not found", .{ t_label, spec.container_filter.? }),
        };
    }

    var running_count: usize = 0;
    for (res.containers) |c| {
        if (c.running) running_count += 1;
    }

    const t_label = try res.transport.formatSummaryAlloc(arena);
    const summary = if (spec.container_filter) |cf| blk: {
        const st = if (res.containers.len > 0) res.containers[0].state else "unknown";
        break :blk try std.fmt.allocPrint(arena, "{s}::{s} ({s})", .{ t_label, cf, st });
    } else try std.fmt.allocPrint(
        arena,
        "{s} · {d} containers ({d} running)",
        .{ t_label, res.containers.len, running_count },
    );

    return .{
        .ready = true,
        .transport_label = t_label,
        .total_containers = res.containers.len,
        .running_containers = running_count,
        .summary_text = summary,
    };
}

pub fn probeDockerSourceSummaryAlloc(
    arena: std.mem.Allocator,
    io: std.Io,
    env: DockerEnv,
    raw_endpoint: []const u8,
) !DaemonProbeSummary {
    const res = listContainersAlloc(arena, io, env, raw_endpoint) catch {
        return unavailableProbeSummaryAlloc(arena, raw_endpoint);
    };
    return summarizeListedDockerAlloc(arena, res, raw_endpoint);
}

/// Detects and returns the byte length of a leading Docker `timestamps=1` RFC3339Nano prefix
/// (`YYYY-MM-DDTHH:MM:SS[.nanos](Z|±HH:MM) `) so continuation frames (>16 KiB lines) can strip
/// the duplicate timestamp injected by Docker's multiplexed log framer.
pub fn leadingDockerTimestampLen(buf: []const u8) usize {
    // Minimum: `2026-11-14T04:10:32Z ` = 21 bytes
    if (buf.len < 21) return 0;
    if (!(std.ascii.isDigit(buf[0]) and std.ascii.isDigit(buf[1]) and std.ascii.isDigit(buf[2]) and std.ascii.isDigit(buf[3]))) return 0;
    if (buf[4] != '-' or buf[7] != '-') return 0;
    if (!std.ascii.isDigit(buf[5]) or !std.ascii.isDigit(buf[6]) or !std.ascii.isDigit(buf[8]) or !std.ascii.isDigit(buf[9])) return 0;
    if (buf[10] != 'T' and buf[10] != 't' and buf[10] != ' ') return 0;
    if (!std.ascii.isDigit(buf[11]) or !std.ascii.isDigit(buf[12]) or buf[13] != ':') return 0;
    if (!std.ascii.isDigit(buf[14]) or !std.ascii.isDigit(buf[15]) or buf[16] != ':') return 0;
    if (!std.ascii.isDigit(buf[17]) or !std.ascii.isDigit(buf[18])) return 0;

    var pos: usize = 19;
    if (pos < buf.len and buf[pos] == '.') {
        pos += 1;
        const frac_start = pos;
        while (pos < buf.len and pos - frac_start < 12 and std.ascii.isDigit(buf[pos])) : (pos += 1) {}
        if (pos == frac_start) return 0;
    }

    if (pos >= buf.len) return 0;
    if (buf[pos] == 'Z' or buf[pos] == 'z') {
        pos += 1;
    } else if (buf[pos] == '+' or buf[pos] == '-') {
        if (pos + 6 > buf.len) return 0;
        if (!std.ascii.isDigit(buf[pos + 1]) or !std.ascii.isDigit(buf[pos + 2]) or buf[pos + 3] != ':' or
            !std.ascii.isDigit(buf[pos + 4]) or !std.ascii.isDigit(buf[pos + 5]))
        {
            return 0;
        }
        pos += 6;
    } else {
        return 0;
    }

    if (pos < buf.len and buf[pos] == ' ') {
        return pos + 1;
    }
    return 0;
}

/// Appends one `json-file` log record (`{"log":"...","stream":"...","time":"..."}`) into
/// the appropriate per-stream partial-line accumulator and flushes complete `\n`-terminated lines
/// into `ready_buf` with zero heap churn on steady-state lines.
const JsonLogEnvelopeDto = struct {
    log: ?[]const u8 = null,
    stream: ?[]const u8 = null,
    time: ?[]const u8 = null,
};

const FastJsonEnvelope = struct {
    log: []const u8,
    stream: []const u8,
    time: []const u8,
};

const FastJsonStringToken = struct {
    slice: []const u8,
    next_pos: usize,
};

inline fn skipJsonWhitespace(s: []const u8, start: usize) usize {
    var pos = start;
    while (pos < s.len) : (pos += 1) {
        switch (s[pos]) {
            ' ', '\t', '\r', '\n' => {},
            else => break,
        }
    }
    return pos;
}

fn scanPlainAsciiJsonString(s: []const u8, quote_pos: usize) ?FastJsonStringToken {
    if (quote_pos >= s.len or s[quote_pos] != '"') return null;
    var i = quote_pos + 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"') {
            return .{ .slice = s[quote_pos + 1 .. i], .next_pos = i + 1 };
        }
        if (c == '\\' or c < 0x20 or c >= 0x80) return null;
    }
    return null;
}

fn decodeFastLogJsonString(
    gpa: std.mem.Allocator,
    s: []const u8,
    quote_pos: usize,
    decode_scratch: *std.ArrayList(u8),
) !?FastJsonStringToken {
    if (quote_pos >= s.len or s[quote_pos] != '"') return null;

    var i = quote_pos + 1;
    var has_non_ascii = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"') {
            const raw = s[quote_pos + 1 .. i];
            if (has_non_ascii and !std.unicode.utf8ValidateSlice(raw)) return null;
            return .{ .slice = raw, .next_pos = i + 1 };
        }
        if (c < 0x20) return null;
        if (c >= 0x80) has_non_ascii = true;
        if (c == '\\') break;
    }
    if (i >= s.len) return null;

    decode_scratch.clearRetainingCapacity();
    try decode_scratch.appendSlice(gpa, s[quote_pos + 1 .. i]);

    while (i < s.len) {
        const seg_start = i;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '"' or c == '\\') break;
            if (c < 0x20) return null;
            if (c >= 0x80) has_non_ascii = true;
        }
        if (i > seg_start) {
            try decode_scratch.appendSlice(gpa, s[seg_start..i]);
        }
        if (i >= s.len) return null;
        if (s[i] == '"') {
            if (has_non_ascii and !std.unicode.utf8ValidateSlice(decode_scratch.items)) return null;
            return .{ .slice = decode_scratch.items, .next_pos = i + 1 };
        }

        // Handle escape sequence starting at `s[i] == '\\'`
        i += 1;
        if (i >= s.len) return null;
        switch (s[i]) {
            '"', '\\', '/' => try decode_scratch.append(gpa, s[i]),
            'b' => try decode_scratch.append(gpa, 0x08),
            'f' => try decode_scratch.append(gpa, 0x0c),
            'n' => try decode_scratch.append(gpa, '\n'),
            'r' => try decode_scratch.append(gpa, '\r'),
            't' => try decode_scratch.append(gpa, '\t'),
            'u' => {
                if (i + 4 >= s.len) return null;
                const cp = std.fmt.parseInt(u21, s[i + 1 .. i + 5], 16) catch return null;
                // Surrogate pairs fall back cleanly to std.json
                if (cp >= 0xD800 and cp <= 0xDFFF) return null;
                var u8buf: [4]u8 = undefined;
                const ulen = std.unicode.utf8Encode(cp, &u8buf) catch return null;
                try decode_scratch.appendSlice(gpa, u8buf[0..ulen]);
                i += 4;
            },
            else => return null,
        }
        i += 1;
    }
    return null;
}

fn tryParseFastDockerJsonEnvelope(
    gpa: std.mem.Allocator,
    trimmed: []const u8,
    decode_scratch: *std.ArrayList(u8),
) !?FastJsonEnvelope {
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return null;

    var pos = skipJsonWhitespace(trimmed, 1);
    if (pos >= trimmed.len or trimmed[pos] == '}') return null;

    var log_slice: ?[]const u8 = null;
    var stream_slice: ?[]const u8 = null;
    var time_slice: ?[]const u8 = null;

    while (pos < trimmed.len) {
        const key_tok = scanPlainAsciiJsonString(trimmed, pos) orelse return null;
        pos = skipJsonWhitespace(trimmed, key_tok.next_pos);
        if (pos >= trimmed.len or trimmed[pos] != ':') return null;
        pos = skipJsonWhitespace(trimmed, pos + 1);
        if (pos >= trimmed.len or trimmed[pos] != '"') return null;

        if (std.mem.eql(u8, key_tok.slice, "log")) {
            if (log_slice != null) return null;
            const val_tok = (try decodeFastLogJsonString(gpa, trimmed, pos, decode_scratch)) orelse return null;
            log_slice = val_tok.slice;
            pos = val_tok.next_pos;
        } else if (std.mem.eql(u8, key_tok.slice, "stream")) {
            if (stream_slice != null) return null;
            const val_tok = scanPlainAsciiJsonString(trimmed, pos) orelse return null;
            stream_slice = val_tok.slice;
            pos = val_tok.next_pos;
        } else if (std.mem.eql(u8, key_tok.slice, "time")) {
            if (time_slice != null) return null;
            const val_tok = scanPlainAsciiJsonString(trimmed, pos) orelse return null;
            time_slice = val_tok.slice;
            pos = val_tok.next_pos;
        } else {
            return null;
        }

        pos = skipJsonWhitespace(trimmed, pos);
        if (pos >= trimmed.len) return null;
        if (trimmed[pos] == ',') {
            pos = skipJsonWhitespace(trimmed, pos + 1);
            continue;
        }
        if (trimmed[pos] == '}') {
            pos = skipJsonWhitespace(trimmed, pos + 1);
            if (pos != trimmed.len) return null;
            break;
        }
        return null;
    }

    return .{
        .log = log_slice orelse return null,
        .stream = stream_slice orelse "stdout",
        .time = time_slice orelse "",
    };
}

pub fn processJsonLogEnvelopeLine(
    gpa: std.mem.Allocator,
    raw_line: []const u8,
    stdout_partial: *std.ArrayList(u8),
    stderr_partial: *std.ArrayList(u8),
    ready_buf: *std.ArrayList(u8),
    decode_scratch: *std.ArrayList(u8),
    scratch_arena: *std.heap.ArenaAllocator,
    max_line_cap: usize,
) !void {
    const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{') return;

    var log_text: []const u8 = undefined;
    var time_text: []const u8 = undefined;
    var stream_text: []const u8 = undefined;

    if (try tryParseFastDockerJsonEnvelope(gpa, trimmed, decode_scratch)) |fast_env| {
        log_text = fast_env.log;
        time_text = fast_env.time;
        stream_text = fast_env.stream;
    } else {
        _ = scratch_arena.reset(.retain_capacity);
        const arena = scratch_arena.allocator();

        const parsed = std.json.parseFromSlice(JsonLogEnvelopeDto, arena, trimmed, .{
            .ignore_unknown_fields = true,
        }) catch return;

        log_text = parsed.value.log orelse return;
        time_text = parsed.value.time orelse "";
        stream_text = parsed.value.stream orelse "stdout";
    }

    const acc = if (std.ascii.eqlIgnoreCase(stream_text, "stderr")) stderr_partial else stdout_partial;
    const is_continuation = (acc.items.len > 0);

    if (!is_continuation and time_text.len > 0) {
        if (std.mem.indexOfScalar(u8, log_text, '\n')) |nl_idx| {
            if (nl_idx + 1 == log_text.len) {
                // Fast path: single complete line with trailing `\n` -> emit directly to `ready_buf`
                try ready_buf.ensureUnusedCapacity(gpa, time_text.len + 1 + log_text.len);
                ready_buf.appendSliceAssumeCapacity(time_text);
                ready_buf.appendAssumeCapacity(' ');
                ready_buf.appendSliceAssumeCapacity(log_text);
                return;
            }
        }
        try acc.appendSlice(gpa, time_text);
        try acc.append(gpa, ' ');
    }

    if (std.mem.lastIndexOfScalar(u8, log_text, '\n')) |last_nl| {
        try ready_buf.ensureUnusedCapacity(gpa, acc.items.len + last_nl + 1);
        ready_buf.appendSliceAssumeCapacity(acc.items);
        ready_buf.appendSliceAssumeCapacity(log_text[0 .. last_nl + 1]);
        acc.clearRetainingCapacity();

        const rem = log_text[last_nl + 1 ..];
        if (rem.len > 0) {
            if (time_text.len > 0) {
                try acc.appendSlice(gpa, time_text);
                try acc.append(gpa, ' ');
            }
            try acc.appendSlice(gpa, rem);
        }
    } else {
        try acc.appendSlice(gpa, log_text);
        if (acc.items.len >= max_line_cap) {
            try ready_buf.appendSlice(gpa, acc.items);
            try ready_buf.append(gpa, '\n');
            acc.clearRetainingCapacity();
        }
    }
}

const RotatedLogFile = struct {
    name: []const u8,
    rotation_idx: u32, // 0 = active `<id>-json.log` (newest), 1 = `.log.1`, 2 = `.log.2.gz` (older)
    compressed: bool,

    pub fn chronologicalLessThan(_: void, a: RotatedLogFile, b: RotatedLogFile) bool {
        // Older rotations first (`2` -> `1` -> `0`) so line numbers are strictly chronological
        if (a.rotation_idx != b.rotation_idx) return a.rotation_idx > b.rotation_idx;
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

/// Zero-disk-landing streaming `std.Io.Reader` over a Docker container's logs
/// (supports both Docker Engine HTTP multiplexed/raw socket streams and `/var/lib/docker/containers` `json-file` logs).
pub const DockerLogReader = struct {
    pub const Options = struct {
        since_sec: ?u64 = null,
        until_sec: ?u64 = null,
        max_line_len: usize = 8 * 1024 * 1024,
        connect_timeout_ms: u32 = DEFAULT_CONNECT_TIMEOUT_MS,
        head_timeout_ms: u32 = DEFAULT_HEAD_READ_TIMEOUT_MS,
        read_timeout_ms: u32 = DEFAULT_STREAM_READ_TIMEOUT_MS,
        cancel_flag: ?*const std.atomic.Value(bool) = null,
        stop_ctx: ?*const anyopaque = null,
        stop_fn: ?*const fn (*const anyopaque) bool = null,

        pub fn stopCheck(self: Options) StopCheck {
            return .{
                .cancel_flag = self.cancel_flag,
                .stop_ctx = self.stop_ctx,
                .stop_fn = self.stop_fn,
            };
        }
    };

    const Mode = union(enum) {
        http_stream: struct {
            net_stream: std.Io.net.Stream,
            decoder: HttpBodyDecoder,
            stream_format: StreamFormat,
            frame_stream_type: u8 = 1,
            frame_remaining: u32 = 0,
            at_frame_start: bool = false,
            peek_hdr: [8]u8 = undefined,
            peek_hdr_len: usize = 0,
            peek_hdr_pos: usize = 0,
        },
        dir_files: struct {
            container_dir: std.Io.Dir,
            files_arena: std.heap.ArenaAllocator,
            files: []RotatedLogFile = &.{},
            file_idx: usize = 0,
            cur_file: ?std.Io.File = null,
            cur_file_rbuf: [32768]u8 = undefined,
            cur_file_reader: std.Io.File.Reader = undefined,
            cur_decompressed_slice: ?[]u8 = null,
            cur_decompressed_pos: usize = 0,
            raw_line_buf: std.ArrayList(u8) = .empty,
            decode_scratch: std.ArrayList(u8) = .empty,
            json_scratch_arena: std.heap.ArenaAllocator,
        },
    };

    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    interface: std.Io.Reader,
    reader_buf: [65536]u8 = undefined,
    mode: Mode,

    stdout_partial: std.ArrayList(u8) = .empty,
    stderr_partial: std.ArrayList(u8) = .empty,
    ready_buf: std.ArrayList(u8) = .empty,
    ready_pos: usize = 0,
    eof: bool = false,
    had_error: bool = false,
    container_not_found: bool = false,

    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        transport: Transport,
        container_id: []const u8,
        opts: Options,
    ) !*DockerLogReader {
        if (!isSafeContainerId(container_id)) return error.InvalidDockerEndpoint;
        const stop_check = opts.stopCheck();
        if (stop_check.shouldStop()) return error.Canceled;

        const self = try gpa.create(DockerLogReader);
        errdefer gpa.destroy(self);

        switch (transport) {
            .unix_socket, .tcp => {
                const net_stream = try connectTransportStreamWithTimeout(io, transport, opts.connect_timeout_ms);
                errdefer net_stream.close(io);

                const host_hdr = switch (transport) {
                    .tcp => |t| t.host,
                    else => "localhost",
                };

                var uri_buf: [512]u8 = undefined;
                var uri_len: usize = 0;
                {
                    const base = try std.fmt.bufPrint(
                        uri_buf[uri_len..],
                        "/containers/{s}/logs?stdout=1&stderr=1&timestamps=1",
                        .{container_id},
                    );
                    uri_len += base.len;
                }
                if (opts.since_sec) |s_sec| {
                    const part = try std.fmt.bufPrint(uri_buf[uri_len..], "&since={d}", .{s_sec});
                    uri_len += part.len;
                }
                if (opts.until_sec) |u_sec| {
                    const part = try std.fmt.bufPrint(uri_buf[uri_len..], "&until={d}", .{u_sec});
                    uri_len += part.len;
                }
                const target_uri = uri_buf[0..uri_len];

                var head_buf: [16384]u8 = undefined;
                const head = try sendHttpGetAndReadHead(
                    io,
                    net_stream,
                    target_uri,
                    host_hdr,
                    &head_buf,
                    opts.head_timeout_ms,
                    stop_check,
                );
                if (head.status_code == 404) return error.ContainerNotFound;
                if (head.status_code == 501) return error.LogsUnsupportedByDriver;
                if (head.status_code < 200 or head.status_code >= 300) return error.HttpStatusError;

                self.* = .{
                    .gpa = gpa,
                    .io = io,
                    .opts = opts,
                    .interface = undefined,
                    .mode = .{
                        .http_stream = .{
                            .net_stream = net_stream,
                            .decoder = .{ .io = io, .net_stream = net_stream },
                            .stream_format = head.stream_format,
                        },
                    },
                };
                self.mode.http_stream.decoder.initInPlace(io, net_stream, head, opts.read_timeout_ms, stop_check);
            },
            .containers_dir => |dir_path| {
                var root_dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return error.DockerUnavailable;
                defer root_dir.close(io);

                var cdir = root_dir.openDir(io, container_id, .{ .iterate = true }) catch return error.ContainerNotFound;
                errdefer cdir.close(io);

                var files_arena = std.heap.ArenaAllocator.init(gpa);
                errdefer files_arena.deinit();
                const fa = files_arena.allocator();

                const prefix = try std.fmt.allocPrint(fa, "{s}-json.log", .{container_id});
                var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
                var lister = libwebgrep.walk_list.Lister.init(cdir, &scratch);
                var batch: [64]std.Io.Dir.Entry = undefined;
                var rot_list: std.ArrayList(RotatedLogFile) = .empty;

                while (true) {
                    const count = lister.fill(io, &batch) catch break;
                    if (count == 0) break;
                    for (batch[0..count]) |ent| {
                        if (!std.mem.startsWith(u8, ent.name, prefix)) continue;
                        const suffix = ent.name[prefix.len..];
                        var rot_idx: u32 = 0;
                        var is_comp = false;
                        if (suffix.len == 0) {
                            rot_idx = 0;
                        } else if (suffix[0] == '.') {
                            var num_part = suffix[1..];
                            if (std.mem.endsWith(u8, num_part, ".gz")) {
                                is_comp = true;
                                num_part = num_part[0 .. num_part.len - 3];
                            } else if (std.mem.endsWith(u8, num_part, ".zst") or std.mem.endsWith(u8, num_part, ".xz")) {
                                is_comp = true;
                                const dot = std.mem.lastIndexOfScalar(u8, num_part, '.') orelse continue;
                                num_part = num_part[0..dot];
                            }
                            rot_idx = std.fmt.parseInt(u32, num_part, 10) catch continue;
                        } else continue;

                        try rot_list.append(fa, .{
                            .name = try fa.dupe(u8, ent.name),
                            .rotation_idx = rot_idx,
                            .compressed = is_comp,
                        });
                    }
                }
                std.mem.sort(RotatedLogFile, rot_list.items, {}, RotatedLogFile.chronologicalLessThan);

                self.* = .{
                    .gpa = gpa,
                    .io = io,
                    .opts = opts,
                    .interface = undefined,
                    .mode = .{
                        .dir_files = .{
                            .container_dir = cdir,
                            .files_arena = files_arena,
                            .files = rot_list.items,
                            .json_scratch_arena = std.heap.ArenaAllocator.init(gpa),
                        },
                    },
                };
            },
        }

        self.interface = .{
            .vtable = &.{
                .stream = streamImpl,
            },
            .buffer = &self.reader_buf,
            .seek = 0,
            .end = 0,
        };
        return self;
    }

    pub fn destroy(self: *DockerLogReader) void {
        switch (self.mode) {
            .http_stream => |*hs| {
                hs.net_stream.close(self.io);
            },
            .dir_files => |*df| {
                if (df.cur_file) |*f| f.close(self.io);
                if (df.cur_decompressed_slice) |s| self.gpa.free(s);
                df.raw_line_buf.deinit(self.gpa);
                df.decode_scratch.deinit(self.gpa);
                df.json_scratch_arena.deinit();
                df.files_arena.deinit();
                df.container_dir.close(self.io);
            },
        }
        self.stdout_partial.deinit(self.gpa);
        self.stderr_partial.deinit(self.gpa);
        self.ready_buf.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn flushRemainingPartialsAtEof(self: *DockerLogReader) !void {
        if (self.stdout_partial.items.len > 0) {
            try self.ready_buf.appendSlice(self.gpa, self.stdout_partial.items);
            if (self.stdout_partial.items[self.stdout_partial.items.len - 1] != '\n') {
                try self.ready_buf.append(self.gpa, '\n');
            }
            self.stdout_partial.clearRetainingCapacity();
        }
        if (self.stderr_partial.items.len > 0) {
            try self.ready_buf.appendSlice(self.gpa, self.stderr_partial.items);
            if (self.stderr_partial.items[self.stderr_partial.items.len - 1] != '\n') {
                try self.ready_buf.append(self.gpa, '\n');
            }
            self.stderr_partial.clearRetainingCapacity();
        }
    }

    fn fillFromHttpStream(self: *DockerLogReader) !void {
        const stop_check = self.opts.stopCheck();
        if (stop_check.shouldStop()) return error.Canceled;

        const hs = &self.mode.http_stream;

        if (hs.stream_format == .auto_detect) {
            hs.peek_hdr_len = try hs.decoder.readBodyExact(&hs.peek_hdr);
            hs.peek_hdr_pos = 0;
            if (hs.peek_hdr_len == 0) {
                try self.flushRemainingPartialsAtEof();
                return error.EndOfStream;
            }
            if (hs.peek_hdr_len == 8 and
                hs.peek_hdr[0] <= 2 and
                hs.peek_hdr[1] == 0 and
                hs.peek_hdr[2] == 0 and
                hs.peek_hdr[3] == 0)
            {
                hs.stream_format = .multiplexed;
                hs.frame_stream_type = hs.peek_hdr[0];
                hs.frame_remaining = std.mem.readInt(u32, hs.peek_hdr[4..8], .big);
                hs.at_frame_start = true;
                hs.peek_hdr_len = 0;
            } else {
                hs.stream_format = .raw;
            }
        }

        if (hs.stream_format == .raw) {
            if (hs.peek_hdr_pos < hs.peek_hdr_len) {
                try self.ready_buf.appendSlice(self.gpa, hs.peek_hdr[hs.peek_hdr_pos..hs.peek_hdr_len]);
                hs.peek_hdr_pos = hs.peek_hdr_len;
                return;
            }
            var raw_tmp: [32768]u8 = undefined;
            const n = try hs.decoder.readBodySome(&raw_tmp);
            if (n == 0) return error.EndOfStream;
            try self.ready_buf.appendSlice(self.gpa, raw_tmp[0..n]);
            return;
        }

        // Multiplexed 8-byte Docker stream (`[stream_type, 0, 0, 0, len_be_u32]`)
        var frame_chunk: [32768]u8 = undefined;
        while (self.ready_buf.items.len == 0) {
            if (stop_check.shouldStop()) return error.Canceled;

            while (hs.frame_remaining == 0) {
                var hdr8: [8]u8 = undefined;
                const hn = try hs.decoder.readBodyExact(&hdr8);
                if (hn == 0) {
                    try self.flushRemainingPartialsAtEof();
                    if (self.ready_buf.items.len > 0) return;
                    return error.EndOfStream;
                }
                if (hn < 8) return error.CorruptDockerFrame;
                const sz = std.mem.readInt(u32, hdr8[4..8], .big);
                if (sz > 64 * 1024 * 1024) return error.CorruptDockerFrame;
                hs.frame_stream_type = hdr8[0];
                hs.frame_remaining = sz;
                hs.at_frame_start = true;
            }

            const acc = if (hs.frame_stream_type == 2) &self.stderr_partial else &self.stdout_partial;
            const is_continuation = hs.at_frame_start and (acc.items.len > 0);

            var read_n: usize = 0;
            if (is_continuation) {
                // Gather up to 48 bytes contiguously at continuation frame start so RFC3339Nano prefix
                // is never split across TCP packets or HTTP chunk boundaries.
                const prefix_probe: usize = @intCast(@min(hs.frame_remaining, @as(u32, 48)));
                read_n = try hs.decoder.readBodyExact(frame_chunk[0..prefix_probe]);
                if (read_n == 0) return error.CorruptDockerFrame;
            } else {
                const max_want: usize = @intCast(@min(hs.frame_remaining, @as(u32, @intCast(frame_chunk.len))));
                read_n = try hs.decoder.readBodySome(frame_chunk[0..max_want]);
                if (read_n == 0) return error.CorruptDockerFrame;
            }

            hs.frame_remaining -= @intCast(read_n);
            hs.at_frame_start = false;

            var payload: []const u8 = frame_chunk[0..read_n];
            if (is_continuation) {
                const ts_len = leadingDockerTimestampLen(payload);
                if (ts_len > 0 and ts_len <= payload.len) {
                    payload = payload[ts_len..];
                }
            }
            if (payload.len == 0) continue;

            if (acc.items.len == 0 and payload[payload.len - 1] == '\n') {
                try self.ready_buf.appendSlice(self.gpa, payload);
                return;
            }

            if (std.mem.lastIndexOfScalar(u8, payload, '\n')) |last_nl| {
                try self.ready_buf.ensureUnusedCapacity(self.gpa, acc.items.len + last_nl + 1);
                self.ready_buf.appendSliceAssumeCapacity(acc.items);
                self.ready_buf.appendSliceAssumeCapacity(payload[0 .. last_nl + 1]);
                acc.clearRetainingCapacity();

                const tail = payload[last_nl + 1 ..];
                if (tail.len > 0) {
                    try acc.appendSlice(self.gpa, tail);
                }
                return;
            }

            try acc.appendSlice(self.gpa, payload);
            if (acc.items.len >= self.opts.max_line_len) {
                try self.ready_buf.appendSlice(self.gpa, acc.items);
                try self.ready_buf.append(self.gpa, '\n');
                acc.clearRetainingCapacity();
                return;
            }
        }
    }

    fn fillFromDirFiles(self: *DockerLogReader) !void {
        const stop_check = self.opts.stopCheck();
        const df = &self.mode.dir_files;
        var chunk_buf: [32768]u8 = undefined;

        while (self.ready_buf.items.len == 0) {
            if (stop_check.shouldStop()) return error.Canceled;

            // Ensure an active log file or decompressed buffer is open
            if (df.cur_file == null and df.cur_decompressed_slice == null) {
                if (df.file_idx >= df.files.len) {
                    if (df.raw_line_buf.items.len > 0) {
                        try processJsonLogEnvelopeLine(
                            self.gpa,
                            df.raw_line_buf.items,
                            &self.stdout_partial,
                            &self.stderr_partial,
                            &self.ready_buf,
                            &df.decode_scratch,
                            &df.json_scratch_arena,
                            self.opts.max_line_len,
                        );
                        df.raw_line_buf.clearRetainingCapacity();
                    }
                    try self.flushRemainingPartialsAtEof();
                    if (self.ready_buf.items.len > 0) return;
                    return error.EndOfStream;
                }

                const target = df.files[df.file_idx];
                df.file_idx += 1;

                if (self.opts.since_sec) |s_sec| {
                    if (target.rotation_idx > 0 and s_sec > 0) {
                        const cutoff_ns: i128 = @as(i128, @intCast(s_sec -| 1)) * std.time.ns_per_s;
                        if (df.container_dir.statFile(self.io, target.name, .{})) |st| {
                            if (st.mtime.nanoseconds > 0 and @as(i128, st.mtime.nanoseconds) < cutoff_ns) {
                                continue;
                            }
                        } else |_| {}
                    }
                }

                var f = df.container_dir.openFile(self.io, target.name, .{ .allow_directory = false }) catch continue;
                if (target.compressed) {
                    defer f.close(self.io);
                    var comp_rbuf: [32768]u8 = undefined;
                    var comp_reader = f.reader(self.io, &comp_rbuf);
                    const comp_bytes = comp_reader.interface.allocRemaining(self.gpa, .limited(128 * 1024 * 1024)) catch continue;
                    defer self.gpa.free(comp_bytes);
                    const fmt = file_api.detectCompression(target.name) orelse .auto;
                    var decompressed_out: u64 = 0;
                    var offset_map: libwebgrep.decompress.OffsetMap = .{};
                    defer offset_map.deinit(self.gpa);
                    const dec_opt = libwebgrep.decompress.decompressSlice(
                        self.gpa,
                        comp_bytes,
                        fmt,
                        0,
                        256 * 1024 * 1024,
                        1000,
                        &decompressed_out,
                        &offset_map,
                    ) catch continue;
                    if (dec_opt) |dec_bytes| {
                        df.cur_decompressed_slice = dec_bytes;
                        df.cur_decompressed_pos = 0;
                    } else {
                        df.cur_decompressed_slice = try self.gpa.dupe(u8, comp_bytes);
                        df.cur_decompressed_pos = 0;
                    }
                } else {
                    df.cur_file = f;
                    df.cur_file_reader = df.cur_file.?.reader(self.io, &df.cur_file_rbuf);
                }
            }

            var raw_slice: []const u8 = &.{};
            if (df.cur_decompressed_slice) |dec_s| {
                if (df.cur_decompressed_pos >= dec_s.len) {
                    self.gpa.free(dec_s);
                    df.cur_decompressed_slice = null;
                    df.cur_decompressed_pos = 0;
                    if (df.raw_line_buf.items.len > 0) {
                        try processJsonLogEnvelopeLine(
                            self.gpa,
                            df.raw_line_buf.items,
                            &self.stdout_partial,
                            &self.stderr_partial,
                            &self.ready_buf,
                            &df.decode_scratch,
                            &df.json_scratch_arena,
                            self.opts.max_line_len,
                        );
                        df.raw_line_buf.clearRetainingCapacity();
                    }
                    continue;
                }
                const end = @min(dec_s.len, df.cur_decompressed_pos + chunk_buf.len);
                raw_slice = dec_s[df.cur_decompressed_pos..end];
                df.cur_decompressed_pos = end;
            } else if (df.cur_file != null) {
                const n = readReaderSome(&df.cur_file_reader.interface, &chunk_buf) catch 0;
                if (n == 0) {
                    df.cur_file.?.close(self.io);
                    df.cur_file = null;
                    if (df.raw_line_buf.items.len > 0) {
                        try processJsonLogEnvelopeLine(
                            self.gpa,
                            df.raw_line_buf.items,
                            &self.stdout_partial,
                            &self.stderr_partial,
                            &self.ready_buf,
                            &df.decode_scratch,
                            &df.json_scratch_arena,
                            self.opts.max_line_len,
                        );
                        df.raw_line_buf.clearRetainingCapacity();
                    }
                    continue;
                }
                raw_slice = chunk_buf[0..n];
            }

            var pos: usize = 0;
            while (pos < raw_slice.len) {
                if (std.mem.indexOfScalarPos(u8, raw_slice, pos, '\n')) |nl| {
                    const seg = raw_slice[pos..nl];
                    if (df.raw_line_buf.items.len > 0) {
                        try df.raw_line_buf.appendSlice(self.gpa, seg);
                        try processJsonLogEnvelopeLine(
                            self.gpa,
                            df.raw_line_buf.items,
                            &self.stdout_partial,
                            &self.stderr_partial,
                            &self.ready_buf,
                            &df.decode_scratch,
                            &df.json_scratch_arena,
                            self.opts.max_line_len,
                        );
                        df.raw_line_buf.clearRetainingCapacity();
                    } else {
                        try processJsonLogEnvelopeLine(
                            self.gpa,
                            seg,
                            &self.stdout_partial,
                            &self.stderr_partial,
                            &self.ready_buf,
                            &df.decode_scratch,
                            &df.json_scratch_arena,
                            self.opts.max_line_len,
                        );
                    }
                    pos = nl + 1;
                } else {
                    const tail = raw_slice[pos..];
                    if (df.raw_line_buf.items.len + tail.len <= self.opts.max_line_len * 2) {
                        try df.raw_line_buf.appendSlice(self.gpa, tail);
                    }
                    break;
                }
            }
        }
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *DockerLogReader = @alignCast(@fieldParentPtr("interface", io_r));
        if (self.opts.stopCheck().shouldStop()) {
            self.eof = true;
            return error.EndOfStream;
        }

        while (self.ready_pos >= self.ready_buf.items.len) {
            self.ready_buf.clearRetainingCapacity();
            self.ready_pos = 0;
            if (self.eof) return error.EndOfStream;

            const fill_res = switch (self.mode) {
                .http_stream => self.fillFromHttpStream(),
                .dir_files => self.fillFromDirFiles(),
            };
            fill_res catch |err| switch (err) {
                error.EndOfStream, error.Canceled => {
                    self.eof = true;
                    if (err == error.EndOfStream and self.ready_buf.items.len > 0) break;
                    return error.EndOfStream;
                },
                else => {
                    self.had_error = true;
                    return error.ReadFailed;
                },
            };
        }

        const avail = self.ready_buf.items[self.ready_pos..];
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        const n = @min(avail.len, dest.len);
        @memcpy(dest[0..n], avail[0..n]);
        self.ready_pos += n;
        io_w.advance(n);
        return n;
    }
};

/// Builds a `FileResponse` JSON line preview (`/api/file` / `/api/context`) for an already
/// resolved Docker transport + container ID without writing any temporary files to disk.
pub fn buildContainerLinePreviewForResolvedJson(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    transport: Transport,
    cid: []const u8,
    display_vpath: []const u8,
    target_line_raw: u64,
    context_raw: u64,
    since_sec: ?u64,
) ![]u8 {
    var log_reader = DockerLogReader.create(gpa, io, transport, cid, .{
        .since_sec = since_sec,
    }) catch {
        return error.FileNotFound;
    };
    defer log_reader.destroy();

    const target_line = if (target_line_raw == 0) 1 else target_line_raw;
    const context = @min(context_raw, 500);
    const win_start = if (target_line > context) target_line - context else 1;
    const win_end = target_line +| context;
    const max_preview_line_bytes: usize = 512 * 1024;

    var lines_out: std.ArrayList(file_api.FileLine) = .empty;
    var cur_line_buf: std.ArrayList(u8) = .empty;
    defer cur_line_buf.deinit(gpa);

    var line_no: u64 = 0;
    var eof_reached = true;
    var has_unterminated_tail = false;
    var rchunk: [32768]u8 = undefined;

    read_loop: while (true) {
        const n = readReaderSome(&log_reader.interface, &rchunk) catch break;
        if (n == 0) break;

        var pos: usize = 0;
        while (pos < n) {
            if (std.mem.indexOfScalarPos(u8, rchunk[0..n], pos, '\n')) |nl| {
                line_no += 1;
                has_unterminated_tail = false;
                if (line_no >= win_start and line_no <= win_end) {
                    const seg = rchunk[pos..nl];
                    const full_raw = if (cur_line_buf.items.len > 0) blk: {
                        const remain = max_preview_line_bytes -| cur_line_buf.items.len;
                        if (remain > 0) {
                            try cur_line_buf.appendSlice(gpa, seg[0..@min(seg.len, remain)]);
                        }
                        break :blk cur_line_buf.items;
                    } else seg[0..@min(seg.len, max_preview_line_bytes)];

                    const trimmed_cr = if (full_raw.len > 0 and full_raw[full_raw.len - 1] == '\r')
                        full_raw[0 .. full_raw.len - 1]
                    else
                        full_raw;
                    const safe_text = try file_api.sanitizeUtf8Truncated(arena, trimmed_cr, max_preview_line_bytes);
                    const owned_text = if (safe_text.ptr == trimmed_cr.ptr)
                        try arena.dupe(u8, safe_text)
                    else
                        safe_text;

                    try lines_out.append(arena, .{
                        .n = line_no,
                        .text = owned_text,
                    });
                }
                cur_line_buf.clearRetainingCapacity();
                pos = nl + 1;

                // Stop streaming once we pass the requested preview window by >= 1000 lines on huge streams
                // (applies to both `/api/file?context=0` and `/api/context?context=N`).
                if (line_no >= win_end +| 1000) {
                    eof_reached = false;
                    has_unterminated_tail = false;
                    break :read_loop;
                }
            } else {
                has_unterminated_tail = true;
                if (line_no + 1 >= win_start and line_no + 1 <= win_end) {
                    const tail = rchunk[pos..n];
                    const remain = max_preview_line_bytes -| cur_line_buf.items.len;
                    if (remain > 0) {
                        try cur_line_buf.appendSlice(gpa, tail[0..@min(tail.len, remain)]);
                    }
                }
                break;
            }
        }
    }

    if (eof_reached and has_unterminated_tail) {
        line_no += 1;
        if (line_no >= win_start and line_no <= win_end) {
            const trimmed_cr = std.mem.trimEnd(u8, cur_line_buf.items, "\r");
            const safe_text = try file_api.sanitizeUtf8Truncated(arena, trimmed_cr, max_preview_line_bytes);
            const owned_text = if (safe_text.ptr == trimmed_cr.ptr)
                try arena.dupe(u8, safe_text)
            else
                safe_text;
            try lines_out.append(arena, .{
                .n = line_no,
                .text = owned_text,
            });
        }
    }

    const actual_start: u64 = if (lines_out.items.len > 0) lines_out.items[0].n else 1;
    return file_api.stringifyAlloc(arena, file_api.FileResponse{
        .path = display_vpath,
        .startLine = actual_start,
        .totalLines = line_no,
        .binary = false,
        .eof = eof_reached or (win_end >= line_no),
        .lines = lines_out.items,
    });
}

/// Builds a `FileResponse` JSON line preview (`/api/file` / `/api/context`) for a Docker container
/// directly from its in-memory stream, honoring an optional aligned `since_sec` timestamp boundary.
pub fn buildContainerLinePreviewJsonWithSince(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    env: DockerEnv,
    raw_endpoint: []const u8,
    container_ref: []const u8,
    display_vpath: []const u8,
    target_line_raw: u64,
    context_raw: u64,
    since_sec: ?u64,
) ![]u8 {
    const clean_ref = std.mem.trim(u8, container_ref, " \t/");
    if (clean_ref.len == 0 or std.mem.indexOf(u8, clean_ref, "..") != null) {
        return error.InvalidPath;
    }

    const resolved = resolveTransportAlloc(arena, io, env, raw_endpoint) catch {
        return error.FileNotFound;
    };
    const containers = listContainersForTransportAlloc(arena, io, resolved.transport, resolved.container_filter) catch {
        return error.FileNotFound;
    };

    var target_id: ?[]const u8 = null;
    for (containers) |c| {
        if (containerMatchesTargetFilter(c, clean_ref)) {
            target_id = c.id;
            break;
        }
    }
    const cid = target_id orelse return error.FileNotFound;

    return buildContainerLinePreviewForResolvedJson(
        gpa,
        arena,
        io,
        resolved.transport,
        cid,
        display_vpath,
        target_line_raw,
        context_raw,
        since_sec,
    );
}

/// Builds a `FileResponse` JSON line preview (`/api/file` / `/api/context`) for a Docker container
/// directly from its in-memory stream without writing any temporary files to disk.
pub fn buildContainerLinePreviewJson(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    env: DockerEnv,
    raw_endpoint: []const u8,
    container_ref: []const u8,
    display_vpath: []const u8,
    target_line_raw: u64,
    context_raw: u64,
) ![]u8 {
    return buildContainerLinePreviewJsonWithSince(
        gpa,
        arena,
        io,
        env,
        raw_endpoint,
        container_ref,
        display_vpath,
        target_line_raw,
        context_raw,
        null,
    );
}

// ============================================================================
// Unit & Integration Tests (Mock Unix Socket Daemon + json-file Directory Mode)
// ============================================================================

pub fn appendDockerMuxFrame(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    stream_type: u8,
    payload: []const u8,
) !void {
    var hdr: [8]u8 = .{ stream_type, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, hdr[4..8], @intCast(payload.len), .big);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, payload);
}

pub fn writeChunkedBody(writer: *std.Io.Writer, payload: []const u8, chunk_step: usize) !void {
    var pos: usize = 0;
    while (pos < payload.len) {
        const end = @min(payload.len, pos + chunk_step);
        const slice = payload[pos..end];
        try writer.print("{x}\r\n", .{slice.len});
        try writer.writeAll(slice);
        try writer.writeAll("\r\n");
        pos = end;
    }
    try writer.writeAll("0\r\n\r\n");
}

test "parseEndpointSpec handles auto, unix, tcp, IPv6 brackets, and :: container filters" {
    const s1 = parseEndpointSpec("");
    try std.testing.expect(s1.is_auto);
    try std.testing.expectEqualStrings("auto", s1.base_endpoint);
    try std.testing.expect(s1.container_filter == null);

    const s2 = parseEndpointSpec("auto::my-nginx");
    try std.testing.expect(s2.is_auto);
    try std.testing.expectEqualStrings("my-nginx", s2.container_filter.?);

    const s3 = parseEndpointSpec("unix:///var/run/docker.sock::api-1");
    try std.testing.expect(!s3.is_auto);
    try std.testing.expectEqualStrings("unix:///var/run/docker.sock", s3.base_endpoint);
    try std.testing.expectEqualStrings("api-1", s3.container_filter.?);

    const s4 = parseEndpointSpec("tcp://[::1]:2375");
    try std.testing.expect(!s4.is_auto);
    try std.testing.expectEqualStrings("tcp://[::1]:2375", s4.base_endpoint);
    try std.testing.expect(s4.container_filter == null);

    const s5 = parseEndpointSpec("tcp://[::1]:2375::worker");
    try std.testing.expectEqualStrings("tcp://[::1]:2375", s5.base_endpoint);
    try std.testing.expectEqualStrings("worker", s5.container_filter.?);
}

test "leadingDockerTimestampLen accurately measures RFC3339Nano prefixes" {
    try std.testing.expectEqual(
        @as(usize, 31),
        leadingDockerTimestampLen("2026-11-14T04:10:32.123456789Z {\"ok\":true}\n"),
    );
    try std.testing.expectEqual(
        @as(usize, 26),
        leadingDockerTimestampLen("2026-11-14T12:10:32+08:00 hello"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        leadingDockerTimestampLen("{\"level\":\"info\",\"msg\":\"no leading ts\"}"),
    );
}

test "Docker Engine Unix Domain Socket multiplexed chunked stream + >16KiB frame reassembly + libwebgrep search" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Short relative path under `.zig-cache/tmp/<sub_path>/d.sock` (well within 108-byte UnixAddress limit)
    const sock_rel_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/d.sock", .{tmp.sub_path});
    const ua = try std.Io.net.UnixAddress.init(sock_rel_path);
    var srv = try ua.listen(io, .{});

    const MockServer = struct {
        server: *std.Io.net.Server,
        io: std.Io,
        stop: std.atomic.Value(bool) = .init(false),

        fn run(ctx: *@This()) void {
            const alloc = std.heap.page_allocator;
            while (!ctx.stop.load(.acquire)) {
                const conn = ctx.server.accept(ctx.io) catch break;
                handleConn(alloc, ctx.io, conn) catch {};
            }
        }

        fn handleConn(alloc: std.mem.Allocator, conn_io: std.Io, conn: std.Io.net.Stream) !void {
            defer conn.close(conn_io);
            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var r = conn.reader(conn_io, &rbuf);
            var w = conn.writer(conn_io, &wbuf);

            var req_buf: [2048]u8 = undefined;
            var total: usize = 0;
            while (total < req_buf.len) {
                const n = readReaderSome(&r.interface, req_buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (findHeaderEnd(req_buf[0..total]) != null) break;
            }
            const req_head = req_buf[0..total];
            const line_end = std.mem.indexOfScalar(u8, req_head, '\n') orelse return;
            const first_line = std.mem.trimEnd(u8, req_head[0..line_end], "\r");

            if (std.mem.indexOf(u8, first_line, "GET /_ping ") != null) {
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nOK");
                try w.interface.flush();
                return;
            }

            if (std.mem.indexOf(u8, first_line, "GET /containers/json") != null) {
                const body =
                    \\[
                    \\  {"Id":"1111111111112222222222223333333333334444444444445555555555556666","Names":["/api-gateway"],"Image":"envoy:v1.31","State":"running","Status":"Up 2 hours","Created":1763093400},
                    \\  {"Id":"aaaaaaaabbbbccccddddeeeeffff000011112222333344445555666677778888","Names":["/tty-worker"],"Image":"alpine:3.20","State":"exited","Status":"Exited (1) 5m ago","Created":1763090000}
                    \\]
                ;
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n");
                try writeChunkedBody(&w.interface, body, 37);
                try w.interface.flush();
                return;
            }

            if (std.mem.indexOf(u8, first_line, "/containers/111111111111") != null) {
                var mux: std.ArrayList(u8) = .empty;
                defer mux.deinit(alloc);

                // Frame 1 (stdout): normal JSON log line
                try appendDockerMuxFrame(
                    alloc,
                    &mux,
                    1,
                    "2026-11-14T04:10:01.000000001Z {\"level\":\"info\",\"msg\":\"boot_ok\"}\n",
                );

                // Split >16 KiB single-line JSON across Frame 2 + Frame 4 on stdout,
                // with an interleaved stderr Frame 3 in between!
                var big_part1: std.ArrayList(u8) = .empty;
                defer big_part1.deinit(alloc);
                try big_part1.appendSlice(alloc, "2026-11-14T04:10:02.500000000Z {\"level\":\"error\",\"blob\":\"");
                try big_part1.appendNTimes(alloc, 'A', 16400);
                try appendDockerMuxFrame(alloc, &mux, 1, big_part1.items);

                // Frame 3 (stderr interleaved while stdout line is still partial!)
                try appendDockerMuxFrame(
                    alloc,
                    &mux,
                    2,
                    "2026-11-14T04:10:02.600000000Z [STDERR] upstream connection reset\n",
                );

                // Frame 4 (stdout continuation frame — Docker prepends duplicate RFC3339Nano timestamp!)
                try appendDockerMuxFrame(
                    alloc,
                    &mux,
                    1,
                    "2026-11-14T04:10:02.500000000Z _TAIL_SENTINEL_XYZ\"}\n",
                );

                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\nTransfer-Encoding: chunked\r\n\r\n");
                // Deliberately fragment HTTP chunks at 29-byte prime steps to stress header & timestamp boundaries!
                try writeChunkedBody(&w.interface, mux.items, 29);
                try w.interface.flush();
                return;
            }

            if (std.mem.indexOf(u8, first_line, "/containers/aaaaaaaabbbb") != null) {
                const raw_tty = "2026-11-14T04:05:00.000000000Z panic: tty_crash_marker\r\n";
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\nTransfer-Encoding: chunked\r\n\r\n");
                try writeChunkedBody(&w.interface, raw_tty, 13);
                try w.interface.flush();
                return;
            }

            try w.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            try w.interface.flush();
        }
    };

    var mock = MockServer{ .server = &srv, .io = io };
    const srv_thread = try std.Thread.spawn(.{}, MockServer.run, .{&mock});
    defer {
        mock.stop.store(true, .release);
        if (ua.connect(io)) |wake_conn| {
            wake_conn.close(io);
        } else |_| {}
        srv.deinit(io);
        srv_thread.join();
    }

    const env = DockerEnv{ .docker_host = sock_rel_path };

    // 1. Auto-discovery via `DOCKER_HOST` + container listing
    const listed = try listContainersAlloc(arena, io, env, "auto");
    try std.testing.expectEqual(@as(usize, 2), listed.containers.len);
    try std.testing.expectEqualStrings("api-gateway", listed.containers[0].display_name);
    try std.testing.expect(listed.containers[0].running);
    try std.testing.expectEqualStrings("tty-worker", listed.containers[1].display_name);

    // 2. Stream multiplexed logs directly into `libwebgrep.searchSource` (must NOT trigger binary_quit on 0x00 frame headers!)
    {
        var log_reader = try DockerLogReader.create(gpa, io, listed.transport, listed.containers[0].id, .{});
        defer log_reader.destroy();

        const CollectSink = struct {
            lines: std.ArrayList([]u8) = .empty,
            alloc: std.mem.Allocator,

            pub fn event(self: *@This(), ev: libwebgrep.Event) libwebgrep.Flow {
                switch (ev) {
                    .match => |m| {
                        const txt = if (m.text.len > 0) m.text else m.bytes;
                        const copy = self.alloc.dupe(u8, txt) catch return .stop;
                        self.lines.append(self.alloc, copy) catch return .stop;
                    },
                    else => {},
                }
                return .cont;
            }
        };

        var sink = CollectSink{ .alloc = arena };
        var finder = try libwebgrep.Finder.init("_TAIL_SENTINEL_XYZ", .{});
        const res = try libwebgrep.searchSource(
            CollectSink,
            gpa,
            &sink,
            &log_reader.interface,
            "docker/api-gateway",
            &finder,
            .{
                .line_numbers = true,
                .max_line_len = 8 * 1024 * 1024,
                .max_source_bytes = 64 * 1024 * 1024,
                .max_request_bytes = 64 * 1024 * 1024,
                .max_output_bytes = 64 * 1024 * 1024,
                .time_budget_ns = 30 * std.time.ns_per_s,
            },
        );
        try std.testing.expectEqual(libwebgrep.Outcome.complete, res.outcome);
        try std.testing.expectEqual(@as(usize, 1), sink.lines.items.len);
        const reassembled = sink.lines.items[0];
        // Verify >16 KiB line was reassembled WITHOUT duplicate timestamp in the middle and WITHOUT stderr spliced into it!
        try std.testing.expect(reassembled.len > 16450);
        try std.testing.expect(std.mem.startsWith(u8, reassembled, "2026-11-14T04:10:02.500000000Z {\"level\":\"error\",\"blob\":\"AAAA"));
        try std.testing.expect(std.mem.endsWith(u8, reassembled, "AAAA_TAIL_SENTINEL_XYZ\"}"));
        try std.testing.expect(std.mem.indexOf(u8, reassembled, "STDERR") == null);
    }

    // 3. Verify `Tty: true` raw-stream container search
    {
        var tty_reader = try DockerLogReader.create(gpa, io, listed.transport, listed.containers[1].id, .{});
        defer tty_reader.destroy();

        var rbuf: [512]u8 = undefined;
        const n = try tty_reader.interface.readSliceShort(&rbuf);
        try std.testing.expect(std.mem.indexOf(u8, rbuf[0..n], "tty_crash_marker") != null);
    }

    // 4. Verify `/api/file` zero-disk-landing preview (`buildContainerLinePreviewJson`)
    {
        const preview_json = try buildContainerLinePreviewJson(
            gpa,
            arena,
            io,
            env,
            "auto",
            "api-gateway",
            "docker/api-gateway",
            2,
            0,
        );
        try std.testing.expect(std.mem.indexOf(u8, preview_json, "upstream connection reset") != null);

        // Line 3 is the reassembled >16 KiB JSON line (since stderr flushed at line 2 while stdout was still partial!)
        const preview_big = try buildContainerLinePreviewJson(
            gpa,
            arena,
            io,
            env,
            "auto",
            "api-gateway",
            "docker/api-gateway",
            3,
            0,
        );
        try std.testing.expect(std.mem.indexOf(u8, preview_big, "_TAIL_SENTINEL_XYZ") != null);
    }
}

test "Docker containers directory mode (config.v2.json + rotated *-json.log) reads without disk writes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cid = "deadbeef0000111122223333444455556666777788889999aaaabbbbccccdddd";
    try tmp.dir.createDirPath(io, cid);
    var cdir = try tmp.dir.openDir(io, cid, .{});
    defer cdir.close(io);

    {
        var cf = try cdir.createFile(io, "config.v2.json", .{ .truncate = true });
        defer cf.close(io);
        var wbuf: [512]u8 = undefined;
        var fw = cf.writer(io, &wbuf);
        try fw.interface.writeAll(
            \\{"Name":"/orders-service","Created":"2026-11-14T01:00:00Z","State":{"Running":true},"Config":{"Image":"orders:v2"}}
        );
        try fw.interface.flush();
    }

    // Older rotated log `.log.1`
    {
        const rot_name = try std.fmt.allocPrint(arena, "{s}-json.log.1", .{cid});
        var lf1 = try cdir.createFile(io, rot_name, .{ .truncate = true });
        defer lf1.close(io);
        var wbuf: [512]u8 = undefined;
        var fw = lf1.writer(io, &wbuf);
        try fw.interface.writeAll(
            \\{"log":"rotated_first_entry\n","stream":"stdout","time":"2026-11-14T02:00:00.000000000Z"}
            \\
        );
        try fw.interface.flush();
    }

    // Active newest log `.log` (including a split partial line!)
    {
        const cur_name = try std.fmt.allocPrint(arena, "{s}-json.log", .{cid});
        var lf0 = try cdir.createFile(io, cur_name, .{ .truncate = true });
        defer lf0.close(io);
        var wbuf: [512]u8 = undefined;
        var fw = lf0.writer(io, &wbuf);
        try fw.interface.writeAll(
            \\{"log":"{\"order_id\":99,","stream":"stdout","time":"2026-11-14T03:00:00.123456789Z"}
            \\{"log":"\"status\":\"paid\"}\n","stream":"stdout","time":"2026-11-14T03:00:00.123456789Z"}
            \\
        );
        try fw.interface.flush();
    }

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &real_buf);
    const dir_path = try arena.dupe(u8, real_buf[0..tmp_len]);

    const listed = try listContainersAlloc(arena, io, .{}, dir_path);
    try std.testing.expectEqual(@as(usize, 1), listed.containers.len);
    try std.testing.expectEqualStrings("orders-service", listed.containers[0].display_name);
    try std.testing.expectEqualStrings("orders:v2", listed.containers[0].image);
    try std.testing.expect(listed.containers[0].running);

    var reader = try DockerLogReader.create(gpa, io, listed.transport, cid, .{});
    defer reader.destroy();

    const all_bytes = try reader.interface.allocRemaining(arena, .limited(64 * 1024));
    try std.testing.expectEqualStrings(
        "2026-11-14T02:00:00.000000000Z rotated_first_entry\n" ++
            "2026-11-14T03:00:00.123456789Z {\"order_id\":99,\"status\":\"paid\"}\n",
        all_bytes,
    );
}

test "Live host Docker daemon read-only smoke test (when available)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const listed = listContainersAlloc(arena, io, .{}, "auto") catch |err| switch (err) {
        error.DockerUnavailable => return,
        else => return err,
    };
    try std.testing.expect(listed.summary_endpoint.len > 0);

    const summary = try probeDockerSourceSummaryAlloc(arena, io, .{}, "auto");
    try std.testing.expect(summary.ready);
    try std.testing.expectEqual(listed.containers.len, summary.total_containers);

    if (listed.containers.len > 0) {
        const first = listed.containers[0];
        if (DockerLogReader.create(gpa, io, listed.transport, first.id, .{})) |reader| {
            defer reader.destroy();
            var smoke_buf: [4096]u8 = undefined;
            const n = try readReaderSome(&reader.interface, &smoke_buf);
            // Must never emit raw 0x00 multiplexed frame header bytes into decoded log text
            for (smoke_buf[0..n]) |b| {
                try std.testing.expect(b != 0);
            }
        } else |err| switch (err) {
            // Some enterprise logging drivers (`none`, `splunk`, `awslogs`) return HTTP 501/400 on `/logs`
            error.ContainerNotFound, error.LogsUnsupportedByDriver, error.HttpStatusError => {},
            else => return err,
        }
    }
}

fn buildStoredGzipAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    std.debug.assert(payload.len <= 0xFFFF);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // RFC 1952 10-byte gzip header
    try out.appendSlice(allocator, &.{ 0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03 });
    // RFC 1951 uncompressed stored DEFLATE block (`BFINAL=1, BTYPE=00`)
    try out.append(allocator, 0x01);
    const len16: u16 = @intCast(payload.len);
    const nlen16: u16 = ~len16;
    var block_hdr: [4]u8 = undefined;
    std.mem.writeInt(u16, block_hdr[0..2], len16, .little);
    std.mem.writeInt(u16, block_hdr[2..4], nlen16, .little);
    try out.appendSlice(allocator, &block_hdr);
    try out.appendSlice(allocator, payload);
    // RFC 1952 8-byte trailer (`CRC32` + `ISIZE`)
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u32, trailer[0..4], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, trailer[4..8], @intCast(payload.len), .little);
    try out.appendSlice(allocator, &trailer);
    return out.toOwnedSlice(allocator);
}

test "Multiplexed 8-byte frames with raw-stream or text/plain Content-Type sniffed cleanly without binary_quit" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sock_rel_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/legacy.sock", .{tmp.sub_path});
    const ua = try std.Io.net.UnixAddress.init(sock_rel_path);
    var srv = try ua.listen(io, .{});

    const LegacyServer = struct {
        server: *std.Io.net.Server,
        io: std.Io,
        stop: std.atomic.Value(bool) = .init(false),

        fn run(ctx: *@This()) void {
            const alloc = std.heap.page_allocator;
            while (!ctx.stop.load(.acquire)) {
                const conn = ctx.server.accept(ctx.io) catch break;
                handleConn(alloc, ctx.io, conn) catch {};
            }
        }

        fn handleConn(alloc: std.mem.Allocator, conn_io: std.Io, conn: std.Io.net.Stream) !void {
            defer conn.close(conn_io);
            var rbuf: [2048]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var r = conn.reader(conn_io, &rbuf);
            var w = conn.writer(conn_io, &wbuf);

            var req_buf: [2048]u8 = undefined;
            var total: usize = 0;
            while (total < req_buf.len) {
                const n = readReaderSome(&r.interface, req_buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (findHeaderEnd(req_buf[0..total]) != null) break;
            }
            const req_head = req_buf[0..total];
            const line_end = std.mem.indexOfScalar(u8, req_head, '\n') orelse return;
            const first_line = std.mem.trimEnd(u8, req_head[0..line_end], "\r");

            var mux: std.ArrayList(u8) = .empty;
            defer mux.deinit(alloc);
            try appendDockerMuxFrame(alloc, &mux, 1, "2026-11-14T05:00:01.000000000Z legacy_mux_hit_alpha\n");
            try appendDockerMuxFrame(alloc, &mux, 2, "2026-11-14T05:00:02.000000000Z [STDERR] legacy_mux_hit_beta\n");

            if (std.mem.indexOf(u8, first_line, "/containers/111111111111") != null) {
                // Docker Engine < v23 (API < v1.42) sends `application/vnd.docker.raw-stream` even for multiplexed streams!
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\nTransfer-Encoding: chunked\r\n\r\n");
                try writeChunkedBody(&w.interface, mux.items, 11);
                try w.interface.flush();
                return;
            }
            if (std.mem.indexOf(u8, first_line, "/containers/222222222222") != null) {
                // Reverse-proxied daemon returning `text/plain`
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ");
                try w.interface.print("{d}\r\n\r\n", .{mux.items.len});
                try w.interface.writeAll(mux.items);
                try w.interface.flush();
                return;
            }
        }
    };

    var mock = LegacyServer{ .server = &srv, .io = io };
    const srv_thread = try std.Thread.spawn(.{}, LegacyServer.run, .{&mock});
    defer {
        mock.stop.store(true, .release);
        if (ua.connect(io)) |wake_conn| wake_conn.close(io) else |_| {}
        srv.deinit(io);
        srv_thread.join();
    }

    const tr = Transport{ .unix_socket = sock_rel_path };
    const cids = [_][]const u8{
        "1111111111112222222222223333333333334444444444445555555555556666",
        "2222222222223333333333334444444444445555555555556666777788889999",
    };

    for (cids) |cid| {
        var reader = try DockerLogReader.create(gpa, io, tr, cid, .{});
        defer reader.destroy();

        const Sink = struct {
            hits: usize = 0,
            pub fn event(self: *@This(), ev: libwebgrep.Event) libwebgrep.Flow {
                if (ev == .match) self.hits += 1;
                return .cont;
            }
        };
        var sink = Sink{};
        var finder = try libwebgrep.Finder.init("legacy_mux_hit_", .{});
        const res = try libwebgrep.searchSource(
            Sink,
            gpa,
            &sink,
            &reader.interface,
            "docker/legacy",
            &finder,
            .{
                .line_numbers = true,
                .max_line_len = 8 * 1024 * 1024,
                .max_source_bytes = 16 * 1024 * 1024,
                .max_request_bytes = 16 * 1024 * 1024,
                .max_output_bytes = 16 * 1024 * 1024,
                .time_budget_ns = 10 * std.time.ns_per_s,
            },
        );
        try std.testing.expectEqual(libwebgrep.Outcome.complete, res.outcome);
        try std.testing.expectEqual(@as(usize, 2), sink.hits);
    }
}

test "Compressed .log.2.gz rotated json-file with unterminated final line flushes cleanly before .log.1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cid = "feedface0000111122223333444455556666777788889999aaaabbbbccccdddd";
    try tmp.dir.createDirPath(io, cid);
    var cdir = try tmp.dir.openDir(io, cid, .{});
    defer cdir.close(io);

    {
        var cf = try cdir.createFile(io, "config.v2.json", .{ .truncate = true });
        defer cf.close(io);
        var wbuf: [512]u8 = undefined;
        var fw = cf.writer(io, &wbuf);
        try fw.interface.writeAll(
            \\{"Name":"/billing-worker","Created":"2026-11-14T01:00:00Z","State":{"Running":true},"Config":{"Image":"billing:v1"}}
        );
        try fw.interface.flush();
    }

    // Oldest compressed `.log.2.gz` — intentionally NO trailing `\n` on the second JSON envelope!
    {
        const gz_raw_json =
            "{\"log\":\"gz_oldest_complete\\n\",\"stream\":\"stdout\",\"time\":\"2026-11-14T01:00:00.000000000Z\"}\n" ++
            "{\"log\":\"split_across_rotation_HEAD_\",\"stream\":\"stdout\",\"time\":\"2026-11-14T01:05:00.000000000Z\"}";
        const gz_bytes = try buildStoredGzipAlloc(arena, gz_raw_json);
        const gz_name = try std.fmt.allocPrint(arena, "{s}-json.log.2.gz", .{cid});
        var gf = try cdir.createFile(io, gz_name, .{ .truncate = true });
        defer gf.close(io);
        var wbuf: [512]u8 = undefined;
        var fw = gf.writer(io, &wbuf);
        try fw.interface.writeAll(gz_bytes);
        try fw.interface.flush();
    }

    // Middle `.log.1` finishing the partial container line started in `.log.2.gz`
    {
        const rot1_name = try std.fmt.allocPrint(arena, "{s}-json.log.1", .{cid});
        var lf1 = try cdir.createFile(io, rot1_name, .{ .truncate = true });
        defer lf1.close(io);
        var wbuf: [512]u8 = undefined;
        var fw = lf1.writer(io, &wbuf);
        try fw.interface.writeAll(
            \\{"log":"TAIL_COMPLETE\n","stream":"stdout","time":"2026-11-14T01:05:00.000000000Z"}
            \\
        );
        try fw.interface.flush();
    }

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &real_buf);
    const dir_path = try arena.dupe(u8, real_buf[0..tmp_len]);

    const tr = Transport{ .containers_dir = dir_path };
    var reader = try DockerLogReader.create(gpa, io, tr, cid, .{});
    defer reader.destroy();

    const all_bytes = try reader.interface.allocRemaining(arena, .limited(64 * 1024));
    try std.testing.expectEqualStrings(
        "2026-11-14T01:00:00.000000000Z gz_oldest_complete\n" ++
            "2026-11-14T01:05:00.000000000Z split_across_rotation_HEAD_TAIL_COMPLETE\n",
        all_bytes,
    );
}

test "Stalled TCP daemon times out boundedly and blocked stream read aborts promptly on cancel_flag" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const bind_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var srv = try bind_addr.listen(io, .{ .reuse_address = true });
    const bound_port = srv.socket.address.getPort();

    const StallServer = struct {
        server: *std.Io.net.Server,
        io: std.Io,
        stop: std.atomic.Value(bool) = .init(false),
        mode: std.atomic.Value(u8) = .init(0), // 0 = stall before headers, 1 = send headers + 1 frame then stall

        fn run(ctx: *@This()) void {
            while (!ctx.stop.load(.acquire)) {
                const conn = ctx.server.accept(ctx.io) catch break;
                handle(ctx, conn);
            }
        }

        fn handle(ctx: *@This(), conn: std.Io.net.Stream) void {
            defer conn.close(ctx.io);
            var rbuf: [1024]u8 = undefined;
            var r = conn.reader(ctx.io, &rbuf);
            var tmp: [512]u8 = undefined;
            _ = readReaderSome(&r.interface, &tmp) catch {};

            if (ctx.mode.load(.acquire) == 1) {
                var wbuf: [1024]u8 = undefined;
                var w = conn.writer(ctx.io, &wbuf);
                var mux: [64]u8 = undefined;
                const line = "2026-11-14T06:00:00.000000000Z first_live_line\n";
                mux[0] = 1;
                mux[1] = 0;
                mux[2] = 0;
                mux[3] = 0;
                std.mem.writeInt(u32, mux[4..8], @intCast(line.len), .big);
                @memcpy(mux[8 .. 8 + line.len], line);
                w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\n\r\n") catch return;
                w.interface.writeAll(mux[0 .. 8 + line.len]) catch return;
                w.interface.flush() catch return;
            }
            // Hold the TCP socket open without sending EOF until client disconnects or test stops
            while (!ctx.stop.load(.acquire)) {
                var pfd = [1]std.posix.pollfd{.{
                    .fd = conn.socket.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const ready = std.posix.poll(&pfd, 20) catch break;
                if (ready > 0) {
                    var b: [16]u8 = undefined;
                    var vecs: [1][]u8 = .{&b};
                    const n = conn.read(ctx.io, &vecs) catch break;
                    if (n == 0) break;
                }
            }
        }
    };

    var stall = StallServer{ .server = &srv, .io = io };
    const srv_thread = try std.Thread.spawn(.{}, StallServer.run, .{&stall});
    defer {
        stall.stop.store(true, .release);
        if (std.Io.net.IpAddress.parse("127.0.0.1", bound_port)) |wake_ip| {
            if (wake_ip.connect(io, .{ .mode = .stream })) |c| c.close(io) else |_| {}
        } else |_| {}
        srv.deinit(io);
        srv_thread.join();
    }

    const tr = Transport{ .tcp = .{ .host = "127.0.0.1", .port = bound_port } };
    const cid = "1111111111112222222222223333333333334444444444445555555555556666";

    // Mode 0: accepts TCP connection and never sends HTTP headers -> `head_timeout_ms` bounds it!
    try std.testing.expectError(
        error.Timeout,
        DockerLogReader.create(gpa, io, tr, cid, .{
            .connect_timeout_ms = 500,
            .head_timeout_ms = 120,
            .read_timeout_ms = 120,
        }),
    );

    // Mode 1: sends headers + 1 line, then stalls mid-body -> `cancel_flag` aborts blocked stream read cleanly!
    stall.mode.store(1, .release);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var reader = try DockerLogReader.create(gpa, io, tr, cid, .{
        .connect_timeout_ms = 500,
        .head_timeout_ms = 500,
        .read_timeout_ms = 5000, // 5s timeout, so only `cancel_flag` can wake it quickly!
        .cancel_flag = &cancel_flag,
    });
    defer reader.destroy();

    var first_buf: [256]u8 = undefined;
    const n1 = try readReaderSome(&reader.interface, &first_buf);
    try std.testing.expect(std.mem.indexOf(u8, first_buf[0..n1], "first_live_line") != null);

    // Spawn a helper that triggers `cancel_flag` after 60ms while `readReaderSome` is blocked in `poll`
    const Canceler = struct {
        io: std.Io,
        flag: *std.atomic.Value(bool),
        fn run(c: @This()) void {
            std.Io.sleep(c.io, .fromMilliseconds(60), .awake) catch {};
            c.flag.store(true, .release);
        }
    };
    const cancel_thread = try std.Thread.spawn(.{}, Canceler.run, .{Canceler{ .io = io, .flag = &cancel_flag }});
    defer cancel_thread.join();

    const t0 = std.Io.Clock.awake.now(io);
    const n2 = try readReaderSome(&reader.interface, &first_buf);
    const elapsed_ms = t0.untilNow(io, .awake).toMilliseconds();
    try std.testing.expectEqual(@as(usize, 0), n2);
    try std.testing.expect(!reader.had_error);
    try std.testing.expect(elapsed_ms < 1000);
}

test "buildContainerLinePreviewJson stops early when context > 0 on large container logs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cid = "cafebabe0000111122223333444455556666777788889999aaaabbbbccccdddd";
    try tmp.dir.createDirPath(io, cid);
    var cdir = try tmp.dir.openDir(io, cid, .{});
    defer cdir.close(io);

    {
        var cf = try cdir.createFile(io, "config.v2.json", .{ .truncate = true });
        defer cf.close(io);
        var wbuf: [512]u8 = undefined;
        var fw = cf.writer(io, &wbuf);
        try fw.interface.writeAll(
            \\{"Name":"/big-svc","Created":"2026-11-14T01:00:00Z","State":{"Running":true},"Config":{"Image":"svc:v1"}}
        );
        try fw.interface.flush();
    }

    {
        const cur_name = try std.fmt.allocPrint(arena, "{s}-json.log", .{cid});
        var lf = try cdir.createFile(io, cur_name, .{ .truncate = true });
        defer lf.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = lf.writer(io, &wbuf);
        var idx: usize = 1;
        while (idx <= 2500) : (idx += 1) {
            try fw.interface.print(
                "{{\"log\":\"row_{d}\\n\",\"stream\":\"stdout\",\"time\":\"2026-11-14T01:00:00.000000000Z\"}}\n",
                .{idx},
            );
        }
        try fw.interface.flush();
    }

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &real_buf);
    const dir_path = try arena.dupe(u8, real_buf[0..tmp_len]);

    const json_str = try buildContainerLinePreviewJson(
        gpa,
        arena,
        io,
        .{},
        dir_path,
        "big-svc",
        "docker/big-svc",
        5,
        2, // `context > 0` previously disabled early exit and scanned all 2500 lines!
    );
    const parsed = try std.json.parseFromSlice(file_api.FileResponse, arena, json_str, .{});
    try std.testing.expectEqual(@as(usize, 5), parsed.value.lines.len);
    try std.testing.expectEqual(@as(u64, 3), parsed.value.startLine);
    try std.testing.expect(!parsed.value.eof);
    // Must stop right at `win_end (7) + 1000 = 1007` instead of draining all 2500 lines!
    try std.testing.expectEqual(@as(u64, 1007), parsed.value.totalLines);
}

test "HttpBodyDecoder handles chunk extensions, fragmented CRLF boundaries, and trailers in batch scan" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sock_rel_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/frag.sock", .{tmp.sub_path});
    const ua = try std.Io.net.UnixAddress.init(sock_rel_path);
    var srv = try ua.listen(io, .{});

    const FragServer = struct {
        server: *std.Io.net.Server,
        io: std.Io,

        fn run(ctx: *@This()) void {
            const conn = ctx.server.accept(ctx.io) catch return;
            defer conn.close(ctx.io);

            var rbuf: [512]u8 = undefined;
            var r = conn.reader(ctx.io, &rbuf);
            var req_buf: [512]u8 = undefined;
            _ = readReaderSome(&r.interface, &req_buf) catch {};

            // Deliberately split chunk header, `;ext`, `\r\n`, trailers, and closing CRLF
            const frags = [_][]const u8{
                "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=",
                "foo\r\nhello\r",
                "\n6;bar=1\r\n world\r\n0;done\r\nX-Trailer: ok\r\n\r",
                "\n",
            };
            var wbuf: [128]u8 = undefined;
            var w = conn.writer(ctx.io, &wbuf);
            for (frags) |frag| {
                w.interface.writeAll(frag) catch return;
                w.interface.flush() catch return;
                std.Io.sleep(ctx.io, .fromMilliseconds(2), .awake) catch {};
            }
        }
    };

    var mock = FragServer{ .server = &srv, .io = io };
    const th = try std.Thread.spawn(.{}, FragServer.run, .{&mock});
    defer {
        srv.deinit(io);
        th.join();
    }

    var reader = try DockerLogReader.create(gpa, io, .{ .unix_socket = sock_rel_path }, "111111111111", .{});
    defer reader.destroy();

    const body = try reader.interface.allocRemaining(arena, .limited(4096));
    try std.testing.expectEqualStrings("hello world", body);
}

test "processJsonLogEnvelopeLine fast path and fallbacks (reordered fields, escapes, surrogate pairs, attrs)" {
    const gpa = std.testing.allocator;
    var stdout_p: std.ArrayList(u8) = .empty;
    defer stdout_p.deinit(gpa);
    var stderr_p: std.ArrayList(u8) = .empty;
    defer stderr_p.deinit(gpa);
    var ready: std.ArrayList(u8) = .empty;
    defer ready.deinit(gpa);
    var decode_scratch: std.ArrayList(u8) = .empty;
    defer decode_scratch.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    // 1. Reordered keys + standard escapes + BMP \u003c + non-ASCII UTF-8 (handled on fast path)
    try processJsonLogEnvelopeLine(
        gpa,
        "{\"time\":\"2026-11-14T01:00:00Z\",\"stream\":\"stderr\",\"log\":\"a\\\"b\\\\c\\t\\u003c中文\\n\"}",
        &stdout_p,
        &stderr_p,
        &ready,
        &decode_scratch,
        &arena_state,
        1024 * 1024,
    );

    // 2. Surrogate pair \uD83D\uDE00 + unknown extra key `"attrs"` (handled cleanly via JsonLogEnvelopeDto fallback)
    try processJsonLogEnvelopeLine(
        gpa,
        "{\"log\":\"hi \\uD83D\\uDE00\\n\",\"attrs\":{\"env\":\"prod\"},\"stream\":\"stdout\",\"time\":\"2026-11-14T01:00:01Z\"}",
        &stdout_p,
        &stderr_p,
        &ready,
        &decode_scratch,
        &arena_state,
        1024 * 1024,
    );

    try std.testing.expectEqualStrings(
        "2026-11-14T01:00:00Z a\"b\\c\t<中文\n" ++
            "2026-11-14T01:00:01Z hi \xf0\x9f\x98\x80\n",
        ready.items,
    );
}

test "deduplicateDisplayNamesInPlace disambiguates >8 colliding containers in O(C)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list: [20]ContainerInfo = undefined;
    for (&list, 0..) |*item, i| {
        const sid = try std.fmt.allocPrint(arena, "id{d:0>10}", .{i});
        item.* = .{
            .id = sid,
            .short_id = sid[0..12],
            .display_name = try arena.dupe(u8, "worker"),
            .raw_name = "/worker",
            .image = "busybox",
            .state = "running",
            .status = "Up",
            .created_ns = 0,
            .running = true,
        };
    }

    try deduplicateDisplayNamesInPlace(arena, &list);
    for (list, 0..) |item, i| {
        const expected = try std.fmt.allocPrint(arena, "worker-id{d:0>10}", .{i});
        try std.testing.expectEqualStrings(expected, item.display_name);
    }
}

test "DockerLogReader pushes since/until over HTTP and skips stale rotated .log.gz by mtime" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Part A: HTTP Unix socket verifies `&since=...&until=...` in URI
    if (@import("builtin").os.tag != .windows) {
        const sock_rel_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/since.sock", .{tmp.sub_path});
        const ua = try std.Io.net.UnixAddress.init(sock_rel_path);
        var srv = try ua.listen(io, .{});

        const UriServer = struct {
            server: *std.Io.net.Server,
            io: std.Io,
            uri_buf: [512]u8 = undefined,
            uri_len: usize = 0,

            fn run(ctx: *@This()) void {
                const conn = ctx.server.accept(ctx.io) catch return;
                defer conn.close(ctx.io);
                var rbuf: [1024]u8 = undefined;
                var r = conn.reader(ctx.io, &rbuf);
                var req_buf: [1024]u8 = undefined;
                const n = readReaderSome(&r.interface, &req_buf) catch return;
                const eol = std.mem.indexOfScalar(u8, req_buf[0..n], '\n') orelse n;
                const copy_n = @min(eol, ctx.uri_buf.len);
                @memcpy(ctx.uri_buf[0..copy_n], req_buf[0..copy_n]);
                ctx.uri_len = copy_n;

                var wbuf: [512]u8 = undefined;
                var w = conn.writer(ctx.io, &wbuf);
                w.interface.writeAll(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\nContent-Length: 4\r\n\r\nok\n\n",
                ) catch return;
                w.interface.flush() catch {};
            }
        };

        var us = UriServer{ .server = &srv, .io = io };
        const th = try std.Thread.spawn(.{}, UriServer.run, .{&us});
        {
            var reader = try DockerLogReader.create(gpa, io, .{ .unix_socket = sock_rel_path }, "111111111111", .{
                .since_sec = 1700000100,
                .until_sec = 1700000200,
            });
            defer reader.destroy();
            _ = try reader.interface.allocRemaining(arena, .limited(4096));
        }
        srv.deinit(io);
        th.join();
        const seen_uri = us.uri_buf[0..us.uri_len];
        try std.testing.expect(std.mem.indexOf(u8, seen_uri, "&since=1700000100&until=1700000200") != null);
    }

    // Part B: containers_dir skips stale rotated `.log.2.gz` when `since_sec` is newer than its mtime
    const cid = "feedbeef0000111122223333444455556666777788889999aaaabbbbccccdddd";
    try tmp.dir.createDirPath(io, cid);
    var cdir = try tmp.dir.openDir(io, cid, .{});
    defer cdir.close(io);

    {
        var cf = try cdir.createFile(io, "config.v2.json", .{ .truncate = true });
        defer cf.close(io);
        var wbuf: [256]u8 = undefined;
        var fw = cf.writer(io, &wbuf);
        try fw.interface.writeAll("{\"Name\":\"/rot\",\"Created\":\"2026-11-14T01:00:00Z\",\"State\":{\"Running\":true}}");
        try fw.interface.flush();
    }

    {
        const gz_payload =
            \\{"log":"stale_gz_entry\n","stream":"stdout","time":"2023-11-14T22:13:20.000000000Z"}
            \\
        ;
        const gz_bytes = try buildStoredGzipAlloc(arena, gz_payload);
        const gz_name = try std.fmt.allocPrint(arena, "{s}-json.log.2.gz", .{cid});
        var gf = try cdir.createFile(io, gz_name, .{ .truncate = true });
        defer gf.close(io);
        var wbuf: [1024]u8 = undefined;
        var fw = gf.writer(io, &wbuf);
        try fw.interface.writeAll(gz_bytes);
        try fw.interface.flush();
        try gf.setTimestamps(io, .{
            .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, 1_700_000_000) * std.time.ns_per_s } },
        });
    }

    {
        const cur_name = try std.fmt.allocPrint(arena, "{s}-json.log", .{cid});
        var af = try cdir.createFile(io, cur_name, .{ .truncate = true });
        defer af.close(io);
        var wbuf: [512]u8 = undefined;
        var fw = af.writer(io, &wbuf);
        try fw.interface.writeAll(
            \\{"log":"active_entry\n","stream":"stdout","time":"2023-11-14T22:15:05.000000000Z"}
            \\
        );
        try fw.interface.flush();
    }

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &real_buf);
    const dir_path = try arena.dupe(u8, real_buf[0..tmp_len]);

    {
        var r_pruned = try DockerLogReader.create(gpa, io, .{ .containers_dir = dir_path }, cid, .{
            .since_sec = 1_700_000_100,
        });
        defer r_pruned.destroy();
        const pruned_out = try r_pruned.interface.allocRemaining(arena, .limited(64 * 1024));
        try std.testing.expect(std.mem.indexOf(u8, pruned_out, "stale_gz_entry") == null);
        try std.testing.expect(std.mem.indexOf(u8, pruned_out, "active_entry") != null);
    }

    {
        var r_full = try DockerLogReader.create(gpa, io, .{ .containers_dir = dir_path }, cid, .{});
        defer r_full.destroy();
        const full_out = try r_full.interface.allocRemaining(arena, .limited(64 * 1024));
        try std.testing.expect(std.mem.indexOf(u8, full_out, "stale_gz_entry") != null);
        try std.testing.expect(std.mem.indexOf(u8, full_out, "active_entry") != null);
    }
}
