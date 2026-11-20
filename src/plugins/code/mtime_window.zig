const std = @import("std");
const prefilter = @import("../../prefilter.zig");

pub const Verdict = prefilter.Verdict;
pub const FileMeta = prefilter.FileMeta;
pub const QueryPredicates = prefilter.QueryPredicates;

fn mtimeNsU64(mtime_ns: i96) ?u64 {
    if (mtime_ns <= 0) return null;
    if (mtime_ns > std.math.maxInt(u64)) return std.math.maxInt(u64);
    return @intCast(mtime_ns);
}

/// Priority 25 (`mtime_window`, `code` domain): upper-bound mtime filter (`mtime_ns > time_end_ns -> .skip`).
/// Enabled in `.code` preset, and consulted as fallback in `.auto` ONLY after `time_bisect`
/// confirms `.unparsed_no_ts`. OFF in `.timeseries` and `.raw`.
pub fn evalWindow(meta: FileMeta, preds: QueryPredicates) Verdict {
    if (preds.time_end_ns == 0) return .keep;
    const mtime_u64 = mtimeNsU64(meta.mtime_ns) orelse return .keep;
    if (mtime_u64 > preds.time_end_ns) {
        return .skip;
    }
    return .keep;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "mtime_window: upper-bound mtime pruning for code & static files" {
    const s = std.time.ns_per_s;
    const t_1000: u64 = 1_700_000_000 * s;

    const preds_start_only = QueryPredicates{
        .time_start_ns = t_1000,
        .time_end_ns = 0,
    };
    try std.testing.expectEqual(Verdict.keep, evalWindow(.{
        .rel_path = "future.zig",
        .mtime_ns = @intCast(t_1000 + 3600 * s),
    }, preds_start_only));

    const preds_end_only = QueryPredicates{
        .time_start_ns = 0,
        .time_end_ns = t_1000,
    };
    try std.testing.expectEqual(Verdict.skip, evalWindow(.{
        .rel_path = "newer.zig",
        .mtime_ns = @intCast(t_1000 + 1),
    }, preds_end_only));
    try std.testing.expectEqual(Verdict.keep, evalWindow(.{
        .rel_path = "inside.zig",
        .mtime_ns = @intCast(t_1000),
    }, preds_end_only));
    try std.testing.expectEqual(Verdict.keep, evalWindow(.{
        .rel_path = "missing_mtime.zig",
        .mtime_ns = 0,
    }, preds_end_only));
}
