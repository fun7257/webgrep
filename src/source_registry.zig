const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("file_api.zig");
const search_cache = @import("search_cache.zig");

pub const SourceConfigDto = struct {
    path: []const u8 = "",
    endpoint: ?[]const u8 = null,
};

pub const SourceKindMetaDto = struct {
    kind: []const u8,
    label: []const u8,
};

pub const builtin_source_kinds = [_]SourceKindMetaDto{
    .{ .kind = "dir", .label = "Local Directory" },
    .{ .kind = "file", .label = "Single File" },
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
};

pub const UpsertSourceRequest = struct {
    id: ?[]const u8 = null,
    kind: []const u8 = "dir",
    name: []const u8 = "",
    path: []const u8 = "",
    config: ?SourceConfigDto = null,
    enabled: bool = true,
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

    fn deinit(self: *SourceRecord, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.kind);
        gpa.free(self.name);
        gpa.free(self.path);
    }
};

pub const RegistryError = error{
    UnsupportedSourceKind,
    EmptyPath,
    DirectoryNotFound,
    FileNotFound,
    ExpectedDirFoundFile,
    ExpectedFileFoundDir,
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

pub const SourceRegistry = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    data_root_path: []const u8,
    home_dir: ?[]const u8 = null,
    sources: std.ArrayList(SourceRecord) = .empty,
    search_count: std.atomic.Value(u64) = .init(0),
    heat_epoch: std.atomic.Value(u64) = .init(0),
    file_heat: std.StringHashMapUnmanaged(u64) = .empty,
    search_cache: search_cache.SearchCache = .{},

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

    pub fn deinit(self: *SourceRegistry, io: std.Io) void {
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
            const eff_path = if (ps.config) |cfg|
                (if (cfg.path.len > 0) cfg.path else ps.path)
            else
                ps.path;

            if (eff_path.len == 0 or ps.name.len == 0) continue;

            const id_copy = if (isValidUuid(ps.id))
                try self.gpa.dupe(u8, ps.id)
            else blk: {
                migrated_uuid = true;
                break :blk try generateUuidV4Alloc(self.gpa, io);
            };
            errdefer self.gpa.free(id_copy);

            const kind_copy = try self.gpa.dupe(u8, if (ps.kind.len > 0) ps.kind else "dir");
            errdefer self.gpa.free(kind_copy);
            const name_copy = try self.gpa.dupe(u8, ps.name);
            errdefer self.gpa.free(name_copy);
            const path_copy = try self.gpa.dupe(u8, eff_path);
            errdefer self.gpa.free(path_copy);

            try self.sources.append(self.gpa, .{
                .id = id_copy,
                .kind = kind_copy,
                .name = name_copy,
                .path = path_copy,
                .enabled = ps.enabled,
            });
        }

        if (migrated_uuid) {
            self.saveToDiskLocked(io) catch {};
        }
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
        if (!std.mem.eql(u8, eff_kind, "dir") and !is_file_kind) {
            return error.UnsupportedSourceKind;
        }

        const raw_path = if (req.config) |cfg|
            (if (cfg.path.len > 0) cfg.path else req.path)
        else
            req.path;

        const expanded_path = try self.expandTildeAlloc(arena, raw_path);
        if (expanded_path.len == 0) return error.EmptyPath;

        var real_path: []const u8 = expanded_path;

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

        const fallback_name = blk: {
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
                if (std.mem.eql(u8, s.path, real_path)) {
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

        if (target_idx) |idx| {
            var rec = &self.sources.items[idx];
            const next_kind = try self.gpa.dupe(u8, eff_kind);
            errdefer self.gpa.free(next_kind);
            const next_name = try self.gpa.dupe(u8, unique_name);
            errdefer self.gpa.free(next_name);
            const next_path = try self.gpa.dupe(u8, real_path);
            errdefer self.gpa.free(next_path);

            self.gpa.free(rec.kind);
            self.gpa.free(rec.name);
            self.gpa.free(rec.path);

            rec.kind = next_kind;
            rec.name = next_name;
            rec.path = next_path;
            rec.enabled = req.enabled;
        } else {
            const new_id = try generateUuidV4Alloc(self.gpa, io);
            errdefer self.gpa.free(new_id);
            const next_kind = try self.gpa.dupe(u8, eff_kind);
            errdefer self.gpa.free(next_kind);
            const next_name = try self.gpa.dupe(u8, unique_name);
            errdefer self.gpa.free(next_name);
            const next_path = try self.gpa.dupe(u8, real_path);
            errdefer self.gpa.free(next_path);

            try self.sources.append(self.gpa, .{
                .id = new_id,
                .kind = next_kind,
                .name = next_name,
                .path = next_path,
                .enabled = req.enabled,
            });
        }

        try self.saveToDiskLocked(io);
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

            try dto_list.append(arena, .{
                .id = src.id,
                .kind = src.kind,
                .name = src.name,
                .enabled = src.enabled,
                .ready = ready,
                .summary = src.path,
                .config = .{
                    .path = src.path,
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
            });
        }
        return out.toOwnedSlice(arena);
    }

    /// Resolves `<source_name>/<rel_path>` and returns a JSON line preview for InspectorPane.
    pub fn buildLinePreviewJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        virtual_path_raw: []const u8,
        target_line_raw: u64,
        context_raw: u64,
    ) ![]u8 {
        const clean_vpath = try file_api.sanitizeRelPath(virtual_path_raw);
        if (clean_vpath.len == 0) return error.InvalidPath;

        // Boost access heat whenever a user inspects a record from this file
        self.recordFileHeat(io, clean_vpath, 150);

        const slash_idx = std.mem.indexOfScalar(u8, clean_vpath, '/') orelse return error.InvalidPath;
        const source_name = clean_vpath[0..slash_idx];
        const inner_rel = clean_vpath[slash_idx + 1 ..];
        if (source_name.len == 0 or inner_rel.len == 0) return error.InvalidPath;

        var matched_path: ?[]const u8 = null;
        var matched_kind: []const u8 = "dir";
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            for (self.sources.items) |s| {
                if (std.ascii.eqlIgnoreCase(s.name, source_name) or std.ascii.eqlIgnoreCase(s.id, source_name)) {
                    matched_path = try arena.dupe(u8, s.path);
                    matched_kind = try arena.dupe(u8, s.kind);
                    break;
                }
            }
        }

        const src_path = matched_path orelse return error.FileNotFound;
        if (!std.mem.eql(u8, matched_kind, "file")) {
            if (std.Io.Dir.cwd().openDir(io, src_path, .{})) |source_dir_val| {
                var source_dir = source_dir_val;
                defer source_dir.close(io);
                return file_api.buildFileJsonWithDisplayPath(
                    arena,
                    io,
                    source_dir,
                    inner_rel,
                    clean_vpath,
                    target_line_raw,
                    context_raw,
                );
            } else |_| {}
        }

        // Single-file source: open its parent directory and read `basename(src_path)`
        const parent_path = std.fs.path.dirname(src_path) orelse ".";
        const file_base = std.fs.path.basename(src_path);
        if (file_base.len == 0) return error.FileNotFound;

        var parent_dir = try std.Io.Dir.cwd().openDir(io, parent_path, .{});
        defer parent_dir.close(io);

        return file_api.buildFileJsonWithDisplayPath(
            arena,
            io,
            parent_dir,
            file_base,
            clean_vpath,
            target_line_raw,
            context_raw,
        );
    }

    /// Generic source driver completion endpoint (`/api/sources/complete?kind=dir|file&q=...`).
    pub fn buildSourceCompletionJson(
        self: *const SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        kind: []const u8,
        raw_query: []const u8,
    ) ![]u8 {
        const eff_kind = if (kind.len == 0) "dir" else kind;
        if (!std.mem.eql(u8, eff_kind, "dir") and !std.mem.eql(u8, eff_kind, "file")) {
            return file_api.stringifyAlloc(arena, DirSuggestResponse{
                .kind = eff_kind,
                .entries = &.{},
            });
        }
        return self.buildPathSuggestionsJson(arena, io, eff_kind, raw_query);
    }

    /// Provides server filesystem directory autocomplete (`kind == "dir"`).
    pub fn buildDirSuggestionsJson(
        self: *const SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_query: []const u8,
    ) ![]u8 {
        return self.buildPathSuggestionsJson(arena, io, "dir", raw_query);
    }

    /// Provides server filesystem path autocomplete tailored to the selected `kind` (`"dir"` or `"file"`).
    pub fn buildPathSuggestionsJson(
        self: *const SourceRegistry,
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
    }
}
