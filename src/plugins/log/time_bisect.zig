const std = @import("std");
const prefilter = @import("../../prefilter.zig");
const line_time = @import("line_time.zig");

pub const FileMeta = prefilter.FileMeta;
pub const QueryPredicates = prefilter.QueryPredicates;
pub const PositionalReader = prefilter.PositionalReader;
pub const WindowSlice = prefilter.WindowSlice;
pub const WindowStatus = prefilter.WindowStatus;
pub const TimeHooks = prefilter.TimeHooks;
pub const FallbackTimeContext = line_time.FallbackTimeContext;

pub const PROBE_BYTES: usize = 16 * 1024;
pub const LOOKBEHIND_BYTES: usize = 8 * 1024;
pub const LOOKAHEAD_BYTES: usize = 8 * 1024;
pub const MAX_PROBE_LINES: usize = 64;
pub const BISECT_LINEAR_THRESHOLD: u64 = 16 * 1024;

const SourceView = union(enum) {
    slice: []const u8,
    reader: PositionalReader,

    fn len(self: SourceView) u64 {
        return switch (self) {
            .slice => |s| s.len,
            .reader => |r| r.size,
        };
    }

    fn readRange(self: SourceView, start: u64, end: u64, stack_buf: []u8) ![]const u8 {
        const total = self.len();
        const s = @min(start, total);
        const e = @min(end, total);
        if (e <= s) return stack_buf[0..0];
        switch (self) {
            .slice => |sl| {
                return sl[@intCast(s)..@intCast(e)];
            },
            .reader => |r| {
                const want: usize = @intCast(@min(@as(u64, stack_buf.len), e - s));
                const n = try r.readAllAt(s, stack_buf[0..want]);
                return stack_buf[0..n];
            },
        }
    }
};

fn findLineStartInBuf(buf: []const u8, pos: usize) usize {
    var k = @min(pos, buf.len);
    while (k > 0) {
        if (buf[k - 1] == '\n') return k;
        k -= 1;
    }
    return 0;
}

const LookbehindResult = struct {
    ts_ns: u64,
    format_id: ?u32,
    parent_rel_start: usize,
};

fn findTimestampWithLookbehindInBuf(
    buf: []const u8,
    line_start_in_buf: usize,
    ctx: FallbackTimeContext,
    sticky: ?u32,
    hooks: TimeHooks,
) ?LookbehindResult {
    if (line_start_in_buf < buf.len) {
        if (line_time.parseLineWithHooks(buf[line_start_in_buf..], ctx, sticky, hooks)) |res| {
            return .{
                .ts_ns = res.ts_ns,
                .format_id = res.format_id,
                .parent_rel_start = line_start_in_buf,
            };
        }
    }
    var cur = line_start_in_buf;
    var steps: usize = 0;
    while (cur > 0 and steps < MAX_PROBE_LINES) : (steps += 1) {
        const prev_start = findLineStartInBuf(buf, cur - 1);
        if (line_time.parseLineWithHooks(buf[prev_start..cur], ctx, sticky, hooks)) |res| {
            return .{
                .ts_ns = res.ts_ns,
                .format_id = res.format_id,
                .parent_rel_start = prev_start,
            };
        }
        if (prev_start == 0) break;
        cur = prev_start;
    }
    return null;
}

const ProbeHit = struct {
    ts_ns: u64,
    abs_pos: u64,
    format_id: ?u32,
};

fn probeForward(
    view: SourceView,
    start_offset: u64,
    skip_partial_first_line: bool,
    ctx: FallbackTimeContext,
    sticky: ?u32,
    hooks: TimeHooks,
) !?ProbeHit {
    var stack_buf: [PROBE_BYTES]u8 = undefined;
    const chunk = try view.readRange(start_offset, start_offset + PROBE_BYTES, &stack_buf);
    if (chunk.len == 0) return null;

    var pos: usize = 0;
    if (skip_partial_first_line and start_offset > 0) {
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |nl| {
            pos = nl + 1;
        } else {
            return null;
        }
    }

    var lines_checked: usize = 0;
    while (pos < chunk.len and lines_checked < MAX_PROBE_LINES) {
        while (pos < chunk.len and (chunk[pos] == '\n' or chunk[pos] == '\r')) : (pos += 1) {}
        if (pos >= chunk.len) break;
        const nl = std.mem.indexOfScalarPos(u8, chunk, pos, '\n') orelse chunk.len;
        const line = chunk[pos..nl];
        if (line.len > 0) {
            lines_checked += 1;
            if (line_time.parseLineWithHooks(line, ctx, sticky, hooks)) |res| {
                return .{
                    .ts_ns = res.ts_ns,
                    .abs_pos = start_offset + pos,
                    .format_id = res.format_id,
                };
            }
        }
        pos = if (nl < chunk.len) nl + 1 else chunk.len;
    }
    return null;
}

fn probeMidpoint(
    view: SourceView,
    ctx: FallbackTimeContext,
    sticky: ?u32,
    hooks: TimeHooks,
) !?ProbeHit {
    const total = view.len();
    if (total == 0) return null;
    const mid_anchor = total / 2;
    const win_start = mid_anchor -| LOOKBEHIND_BYTES;
    const win_end = @min(total, mid_anchor + PROBE_BYTES);
    var stack_buf: [LOOKBEHIND_BYTES + PROBE_BYTES]u8 = undefined;
    const chunk = try view.readRange(win_start, win_end, &stack_buf);
    if (chunk.len == 0) return null;

    const mid_rel: usize = @intCast(mid_anchor - win_start);
    const line_start_rel = findLineStartInBuf(chunk, mid_rel);
    if (line_start_rel > 0 or win_start == 0) {
        if (findTimestampWithLookbehindInBuf(chunk, line_start_rel, ctx, sticky, hooks)) |lb| {
            return .{
                .ts_ns = lb.ts_ns,
                .abs_pos = win_start + lb.parent_rel_start,
                .format_id = lb.format_id,
            };
        }
    }

    var pos: usize = line_start_rel;
    var lines_checked: usize = 0;
    while (pos < chunk.len and lines_checked < MAX_PROBE_LINES) {
        while (pos < chunk.len and (chunk[pos] == '\n' or chunk[pos] == '\r')) : (pos += 1) {}
        if (pos >= chunk.len) break;
        const nl = std.mem.indexOfScalarPos(u8, chunk, pos, '\n') orelse chunk.len;
        const line = chunk[pos..nl];
        if (line.len > 0) {
            lines_checked += 1;
            if (line_time.parseLineWithHooks(line, ctx, sticky, hooks)) |res| {
                return .{
                    .ts_ns = res.ts_ns,
                    .abs_pos = win_start + pos,
                    .format_id = res.format_id,
                };
            }
        }
        pos = if (nl < chunk.len) nl + 1 else chunk.len;
    }
    return null;
}

fn probeTail(
    view: SourceView,
    ctx: FallbackTimeContext,
    sticky: ?u32,
    hooks: TimeHooks,
) !?ProbeHit {
    const total = view.len();
    if (total == 0) return null;
    const win_start = total -| PROBE_BYTES;
    var stack_buf: [PROBE_BYTES]u8 = undefined;
    const chunk = try view.readRange(win_start, total, &stack_buf);
    if (chunk.len == 0) return null;

    var end_trim = chunk.len;
    while (end_trim > 0 and (chunk[end_trim - 1] == '\n' or chunk[end_trim - 1] == '\r' or chunk[end_trim - 1] == ' ')) {
        end_trim -= 1;
    }
    if (end_trim == 0) return null;

    const last_line_start = findLineStartInBuf(chunk[0..end_trim], end_trim);
    if (findTimestampWithLookbehindInBuf(chunk[0..end_trim], last_line_start, ctx, sticky, hooks)) |lb| {
        return .{
            .ts_ns = lb.ts_ns,
            .abs_pos = win_start + lb.parent_rel_start,
            .format_id = lb.format_id,
        };
    }
    return null;
}

/// Priority 40 (`time_bisect`) for in-memory slices (`<= 512 MiB`).
pub fn narrowSlice(
    slice: []const u8,
    meta: FileMeta,
    preds: QueryPredicates,
    hooks: TimeHooks,
) WindowSlice {
    return narrowImpl(.{ .slice = slice }, meta, preds, hooks) catch .{
        .start_byte = 0,
        .end_byte = slice.len,
        .status = .full_scan,
    };
}

/// Priority 40 (`time_bisect`) for `> 512 MiB` files via `PositionalReader` (`pread`), zero `mmap`.
pub fn narrowReader(
    reader: PositionalReader,
    meta: FileMeta,
    preds: QueryPredicates,
    hooks: TimeHooks,
) !WindowSlice {
    return narrowImpl(.{ .reader = reader }, meta, preds, hooks);
}

fn countNewlinesInSlice(slice: []const u8) u64 {
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

fn narrowImpl(
    view: SourceView,
    meta: FileMeta,
    preds: QueryPredicates,
    hooks: TimeHooks,
) !WindowSlice {
    const total = view.len();
    if (total == 0) {
        return .{ .start_byte = 0, .end_byte = 0, .status = .empty_skip };
    }
    if (meta.is_compressed or meta.is_archive_container or total < 8) {
        return .{ .start_byte = 0, .end_byte = total, .status = if (total < 8) .unparsed_no_ts else .full_scan };
    }

    const ctx = FallbackTimeContext.fromMetaAndPreds(meta, preds);

    // 1. Head & Tail probes
    const head_hit = try probeForward(view, 0, false, ctx, null, hooks);
    var sticky: ?u32 = if (head_hit) |h| h.format_id else null;
    const tail_hit = try probeTail(view, ctx, sticky, hooks);
    if (sticky == null and tail_hit != null) {
        sticky = tail_hit.?.format_id;
    }

    // 2. Midpoint probe (catches non-monotonic jumps even in <32 KiB files AND confirms `.unparsed_no_ts`)
    const mid_hit: ?ProbeHit = if (total > 64)
        try probeMidpoint(view, ctx, sticky, hooks)
    else
        null;
    if (sticky == null and mid_hit != null) {
        sticky = mid_hit.?.format_id;
    }

    // All 3 probes found zero timestamps -> confirmed `.unparsed_no_ts`
    if (head_hit == null and tail_hit == null and mid_hit == null) {
        return .{
            .start_byte = 0,
            .end_byte = total,
            .status = .unparsed_no_ts,
        };
    }

    // Partial timestamp presence -> conservative `.full_scan`
    if (head_hit == null or tail_hit == null) {
        return .{
            .start_byte = 0,
            .end_byte = total,
            .status = .full_scan,
            .sticky_format_id = sticky,
            .head_ts_ns = if (head_hit) |h| h.ts_ns else null,
            .tail_ts_ns = if (tail_hit) |t| t.ts_ns else null,
        };
    }

    const head_t = head_hit.?.ts_ns;
    const tail_t = tail_hit.?.ts_ns;
    const slop = preds.bisect_slop_ns;

    // Monotonicity sanity checks across head, mid, and tail
    if (tail_t +| slop < head_t or tail_t < head_t) {
        return .{
            .start_byte = 0,
            .end_byte = total,
            .status = .full_scan,
            .sticky_format_id = sticky,
            .head_ts_ns = head_t,
            .tail_ts_ns = tail_t,
        };
    }
    if (mid_hit) |mh| {
        if (mh.ts_ns +| slop < head_t or mh.ts_ns > tail_t +| slop) {
            return .{
                .start_byte = 0,
                .end_byte = total,
                .status = .full_scan,
                .sticky_format_id = sticky,
                .head_ts_ns = head_t,
                .tail_ts_ns = tail_t,
            };
        }
    } else if (total > 2 * PROBE_BYTES) {
        // Large gap (>16 KiB) with no timestamps at midpoint: conservative `.full_scan`
        return .{
            .start_byte = 0,
            .end_byte = total,
            .status = .full_scan,
            .sticky_format_id = sticky,
            .head_ts_ns = head_t,
            .tail_ts_ns = tail_t,
        };
    }

    if (!preds.hasTimeRange()) {
        return .{
            .start_byte = 0,
            .end_byte = total,
            .status = .full_scan,
            .sticky_format_id = sticky,
            .head_ts_ns = head_t,
            .tail_ts_ns = tail_t,
        };
    }

    const eff_lo: u64 = if (preds.time_start_ns > 0) (preds.time_start_ns -| slop) else 0;
    const eff_hi: u64 = if (preds.time_end_ns > 0) (preds.time_end_ns +| slop) else 0;

    // Provably disjoint head/tail fast skip
    if ((eff_lo > 0 and tail_t < eff_lo) or (eff_hi > 0 and head_t > eff_hi)) {
        return .{
            .start_byte = 0,
            .end_byte = 0,
            .status = .empty_skip,
            .sticky_format_id = sticky,
            .head_ts_ns = head_t,
            .tail_ts_ns = tail_t,
        };
    }

    // 3. Lower-bound binary search: find `sub_start` (first line with timestamp >= eff_lo)
    var sub_start: u64 = 0;
    if (eff_lo > 0 and head_t < eff_lo) {
        const res = try bisectLowerBound(view, total, head_hit.?.abs_pos, head_t, tail_t, eff_lo, slop, ctx, sticky, hooks);
        if (res.non_monotonic) {
            return .{
                .start_byte = 0,
                .end_byte = total,
                .status = .full_scan,
                .sticky_format_id = sticky,
                .head_ts_ns = head_t,
                .tail_ts_ns = tail_t,
            };
        }
        sub_start = res.offset;
    }

    if (sub_start >= total) {
        return .{
            .start_byte = 0,
            .end_byte = 0,
            .status = .empty_skip,
            .sticky_format_id = sticky,
            .head_ts_ns = head_t,
            .tail_ts_ns = tail_t,
        };
    }

    // 4. Upper-bound binary search: find `sub_end` (first line with timestamp > eff_hi, preserving stack traces of <= eff_hi)
    var sub_end: u64 = total;
    if (eff_hi > 0 and tail_t > eff_hi) {
        const res = try bisectUpperBound(view, total, @max(sub_start, head_hit.?.abs_pos), head_t, tail_t, eff_hi, slop, ctx, sticky, hooks);
        if (res.non_monotonic) {
            return .{
                .start_byte = 0,
                .end_byte = total,
                .status = .full_scan,
                .sticky_format_id = sticky,
                .head_ts_ns = head_t,
                .tail_ts_ns = tail_t,
            };
        }
        sub_end = res.offset;
    }

    if (sub_start >= sub_end) {
        return .{
            .start_byte = 0,
            .end_byte = 0,
            .status = .empty_skip,
            .sticky_format_id = sticky,
            .head_ts_ns = head_t,
            .tail_ts_ns = tail_t,
        };
    }

    const narrowed_flag = (sub_start > 0 or sub_end < total);
    const base_lines: u64 = switch (view) {
        .slice => |sl| if (sub_start > 0) countNewlinesInSlice(sl[0..@intCast(sub_start)]) else 0,
        .reader => 0, // Do NOT scan GBs to count lines on PositionalReader (preserve O(log N))
    };

    return .{
        .start_byte = sub_start,
        .end_byte = sub_end,
        .base_line_offset = base_lines,
        .status = if (narrowed_flag) .narrowed else .full_scan,
        .sticky_format_id = sticky,
        .head_ts_ns = head_t,
        .tail_ts_ns = tail_t,
    };
}

const BisectRes = struct {
    offset: u64,
    non_monotonic: bool = false,
};

fn bisectLowerBound(
    view: SourceView,
    total: u64,
    first_ts_pos: u64,
    head_t: u64,
    tail_t: u64,
    eff_lo: u64,
    slop: u64,
    ctx: FallbackTimeContext,
    sticky: ?u32,
    hooks: TimeHooks,
) !BisectRes {
    var lo: u64 = first_ts_pos;
    var hi: u64 = total;
    var lo_ts: u64 = head_t;
    var hi_ts: u64 = tail_t;

    var step_buf: [LOOKBEHIND_BYTES + LOOKAHEAD_BYTES]u8 = undefined;
    while (hi > lo and (hi - lo) > BISECT_LINEAR_THRESHOLD) {
        const mid = lo + (hi - lo) / 2;
        const win_start = mid -| LOOKBEHIND_BYTES;
        const win_end = @min(total, mid + LOOKAHEAD_BYTES);
        const buf = try view.readRange(win_start, win_end, &step_buf);
        if (buf.len == 0) break;

        const mid_rel: usize = @intCast(mid - win_start);
        var line_start_rel = findLineStartInBuf(buf, mid_rel);
        // If `win_start == 0` and `mid_rel` is within `lo`, clamp if needed; if `line_start_rel == 0 and win_start > 0`, >8 KiB line
        if (line_start_rel == 0 and win_start > 0) {
            return .{ .offset = lo };
        }
        const abs_line_start = win_start + line_start_rel;
        if (abs_line_start < lo) {
            line_start_rel = @intCast(lo - win_start);
        }

        const nl_rel = std.mem.indexOfScalarPos(u8, buf, mid_rel, '\n');
        if (nl_rel == null and win_end < total) {
            // Line exceeds lookahead buffer -> stop conservatively at `lo`
            return .{ .offset = lo };
        }
        const line_end_rel = if (nl_rel) |nl| nl + 1 else buf.len;
        const abs_line_end = win_start + line_end_rel;

        if (findTimestampWithLookbehindInBuf(buf, line_start_rel, ctx, sticky, hooks)) |lb| {
            if (lb.ts_ns +| slop < lo_ts or lb.ts_ns > hi_ts +| slop) {
                return .{ .offset = 0, .non_monotonic = true };
            }
            if (lb.ts_ns < eff_lo) {
                if (abs_line_end <= lo) break;
                lo = abs_line_end;
                lo_ts = lb.ts_ns;
            } else {
                const parent_abs = win_start + lb.parent_rel_start;
                const next_hi = @max(lo, parent_abs);
                if (next_hi >= hi) break;
                hi = next_hi;
                hi_ts = lb.ts_ns;
            }
        } else {
            return .{ .offset = lo };
        }
    }

    // Exact linear scan of final `<= 16 KiB` window (`[lo .. hi]`) with 8 KiB lookbehind
    const lb_start = lo -| LOOKBEHIND_BYTES;
    var fin_buf: [LOOKBEHIND_BYTES + BISECT_LINEAR_THRESHOLD + 4096]u8 = undefined;
    const read_end = @min(total, @max(hi, lo) + 4096);
    const buf = try view.readRange(lb_start, read_end, &fin_buf);
    const lo_rel: usize = @intCast(lo - lb_start);
    const hi_rel: usize = @intCast(@min(hi - lb_start, buf.len));

    var pos: usize = lo_rel;
    while (pos < hi_rel) {
        const nl = std.mem.indexOfScalarPos(u8, buf, pos, '\n');
        const le = if (nl) |n| n + 1 else buf.len;
        if (line_time.parseLineWithHooks(buf[pos..le], ctx, sticky, hooks)) |res| {
            if (res.ts_ns +| slop < lo_ts or res.ts_ns > hi_ts +| slop) {
                return .{ .offset = 0, .non_monotonic = true };
            }
            if (res.ts_ns >= eff_lo) {
                return .{ .offset = lb_start + pos };
            }
            lo_ts = res.ts_ns;
        } else if (pos == lo_rel) {
            if (findTimestampWithLookbehindInBuf(buf, pos, ctx, sticky, hooks)) |lb| {
                if (lb.ts_ns >= eff_lo) {
                    return .{ .offset = lb_start + lb.parent_rel_start };
                }
            }
        }
        pos = le;
    }
    return .{ .offset = hi };
}

fn bisectUpperBound(
    view: SourceView,
    total: u64,
    start_floor: u64,
    head_t: u64,
    tail_t: u64,
    eff_hi: u64,
    slop: u64,
    ctx: FallbackTimeContext,
    sticky: ?u32,
    hooks: TimeHooks,
) !BisectRes {
    var lo: u64 = start_floor;
    var hi: u64 = total;
    var lo_ts: u64 = head_t;
    var hi_ts: u64 = tail_t;

    var step_buf: [LOOKBEHIND_BYTES + LOOKAHEAD_BYTES]u8 = undefined;
    while (hi > lo and (hi - lo) > BISECT_LINEAR_THRESHOLD) {
        const mid = lo + (hi - lo) / 2;
        const win_start = mid -| LOOKBEHIND_BYTES;
        const win_end = @min(total, mid + LOOKAHEAD_BYTES);
        const buf = try view.readRange(win_start, win_end, &step_buf);
        if (buf.len == 0) break;

        const mid_rel: usize = @intCast(mid - win_start);
        var line_start_rel = findLineStartInBuf(buf, mid_rel);
        if (line_start_rel == 0 and win_start > 0) {
            return .{ .offset = hi };
        }
        const abs_line_start = win_start + line_start_rel;
        if (abs_line_start < lo) {
            line_start_rel = @intCast(lo - win_start);
        }

        const nl_rel = std.mem.indexOfScalarPos(u8, buf, mid_rel, '\n');
        if (nl_rel == null and win_end < total) {
            return .{ .offset = hi };
        }
        const line_end_rel = if (nl_rel) |nl| nl + 1 else buf.len;
        const abs_line_end = win_start + line_end_rel;

        if (findTimestampWithLookbehindInBuf(buf, line_start_rel, ctx, sticky, hooks)) |lb| {
            if (lb.ts_ns +| slop < lo_ts or lb.ts_ns > hi_ts +| slop) {
                return .{ .offset = 0, .non_monotonic = true };
            }
            if (lb.ts_ns <= eff_hi) {
                if (abs_line_end <= lo) break;
                lo = abs_line_end;
                lo_ts = lb.ts_ns;
            } else {
                const parent_abs = win_start + lb.parent_rel_start;
                const next_hi = @max(lo, parent_abs);
                if (next_hi >= hi) break;
                hi = next_hi;
                hi_ts = lb.ts_ns;
            }
        } else {
            return .{ .offset = hi };
        }
    }

    // Exact linear finish in `[lo .. hi]` preserving continuation lines of last `<= eff_hi` record
    const lb_start = lo -| LOOKBEHIND_BYTES;
    var fin_buf: [LOOKBEHIND_BYTES + BISECT_LINEAR_THRESHOLD + 4096]u8 = undefined;
    const read_end = @min(total, @max(hi, lo) + 4096);
    const buf = try view.readRange(lb_start, read_end, &fin_buf);
    const lo_rel: usize = @intCast(lo - lb_start);
    const hi_rel: usize = @intCast(@min(hi - lb_start, buf.len));

    var cur_in_range = true;
    if (lo_rel < buf.len) {
        if (findTimestampWithLookbehindInBuf(buf, lo_rel, ctx, sticky, hooks)) |lb| {
            cur_in_range = (lb.ts_ns <= eff_hi);
        }
    }

    var last_kept_end: u64 = lo;
    var pos: usize = lo_rel;
    while (pos < hi_rel) {
        const nl = std.mem.indexOfScalarPos(u8, buf, pos, '\n');
        const le = if (nl) |n| @min(n + 1, hi_rel) else hi_rel;
        const line = buf[pos..le];
        if (line_time.parseLineWithHooks(line, ctx, sticky, hooks)) |res| {
            if (res.ts_ns +| slop < lo_ts or res.ts_ns > hi_ts +| slop) {
                return .{ .offset = 0, .non_monotonic = true };
            }
            if (res.ts_ns > eff_hi) {
                return .{ .offset = lb_start + pos };
            }
            cur_in_range = true;
            lo_ts = res.ts_ns;
            last_kept_end = lb_start + le;
        } else {
            if (cur_in_range) {
                last_kept_end = lb_start + le;
            }
        }
        pos = le;
    }
    return .{ .offset = last_kept_end };
}

// ============================================================================
// Unit Tests (including >512 MiB Simulated PositionalReader Binary Search!)
// ============================================================================

test "time_bisect: CRLF/LF alignment, 8 KiB stack-trace lookbehind, monotonicity check, and unparsed_no_ts" {
    const t_lo = line_time.testUtcNs(2026, 11, 18, 9, 0, 0, 0);
    const t_hi = line_time.testUtcNs(2026, 11, 18, 10, 0, 0, 0);

    // 1. CRLF log with multi-line stack trace crossing target boundary
    const crlf_log =
        "2026-11-18T08:00:00Z INFO early\r\n" ++
        "    at EarlyFrame(a.zig:1)\r\n" ++
        "2026-11-18T09:15:00Z ERROR inside_1\r\n" ++
        "    at StackFrame1(b.zig:10)\r\n" ++
        "    at StackFrame2(b.zig:11)\r\n" ++
        "2026-11-18T11:30:00Z INFO late\r\n" ++
        "    at LateFrame(c.zig:20)\r\n";

    const meta = FileMeta{ .rel_path = "crlf.log", .size_bytes = crlf_log.len };
    const preds = QueryPredicates{
        .time_start_ns = t_lo,
        .time_end_ns = t_hi,
        .bisect_slop_ns = 0,
    };

    const w_slice = narrowSlice(crlf_log, meta, preds, .{});
    try std.testing.expectEqual(WindowStatus.narrowed, w_slice.status);
    const sub = crlf_log[@intCast(w_slice.start_byte)..@intCast(w_slice.end_byte)];
    try std.testing.expect(std.mem.indexOf(u8, sub, "ERROR inside_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub, "StackFrame2") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub, "early") == null);
    try std.testing.expect(std.mem.indexOf(u8, sub, "late") == null);

    // Identical bounds via PositionalReader!
    var slice_ctx = PositionalReader.SliceCtx{ .data = crlf_log };
    const w_reader = try narrowReader(slice_ctx.reader(), meta, preds, .{});
    try std.testing.expectEqual(w_slice.start_byte, w_reader.start_byte);
    try std.testing.expectEqual(w_slice.end_byte, w_reader.end_byte);
    try std.testing.expectEqual(w_slice.status, w_reader.status);

    // 2. Non-monotonic clock jump falls back to `.full_scan`
    const skewed_log =
        "2026-11-18T12:00:00Z INFO jump_head\n" ++
        "2026-11-18T09:30:00Z ERROR target_inside\n" ++
        "2026-11-18T13:00:00Z INFO jump_tail\n";
    const w_skew = narrowSlice(skewed_log, .{ .rel_path = "skew.log", .size_bytes = skewed_log.len }, preds, .{});
    try std.testing.expectEqual(WindowStatus.full_scan, w_skew.status);
    try std.testing.expectEqual(@as(u64, 0), w_skew.start_byte);
    try std.testing.expectEqual(@as(u64, skewed_log.len), w_skew.end_byte);

    // 3. Plain untimestamped code/notes reports `.unparsed_no_ts`
    const plain_code = "const x = 1;\nfn hello() void {\n    return;\n}\n";
    const w_code = narrowSlice(plain_code, .{ .rel_path = "main.zig", .size_bytes = plain_code.len }, preds, .{});
    try std.testing.expectEqual(WindowStatus.unparsed_no_ts, w_code.status);
}

test "time_bisect: >512 MiB simulated PositionalReader O(log N) pread binary search without allocating 512 MiB" {
    // Simulate a 600 MiB ordered log file made of fixed 64-byte records:
    // `2026-11-18T00:00:00Z INFO record=000000000 padding_payload_here_\n` (64 bytes!)
    // Total records: 9,830,400 (~600 MiB = 629,145,600 bytes).
    // Note: each day has 86,400 seconds; let's advance timestamp by 1 second every 120 records
    // so total span = 81,920 seconds (~22.75 hours: 00:00:00Z .. 22:45:19Z).
    const RECORD_LEN: u64 = 64;
    const TOTAL_RECORDS: u64 = 9_830_400; // 600 MiB exact!
    const TOTAL_BYTES: u64 = TOTAL_RECORDS * RECORD_LEN;
    const RECORDS_PER_SEC: u64 = 120;
    const base_sec: u64 = @intCast(line_time.civilToEpochSeconds(2026, 11, 18, 0, 0, 0).?);

    const VirtualLog = struct {
        read_calls: usize = 0,
        bytes_read: u64 = 0,
        base_sec_val: u64,

        fn formatRecord(base_s: u64, rec_idx: u64, out: *[RECORD_LEN]u8) void {
            const sec = base_s + (rec_idx / RECORDS_PER_SEC);
            const civil = line_time.epochSecondsToCivil(@intCast(sec)).?;
            const written = std.fmt.bufPrint(
                out,
                "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z INFO rec={d:0>9} pad_0123456789abcdef_xy\n",
                .{ civil.year, civil.month, civil.day, civil.hour, civil.minute, civil.second, rec_idx },
            ) catch unreachable;
            std.debug.assert(written.len == RECORD_LEN);
        }

        fn readAt(raw: *anyopaque, offset: u64, buf: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.read_calls += 1;
            if (offset >= TOTAL_BYTES) return 0;
            const avail = @min(@as(u64, buf.len), TOTAL_BYTES - offset);
            const want: usize = @intCast(avail);

            var written: usize = 0;
            var rec_buf: [RECORD_LEN]u8 = undefined;
            while (written < want) {
                const abs_off = offset + written;
                const rec_idx = abs_off / RECORD_LEN;
                const in_rec: usize = @intCast(abs_off % RECORD_LEN);
                formatRecord(self.base_sec_val, rec_idx, &rec_buf);
                const copy_n = @min(want - written, RECORD_LEN - in_rec);
                @memcpy(buf[written .. written + copy_n], rec_buf[in_rec .. in_rec + copy_n]);
                written += copy_n;
            }
            self.bytes_read += written;
            return written;
        }
    };

    var vlog = VirtualLog{ .base_sec_val = base_sec };
    const reader = PositionalReader{
        .ctx = &vlog,
        .size = TOTAL_BYTES,
        .readAtFn = VirtualLog.readAt,
    };

    // Query exact 5-minute window [09:00:00Z, 09:05:00Z] inside the 600 MiB file (with slop = 0)
    const q_start = line_time.testUtcNs(2026, 11, 18, 9, 0, 0, 0);
    const q_end = line_time.testUtcNs(2026, 11, 18, 9, 5, 0, 0);
    const meta = FileMeta{
        .rel_path = "huge-600mb.log",
        .size_bytes = TOTAL_BYTES,
        .mtime_ns = @intCast(line_time.testUtcNs(2026, 11, 18, 23, 0, 0, 0)),
    };
    const preds = QueryPredicates{
        .time_start_ns = q_start,
        .time_end_ns = q_end,
        .bisect_slop_ns = 0,
    };

    const win = try narrowReader(reader, meta, preds, .{});
    try std.testing.expectEqual(WindowStatus.narrowed, win.status);

    // Exact expected byte offsets:
    // 09:00:00 is 32,400 seconds after 00:00:00 -> rec_idx = 32,400 * 120 = 3,888,000 -> byte = 248,832,000
    // 09:05:00 ends after 09:05:00 inclusive -> first > 09:05:00 is 09:05:01 -> 32,701 * 120 = 3,924,120 -> byte = 251,143,680
    const expected_start: u64 = 32400 * RECORDS_PER_SEC * RECORD_LEN;
    const expected_end: u64 = 32701 * RECORDS_PER_SEC * RECORD_LEN;
    try std.testing.expectEqual(expected_start, win.start_byte);
    try std.testing.expectEqual(expected_end, win.end_byte);

    // Verify strictly O(log N) bounded preads (< 80 reads, < 2 MiB total read out of 600 MiB!)
    try std.testing.expect(vlog.read_calls <= 80);
    try std.testing.expect(vlog.bytes_read < 2 * 1024 * 1024);
}

test "time_bisect: multi-line stack trace lookbehind >32 KiB, compressed skip safety, and open-ended bounds" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // Build a ~48 KiB ordered log containing a 4 KiB multi-line stack trace inside the target window
    var line_tmp: [256]u8 = undefined;
    for (0..400) |i| {
        const min: u8 = @intCast(i / 60);
        const sec: u8 = @intCast(i % 60);
        const line = std.fmt.bufPrint(&line_tmp, "2026-11-18T08:{d:0>2}:{d:0>2}Z INFO warmup_{d:0>4} padding_0123456789abcdef0123456789\n", .{ min, sec, i }) catch unreachable;
        try buf.appendSlice(gpa, line);
    }
    try buf.appendSlice(gpa, "2026-11-18T09:15:00Z ERROR big_stack_root\n");
    for (0..80) |j| {
        const line = std.fmt.bufPrint(&line_tmp, "    at Frame.level{d:0>2}(pkg/Service.java:{d})\n", .{ j, 100 + j }) catch unreachable;
        try buf.appendSlice(gpa, line);
    }
    for (0..400) |i| {
        const min: u8 = @intCast(i / 60);
        const sec: u8 = @intCast(i % 60);
        const line = std.fmt.bufPrint(&line_tmp, "2026-11-18T11:{d:0>2}:{d:0>2}Z INFO cooldown_{d:0>4} padding_0123456789abcdef0123456789\n", .{ min, sec, i }) catch unreachable;
        try buf.appendSlice(gpa, line);
    }

    const meta = FileMeta{ .rel_path = "big_stack.log", .size_bytes = buf.items.len };
    const preds = QueryPredicates{
        .time_start_ns = line_time.testUtcNs(2026, 11, 18, 9, 0, 0, 0),
        .time_end_ns = line_time.testUtcNs(2026, 11, 18, 10, 0, 0, 0),
        .bisect_slop_ns = 0,
    };

    const w = narrowSlice(buf.items, meta, preds, .{});
    try std.testing.expectEqual(WindowStatus.narrowed, w.status);
    const sub = buf.items[@intCast(w.start_byte)..@intCast(w.end_byte)];
    try std.testing.expect(std.mem.indexOf(u8, sub, "ERROR big_stack_root") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub, "Frame.level79") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub, "warmup_0000") == null);
    try std.testing.expect(std.mem.indexOf(u8, sub, "cooldown_0000") == null);

    // Compressed files must return `.full_scan` (never `.unparsed_no_ts` or bisect raw bytes)
    const w_gz = narrowSlice("binary_gz_bytes", .{ .rel_path = "app.log.gz", .size_bytes = 15, .is_compressed = true }, preds, .{});
    try std.testing.expectEqual(WindowStatus.full_scan, w_gz.status);

    // Open-ended start-only query (`time_end_ns == 0`)
    const w_open_end = narrowSlice(buf.items, meta, .{
        .time_start_ns = line_time.testUtcNs(2026, 11, 18, 9, 0, 0, 0),
        .time_end_ns = 0,
        .bisect_slop_ns = 0,
    }, .{});
    try std.testing.expectEqual(WindowStatus.narrowed, w_open_end.status);
    try std.testing.expectEqual(@as(u64, buf.items.len), w_open_end.end_byte);
}
