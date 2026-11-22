const std = @import("std");
const libwebgrep = @import("libwebgrep");
const calendar = @import("calendar.zig");
const universal = @import("universal.zig");
const strftime = @import("strftime.zig");
const extractors = @import("extractors.zig");
const slice_narrow = @import("slice_narrow.zig");

const TimeMode = calendar.TimeMode;
const FallbackTimeContext = calendar.FallbackTimeContext;
const PrefixEpochCache = calendar.PrefixEpochCache;
const CivilDateTime = calendar.CivilDateTime;
const civilToEpochSeconds = calendar.civilToEpochSeconds;
const epochSecondsToCivil = calendar.epochSecondsToCivil;
const parseTimestampValueNs = universal.parseTimestampValueNs;
const parseUniversalLineNs = universal.parseUniversalLineNs;
const StrftimeProg = strftime.StrftimeProg;
const JsonFieldProg = extractors.JsonFieldProg;
const RegexCaptureProg = extractors.RegexCaptureProg;
const CompiledTimeParser = extractors.CompiledTimeParser;
const TimeHookAdapter = extractors.TimeHookAdapter;
const isLikelyContinuationLine = slice_narrow.isLikelyContinuationLine;
const findLineTimestampWithLookbehind = slice_narrow.findLineTimestampWithLookbehind;
const SliceTimeStatus = slice_narrow.SliceTimeStatus;
const NarrowedSlice = slice_narrow.NarrowedSlice;
const narrowSliceByTimeParser = slice_narrow.narrowSliceByTimeParser;
const TimePreviewResponse = slice_narrow.TimePreviewResponse;
const buildTimePreviewJson = slice_narrow.buildTimePreviewJson;

test "time_parser: civilToEpochSeconds round-trip and PrefixEpochCache + tzOffsetMin" {
    const t0 = civilToEpochSeconds(2026, 11, 14, 9, 15, 2).?;
    const rev = epochSecondsToCivil(t0).?;
    try std.testing.expectEqual(@as(u16, 2026), rev.year);
    try std.testing.expectEqual(@as(u8, 11), rev.month);
    try std.testing.expectEqual(@as(u8, 14), rev.day);
    try std.testing.expectEqual(@as(u8, 9), rev.hour);
    try std.testing.expectEqual(@as(u8, 15), rev.minute);
    try std.testing.expectEqual(@as(u8, 2), rev.second);

    var cache = PrefixEpochCache{};
    const ctx_utc8 = FallbackTimeContext{ .year = 2026, .month = 11, .day = 14, .tz_offset_sec = 8 * 3600 };
    const ns1 = parseUniversalLineNs("2026-11-14 09:15:02,418 ERROR first", ctx_utc8, &cache).?;
    const ns2 = parseUniversalLineNs("2026-11-14 09:15:49,100 INFO same minute", ctx_utc8, &cache).?;
    try std.testing.expectEqual(ns1 + 46 * std.time.ns_per_s + 682 * std.time.ns_per_ms, ns2);

    // Explicitly 09:15:02+08:00 must equal naive 09:15:02 under tzOffsetMin=480 (01:15:02Z)
    const explicit_ns = parseTimestampValueNs("2026-11-14T01:15:02.418Z", ctx_utc8, null).?;
    try std.testing.expectEqual(explicit_ns, ns1);
}

test "time_parser: strftime masks (%Y-%m-%d %H:%M:%S,%f, anchored ^[clf], syslog, epoch, invalid diagnostic)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try gpa.create(CompiledTimeParser);
    p.* = .{};
    defer {
        p.deinit(gpa);
        gpa.destroy(p);
    }

    var err_msg: ?[]const u8 = null;
    try p.initInPlace(gpa, arena, "^[%d/%b/%Y:%H:%M:%S %z]", &err_msg);
    try std.testing.expect(err_msg == null);

    const ctx = FallbackTimeContext{};
    const anchored_ok = p.parseLine("[14/Nov/2026:09:15:02 +0800] GET /api", ctx, null, null);
    try std.testing.expect(anchored_ok != null);
    // Prefix doesn't start at column 0 -> must reject due to leading ^
    const anchored_miss = p.parseLine("10.0.0.1 [14/Nov/2026:09:15:02 +0800] GET /api", ctx, null, null);
    try std.testing.expect(anchored_miss == null);
    p.deinit(gpa);

    // Syslog with space-padded single-digit day
    try p.initInPlace(gpa, arena, "%b %e %H:%M:%S", &err_msg);
    const sys_ns = p.parseLine("Nov  5 09:15:02 edge-gw nginx: ok", .{ .year = 2026 }, null, null).?;
    try std.testing.expectEqual(@as(u64, @intCast(civilToEpochSeconds(2026, 11, 5, 9, 15, 2).?)) * std.time.ns_per_s, sys_ns);
    p.deinit(gpa);

    // Invalid specifier reports diagnostic
    try std.testing.expectError(error.InvalidTimeFormat, p.initInPlace(gpa, arena, "%Y-%q", &err_msg));
    try std.testing.expect(err_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg.?, "%q") != null);
}

test "time_parser: json:<field>[|<strftime>] top-level, nested path, and epoch ms" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try gpa.create(CompiledTimeParser);
    p.* = .{};
    defer {
        p.deinit(gpa);
        gpa.destroy(p);
    }

    var err_msg: ?[]const u8 = null;
    try p.initInPlace(gpa, arena, "json:meta.created_at|%Y/%m/%d %H:%M:%S", &err_msg);
    const line = "{\"level\":\"error\",\"meta\":{\"created_at\":\"2026/11/14 09:15:02\"},\"msg\":\"fail\"}";
    const ns = p.parseLine(line, .{}, null, null).?;
    try std.testing.expectEqual(@as(u64, @intCast(civilToEpochSeconds(2026, 11, 14, 9, 15, 2).?)) * std.time.ns_per_s, ns);
    p.deinit(gpa);

    try p.initInPlace(gpa, arena, "json:ts_ms", &err_msg);
    const ms_ns = p.parseLine("{\"ts_ms\": 1730340902418, \"msg\":\"ok\"}", .{}, null, null).?;
    try std.testing.expectEqual(@as(u64, 1730340902418_000_000), ms_ns);
}

test "time_parser: regex:<pattern> with (?P<ts>...), named components, alternation, and CompileDiagnostic" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try gpa.create(CompiledTimeParser);
    p.* = .{};
    defer {
        p.deinit(gpa);
        gpa.destroy(p);
    }

    var scratch = libwebgrep.RegexScratch.init(gpa);
    defer scratch.deinit();

    var err_msg: ?[]const u8 = null;
    try p.initInPlace(gpa, arena, "regex:^(?:INFO|ERROR) (?P<ts>\\d{4}/\\d{2}/\\d{2} \\d{2}:\\d{2}:\\d{2})", &err_msg);
    const ns1 = p.parseLine("ERROR 2026/11/14 09:15:02 server.go:88 failed", .{}, &scratch, null).?;
    try std.testing.expectEqual(@as(u64, @intCast(civilToEpochSeconds(2026, 11, 14, 9, 15, 2).?)) * std.time.ns_per_s, ns1);
    try std.testing.expect(p.parseLine("DEBUG 2026/11/14 09:15:02 ignored", .{}, &scratch, null) == null);
    p.deinit(gpa);

    // Named date components (DD-MM-YYYY HH:MM:SS)
    try p.initInPlace(gpa, arena, "regex:(?P<d>\\d{2})-(?P<m>\\d{2})-(?P<Y>\\d{4}) (?P<H>\\d{2}):(?P<M>\\d{2}):(?P<S>\\d{2})", &err_msg);
    const ns2 = p.parseLine("ts=14-11-2026 09:15:02 ok", .{}, &scratch, null).?;
    try std.testing.expectEqual(ns1, ns2);
    p.deinit(gpa);

    // Invalid regex produces CompileDiagnostic error
    try std.testing.expectError(error.InvalidTimeFormat, p.initInPlace(gpa, arena, "regex:(unclosed", &err_msg));
    try std.testing.expect(err_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg.?, "col ") != null);
}

test "time_parser: multi-line banner quorum + narrowSliceByTimeParser" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const p = try gpa.create(CompiledTimeParser);
    p.* = .{};
    defer {
        p.deinit(gpa);
        gpa.destroy(p);
    }
    var err_msg: ?[]const u8 = null;
    try p.initInPlace(gpa, arena_state.allocator(), "", &err_msg);

    const log_with_banner =
        "# Version: 1.0\n" ++
        "# Fields: date time msg\n" ++
        "2026-10-31T10:15:00Z INFO start\n" ++
        "2026-10-31T10:15:10Z ERROR target_10\n" ++
        "    at StackFrame.run(App.java:12)\n" ++
        "2026-10-31T10:15:30Z INFO end\n";

    const lo = parseTimestampValueNs("2026-10-31T10:15:10Z", .{}, null).?;
    const hi = parseTimestampValueNs("2026-10-31T10:15:12Z", .{}, null).?;
    const res = narrowSliceByTimeParser(log_with_banner, p, lo, hi, .{}, null, null, 5 * std.time.ns_per_s);
    try std.testing.expectEqual(SliceTimeStatus.ordered_series, res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.sub_slice, "ERROR target_10") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.sub_slice, "INFO end") == null);
}

fn testUtcNs(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8, sub_ns: u64) u64 {
    const sec = civilToEpochSeconds(year, month, day, hour, minute, second).?;
    return @as(u64, @intCast(sec)) * std.time.ns_per_s + sub_ns;
}

test "time_parser: comprehensive universal auto formats and false-positive guards" {
    const ctx = FallbackTimeContext{ .year = 2026, .month = 11, .day = 14, .tz_offset_sec = 0 };
    const utc_base = testUtcNs(2026, 11, 14, 10, 15, 2, 0);

    // Dot YMD, single-digit YMD, minute-only, underscore separators
    try std.testing.expectEqual(utc_base, parseUniversalLineNs("2026.11.14 10:15:02 INFO started", ctx, null).?);
    try std.testing.expectEqual(testUtcNs(2026, 1, 5, 8, 5, 0, 0), parseUniversalLineNs("2026-1-5 8:5 WARN low", ctx, null).?);
    try std.testing.expectEqual(testUtcNs(2026, 11, 14, 10, 15, 0, 0), parseUniversalLineNs("2026-11-14 10:15 DEBUG heartbeat", ctx, null).?);
    try std.testing.expectEqual(utc_base, parseUniversalLineNs("2026-11-14_10:15:02 worker-1 ok", ctx, null).?);
    try std.testing.expectEqual(utc_base, parseUniversalLineNs("2026-11-14_10-15-02 snapshot saved", ctx, null).?);

    // CJK dates & times
    try std.testing.expectEqual(utc_base, parseUniversalLineNs("2026年11月14日 10时15分02秒 INFO 启动完成", ctx, null).?);
    try std.testing.expectEqual(testUtcNs(2026, 1, 5, 8, 5, 2, 0), parseUniversalLineNs("2026年1月5日 08:05:02 警告", ctx, null).?);

    // Compact calendar stamps
    try std.testing.expectEqual(utc_base, parseUniversalLineNs("20261114101502 INFO compact", ctx, null).?);
    try std.testing.expectEqual(utc_base, parseUniversalLineNs("20261114T101502Z INFO iso_compact", ctx, null).?);
    try std.testing.expectEqual(utc_base, parseUniversalLineNs("20261114 10:15:02 INFO space_compact", ctx, null).?);

    // Bracketed Nginx/Apache CLF, RFC 2822, DD-Mon-YYYY, Apache ctime
    try std.testing.expectEqual(
        testUtcNs(2026, 11, 14, 2, 15, 2, 0),
        parseUniversalLineNs("10.0.0.1 - - [14/Nov/2026:10:15:02 +0800] \"GET /health\" 200", ctx, null).?,
    );
    try std.testing.expectEqual(utc_base, parseUniversalLineNs("Sat, 14 Nov 2026 10:15:02 GMT mail queued", ctx, null).?);
    try std.testing.expectEqual(
        testUtcNs(2026, 11, 14, 10, 15, 2, 500_000_000),
        parseUniversalLineNs("14-Nov-2026 10:15:02.500 INFO tomcat", ctx, null).?,
    );
    try std.testing.expectEqual(
        testUtcNs(2026, 11, 14, 10, 15, 2, 123_456_000),
        parseUniversalLineNs("[Sat Nov 14 10:15:02.123456 2026] [core:notice] pid 42", ctx, null).?,
    );

    // US MDY + 12h AM/PM & EU DMY
    try std.testing.expectEqual(
        testUtcNs(2026, 11, 14, 14, 15, 2, 0),
        parseUniversalLineNs("11/14/2026 2:15:02 PM service started", ctx, null).?,
    );
    try std.testing.expectEqual(utc_base, parseUniversalLineNs("14.11.2026 10:15:02 INFO eu", ctx, null).?);

    // Google glog, Android logcat, 2-digit year
    try std.testing.expectEqual(
        testUtcNs(2026, 11, 14, 10, 15, 2, 123_456_000),
        parseUniversalLineNs("I1114 10:15:02.123456 99 main.go:1] listening", ctx, null).?,
    );
    try std.testing.expectEqual(
        testUtcNs(2026, 11, 14, 10, 15, 2, 418_000_000),
        parseUniversalLineNs("11-14 10:15:02.418  100  200 I Tag: hi", ctx, null).?,
    );
    try std.testing.expectEqual(utc_base, parseUniversalLineNs("26-11-14 10:15:02 INFO short_ymd", ctx, null).?);

    // Leading epoch float, leading time-only, expanded JSONL, logfmt
    try std.testing.expectEqual(
        1794647700 * std.time.ns_per_s + 123_000_000,
        parseUniversalLineNs("1794647700.123 INFO worker booted", ctx, null).?,
    );
    try std.testing.expectEqual(
        testUtcNs(2026, 11, 14, 10, 15, 2, 418_000_000),
        parseUniversalLineNs("10:15:02.418 INFO time_only", ctx, null).?,
    );
    try std.testing.expectEqual(
        utc_base,
        parseUniversalLineNs("{\"level\":\"info\",\"created_at\" : \"2026-11-14T10:15:02Z\",\"msg\":\"ok\"}", ctx, null).?,
    );
    try std.testing.expectEqual(
        utc_base,
        parseUniversalLineNs("lvl=info ts=2026-11-14T10:15:02Z msg=ok", ctx, null).?,
    );

    // False-positive guards: IPv4, MAC/colon hex, code constants, embedded digits
    try std.testing.expect(parseUniversalLineNs("192.168.1.1 GET /index.html 200", ctx, null) == null);
    try std.testing.expect(parseUniversalLineNs("12:34:56:78 MAC address mismatch", ctx, null) == null);
    try std.testing.expect(parseUniversalLineNs("const port = 8080; // server listen", ctx, null) == null);
    try std.testing.expect(parseUniversalLineNs("id=abc20261114101502def status=ok", ctx, null) == null);
}

test "time_parser: human date-picture formats (yyyy-hm, yyyy-MM-dd HH:mm:ss, compact, invalid)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ctx = FallbackTimeContext{ .year = 2026, .month = 1, .day = 1, .tz_offset_sec = 0 };

    // 1. Custom yyyy-hm with packed 2/3/4-digit h+m values
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "yyyy-hm", &err_msg);

        try std.testing.expectEqual(testUtcNs(2026, 1, 1, 10, 30, 0, 0), p.parseLine("2026-1030 ERROR retry", ctx, null, null).?);
        try std.testing.expectEqual(testUtcNs(2026, 1, 1, 9, 15, 0, 0), p.parseLine("2026-0915 INFO ok", ctx, null, null).?);
        try std.testing.expectEqual(testUtcNs(2026, 1, 1, 9, 15, 0, 0), p.parseLine("2026-915 INFO ok", ctx, null, null).?);
        try std.testing.expectEqual(testUtcNs(2026, 1, 1, 9, 5, 0, 0), p.parseLine("2026-95 WARN short", ctx, null, null).?);
    }

    // 2. Standard human date-picture (plus opportunistic .418Z, lowercase/uppercase, single-digit)
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "yyyy-MM-dd HH:mm:ss", &err_msg);
        try std.testing.expectEqual(
            testUtcNs(2026, 11, 14, 10, 15, 2, 0),
            p.parseLine("INFO [main] 2026-11-14 10:15:02 ready", ctx, null, null).?,
        );
        try std.testing.expectEqual(
            testUtcNs(2026, 11, 14, 10, 15, 2, 418_000_000),
            p.parseLine("2026-11-14 10:15:02.418Z ready", ctx, null, null).?,
        );
    }
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "yyyy-mm-dd hh:mm:ss", &err_msg);
        try std.testing.expectEqual(
            testUtcNs(2026, 11, 14, 18, 15, 2, 0),
            p.parseLine("2026-11-14 18:15:02 INFO lower", ctx, null, null).?,
        );
    }
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "YYYY-MM-DD HH:MM:SS", &err_msg);
        try std.testing.expectEqual(
            testUtcNs(2026, 11, 14, 10, 15, 2, 0),
            p.parseLine("2026-11-14 10:15:02 INFO upper", ctx, null, null).?,
        );
    }
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "yyyy/M/d H:m", &err_msg);
        try std.testing.expectEqual(
            testUtcNs(2026, 1, 5, 8, 9, 0, 0),
            p.parseLine("2026/1/5 8:9 WARN flex", ctx, null, null).?,
        );
    }

    // 3. Compact, CLF, quoted 'T', 12-hour a, json|picture, regex||picture, epoch alias
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "yyyyMMddHHmmss", &err_msg);
        try std.testing.expectEqual(testUtcNs(2026, 11, 14, 10, 15, 2, 0), p.parseLine("20261114101502 ok", ctx, null, null).?);
    }
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "dd/MMM/yyyy:HH:mm:ss Z", &err_msg);
        try std.testing.expectEqual(
            testUtcNs(2026, 11, 14, 2, 15, 2, 0),
            p.parseLine("10.0.0.1 - [14/Nov/2026:10:15:02 +0800] GET /", ctx, null, null).?,
        );
    }
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "yyyy-MM-dd'T'HH:mm:ss.SSSZ", &err_msg);
        try std.testing.expectEqual(
            testUtcNs(2026, 11, 14, 2, 15, 2, 123_000_000),
            p.parseLine("2026-11-14T10:15:02.123+08:00 ok", ctx, null, null).?,
        );
    }
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "hh:mm:ss a", &err_msg);
        try std.testing.expectEqual(
            testUtcNs(2026, 1, 1, 14, 15, 2, 0),
            p.parseLine("02:15:02 PM event", ctx, null, null).?,
        );
    }
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "json:meta.t|yyyy-hm", &err_msg);
        try std.testing.expectEqual(
            testUtcNs(2026, 1, 1, 10, 30, 0, 0),
            p.parseLine("{\"meta\":{\"t\":\"2026-1030\"},\"msg\":\"ok\"}", ctx, null, null).?,
        );
    }
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "regex:\\[ts=([^\\]]+)\\]||yyyy-hm", &err_msg);
        try std.testing.expectEqual(
            testUtcNs(2026, 1, 1, 10, 30, 0, 0),
            p.parseLine("ERR [ts=2026-1030] timeout", ctx, null, null).?,
        );
    }
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try p.initInPlace(gpa, arena, "epoch", &err_msg);
        try std.testing.expectEqual(1794647700 * std.time.ns_per_s, p.parseLine("1794647700 ok", ctx, null, null).?);
    }

    // 4. Invalid picture specifier must return error.InvalidTimeFormat
    {
        var p = CompiledTimeParser{};
        defer p.deinit(gpa);
        var err_msg: ?[]const u8 = null;
        try std.testing.expectError(error.InvalidTimeFormat, p.initInPlace(gpa, arena, "yyyy-qq", &err_msg));
        try std.testing.expect(err_msg != null);
    }
}

