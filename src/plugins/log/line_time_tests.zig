const std = @import("std");
const prefilter = @import("../../prefilter.zig");
const line_time = @import("line_time.zig");
const kv_filter = @import("kv_filter.zig");

const FallbackTimeContext = line_time.FallbackTimeContext;
const testUtcNs = line_time.testUtcNs;
const parseLineBuiltin = line_time.parseLineBuiltin;
const parseLineWithHooks = line_time.parseLineWithHooks;
const filterLine = line_time.filterLine;
const matchesKvPredicates = kv_filter.matchesKvPredicates;
const FileMeta = prefilter.FileMeta;
const QueryPredicates = prefilter.QueryPredicates;
const LineState = prefilter.LineState;
const TimeHooks = prefilter.TimeHooks;
const TimeParseResult = prefilter.TimeParseResult;
const KvPredicate = prefilter.KvPredicate;

test "line_time: sticky_format_id, O(1) continuation, and custom hook" {
    const t_09_00 = testUtcNs(2026, 11, 18, 9, 0, 0, 0);
    const t_10_00 = testUtcNs(2026, 11, 18, 10, 0, 0, 0);

    // Sticky format caching + O(1) continuation skipping
    const meta = FileMeta{ .rel_path = "app.log", .mtime_ns = @intCast(t_10_00) };
    const preds = QueryPredicates{
        .time_start_ns = t_09_00,
        .time_end_ns = t_10_00,
    };
    var st = LineState{};
    try std.testing.expect(!filterLine("2026-11-18T08:00:00Z INFO early", meta, preds, &st, .{}));
    try std.testing.expect(st.sticky_format_id != null);
    try std.testing.expect(!filterLine("    at Early.frame(early.zig:1)", meta, preds, &st, .{}));
    try std.testing.expectEqual(@as(u64, 1), st.stats.continuations_inherited);

    try std.testing.expect(filterLine("2026-11-18T09:30:00Z ERROR hit", meta, preds, &st, .{}));
    try std.testing.expectEqual(@as(u64, 1), st.stats.sticky_hits);
    try std.testing.expect(filterLine("    at Hit.frame(hit.zig:2)", meta, preds, &st, .{}));
    try std.testing.expect(filterLine("Caused by: timeout", meta, preds, &st, .{}));
    try std.testing.expectEqual(@as(u64, 3), st.stats.continuations_inherited);
    try std.testing.expectEqual(@as(u64, 3), st.stats.lines_kept);

    // 3. Injected custom TimeParseFn hook
    const CustomHook = struct {
        calls: usize = 0,
        fn parse(
            raw_ctx: ?*anyopaque,
            line: []const u8,
            _: u16,
            _: u8,
            _: u8,
            _: i16,
            _: ?u32,
        ) ?TimeParseResult {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            self.calls += 1;
            if (std.mem.startsWith(u8, line, "CUSTOM_IN")) {
                return .{ .ts_ns = testUtcNs(2026, 11, 18, 9, 30, 0, 0), .format_id = 99 };
            }
            return null;
        }
    };
    var hook_state = CustomHook{};
    var custom_st = LineState{};
    const hooks = TimeHooks{ .ctx = &hook_state, .parseLineFn = CustomHook.parse };
    try std.testing.expect(filterLine("CUSTOM_IN payload", meta, preds, &custom_st, hooks));
    try std.testing.expectEqual(@as(?u32, 99), custom_st.sticky_format_id);
    try std.testing.expect(filterLine("    at Stack.frame()", meta, preds, &custom_st, hooks));
    // O(1) continuation avoided calling custom parseLineFn on the indented stack frame!
    try std.testing.expectEqual(@as(usize, 1), hook_state.calls);
}

test "line_time: zero-alloc KvPredicate verifier on JSON, nested JSON, mixed prefix+JSON, and logfmt" {
    const json_line = "{\"level\":\"ERROR\",\"http\":{\"status\":503},\"latency_ms\":245.5,\"msg\":\"upstream \\\"db\\\" timeout\"}";
    const logfmt_line = "ts=2026-11-18T09:30:00Z level=error status=503 latency_ms=245.5 msg=\"upstream timeout\"";
    const mixed_line = "2026-11-18T09:30:00Z ERROR {\"level\":\"error\",\"status\":200,\"latency_ms\":12.1,\"trace\":null}";

    try std.testing.expect(matchesKvPredicates(json_line, &.{
        .{ .key = "level", .op = .eq, .value = "error", .case_sensitive = false },
        .{ .key = "http.status", .op = .eq, .value = "503" },
        .{ .key = "latency_ms", .op = .gt_num, .value = "200" },
        .{ .key = "latency_ms", .op = .lt_num, .value = "500" },
        .{ .key = "msg", .op = .contains, .value = "\"db\" timeout" },
        .{ .key = "http.status", .op = .exists },
    }));
    try std.testing.expect(!matchesKvPredicates(json_line, &.{
        .{ .key = "level", .op = .eq, .value = "error", .case_sensitive = true },
    }));
    try std.testing.expect(!matchesKvPredicates(json_line, &.{
        .{ .key = "missing", .op = .exists },
    }));

    try std.testing.expect(matchesKvPredicates(logfmt_line, &.{
        .{ .key = "level", .op = .eq, .value = "error" },
        .{ .key = "status", .op = .neq, .value = "200" },
        .{ .key = "latency_ms", .op = .gt_num, .value = "200" },
        .{ .key = "msg", .op = .contains, .value = "upstream" },
    }));
    try std.testing.expect(!matchesKvPredicates(logfmt_line, &.{
        .{ .key = "status", .op = .eq, .value = "200" },
    }));
    // Quoted value containing `status=200` must NOT trick logfmt parser when actual `status=503`
    const tricky_logfmt = "2026-11-18T09:30:00Z WARN msg=\"retry status=200 failed\" status=503";
    try std.testing.expect(matchesKvPredicates(tricky_logfmt, &.{
        .{ .key = "status", .op = .eq, .value = "503" },
    }));
    try std.testing.expect(!matchesKvPredicates(tricky_logfmt, &.{
        .{ .key = "status", .op = .eq, .value = "200" },
    }));

    try std.testing.expect(matchesKvPredicates(mixed_line, &.{
        .{ .key = "status", .op = .eq, .value = "200" },
    }));
    try std.testing.expect(!matchesKvPredicates(mixed_line, &.{
        .{ .key = "trace", .op = .exists },
    }));
    try std.testing.expect(matchesKvPredicates(mixed_line, &.{
        .{ .key = "trace", .op = .neq, .value = "abc" },
    }));
}
