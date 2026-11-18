const std = @import("std");

pub const path_scope = @import("plugins/path_scope.zig");
pub const mtime_guard = @import("plugins/mtime_guard.zig");
pub const filename_date = @import("plugins/filename_date.zig");
pub const sidecar_sketch = @import("plugins/sidecar_sketch.zig");
pub const time_bisect = @import("plugins/time_bisect.zig");
pub const line_time = @import("plugins/line_time.zig");

pub const MAX_PLUGINS: usize = 16;

pub const PluginId = enum(u4) {
    path_scope = 0,
    mtime_guard = 1,
    mtime_window = 2,
    filename_date = 3,
    sidecar_sketch = 4,
    time_bisect = 5,
    line_time = 6,

    pub fn asStr(self: PluginId) []const u8 {
        return switch (self) {
            .path_scope => "path_scope",
            .mtime_guard => "mtime_guard",
            .mtime_window => "mtime_window",
            .filename_date => "filename_date",
            .sidecar_sketch => "sidecar_sketch",
            .time_bisect => "time_bisect",
            .line_time => "line_time",
        };
    }

    pub fn parse(raw: []const u8) ?PluginId {
        const s = std.mem.trim(u8, raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(s, "path_scope")) return .path_scope;
        if (std.ascii.eqlIgnoreCase(s, "mtime_guard")) return .mtime_guard;
        if (std.ascii.eqlIgnoreCase(s, "mtime_window")) return .mtime_window;
        if (std.ascii.eqlIgnoreCase(s, "filename_date")) return .filename_date;
        if (std.ascii.eqlIgnoreCase(s, "sidecar_sketch")) return .sidecar_sketch;
        if (std.ascii.eqlIgnoreCase(s, "time_bisect")) return .time_bisect;
        if (std.ascii.eqlIgnoreCase(s, "line_time")) return .line_time;
        return null;
    }

    pub inline fn bit(self: PluginId) u32 {
        return @as(u32, 1) << @intFromEnum(self);
    }
};

pub const Stage = enum {
    source_plan,
    file_prune,
    window_narrow,
    line_filter,

    pub fn asStr(self: Stage) []const u8 {
        return switch (self) {
            .source_plan => "source_plan",
            .file_prune => "file_prune",
            .window_narrow => "window_narrow",
            .line_filter => "line_filter",
        };
    }
};

pub const Verdict = enum {
    keep,
    skip,
    needs_window,
};

pub const Preset = enum {
    auto,
    timeseries,
    code,
    raw,

    pub fn parse(raw_str: []const u8) Preset {
        return parseStrict(raw_str) orelse .auto;
    }

    pub fn parseStrict(raw_str: []const u8) ?Preset {
        const s = std.mem.trim(u8, raw_str, " \t\r\n");
        if (s.len == 0 or std.ascii.eqlIgnoreCase(s, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(s, "timeseries")) return .timeseries;
        if (std.ascii.eqlIgnoreCase(s, "code")) return .code;
        if (std.ascii.eqlIgnoreCase(s, "raw")) return .raw;
        return null;
    }

    pub fn asStr(self: Preset) []const u8 {
        return switch (self) {
            .auto => "auto",
            .timeseries => "timeseries",
            .code => "code",
            .raw => "raw",
        };
    }
};

pub const SourceKind = enum {
    dir,
    file,
    docker,
    archive,
    unknown,

    pub fn parse(raw_str: []const u8) SourceKind {
        const s = std.mem.trim(u8, raw_str, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(s, "dir")) return .dir;
        if (std.ascii.eqlIgnoreCase(s, "file")) return .file;
        if (std.ascii.eqlIgnoreCase(s, "docker")) return .docker;
        if (std.ascii.eqlIgnoreCase(s, "archive")) return .archive;
        return .unknown;
    }

    pub fn asStr(self: SourceKind) []const u8 {
        return switch (self) {
            .dir => "dir",
            .file => "file",
            .docker => "docker",
            .archive => "archive",
            .unknown => "unknown",
        };
    }
};

pub const TimeFilterMode = enum {
    auto,
    source,
    content,
    mtime,

    pub fn parse(raw_str: []const u8) TimeFilterMode {
        const s = std.mem.trim(u8, raw_str, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(s, "source")) return .source;
        if (std.ascii.eqlIgnoreCase(s, "content")) return .content;
        if (std.ascii.eqlIgnoreCase(s, "mtime")) return .mtime;
        return .auto;
    }
};

pub const KvOp = enum {
    eq,
    neq,
    contains,
    gt_num,
    lt_num,
    exists,

    pub fn parse(raw_str: []const u8) ?KvOp {
        const s = std.mem.trim(u8, raw_str, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(s, "eq") or std.mem.eql(u8, s, "=") or std.mem.eql(u8, s, "==")) return .eq;
        if (std.ascii.eqlIgnoreCase(s, "neq") or std.mem.eql(u8, s, "!=")) return .neq;
        if (std.ascii.eqlIgnoreCase(s, "contains") or std.mem.eql(u8, s, "~")) return .contains;
        if (std.ascii.eqlIgnoreCase(s, "gt_num") or std.mem.eql(u8, s, ">")) return .gt_num;
        if (std.ascii.eqlIgnoreCase(s, "lt_num") or std.mem.eql(u8, s, "<")) return .lt_num;
        if (std.ascii.eqlIgnoreCase(s, "exists")) return .exists;
        return null;
    }

    pub fn asStr(self: KvOp) []const u8 {
        return switch (self) {
            .eq => "eq",
            .neq => "neq",
            .contains => "contains",
            .gt_num => "gt_num",
            .lt_num => "lt_num",
            .exists => "exists",
        };
    }
};

pub const KvPredicate = struct {
    key: []const u8,
    op: KvOp = .eq,
    value: []const u8 = "",
    num_value: ?f64 = null,
    case_sensitive: bool = false,
};

pub const QueryPredicates = struct {
    time_start_ns: u64 = 0,
    time_end_ns: u64 = 0,
    tz_offset_min: i16 = 0,
    now_epoch_ms: u64 = 0,
    skew_tolerance_ns: u64 = 5 * std.time.ns_per_s,
    bisect_slop_ns: u64 = 5 * std.time.ns_per_s,
    source_kind: SourceKind = .dir,
    time_mode: TimeFilterMode = .auto,
    preset: Preset = .auto,
    custom_plugin_mask: ?u32 = null,
    enabled_overrides: []const PluginId = &.{},
    disabled_overrides: []const PluginId = &.{},
    include_globs: []const []const u8 = &.{},
    exclude_globs: []const []const u8 = &.{},
    file_types: []const []const u8 = &.{},
    exclude_file_types: []const []const u8 = &.{},
    literal_anchors: []const []const u8 = &.{},
    anchors_case_insensitive: bool = true,
    anchor_case_flags: []const bool = &.{},
    kv_predicates: []const KvPredicate = &.{},
    /// When false (e.g. `timeMode == "content"`), `.auto` must NOT fall back to mtime on `unparsed_no_ts`.
    allow_mtime_fallback_on_no_ts: bool = true,
    /// When true, untimestamped standalone lines inside files are dropped rather than inheriting mtime.
    strict_content_time: bool = false,

    pub fn hasTimeRange(self: QueryPredicates) bool {
        return self.time_start_ns > 0 or self.time_end_ns > 0;
    }

    pub fn fallbackEpochNs(self: QueryPredicates, meta: FileMeta) i96 {
        if (meta.mtime_ns > 0) return meta.mtime_ns;
        if (self.now_epoch_ms > 0) return @as(i96, self.now_epoch_ms) * std.time.ns_per_ms;
        return 0;
    }
};

pub const FileMeta = struct {
    rel_path: []const u8,
    abs_path: []const u8 = "",
    base_name: []const u8 = "",
    size_bytes: u64 = 0,
    mtime_ns: i96 = 0,
    ctime_ns: i96 = 0,
    inode: u64 = 0,
    dev: u64 = 0,
    is_archive_entry: bool = false,
    is_archive_container: bool = false,
    is_compressed: bool = false,
    has_custom_time_format: bool = false,

    pub fn effectiveBaseName(self: FileMeta) []const u8 {
        if (self.base_name.len > 0) return self.base_name;
        return std.fs.path.basename(self.rel_path);
    }
};

pub const PositionalReader = struct {
    ctx: *anyopaque,
    size: u64,
    readAtFn: *const fn (ctx: *anyopaque, offset: u64, buf: []u8) anyerror!usize,

    pub fn readAt(self: PositionalReader, offset: u64, buf: []u8) !usize {
        if (offset >= self.size or buf.len == 0) return 0;
        const cap: usize = @intCast(@min(@as(u64, buf.len), self.size - offset));
        return self.readAtFn(self.ctx, offset, buf[0..cap]);
    }

    pub fn readAllAt(self: PositionalReader, offset: u64, buf: []u8) !usize {
        if (offset >= self.size or buf.len == 0) return 0;
        const target: usize = @intCast(@min(@as(u64, buf.len), self.size - offset));
        var total: usize = 0;
        while (total < target) {
            const n = try self.readAtFn(self.ctx, offset + total, buf[total..target]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    pub const SliceCtx = struct {
        data: []const u8,
        read_calls: usize = 0,
        bytes_read: u64 = 0,

        pub fn reader(self: *SliceCtx) PositionalReader {
            return .{
                .ctx = self,
                .size = self.data.len,
                .readAtFn = readFn,
            };
        }

        fn readFn(raw: *anyopaque, offset: u64, buf: []u8) anyerror!usize {
            const s: *SliceCtx = @ptrCast(@alignCast(raw));
            s.read_calls += 1;
            if (offset >= s.data.len) return 0;
            const off: usize = @intCast(offset);
            const n = @min(buf.len, s.data.len - off);
            @memcpy(buf[0..n], s.data[off .. off + n]);
            s.bytes_read += n;
            return n;
        }
    };
};

pub const WindowStatus = enum {
    empty_skip,
    narrowed,
    full_scan,
    unparsed_no_ts,
};

pub const WindowSlice = struct {
    start_byte: u64 = 0,
    end_byte: u64 = 0,
    base_line_offset: u64 = 0,
    status: WindowStatus = .full_scan,
    sticky_format_id: ?u32 = null,
    tail_ts_ns: ?u64 = null,
    head_ts_ns: ?u64 = null,

    pub fn byteLen(self: WindowSlice) u64 {
        if (self.end_byte <= self.start_byte) return 0;
        return self.end_byte - self.start_byte;
    }
};

pub const LineStats = struct {
    lines_seen: u64 = 0,
    lines_kept: u64 = 0,
    lines_skipped_time: u64 = 0,
    lines_skipped_kv: u64 = 0,
    continuations_inherited: u64 = 0,
    sticky_hits: u64 = 0,
};

pub const LineState = struct {
    sticky_format_id: ?u32 = null,
    prev_ts_ns: ?u64 = null,
    prev_in_range: bool = false,
    prev_is_matched_anchor: bool = false,
    saw_any_timestamp: bool = false,
    observed_min_ts_ns: ?u64 = null,
    observed_max_ts_ns: ?u64 = null,
    stats: LineStats = .{},

    pub fn reset(self: *LineState) void {
        self.* = .{};
    }

    pub fn recordObservedTs(self: *LineState, ts_ns: u64) void {
        self.saw_any_timestamp = true;
        if (self.observed_min_ts_ns) |cur_min| {
            if (ts_ns < cur_min) self.observed_min_ts_ns = ts_ns;
        } else {
            self.observed_min_ts_ns = ts_ns;
        }
        if (self.observed_max_ts_ns) |cur_max| {
            if (ts_ns > cur_max) self.observed_max_ts_ns = ts_ns;
        } else {
            self.observed_max_ts_ns = ts_ns;
        }
    }
};

pub const TimeParseResult = struct {
    ts_ns: u64,
    format_id: ?u32 = null,
};

pub const TimeParseFn = *const fn (
    ctx: ?*anyopaque,
    line: []const u8,
    fallback_year: u16,
    fallback_month: u8,
    fallback_day: u8,
    tz_offset_min: i16,
    sticky_format_id: ?u32,
) ?TimeParseResult;

pub const ContinuationCheckFn = *const fn (
    ctx: ?*anyopaque,
    line: []const u8,
) bool;

pub const TimeHooks = struct {
    ctx: ?*anyopaque = null,
    parseLineFn: ?TimeParseFn = null,
    isContinuationFn: ?ContinuationCheckFn = null,
};

pub const PluginMetadata = struct {
    id: PluginId,
    id_str: []const u8,
    name_key: []const u8,
    description: []const u8,
    stages: []const Stage,
    default_presets: []const Preset,
    priority: u16,
    cost_hint: []const u8,
};

pub const PresetMetadata = struct {
    preset: Preset,
    id_str: []const u8,
    name_key: []const u8,
    description: []const u8,
    default_plugins: []const PluginId,
};

pub const PLUGIN_CATALOG = [_]PluginMetadata{
    .{
        .id = .path_scope,
        .id_str = "path_scope",
        .name_key = "plugins.path_scope",
        .description = "Zero-alloc path, extension, and glob pruning before scanning",
        .stages = &.{ .source_plan, .file_prune },
        .default_presets = &.{ .auto, .timeseries, .code, .raw },
        .priority = 10,
        .cost_hint = "O(1) path",
    },
    .{
        .id = .mtime_guard,
        .id_str = "mtime_guard",
        .name_key = "plugins.mtime_guard",
        .description = "Lower-bound mtime guard (mtime < timeStart)",
        .stages = &.{.file_prune},
        .default_presets = &.{ .auto, .timeseries, .code },
        .priority = 20,
        .cost_hint = "O(1) stat",
    },
    .{
        .id = .mtime_window,
        .id_str = "mtime_window",
        .name_key = "plugins.mtime_window",
        .description = "Upper-bound mtime window (active in code; fallback for timestamp-less files in auto)",
        .stages = &.{.file_prune},
        .default_presets = &.{.code},
        .priority = 25,
        .cost_hint = "O(1) stat",
    },
    .{
        .id = .filename_date,
        .id_str = "filename_date",
        .name_key = "plugins.filename_date",
        .description = "Extract rotated filename dates/hours before decompression",
        .stages = &.{.file_prune},
        .default_presets = &.{ .auto, .timeseries },
        .priority = 30,
        .cost_hint = "O(1) name",
    },
    .{
        .id = .sidecar_sketch,
        .id_str = "sidecar_sketch",
        .name_key = "plugins.sidecar_sketch",
        .description = "Observed timestamp bounds & ASCII trigram Bloom sketch in data_dir",
        .stages = &.{.file_prune},
        .default_presets = &.{ .auto, .timeseries, .code },
        .priority = 35,
        .cost_hint = "O(1) bloom",
    },
    .{
        .id = .time_bisect,
        .id_str = "time_bisect",
        .name_key = "plugins.time_bisect",
        .description = "Binary-search byte windows by parsed line timestamps",
        .stages = &.{.window_narrow},
        .default_presets = &.{ .auto, .timeseries },
        .priority = 40,
        .cost_hint = "O(log N) pread",
    },
    .{
        .id = .line_time,
        .id_str = "line_time",
        .name_key = "plugins.line_time",
        .description = "Line timestamp filter, stack-trace continuation binding, and KV pushdown",
        .stages = &.{ .source_plan, .line_filter },
        .default_presets = &.{ .auto, .timeseries, .raw },
        .priority = 50,
        .cost_hint = "O(1) sticky",
    },
};

pub const PRESET_CATALOG = [_]PresetMetadata{
    .{
        .preset = .auto,
        .id_str = "auto",
        .name_key = "prefilter.preset.auto",
        .description = "Safe timestamp probing, filename/sketch pruning; never drops active daily logs",
        .default_plugins = &.{ .path_scope, .mtime_guard, .filename_date, .sidecar_sketch, .time_bisect, .line_time },
    },
    .{
        .preset = .timeseries,
        .id_str = "timeseries",
        .name_key = "prefilter.preset.timeseries",
        .description = "Append logs & time-series (time bisect + filename date + sketch, no mtime upper bound)",
        .default_plugins = &.{ .path_scope, .mtime_guard, .filename_date, .sidecar_sketch, .time_bisect, .line_time },
    },
    .{
        .preset = .code,
        .id_str = "code",
        .name_key = "prefilter.preset.code",
        .description = "Source code & docs (mtime window + path scope + sketch)",
        .default_plugins = &.{ .path_scope, .mtime_guard, .mtime_window, .sidecar_sketch },
    },
    .{
        .preset = .raw,
        .id_str = "raw",
        .name_key = "prefilter.preset.raw",
        .description = "Bypass heuristic prefilters for full raw scan",
        .default_plugins = &.{ .path_scope, .line_time },
    },
};

pub const PluginCatalog = PLUGIN_CATALOG;

pub fn getCatalog() []const PluginMetadata {
    return &PLUGIN_CATALOG;
}

pub fn getPresets() []const PresetMetadata {
    return &PRESET_CATALOG;
}

pub fn defaultPluginMaskForPreset(preset: Preset) u32 {
    var mask: u32 = 0;
    for (PLUGIN_CATALOG) |entry| {
        for (entry.default_presets) |dp| {
            if (dp == preset) {
                mask |= entry.id.bit();
                break;
            }
        }
    }
    return mask;
}

pub const ResolvedPluginChain = struct {
    preset: Preset,
    active_mask: u32,
    plugins: [MAX_PLUGINS]PluginId = undefined,
    len: usize = 0,
    allow_mtime_fallback_on_no_ts: bool = false,
    signature: u64 = 0,

    pub fn slice(self: *const ResolvedPluginChain) []const PluginId {
        return self.plugins[0..self.len];
    }

    pub fn has(self: *const ResolvedPluginChain, id: PluginId) bool {
        return (self.active_mask & id.bit()) != 0;
    }
};

pub fn computePluginSignature(chain: *const ResolvedPluginChain) u64 {
    var hasher = std.hash.Wyhash.init(0x70726566_696c7431);
    const p_byte: [1]u8 = .{@intFromEnum(chain.preset)};
    hasher.update(&p_byte);
    hasher.update(std.mem.asBytes(&chain.active_mask));
    const fb_byte: [1]u8 = .{@intFromBool(chain.allow_mtime_fallback_on_no_ts)};
    hasher.update(&fb_byte);
    return hasher.final();
}

pub fn resolvePluginChain(
    preset: Preset,
    enabled_overrides_opt: ?[]const PluginId,
    disabled_overrides_opt: ?[]const PluginId,
) ResolvedPluginChain {
    var mask = defaultPluginMaskForPreset(preset);
    var allow_fallback = (preset == .auto);

    if (enabled_overrides_opt) |en| {
        for (en) |pid| {
            mask |= pid.bit();
            if (pid == .mtime_window and preset == .auto) {
                allow_fallback = true;
            }
        }
    }

    if (disabled_overrides_opt) |dis| {
        for (dis) |pid| {
            mask &= ~pid.bit();
            if (pid == .mtime_window) {
                allow_fallback = false;
            }
        }
    }

    var chain = ResolvedPluginChain{
        .preset = preset,
        .active_mask = mask,
        .allow_mtime_fallback_on_no_ts = allow_fallback,
    };

    for (PLUGIN_CATALOG) |entry| {
        if ((mask & entry.id.bit()) != 0 and chain.len < MAX_PLUGINS) {
            chain.plugins[chain.len] = entry.id;
            chain.len += 1;
        }
    }
    chain.signature = computePluginSignature(&chain);
    return chain;
}

pub fn resolvePluginChainWithMask(
    preset: Preset,
    explicit_mask: u32,
    allow_mtime_fallback_on_no_ts: bool,
) ResolvedPluginChain {
    var chain = ResolvedPluginChain{
        .preset = preset,
        .active_mask = explicit_mask,
        .allow_mtime_fallback_on_no_ts = allow_mtime_fallback_on_no_ts and ((explicit_mask & PluginId.mtime_window.bit()) == 0 or preset == .auto),
    };
    for (PLUGIN_CATALOG) |entry| {
        if ((explicit_mask & entry.id.bit()) != 0 and chain.len < MAX_PLUGINS) {
            chain.plugins[chain.len] = entry.id;
            chain.len += 1;
        }
    }
    chain.signature = computePluginSignature(&chain);
    return chain;
}

pub fn resolvePluginChainFromNames(
    preset_raw: []const u8,
    enabled_names: []const []const u8,
    disabled_names: []const []const u8,
) ResolvedPluginChain {
    var en_buf: [MAX_PLUGINS]PluginId = undefined;
    var en_len: usize = 0;
    for (enabled_names) |name| {
        if (PluginId.parse(name)) |pid| {
            if (en_len < MAX_PLUGINS) {
                en_buf[en_len] = pid;
                en_len += 1;
            }
        }
    }
    var dis_buf: [MAX_PLUGINS]PluginId = undefined;
    var dis_len: usize = 0;
    for (disabled_names) |name| {
        if (PluginId.parse(name)) |pid| {
            if (dis_len < MAX_PLUGINS) {
                dis_buf[dis_len] = pid;
                dis_len += 1;
            }
        }
    }
    return resolvePluginChain(
        Preset.parse(preset_raw),
        if (en_len > 0) en_buf[0..en_len] else null,
        if (dis_len > 0) dis_buf[0..dis_len] else null,
    );
}

pub fn resolveChainForPredicates(preds: QueryPredicates) ResolvedPluginChain {
    if (preds.custom_plugin_mask) |mask| {
        return resolvePluginChainWithMask(preds.preset, mask, preds.preset == .auto and preds.allow_mtime_fallback_on_no_ts);
    }
    var chain = resolvePluginChain(
        preds.preset,
        if (preds.enabled_overrides.len > 0) preds.enabled_overrides else null,
        if (preds.disabled_overrides.len > 0) preds.disabled_overrides else null,
    );
    if (!preds.allow_mtime_fallback_on_no_ts) {
        chain.allow_mtime_fallback_on_no_ts = false;
        chain.signature = computePluginSignature(&chain);
    }
    return chain;
}

// ============================================================================
// 4-Stage Pipeline Orchestration Helpers
// ============================================================================

pub const SourcePlanResult = struct {
    verdict: Verdict = .keep,
    docker_since_sec: ?u64 = null,
    docker_until_sec: ?u64 = null,
};

pub fn planSource(
    chain: *const ResolvedPluginChain,
    preds: QueryPredicates,
    allow_docker_pushdown: bool,
) SourcePlanResult {
    var out = SourcePlanResult{};
    if (chain.has(.path_scope)) {
        if (path_scope.planSource(preds) == .skip) {
            out.verdict = .skip;
            return out;
        }
    }
    if (chain.has(.line_time)) {
        const lt_plan = line_time.planSource(preds, allow_docker_pushdown);
        out.docker_since_sec = lt_plan.docker_since_sec;
        out.docker_until_sec = lt_plan.docker_until_sec;
        if (lt_plan.verdict == .skip) {
            out.verdict = .skip;
            return out;
        }
    }
    return out;
}

pub const PruneDecision = struct {
    verdict: Verdict = .keep,
    pruned_by: ?PluginId = null,
};

pub fn pruneFile(
    chain: *const ResolvedPluginChain,
    meta: FileMeta,
    preds: QueryPredicates,
    sketch_store: ?*sidecar_sketch.SketchStore,
) PruneDecision {
    for (chain.slice()) |pid| {
        switch (pid) {
            .path_scope => {
                if (path_scope.eval(meta, preds) == .skip) {
                    return .{ .verdict = .skip, .pruned_by = .path_scope };
                }
            },
            .mtime_guard => {
                if (mtime_guard.evalGuard(meta, preds) == .skip) {
                    return .{ .verdict = .skip, .pruned_by = .mtime_guard };
                }
            },
            .mtime_window => {
                if (mtime_guard.evalWindow(meta, preds) == .skip) {
                    return .{ .verdict = .skip, .pruned_by = .mtime_window };
                }
            },
            .filename_date => {
                if (filename_date.eval(meta, preds) == .skip) {
                    return .{ .verdict = .skip, .pruned_by = .filename_date };
                }
            },
            .sidecar_sketch => {
                if (sketch_store) |store| {
                    if (sidecar_sketch.eval(store, meta, preds) == .skip) {
                        return .{ .verdict = .skip, .pruned_by = .sidecar_sketch };
                    }
                }
            },
            .time_bisect, .line_time => {},
        }
    }
    return .{ .verdict = .keep, .pruned_by = null };
}

pub fn narrowSliceWindow(
    chain: *const ResolvedPluginChain,
    slice: []const u8,
    meta: FileMeta,
    preds: QueryPredicates,
    hooks: TimeHooks,
) WindowSlice {
    if (!chain.has(.time_bisect)) {
        return .{
            .start_byte = 0,
            .end_byte = slice.len,
            .status = .full_scan,
        };
    }
    var win = time_bisect.narrowSlice(slice, meta, preds, hooks);
    if (win.status == .unparsed_no_ts and
        chain.allow_mtime_fallback_on_no_ts and
        preds.allow_mtime_fallback_on_no_ts and
        preds.hasTimeRange())
    {
        if (mtime_guard.evalWindow(meta, preds) == .skip or
            mtime_guard.evalGuard(meta, preds) == .skip)
        {
            win.start_byte = 0;
            win.end_byte = 0;
            win.status = .empty_skip;
        }
    }
    return win;
}

pub fn narrowReaderWindow(
    chain: *const ResolvedPluginChain,
    reader: PositionalReader,
    meta: FileMeta,
    preds: QueryPredicates,
    hooks: TimeHooks,
) !WindowSlice {
    if (!chain.has(.time_bisect)) {
        return .{
            .start_byte = 0,
            .end_byte = reader.size,
            .status = .full_scan,
        };
    }
    var win = try time_bisect.narrowReader(reader, meta, preds, hooks);
    if (win.status == .unparsed_no_ts and
        chain.allow_mtime_fallback_on_no_ts and
        preds.allow_mtime_fallback_on_no_ts and
        preds.hasTimeRange())
    {
        if (mtime_guard.evalWindow(meta, preds) == .skip or
            mtime_guard.evalGuard(meta, preds) == .skip)
        {
            win.start_byte = 0;
            win.end_byte = 0;
            win.status = .empty_skip;
        }
    }
    return win;
}

pub fn filterLine(
    chain: *const ResolvedPluginChain,
    line: []const u8,
    meta: FileMeta,
    preds: QueryPredicates,
    state: *LineState,
    hooks: TimeHooks,
) bool {
    if (chain.has(.line_time)) {
        return line_time.filterLine(line, meta, preds, state, hooks);
    }
    state.stats.lines_seen += 1;
    if (preds.kv_predicates.len > 0) {
        if (!line_time.matchesKvPredicates(line, preds.kv_predicates)) {
            state.stats.lines_skipped_kv += 1;
            return false;
        }
    }
    state.stats.lines_kept += 1;
    return true;
}

// ============================================================================
// Standalone Tests & Monotone Superset Property Verification
// ============================================================================

test {
    _ = path_scope;
    _ = mtime_guard;
    _ = filename_date;
    _ = sidecar_sketch;
    _ = time_bisect;
    _ = line_time;
}

test "prefilter: catalog, presets, deterministic ordering, and cache signature invalidation" {
    const catalog = getCatalog();
    try std.testing.expectEqual(@as(usize, 7), catalog.len);
    for (catalog, 1..) |entry, idx| {
        if (idx < catalog.len) {
            try std.testing.expect(entry.priority < catalog[idx].priority);
        }
    }

    const c_auto = resolvePluginChain(.auto, null, null);
    const c_ts = resolvePluginChain(.timeseries, null, null);
    const c_code = resolvePluginChain(.code, null, null);
    const c_raw = resolvePluginChain(.raw, null, null);

    try std.testing.expect(c_auto.has(.path_scope));
    try std.testing.expect(c_auto.has(.mtime_guard));
    try std.testing.expect(!c_auto.has(.mtime_window));
    try std.testing.expect(c_auto.allow_mtime_fallback_on_no_ts);
    try std.testing.expect(c_auto.has(.time_bisect));
    try std.testing.expect(c_auto.has(.line_time));

    try std.testing.expect(!c_ts.has(.mtime_window));
    try std.testing.expect(!c_ts.allow_mtime_fallback_on_no_ts);

    try std.testing.expect(c_code.has(.mtime_window));
    try std.testing.expect(!c_code.has(.filename_date));
    try std.testing.expect(!c_code.has(.time_bisect));

    try std.testing.expect(c_raw.has(.path_scope));
    try std.testing.expect(c_raw.has(.line_time));
    try std.testing.expect(!c_raw.has(.mtime_guard));
    try std.testing.expect(!c_raw.has(.mtime_window));
    try std.testing.expect(!c_raw.has(.sidecar_sketch));

    // Cache signatures change across presets and overrides
    try std.testing.expect(c_auto.signature != c_ts.signature);
    try std.testing.expect(c_auto.signature != c_code.signature);
    try std.testing.expect(c_auto.signature != c_raw.signature);

    const c_auto_no_mtime_fb = resolvePluginChain(.auto, null, &.{.mtime_window});
    try std.testing.expect(!c_auto_no_mtime_fb.allow_mtime_fallback_on_no_ts);
    try std.testing.expect(c_auto_no_mtime_fb.signature != c_auto.signature);

    const c_raw_with_sketch = resolvePluginChainFromNames("raw", &.{"sidecar_sketch"}, &.{});
    try std.testing.expect(c_raw_with_sketch.has(.sidecar_sketch));
    try std.testing.expect(c_raw_with_sketch.signature != c_raw.signature);
}

test "prefilter: active daily-append log (mtime=23:59, query=09:00..10:00) across auto vs code vs timeseries vs raw" {
    const t_00 = line_time.testUtcNs(2026, 11, 18, 0, 0, 0, 0);
    const t_09_00 = line_time.testUtcNs(2026, 11, 18, 9, 0, 0, 0);
    const t_09_30 = line_time.testUtcNs(2026, 11, 18, 9, 30, 0, 0);
    const t_10_00 = line_time.testUtcNs(2026, 11, 18, 10, 0, 0, 0);
    const t_23_59 = line_time.testUtcNs(2026, 11, 18, 23, 59, 0, 0);

    const daily_log =
        "2026-11-18T00:05:00Z INFO midnight boot\n" ++
        "2026-11-18T09:30:00Z ERROR target_morning_hit\n" ++
        "    at Worker.handle(worker.zig:42)\n" ++
        "2026-11-18T23:59:00Z INFO end of day\n";

    const log_meta = FileMeta{
        .rel_path = "logs/service.log",
        .size_bytes = daily_log.len,
        .mtime_ns = @intCast(t_23_59),
        .inode = 101,
        .dev = 1,
    };
    const code_meta = FileMeta{
        .rel_path = "src/main.zig",
        .size_bytes = 32,
        .mtime_ns = @intCast(t_23_59),
        .inode = 102,
        .dev = 1,
    };
    const code_data = "pub fn main() void {\n    _ = 1;\n}\n";

    // 1. .auto: daily_log MUST survive Stage 2, narrow in Stage 3, and match morning hit + stack trace in Stage 4;
    //    meanwhile untimestamped code_meta (mtime=23:59) confirms unparsed_no_ts and falls back to mtime_window -> skip!
    {
        const preds = QueryPredicates{
            .time_start_ns = t_09_00,
            .time_end_ns = t_10_00,
            .preset = .auto,
        };
        const chain = resolveChainForPredicates(preds);
        try std.testing.expectEqual(Verdict.keep, pruneFile(&chain, log_meta, preds, null).verdict);
        const w_log = narrowSliceWindow(&chain, daily_log, log_meta, preds, .{});
        try std.testing.expectEqual(WindowStatus.narrowed, w_log.status);
        const sub = daily_log[@intCast(w_log.start_byte)..@intCast(w_log.end_byte)];
        try std.testing.expect(std.mem.indexOf(u8, sub, "target_morning_hit") != null);
        try std.testing.expect(std.mem.indexOf(u8, sub, "Worker.handle") != null);

        var lstate = LineState{};
        try std.testing.expect(filterLine(&chain, "2026-11-18T09:30:00Z ERROR target_morning_hit", log_meta, preds, &lstate, .{}));
        try std.testing.expect(filterLine(&chain, "    at Worker.handle(worker.zig:42)", log_meta, preds, &lstate, .{}));
        try std.testing.expect(!filterLine(&chain, "2026-11-18T23:59:00Z INFO end of day", log_meta, preds, &lstate, .{}));

        try std.testing.expectEqual(Verdict.keep, pruneFile(&chain, code_meta, preds, null).verdict);
        const w_code = narrowSliceWindow(&chain, code_data, code_meta, preds, .{});
        try std.testing.expectEqual(WindowStatus.empty_skip, w_code.status);
    }

    // 2. .code: Stage 2 mtime_window skips mtime=23:59 > 10:00 immediately
    {
        const preds = QueryPredicates{
            .time_start_ns = t_09_00,
            .time_end_ns = t_10_00,
            .preset = .code,
        };
        const chain = resolveChainForPredicates(preds);
        const d = pruneFile(&chain, log_meta, preds, null);
        try std.testing.expectEqual(Verdict.skip, d.verdict);
        try std.testing.expectEqual(PluginId.mtime_window, d.pruned_by.?);
    }

    // 3. .timeseries: daily_log survives & narrows; untimestamped file is NOT dropped by mtime_window
    {
        const preds = QueryPredicates{
            .time_start_ns = t_09_00,
            .time_end_ns = t_10_00,
            .preset = .timeseries,
        };
        const chain = resolveChainForPredicates(preds);
        try std.testing.expectEqual(Verdict.keep, pruneFile(&chain, log_meta, preds, null).verdict);
        const w_log = narrowSliceWindow(&chain, daily_log, log_meta, preds, .{});
        try std.testing.expectEqual(WindowStatus.narrowed, w_log.status);

        const w_code = narrowSliceWindow(&chain, code_data, code_meta, preds, .{});
        try std.testing.expectEqual(WindowStatus.unparsed_no_ts, w_code.status);
    }

    // 4. .raw: never prunes at Stage 2/3, full_scan + Stage 4 line filter
    {
        const preds = QueryPredicates{
            .time_start_ns = t_09_00,
            .time_end_ns = t_10_00,
            .preset = .raw,
        };
        const chain = resolveChainForPredicates(preds);
        try std.testing.expectEqual(Verdict.keep, pruneFile(&chain, log_meta, preds, null).verdict);
        const w_log = narrowSliceWindow(&chain, daily_log, log_meta, preds, .{});
        try std.testing.expectEqual(WindowStatus.full_scan, w_log.status);
        var lstate = LineState{};
        try std.testing.expect(!filterLine(&chain, "2026-11-18T00:05:00Z INFO midnight boot", log_meta, preds, &lstate, .{}));
        try std.testing.expect(filterLine(&chain, "2026-11-18T09:30:00Z ERROR target_morning_hit", log_meta, preds, &lstate, .{}));
    }

    _ = t_00;
    _ = t_09_30;
}

test "prefilter: Monotone Superset property verification against linear brute-force oracle" {
    const gpa = std.testing.allocator;
    var store = sidecar_sketch.SketchStore{};
    defer store.deinit(gpa);

    // Construct a rich multi-file corpus with:
    // (a) ordered ISO-8601 + stack traces + KV JSON/logfmt lines
    // (b) active daily log (mtime=23:59)
    // (c) rotated filename app-2026-11-10.log (written today so mtime=23:59!)
    // (d) non-monotonic clock jump log
    // (e) untimestamped code file with mtime at 09:30
    const t_09_00 = line_time.testUtcNs(2026, 11, 18, 9, 0, 0, 0);
    const t_09_30 = line_time.testUtcNs(2026, 11, 18, 9, 30, 0, 0);
    const t_10_00 = line_time.testUtcNs(2026, 11, 18, 10, 0, 0, 0);
    const t_23_59 = line_time.testUtcNs(2026, 11, 18, 23, 59, 0, 0);

    const CorpusItem = struct {
        meta: FileMeta,
        body: []const u8,
        min_ts: ?u64 = null,
        max_ts: ?u64 = null,
        has_ts: bool = true,
    };

    const corpus = [_]CorpusItem{
        .{
            .meta = .{ .rel_path = "logs/api.log", .size_bytes = 0, .mtime_ns = @intCast(t_23_59), .inode = 1, .dev = 1 },
            .body = "2026-11-18T08:50:00Z INFO target_alpha status=200\n" ++
                "2026-11-18T09:15:00Z ERROR target_alpha status=503\n" ++
                "    at Handler.serve(api.zig:99)\n" ++
                "2026-11-18T09:45:00Z ERROR target_alpha status=500\n" ++
                "2026-11-18T11:10:00Z INFO target_alpha status=200\n",
            .min_ts = line_time.testUtcNs(2026, 11, 18, 8, 50, 0, 0),
            .max_ts = line_time.testUtcNs(2026, 11, 18, 11, 10, 0, 0),
        },
        .{
            .meta = .{ .rel_path = "logs/app-2026-11-10.log", .size_bytes = 0, .mtime_ns = @intCast(t_23_59), .inode = 2, .dev = 1 },
            .body = "2026-11-10T09:15:00Z INFO target_alpha old_rotated\n",
            .min_ts = line_time.testUtcNs(2026, 11, 10, 9, 15, 0, 0),
            .max_ts = line_time.testUtcNs(2026, 11, 10, 9, 15, 0, 0),
        },
        .{
            .meta = .{ .rel_path = "logs/skewed.log", .size_bytes = 0, .mtime_ns = @intCast(t_23_59), .inode = 3, .dev = 1 },
            .body = "2026-11-18T12:00:00Z INFO target_alpha out_of_order_head\n" ++
                "2026-11-18T09:20:00Z ERROR target_alpha out_of_order_mid\n" ++
                "2026-11-18T13:00:00Z INFO target_alpha out_of_order_tail\n",
            .min_ts = t_09_00,
            .max_ts = line_time.testUtcNs(2026, 11, 18, 13, 0, 0, 0),
        },
        .{
            .meta = .{ .rel_path = "docs/notes.txt", .size_bytes = 0, .mtime_ns = @intCast(t_09_30), .inode = 4, .dev = 1 },
            .body = "plain target_alpha inside untimestamped note\n",
            .has_ts = false,
        },
    };

    // Populate sidecar sketches with full file content
    for (corpus) |item| {
        var m = item.meta;
        m.size_bytes = item.body.len;
        if (sidecar_sketch.SketchKey.fromFileMeta(m)) |k| {
            var b = sidecar_sketch.TrigramBloom{};
            b.addSlice(item.body);
            store.upsert(k, .{
                .bloom = b,
                .has_bloom = true,
                .has_timestamps = item.has_ts,
                .has_ts_bounds = item.has_ts,
                .min_ts_ns = item.min_ts orelse 0,
                .max_ts_ns = item.max_ts orelse 0,
            });
        }
    }

    const presets = [_]Preset{ .auto, .timeseries, .raw };
    for (presets) |preset| {
        const preds = QueryPredicates{
            .time_start_ns = t_09_00,
            .time_end_ns = t_10_00,
            .preset = preset,
            .literal_anchors = &.{"target_alpha"},
        };
        const chain = resolveChainForPredicates(preds);

        for (corpus) |item| {
            var meta = item.meta;
            meta.size_bytes = item.body.len;

            // Oracle: full linear line scan
            var oracle_kept: std.ArrayList([]const u8) = .empty;
            defer oracle_kept.deinit(gpa);
            {
                var st = LineState{};
                var it = std.mem.splitScalar(u8, item.body, '\n');
                while (it.next()) |line| {
                    if (line.len == 0) continue;
                    if (line_time.filterLine(line, meta, preds, &st, .{})) {
                        try oracle_kept.append(gpa, line);
                    }
                }
            }

            // Pipeline: Stage 2 -> Stage 3 -> Stage 4
            var pipe_kept: std.ArrayList([]const u8) = .empty;
            defer pipe_kept.deinit(gpa);
            if (pruneFile(&chain, meta, preds, &store).verdict == .keep) {
                const win = narrowSliceWindow(&chain, item.body, meta, preds, .{});
                if (win.status != .empty_skip) {
                    const sub = item.body[@intCast(win.start_byte)..@intCast(win.end_byte)];
                    var st = LineState{ .sticky_format_id = win.sticky_format_id };
                    var it = std.mem.splitScalar(u8, sub, '\n');
                    while (it.next()) |line| {
                        if (line.len == 0) continue;
                        if (filterLine(&chain, line, meta, preds, &st, .{})) {
                            try pipe_kept.append(gpa, line);
                        }
                    }
                }
            }

            // Monotone Superset Law: every oracle-kept line MUST appear in pipe_kept (0 false negatives!)
            for (oracle_kept.items) |expected_line| {
                var found = false;
                for (pipe_kept.items) |actual_line| {
                    if (std.mem.eql(u8, expected_line, actual_line)) {
                        found = true;
                        break;
                    }
                }
                try std.testing.expect(found);
            }
            // In fact, for these inputs pipeline and oracle match identically!
            try std.testing.expectEqual(oracle_kept.items.len, pipe_kept.items.len);
        }
    }
}
