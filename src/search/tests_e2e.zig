const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");
const prefilter = @import("../prefilter.zig");
const source_registry = @import("../source_registry.zig");
const search_cache = @import("../search_cache.zig");
const time_parser = @import("../time_parser.zig");
const protocol = @import("protocol.zig");
const limits = @import("limits.zig");
const query_plan = @import("query_plan.zig");
const types = @import("types.zig");
const runner_mod = @import("runner.zig");
const execute = @import("execute.zig");

const KvPredicateDto = protocol.KvPredicateDto;
const SearchRequest = protocol.SearchRequest;
const FrameSender = protocol.FrameSender;
const HitSpan = protocol.HitSpan;
const HitItem = protocol.HitItem;
const HitsFrame = protocol.HitsFrame;
const ProgressFrame = protocol.ProgressFrame;
const DoneFrame = protocol.DoneFrame;
const ErrorFrame = protocol.ErrorFrame;
const EngineLimits = limits.EngineLimits;
const ARCHIVE_VIRTUAL_SEP = limits.ARCHIVE_VIRTUAL_SEP;
const detectArchiveFormat = limits.detectArchiveFormat;
const formatRegexDiagnosticAlloc = limits.formatRegexDiagnosticAlloc;
const custom_file_types = limits.custom_file_types;
const parseCaseMode = query_plan.parseCaseMode;
const hasRegexMeta = query_plan.hasRegexMeta;
const computeRegexSelectivity = query_plan.computeRegexSelectivity;
const computeLiteralSelectivity = query_plan.computeLiteralSelectivity;
const PositionalWindowReader = types.PositionalWindowReader;
const JobRunner = runner_mod.JobRunner;
const executeSearchJson = execute.executeSearchJson;
const executeSearch = execute.executeSearch;
const executeSearchWithRegistry = execute.executeSearchWithRegistry;

fn buildTestStoredGzipAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    std.debug.assert(payload.len <= 0xFFFF);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &.{ 0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03 });
    try out.append(allocator, 0x01);
    const len16: u16 = @intCast(payload.len);
    const nlen16: u16 = ~len16;
    var block_hdr: [4]u8 = undefined;
    std.mem.writeInt(u16, block_hdr[0..2], len16, .little);
    std.mem.writeInt(u16, block_hdr[2..4], nlen16, .little);
    try out.appendSlice(allocator, &block_hdr);
    try out.appendSlice(allocator, payload);
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u32, trailer[0..4], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, trailer[4..8], @intCast(payload.len), .little);
    try out.appendSlice(allocator, &trailer);
    return out.toOwnedSlice(allocator);
}

const PrefilterE2ECollector = struct {
    allocator: std.mem.Allocator,
    files_searched: u64 = 0,
    files_matched: u64 = 0,
    matched_lines: u64 = 0,
    files_pruned: u64 = 0,
    bytes_saved: u64 = 0,
    bytes_scanned: u64 = 0,
    cache_hit: [32]u8 = undefined,
    cache_hit_len: usize = 0,
    error_msg: ?[]u8 = null,
    texts: std.ArrayList([]u8) = .empty,

    fn deinit(self: *PrefilterE2ECollector) void {
        if (self.error_msg) |m| self.allocator.free(m);
        for (self.texts.items) |t| self.allocator.free(t);
        self.texts.deinit(self.allocator);
    }

    fn tier(self: *const PrefilterE2ECollector) []const u8 {
        return self.cache_hit[0..self.cache_hit_len];
    }

    fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
        const self: *PrefilterE2ECollector = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
            var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            for (parsed.value.items) |it| {
                if (it.isContext) continue;
                try self.texts.append(self.allocator, try self.allocator.dupe(u8, it.text));
            }
        } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
            var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            self.files_searched = parsed.value.filesSearched;
            self.files_matched = parsed.value.filesMatched;
            self.matched_lines = parsed.value.matchedLines;
            self.files_pruned = parsed.value.filesPruned;
            self.bytes_saved = parsed.value.bytesSaved;
            self.bytes_scanned = parsed.value.bytesScanned;
            const n = @min(parsed.value.cacheHit.len, self.cache_hit.len);
            @memcpy(self.cache_hit[0..n], parsed.value.cacheHit[0..n]);
            self.cache_hit_len = n;
        } else if (std.mem.indexOf(u8, json_text, "\"type\":\"error\"") != null) {
            var parsed = try std.json.parseFromSlice(ErrorFrame, self.allocator, json_text, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            if (self.error_msg) |old| self.allocator.free(old);
            self.error_msg = try self.allocator.dupe(u8, parsed.value.message);
        }
    }
};

test "search_job: daily-append log at 23:59 found at 09:00..10:00 under auto vs skipped under code + fallback for untimestamped files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "data");
    try tmp.dir.createDirPath(io, "app_logs");

    const t_09_00: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 18, 9, 0, 0).? * std.time.ns_per_s);
    const t_10_00: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 18, 10, 0, 0).? * std.time.ns_per_s);
    const t_23_59_ns: i96 = @as(i96, time_parser.civilToEpochSeconds(2026, 11, 18, 23, 59, 0).?) * std.time.ns_per_s;

    {
        var f = try tmp.dir.createFile(io, "app_logs/daily.log", .{ .truncate = true });
        defer f.close(io);
        var wb: [512]u8 = undefined;
        var fw = f.writer(io, &wb);
        try fw.interface.writeAll(
            "2026-11-18T00:05:00Z INFO midnight boot\n" ++
                "2026-11-18T09:30:00Z ERROR daily_morning_boom\n" ++
                "    at DailyWorker.run(worker.zig:10)\n" ++
                "2026-11-18T23:59:00Z INFO end of day\n",
        );
        try fw.interface.flush();
        try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = t_23_59_ns } } });
    }
    {
        var f = try tmp.dir.createFile(io, "app_logs/notes.txt", .{ .truncate = true });
        defer f.close(io);
        var wb: [256]u8 = undefined;
        var fw = f.writer(io, &wb);
        try fw.interface.writeAll("untimestamped note mentioning daily_morning_boom\n");
        try fw.interface.flush();
        try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = t_23_59_ns } } });
    }

    var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rlen = try tmp.dir.realPath(io, &pbuf);
    const root_real = pbuf[0..rlen];
    const data_path = try std.fmt.allocPrint(arena, "{s}/data", .{root_real});
    const logs_path = try std.fmt.allocPrint(arena, "{s}/app_logs", .{root_real});

    var reg = source_registry.SourceRegistry.init(gpa, io, data_path, null);
    defer reg.deinit(io);
    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "app",
        .config = .{ .path = logs_path },
        .enabled = true,
    });

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Default `pluginPreset = "auto"` with frontend `timeMode = "source"`:
    //    `daily.log` (mtime 23:59) survives Stage 2 `mtime_guard`, narrows via Stage 3 `time_bisect`,
    //    and matches the 09:30 hit! Meanwhile untimestamped `notes.txt` (unparsed_no_ts, mtime 23:59 > 10:00)
    //    falls back cleanly to `mtime_window` and is excluded!
    var c_auto = PrefilterE2ECollector{ .allocator = gpa };
    defer c_auto.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3001,
        .pattern = "daily_morning_boom",
        .timeMode = "source",
        .timeStartNs = t_09_00,
        .timeEndNs = t_10_00,
    }, &cancel, .{ .ctx = &c_auto, .sendFn = PrefilterE2ECollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_auto.files_matched);
    try std.testing.expectEqual(@as(u64, 1), c_auto.matched_lines);
    try std.testing.expectEqual(@as(usize, 1), c_auto.texts.items.len);
    try std.testing.expect(std.mem.indexOf(u8, c_auto.texts.items[0], "09:30:00Z") != null);
    try std.testing.expect(c_auto.bytes_saved > 0);

    // Continuation stack frame on `daily.log` matches via lookbehind + time_bisect window
    var c_cont = PrefilterE2ECollector{ .allocator = gpa };
    defer c_cont.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3002,
        .pattern = "DailyWorker.run",
        .timeMode = "source",
        .timeStartNs = t_09_00,
        .timeEndNs = t_10_00,
    }, &cancel, .{ .ctx = &c_cont, .sendFn = PrefilterE2ECollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_cont.matched_lines);

    // 2. Request-level `pluginPreset = "code"` skips BOTH files in Stage 2 via `mtime_window` (23:59 > 10:00)
    //    and never leaks stale L1 cache from the `"auto"` run!
    var c_code = PrefilterE2ECollector{ .allocator = gpa };
    defer c_code.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3003,
        .pattern = "daily_morning_boom",
        .timeMode = "source",
        .timeStartNs = t_09_00,
        .timeEndNs = t_10_00,
        .pluginPreset = "code",
    }, &cancel, .{ .ctx = &c_code, .sendFn = PrefilterE2ECollector.send });
    try std.testing.expectEqual(@as(u64, 0), c_code.matched_lines);
    try std.testing.expectEqual(@as(u64, 2), c_code.files_pruned);
    try std.testing.expect(c_code.bytes_saved > 0);
}

test "search_job: rotated app-2026-11-10.log.gz pruned by filename_date without decompressing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "data");
    try tmp.dir.createDirPath(io, "rotated");

    const t_09_00: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 18, 9, 0, 0).? * std.time.ns_per_s);
    const t_10_00: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 18, 10, 0, 0).? * std.time.ns_per_s);
    const t_23_59_ns: i96 = @as(i96, time_parser.civilToEpochSeconds(2026, 11, 18, 23, 59, 0).?) * std.time.ns_per_s;

    // Write deliberately invalid gzip stream inside `app-2026-11-10.log.gz` with today's mtime:
    // if WebGrep attempts decompression, libwebgrep fails with scan error (`had_scan_error`).
    // `filename_date` must prune it at Stage 2 with zero decompression and zero errors!
    const corrupt_gz = "\x1f\x8b\x08\x00CORRUPT_NOT_REAL_GZIP_DO_NOT_DECOMPRESS_today_gz_hit";
    {
        var f = try tmp.dir.createFile(io, "rotated/app-2026-11-10.log.gz", .{ .truncate = true });
        defer f.close(io);
        var wb: [256]u8 = undefined;
        var fw = f.writer(io, &wb);
        try fw.interface.writeAll(corrupt_gz);
        try fw.interface.flush();
        try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = t_23_59_ns } } });
    }
    const valid_gz = try buildTestStoredGzipAlloc(arena, "2026-11-18T09:30:00Z ERROR today_gz_hit\n");
    {
        var f = try tmp.dir.createFile(io, "rotated/app-2026-11-18.log.gz", .{ .truncate = true });
        defer f.close(io);
        var wb: [256]u8 = undefined;
        var fw = f.writer(io, &wb);
        try fw.interface.writeAll(valid_gz);
        try fw.interface.flush();
        try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = t_23_59_ns } } });
    }

    var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rlen = try tmp.dir.realPath(io, &pbuf);
    const root_real = pbuf[0..rlen];
    const data_path = try std.fmt.allocPrint(arena, "{s}/data", .{root_real});
    const rot_path = try std.fmt.allocPrint(arena, "{s}/rotated", .{root_real});

    var reg = source_registry.SourceRegistry.init(gpa, io, data_path, null);
    defer reg.deinit(io);
    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "rot",
        .config = .{ .path = rot_path },
        .enabled = true,
    });

    var cancel = std.atomic.Value(bool).init(false);
    var col = PrefilterE2ECollector{ .allocator = gpa };
    defer col.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3010,
        .pattern = "today_gz_hit",
        .timeMode = "source",
        .timeStartNs = t_09_00,
        .timeEndNs = t_10_00,
    }, &cancel, .{ .ctx = &col, .sendFn = PrefilterE2ECollector.send });

    try std.testing.expect(col.error_msg == null);
    try std.testing.expectEqual(@as(u64, 1), col.files_pruned);
    try std.testing.expectEqual(@as(u64, corrupt_gz.len), col.bytes_saved);
    try std.testing.expectEqual(@as(u64, 1), col.files_matched);
    try std.testing.expectEqual(@as(u64, 1), col.matched_lines);
}

test "search_job: sidecar_sketch persists only under <data_dir>/sketches and prunes Bloom + observed_ts across reload" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "data");
    try tmp.dir.createDirPath(io, "src_logs");

    const log_body =
        "2026-11-18T09:05:00Z INFO boot\n" ++
        "2026-11-18T09:30:00Z ERROR InfluxDB_Timeout db=1\n" ++
        "2026-11-18T09:50:00Z INFO settled\n";
    const t_12_00: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 18, 12, 0, 0).? * std.time.ns_per_s);
    const t_13_00: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 18, 13, 0, 0).? * std.time.ns_per_s);
    const t_09_00: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 18, 9, 0, 0).? * std.time.ns_per_s);
    const t_10_00: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 18, 10, 0, 0).? * std.time.ns_per_s);
    const t_14_00_ns: i96 = @as(i96, time_parser.civilToEpochSeconds(2026, 11, 18, 14, 0, 0).?) * std.time.ns_per_s;

    {
        var f = try tmp.dir.createFile(io, "src_logs/service.log", .{ .truncate = true });
        defer f.close(io);
        var wb: [256]u8 = undefined;
        var fw = f.writer(io, &wb);
        try fw.interface.writeAll(log_body);
        try fw.interface.flush();
        try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = t_14_00_ns } } });
    }

    var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rlen = try tmp.dir.realPath(io, &pbuf);
    const root_real = pbuf[0..rlen];
    const data_path = try std.fmt.allocPrint(arena, "{s}/data", .{root_real});
    const logs_path = try std.fmt.allocPrint(arena, "{s}/src_logs", .{root_real});

    var cancel = std.atomic.Value(bool).init(false);

    {
        var reg = source_registry.SourceRegistry.init(gpa, io, data_path, null);
        defer reg.deinit(io);
        try reg.upsertSource(arena, io, .{
            .kind = "dir",
            .name = "svc",
            .config = .{ .path = logs_path },
            .enabled = true,
        });

        // 1. Full scan populates full-file TrigramBloom in `sidecar_sketch` and persists under `<data_dir>/sketches/`
        var c1 = PrefilterE2ECollector{ .allocator = gpa };
        defer c1.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
            .id = 3020,
            .pattern = "InfluxDB_Timeout",
        }, &cancel, .{ .ctx = &c1, .sendFn = PrefilterE2ECollector.send });
        try std.testing.expectEqual(@as(u64, 1), c1.matched_lines);

        // 2. Time-filtered query populates observed [min_ts, max_ts] (`09:05..09:50`)
        var c2 = PrefilterE2ECollector{ .allocator = gpa };
        defer c2.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
            .id = 3021,
            .pattern = "InfluxDB_Timeout",
            .timeMode = "source",
            .timeStartNs = t_09_00,
            .timeEndNs = t_10_00,
        }, &cancel, .{ .ctx = &c2, .sendFn = PrefilterE2ECollector.send });
        try std.testing.expectEqual(@as(u64, 1), c2.matched_lines);

        // Verify sketch persisted ONLY under `<data_dir>/sketches/` and NEVER inside `src_logs/`
        _ = try tmp.dir.statFile(io, "data/sketches/sidecar_sketches_v1.bin", .{});
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "src_logs/sidecar_sketches_v1.bin", .{}));
        var src_dir = try tmp.dir.openDir(io, "src_logs", .{ .iterate = true });
        defer src_dir.close(io);
        var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
        var lister = libwebgrep.walk_list.Lister.init(src_dir, &scratch);
        var batch: [16]std.Io.Dir.Entry = undefined;
        var src_file_count: usize = 0;
        while (true) {
            const cnt = try lister.fill(io, &batch);
            if (cnt == 0) break;
            src_file_count += cnt;
        }
        try std.testing.expectEqual(@as(usize, 1), src_file_count);
    }

    // Reload fresh SourceRegistry from disk (cold L1/L2/L3 cache; warm reloaded `sidecar_sketch`!)
    {
        var reg2 = source_registry.SourceRegistry.init(gpa, io, data_path, null);
        defer reg2.deinit(io);

        // 3. Disjoint literal anchor skipped via reloaded TrigramBloom (`filesPruned == 1, bytesSaved == log_body.len`)
        var c3 = PrefilterE2ECollector{ .allocator = gpa };
        defer c3.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg2, .{
            .id = 3022,
            .pattern = "TotallyAbsentKeywordXYZ",
        }, &cancel, .{ .ctx = &c3, .sendFn = PrefilterE2ECollector.send });
        try std.testing.expectEqual(@as(u64, 0), c3.matched_lines);
        try std.testing.expectEqual(@as(u64, 1), c3.files_pruned);
        try std.testing.expectEqual(@as(u64, log_body.len), c3.bytes_saved);
        try std.testing.expectEqualStrings("pruned", c3.tier());

        // 4. Disjoint later time window (`12:00..13:00` while mtime=14:00) skipped via reloaded observed [min_ts, max_ts]!
        var c4 = PrefilterE2ECollector{ .allocator = gpa };
        defer c4.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg2, .{
            .id = 3023,
            .pattern = "InfluxDB_Timeout",
            .timeMode = "source",
            .timeStartNs = t_12_00,
            .timeEndNs = t_13_00,
        }, &cancel, .{ .ctx = &c4, .sendFn = PrefilterE2ECollector.send });
        try std.testing.expectEqual(@as(u64, 0), c4.matched_lines);
        try std.testing.expectEqual(@as(u64, 1), c4.files_pruned);
        try std.testing.expectEqual(@as(u64, log_body.len), c4.bytes_saved);
        try std.testing.expectEqualStrings("pruned", c4.tier());

        // 5. Disabling pruning plugins on source invalidates pluginSig so Bloom is bypassed & cache isn't stale
        try reg2.upsertSource(arena, io, .{
            .kind = "dir",
            .name = "svc",
            .config = .{
                .path = logs_path,
                .pluginPreset = "timeseries",
                .plugins = .{ .disable = &.{ "sidecar_sketch", "mtime_guard", "filename_date", "time_bisect" } },
            },
            .enabled = true,
        });
        var c5 = PrefilterE2ECollector{ .allocator = gpa };
        defer c5.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg2, .{
            .id = 3024,
            .pattern = "InfluxDB_Timeout",
            .timeMode = "source",
            .timeStartNs = t_12_00,
            .timeEndNs = t_13_00,
        }, &cancel, .{ .ctx = &c5, .sendFn = PrefilterE2ECollector.send });
        try std.testing.expectEqual(@as(u64, 0), c5.files_pruned);
        try std.testing.expectEqualStrings("none", c5.tier());
    }
}

test "search_job: generic kvPredicates filtering JSON, nested JSON, mixed prefix+JSON, and logfmt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "data");
    try tmp.dir.createDirPath(io, "kv");

    try tmp.dir.writeFile(io, .{
        .sub_path = "kv/events.jsonl",
        .data = "{\"level\":\"ERROR\",\"http\":{\"status\":503},\"latency_ms\":245.5,\"msg\":\"upstream \\\"db\\\" timeout\"}\n" ++
            "{\"level\":\"INFO\",\"http\":{\"status\":200},\"latency_ms\":12.0,\"msg\":\"ok\"}\n" ++
            "2026-11-18T09:30:00Z WARN {\"level\":\"error\",\"http\":{\"status\":503},\"latency_ms\":999,\"msg\":\"mixed slow\"}\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "kv/req.logfmt",
        .data = "ts=2026-11-18T09:30:00Z level=error status=503 latency_ms=310.2 msg=\"upstream timeout\"\n" ++
            "ts=2026-11-18T09:31:00Z level=warn status=200 latency_ms=50 msg=\"fast\"\n",
    });

    var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rlen = try tmp.dir.realPath(io, &pbuf);
    const root_real = pbuf[0..rlen];
    const data_path = try std.fmt.allocPrint(arena, "{s}/data", .{root_real});
    const kv_path = try std.fmt.allocPrint(arena, "{s}/kv", .{root_real});

    var reg = source_registry.SourceRegistry.init(gpa, io, data_path, null);
    defer reg.deinit(io);
    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "kv",
        .config = .{ .path = kv_path },
        .enabled = true,
    });

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Pattern + kvPredicates (latency_ms > 200 and level == error) matches both JSONL lines + logfmt line = 3
    var c1 = PrefilterE2ECollector{ .allocator = gpa };
    defer c1.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3030,
        .pattern = "",
        .kvPredicates = &.{
            .{ .key = "level", .op = "eq", .value = "error", .caseSensitive = false },
            .{ .key = "latency_ms", .op = "gt_num", .value = "200" },
        },
    }, &cancel, .{ .ctx = &c1, .sendFn = PrefilterE2ECollector.send });
    try std.testing.expectEqual(@as(u64, 3), c1.matched_lines);

    // 2. Narrow with nested dotted key `http.status == 503` (only JSONL lines have nested http.status -> 2 lines; isolates L1 cache!)
    var c2 = PrefilterE2ECollector{ .allocator = gpa };
    defer c2.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3031,
        .pattern = "",
        .kvPredicates = &.{
            .{ .key = "level", .op = "eq", .value = "error", .caseSensitive = false },
            .{ .key = "latency_ms", .op = "gt_num", .value = "200" },
            .{ .key = "http.status", .op = "exists" },
            .{ .key = "http.status", .op = "lt_num", .value = "600" },
        },
    }, &cancel, .{ .ctx = &c2, .sendFn = PrefilterE2ECollector.send });
    try std.testing.expectEqual(@as(u64, 2), c2.matched_lines);
    try std.testing.expectEqualStrings("none", c2.tier());

    // 3. Invalid kvPredicate op returns clean error frame
    var c_err = PrefilterE2ECollector{ .allocator = gpa };
    defer c_err.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3032,
        .pattern = "",
        .kvPredicates = &.{
            .{ .key = "level", .op = "invalid_op", .value = "x" },
        },
    }, &cancel, .{ .ctx = &c_err, .sendFn = PrefilterE2ECollector.send });
    try std.testing.expect(c_err.error_msg != null);
}

test "search_job: PositionalWindowReader bounded zero-mmap window scan stops cleanly at end_byte" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const p1 = "2026-11-18T08:00:00Z INFO target_token BEFORE_WINDOW\n";
    const p2 = "2026-11-18T09:30:00Z ERROR target_token IN_WINDOW\n";
    const p3 = "2026-11-18T11:00:00Z INFO target_token AFTER_WINDOW_MUST_NOT_BE_READ\n";
    const payload = p1 ++ p2 ++ p3;
    try tmp.dir.writeFile(io, .{ .sub_path = "window.log", .data = payload });

    var f = try tmp.dir.openFile(io, "window.log", .{ .allow_directory = false });
    defer f.close(io);

    var win_reader = PositionalWindowReader{
        .io = io,
        .file = f,
        .cur_pos = p1.len,
        .end_pos = p1.len + p2.len,
    };
    win_reader.bindInterface();

    const WindowSink = struct {
        matched: u64 = 0,
        last_raw_offset: u64 = 0,

        pub fn control(_: *const @This()) libwebgrep.Flow {
            return .stop;
        }
        pub fn event(self: *@This(), ev: libwebgrep.Event) libwebgrep.Flow {
            switch (ev) {
                .match => |line| {
                    self.matched += 1;
                    self.last_raw_offset = line.raw_offset;
                },
                else => {},
            }
            return .cont;
        }
    };

    var sink = WindowSink{};
    const finder = try libwebgrep.Finder.init("target_token", EngineLimits.findOptions(.sensitive));
    var scratch = libwebgrep.Scratch.init(gpa);
    defer scratch.deinit();

    var cfg = libwebgrep.SearchConfig{
        .line_numbers = true,
        .allocator = gpa,
        .decode_allocator = gpa,
        .scratch_pool = &scratch,
        .max_source_bytes = EngineLimits.max_source_bytes,
        .max_request_bytes = EngineLimits.max_request_bytes,
        .max_output_bytes = EngineLimits.max_output_bytes,
        .time_budget_ns = EngineLimits.time_budget_ns,
        .max_decode_bytes = EngineLimits.max_decode_bytes,
        .max_decompressed_bytes = EngineLimits.max_decompressed_bytes,
    };
    _ = &cfg;

    const res = try libwebgrep.searchSource(WindowSink, gpa, &sink, &win_reader.interface, "window.log", &finder, cfg);
    try std.testing.expect(res.scanned_all);
    try std.testing.expectEqual(@as(u64, 1), sink.matched);
    try std.testing.expectEqual(@as(u64, p2.len), res.bytes_read);
    try std.testing.expectEqual(@as(u64, p1.len), p1.len + sink.last_raw_offset);
}
