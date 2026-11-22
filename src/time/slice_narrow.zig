const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");
const calendar = @import("calendar.zig");
const universal = @import("universal.zig");
const extractors = @import("extractors.zig");

const FallbackTimeContext = calendar.FallbackTimeContext;
const PrefixEpochCache = calendar.PrefixEpochCache;
const currentUnixNano = calendar.currentUnixNano;
const epochSecondsToCivil = calendar.epochSecondsToCivil;
const CompiledTimeParser = extractors.CompiledTimeParser;
const sliceAtLineEnd = universal.sliceAtLineEnd;

pub fn isLikelyContinuationLine(raw_line: []const u8) bool {
    const line = sliceAtLineEnd(raw_line);
    if (line.len == 0) return false;
    if (line[0] == ' ' or line[0] == '\t') return true;
    if (std.mem.startsWith(u8, line, "Caused by:") or
        std.mem.startsWith(u8, line, "Suppressed:") or
        std.mem.startsWith(u8, line, "... ") or
        std.mem.startsWith(u8, line, "}") or
        std.mem.startsWith(u8, line, "]") or
        std.mem.startsWith(u8, line, ")"))
    {
        return true;
    }
    return false;
}

pub fn findLineStartAtOrBefore(slice: []const u8, pos: usize) usize {
    var k = @min(pos, slice.len);
    while (k > 0) {
        if (slice[k - 1] == '\n') return k;
        k -= 1;
    }
    return 0;
}

pub fn countNewlinesFast(slice: []const u8) u64 {
    var count: u64 = 0;
    const Vec32 = @Vector(32, u8);
    const nl_vec: Vec32 = @splat('\n');
    var i: usize = 0;
    while (i + 32 <= slice.len) : (i += 32) {
        const chunk: Vec32 = slice[i..][0..32].*;
        const mask: u32 = @bitCast(chunk == nl_vec);
        count += @popCount(mask);
    }
    while (i < slice.len) : (i += 1) {
        if (slice[i] == '\n') count += 1;
    }
    return count;
}

/// Walks backwards up to 32 lines from `line_start` to find the nearest timestamped parent line
/// (so multi-line stack traces in Java/Python/Go logs inherit their parent event's timestamp).
pub fn findLineTimestampWithLookbehind(
    slice: []const u8,
    line_start: usize,
    parser: *const CompiledTimeParser,
    ctx: FallbackTimeContext,
    scratch: ?*libwebgrep.RegexScratch,
    cache: ?*PrefixEpochCache,
) ?u64 {
    if (line_start < slice.len) {
        if (parser.parseLine(slice[line_start..], ctx, scratch, cache)) |ns| return ns;
    }
    var cur = line_start;
    var steps: usize = 0;
    while (cur > 0 and steps < 32) : (steps += 1) {
        const prev_start = findLineStartAtOrBefore(slice, cur - 1);
        if (parser.parseLine(slice[prev_start..cur], ctx, scratch, cache)) |ns| {
            return ns;
        }
        cur = prev_start;
    }
    return null;
}

pub const SliceTimeStatus = enum {
    ordered_series,
    unordered_has_ts,
    no_timestamps,
};

pub const NarrowedSlice = struct {
    sub_slice: []const u8,
    sub_start: usize = 0,
    base_line_offset: u64 = 0,
    status: SliceTimeStatus,
};

/// Inspects head (up to 64 lines / 16 KiB) + tail (with 32-line lookbehind) to classify `slice`
/// and perform O(log N) binary search with `±slop_ns` safety margin on ordered time-series logs.
pub fn narrowSliceByTimeParser(
    slice: []const u8,
    parser: *const CompiledTimeParser,
    start_ns: u64,
    end_ns: u64,
    ctx: FallbackTimeContext,
    scratch: ?*libwebgrep.RegexScratch,
    cache: ?*PrefixEpochCache,
    slop_ns: u64,
) NarrowedSlice {
    if (slice.len < 6) {
        return .{ .sub_slice = slice, .status = .no_timestamps };
    }

    // 1. Scan up to 64 non-empty lines within the first 16 KiB to tolerate file headers/banners
    const head_limit = @min(slice.len, 16 * 1024);
    var first_ns: ?u64 = null;
    var first_ts_pos: usize = 0;
    var pos: usize = 0;
    var lines_checked: usize = 0;
    while (pos < head_limit and lines_checked < 64) {
        while (pos < head_limit and (slice[pos] == '\n' or slice[pos] == '\r')) : (pos += 1) {}
        if (pos >= head_limit) break;
        const nl = std.mem.indexOfScalarPos(u8, slice, pos, '\n') orelse slice.len;
        const line = slice[pos..nl];
        if (line.len > 0) {
            lines_checked += 1;
            if (parser.parseLine(line, ctx, scratch, cache)) |ns| {
                first_ns = ns;
                first_ts_pos = pos;
                break;
            }
        }
        pos = if (nl < slice.len) nl + 1 else slice.len;
    }

    // 2. Inspect near EOF (with up to 32-line stack-trace lookbehind)
    var end_trim = slice.len;
    while (end_trim > 0 and (slice[end_trim - 1] == '\n' or slice[end_trim - 1] == '\r' or slice[end_trim - 1] == ' ')) {
        end_trim -= 1;
    }
    const last_ns: ?u64 = if (end_trim > 0) blk_last: {
        const last_line_start = findLineStartAtOrBefore(slice, end_trim);
        break :blk_last findLineTimestampWithLookbehind(slice[0..end_trim], last_line_start, parser, ctx, scratch, cache);
    } else null;

    if (first_ns == null and last_ns == null) {
        return .{ .sub_slice = slice, .status = .no_timestamps };
    }
    if (first_ns == null or last_ns == null or last_ns.? < first_ns.?) {
        return .{ .sub_slice = slice, .status = .unordered_has_ts };
    }

    const head_t = first_ns.?;
    const tail_t = last_ns.?;

    if (start_ns == 0 and end_ns == 0) {
        return .{ .sub_slice = slice, .status = .ordered_series };
    }

    const eff_lo_ns: u64 = if (start_ns > 0) (start_ns -| slop_ns) else 0;
    const eff_hi_ns: u64 = if (end_ns > 0) (end_ns +| slop_ns) else 0;

    if ((eff_lo_ns > 0 and tail_t < eff_lo_ns) or (eff_hi_ns > 0 and head_t > eff_hi_ns)) {
        return .{ .sub_slice = slice[0..0], .status = .ordered_series };
    }

    var sub_start: usize = 0;
    if (eff_lo_ns > 0 and head_t < eff_lo_ns) {
        var lo: usize = first_ts_pos;
        var hi: usize = slice.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            var line_start = findLineStartAtOrBefore(slice, mid);
            if (line_start < lo) line_start = lo;
            const line_end = if (std.mem.indexOfScalarPos(u8, slice, line_start, '\n')) |nl|
                nl + 1
            else
                slice.len;

            if (findLineTimestampWithLookbehind(slice, line_start, parser, ctx, scratch, cache)) |line_ns| {
                if (line_ns < eff_lo_ns) {
                    lo = line_end;
                } else {
                    hi = line_start;
                }
            } else {
                // Gap >32 lines without timestamps: fall back safely to full linear scan
                return .{ .sub_slice = slice, .status = .ordered_series };
            }
        }
        sub_start = lo;
    }

    if (sub_start >= slice.len) {
        return .{ .sub_slice = slice[0..0], .status = .ordered_series };
    }

    var sub_end: usize = slice.len;
    if (eff_hi_ns > 0 and tail_t > eff_hi_ns) {
        var lo: usize = @max(sub_start, first_ts_pos);
        var hi: usize = slice.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            var line_start = findLineStartAtOrBefore(slice, mid);
            if (line_start < lo) line_start = lo;
            const line_end = if (std.mem.indexOfScalarPos(u8, slice, line_start, '\n')) |nl|
                nl + 1
            else
                slice.len;

            if (findLineTimestampWithLookbehind(slice, line_start, parser, ctx, scratch, cache)) |line_ns| {
                if (line_ns <= eff_hi_ns) {
                    lo = line_end;
                } else {
                    hi = line_start;
                }
            } else {
                return .{ .sub_slice = slice, .status = .ordered_series };
            }
        }
        sub_end = lo;
    }

    if (sub_start >= sub_end) {
        return .{ .sub_slice = slice[0..0], .status = .ordered_series };
    }

    const base_lines = if (sub_start > 0) countNewlinesFast(slice[0..sub_start]) else 0;
    return .{
        .sub_slice = slice[sub_start..sub_end],
        .sub_start = sub_start,
        .base_line_offset = base_lines,
        .status = .ordered_series,
    };
}

// ============================================================================
// HTTP Live Preview Endpoint Helper (`/api/time/preview`)
// ============================================================================

pub const TimePreviewResponse = struct {
    validFormat: bool,
    matched: bool,
    epochMs: ?i64 = null,
    isoUtc: ?[]const u8 = null,
    localDisplay: ?[]const u8 = null,
    errorMessage: ?[]const u8 = null,
};

pub fn buildTimePreviewJson(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    raw_format: []const u8,
    sample_line: []const u8,
    tz_offset_min: i16,
    now_ns: u64,
) ![]u8 {
    var parser = try gpa.create(CompiledTimeParser);
    parser.* = .{};
    defer {
        parser.deinit(gpa);
        gpa.destroy(parser);
    }

    var err_msg: ?[]const u8 = null;
    parser.initInPlace(gpa, arena, raw_format, &err_msg) catch {
        return try std.json.Stringify.valueAlloc(arena, TimePreviewResponse{
            .validFormat = false,
            .matched = false,
            .errorMessage = err_msg orelse "Invalid time format",
        }, .{});
    };

    const clean_sample = std.mem.trim(u8, sample_line, "\r\n");
    if (clean_sample.len == 0) {
        return try std.json.Stringify.valueAlloc(arena, TimePreviewResponse{
            .validFormat = true,
            .matched = false,
        }, .{});
    }

    var scratch = libwebgrep.RegexScratch.init(gpa);
    defer scratch.deinit();
    var cache = PrefixEpochCache{};

    const ctx = FallbackTimeContext.fromMtimeAndTz(@intCast(now_ns), tz_offset_min);
    const parsed_ns = parser.parseLine(clean_sample, ctx, &scratch, &cache) orelse {
        return try std.json.Stringify.valueAlloc(arena, TimePreviewResponse{
            .validFormat = true,
            .matched = false,
        }, .{});
    };

    const total_ms: u64 = parsed_ns / std.time.ns_per_ms;
    const utc_sec: i64 = @intCast(total_ms / 1000);
    const ms_rem: u64 = total_ms % 1000;

    const utc_civil = epochSecondsToCivil(utc_sec);
    const local_sec = utc_sec + ctx.tz_offset_sec;
    const local_civil = epochSecondsToCivil(local_sec) orelse utc_civil;

    const iso_utc = if (utc_civil) |c|
        try std.fmt.allocPrint(
            arena,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
            .{ c.year, c.month, c.day, c.hour, c.minute, c.second, ms_rem },
        )
    else
        null;

    const local_display = if (local_civil) |lc|
        try std.fmt.allocPrint(
            arena,
            "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
            .{ lc.year, lc.month, lc.day, lc.hour, lc.minute, lc.second, ms_rem },
        )
    else
        null;

    return try std.json.Stringify.valueAlloc(arena, TimePreviewResponse{
        .validFormat = true,
        .matched = true,
        .epochMs = @intCast(total_ms),
        .isoUtc = iso_utc,
        .localDisplay = local_display,
    }, .{});
}

// ============================================================================
// Unit Tests
// ============================================================================
