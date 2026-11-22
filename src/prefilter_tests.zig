const std = @import("std");
const prefilter = @import("prefilter.zig");
const line_time = @import("plugins/log/line_time.zig");
const sidecar_sketch = @import("plugins/common/sidecar_sketch.zig");

const PluginId = prefilter.PluginId;
const Preset = prefilter.Preset;
const SourceKind = prefilter.SourceKind;
const TimeMode = prefilter.TimeMode;
const Verdict = prefilter.Verdict;
const WindowStatus = prefilter.WindowStatus;
const FileMeta = prefilter.FileMeta;
const QueryPredicates = prefilter.QueryPredicates;
const LineState = prefilter.LineState;
const ResolvedPluginChain = prefilter.ResolvedPluginChain;
const getCatalog = prefilter.getCatalog;
const getPresets = prefilter.getPresets;
const resolvePluginChain = prefilter.resolvePluginChain;
const resolveChainForPredicates = prefilter.resolveChainForPredicates;
const resolvePluginChainFromNames = prefilter.resolvePluginChainFromNames;
const computePluginSignature = prefilter.computePluginSignature;
const pruneFile = prefilter.pruneFile;
const narrowSliceWindow = prefilter.narrowSliceWindow;
const filterLine = prefilter.filterLine;

test "prefilter: catalog, presets, deterministic ordering, and cache signature invalidation" {
    const catalog = getCatalog();
    try std.testing.expectEqual(@as(usize, 7), catalog.len);
    for (catalog, 1..) |entry, idx| {
        try std.testing.expectEqual(entry.id.domain(), entry.domain);
        if (idx < catalog.len) {
            try std.testing.expect(entry.priority < catalog[idx].priority);
        }
    }

    // Domain isolation guard: code preset ignores log-domain enable overrides; timeseries ignores code-domain enable overrides
    const c_code_isolated = resolvePluginChain(.code, &.{ .filename_date, .time_bisect, .line_time }, null);
    try std.testing.expect(!c_code_isolated.has(.filename_date));
    try std.testing.expect(!c_code_isolated.has(.time_bisect));
    try std.testing.expect(!c_code_isolated.has(.line_time));
    try std.testing.expect(c_code_isolated.has(.mtime_window));

    const c_ts_isolated = resolvePluginChain(.timeseries, &.{.mtime_window}, null);
    try std.testing.expect(!c_ts_isolated.has(.mtime_window));
    try std.testing.expect(c_ts_isolated.has(.time_bisect));

    const c_ts = resolvePluginChain(.timeseries, null, null);
    const c_code = resolvePluginChain(.code, null, null);

    try std.testing.expect(c_ts.has(.path_scope));
    try std.testing.expect(c_ts.has(.mtime_guard));
    try std.testing.expect(c_ts.has(.filename_date));
    try std.testing.expect(c_ts.has(.sidecar_sketch));
    try std.testing.expect(c_ts.has(.time_bisect));
    try std.testing.expect(c_ts.has(.line_time));
    try std.testing.expect(!c_ts.has(.mtime_window));
    try std.testing.expect(!c_ts.allow_mtime_fallback_on_no_ts);

    try std.testing.expect(c_code.has(.path_scope));
    try std.testing.expect(c_code.has(.mtime_guard));
    try std.testing.expect(c_code.has(.mtime_window));
    try std.testing.expect(c_code.has(.sidecar_sketch));
    try std.testing.expect(!c_code.has(.filename_date));
    try std.testing.expect(!c_code.has(.time_bisect));
    try std.testing.expect(!c_code.has(.line_time));

    // Cache signatures change across presets and overrides
    try std.testing.expect(c_ts.signature != c_code.signature);

    const c_ts_no_sketch = resolvePluginChainFromNames("timeseries", &.{}, &.{"sidecar_sketch"});
    try std.testing.expect(!c_ts_no_sketch.has(.sidecar_sketch));
    try std.testing.expect(c_ts_no_sketch.signature != c_ts.signature);

    // Alias "log" maps cleanly to .timeseries; legacy "auto"/"raw" fall back safely to .timeseries via Preset.parse
    try std.testing.expectEqual(Preset.timeseries, Preset.parseStrict("log").?);
    try std.testing.expectEqual(Preset.timeseries, Preset.parse("auto"));
    try std.testing.expectEqual(Preset.timeseries, Preset.parse("raw"));
    try std.testing.expectEqual(Preset.code, Preset.parseStrict("code").?);
}

test "prefilter: active daily-append log (mtime=23:59, query=09:00..10:00) across timeseries vs code" {
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

    // 1. .code: Stage 2 mtime_window skips mtime=23:59 > 10:00 immediately
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

    // 2. .timeseries (log): daily_log survives & narrows; untimestamped file is NOT dropped by mtime_window
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
        const sub = daily_log[@intCast(w_log.start_byte)..@intCast(w_log.end_byte)];
        try std.testing.expect(std.mem.indexOf(u8, sub, "target_morning_hit") != null);
        try std.testing.expect(std.mem.indexOf(u8, sub, "Worker.handle") != null);

        var lstate = LineState{};
        try std.testing.expect(filterLine(&chain, "2026-11-18T09:30:00Z ERROR target_morning_hit", log_meta, preds, &lstate, .{}));
        try std.testing.expect(filterLine(&chain, "    at Worker.handle(worker.zig:42)", log_meta, preds, &lstate, .{}));
        try std.testing.expect(!filterLine(&chain, "2026-11-18T23:59:00Z INFO end of day", log_meta, preds, &lstate, .{}));

        const w_code = narrowSliceWindow(&chain, code_data, code_meta, preds, .{});
        try std.testing.expectEqual(WindowStatus.unparsed_no_ts, w_code.status);
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

    const presets = [_]Preset{.timeseries};
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
