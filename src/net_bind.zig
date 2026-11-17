const std = @import("std");
const builtin = @import("builtin");
const server = @import("server.zig");

/// Default listen specification: loopback + Tailscale overlay interface(s),
/// without exposing LAN interfaces or `0.0.0.0`.
pub const DEFAULT_HOST_SPEC = "127.0.0.1,tailscale";

pub const HostSpec = struct {
    explicit_addrs: []std.Io.net.IpAddress,
    include_tailscale: bool,

    pub fn deinit(self: *HostSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.explicit_addrs);
        self.* = undefined;
    }
};

fn appendUniqueIp(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(std.Io.net.IpAddress),
    addr: std.Io.net.IpAddress,
) !void {
    for (list.items) |*existing| {
        if (existing.eql(&addr)) return;
    }
    try list.append(allocator, addr);
}

/// Parses a comma-separated `--host` / `WEBGREP_HOST` bind list containing literal
/// IPv4/IPv6 addresses and/or the `tailscale` keyword.
pub fn parseHostSpec(allocator: std.mem.Allocator, raw_spec: []const u8, port: u16) !HostSpec {
    var addrs: std.ArrayList(std.Io.net.IpAddress) = .empty;
    errdefer addrs.deinit(allocator);

    var include_tailscale = false;
    var it = std.mem.splitScalar(u8, raw_spec, ',');
    while (it.next()) |raw_part| {
        const tok = std.mem.trim(u8, raw_part, " \t\r\n");
        if (tok.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(tok, "tailscale")) {
            include_tailscale = true;
            continue;
        }
        const clean_tok = if (tok.len >= 2 and tok[0] == '[' and tok[tok.len - 1] == ']')
            tok[1 .. tok.len - 1]
        else
            tok;
        const parsed = try std.Io.net.IpAddress.parse(clean_tok, port);
        try appendUniqueIp(allocator, &addrs, parsed);
    }

    if (!include_tailscale and addrs.items.len == 0) {
        try addrs.append(allocator, .{ .ip4 = std.Io.net.Ip4Address.loopback(port) });
    }

    return .{
        .explicit_addrs = try addrs.toOwnedSlice(allocator),
        .include_tailscale = include_tailscale,
    };
}

/// Returns true for Tailscale CGNAT IPv4 addresses (`100.64.0.0/10`),
/// excluding MagicDNS (`100.100.100.100`).
pub fn isTailscaleIpv4(bytes: [4]u8) bool {
    return bytes[0] == 100 and (bytes[1] & 0xC0) == 64 and
        !(bytes[1] == 100 and bytes[2] == 100 and bytes[3] == 100);
}

/// Returns true for Tailscale ULA IPv6 prefix (`fd7a:115c:a1e0::/48`).
pub fn isTailscaleIpv6(bytes: [16]u8) bool {
    return std.mem.eql(u8, bytes[0..6], &.{ 0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0 });
}

/// Matches interface names used by Tailscale across macOS (`utun*`) and Linux/BSD
/// (`tailscale*`, `tun*`, `ts*`, `wg*`).
pub fn isTailscaleInterfaceName(name: []const u8) bool {
    const prefixes = [_][]const u8{ "utun", "tailscale", "tun", "ts", "wg" };
    for (prefixes) |prefix| {
        if (name.len >= prefix.len and std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) {
            return true;
        }
    }
    return false;
}

const CIfAddrs = extern struct {
    ifa_next: ?*CIfAddrs,
    ifa_name: ?[*:0]const u8,
    ifa_flags: c_uint,
    ifa_addr: ?*const std.posix.sockaddr,
    ifa_netmask: ?*const std.posix.sockaddr,
    ifa_dstaddr: ?*const std.posix.sockaddr,
    ifa_data: ?*anyopaque,
};

extern "c" fn getifaddrs(ifap: *?*CIfAddrs) c_int;
extern "c" fn freeifaddrs(ifa: ?*CIfAddrs) void;
const IFF_UP: c_uint = 0x1;

/// Enumerates active OS network interfaces and returns deduplicated Tailscale IPv4/IPv6
/// socket addresses for `port`.
pub fn discoverTailscaleAddresses(allocator: std.mem.Allocator, port: u16) ![]std.Io.net.IpAddress {
    var result: std.ArrayList(std.Io.net.IpAddress) = .empty;
    errdefer result.deinit(allocator);

    if (comptime (builtin.os.tag == .windows or builtin.os.tag == .wasi)) {
        return result.toOwnedSlice(allocator);
    }

    var ifap: ?*CIfAddrs = null;
    if (getifaddrs(&ifap) != 0) {
        return result.toOwnedSlice(allocator);
    }
    defer freeifaddrs(ifap);

    var cur = ifap;
    while (cur) |entry| : (cur = entry.ifa_next) {
        if ((entry.ifa_flags & IFF_UP) == 0) continue;
        const raw_name = entry.ifa_name orelse continue;
        const if_name = std.mem.span(raw_name);
        if (!isTailscaleInterfaceName(if_name)) continue;

        const addr_ptr = entry.ifa_addr orelse continue;
        switch (addr_ptr.family) {
            std.posix.AF.INET => {
                var sin: std.posix.sockaddr.in = undefined;
                @memcpy(std.mem.asBytes(&sin), @as([*]const u8, @ptrCast(addr_ptr))[0..@sizeOf(std.posix.sockaddr.in)]);
                const bytes: [4]u8 = @bitCast(sin.addr);
                if (!isTailscaleIpv4(bytes)) continue;
                try appendUniqueIp(allocator, &result, .{
                    .ip4 = .{ .bytes = bytes, .port = port },
                });
            },
            std.posix.AF.INET6 => {
                var sin6: std.posix.sockaddr.in6 = undefined;
                @memcpy(std.mem.asBytes(&sin6), @as([*]const u8, @ptrCast(addr_ptr))[0..@sizeOf(std.posix.sockaddr.in6)]);
                if (!isTailscaleIpv6(sin6.addr)) continue;
                try appendUniqueIp(allocator, &result, .{
                    .ip6 = .{ .bytes = sin6.addr, .port = port },
                });
            },
            else => {},
        }
    }

    return result.toOwnedSlice(allocator);
}

fn logListeningAddr(io: std.Io, log_mutex: *std.Io.Mutex, addr: std.Io.net.IpAddress) void {
    log_mutex.lockUncancelable(io);
    defer log_mutex.unlock(io);
    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    stdout_writer.interface.print("webgrep listening on http://{f}\n", .{addr}) catch {};
    stdout_writer.interface.flush() catch {};
}

fn logTailscaleWatch(io: std.Io, log_mutex: *std.Io.Mutex, port: u16) void {
    log_mutex.lockUncancelable(io);
    defer log_mutex.unlock(io);
    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    stdout_writer.interface.print(
        "webgrep tailscale watch active (waiting for Tailscale interface on port {d})\n",
        .{port},
    ) catch {};
    stdout_writer.interface.flush() catch {};
}

fn isWildcardCovering(explicit: std.Io.net.IpAddress, candidate: std.Io.net.IpAddress) bool {
    return switch (explicit) {
        .ip4 => |v4| switch (candidate) {
            .ip4 => std.mem.allEqual(u8, &v4.bytes, 0) and v4.port == candidate.getPort(),
            else => false,
        },
        .ip6 => |v6| switch (candidate) {
            .ip6 => std.mem.allEqual(u8, &v6.bytes, 0) and v6.port == candidate.getPort(),
            else => false,
        },
    };
}

const DynamicSlot = struct {
    manager: *DynamicManager,
    addr: std.Io.net.IpAddress,
    net_server: std.Io.net.Server,
};

const DynamicManager = struct {
    ctx: *const server.ServerContext,
    port: u16,
    explicit_addrs: []const std.Io.net.IpAddress,
    mutex: std.Io.Mutex = .init,
    log_mutex: *std.Io.Mutex,
    bound_addrs: std.ArrayList(std.Io.net.IpAddress) = .empty,

    fn isAlreadyCoveredLocked(self: *const DynamicManager, candidate: std.Io.net.IpAddress) bool {
        for (self.explicit_addrs) |*explicit| {
            if (explicit.eql(&candidate) or isWildcardCovering(explicit.*, candidate)) return true;
        }
        for (self.bound_addrs.items) |*bound| {
            if (bound.eql(&candidate)) return true;
        }
        return false;
    }

    fn removeBoundAddr(self: *DynamicManager, addr: std.Io.net.IpAddress) void {
        self.mutex.lockUncancelable(self.ctx.io);
        defer self.mutex.unlock(self.ctx.io);
        for (self.bound_addrs.items, 0..) |*item, i| {
            if (item.eql(&addr)) {
                _ = self.bound_addrs.swapRemove(i);
                return;
            }
        }
    }

    fn bindAvailableTailscale(self: *DynamicManager) usize {
        const discovered = discoverTailscaleAddresses(self.ctx.gpa, self.port) catch return 0;
        defer self.ctx.gpa.free(discovered);

        self.mutex.lockUncancelable(self.ctx.io);
        defer self.mutex.unlock(self.ctx.io);

        var newly_bound: usize = 0;
        for (discovered) |addr| {
            if (self.isAlreadyCoveredLocked(addr)) continue;

            var net_server = addr.listen(self.ctx.io, .{ .reuse_address = true }) catch continue;
            self.bound_addrs.append(self.ctx.gpa, addr) catch {
                net_server.deinit(self.ctx.io);
                continue;
            };
            const slot = self.ctx.gpa.create(DynamicSlot) catch {
                _ = self.bound_addrs.pop();
                net_server.deinit(self.ctx.io);
                continue;
            };
            slot.* = .{
                .manager = self,
                .addr = addr,
                .net_server = net_server,
            };

            if (std.Thread.spawn(.{}, acceptDynamicThread, .{slot})) |t| {
                t.detach();
                logListeningAddr(self.ctx.io, self.log_mutex, addr);
                newly_bound += 1;
            } else |_| {
                _ = self.bound_addrs.pop();
                net_server.deinit(self.ctx.io);
                self.ctx.gpa.destroy(slot);
            }
        }
        return newly_bound;
    }
};

fn acceptStaticLoop(ctx: *const server.ServerContext, net_server: *std.Io.net.Server) void {
    while (true) {
        const stream = net_server.accept(ctx.io) catch continue;
        if (std.Thread.spawn(.{}, server.handleConnectionThread, .{ ctx, stream })) |t| {
            t.detach();
        } else |_| {
            server.handleConnectionThread(ctx, stream);
        }
    }
}

fn acceptStaticThread(ctx: *const server.ServerContext, net_server: *std.Io.net.Server) void {
    acceptStaticLoop(ctx, net_server);
}

fn acceptDynamicThread(slot: *DynamicSlot) void {
    const ctx = slot.manager.ctx;
    while (true) {
        const stream = slot.net_server.accept(ctx.io) catch |err| switch (err) {
            error.SocketNotListening, error.NetworkDown => break,
            else => continue,
        };
        if (std.Thread.spawn(.{}, server.handleConnectionThread, .{ ctx, stream })) |t| {
            t.detach();
        } else |_| {
            server.handleConnectionThread(ctx, stream);
        }
    }
    slot.manager.removeBoundAddr(slot.addr);
    slot.net_server.deinit(ctx.io);
    ctx.gpa.destroy(slot);
}

fn watchTailscaleLoop(manager: *DynamicManager) void {
    while (true) {
        std.Io.sleep(manager.ctx.io, .fromMilliseconds(2000), .awake) catch {};
        _ = manager.bindAvailableTailscale();
    }
}

/// Binds all static addresses from `host_spec_raw` on `port` and, if requested
/// (`tailscale`), binds active Tailscale addresses immediately and watches for
/// Tailscale connect/reconnect events every 2 seconds.
pub fn runListeners(ctx: *const server.ServerContext, host_spec_raw: []const u8, port: u16) !void {
    var spec = try parseHostSpec(ctx.gpa, host_spec_raw, port);
    defer spec.deinit(ctx.gpa);

    var log_mutex: std.Io.Mutex = .init;
    var explicit_servers: std.ArrayList(std.Io.net.Server) = .empty;
    errdefer {
        for (explicit_servers.items) |*srv| srv.deinit(ctx.io);
        explicit_servers.deinit(ctx.gpa);
    }

    for (spec.explicit_addrs) |addr| {
        const srv = try addr.listen(ctx.io, .{ .reuse_address = true });
        try explicit_servers.append(ctx.gpa, srv);
    }

    for (spec.explicit_addrs) |addr| {
        logListeningAddr(ctx.io, &log_mutex, addr);
    }

    var manager = DynamicManager{
        .ctx = ctx,
        .port = port,
        .explicit_addrs = spec.explicit_addrs,
        .log_mutex = &log_mutex,
    };
    defer manager.bound_addrs.deinit(ctx.gpa);

    if (spec.include_tailscale) {
        const initial_bound = manager.bindAvailableTailscale();
        if (initial_bound == 0) {
            logTailscaleWatch(ctx.io, &log_mutex, port);
        }
        if (explicit_servers.items.len > 0) {
            const watch_thread = try std.Thread.spawn(.{}, watchTailscaleLoop, .{&manager});
            watch_thread.detach();
        }
    }

    if (explicit_servers.items.len == 0) {
        watchTailscaleLoop(&manager);
        return;
    }

    for (explicit_servers.items[1..]) |*srv| {
        const t = try std.Thread.spawn(.{}, acceptStaticThread, .{ ctx, srv });
        t.detach();
    }

    acceptStaticLoop(ctx, &explicit_servers.items[0]);
}

test "parseHostSpec parses default, ipv6 brackets, duplicates, and empty" {
    const gpa = std.testing.allocator;

    {
        var spec = try parseHostSpec(gpa, DEFAULT_HOST_SPEC, 8787);
        defer spec.deinit(gpa);
        try std.testing.expect(spec.include_tailscale);
        try std.testing.expectEqual(@as(usize, 1), spec.explicit_addrs.len);
        const expected = try std.Io.net.IpAddress.parse("127.0.0.1", 8787);
        try std.testing.expect(spec.explicit_addrs[0].eql(&expected));
    }

    {
        var spec = try parseHostSpec(gpa, "127.0.0.1, [::1], 127.0.0.1", 8787);
        defer spec.deinit(gpa);
        try std.testing.expect(!spec.include_tailscale);
        try std.testing.expectEqual(@as(usize, 2), spec.explicit_addrs.len);
        const expected_v6 = try std.Io.net.IpAddress.parse("::1", 8787);
        try std.testing.expect(spec.explicit_addrs[1].eql(&expected_v6));
    }

    {
        var spec = try parseHostSpec(gpa, " , ", 8787);
        defer spec.deinit(gpa);
        try std.testing.expect(!spec.include_tailscale);
        try std.testing.expectEqual(@as(usize, 1), spec.explicit_addrs.len);
        const expected = try std.Io.net.IpAddress.parse("127.0.0.1", 8787);
        try std.testing.expect(spec.explicit_addrs[0].eql(&expected));
    }

    {
        var spec = try parseHostSpec(gpa, "tailscale", 9000);
        defer spec.deinit(gpa);
        try std.testing.expect(spec.include_tailscale);
        try std.testing.expectEqual(@as(usize, 0), spec.explicit_addrs.len);
    }
}

test "Tailscale address and interface classification rejects LAN and proxy TUN" {
    try std.testing.expect(isTailscaleIpv4(.{ 100, 104, 203, 10 }));
    try std.testing.expect(isTailscaleIpv4(.{ 100, 64, 0, 1 }));
    try std.testing.expect(isTailscaleIpv4(.{ 100, 127, 255, 254 }));
    try std.testing.expect(!isTailscaleIpv4(.{ 100, 100, 100, 100 }));
    try std.testing.expect(!isTailscaleIpv4(.{ 198, 18, 0, 1 }));
    try std.testing.expect(!isTailscaleIpv4(.{ 192, 168, 0, 2 }));
    try std.testing.expect(!isTailscaleIpv4(.{ 127, 0, 0, 1 }));

    const ts6 = (try std.Io.net.Ip6Address.parse("fd7a:115c:a1e0::3b2d:cb0b", 8787)).bytes;
    const link6 = (try std.Io.net.Ip6Address.parse("fe80::1", 8787)).bytes;
    const loop6 = (try std.Io.net.Ip6Address.parse("::1", 8787)).bytes;
    try std.testing.expect(isTailscaleIpv6(ts6));
    try std.testing.expect(!isTailscaleIpv6(link6));
    try std.testing.expect(!isTailscaleIpv6(loop6));

    try std.testing.expect(isTailscaleInterfaceName("utun4"));
    try std.testing.expect(isTailscaleInterfaceName("tailscale0"));
    try std.testing.expect(isTailscaleInterfaceName("tun0"));
    try std.testing.expect(isTailscaleInterfaceName("TS0"));
    try std.testing.expect(isTailscaleInterfaceName("wg0"));
    try std.testing.expect(!isTailscaleInterfaceName("en0"));
    try std.testing.expect(!isTailscaleInterfaceName("lo0"));
    try std.testing.expect(!isTailscaleInterfaceName("awdl0"));
}

test "discoverTailscaleAddresses executes cleanly against host interfaces" {
    const addrs = try discoverTailscaleAddresses(std.testing.allocator, 8787);
    defer std.testing.allocator.free(addrs);
    for (addrs) |addr| {
        switch (addr) {
            .ip4 => |v4| try std.testing.expect(isTailscaleIpv4(v4.bytes)),
            .ip6 => |v6| try std.testing.expect(isTailscaleIpv6(v6.bytes)),
        }
    }
}
