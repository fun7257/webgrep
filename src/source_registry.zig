const std = @import("std");
const libwebgrep = @import("libwebgrep");
const docker_logs = @import("docker_logs.zig");
const file_api = @import("file_api.zig");
const search_cache = @import("search_cache.zig");

pub const SourceConfigDto = struct {
    path: []const u8 = "",
    endpoint: ?[]const u8 = null,
    timeFormat: ?[]const u8 = null,
};

pub const SourceKindMetaDto = struct {
    kind: []const u8,
    label: []const u8,
};

pub const builtin_source_kinds = [_]SourceKindMetaDto{
    .{ .kind = "dir", .label = "Local Directory" },
    .{ .kind = "file", .label = "Single File" },
    .{ .kind = "docker", .label = "Docker Containers" },
};

pub const SourceInfoDto = struct {
    id: []const u8,
    kind: []const u8,
    name: []const u8,
    enabled: bool,
    ready: bool,
    summary: []const u8,
    config: SourceConfigDto,
    path: []const u8,
    exists: bool,
};

pub const SourcesResponse = struct {
    kinds: []const SourceKindMetaDto = &builtin_source_kinds,
    searchCount: u64 = 0,
    sources: []const SourceInfoDto,
};

pub const SearchableSource = struct {
    id: []const u8,
    kind: []const u8,
    name: []const u8,
    path: []const u8,
    enabled: bool,
    time_format: []const u8 = "",
};

pub const UpsertSourceRequest = struct {
    id: ?[]const u8 = null,
    kind: []const u8 = "dir",
    name: []const u8 = "",
    path: []const u8 = "",
    config: ?SourceConfigDto = null,
    enabled: bool = true,
    timeFormat: ?[]const u8 = null,
};

pub const ToggleSourceRequest = struct {
    id: ?[]const u8 = null,
    enabled: ?bool = null,
};

pub const DeleteSourceRequest = struct {
    id: []const u8 = "",
};

pub const DirSuggestEntry = struct {
    name: []const u8,
    path: []const u8,
    isDir: bool = true,

    pub fn lessThan(_: void, a: DirSuggestEntry, b: DirSuggestEntry) bool {
        if (a.isDir != b.isDir) return a.isDir; // directories first, then files
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

pub const DirSuggestResponse = struct {
    kind: []const u8 = "dir",
    entries: []const DirSuggestEntry,
};

const PersistedSource = struct {
    id: []const u8 = "",
    kind: []const u8 = "dir",
    name: []const u8,
    path: []const u8 = "",
    config: ?SourceConfigDto = null,
    enabled: bool = true,
};

const PersistedFile = struct {
    version: u32 = 3,
    searchCount: u64 = 0,
    sources: []const PersistedSource = &.{},
};

const SourceRecord = struct {
    id: []u8,
    kind: []u8,
    name: []u8,
    path: []u8,
    enabled: bool = true,
    time_format: []u8,

    fn deinit(self: *SourceRecord, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.kind);
        gpa.free(self.name);
        gpa.free(self.path);
        gpa.free(self.time_format);
    }
};

pub const RegistryError = error{
    UnsupportedSourceKind,
    EmptyPath,
    DirectoryNotFound,
    FileNotFound,
    ExpectedDirFoundFile,
    ExpectedFileFoundDir,
    DockerUnavailable,
    InvalidDockerEndpoint,
    DuplicateSourceName,
    SourceNotFound,
};

/// Generates a standard 36-character RFC 4122 UUID v4 string (`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`).
pub fn generateUuidV4Alloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant RFC 4122

    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
}

pub fn isValidUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |ch, idx| {
        if (idx == 8 or idx == 13 or idx == 18 or idx == 23) {
            if (ch != '-') return false;
        } else {
            if (!std.ascii.isHex(ch)) return false;
        }
    }
    return true;
}

pub fn sanitizeNameAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (trimmed) |ch| {
        if (ch == '/' or ch == '\\' or ch == 0 or ch == ':' or ch == '@' or std.ascii.isWhitespace(ch)) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '-') {
                try out.append(allocator, '-');
            }
        } else {
            try out.append(allocator, ch);
        }
        if (out.items.len >= 64) break;
    }
    while (out.items.len > 0 and (out.items[0] == '.' or out.items[0] == '-')) {
        _ = out.orderedRemove(0);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

const DOCKER_CACHE_TTL_NS: i96 = 1_500 * std.time.ns_per_ms;
const MAX_DOCKER_CACHE_SLOTS: usize = 8;

const DockerCacheSlot = struct {
    arena: *std.heap.ArenaAllocator,
    base_endpoint: []const u8,
    docker_host: ?[]const u8,
    home_dir: ?[]const u8,
    xdg_runtime_dir: ?[]const u8,
    fetched_ns: i96,
    listed: docker_logs.ListedDocker,

    fn deinit(self: *DockerCacheSlot, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

const CachedAutoTransport = struct {
    arena: *std.heap.ArenaAllocator,
    docker_host: ?[]const u8,
    home_dir: ?[]const u8,
    xdg_runtime_dir: ?[]const u8,
    transport: docker_logs.Transport,

    fn deinit(self: *CachedAutoTransport, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn optStrDupeAlloc(alloc: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try alloc.dupe(u8, v) else null;
}

fn cloneDockerTransportAlloc(alloc: std.mem.Allocator, t: docker_logs.Transport) !docker_logs.Transport {
    return switch (t) {
        .unix_socket => |p| .{ .unix_socket = try alloc.dupe(u8, p) },
        .tcp => |tc| .{ .tcp = .{ .host = try alloc.dupe(u8, tc.host), .port = tc.port } },
        .containers_dir => |d| .{ .containers_dir = try alloc.dupe(u8, d) },
    };
}

fn cloneDockerContainerAlloc(alloc: std.mem.Allocator, c: docker_logs.ContainerInfo) !docker_logs.ContainerInfo {
    return .{
        .id = try alloc.dupe(u8, c.id),
        .short_id = try alloc.dupe(u8, c.short_id),
        .display_name = try alloc.dupe(u8, c.display_name),
        .raw_name = try alloc.dupe(u8, c.raw_name),
        .image = try alloc.dupe(u8, c.image),
        .state = try alloc.dupe(u8, c.state),
        .status = try alloc.dupe(u8, c.status),
        .created_ns = c.created_ns,
        .running = c.running,
    };
}

fn cloneListedDockerAlloc(
    alloc: std.mem.Allocator,
    src: docker_logs.ListedDocker,
    container_filter: ?[]const u8,
) !docker_logs.ListedDocker {
    const tp = try cloneDockerTransportAlloc(alloc, src.transport);
    const summary_ep = try alloc.dupe(u8, src.summary_endpoint);

    const clean_cf: ?[]const u8 = if (container_filter) |cf| blk: {
        const trimmed = std.mem.trim(u8, cf, " \t/");
        break :blk if (trimmed.len > 0) trimmed else null;
    } else null;

    var out: std.ArrayList(docker_logs.ContainerInfo) = .empty;
    var running_count: usize = 0;
    if (clean_cf == null) {
        try out.ensureTotalCapacity(alloc, src.containers.len);
        for (src.containers) |c| {
            const cloned = try cloneDockerContainerAlloc(alloc, c);
            if (cloned.running) running_count += 1;
            out.appendAssumeCapacity(cloned);
        }
    } else {
        for (src.containers) |c| {
            if (!docker_logs.containerMatchesTargetFilter(c, clean_cf.?)) continue;
            const cloned = try cloneDockerContainerAlloc(alloc, c);
            if (cloned.running) running_count += 1;
            try out.append(alloc, cloned);
        }
    }

    return .{
        .transport = tp,
        .containers = try out.toOwnedSlice(alloc),
        .running_count = running_count,
        .summary_endpoint = summary_ep,
    };
}

pub const SourceRegistry = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    data_root_path: []const u8,
    home_dir: ?[]const u8 = null,
    docker_host: ?[]const u8 = null,
    xdg_runtime_dir: ?[]const u8 = null,
    sources: std.ArrayList(SourceRecord) = .empty,
    search_count: std.atomic.Value(u64) = .init(0),
    heat_epoch: std.atomic.Value(u64) = .init(0),
    file_heat: std.StringHashMapUnmanaged(u64) = .empty,
    search_cache: search_cache.SearchCache = .{},
    // Lock order invariant: `docker_cache_mutex` guards ONLY the in-memory Docker discovery slots
    // and cached `auto` transport hint. Never acquire `self.mutex` or perform socket/disk I/O while holding it.
    docker_cache_mutex: std.Io.Mutex = .init,
    docker_cache_slots: std.ArrayList(DockerCacheSlot) = .empty,
    docker_cached_auto: ?CachedAutoTransport = null,

    pub fn dockerEnv(self: *const SourceRegistry) docker_logs.DockerEnv {
        return .{
            .home_dir = self.home_dir,
            .docker_host = self.docker_host,
            .xdg_runtime_dir = self.xdg_runtime_dir,
        };
    }

    pub fn getSearchCount(self: *const SourceRegistry) u64 {
        return self.search_count.load(.acquire);
    }

    pub fn getHeatEpoch(self: *const SourceRegistry) u64 {
        return self.heat_epoch.load(.acquire);
    }

    pub fn recordFileHeat(self: *SourceRegistry, io: std.Io, virtual_path: []const u8, delta: u64) void {
        self.recordFileHeatInternal(io, virtual_path, delta, true);
    }

    pub fn recordPassiveMatchHeat(self: *SourceRegistry, io: std.Io, virtual_path: []const u8, delta: u64) void {
        self.recordFileHeatInternal(io, virtual_path, delta, false);
    }

    fn recordFileHeatInternal(self: *SourceRegistry, io: std.Io, virtual_path: []const u8, delta: u64, bump_epoch: bool) void {
        if (virtual_path.len == 0 or delta == 0) return;
        if (bump_epoch) {
            _ = self.heat_epoch.fetchAdd(1, .acq_rel);
        }
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.file_heat.getPtr(virtual_path)) |val_ptr| {
            val_ptr.* = @min(2000, val_ptr.* +| delta);
            return;
        }
        if (self.file_heat.count() >= 4096) return;
        const key_copy = self.gpa.dupe(u8, virtual_path) catch return;
        self.file_heat.put(self.gpa, key_copy, @min(2000, delta)) catch {
            self.gpa.free(key_copy);
        };
    }

    pub fn getFileHeat(self: *SourceRegistry, io: std.Io, virtual_path: []const u8) u64 {
        if (virtual_path.len == 0) return 0;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.file_heat.get(virtual_path) orelse 0;
    }

    pub fn recordSearch(self: *SourceRegistry, io: std.Io) u64 {
        const next = self.search_count.fetchAdd(1, .acq_rel) + 1;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.saveToDiskLocked(io) catch {};
        return next;
    }

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        data_root_path: []const u8,
        home_dir: ?[]const u8,
    ) SourceRegistry {
        var reg = SourceRegistry{
            .gpa = gpa,
            .data_root_path = data_root_path,
            .home_dir = home_dir,
        };
        reg.loadFromDisk(io) catch {};
        return reg;
    }

    pub fn invalidateDockerCache(self: *SourceRegistry, io: std.Io) void {
        self.docker_cache_mutex.lockUncancelable(io);
        defer self.docker_cache_mutex.unlock(io);
        for (self.docker_cache_slots.items) |*slot| {
            slot.deinit(self.gpa);
        }
        self.docker_cache_slots.clearRetainingCapacity();
        if (self.docker_cached_auto) |*ca| {
            ca.deinit(self.gpa);
            self.docker_cached_auto = null;
        }
    }

    fn clearCachedAutoTransport(self: *SourceRegistry, io: std.Io) void {
        self.docker_cache_mutex.lockUncancelable(io);
        defer self.docker_cache_mutex.unlock(io);
        if (self.docker_cached_auto) |*ca| {
            ca.deinit(self.gpa);
            self.docker_cached_auto = null;
        }
    }

    fn storeDockerCacheResult(
        self: *SourceRegistry,
        io: std.Io,
        env: docker_logs.DockerEnv,
        spec: docker_logs.EndpointSpec,
        base_listed: docker_logs.ListedDocker,
    ) !void {
        const now_ns: i96 = std.Io.Clock.awake.now(io).nanoseconds;

        const slot_arena = try self.gpa.create(std.heap.ArenaAllocator);
        slot_arena.* = std.heap.ArenaAllocator.init(self.gpa);
        var slot = DockerCacheSlot{
            .arena = slot_arena,
            .base_endpoint = &.{},
            .docker_host = null,
            .home_dir = null,
            .xdg_runtime_dir = null,
            .fetched_ns = now_ns,
            .listed = undefined,
        };
        errdefer slot.deinit(self.gpa);

        const sa = slot_arena.allocator();
        slot.base_endpoint = try sa.dupe(u8, spec.base_endpoint);
        slot.docker_host = try optStrDupeAlloc(sa, env.docker_host);
        slot.home_dir = try optStrDupeAlloc(sa, env.home_dir);
        slot.xdg_runtime_dir = try optStrDupeAlloc(sa, env.xdg_runtime_dir);
        slot.listed = try cloneListedDockerAlloc(sa, base_listed, null);

        var next_auto: ?CachedAutoTransport = null;
        errdefer if (next_auto) |*na| na.deinit(self.gpa);
        if (spec.is_auto) {
            const aa_ptr = try self.gpa.create(std.heap.ArenaAllocator);
            aa_ptr.* = std.heap.ArenaAllocator.init(self.gpa);
            var ca = CachedAutoTransport{
                .arena = aa_ptr,
                .docker_host = null,
                .home_dir = null,
                .xdg_runtime_dir = null,
                .transport = undefined,
            };
            errdefer ca.deinit(self.gpa);
            const aa = aa_ptr.allocator();
            ca.docker_host = try optStrDupeAlloc(aa, env.docker_host);
            ca.home_dir = try optStrDupeAlloc(aa, env.home_dir);
            ca.xdg_runtime_dir = try optStrDupeAlloc(aa, env.xdg_runtime_dir);
            ca.transport = try cloneDockerTransportAlloc(aa, base_listed.transport);
            next_auto = ca;
        }

        self.docker_cache_mutex.lockUncancelable(io);
        defer self.docker_cache_mutex.unlock(io);

        var replaced = false;
        for (self.docker_cache_slots.items) |*existing| {
            if (std.mem.eql(u8, existing.base_endpoint, spec.base_endpoint) and
                optStrEql(existing.docker_host, env.docker_host) and
                optStrEql(existing.home_dir, env.home_dir) and
                optStrEql(existing.xdg_runtime_dir, env.xdg_runtime_dir))
            {
                existing.deinit(self.gpa);
                existing.* = slot;
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            if (self.docker_cache_slots.items.len >= MAX_DOCKER_CACHE_SLOTS) {
                var oldest_idx: usize = 0;
                for (self.docker_cache_slots.items[1..], 1..) |cand, i| {
                    if (cand.fetched_ns < self.docker_cache_slots.items[oldest_idx].fetched_ns) {
                        oldest_idx = i;
                    }
                }
                var evicted = self.docker_cache_slots.orderedRemove(oldest_idx);
                evicted.deinit(self.gpa);
            }
            try self.docker_cache_slots.append(self.gpa, slot);
        }

        if (next_auto) |na| {
            if (self.docker_cached_auto) |*prev| {
                prev.deinit(self.gpa);
            }
            self.docker_cached_auto = na;
        }
    }

    fn fetchBaseDockerFreshAlloc(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        env: docker_logs.DockerEnv,
        spec: docker_logs.EndpointSpec,
    ) !docker_logs.ListedDocker {
        var cached_tp_hint: ?docker_logs.Transport = null;
        if (spec.is_auto) {
            self.docker_cache_mutex.lockUncancelable(io);
            defer self.docker_cache_mutex.unlock(io);
            if (self.docker_cached_auto) |ca| {
                if (optStrEql(ca.docker_host, env.docker_host) and
                    optStrEql(ca.home_dir, env.home_dir) and
                    optStrEql(ca.xdg_runtime_dir, env.xdg_runtime_dir))
                {
                    cached_tp_hint = try cloneDockerTransportAlloc(arena, ca.transport);
                }
            }
        }

        var fetched_listed: docker_logs.ListedDocker = undefined;
        if (cached_tp_hint) |tp_hint| {
            if (docker_logs.listContainersForTransportAlloc(arena, io, tp_hint, null)) |containers| {
                var rc: usize = 0;
                for (containers) |c| {
                    if (c.running) rc += 1;
                }
                fetched_listed = .{
                    .transport = tp_hint,
                    .containers = containers,
                    .running_count = rc,
                    .summary_endpoint = try tp_hint.formatSummaryAlloc(arena),
                };
            } else |_| {
                self.clearCachedAutoTransport(io);
                fetched_listed = try docker_logs.listContainersAlloc(arena, io, env, spec.base_endpoint);
            }
        } else {
            fetched_listed = try docker_logs.listContainersAlloc(arena, io, env, spec.base_endpoint);
        }

        self.storeDockerCacheResult(io, env, spec, fetched_listed) catch {};
        return fetched_listed;
    }

    /// Reads Docker containers with a 1.5s in-memory TTL cache (and cached `auto` transport reuse).
    /// Failures are never negatively cached.
    pub fn listDockerCachedAlloc(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_endpoint: []const u8,
    ) !docker_logs.ListedDocker {
        const spec = docker_logs.parseEndpointSpec(raw_endpoint);
        const env = self.dockerEnv();
        const now_ns: i96 = std.Io.Clock.awake.now(io).nanoseconds;

        {
            self.docker_cache_mutex.lockUncancelable(io);
            defer self.docker_cache_mutex.unlock(io);
            for (self.docker_cache_slots.items) |slot| {
                if (now_ns - slot.fetched_ns <= DOCKER_CACHE_TTL_NS and
                    std.mem.eql(u8, slot.base_endpoint, spec.base_endpoint) and
                    optStrEql(slot.docker_host, env.docker_host) and
                    optStrEql(slot.home_dir, env.home_dir) and
                    optStrEql(slot.xdg_runtime_dir, env.xdg_runtime_dir))
                {
                    return cloneListedDockerAlloc(arena, slot.listed, spec.container_filter);
                }
            }
        }

        const base_listed = try self.fetchBaseDockerFreshAlloc(arena, io, env, spec);
        return cloneListedDockerAlloc(arena, base_listed, spec.container_filter);
    }

    /// Always queries live Docker (`/containers/json?all=1`) so search sees newly spawned or stopped
    /// containers immediately, while still reusing the cached `auto` transport and warming the 1.5s cache.
    pub fn listDockerFreshForSearchAlloc(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_endpoint: []const u8,
    ) !docker_logs.ListedDocker {
        const spec = docker_logs.parseEndpointSpec(raw_endpoint);
        const env = self.dockerEnv();
        const base_listed = try self.fetchBaseDockerFreshAlloc(arena, io, env, spec);
        return cloneListedDockerAlloc(arena, base_listed, spec.container_filter);
    }

    pub fn deinit(self: *SourceRegistry, io: std.Io) void {
        self.invalidateDockerCache(io);
        self.docker_cache_slots.deinit(self.gpa);
        self.search_cache.deinit(self.gpa, io);
        self.mutex.lockUncancelable(io);
        var it = self.file_heat.keyIterator();
        while (it.next()) |k| {
            self.gpa.free(k.*);
        }
        self.file_heat.deinit(self.gpa);
        for (self.sources.items) |*s| s.deinit(self.gpa);
        self.sources.deinit(self.gpa);
        self.mutex.unlock(io);
    }

    pub fn expandTildeAlloc(self: *const SourceRegistry, allocator: std.mem.Allocator, raw_path: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
        if (trimmed.len == 0) return "";
        if (trimmed[0] == '~') {
            if (self.home_dir) |home| {
                if (trimmed.len == 1) {
                    return try allocator.dupe(u8, home);
                } else if (trimmed[1] == '/') {
                    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, trimmed[1..] });
                }
            }
        }
        return try allocator.dupe(u8, trimmed);
    }

    fn loadFromDisk(self: *SourceRegistry, io: std.Io) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const cwd = std.Io.Dir.cwd();
        var data_dir = cwd.openDir(io, self.data_root_path, .{}) catch return;
        defer data_dir.close(io);

        var file = data_dir.openFile(io, "sources.json", .{ .allow_directory = false }) catch return;
        defer file.close(io);

        var read_buf: [8192]u8 = undefined;
        var file_reader = file.reader(io, &read_buf);
        const raw_bytes = file_reader.interface.allocRemaining(arena, .limited(8 * 1024 * 1024)) catch return;

        var parsed = std.json.parseFromSlice(PersistedFile, arena, raw_bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.search_count.store(parsed.value.searchCount, .release);

        for (self.sources.items) |*s| s.deinit(self.gpa);
        self.sources.clearRetainingCapacity();

        var migrated_uuid = false;
        for (parsed.value.sources) |ps| {
            const eff_kind_str = if (ps.kind.len > 0) ps.kind else "dir";
            const is_docker = std.mem.eql(u8, eff_kind_str, "docker");
            const raw_eff_path = resolveConfigPath(ps.config, ps.path);
            const eff_path = if (raw_eff_path.len == 0 and is_docker)
                "auto"
            else
                raw_eff_path;

            if (eff_path.len == 0 or ps.name.len == 0) continue;

            const id_copy = if (isValidUuid(ps.id))
                try self.gpa.dupe(u8, ps.id)
            else blk: {
                migrated_uuid = true;
                break :blk try generateUuidV4Alloc(self.gpa, io);
            };
            errdefer self.gpa.free(id_copy);

            const kind_copy = try self.gpa.dupe(u8, eff_kind_str);
            errdefer self.gpa.free(kind_copy);
            const name_copy = try self.gpa.dupe(u8, ps.name);
            errdefer self.gpa.free(name_copy);
            const path_copy = try self.gpa.dupe(u8, eff_path);
            errdefer self.gpa.free(path_copy);
            const default_loaded_tf: []const u8 = if (is_docker) "auto" else "";
            const maybe_cfg_tf: ?[]const u8 = if (ps.config) |cfg| cfg.timeFormat else null;
            const raw_tf = maybe_cfg_tf orelse default_loaded_tf;
            const trimmed_tf = std.mem.trim(u8, raw_tf[0..@min(raw_tf.len, 256)], " \t\r\n");
            const tf_copy = try self.gpa.dupe(u8, trimmed_tf);
            errdefer self.gpa.free(tf_copy);

            try self.sources.append(self.gpa, .{
                .id = id_copy,
                .kind = kind_copy,
                .name = name_copy,
                .path = path_copy,
                .enabled = ps.enabled,
                .time_format = tf_copy,
            });
        }

        if (migrated_uuid) {
            self.saveToDiskLocked(io) catch {};
        }
    }

    fn resolveConfigPath(cfg_opt: ?SourceConfigDto, top_path: []const u8) []const u8 {
        if (cfg_opt) |cfg| {
            if (cfg.path.len > 0) return cfg.path;
            if (cfg.endpoint) |ep| {
                if (ep.len > 0) return ep;
            }
        }
        return top_path;
    }

    fn serializedSourceTimeFormat(kind: []const u8, tf: []const u8) ?[]const u8 {
        if (tf.len > 0 or std.mem.eql(u8, kind, "docker")) return tf;
        return null;
    }

    fn hasExistingDockerEndpoint(self: *SourceRegistry, io: std.Io, req_id: ?[]const u8, real_path: []const u8) bool {
        const id = req_id orelse return false;
        if (id.len == 0) return false;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.sources.items) |s| {
            if (std.mem.eql(u8, s.id, id) and std.mem.eql(u8, s.kind, "docker") and std.mem.eql(u8, s.path, real_path)) {
                return true;
            }
        }
        return false;
    }

    fn saveToDiskLocked(self: *const SourceRegistry, io: std.Io) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var persisted_list: std.ArrayList(PersistedSource) = .empty;
        try persisted_list.ensureTotalCapacity(arena, self.sources.items.len);

        for (self.sources.items) |src| {
            persisted_list.appendAssumeCapacity(.{
                .id = src.id,
                .kind = src.kind,
                .name = src.name,
                .path = src.path,
                .config = .{
                    .path = src.path,
                    .timeFormat = serializedSourceTimeFormat(src.kind, src.time_format),
                },
                .enabled = src.enabled,
            });
        }

        const json_bytes = try file_api.stringifyAlloc(arena, PersistedFile{
            .version = 3,
            .searchCount = self.search_count.load(.acquire),
            .sources = persisted_list.items,
        });

        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, self.data_root_path) catch {};
        var data_dir = try cwd.openDir(io, self.data_root_path, .{});
        defer data_dir.close(io);

        var file = try data_dir.createFile(io, "sources.json", .{ .truncate = true });
        defer file.close(io);

        var write_buf: [16384]u8 = undefined;
        var file_writer = file.writer(io, &write_buf);
        try file_writer.interface.writeAll(json_bytes);
        try file_writer.interface.flush();
    }

    pub fn upsertSource(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        req: UpsertSourceRequest,
    ) !void {
        const eff_kind = if (req.kind.len > 0) req.kind else "dir";
        const is_file_kind = std.mem.eql(u8, eff_kind, "file");
        const is_docker_kind = std.mem.eql(u8, eff_kind, "docker");
        if (!std.mem.eql(u8, eff_kind, "dir") and !is_file_kind and !is_docker_kind) {
            return error.UnsupportedSourceKind;
        }

        const raw_path = resolveConfigPath(req.config, req.path);

        var real_path: []const u8 = "";
        var docker_filter_name: ?[]const u8 = null;

        if (is_docker_kind) {
            real_path = try docker_logs.normalizeStoredEndpointAlloc(arena, self.dockerEnv(), raw_path);
            const spec = docker_logs.parseEndpointSpec(real_path);
            docker_filter_name = spec.container_filter;
            // Allow editing metadata (`timeFormat`, `name`, `enabled`) on an already-registered
            // Docker source even when the daemon is temporarily stopped; validate reachability
            // strictly when adding a new Docker source or changing its endpoint/container target.
            if (!self.hasExistingDockerEndpoint(io, req.id, real_path)) {
                const listed = docker_logs.listContainersAlloc(arena, io, self.dockerEnv(), real_path) catch |err| {
                    return switch (err) {
                        error.InvalidDockerEndpoint => error.InvalidDockerEndpoint,
                        else => error.DockerUnavailable,
                    };
                };
                if (spec.container_filter != null and listed.containers.len == 0) {
                    return error.DockerUnavailable;
                }
            }
        } else {
            const expanded_path = try self.expandTildeAlloc(arena, raw_path);
            if (expanded_path.len == 0) return error.EmptyPath;

            real_path = expanded_path;

            const target_stat = std.Io.Dir.cwd().statFile(io, expanded_path, .{}) catch {
                return if (is_file_kind) error.FileNotFound else error.DirectoryNotFound;
            };

            if (!is_file_kind) {
                if (target_stat.kind == .file) return error.ExpectedDirFoundFile;
                if (target_stat.kind != .directory) return error.DirectoryNotFound;

                var opened_dir = std.Io.Dir.cwd().openDir(io, expanded_path, .{ .iterate = true }) catch {
                    return error.DirectoryNotFound;
                };
                defer opened_dir.close(io);
                var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                if (opened_dir.realPath(io, &real_buf)) |n| {
                    real_path = try arena.dupe(u8, real_buf[0..n]);
                } else |_| {}
            } else {
                if (target_stat.kind == .directory) return error.ExpectedFileFoundDir;
                if (target_stat.kind != .file) return error.FileNotFound;

                const parent_path = std.fs.path.dirname(expanded_path) orelse ".";
                const file_base = std.fs.path.basename(expanded_path);
                if (file_base.len == 0) return error.FileNotFound;

                var parent_dir = std.Io.Dir.cwd().openDir(io, parent_path, .{}) catch {
                    return error.FileNotFound;
                };
                defer parent_dir.close(io);

                var opened_file = parent_dir.openFile(io, file_base, .{ .allow_directory = false }) catch {
                    return error.FileNotFound;
                };
                defer opened_file.close(io);

                var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const parent_real = if (parent_dir.realPath(io, &real_buf)) |n|
                    real_buf[0..n]
                else |_|
                    parent_path;

                real_path = if (std.mem.eql(u8, parent_real, "/"))
                    try std.fmt.allocPrint(arena, "/{s}", .{file_base})
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ parent_real, file_base });
            }
        }

        const fallback_name = blk: {
            if (is_docker_kind) {
                break :blk if (docker_filter_name) |cf| cf else "docker";
            }
            const b = std.fs.path.basename(real_path);
            break :blk if (b.len > 0) b else "root";
        };
        const raw_name = if (std.mem.trim(u8, req.name, " \t\r\n").len > 0) req.name else fallback_name;
        const clean_name = try sanitizeNameAlloc(arena, raw_name);
        const final_name = if (clean_name.len > 0) clean_name else "project";

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // Locate existing record by UUID id or path
        var target_idx: ?usize = null;
        if (req.id) |req_id| {
            if (req_id.len > 0) {
                for (self.sources.items, 0..) |s, idx| {
                    if (std.mem.eql(u8, s.id, req_id)) {
                        target_idx = idx;
                        break;
                    }
                }
            }
        }
        if (target_idx == null) {
            for (self.sources.items, 0..) |s, idx| {
                if (std.mem.eql(u8, s.kind, eff_kind) and std.mem.eql(u8, s.path, real_path)) {
                    target_idx = idx;
                    break;
                }
            }
        }

        // Ensure unique project name across other sources
        var unique_name = try arena.dupe(u8, final_name);
        var suffix: usize = 2;
        while (true) {
            var conflict = false;
            for (self.sources.items, 0..) |s, idx| {
                if (target_idx != null and target_idx.? == idx) continue;
                if (std.ascii.eqlIgnoreCase(s.name, unique_name)) {
                    conflict = true;
                    break;
                }
            }
            if (!conflict) break;
            unique_name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ final_name, suffix });
            suffix += 1;
        }

        const maybe_req_tf: ?[]const u8 = (if (req.config) |cfg| cfg.timeFormat else null) orelse req.timeFormat;
        const capped_req_tf: ?[]const u8 = if (maybe_req_tf) |raw_tf| blk_tf: {
            const trimmed = std.mem.trim(u8, raw_tf[0..@min(raw_tf.len, 256)], " \t\r\n");
            break :blk_tf trimmed;
        } else null;

        if (target_idx) |idx| {
            var rec = &self.sources.items[idx];
            const next_kind = try self.gpa.dupe(u8, eff_kind);
            errdefer self.gpa.free(next_kind);
            const next_name = try self.gpa.dupe(u8, unique_name);
            errdefer self.gpa.free(next_name);
            const next_path = try self.gpa.dupe(u8, real_path);
            errdefer self.gpa.free(next_path);
            const next_tf: ?[]u8 = if (capped_req_tf) |tf| try self.gpa.dupe(u8, tf) else null;

            self.gpa.free(rec.kind);
            self.gpa.free(rec.name);
            self.gpa.free(rec.path);

            rec.kind = next_kind;
            rec.name = next_name;
            rec.path = next_path;
            rec.enabled = req.enabled;
            if (next_tf) |tf| {
                self.gpa.free(rec.time_format);
                rec.time_format = tf;
            }
        } else {
            const new_id = try generateUuidV4Alloc(self.gpa, io);
            errdefer self.gpa.free(new_id);
            const next_kind = try self.gpa.dupe(u8, eff_kind);
            errdefer self.gpa.free(next_kind);
            const next_name = try self.gpa.dupe(u8, unique_name);
            errdefer self.gpa.free(next_name);
            const next_path = try self.gpa.dupe(u8, real_path);
            errdefer self.gpa.free(next_path);
            const default_tf: []const u8 = if (is_docker_kind) "auto" else "";
            const next_tf = try self.gpa.dupe(u8, capped_req_tf orelse default_tf);
            errdefer self.gpa.free(next_tf);

            try self.sources.append(self.gpa, .{
                .id = new_id,
                .kind = next_kind,
                .name = next_name,
                .path = next_path,
                .enabled = req.enabled,
                .time_format = next_tf,
            });
        }

        try self.saveToDiskLocked(io);
        self.invalidateDockerCache(io);
    }

    pub fn toggleSource(
        self: *SourceRegistry,
        io: std.Io,
        req: ToggleSourceRequest,
    ) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var changed = false;
        if (req.id) |id_val| {
            if (id_val.len > 0) {
                for (self.sources.items) |*s| {
                    if (std.mem.eql(u8, s.id, id_val) or std.ascii.eqlIgnoreCase(s.name, id_val)) {
                        s.enabled = if (req.enabled) |en| en else !s.enabled;
                        changed = true;
                        break;
                    }
                }
            }
        } else if (req.enabled) |en| {
            for (self.sources.items) |*s| {
                if (s.enabled != en) {
                    s.enabled = en;
                    changed = true;
                }
            }
        }

        if (changed) {
            try self.saveToDiskLocked(io);
            self.invalidateDockerCache(io);
        }
    }

    pub fn removeSource(
        self: *SourceRegistry,
        io: std.Io,
        id: []const u8,
    ) !void {
        if (id.len == 0) return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (self.sources.items, 0..) |*s, idx| {
            if (std.mem.eql(u8, s.id, id) or std.ascii.eqlIgnoreCase(s.name, id)) {
                s.deinit(self.gpa);
                _ = self.sources.orderedRemove(idx);
                try self.saveToDiskLocked(io);
                self.invalidateDockerCache(io);
                return;
            }
        }
    }

    pub fn buildSourcesJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
    ) ![]u8 {
        const snapshot = try self.snapshotAllSources(arena, io);
        var dto_list: std.ArrayList(SourceInfoDto) = .empty;

        for (snapshot) |src| {
            var ready = false;
            var summary_text: []const u8 = src.path;

            if (std.mem.eql(u8, src.kind, "docker")) {
                const probe = if (self.listDockerCachedAlloc(arena, io, src.path)) |listed|
                    try docker_logs.summarizeListedDockerAlloc(arena, listed, src.path)
                else |_|
                    try docker_logs.unavailableProbeSummaryAlloc(arena, src.path);
                ready = probe.ready;
                summary_text = probe.summary_text;
            } else {
                if (!std.mem.eql(u8, src.kind, "file")) {
                    if (std.Io.Dir.cwd().openDir(io, src.path, .{ .iterate = true })) |dir_val| {
                        var d = dir_val;
                        defer d.close(io);
                        ready = true;
                    } else |_| {}
                }
                if (!ready) {
                    const parent_p = std.fs.path.dirname(src.path) orelse ".";
                    const base_p = std.fs.path.basename(src.path);
                    if (base_p.len > 0) {
                        if (std.Io.Dir.cwd().openDir(io, parent_p, .{})) |pdir_val| {
                            var pdir = pdir_val;
                            defer pdir.close(io);
                            if (pdir.openFile(io, base_p, .{ .allow_directory = false })) |f_val| {
                                var f = f_val;
                                defer f.close(io);
                                ready = true;
                            } else |_| {}
                        } else |_| {}
                    }
                }
            }

            try dto_list.append(arena, .{
                .id = src.id,
                .kind = src.kind,
                .name = src.name,
                .enabled = src.enabled,
                .ready = ready,
                .summary = summary_text,
                .config = .{
                    .path = src.path,
                    .timeFormat = serializedSourceTimeFormat(src.kind, src.time_format),
                },
                .path = src.path,
                .exists = ready,
            });
        }

        return file_api.stringifyAlloc(arena, SourcesResponse{
            .searchCount = self.search_count.load(.acquire),
            .sources = dto_list.items,
        });
    }

    pub fn snapshotAllSources(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
    ) ![]SearchableSource {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var out: std.ArrayList(SearchableSource) = .empty;
        try out.ensureTotalCapacity(arena, self.sources.items.len);

        for (self.sources.items) |s| {
            out.appendAssumeCapacity(.{
                .id = try arena.dupe(u8, s.id),
                .kind = try arena.dupe(u8, s.kind),
                .name = try arena.dupe(u8, s.name),
                .path = try arena.dupe(u8, s.path),
                .enabled = s.enabled,
                .time_format = try arena.dupe(u8, s.time_format),
            });
        }
        return out.toOwnedSlice(arena);
    }

    /// Resolves `<source_name>/<rel_path>` (including `<archive>::<entry>` virtual paths and sandboxed
    /// source-prefixed paths) and returns a JSON line preview for InspectorPane.
    pub fn buildLinePreviewJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        virtual_path_raw: []const u8,
        target_line_raw: u64,
        context_raw: u64,
    ) ![]u8 {
        return self.buildLinePreviewJsonWithSince(
            arena,
            io,
            virtual_path_raw,
            target_line_raw,
            context_raw,
            null,
        );
    }

    pub fn buildLinePreviewJsonWithSince(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        virtual_path_raw: []const u8,
        target_line_raw: u64,
        context_raw: u64,
        since_sec: ?u64,
    ) ![]u8 {
        return self.buildLinePreviewWindowJson(
            arena,
            io,
            virtual_path_raw,
            .{ .line = target_line_raw, .context = context_raw },
            since_sec,
        );
    }

    pub fn buildLinePreviewWindowJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        virtual_path_raw: []const u8,
        query: file_api.FileWindowQuery,
        since_sec: ?u64,
    ) ![]u8 {
        var trimmed = std.mem.trim(u8, virtual_path_raw, " \t\r\n");
        while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }
        if (trimmed.len == 0) return error.InvalidPath;

        var host_raw: []const u8 = trimmed;
        var clean_entry: ?[]const u8 = null;
        if (std.mem.indexOf(u8, trimmed, file_api.ARCHIVE_VIRTUAL_SEP) != null) {
            const vp = file_api.splitArchiveVirtualPath(trimmed) orelse return error.InvalidPath;
            host_raw = vp.archive_path;
            clean_entry = try file_api.sanitizeArchiveEntryPath(vp.entry_path);
        }

        var matched_path: ?[]const u8 = null;
        var matched_kind: []const u8 = "dir";
        var inner_host_rel: []const u8 = "";
        var display_vpath: []const u8 = trimmed;

        if (host_raw.len > 0 and host_raw[0] == '/') {
            // Absolute path form: must strictly reside inside a registered source sandbox
            const abs_body = try file_api.sanitizeRelPath(host_raw[1..]);
            if (abs_body.len == 0) return error.InvalidPath;

            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            var best_len: usize = 0;
            for (self.sources.items) |s| {
                if (std.mem.eql(u8, s.kind, "docker")) continue;
                const s_trimmed = std.mem.trimEnd(u8, s.path, "/");
                if (s_trimmed.len == 0) continue;
                if (std.mem.eql(u8, s.kind, "file")) {
                    if (std.mem.eql(u8, host_raw, s_trimmed) and s_trimmed.len > best_len) {
                        best_len = s_trimmed.len;
                        matched_path = try arena.dupe(u8, s.path);
                        matched_kind = try arena.dupe(u8, s.kind);
                        inner_host_rel = std.fs.path.basename(s_trimmed);
                    }
                } else {
                    if (std.mem.startsWith(u8, host_raw, s_trimmed) and
                        host_raw.len > s_trimmed.len and
                        host_raw[s_trimmed.len] == '/' and
                        s_trimmed.len > best_len)
                    {
                        const rel_part = try file_api.sanitizeRelPath(host_raw[s_trimmed.len + 1 ..]);
                        if (rel_part.len > 0) {
                            best_len = s_trimmed.len;
                            matched_path = try arena.dupe(u8, s.path);
                            matched_kind = try arena.dupe(u8, s.kind);
                            inner_host_rel = rel_part;
                        }
                    }
                }
            }
            if (matched_path == null) return error.InvalidPath;
        } else {
            const clean_host = try file_api.sanitizeRelPath(host_raw);
            if (clean_host.len == 0) return error.InvalidPath;
            display_vpath = if (clean_entry) |entry|
                try file_api.formatArchiveVirtualPathAlloc(arena, clean_host, entry)
            else
                clean_host;

            if (std.mem.indexOfScalar(u8, clean_host, '/')) |slash_idx| {
                const source_name = clean_host[0..slash_idx];
                const candidate_rel = clean_host[slash_idx + 1 ..];
                if (source_name.len == 0 or candidate_rel.len == 0) return error.InvalidPath;

                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                for (self.sources.items) |s| {
                    if (std.ascii.eqlIgnoreCase(s.name, source_name) or std.ascii.eqlIgnoreCase(s.id, source_name)) {
                        matched_path = try arena.dupe(u8, s.path);
                        matched_kind = try arena.dupe(u8, s.kind);
                        inner_host_rel = candidate_rel;
                        break;
                    }
                }
            }

            // Fallback for source-less relative paths (e.g. `web-grep-v0.1.7.tar.gz::README.md`)
            if (matched_path == null) {
                var dir_candidates: std.ArrayList([]const u8) = .empty;
                var docker_candidates: std.ArrayList([]const u8) = .empty;
                {
                    self.mutex.lockUncancelable(io);
                    defer self.mutex.unlock(io);
                    for (self.sources.items) |s| {
                        if (std.mem.eql(u8, s.kind, "docker")) {
                            try docker_candidates.append(arena, try arena.dupe(u8, s.path));
                            continue;
                        }
                        const base = std.fs.path.basename(s.path);
                        if (std.mem.eql(u8, s.kind, "file") and
                            (std.ascii.eqlIgnoreCase(s.name, clean_host) or
                                std.ascii.eqlIgnoreCase(s.id, clean_host) or
                                std.ascii.eqlIgnoreCase(base, clean_host)))
                        {
                            matched_path = try arena.dupe(u8, s.path);
                            matched_kind = try arena.dupe(u8, s.kind);
                            inner_host_rel = base;
                            break;
                        }
                        if (!std.mem.eql(u8, s.kind, "file")) {
                            try dir_candidates.append(arena, try arena.dupe(u8, s.path));
                        }
                    }
                }
                if (matched_path == null) {
                    for (dir_candidates.items) |dpath| {
                        if (std.Io.Dir.cwd().openDir(io, dpath, .{})) |dir_val| {
                            var d = dir_val;
                            defer d.close(io);
                            if (d.statFile(io, clean_host, .{})) |st| {
                                if (st.kind != .directory) {
                                    matched_path = dpath;
                                    matched_kind = "dir";
                                    inner_host_rel = clean_host;
                                    break;
                                }
                            } else |_| {}
                        } else |_| {}
                    }
                }
                if (matched_path == null and clean_entry == null and std.mem.indexOfScalar(u8, clean_host, '/') == null) {
                    for (docker_candidates.items) |dep| {
                        if (self.listDockerCachedAlloc(arena, io, dep)) |listed| {
                            for (listed.containers) |c| {
                                if (docker_logs.containerMatchesTargetFilter(c, clean_host)) {
                                    matched_path = dep;
                                    matched_kind = "docker";
                                    inner_host_rel = clean_host;
                                    break;
                                }
                            }
                            if (matched_path != null) break;
                        } else |_| {}
                    }
                }
            }
        }

        // Boost access heat whenever a user inspects a record from this file
        self.recordFileHeat(io, display_vpath, 150);

        const src_path = matched_path orelse return error.FileNotFound;
        if (std.mem.eql(u8, matched_kind, "docker")) {
            if (clean_entry != null) return error.InvalidPath;
            const clean_ref = std.mem.trim(u8, inner_host_rel, " \t/");
            if (clean_ref.len == 0 or std.mem.indexOf(u8, clean_ref, "..") != null) {
                return error.InvalidPath;
            }

            if (self.listDockerCachedAlloc(arena, io, src_path)) |listed| {
                for (listed.containers) |c| {
                    if (docker_logs.containerMatchesTargetFilter(c, clean_ref)) {
                        if (docker_logs.buildContainerLineWindowForResolvedJson(
                            self.gpa,
                            arena,
                            io,
                            listed.transport,
                            c.id,
                            display_vpath,
                            query,
                            since_sec,
                        )) |res_json| {
                            return res_json;
                        } else |err| switch (err) {
                            error.FileNotFound => break,
                            else => return err,
                        }
                    }
                }
            } else |_| {}

            // Cache miss or stale container/transport -> invalidate once and perform a fresh lookup + stream
            self.invalidateDockerCache(io);
            const fresh_listed = self.listDockerFreshForSearchAlloc(arena, io, src_path) catch return error.FileNotFound;
            for (fresh_listed.containers) |c| {
                if (docker_logs.containerMatchesTargetFilter(c, clean_ref)) {
                    return docker_logs.buildContainerLineWindowForResolvedJson(
                        self.gpa,
                        arena,
                        io,
                        fresh_listed.transport,
                        c.id,
                        display_vpath,
                        query,
                        since_sec,
                    );
                }
            }
            return error.FileNotFound;
        }
        if (!std.mem.eql(u8, matched_kind, "file")) {
            const rel_target = if (clean_entry) |entry|
                try file_api.formatArchiveVirtualPathAlloc(arena, inner_host_rel, entry)
            else
                inner_host_rel;

            if (std.Io.Dir.cwd().openDir(io, src_path, .{})) |source_dir_val| {
                var source_dir = source_dir_val;
                defer source_dir.close(io);
                return file_api.buildFileWindowJsonWithDisplayPath(
                    arena,
                    io,
                    source_dir,
                    rel_target,
                    display_vpath,
                    query,
                );
            } else |_| {}
        }

        // Single-file source: open its parent directory and read `basename(src_path)` (or `basename::entry`)
        const parent_path = std.fs.path.dirname(src_path) orelse ".";
        const file_base = std.fs.path.basename(src_path);
        if (file_base.len == 0) return error.FileNotFound;

        const file_target = if (clean_entry) |entry|
            try file_api.formatArchiveVirtualPathAlloc(arena, file_base, entry)
        else
            file_base;

        var parent_dir = try std.Io.Dir.cwd().openDir(io, parent_path, .{});
        defer parent_dir.close(io);

        return file_api.buildFileWindowJsonWithDisplayPath(
            arena,
            io,
            parent_dir,
            file_target,
            display_vpath,
            query,
        );
    }

    /// Generic source driver completion endpoint (`/api/sources/complete?kind=dir|file|docker&q=...`).
    pub fn buildSourceCompletionJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        kind: []const u8,
        raw_query: []const u8,
    ) ![]u8 {
        const eff_kind = if (kind.len == 0) "dir" else kind;
        if (std.mem.eql(u8, eff_kind, "docker")) {
            return self.buildDockerSuggestionsJson(arena, io, raw_query);
        }
        if (!std.mem.eql(u8, eff_kind, "dir") and !std.mem.eql(u8, eff_kind, "file")) {
            return file_api.stringifyAlloc(arena, DirSuggestResponse{
                .kind = eff_kind,
                .entries = &.{},
            });
        }
        return self.buildPathSuggestionsJson(arena, io, eff_kind, raw_query);
    }

    fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    /// Provides live Docker socket & container autocomplete (`kind == "docker"`).
    pub fn buildDockerSuggestionsJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_query: []const u8,
    ) ![]u8 {
        const trimmed_q = std.mem.trim(u8, raw_query, " \t\r\n");
        var entries: std.ArrayList(DirSuggestEntry) = .empty;
        const max_entries: usize = 50;

        var base_ep: []const u8 = "auto";
        var filter_q: []const u8 = trimmed_q;
        const has_sep = std.mem.indexOf(u8, trimmed_q, "::") != null;

        if (std.mem.indexOf(u8, trimmed_q, "::")) |sep_idx| {
            const left = std.mem.trim(u8, trimmed_q[0..sep_idx], " \t");
            base_ep = if (left.len > 0) left else "auto";
            filter_q = std.mem.trim(u8, trimmed_q[sep_idx + 2 ..], " \t");
        } else if (std.ascii.startsWithIgnoreCase(trimmed_q, "unix://") or
            std.ascii.startsWithIgnoreCase(trimmed_q, "tcp://") or
            std.ascii.startsWithIgnoreCase(trimmed_q, "http://") or
            (trimmed_q.len > 0 and (trimmed_q[0] == '/' or trimmed_q[0] == '~')))
        {
            base_ep = trimmed_q;
            filter_q = "";
        }

        const env = self.dockerEnv();
        const listed_opt: ?docker_logs.ListedDocker = self.listDockerCachedAlloc(arena, io, base_ep) catch blk: {
            if (!std.mem.eql(u8, base_ep, "auto")) {
                break :blk (self.listDockerCachedAlloc(arena, io, "auto") catch null);
            }
            break :blk null;
        };

        // 1. Auto-discover all containers entry (`"auto"`)
        if (!has_sep and (trimmed_q.len == 0 or
            containsCaseInsensitive("auto", trimmed_q) or
            containsCaseInsensitive("docker", trimmed_q) or
            containsCaseInsensitive("all", trimmed_q)))
        {
            const auto_label = if (listed_opt) |listed|
                try std.fmt.allocPrint(
                    arena,
                    "auto · {d} containers ({d} running)",
                    .{ listed.containers.len, listed.running_count },
                )
            else
                "auto";
            try entries.append(arena, .{
                .name = auto_label,
                .path = "auto",
                .isDir = false,
            });
        }

        // 2. Detected active Unix sockets on host
        if (!has_sep) {
            const candidates = try docker_logs.candidateSocketPathsAlloc(arena, env);
            for (candidates) |sock_p| {
                const uri = try std.fmt.allocPrint(arena, "unix://{s}", .{sock_p});
                if (trimmed_q.len > 0 and !containsCaseInsensitive(uri, trimmed_q)) continue;
                if (std.Io.Dir.cwd().statFile(io, sock_p, .{})) |_| {
                    try entries.append(arena, .{
                        .name = uri,
                        .path = uri,
                        .isDir = false,
                    });
                } else |_| {}
            }
        }

        // 3. Individual containers (`<base>::<container_name>`)
        if (listed_opt) |listed| {
            const prefix = if (has_sep) base_ep else "auto";
            for (listed.containers) |c| {
                if (entries.items.len >= max_entries) break;
                if (filter_q.len > 0) {
                    const matched = containsCaseInsensitive(c.display_name, filter_q) or
                        containsCaseInsensitive(c.image, filter_q) or
                        containsCaseInsensitive(c.short_id, filter_q) or
                        containsCaseInsensitive(c.state, filter_q);
                    if (!matched) continue;
                }
                const target_path = try std.fmt.allocPrint(arena, "{s}::{s}", .{ prefix, c.display_name });
                const label = if (c.image.len > 0)
                    try std.fmt.allocPrint(
                        arena,
                        "{s} ({s} · {s})",
                        .{ c.display_name, if (c.running) "running" else c.state, c.image },
                    )
                else
                    try std.fmt.allocPrint(
                        arena,
                        "{s} ({s})",
                        .{ c.display_name, if (c.running) "running" else c.state },
                    );
                try entries.append(arena, .{
                    .name = label,
                    .path = target_path,
                    .isDir = false,
                });
            }
        }

        return file_api.stringifyAlloc(arena, DirSuggestResponse{
            .kind = "docker",
            .entries = entries.items,
        });
    }

    /// Provides server filesystem directory autocomplete (`kind == "dir"`).
    pub fn buildDirSuggestionsJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_query: []const u8,
    ) ![]u8 {
        return self.buildPathSuggestionsJson(arena, io, "dir", raw_query);
    }

    /// Provides server filesystem path autocomplete tailored to the selected `kind` (`"dir"` or `"file"`).
    pub fn buildPathSuggestionsJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        kind: []const u8,
        raw_query: []const u8,
    ) ![]u8 {
        const is_file_mode = std.mem.eql(u8, kind, "file");
        const expanded = try self.expandTildeAlloc(arena, raw_query);
        var entries: std.ArrayList(DirSuggestEntry) = .empty;
        const max_entries: usize = 50;

        const search_target = if (expanded.len == 0) "." else expanded;
        const ends_with_sep = expanded.len > 0 and expanded[expanded.len - 1] == '/';

        // If the exact path matches the requested target type, include it first (resolved to realPath)
        if (!ends_with_sep) {
            if (std.Io.Dir.cwd().statFile(io, search_target, .{})) |exact_st| {
                if (!is_file_mode and exact_st.kind == .directory) {
                    if (std.Io.Dir.cwd().openDir(io, search_target, .{ .iterate = true })) |exact_dir_val| {
                        var exact_dir = exact_dir_val;
                        defer exact_dir.close(io);
                        var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        if (exact_dir.realPath(io, &real_buf)) |n| {
                            const real_str = try arena.dupe(u8, real_buf[0..n]);
                            const base = std.fs.path.basename(real_str);
                            try entries.append(arena, .{
                                .name = if (base.len > 0) try arena.dupe(u8, base) else real_str,
                                .path = real_str,
                                .isDir = true,
                            });
                        } else |_| {}
                    } else |_| {}
                } else if (is_file_mode and exact_st.kind == .file) {
                    const exact_parent = std.fs.path.dirname(search_target) orelse ".";
                    const exact_base = std.fs.path.basename(search_target);
                    if (exact_base.len > 0) {
                        if (std.Io.Dir.cwd().openDir(io, exact_parent, .{})) |pdir_val| {
                            var pdir = pdir_val;
                            defer pdir.close(io);
                            var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                            const p_real = if (pdir.realPath(io, &real_buf)) |n|
                                real_buf[0..n]
                            else |_|
                                exact_parent;
                            const real_file = if (std.mem.eql(u8, p_real, "/"))
                                try std.fmt.allocPrint(arena, "/{s}", .{exact_base})
                            else
                                try std.fmt.allocPrint(arena, "{s}/{s}", .{ p_real, exact_base });
                            try entries.append(arena, .{
                                .name = try arena.dupe(u8, exact_base),
                                .path = real_file,
                                .isDir = false,
                            });
                        } else |_| {}
                    }
                }
            } else |_| {}
        }

        const exact_count = entries.items.len;

        const dir_to_open: []const u8 = if (ends_with_sep)
            search_target
        else
            (std.fs.path.dirname(search_target) orelse ".");

        const filter_prefix: []const u8 = if (ends_with_sep)
            ""
        else
            std.fs.path.basename(search_target);

        if (std.Io.Dir.cwd().openDir(io, dir_to_open, .{ .iterate = true })) |parent_val| {
            var parent_dir = parent_val;
            defer parent_dir.close(io);

            var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const parent_real = if (parent_dir.realPath(io, &real_buf)) |n|
                try arena.dupe(u8, real_buf[0..n])
            else |_|
                dir_to_open;

            var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
            var lister = libwebgrep.walk_list.Lister.init(parent_dir, &scratch);
            var batch: [64]std.Io.Dir.Entry = undefined;

            outer: while (true) {
                const count = lister.fill(io, &batch) catch break;
                if (count == 0) break;
                for (batch[0..count]) |item| {
                    if (item.name.len == 0) continue;
                    if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
                    if (file_api.isAlwaysSkippedDir(item.name)) continue;
                    if (filter_prefix.len == 0 and item.name[0] == '.') continue;
                    if (filter_prefix.len > 0 and filter_prefix[0] != '.' and item.name[0] == '.') continue;

                    var is_dir = item.kind == .directory;
                    var is_file = item.kind == .file;
                    if (item.kind == .sym_link or item.kind == .unknown) {
                        if (parent_dir.statFile(io, item.name, .{})) |st| {
                            is_dir = st.kind == .directory;
                            is_file = st.kind == .file;
                        } else |_| continue;
                    }
                    if (!is_file_mode) {
                        if (!is_dir) continue;
                    } else {
                        if (!is_dir and !is_file) continue;
                    }

                    if (filter_prefix.len > 0 and !std.ascii.eqlIgnoreCase(filter_prefix, ".")) {
                        var matched = false;
                        if (item.name.len >= filter_prefix.len) {
                            var k: usize = 0;
                            while (k <= item.name.len - filter_prefix.len) : (k += 1) {
                                if (std.ascii.eqlIgnoreCase(item.name[k .. k + filter_prefix.len], filter_prefix)) {
                                    matched = true;
                                    break;
                                }
                            }
                        }
                        if (!matched) continue;
                    }

                    const full_path = if (std.mem.eql(u8, parent_real, "/"))
                        try std.fmt.allocPrint(arena, "/{s}", .{item.name})
                    else
                        try std.fmt.allocPrint(arena, "{s}/{s}", .{ parent_real, item.name });

                    var dup = false;
                    for (entries.items) |e| {
                        if (std.mem.eql(u8, e.path, full_path)) {
                            dup = true;
                            break;
                        }
                    }
                    if (dup) continue;

                    try entries.append(arena, .{
                        .name = try arena.dupe(u8, item.name),
                        .path = full_path,
                        .isDir = is_dir,
                    });
                    if (entries.items.len >= 256) break :outer;
                }
            }
        } else |_| {}

        if (entries.items.len > exact_count + 1) {
            std.mem.sort(DirSuggestEntry, entries.items[exact_count..], {}, DirSuggestEntry.lessThan);
        }

        const final_entries = if (entries.items.len > max_entries)
            entries.items[0..max_entries]
        else
            entries.items;

        return file_api.stringifyAlloc(arena, DirSuggestResponse{
            .kind = if (is_file_mode) "file" else "dir",
            .entries = final_entries,
        });
    }
};

test "SourceRegistry auto-assigns UUID v4 and persists directory projects" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    var assigned_uuid: []const u8 = "";
    {
        var reg = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg.deinit(io);

        try reg.upsertSource(arena, io, .{
            .kind = "dir",
            .name = "webgrep",
            .config = .{ .path = "." },
            .enabled = true,
        });

        const snap = try reg.snapshotAllSources(arena, io);
        try std.testing.expectEqual(@as(usize, 1), snap.len);
        try std.testing.expect(isValidUuid(snap[0].id));
        assigned_uuid = try arena.dupe(u8, snap[0].id);

        const json = try reg.buildSourcesJson(arena, io);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"dir\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"webgrep\"") != null);
    }

    // Re-load from disk and verify UUID persistence
    {
        var reg2 = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg2.deinit(io);

        const snap = try reg2.snapshotAllSources(arena, io);
        try std.testing.expectEqual(@as(usize, 1), snap.len);
        try std.testing.expectEqualStrings("dir", snap[0].kind);
        try std.testing.expectEqualStrings("webgrep", snap[0].name);
        try std.testing.expectEqualStrings(assigned_uuid, snap[0].id);
    }

    // Concurrent recordSearch across multiple threads (race-free atomic + mutex persistence)
    {
        var reg3 = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg3.deinit(io);

        const Worker = struct {
            fn run(r: *SourceRegistry, w_io: std.Io) void {
                for (0..25) |_| {
                    _ = r.recordSearch(w_io);
                }
            }
        };

        var threads: [4]?std.Thread = .{ null, null, null, null };
        for (0..4) |i| {
            threads[i] = std.Thread.spawn(.{}, Worker.run, .{ &reg3, io }) catch blk: {
                Worker.run(&reg3, io);
                break :blk null;
            };
        }
        for (0..4) |i| {
            if (threads[i]) |t| t.join();
        }
        try std.testing.expectEqual(@as(u64, 100), reg3.getSearchCount());
    }

    // Verify persisted searchCount after reload
    {
        var reg4 = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg4.deinit(io);
        try std.testing.expectEqual(@as(u64, 100), reg4.getSearchCount());
    }

    // Verify single-file data source (`kind: "file"`) auto-detection, persistence, and line preview
    {
        var f = try tmp.dir.createFile(io, "events.jsonl", .{ .truncate = true });
        var w_buf: [256]u8 = undefined;
        var fw = f.writer(io, &w_buf);
        try fw.interface.writeAll("{\"id\":1,\"msg\":\"alpha\"}\n{\"id\":2,\"msg\":\"beta\"}\n");
        try fw.interface.flush();
        f.close(io);

        const single_file_path = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{tmp_path});
        var reg5 = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg5.deinit(io);

        try reg5.upsertSource(arena, io, .{
            .kind = "file",
            .name = "",
            .config = .{ .path = single_file_path },
            .enabled = true,
        });

        const snap = try reg5.snapshotAllSources(arena, io);
        try std.testing.expectEqual(@as(usize, 2), snap.len);
        try std.testing.expectEqualStrings("file", snap[1].kind);
        try std.testing.expectEqualStrings("events.jsonl", snap[1].name);

        const preview_json = try reg5.buildLinePreviewJson(arena, io, "events.jsonl/events.jsonl", 2, 1);
        try std.testing.expect(std.mem.indexOf(u8, preview_json, "beta") != null);

        // Verify zero-disk-landing archive virtual path preview (`::`) and sandbox checks
        const payload = "line1_alpha\nline2_archive_hit\nline3_omega\n";
        const padded_payload = std.mem.alignForward(usize, payload.len, 512);
        const tar_buf = try arena.alloc(u8, 512 + padded_payload + 1024);
        @memset(tar_buf, 0);
        const entry_name = "inner/app.zig";
        @memcpy(tar_buf[0..entry_name.len], entry_name);
        @memcpy(tar_buf[100..107], "0000644");
        @memcpy(tar_buf[108..115], "0000000");
        @memcpy(tar_buf[116..123], "0000000");
        _ = try std.fmt.bufPrint(tar_buf[124..135], "{o:0>11}", .{payload.len});
        @memcpy(tar_buf[136..147], "00000000000");
        @memset(tar_buf[148..156], ' ');
        tar_buf[156] = '0';
        @memcpy(tar_buf[257..262], "ustar");
        @memcpy(tar_buf[263..265], "00");
        var sum: u64 = 0;
        for (tar_buf[0..512]) |b| sum += b;
        _ = try std.fmt.bufPrint(tar_buf[148..154], "{o:0>6}", .{sum});
        tar_buf[154] = 0;
        tar_buf[155] = ' ';
        @memcpy(tar_buf[512 .. 512 + payload.len], payload);

        var tf = try tmp.dir.createFile(io, "bundle.tar", .{ .truncate = true });
        var tw_buf: [512]u8 = undefined;
        var tfw = tf.writer(io, &tw_buf);
        try tfw.interface.writeAll(tar_buf);
        try tfw.interface.flush();
        tf.close(io);

        try reg5.upsertSource(arena, io, .{
            .kind = "dir",
            .name = "tmpdir",
            .config = .{ .path = tmp_path },
            .enabled = true,
        });

        // 1) `<source_name>/<archive>::<entry>`
        const arch_preview_1 = try reg5.buildLinePreviewJson(arena, io, "tmpdir/bundle.tar::inner/app.zig", 2, 1);
        try std.testing.expect(std.mem.indexOf(u8, arch_preview_1, "line2_archive_hit") != null);

        // 2) `<archive>::<entry>` resolved from registered directory source
        const arch_preview_2 = try reg5.buildLinePreviewJson(arena, io, "bundle.tar::inner/app.zig", 2, 1);
        try std.testing.expect(std.mem.indexOf(u8, arch_preview_2, "line2_archive_hit") != null);

        // 3) Reject traversal inside entry or outside source sandbox
        try std.testing.expectError(error.InvalidPath, reg5.buildLinePreviewJson(arena, io, "tmpdir/bundle.tar::../etc/passwd", 1, 1));
        try std.testing.expectError(error.InvalidPath, reg5.buildLinePreviewJson(arena, io, "/etc/passwd", 1, 1));
    }
}

test "SourceRegistry Docker source registration, persistence, live summary, autocomplete, and zero-disk line preview" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    const sock_rel_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/sr.sock", .{tmp.sub_path});
    const ua = try std.Io.net.UnixAddress.init(sock_rel_path);
    var srv = try ua.listen(io, .{});

    const MockServer = struct {
        server: *std.Io.net.Server,
        io: std.Io,
        stop: std.atomic.Value(bool) = .init(false),
        ping_hits: std.atomic.Value(u32) = .init(0),
        list_hits: std.atomic.Value(u32) = .init(0),
        logs_hits: std.atomic.Value(u32) = .init(0),

        fn run(ctx: *@This()) void {
            const alloc = std.heap.page_allocator;
            while (!ctx.stop.load(.acquire)) {
                const conn = ctx.server.accept(ctx.io) catch break;
                ctx.handleConn(alloc, ctx.io, conn) catch {};
            }
        }

        fn handleConn(ctx: *@This(), alloc: std.mem.Allocator, conn_io: std.Io, conn: std.Io.net.Stream) !void {
            defer conn.close(conn_io);
            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var r = conn.reader(conn_io, &rbuf);
            var w = conn.writer(conn_io, &wbuf);

            var req_buf: [2048]u8 = undefined;
            var total: usize = 0;
            while (total < req_buf.len) {
                const n = docker_logs.readReaderSome(&r.interface, req_buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (docker_logs.findHeaderEnd(req_buf[0..total]) != null) break;
            }
            const req_head = req_buf[0..total];
            const line_end = std.mem.indexOfScalar(u8, req_head, '\n') orelse return;
            const first_line = std.mem.trimEnd(u8, req_head[0..line_end], "\r");

            if (std.mem.indexOf(u8, first_line, "GET /_ping ") != null) {
                _ = ctx.ping_hits.fetchAdd(1, .acq_rel);
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK");
                try w.interface.flush();
                return;
            }

            if (std.mem.indexOf(u8, first_line, "GET /containers/json") != null) {
                _ = ctx.list_hits.fetchAdd(1, .acq_rel);
                const body =
                    \\[
                    \\  {"Id":"1111111111112222222222223333333333334444444444445555555555556666","Names":["/web-api"],"Image":"nginx:1.27","State":"running","Status":"Up 3h","Created":1763093400},
                    \\  {"Id":"2222222222223333333333334444444444445555555555556666777777778888","Names":["/batch-job"],"Image":"busybox:1.36","State":"exited","Status":"Exited (0)","Created":1763090000}
                    \\]
                ;
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n");
                try docker_logs.writeChunkedBody(&w.interface, body, 48);
                try w.interface.flush();
                return;
            }

            if (std.mem.indexOf(u8, first_line, "/containers/111111111111") != null) {
                _ = ctx.logs_hits.fetchAdd(1, .acq_rel);
                var mux: std.ArrayList(u8) = .empty;
                defer mux.deinit(alloc);
                try docker_logs.appendDockerMuxFrame(alloc, &mux, 1, "2026-11-14T04:00:01.000000000Z {\"msg\":\"hello_line_1\"}\n");
                try docker_logs.appendDockerMuxFrame(alloc, &mux, 2, "2026-11-14T04:00:02.000000000Z [STDERR] warn_line_2\n");
                try docker_logs.appendDockerMuxFrame(alloc, &mux, 1, "2026-11-14T04:00:03.000000000Z {\"msg\":\"done_line_3\"}\n");

                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\nTransfer-Encoding: chunked\r\n\r\n");
                try docker_logs.writeChunkedBody(&w.interface, mux.items, 31);
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

    // 1. Register auto-discovered Docker source (`path = ""` -> `"auto"`, `name` -> `"docker"`, `time_format` -> `"auto"`)
    {
        var reg = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg.deinit(io);
        reg.docker_host = sock_rel_path;

        try reg.upsertSource(arena, io, .{
            .kind = "docker",
            .name = "",
            .config = .{ .path = "" },
            .enabled = true,
        });

        // Non-existent container filter must fail validation
        try std.testing.expectError(
            error.DockerUnavailable,
            reg.upsertSource(arena, io, .{
                .kind = "docker",
                .name = "",
                .config = .{ .path = "auto::missing-container" },
                .enabled = true,
            }),
        );

        // Single-container endpoint derives container name (`"web-api"`)
        try reg.upsertSource(arena, io, .{
            .kind = "docker",
            .name = "",
            .config = .{ .path = "auto::web-api" },
            .enabled = true,
        });

        const snap = try reg.snapshotAllSources(arena, io);
        try std.testing.expectEqual(@as(usize, 2), snap.len);
        try std.testing.expectEqualStrings("docker", snap[0].kind);
        try std.testing.expectEqualStrings("docker", snap[0].name);
        try std.testing.expectEqualStrings("auto", snap[0].path);
        try std.testing.expectEqualStrings("auto", snap[0].time_format);

        try std.testing.expectEqualStrings("docker", snap[1].kind);
        try std.testing.expectEqualStrings("web-api", snap[1].name);
        try std.testing.expectEqualStrings("auto::web-api", snap[1].path);

        // Live `/api/sources` JSON summary populates 1.5s Docker discovery cache
        const ping_before_summary = mock.ping_hits.load(.acquire);
        const list_before_summary = mock.list_hits.load(.acquire);
        const sources_json = try reg.buildSourcesJson(arena, io);
        try std.testing.expect(std.mem.indexOf(u8, sources_json, "\"kind\":\"docker\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, sources_json, "\"ready\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, sources_json, "2 containers (1 running)") != null);
        const list_after_summary = mock.list_hits.load(.acquire);
        const ping_after_summary = mock.ping_hits.load(.acquire);
        try std.testing.expectEqual(list_before_summary + 1, list_after_summary);
        try std.testing.expect(ping_after_summary >= ping_before_summary);

        // Autocomplete (`/api/sources/complete?kind=docker`) & cached previews reuse the 1.5s discovery slot (0 extra `/containers/json` or `/_ping` calls!)
        const suggest_all = try reg.buildSourceCompletionJson(arena, io, "docker", "");
        try std.testing.expect(std.mem.indexOf(u8, suggest_all, "\"path\":\"auto\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, suggest_all, "\"path\":\"auto::web-api\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, suggest_all, "\"path\":\"auto::batch-job\"") != null);

        const suggest_filtered = try reg.buildSourceCompletionJson(arena, io, "docker", "auto::web");
        try std.testing.expect(std.mem.indexOf(u8, suggest_filtered, "\"path\":\"auto::web-api\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, suggest_filtered, "batch-job") == null);

        // Zero-disk-landing `/api/file` line preview (`context = 0` vs `context = 1`)
        const logs_before_preview = mock.logs_hits.load(.acquire);
        const p_single = try reg.buildLinePreviewJson(arena, io, "docker/web-api", 2, 0);
        try std.testing.expect(std.mem.indexOf(u8, p_single, "warn_line_2") != null);
        try std.testing.expect(std.mem.indexOf(u8, p_single, "hello_line_1") == null);
        try std.testing.expect(std.mem.indexOf(u8, p_single, "done_line_3") == null);

        const p_window = try reg.buildLinePreviewJson(arena, io, "docker/web-api", 2, 1);
        try std.testing.expect(std.mem.indexOf(u8, p_window, "hello_line_1") != null);
        try std.testing.expect(std.mem.indexOf(u8, p_window, "warn_line_2") != null);
        try std.testing.expect(std.mem.indexOf(u8, p_window, "done_line_3") != null);
        try std.testing.expectEqual(ping_after_summary, mock.ping_hits.load(.acquire));
        try std.testing.expectEqual(list_after_summary, mock.list_hits.load(.acquire));
        try std.testing.expectEqual(logs_before_preview + 2, mock.logs_hits.load(.acquire));

        // Cache invalidation on mutation (`toggleSource` clears discovery slots + auto transport -> `buildSourcesJson` re-probes once),
        // while `listDockerFreshForSearchAlloc` fetches fresh `/containers/json` reusing `cached_auto` (`ping_hits` stays unchanged!)
        try reg.toggleSource(io, .{ .id = snap[1].id, .enabled = false });
        _ = try reg.buildSourcesJson(arena, io);
        try std.testing.expectEqual(ping_after_summary + 1, mock.ping_hits.load(.acquire));
        try std.testing.expectEqual(list_after_summary + 1, mock.list_hits.load(.acquire));

        const fresh_res = try reg.listDockerFreshForSearchAlloc(arena, io, "auto");
        try std.testing.expectEqual(@as(usize, 2), fresh_res.containers.len);
        try std.testing.expectEqual(ping_after_summary + 1, mock.ping_hits.load(.acquire));
        try std.testing.expectEqual(list_after_summary + 2, mock.list_hits.load(.acquire));
        try reg.toggleSource(io, .{ .id = snap[1].id, .enabled = true });

        // Path traversal & archive `::` separator rejection on Docker paths
        try std.testing.expectError(error.InvalidPath, reg.buildLinePreviewJson(arena, io, "docker/../etc/passwd", 1, 0));
        try std.testing.expectError(error.InvalidPath, reg.buildLinePreviewJson(arena, io, "docker/web-api::inner", 1, 0));
        try std.testing.expectError(error.FileNotFound, reg.buildLinePreviewJson(arena, io, "docker/no-such-ctr", 1, 0));
    }

    // 2. Reload from disk (`sources.json`) and verify only lightweight metadata persisted (zero container log files)
    {
        var reg2 = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg2.deinit(io);
        reg2.docker_host = sock_rel_path;

        const snap = try reg2.snapshotAllSources(arena, io);
        try std.testing.expectEqual(@as(usize, 2), snap.len);
        try std.testing.expectEqualStrings("docker", snap[0].kind);
        try std.testing.expectEqualStrings("auto", snap[0].path);
        try std.testing.expectEqualStrings("auto", snap[0].time_format);

        // 3. Explicit `timeFormat: ""` (`mtime` mode) via top-level `req.timeFormat` alongside `req.config`
        // AND offline metadata editing (`docker_host` pointing to a dead socket) must both round-trip cleanly!
        reg2.docker_host = "unix:///nonexistent/offline-docker.sock";
        try reg2.upsertSource(arena, io, .{
            .id = snap[0].id,
            .kind = "docker",
            .name = "docker-mtime",
            .config = .{ .path = "", .endpoint = "auto" },
            .timeFormat = "",
            .enabled = true,
        });

        const mtime_json = try reg2.buildSourcesJson(arena, io);
        // Must serialize `"timeFormat":""` (NOT `null`) so frontend `isContentTimeSource` agrees on `mtime`!
        try std.testing.expect(std.mem.indexOf(u8, mtime_json, "\"timeFormat\":\"\"") != null);
    }

    // 4. Reload again from disk (`sources.json`) and verify explicit `""` (`mtime`) survived reload while
    // untouched `snap[1]` (`"auto::web-api"`) retained `"auto"`.
    {
        var reg3 = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg3.deinit(io);
        const snap3 = try reg3.snapshotAllSources(arena, io);
        try std.testing.expectEqual(@as(usize, 2), snap3.len);
        try std.testing.expectEqualStrings("docker-mtime", snap3[0].name);
        try std.testing.expectEqualStrings("", snap3[0].time_format);
        try std.testing.expectEqualStrings("auto", snap3[1].time_format);
    }
}
