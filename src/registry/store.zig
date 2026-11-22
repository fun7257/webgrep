const std = @import("std");
const file_api = @import("../file_api.zig");
const prefilter = @import("../prefilter.zig");
const search_cache = @import("../search_cache.zig");
const types = @import("types.zig");
const preview = @import("preview.zig");
const suggest = @import("suggest.zig");

const PluginsOverrideDto = types.PluginsOverrideDto;
const SourceConfigDto = types.SourceConfigDto;
const SourceInfoDto = types.SourceInfoDto;
const SourcesResponse = types.SourcesResponse;
const SearchableSource = types.SearchableSource;
const UpsertSourceRequest = types.UpsertSourceRequest;
const ToggleSourceRequest = types.ToggleSourceRequest;
const DeleteSourceRequest = types.DeleteSourceRequest;
const PersistedSource = types.PersistedSource;
const PersistedFile = types.PersistedFile;
const SourceRecord = types.SourceRecord;
const RegistryError = types.RegistryError;
const freeStringList = types.freeStringList;
const normalizePluginPresetStrict = types.normalizePluginPresetStrict;
const clonePluginIdsAlloc = types.clonePluginIdsAlloc;
const makePluginsOverrideDtoFromConst = types.makePluginsOverrideDtoFromConst;
const makePluginsOverrideDtoFromOwned = types.makePluginsOverrideDtoFromOwned;
const generateUuidV4Alloc = types.generateUuidV4Alloc;
const isValidUuid = types.isValidUuid;
const sanitizeNameAlloc = types.sanitizeNameAlloc;

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
        reg.search_cache.initSketchStore(gpa, io, data_root_path);
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
            const eff_kind_str = if (ps.kind.len > 0) ps.kind else "dir";
            if (!std.mem.eql(u8, eff_kind_str, "dir") and !std.mem.eql(u8, eff_kind_str, "file")) {
                migrated_uuid = true;
                continue;
            }
            const eff_path = resolveConfigPath(ps.config, ps.path);

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
            const maybe_cfg_tf: ?[]const u8 = if (ps.config) |cfg| cfg.timeFormat else null;
            const raw_tf = maybe_cfg_tf orelse "";
            const trimmed_tf = std.mem.trim(u8, raw_tf[0..@min(raw_tf.len, 256)], " \t\r\n");
            const tf_copy = try self.gpa.dupe(u8, trimmed_tf);
            errdefer self.gpa.free(tf_copy);

            const maybe_cfg_preset: ?[]const u8 = (if (ps.config) |cfg| cfg.pluginPreset else null) orelse ps.pluginPreset;
            const parsed_preset = prefilter.Preset.parse(maybe_cfg_preset orelse "timeseries").asStr();
            if (maybe_cfg_preset) |raw_p| {
                if (!std.mem.eql(u8, raw_p, parsed_preset)) migrated_uuid = true;
            }
            const preset_copy = try self.gpa.dupe(u8, parsed_preset);
            errdefer self.gpa.free(preset_copy);

            const maybe_cfg_plugins: ?PluginsOverrideDto = (if (ps.config) |cfg| cfg.plugins else null) orelse ps.plugins;
            const en_copy = try clonePluginIdsAlloc(self.gpa, if (maybe_cfg_plugins) |ov| ov.enable else null, false);
            errdefer freeStringList(self.gpa, en_copy);
            const dis_copy = try clonePluginIdsAlloc(self.gpa, if (maybe_cfg_plugins) |ov| ov.disable else null, false);
            errdefer freeStringList(self.gpa, dis_copy);

            try self.sources.append(self.gpa, .{
                .id = id_copy,
                .kind = kind_copy,
                .name = name_copy,
                .path = path_copy,
                .enabled = ps.enabled,
                .time_format = tf_copy,
                .plugin_preset = preset_copy,
                .plugins_enable = en_copy,
                .plugins_disable = dis_copy,
            });
        }

        if (migrated_uuid) {
            self.saveToDiskLocked(io) catch {};
        }
    }

    fn resolveConfigPath(cfg_opt: ?SourceConfigDto, top_path: []const u8) []const u8 {
        if (cfg_opt) |cfg| {
            if (cfg.path.len > 0) return cfg.path;
        }
        return top_path;
    }

    fn serializedSourceTimeFormat(_: []const u8, tf: []const u8) ?[]const u8 {
        if (tf.len > 0) return tf;
        return null;
    }

    fn saveToDiskLocked(self: *const SourceRegistry, io: std.Io) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var persisted_list: std.ArrayList(PersistedSource) = .empty;
        try persisted_list.ensureTotalCapacity(arena, self.sources.items.len);

        for (self.sources.items) |src| {
            const ov_dto = try makePluginsOverrideDtoFromOwned(arena, src.plugins_enable, src.plugins_disable);
            persisted_list.appendAssumeCapacity(.{
                .id = src.id,
                .kind = src.kind,
                .name = src.name,
                .path = src.path,
                .config = .{
                    .path = src.path,
                    .timeFormat = serializedSourceTimeFormat(src.kind, src.time_format),
                    .pluginPreset = src.plugin_preset,
                    .plugins = ov_dto,
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

        const maybe_req_preset: ?[]const u8 = (if (req.config) |cfg| cfg.pluginPreset else null) orelse req.pluginPreset;
        const validated_req_preset = try normalizePluginPresetStrict(maybe_req_preset);
        const maybe_req_plugins: ?PluginsOverrideDto = (if (req.config) |cfg| cfg.plugins else null) orelse req.plugins;
        if (maybe_req_plugins) |ov| {
            // Validate plugin IDs early before mutating any registry state.
            const en_check = try clonePluginIdsAlloc(arena, ov.enable, true);
            _ = en_check;
            const dis_check = try clonePluginIdsAlloc(arena, ov.disable, true);
            _ = dis_check;
        }

        const raw_path = resolveConfigPath(req.config, req.path);
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
            errdefer if (next_tf) |tf| self.gpa.free(tf);
            const next_preset: ?[]u8 = if (validated_req_preset) |ps| try self.gpa.dupe(u8, ps) else null;
            errdefer if (next_preset) |ps| self.gpa.free(ps);
            const next_en: ?[][]u8 = if (maybe_req_plugins) |ov| try clonePluginIdsAlloc(self.gpa, ov.enable, true) else null;
            errdefer if (next_en) |en| freeStringList(self.gpa, en);
            const next_dis: ?[][]u8 = if (maybe_req_plugins) |ov| try clonePluginIdsAlloc(self.gpa, ov.disable, true) else null;
            errdefer if (next_dis) |dis| freeStringList(self.gpa, dis);

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
            if (next_preset) |ps| {
                self.gpa.free(rec.plugin_preset);
                rec.plugin_preset = ps;
            }
            if (next_en) |en| {
                freeStringList(self.gpa, rec.plugins_enable);
                rec.plugins_enable = en;
            }
            if (next_dis) |dis| {
                freeStringList(self.gpa, rec.plugins_disable);
                rec.plugins_disable = dis;
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
            const next_tf = try self.gpa.dupe(u8, capped_req_tf orelse "");
            errdefer self.gpa.free(next_tf);
            const next_preset = try self.gpa.dupe(u8, validated_req_preset orelse "timeseries");
            errdefer self.gpa.free(next_preset);
            const next_en = try clonePluginIdsAlloc(self.gpa, if (maybe_req_plugins) |ov| ov.enable else null, true);
            errdefer freeStringList(self.gpa, next_en);
            const next_dis = try clonePluginIdsAlloc(self.gpa, if (maybe_req_plugins) |ov| ov.disable else null, true);
            errdefer freeStringList(self.gpa, next_dis);

            try self.sources.append(self.gpa, .{
                .id = new_id,
                .kind = next_kind,
                .name = next_name,
                .path = next_path,
                .enabled = req.enabled,
                .time_format = next_tf,
                .plugin_preset = next_preset,
                .plugins_enable = next_en,
                .plugins_disable = next_dis,
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
            const summary_text: []const u8 = src.path;

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

            const ov_dto = makePluginsOverrideDtoFromConst(src.plugins_enable, src.plugins_disable);
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
                    .pluginPreset = src.plugin_preset,
                    .plugins = ov_dto,
                },
                .path = src.path,
                .exists = ready,
                .pluginPreset = src.plugin_preset,
                .plugins = ov_dto,
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
            const en_slice = try arena.alloc([]const u8, s.plugins_enable.len);
            for (s.plugins_enable, 0..) |it, i| en_slice[i] = try arena.dupe(u8, it);
            const dis_slice = try arena.alloc([]const u8, s.plugins_disable.len);
            for (s.plugins_disable, 0..) |it, i| dis_slice[i] = try arena.dupe(u8, it);
            const chain = prefilter.resolvePluginChainFromNames(s.plugin_preset, en_slice, dis_slice);
            out.appendAssumeCapacity(.{
                .id = try arena.dupe(u8, s.id),
                .kind = try arena.dupe(u8, s.kind),
                .name = try arena.dupe(u8, s.name),
                .path = try arena.dupe(u8, s.path),
                .enabled = s.enabled,
                .time_format = try arena.dupe(u8, s.time_format),
                .plugin_preset = try arena.dupe(u8, s.plugin_preset),
                .plugins_enable = en_slice,
                .plugins_disable = dis_slice,
                .plugin_sig = chain.signature,
            });
        }
        return out.toOwnedSlice(arena);
    }

    // --- Delegated line preview methods ---
    pub fn buildLinePreviewJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_virtual_path: []const u8,
        line: u64,
        context: u32,
    ) ![]u8 {
        return preview.buildLinePreviewJson(self, arena, io, raw_virtual_path, line, context);
    }
    pub fn buildLinePreviewWindowJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_virtual_path: []const u8,
        query: file_api.FileWindowQuery,
    ) ![]u8 {
        return preview.buildLinePreviewWindowJson(self, arena, io, raw_virtual_path, query);
    }

    // --- Delegated source completion / suggestion methods ---
    pub fn buildSourceCompletionJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        kind_raw: []const u8,
        raw_input: []const u8,
    ) ![]u8 {
        return suggest.buildSourceCompletionJson(self, arena, io, kind_raw, raw_input);
    }
    pub fn buildDirSuggestionsJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_input: []const u8,
    ) ![]u8 {
        return suggest.buildDirSuggestionsJson(self, arena, io, raw_input);
    }
    pub fn buildPathSuggestionsJson(
        self: *SourceRegistry,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_input: []const u8,
        include_files: bool,
    ) ![]u8 {
        return suggest.buildPathSuggestionsJson(self, arena, io, raw_input, include_files);
    }
};
