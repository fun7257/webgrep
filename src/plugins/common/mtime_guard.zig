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

/// Priority 20 (`mtime_guard`, `common` domain): provably safe lower bound.
/// Skips files whose `mtime_ns + skew_tolerance_ns < time_start_ns` (both for bounded windows
/// and open-ended `time_start_ns`-only windows). Never skips when `mtime_ns <= 0` or `time_start_ns == 0`.
pub fn evalGuard(meta: FileMeta, preds: QueryPredicates) Verdict {
    if (preds.time_start_ns == 0) return .keep;
    const mtime_u64 = mtimeNsU64(meta.mtime_ns) orelse return .keep;
    if (mtime_u64 +| preds.skew_tolerance_ns < preds.time_start_ns) {
        return .skip;
    }
    return .keep;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "mtime_guard: partial ranges, skew tolerance, and missing mtime" {
    const s = std.time.ns_per_s;
    const t_1000: u64 = 1_700_000_000 * s;

    const preds_start_only = QueryPredicates{
        .time_start_ns = t_1000,
        .time_end_ns = 0,
        .skew_tolerance_ns = 5 * s,
    };
    try std.testing.expectEqual(Verdict.skip, evalGuard(.{
        .rel_path = "old.log",
        .mtime_ns = @intCast(t_1000 - 10 * s),
    }, preds_start_only));
    try std.testing.expectEqual(Verdict.keep, evalGuard(.{
        .rel_path = "skew.log",
        .mtime_ns = @intCast(t_1000 - 3 * s),
    }, preds_start_only));
    try std.testing.expectEqual(Verdict.keep, evalGuard(.{
        .rel_path = "virtual.log",
        .mtime_ns = 0,
    }, preds_start_only));

    const preds_end_only = QueryPredicates{
        .time_start_ns = 0,
        .time_end_ns = t_1000,
    };
    try std.testing.expectEqual(Verdict.keep, evalGuard(.{
        .rel_path = "old.log",
        .mtime_ns = @intCast(t_1000 - 86400 * s),
    }, preds_end_only));
}
