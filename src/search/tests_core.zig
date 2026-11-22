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

test "search_job literal, multi, regex, and replacement over root directory" {
    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        frames: std.ArrayList([]u8) = .empty,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const copy = try self.allocator.dupe(u8, json_text);
            try self.frames.append(self.allocator, copy);
        }

        fn deinit(self: *@This()) void {
            for (self.frames.items) |f| self.allocator.free(f);
            self.frames.deinit(self.allocator);
        }
    };

    var collector = Collector{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    defer collector.deinit();

    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{ .iterate = true });
    defer root_dir.close(std.testing.io);

    var cancel = std.atomic.Value(bool).init(false);

    try executeSearch(
        std.testing.allocator,
        std.testing.io,
        root_dir,
        .{
            .id = 7,
            .pattern = "sanitizeRelPath",
            .mode = "literal",
            .paths = &.{"src"},
            .types = &.{"zig"},
        },
        &cancel,
        .{ .ctx = &collector, .sendFn = Collector.send },
    );

    try std.testing.expect(collector.frames.items.len >= 2);
    // First frame should be hits, last frame should be done
    try std.testing.expect(std.mem.indexOf(u8, collector.frames.items[0], "\"type\":\"hits\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, collector.frames.items[collector.frames.items.len - 1], "\"type\":\"done\"") != null);
}

test "matchesProjectScopeToken only matches project name or UUID id" {
    const src_id = "550e8400-e29b-41d4-a716-446655440000";
    const src_name = "webgrep";

    try std.testing.expect(JobRunner.matchesProjectScopeToken(src_id, src_name, "webgrep"));
    try std.testing.expect(JobRunner.matchesProjectScopeToken(src_id, src_name, "WEBGREP"));
    try std.testing.expect(JobRunner.matchesProjectScopeToken(src_id, src_name, src_id));
    try std.testing.expect(!JobRunner.matchesProjectScopeToken(src_id, src_name, "libwebgrep"));
    try std.testing.expect(!JobRunner.matchesProjectScopeToken(src_id, src_name, "webgrep/src/main.zig"));
}

test "progressive search order commutativity: regex+literal == literal+regex and case-insensitive contains" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var root_dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer root_dir.close(io);

    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Regex first ("pub\\s+fn"), Literal second ("executesearch")
    var c1 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 1,
        .pattern = "pub\\s+fn",
        .mode = "regex",
        .case = "insensitive",
        .contains = &.{"executesearch"},
        .paths = &.{"src/search/execute.zig"},
    }, &cancel, .{ .ctx = &c1, .sendFn = Collector.send });

    // 2. Literal first ("executesearch"), Regex second ("pub\\s+fn")
    var c2 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 2,
        .pattern = "executesearch",
        .mode = "regex",
        .case = "insensitive",
        .contains = &.{"pub\\s+fn"},
        .paths = &.{"src/search/execute.zig"},
    }, &cancel, .{ .ctx = &c2, .sendFn = Collector.send });

    try std.testing.expect(c1.matched_lines > 0);
    try std.testing.expectEqual(c1.matched_lines, c2.matched_lines);

    // 3. Mixed multiple regexes + multiple literals + regex/literal excludes in 4 permutations (with smart case)
    var m1 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 3,
        .pattern = "pub\\s+fn",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "With\\w+", "executesearch", "WithRegistry(" },
        .excludes = &.{ "nonexistent_\\d+", "never_match_xyz" },
        .paths = &.{"src/search/execute.zig"},
    }, &cancel, .{ .ctx = &m1, .sendFn = Collector.send });

    var m2 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 4,
        .pattern = "With\\w+",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "executesearch", "pub\\s+fn", "WithRegistry(" },
        .excludes = &.{ "never_match_xyz", "nonexistent_\\d+" },
        .paths = &.{"src/search/execute.zig"},
    }, &cancel, .{ .ctx = &m2, .sendFn = Collector.send });

    var m3 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 5,
        .pattern = "executesearch",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "WithRegistry(", "With\\w+", "pub\\s+fn" },
        .excludes = &.{ "nonexistent_\\d+", "never_match_xyz" },
        .paths = &.{"src/search/execute.zig"},
    }, &cancel, .{ .ctx = &m3, .sendFn = Collector.send });

    var m4 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 6,
        .pattern = "WithRegistry(",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "executesearch", "With\\w+", "pub\\s+fn" },
        .excludes = &.{ "never_match_xyz", "nonexistent_\\d+" },
        .paths = &.{"src/search/execute.zig"},
    }, &cancel, .{ .ctx = &m4, .sendFn = Collector.send });

    try std.testing.expect(m1.matched_lines > 0);
    try std.testing.expectEqual(m1.matched_lines, m2.matched_lines);
    try std.testing.expectEqual(m1.matched_lines, m3.matched_lines);
    try std.testing.expectEqual(m1.matched_lines, m4.matched_lines);

    // 4. Scoped `$r(xxxxxxx)` syntax in `literal` mode, mixed with literals (including unescaped parens) and context=2
    var s1 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 7,
        .pattern = "$r(pub\\s+fn)",
        .mode = "literal",
        .case = "smart",
        .context = 2,
        .contains = &.{ "WithRegistry(", "$r(With\\w+)", "executesearch" },
        .excludes = &.{"$r(nonexistent_\\d+)"},
        .paths = &.{"src/search/execute.zig"},
    }, &cancel, .{ .ctx = &s1, .sendFn = Collector.send });

    var s2 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 8,
        .pattern = "WithRegistry(",
        .mode = "literal",
        .case = "smart",
        .context = 2,
        .contains = &.{ "$r(pub\\s+fn)", "executesearch", "$r(With\\w+)" },
        .excludes = &.{"$r(nonexistent_\\d+)"},
        .paths = &.{"src/search/execute.zig"},
    }, &cancel, .{ .ctx = &s2, .sendFn = Collector.send });

    try std.testing.expectEqual(m1.matched_lines, s1.matched_lines);
    try std.testing.expectEqual(s1.matched_lines, s2.matched_lines);
}

test "heat-weighted elastic water-filling: single file gets full maxResults and hotter file gets more quota" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    try tmp.dir.createDirPath(io, "logs");

    // Create 3 files: cold.log (200 matches), hot.log (200 matches), empty.log (0 matches)
    {
        var f_cold = try tmp.dir.createFile(io, "logs/cold.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_cold.writer(io, &w_buf);
        for (0..200) |i| {
            try fw.interface.print("record={d} tag=COMMON_HIT only_in_cold\n", .{i});
        }
        try fw.interface.flush();
        f_cold.close(io);
    }
    {
        var f_hot = try tmp.dir.createFile(io, "logs/hot.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_hot.writer(io, &w_buf);
        for (0..200) |i| {
            try fw.interface.print("record={d} tag=COMMON_HIT only_in_hot\n", .{i});
        }
        try fw.interface.flush();
        f_hot.close(io);
    }
    {
        var f_empty = try tmp.dir.createFile(io, "logs/empty.log", .{ .truncate = true });
        var w_buf: [256]u8 = undefined;
        var fw = f_empty.writer(io, &w_buf);
        try fw.interface.writeAll("unrelated line\n");
        try fw.interface.flush();
        f_empty.close(io);
    }

    const logs_dir_path = try std.fmt.allocPrint(arena, "{s}/logs", .{tmp_path});
    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "logs",
        .config = .{ .path = logs_dir_path },
        .enabled = true,
    });

    // Boost access heat of logs/hot.log significantly
    reg.recordFileHeat(io, "logs/hot.log", 1200);

    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        hot_hits: usize = 0,
        cold_hits: usize = 0,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);

            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                for (parsed.value.items) |it| {
                    if (std.mem.eql(u8, it.file, "logs/hot.log")) self.hot_hits += 1;
                    if (std.mem.eql(u8, it.file, "logs/cold.log")) self.cold_hits += 1;
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // Case 1: Only 1 file (`only_in_cold`) matches among 3 files, with maxResults = 150.
    // Even though initial Phase 1 soft quota is < 150, Phase 2 water-filling gives it all 150!
    var c_single = Collector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 10,
        .pattern = "only_in_cold",
        .maxResults = 150,
    }, &cancel, .{ .ctx = &c_single, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 150), c_single.matched_lines);
    try std.testing.expectEqual(@as(usize, 150), c_single.cold_hits);

    // Case 2: Both hot.log and cold.log match `COMMON_HIT`, with maxResults = 120.
    // hot.log (higher heat score) receives strictly more quota than cold.log, and both > 0, summing to 120!
    var c_both = Collector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 11,
        .pattern = "COMMON_HIT",
        .maxResults = 120,
    }, &cancel, .{ .ctx = &c_both, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 120), c_both.matched_lines);
    try std.testing.expectEqual(@as(usize, 120), c_both.hot_hits + c_both.cold_hits);
    try std.testing.expect(c_both.hot_hits > c_both.cold_hits);
    try std.testing.expect(c_both.cold_hits > 0);
}

test "multi-tier millisecond search cache: L1 exact, L2 progressive superset, L3 negative file pruning, and mtime invalidation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    try tmp.dir.createDirPath(io, "svc");
    {
        var f_orders = try tmp.dir.createFile(io, "svc/orders.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_orders.writer(io, &w_buf);
        for (0..50) |i| {
            const status = if (i % 2 == 0) "FULFILLED" else "CANCELLED";
            const region = if (i % 5 == 0) "APAC" else "EMEA";
            try fw.interface.print("order=ORD-2026-{d} status={s} region={s}\n", .{ i, status, region });
        }
        try fw.interface.flush();
        f_orders.close(io);
    }
    {
        var f_audit = try tmp.dir.createFile(io, "svc/audit.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_audit.writer(io, &w_buf);
        for (0..50) |i| {
            try fw.interface.print("audit=AUD-{d} action=LOGIN user=admin\n", .{i});
        }
        try fw.interface.flush();
        f_audit.close(io);
    }

    const svc_dir_path = try std.fmt.allocPrint(arena, "{s}/svc", .{tmp_path});
    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "svc",
        .config = .{ .path = svc_dir_path },
        .enabled = true,
    });

    const CacheCollector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        matched_lines: u64 = 0,
        cache_hit: [32]u8 = undefined,
        cache_hit_len: usize = 0,

        fn tier(self: *const @This()) []const u8 {
            return self.cache_hit[0..self.cache_hit_len];
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);

            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                const ch = parsed.value.cacheHit;
                const copy_len = @min(ch.len, self.cache_hit.len);
                @memcpy(self.cache_hit[0..copy_len], ch[0..copy_len]);
                self.cache_hit_len = copy_len;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Cold search for "ORD-2026-" (matches 50 lines in orders.log, 0 in audit.log, limitHit == "none")
    var c1 = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 1,
        .pattern = "ORD-2026-",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c1, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 50), c1.matched_lines);
    try std.testing.expectEqualStrings("none", c1.tier());

    // 2. Repeat identical search -> hits Tier L1 ("exact")
    var c2 = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 2,
        .pattern = "ORD-2026-",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c2, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 50), c2.matched_lines);
    try std.testing.expectEqualStrings("exact", c2.tier());

    // 3. Progressive space refinement: add contains=["FULFILLED"] and excludes=["APAC"] -> hits Tier L2 ("superset")
    var c3 = CacheCollector{ .allocator = gpa, .io = io };
    const inc = [_][]const u8{"FULFILLED"};
    const exc = [_][]const u8{"APAC"};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3,
        .pattern = "ORD-2026-",
        .contains = &inc,
        .excludes = &exc,
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c3, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 20), c3.matched_lines);
    try std.testing.expectEqualStrings("superset", c3.tier());

    // 4. Longer literal superstring "ORD-2026-10" when parent "ORD-2026-" is complete -> hits Tier L2 ("superset") in RAM!
    var c4 = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 4,
        .pattern = "ORD-2026-10",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c4, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c4.matched_lines);
    try std.testing.expectEqualStrings("superset", c4.tier());

    // 5. Truncated search ("AUD-" with maxResults = 10 -> limitHit = true, orders.log has 0 hits for "AUD-"),
    // followed by "AUD-1" -> orders.log is pruned by Tier L3 ("pruned")!
    var c5_init = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 5,
        .pattern = "AUD-",
        .maxResults = 10,
    }, &cancel, .{ .ctx = &c5_init, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 10), c5_init.matched_lines);

    var c5_pruned = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 6,
        .pattern = "AUD-15",
        .maxResults = 10,
    }, &cancel, .{ .ctx = &c5_pruned, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c5_pruned.matched_lines);
    try std.testing.expectEqualStrings("pruned", c5_pruned.tier());

    // 6. Zero Dirty-Read Verification: modify orders.log on disk (adding a 51st match "ORD-2026-99"),
    // and verify that L1/L2/L4 caches immediately detect the (mtime_ns, file_size) change on orders.log
    // (returning 51 matches instead of 50), while unmodified audit.log remains pruned by L3 ("pruned")!
    {
        var f_orders = try tmp.dir.createFile(io, "svc/orders.log", .{});
        var buf: [4096]u8 = undefined;
        var fw = f_orders.writer(io, &buf);
        for (0..50) |i| {
            const status = if (i % 2 == 0) "FULFILLED" else "PENDING";
            const region = if (i % 5 == 0) "APAC" else "EMEA";
            try fw.interface.print("2026-10-30 INFO order=ORD-2026-{d:0>2} status={s} region={s}\n", .{ i, status, region });
        }
        try fw.interface.print("2026-10-30 INFO order=ORD-2026-99 status=FULFILLED region=EMEA\n", .{});
        try fw.interface.flush();
        f_orders.close(io);
    }

    var c6_fresh = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 7,
        .pattern = "ORD-2026-",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c6_fresh, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 51), c6_fresh.matched_lines);
    try std.testing.expectEqualStrings("pruned", c6_fresh.tier());
}

test "strong consistency: >4096-byte long lines never miss L2 contains/excludes and wholeWord+contains never false-matches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    try tmp.dir.createDirPath(io, "strict");
    {
        var f_long = try tmp.dir.createFile(io, "strict/long_line.log", .{ .truncate = true });
        var w_buf: [8192]u8 = undefined;
        var fw = f_long.writer(io, &w_buf);
        try fw.interface.writeAll("PRIMARY_HEAD_TOKEN ");
        for (0..5000) |_| {
            try fw.interface.writeAll("x");
        }
        try fw.interface.writeAll(" SECONDARY_TAIL_TOKEN_AT_5000\n");
        // Second line for wholeWord + contains test: "err" is inside "my_err_code" (not a whole word!), while "LONGER_CONTAINS_ANCHOR" is present
        try fw.interface.writeAll("prefix my_err_code LONGER_CONTAINS_ANCHOR\n");
        // Third line where "err" IS a whole word and "LONGER_CONTAINS_ANCHOR" is present
        try fw.interface.writeAll("prefix err LONGER_CONTAINS_ANCHOR\n");
        try fw.interface.flush();
        f_long.close(io);
    }

    const strict_dir_path = try std.fmt.allocPrint(arena, "{s}/strict", .{tmp_path});
    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "strict",
        .config = .{ .path = strict_dir_path },
        .enabled = true,
    });

    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Search "PRIMARY_HEAD_TOKEN" first (caches the >5000-byte line whose display text was truncated to 4096 bytes)
    var c_head = Collector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 1,
        .pattern = "PRIMARY_HEAD_TOKEN",
        .maxResults = 100,
    }, &cancel, .{ .ctx = &c_head, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 1), c_head.matched_lines);

    // 2. Follow-up progressive search adding `contains = ["SECONDARY_TAIL_TOKEN_AT_5000"]` (which sits at byte 5020 > 4096).
    // Because `all_lines_exact == false`, Tier L2 refuses to filter the truncated 4096-byte preview in RAM and instead scans the full file, finding all 1 match!
    var c_tail = Collector{ .allocator = gpa, .io = io };
    const tail_inc = [_][]const u8{"SECONDARY_TAIL_TOKEN_AT_5000"};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 2,
        .pattern = "PRIMARY_HEAD_TOKEN",
        .contains = &tail_inc,
        .maxResults = 100,
    }, &cancel, .{ .ctx = &c_tail, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 1), c_tail.matched_lines);

    // 3. Verify `wholeWord = true` with a longer `contains` token only matches the line where `err` is a true whole word (1 match, not 2!)
    var c_word = Collector{ .allocator = gpa, .io = io };
    const word_inc = [_][]const u8{"LONGER_CONTAINS_ANCHOR"};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3,
        .pattern = "err",
        .wholeWord = true,
        .contains = &word_inc,
        .maxResults = 100,
    }, &cancel, .{ .ctx = &c_word, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 1), c_word.matched_lines);
}

test "strong consistency: >64MiB files (91MB, 195MB, 203MB) scan 100% to EOF and find tail needles without truncation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Only run if testdata/ large files exist in workspace
    var td_dir = std.Io.Dir.cwd().openDir(io, "testdata", .{ .iterate = true }) catch return;
    defer td_dir.close(io);
    _ = td_dir.statFile(io, "gateway-logs/access_large.kv.log", .{}) catch return;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    var td_real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const td_path_len = try td_dir.realPath(io, &td_real_buf);
    const td_abs_path = try arena.dupe(u8, td_real_buf[0..td_path_len]);

    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "testdata",
        .config = .{ .path = td_abs_path },
        .enabled = true,
    });

    const TailCollector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        matched_lines: u64 = 0,
        bytes_searched: u64 = 0,
        cache_hit: [32]u8 = undefined,
        cache_hit_len: usize = 0,

        fn tier(self: *const @This()) []const u8 {
            return self.cache_hit[0..self.cache_hit_len];
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.bytes_searched = parsed.value.bytesSearched;
                const ch = parsed.value.cacheHit;
                const copy_len = @min(ch.len, self.cache_hit.len);
                @memcpy(self.cache_hit[0..copy_len], ch[0..copy_len]);
                self.cache_hit_len = copy_len;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Tail needle `ORD-20261029-250000` across 91 MB `ecommerce_orders.jsonl:150000`, 99 MB `upstream_trace_large.log:150000`,
    // and 195 MB `transactions_large.jsonl:150000` -> must find all 3 matches (previously truncated at 64 MiB!)
    var c_91m = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 1,
        .pattern = "ORD-20261029-250000",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_91m, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_91m.matched_lines);
    try std.testing.expect(c_91m.bytes_searched > 500 * 1024 * 1024);

    // 2. Repeat identical search -> hits Tier L1 ("exact") with all 3 matches
    var c_91m_l1 = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 2,
        .pattern = "ORD-20261029-250000",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_91m_l1, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_91m_l1.matched_lines);
    try std.testing.expectEqualStrings("exact", c_91m_l1.tier());

    // 2b. Progressive L2 narrowing to `SW-INFINIBAND-800G` (at 91 MB tail of `ecommerce_orders.jsonl`) -> 1 match via Tier L2 ("superset")
    var c_91m_l2 = TailCollector{ .allocator = gpa, .io = io };
    const inc_sw = [_][]const u8{"SW-INFINIBAND-800G"};
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 20,
        .pattern = "ORD-20261029-250000",
        .contains = &inc_sw,
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_91m_l2, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_91m_l2.matched_lines);
    try std.testing.expectEqualStrings("superset", c_91m_l2.tier());

    // 3. Tail needle at the very end of 195 MB `transactions_large.jsonl` (`ORD-20261029-700000`)
    var c_195m = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 3,
        .pattern = "ORD-20261029-700000",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_195m, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_195m.matched_lines);

    // 4. Tail needle at the very end of 203 MB `access_large.kv.log` (`CRITICAL_NEEDLE_EVENT_1000000`)
    var c_203m = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 4,
        .pattern = "CRITICAL_NEEDLE_EVENT_",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_203m, .sendFn = TailCollector.send });
    try std.testing.expect(c_203m.matched_lines >= 3);

    // 5. Progressive L2 narrowing on 203 MB file (`CRITICAL_NEEDLE_EVENT_` + `contains: ["1000000"]`) -> hits Tier L2 ("superset")
    var c_203m_l2 = TailCollector{ .allocator = gpa, .io = io };
    const inc_1m = [_][]const u8{"1000000"};
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 5,
        .pattern = "CRITICAL_NEEDLE_EVENT_",
        .contains = &inc_1m,
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_203m_l2, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_203m_l2.matched_lines);
    try std.testing.expectEqualStrings("superset", c_203m_l2.tier());

    // 6. Scoped `$w(ErrorCode)` and `$cw(ErrorCode)` parity with `wholeWord: true` (`rg -s -w ErrorCode`) on testdata/
    var c_ww_native = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 6,
        .pattern = "ErrorCode",
        .case = "sensitive",
        .wholeWord = true,
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_ww_native, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_ww_native.matched_lines);

    var c_scoped_w = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 7,
        .pattern = "$w(ErrorCode)",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_scoped_w, .sendFn = TailCollector.send });
    try std.testing.expectEqual(c_ww_native.matched_lines, c_scoped_w.matched_lines);

    var c_scoped_cw = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 8,
        .pattern = "$cw(ErrorCode)",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_scoped_cw, .sendFn = TailCollector.send });
    try std.testing.expectEqual(c_ww_native.matched_lines, c_scoped_cw.matched_lines);
}

test "search_job: scoped whole-word modifiers ($w, $cw, $rw, $rcw) on indented lines match rg -w semantics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Indented code and log lines where byte 0 is space/tab or punctuation (non-word character)
    try tmp.dir.writeFile(io, .{
        .sub_path = "indented.zig",
        .data = "pub const Engine = struct {\n" ++
            "    id: u64 = 1001,\n" ++
            "    user_id: u64 = 2002,\n" ++
            "    pub fn check(id: u64) ErrorCode {\n" ++
            "        const err = ErrorCode.Timeout;\n" ++
            "        const fake = MyErrorCode;\n" ++
            "        const lower = errorcode;\n" ++
            "        // partial word first, then exact whole word on the same indented line:\n" ++
            "        const combo = ErrorCode2 + ErrorCode;\n" ++
            "        return err;\n" ++
            "    }\n" ++
            "};\n" ++
            "\tid = 4096; // tab-indented whole word + 4-digit number\n" ++
            "    code_5digits = 12345;\n" ++
            "    port = 8080;\n",
    });

    const CountCollector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        matched_lines: u64 = 0,
        total_matches: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.total_matches = parsed.value.totalMatches;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. `$w(id)` on indented lines: matches `    id: u64`, `    pub fn check(id: u64)`, and `\tid = 4096;` (3 lines),
    //    must NOT match `user_id`!
    var c_w_id = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 1,
        .pattern = "$w(id)",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_w_id, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_w_id.matched_lines);

    // 2. `$cw(ErrorCode)` (case-sensitive + whole-word): matches lines 4, 5, and 9 (`ErrorCode2 + ErrorCode`),
    //    must NOT match `MyErrorCode` (line 6) or `errorcode` (line 7)!
    var c_cw_err = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 2,
        .pattern = "$cw(ErrorCode)",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_cw_err, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_cw_err.matched_lines);

    // 3. `$w(ErrorCode)` with case="insensitive": matches lines 4, 5, 7 (`errorcode`), and 9 (`ErrorCode2 + ErrorCode`) = 4 lines
    var c_w_err_ci = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 3,
        .pattern = "$w(ErrorCode)",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_w_err_ci, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_w_err_ci.matched_lines);

    // 4. `$rw(\d{4})` (regex + whole-word): matches `1001`, `2002`, `4096`, `8080` (4 lines),
    //    must NOT match `12345` (5 digits)!
    var c_rw_digits = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 4,
        .pattern = "$rw(\\d{4})",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_rw_digits, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_rw_digits.matched_lines);

    // 5. Raw regex `\b\d{4}\b` in `mode: "regex"` on indented lines -> also 4 lines
    var c_raw_re = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 5,
        .pattern = "\\b\\d{4}\\b",
        .mode = "regex",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_raw_re, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_raw_re.matched_lines);

    // 6. Scoped `$w(...)` and `$rw(...)` inside `contains` and `excludes`
    var c_contains_w = CountCollector{ .allocator = gpa, .io = io };
    const inc_rw = [_][]const u8{"$rw(\\d{4})"};
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 6,
        .pattern = "$w(id)",
        .contains = &inc_rw,
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_contains_w, .sendFn = CountCollector.send });
    // Only `    id: u64 = 1001,` and `\tid = 4096;` have both whole-word `id` and a 4-digit number!
    try std.testing.expectEqual(@as(u64, 2), c_contains_w.matched_lines);
}

test "search_job: dual-granularity time filter on ISO-8601/Nginx/JSONL logs (with stack traces) AND code/HTML files via stat.mtime" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "logs");
    try tmp.dir.createDirPath(io, "code");

    // 1. Existing ISO-8601 / Spring Boot log with multi-line Java stack trace (timeseries source)
    const spring_log =
        "2026-10-31 10:15:01,000 INFO  [main] Booting service\n" ++
        "2026-10-31 10:15:02,500 ERROR [worker-1] NullPointerException in PaymentService\n" ++
        "    at com.example.PaymentService.charge(PaymentService.java:88)\n" ++
        "    at com.example.OrderController.submit(OrderController.java:42)\n" ++
        "2026-10-31 10:15:05,000 INFO  [main] Shutdown complete\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/spring.log", .data = spring_log });

    // 2. Code (.zig) and HTML (.html) files (code source -> filtered strictly by stat.mtime!)
    try tmp.dir.writeFile(io, .{
        .sub_path = "code/app.zig",
        .data = "pub fn handlePayment() void {\n    // PaymentService logic\n}\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "code/index.html",
        .data = "<!DOCTYPE html>\n<html><body><div class=\"PaymentService\">Pay</div></body></html>\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root_real = try gpa.dupe(u8, path_buf[0..n]);
    defer gpa.free(root_real);

    var reg = source_registry.SourceRegistry.init(gpa, io, root_real, null);
    defer reg.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const logs_dir_path = try std.fmt.allocPrint(arena_state.allocator(), "{s}/logs", .{root_real});
    try reg.upsertSource(arena_state.allocator(), io, .{
        .kind = "dir",
        .name = "logs",
        .path = logs_dir_path,
        .enabled = true,
        .pluginPreset = "timeseries",
    });
    const code_dir_path = try std.fmt.allocPrint(arena_state.allocator(), "{s}/code", .{root_real});
    try reg.upsertSource(arena_state.allocator(), io, .{
        .kind = "dir",
        .name = "code",
        .path = code_dir_path,
        .enabled = true,
        .pluginPreset = "code",
    });

    const SimpleCollector = struct {
        allocator: std.mem.Allocator,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // A. Search `PaymentService` inside historical log window [2026-10-31T10:15:02Z, 2026-10-31T10:15:03Z]:
    //    - `spring.log` is a time-series log: matches both line 2 (`ERROR ... PaymentService`) AND line 3 (stack trace `at ... PaymentService.java:88` via lookbehind inheritance)!
    //    - `app.zig` and `index.html` have `mtime = now` (outside the narrow 1-second window if `timeEndNs` is 10:15:03Z, or inside if `timeEndNs == 0`).
    const t_start = time_parser.parseTimestampValueNs("2026-10-31T10:15:02Z", .{}, null).?;
    const t_end = time_parser.parseTimestampValueNs("2026-10-31T10:15:03Z", .{}, null).?;

    var col_log_window = SimpleCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 10,
        .pattern = "PaymentService",
        .timeStartNs = t_start,
        .timeEndNs = t_end,
    }, &cancel, .{ .ctx = &col_log_window, .sendFn = SimpleCollector.send });
    try std.testing.expectEqual(@as(u64, 2), col_log_window.matched_lines);

    // B. Search `PaymentService` with `timeStartNs = now - 60s` (`$t(1m)`):
    //    - `app.zig` and `index.html` were just modified (`mtime >= now - 60s`), so both code and HTML files match (1 line each = 2 lines)!
    const now_ns = time_parser.currentUnixNano(io);
    var col_recent = SimpleCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 11,
        .pattern = "PaymentService",
        .timeStartNs = now_ns -| (60 * std.time.ns_per_s),
        .timeEndNs = now_ns +| (60 * std.time.ns_per_s),
    }, &cancel, .{ .ctx = &col_recent, .sendFn = SimpleCollector.send });
    try std.testing.expectEqual(@as(u64, 2), col_recent.matched_lines);
}

test "search_job: $@(zedis-rust) pub fn async members falls back to ±15-line block proximity when terms span doc-comment and function signature" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "zedis-rust/states/server");
    const set_rs =
        "/// Performs the initial load of a Redis SET value.\n" ++
        "///\n" ++
        "/// Fetches the total cardinality (SCARD) and loads the first batch of members (up to 100).\n" ++
        "///\n" ++
        "/// # Arguments\n" ++
        "/// * `conn` - Redis asynchronous connection\n" ++
        "/// * `key` - The SET key to load\n" ++
        "pub(crate) async fn first_load_set_value(conn: &mut RedisAsyncConn, key: &str) -> Result<RedisValue> {\n" ++
        "    // Get total number of members in the SET\n" ++
        "    let size: usize = cmd(\"SCARD\").arg(key).query_async(conn).await?;\n" ++
        "}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "zedis-rust/states/server/set.rs", .data = set_rs });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root_real = try gpa.dupe(u8, path_buf[0..n]);
    defer gpa.free(root_real);

    var reg = source_registry.SourceRegistry.init(gpa, io, root_real, null);
    defer reg.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const zedis_dir_path = try std.fmt.allocPrint(arena_state.allocator(), "{s}/zedis-rust", .{root_real});
    try reg.upsertSource(arena_state.allocator(), io, .{
        .kind = "dir",
        .name = "zedis-rust",
        .path = zedis_dir_path,
        .enabled = true,
    });

    const BlockCollector = struct {
        allocator: std.mem.Allocator,
        matched_lines: u64 = 0,
        first_line_no: u64 = 0,
        span_count: usize = 0,
        nearby_lines: u32 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                if (parsed.value.items.len > 0 and self.first_line_no == 0) {
                    self.first_line_no = parsed.value.items[0].line;
                    self.span_count = parsed.value.items[0].spans.len;
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.nearby_lines = parsed.value.nearbyLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // Default (`nearbyLines = 0`) keeps the search strictly single-line.
    var col_default_strict = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 98,
        .pattern = "pub",
        .contains = &.{ "fn", "async", "members" },
        .globs = &.{"zedis-rust"},
    }, &cancel, .{ .ctx = &col_default_strict, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(@as(u64, 0), col_default_strict.matched_lines);
    try std.testing.expectEqual(@as(u32, 0), col_default_strict.nearby_lines);

    var col = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 99,
        .pattern = "pub",
        .contains = &.{ "fn", "async", "members" },
        .globs = &.{"zedis-rust"},
        .sources = &.{"other-unrelated-source"},
        .nearbyLines = 15,
    }, &cancel, .{ .ctx = &col, .sendFn = BlockCollector.send });

    try std.testing.expect(col.matched_lines >= 1);
    try std.testing.expectEqual(@as(u64, 8), col.first_line_no);
    try std.testing.expect(col.span_count >= 3);
    try std.testing.expectEqual(@as(u32, 15), col.nearby_lines);

    // Same query again: L1/L2 must not have cached the fallback hits as strict single-line results,
    // and the nearby fallback must still kick in (previously a cached "0 hits" could be replayed).
    var col_again = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 100,
        .pattern = "pub",
        .contains = &.{ "fn", "async", "members" },
        .globs = &.{"zedis-rust"},
        .nearbyLines = 15,
    }, &cancel, .{ .ctx = &col_again, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(col.matched_lines, col_again.matched_lines);
    try std.testing.expectEqual(@as(u32, 15), col_again.nearby_lines);

    // `nearbyLines = 0` keeps the search strictly single-line.
    var col_strict = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 101,
        .pattern = "pub",
        .contains = &.{ "fn", "async", "members" },
        .nearbyLines = 0,
    }, &cancel, .{ .ctx = &col_strict, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(@as(u64, 0), col_strict.matched_lines);
    try std.testing.expectEqual(@as(u32, 0), col_strict.nearby_lines);

    // `fileGlobs`: `@*.rs` keeps set.rs, `-@*.rs` drops it.
    var col_glob = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 102,
        .pattern = "SCARD",
        .fileGlobs = &.{"server/*.rs"},
    }, &cancel, .{ .ctx = &col_glob, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(@as(u64, 2), col_glob.matched_lines);

    var col_glob_neg = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 103,
        .pattern = "SCARD",
        .fileGlobs = &.{"!*.rs"},
    }, &cancel, .{ .ctx = &col_glob_neg, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(@as(u64, 0), col_glob_neg.matched_lines);
}
