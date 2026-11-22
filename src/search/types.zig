const std = @import("std");
const libwebgrep = @import("libwebgrep");
const prefilter = @import("../prefilter.zig");
const source_registry = @import("../source_registry.zig");
const time_parser = @import("../time_parser.zig");
const protocol = @import("protocol.zig");

const SearchRequest = protocol.SearchRequest;

pub const DirEntryItem = struct {
    name: []const u8,
    is_dir: bool,
    is_symlink: bool = false,

    pub fn lessThan(_: void, a: DirEntryItem, b: DirEntryItem) bool {
        if (a.is_dir != b.is_dir) return !a.is_dir; // search files in dir first, then recurse subdirs
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

pub const SourcePipelineConfig = struct {
    chain: prefilter.ResolvedPluginChain,
    task_time_mode: time_parser.TimeMode,
    source_kind: prefilter.SourceKind = .dir,
    strict_content_time: bool = false,
    allow_mtime_fallback: bool = true,
};

pub fn resolveSourcePipeline(
    req: SearchRequest,
    trimmed_req_tf: []const u8,
    src_opt: ?source_registry.SearchableSource,
    time_mode: time_parser.TimeMode,
) SourcePipelineConfig {
    const req_preset_trimmed = if (req.pluginPreset) |p|
        std.mem.trim(u8, p, " \t\r\n")
    else
        "";
    const eff_preset_raw: []const u8 = if (req_preset_trimmed.len > 0)
        req_preset_trimmed
    else if (src_opt) |s|
        s.plugin_preset
    else
        "auto";

    const en_names: []const []const u8 = if (req.plugins) |ov|
        (ov.enable orelse &.{})
    else if (src_opt) |s|
        s.plugins_enable
    else
        &.{};
    const dis_names: []const []const u8 = if (req.plugins) |ov|
        (ov.disable orelse &.{})
    else if (src_opt) |s|
        s.plugins_disable
    else
        &.{};

    var chain = prefilter.resolvePluginChainFromNames(eff_preset_raw, en_names, dis_names);
    const trimmed_src_tf: []const u8 = if (src_opt) |s|
        std.mem.trim(u8, s.time_format, " \t\r\n")
    else
        "";

    const sk: prefilter.SourceKind = if (src_opt) |s| prefilter.SourceKind.parse(s.kind) else .dir;

    if (time_mode == .mtime) {
        const mask = (chain.active_mask | prefilter.PluginId.mtime_guard.bit() | prefilter.PluginId.mtime_window.bit()) &
            ~(prefilter.PluginId.time_bisect.bit() | prefilter.PluginId.line_time.bit() | prefilter.PluginId.filename_date.bit());
        chain = prefilter.resolvePluginChainWithMask(chain.preset, mask, true);
        return .{
            .chain = chain,
            .task_time_mode = .mtime,
            .source_kind = sk,
            .strict_content_time = false,
            .allow_mtime_fallback = true,
        };
    }

    if (time_mode == .content) {
        var mask = chain.active_mask & ~prefilter.PluginId.mtime_window.bit();
        mask |= prefilter.PluginId.line_time.bit();
        mask |= prefilter.PluginId.time_bisect.bit();
        chain = prefilter.resolvePluginChainWithMask(chain.preset, mask, false);
        return .{
            .chain = chain,
            .task_time_mode = .content,
            .source_kind = sk,
            .strict_content_time = true,
            .allow_mtime_fallback = false,
        };
    }

    // `.source` or `.auto` mode:
    if (chain.preset == .code and !chain.has(.time_bisect)) {
        return .{
            .chain = chain,
            .task_time_mode = .mtime,
            .source_kind = sk,
            .strict_content_time = false,
            .allow_mtime_fallback = true,
        };
    }

    if (trimmed_req_tf.len > 0 or trimmed_src_tf.len > 0) {
        const mask = chain.active_mask & ~prefilter.PluginId.mtime_window.bit();
        chain = prefilter.resolvePluginChainWithMask(chain.preset, mask, false);
        return .{
            .chain = chain,
            .task_time_mode = .content,
            .source_kind = sk,
            .strict_content_time = true,
            .allow_mtime_fallback = false,
        };
    }

    const allow_fb = chain.allow_mtime_fallback_on_no_ts;
    return .{
        .chain = chain,
        .task_time_mode = time_mode,
        .source_kind = sk,
        .strict_content_time = (chain.preset == .timeseries) or !allow_fb,
        .allow_mtime_fallback = allow_fb,
    };
}

pub const PositionalFileCtx = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64,

    pub fn asPositionalReader(self: *PositionalFileCtx) prefilter.PositionalReader {
        return .{
            .ctx = self,
            .size = self.size,
            .readAtFn = readAt,
        };
    }

    fn readAt(raw_ctx: *anyopaque, offset: u64, buf: []u8) anyerror!usize {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        if (offset >= self.size or buf.len == 0) return 0;
        const avail: usize = @intCast(@min(@as(u64, buf.len), self.size - offset));
        return try self.file.readPositionalAll(self.io, buf[0..avail], offset);
    }
};

/// Bounded zero-mmap `std.Io.Reader` backed by `pread` (`readPositionalAll`) over `[cur_pos, end_pos)`.
/// Must call `bindInterface()` once residing at its pinned stack address.
pub const PositionalWindowReader = struct {
    io: std.Io,
    file: std.Io.File,
    cur_pos: u64,
    end_pos: u64,
    interface: std.Io.Reader = undefined,
    read_buf: [64 * 1024]u8 = undefined,

    pub fn bindInterface(self: *PositionalWindowReader) void {
        self.interface = .{
            .vtable = &.{
                .stream = streamImpl,
            },
            .buffer = &self.read_buf,
            .seek = 0,
            .end = 0,
        };
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *PositionalWindowReader = @alignCast(@fieldParentPtr("interface", io_r));
        if (self.cur_pos >= self.end_pos) return error.EndOfStream;
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;
        const remain = self.end_pos - self.cur_pos;
        const to_read: usize = @intCast(@min(remain, @as(u64, dest.len)));
        const n = self.file.readPositionalAll(self.io, dest[0..to_read], self.cur_pos) catch {
            return error.ReadFailed;
        };
        if (n == 0) {
            self.cur_pos = self.end_pos;
            return error.EndOfStream;
        }
        self.cur_pos += n;
        io_w.advance(n);
        return n;
    }
};

pub const FileTask = struct {
    pub const COLOSSAL_FILE_THRESHOLD: u64 = 256 * 1024 * 1024;

    parent_dir_path: ?[]const u8 = null,
    open_sub_path: []const u8,
    rel_path: []const u8,
    base_name: []const u8,
    source_id: []const u8 = "",
    source_name: []const u8 = "",
    source_kind: prefilter.SourceKind = .dir,
    archive_format: ?libwebgrep.ArchiveFormat = null,
    effective_contains: []const []const u8 = &.{},
    effective_excludes: []const []const u8 = &.{},
    line_time_parser: *const time_parser.CompiledTimeParser,
    task_time_mode: time_parser.TimeMode = .auto,
    plugin_chain: prefilter.ResolvedPluginChain = prefilter.resolvePluginChain(.timeseries, null, null),
    strict_content_time: bool = true,
    allow_mtime_fallback: bool = false,
    mtime_ns: i96 = 0,
    file_size: u64 = 0,
    inode: std.Io.File.INode = 0,
    dev: u64 = 0,
    access_heat: u64 = 0,
    base_heat: u64 = 100,
    heat_score: u64 = 100,
    soft_quota: u64 = 0,
    emitted_in_file: u64 = 0,
    resume_after_line: u64 = 0,
    paused_result: ?libwebgrep.Result = null,
    cached_window: ?prefilter.WindowSlice = null,
    phase_bytes: u64 = 0,
    prev_scanned_bytes: u64 = 0,
    paused_at_soft_quota: bool = false,
    counted_file_searched: bool = false,
    counted_file_matched: bool = false,
    counted_window_savings: bool = false,
    counted_window_sketch_ts: bool = false,

    pub fn isColossal(self: FileTask) bool {
        return self.file_size > COLOSSAL_FILE_THRESHOLD;
    }

    pub fn hotterThan(_: void, a: FileTask, b: FileTask) bool {
        const a_col = a.isColossal();
        const b_col = b.isColossal();
        if (a_col != b_col) return !a_col;
        if (a_col and b_col and a.file_size != b.file_size) return a.file_size < b.file_size;
        if (a.heat_score != b.heat_score) return a.heat_score > b.heat_score;
        if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
        return std.mem.order(u8, a.rel_path, b.rel_path) == .lt;
    }
};

pub const TimeParserPoolEntry = struct {
    key: []const u8,
    ptr: *time_parser.CompiledTimeParser,
};
