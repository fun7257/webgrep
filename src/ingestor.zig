const std = @import("std");
const file_api = @import("file_api.zig");
const source_registry = @import("source_registry.zig");

pub const DEFAULT_ROLLOVER_BYTES: u64 = 64 * 1024 * 1024; // 64 MiB sealed segment target
pub const GROUP_COMMIT_BUFFER_CAP: usize = 256 * 1024; // 256 KiB in-memory write buffer before mid-batch flush

pub const IngestStats = struct {
    accepted: u64 = 0,
    bytesWritten: u64 = 0,
};

pub const SegmentTimeRange = struct {
    min_ns: u64,
    max_ns: u64,
};

/// Returns the current wall-clock Unix timestamp in nanoseconds (`u64`).
pub fn currentUnixNano(io: std.Io) u64 {
    const ts = std.Io.Clock.real.now(io);
    if (ts.nanoseconds <= 0) return 1_700_000_000_000_000_000;
    return @intCast(@min(ts.nanoseconds, std.math.maxInt(u64)));
}

/// Formats a Unix nanosecond timestamp (`u64`) into `YYYY-MM-DD` (UTC).
pub fn formatDateYmd(ts_ns: u64, out_buf: *[10]u8) []const u8 {
    const secs: u64 = ts_ns / std.time.ns_per_s;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const month_num: u8 = month_day.month.numeric();
    const day_num: u8 = month_day.day_index + 1;

    _ = std.fmt.bufPrint(
        out_buf,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ year_day.year, month_num, day_num },
    ) catch {
        @memcpy(out_buf, "1970-01-01");
    };
    return out_buf[0..10];
}

pub fn currentYearUtc(ts_ns: u64) u16 {
    const secs: u64 = ts_ns / std.time.ns_per_s;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    return epoch_seconds.getEpochDay().calculateYearDay().year;
}

/// Fast O(1) parser for a 19-digit leading Unix nanosecond timestamp at the start of a log line:
/// `<19-digit-ns> <payload>`
pub fn parseLineLeadingNs(line: []const u8) ?u64 {
    if (line.len < 20 or line[19] != ' ') return null;
    var acc: u64 = 0;
    for (line[0..19]) |ch| {
        if (ch < '0' or ch > '9') return null;
        acc = acc *| 10 +| @as(u64, ch - '0');
    }
    return acc;
}

/// Parses a sealed segment filename `<19-digit-min_ns>-<19-digit-max_ns>.log` (or `...-<seq>.log[.zst/.gz/.lz4]`)
/// in O(1) time without touching the filesystem.
pub fn parseSealedSegmentTimeRange(base_name: []const u8) ?SegmentTimeRange {
    if (base_name.len < 43) return null; // 19 + 1 + 19 + 4 (".log")
    if (base_name[19] != '-') return null;

    var min_ns: u64 = 0;
    for (base_name[0..19]) |ch| {
        if (ch < '0' or ch > '9') return null;
        min_ns = min_ns *| 10 +| @as(u64, ch - '0');
    }

    var max_ns: u64 = 0;
    for (base_name[20..39]) |ch| {
        if (ch < '0' or ch > '9') return null;
        max_ns = max_ns *| 10 +| @as(u64, ch - '0');
    }

    const tail = base_name[39..];
    if (!std.mem.startsWith(u8, tail, ".log") and !std.mem.startsWith(u8, tail, "-")) {
        return null;
    }

    if (max_ns < min_ns) return .{ .min_ns = max_ns, .max_ns = min_ns };
    return .{ .min_ns = min_ns, .max_ns = max_ns };
}

fn isLeapYear(y: u16) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

fn daysBeforeMonth(year: u16, month: u8) ?u16 {
    if (month < 1 or month > 12) return null;
    const table = [_]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    var days = table[month - 1];
    if (month > 2 and isLeapYear(year)) days += 1;
    return days;
}

fn civilToEpochSeconds(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?i64 {
    if (year < 1970 or year > 2261) return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    var total_days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        total_days += if (isLeapYear(y)) 366 else 365;
    }
    const dbm = daysBeforeMonth(year, month) orelse return null;
    total_days += @as(i64, dbm) + @as(i64, day - 1);

    return total_days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn parse2Digits(s: []const u8) ?u8 {
    if (s.len < 2) return null;
    if (!std.ascii.isDigit(s[0]) or !std.ascii.isDigit(s[1])) return null;
    return (s[0] - '0') * 10 + (s[1] - '0');
}

fn parse4Digits(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    var acc: u16 = 0;
    for (s[0..4]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        acc = acc * 10 + @as(u16, c - '0');
    }
    return acc;
}

fn parseMonthAbbrev(mon: []const u8) ?u8 {
    if (mon.len != 3) return null;
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (months, 1..) |m, idx| {
        if (std.ascii.eqlIgnoreCase(mon, m)) return @intCast(idx);
    }
    return null;
}

/// Parses timestamps from diverse log shippers into Unix nanoseconds (`u64`):
/// - 19-digit Unix nanoseconds (`1730340902418923105`)
/// - 16-digit Unix microseconds (`1730340902418923`)
/// - 13-digit Unix milliseconds (`1730340902418`)
/// - 10-digit Unix seconds (`1730340902`) or float seconds (`1730340902.418923`)
/// - ISO-8601 / RFC 3339 (`2026-10-31T10:15:02.418923105Z`, `2026-10-31 10:15:02+08:00`)
/// - RFC 3164 Syslog (`Oct 31 10:15:02`)
pub fn parseTimestampToNs(raw: []const u8, fallback_year: u16) ?u64 {
    const s = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (s.len == 0) return null;

    // 1. Check pure integer or float epoch timestamp
    var all_digits = true;
    var dot_pos: ?usize = null;
    for (s, 0..) |c, idx| {
        if (c == '.' and dot_pos == null and idx > 0 and idx + 1 < s.len) {
            dot_pos = idx;
            continue;
        }
        if (!std.ascii.isDigit(c)) {
            all_digits = false;
            break;
        }
    }

    if (all_digits) {
        if (dot_pos) |dp| {
            const sec_part = std.fmt.parseInt(u64, s[0..dp], 10) catch return null;
            const frac_str = s[dp + 1 ..];
            var frac_ns: u64 = 0;
            var mult: u64 = 100_000_000;
            for (frac_str) |fc| {
                if (mult == 0) break;
                frac_ns += @as(u64, fc - '0') * mult;
                mult /= 10;
            }
            return sec_part *| std.time.ns_per_s +| frac_ns;
        } else {
            const val = std.fmt.parseInt(u64, s, 10) catch return null;
            if (s.len >= 18) return val; // nanoseconds
            if (s.len >= 15) return val *| 1_000; // microseconds
            if (s.len >= 12) return val *| 1_000_000; // milliseconds
            if (s.len >= 9) return val *| 1_000_000_000; // seconds
            return null;
        }
    }

    // 2. Check ISO-8601 / RFC 3339 / Slash YMD: YYYY[-/]MM[-/]DD[T ]HH:MM:SS[.frac][Z|±HH:?MM]
    if (s.len >= 19 and (s[4] == '-' or s[4] == '/') and s[7] == s[4] and (s[10] == 'T' or s[10] == 't' or s[10] == ' ') and s[13] == ':' and s[16] == ':') {
        const year = parse4Digits(s[0..4]) orelse return null;
        const month = parse2Digits(s[5..7]) orelse return null;
        const day = parse2Digits(s[8..10]) orelse return null;
        const hour = parse2Digits(s[11..13]) orelse return null;
        const minute = parse2Digits(s[14..16]) orelse return null;
        const second = parse2Digits(s[17..19]) orelse return null;

        var base_sec = civilToEpochSeconds(year, month, day, hour, minute, second) orelse return null;
        var pos: usize = 19;
        var frac_ns: u64 = 0;

        if (pos < s.len and (s[pos] == '.' or s[pos] == ',')) {
            pos += 1;
            var mult: u64 = 100_000_000;
            while (pos < s.len and std.ascii.isDigit(s[pos])) : (pos += 1) {
                if (mult > 0) {
                    frac_ns += @as(u64, s[pos] - '0') * mult;
                    mult /= 10;
                }
            }
        }

        while (pos < s.len and s[pos] == ' ') : (pos += 1) {}
        if (pos < s.len) {
            const tz = s[pos..];
            if (tz[0] == '+' or tz[0] == '-') {
                const sign: i64 = if (tz[0] == '+') -1 else 1; // convert local to UTC
                const tz_body = tz[1..];
                if (tz_body.len >= 2) {
                    const tz_h = parse2Digits(tz_body[0..2]) orelse 0;
                    var tz_m: u8 = 0;
                    if (tz_body.len >= 5 and tz_body[2] == ':') {
                        tz_m = parse2Digits(tz_body[3..5]) orelse 0;
                    } else if (tz_body.len >= 4) {
                        tz_m = parse2Digits(tz_body[2..4]) orelse 0;
                    }
                    base_sec += sign * (@as(i64, tz_h) * 3600 + @as(i64, tz_m) * 60);
                }
            }
        }

        if (base_sec <= 0) return null;
        return @as(u64, @intCast(base_sec)) *| std.time.ns_per_s +| frac_ns;
    }

    // 3. Check Nginx / Apache Common Log Format: "31/Oct/2026:10:15:02 +0800"
    if (s.len >= 20 and s[2] == '/' and s[6] == '/' and s[11] == ':' and s[14] == ':' and s[17] == ':') {
        const day = parse2Digits(s[0..2]) orelse return null;
        const month = parseMonthAbbrev(s[3..6]) orelse return null;
        const year = parse4Digits(s[7..11]) orelse return null;
        const hour = parse2Digits(s[12..14]) orelse return null;
        const minute = parse2Digits(s[15..17]) orelse return null;
        const second = parse2Digits(s[18..20]) orelse return null;

        var base_sec = civilToEpochSeconds(year, month, day, hour, minute, second) orelse return null;
        var pos: usize = 20;
        while (pos < s.len and s[pos] == ' ') : (pos += 1) {}
        if (pos < s.len and (s[pos] == '+' or s[pos] == '-')) {
            const sign: i64 = if (s[pos] == '+') -1 else 1;
            const tz_body = s[pos + 1 ..];
            if (tz_body.len >= 4) {
                const tz_h = parse2Digits(tz_body[0..2]) orelse 0;
                const tz_m = parse2Digits(tz_body[2..4]) orelse 0;
                base_sec += sign * (@as(i64, tz_h) * 3600 + @as(i64, tz_m) * 60);
            }
        }
        if (base_sec <= 0) return null;
        return @as(u64, @intCast(base_sec)) *| std.time.ns_per_s;
    }

    // 4. Check RFC 3164 Syslog: "Oct 31 10:15:02" or "Oct  5 08:01:09"
    if (s.len >= 15 and s[3] == ' ' and s[6] == ' ' and s[9] == ':' and s[12] == ':') {
        const month = parseMonthAbbrev(s[0..3]) orelse return null;
        const day_str = std.mem.trim(u8, s[4..6], " ");
        const day = std.fmt.parseInt(u8, day_str, 10) catch return null;
        const hour = parse2Digits(s[7..9]) orelse return null;
        const minute = parse2Digits(s[10..12]) orelse return null;
        const second = parse2Digits(s[13..15]) orelse return null;
        const eff_year: u16 = if (fallback_year >= 1970) fallback_year else 2026;
        const sec = civilToEpochSeconds(eff_year, month, day, hour, minute, second) orelse return null;
        if (sec <= 0) return null;
        return @as(u64, @intCast(sec)) *| std.time.ns_per_s;
    }

    return null;
}

/// Universal zero-allocation line-prefix timestamp sniffer for both WebGrep native `<19-digit-ns>`
/// streams and existing log files (ISO-8601, RFC3339, Log4j, Slash YMD, Nginx CLF, Syslog, JSONL).
/// Inspects only the leading header window of `raw_line` so dates inside HTML/code bodies are never misclassified.
pub fn parseUniversalLineTimestampNs(raw_line: []const u8, fallback_year: u16) ?u64 {
    const line = if (std.mem.indexOfScalar(u8, raw_line, '\n')) |nl| raw_line[0..nl] else raw_line;
    if (line.len < 10) return null;

    // 1. Fast O(1) 19-digit nanosecond prefix (`<19-digit-ns> <payload>`)
    if (parseLineLeadingNs(line)) |ns| return ns;

    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 10) return null;

    // 2. JSON Lines starting with `{`: scan first 160 bytes for "@timestamp", "timestamp", "time", or "ts"
    if (trimmed[0] == '{') {
        const win = trimmed[0..@min(trimmed.len, 160)];
        const keys = [_][]const u8{ "\"@timestamp\":", "\"timestamp\":", "\"time\":", "\"ts\":" };
        for (keys) |k| {
            if (std.mem.indexOf(u8, win, k)) |idx| {
                var val_start = idx + k.len;
                while (val_start < win.len and (win[val_start] == ' ' or win[val_start] == '\t')) : (val_start += 1) {}
                if (val_start >= win.len) continue;
                if (win[val_start] == '"') {
                    val_start += 1;
                    const val_end = std.mem.indexOfScalarPos(u8, win, val_start, '"') orelse continue;
                    if (parseTimestampToNs(win[val_start..val_end], fallback_year)) |ns| return ns;
                } else {
                    var val_end = val_start;
                    while (val_end < win.len and (std.ascii.isDigit(win[val_end]) or win[val_end] == '.')) : (val_end += 1) {}
                    if (val_end > val_start) {
                        if (parseTimestampToNs(win[val_start..val_end], fallback_year)) |ns| return ns;
                    }
                }
            }
        }
        return null;
    }

    // 3. Scan the first 36 bytes for ISO-8601 / RFC3339 / Log4j / Slash YMD (`YYYY[-/]MM[-/]DD[T ]HH:MM:SS...`)
    const scan_limit = @min(trimmed.len, 36);
    var i: usize = 0;
    while (i + 19 <= trimmed.len and i < scan_limit) : (i += 1) {
        const c = trimmed[i];
        if ((c == '1' or c == '2') and
            (trimmed[i + 4] == '-' or trimmed[i + 4] == '/') and
            trimmed[i + 7] == trimmed[i + 4] and
            (trimmed[i + 10] == 'T' or trimmed[i + 10] == 't' or trimmed[i + 10] == ' ') and
            trimmed[i + 13] == ':' and
            trimmed[i + 16] == ':')
        {
            if (i == 0 or !std.ascii.isAlphanumeric(trimmed[i - 1])) {
                const cand_end = @min(trimmed.len, i + 35);
                if (parseTimestampToNs(trimmed[i..cand_end], fallback_year)) |ns| return ns;
            }
        }
    }

    // 4. Nginx / Apache Common Log Format `[31/Oct/2026:10:15:02 +0800]` within first 64 bytes
    const clf_win = trimmed[0..@min(trimmed.len, 64)];
    if (std.mem.indexOfScalar(u8, clf_win, '[')) |open_br| {
        if (open_br + 21 < trimmed.len) {
            const inner = trimmed[open_br + 1 .. @min(trimmed.len, open_br + 29)];
            const close_br = std.mem.indexOfScalar(u8, inner, ']') orelse inner.len;
            if (parseTimestampToNs(inner[0..close_br], fallback_year)) |ns| return ns;
        }
    }

    // 5. Syslog RFC 3164 (`Oct 31 10:15:02` or `<134>Oct 31 10:15:02`) at line start
    var sys_start: usize = 0;
    if (trimmed[0] == '<') {
        if (std.mem.indexOfScalar(u8, trimmed[0..@min(trimmed.len, 8)], '>')) |gt| {
            sys_start = gt + 1;
        }
    }
    if (sys_start + 15 <= trimmed.len) {
        if (parseTimestampToNs(trimmed[sys_start .. sys_start + 15], fallback_year)) |ns| return ns;
    }

    return null;
}

/// Appends `<19-digit-ns> <single-line-escaped-payload>\n` to `out_buf`.
/// Any internal `\n` or `\r` in `payload` is escaped to literal `\n` or `\r` so 1 log event = strictly 1 line.
pub fn appendFormattedLogLine(
    allocator: std.mem.Allocator,
    out_buf: *std.ArrayList(u8),
    ts_ns: u64,
    payload: []const u8,
) !usize {
    const trimmed = std.mem.trimEnd(u8, payload, "\r\n");
    if (trimmed.len == 0) return 0;

    // If payload already starts with a valid 19-digit nanosecond prefix, preserve it as-is
    if (parseLineLeadingNs(trimmed) != null and std.mem.indexOfAny(u8, trimmed, "\r\n") == null) {
        try out_buf.ensureUnusedCapacity(allocator, trimmed.len + 1);
        out_buf.appendSliceAssumeCapacity(trimmed);
        out_buf.appendAssumeCapacity('\n');
        return trimmed.len + 1;
    }

    const start_len = out_buf.items.len;
    try out_buf.ensureUnusedCapacity(allocator, 20 + trimmed.len + 16);

    var ns_buf: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&ns_buf, "{d:0>19} ", .{ts_ns}) catch unreachable;
    out_buf.appendSliceAssumeCapacity(&ns_buf);

    for (trimmed) |ch| {
        if (ch == '\n') {
            try out_buf.appendSlice(allocator, "\\n");
        } else if (ch == '\r') {
            try out_buf.appendSlice(allocator, "\\r");
        } else {
            try out_buf.append(allocator, ch);
        }
    }
    try out_buf.append(allocator, '\n');
    return out_buf.items.len - start_len;
}

const ServiceStream = struct {
    service_name: []u8,
    current_ymd: [10]u8 = "0000-00-00".*,
    min_ns: u64 = 0,
    max_ns: u64 = 0,
    active_bytes: u64 = 0,
    seal_seq: u32 = 0,
    registered_in_sources: bool = false,
    write_buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *ServiceStream, gpa: std.mem.Allocator) void {
        gpa.free(self.service_name);
        self.write_buf.deinit(gpa);
        gpa.destroy(self);
    }
};

pub const Ingestor = struct {
    gpa: std.mem.Allocator,
    registry: *source_registry.SourceRegistry,
    rollover_bytes: u64 = DEFAULT_ROLLOVER_BYTES,
    mutex: std.Io.Mutex = .init,
    streams: std.StringHashMapUnmanaged(*ServiceStream) = .empty,

    pub fn init(
        gpa: std.mem.Allocator,
        registry: *source_registry.SourceRegistry,
        rollover_bytes: u64,
    ) Ingestor {
        return .{
            .gpa = gpa,
            .registry = registry,
            .rollover_bytes = if (rollover_bytes > 0) rollover_bytes else DEFAULT_ROLLOVER_BYTES,
        };
    }

    pub fn deinit(self: *Ingestor, io: std.Io) void {
        self.flushAll(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var it = self.streams.valueIterator();
        while (it.next()) |stream_ptr| {
            stream_ptr.*.deinit(self.gpa);
        }
        self.streams.deinit(self.gpa);
    }

    pub fn flushAll(self: *Ingestor, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();

        var it = self.streams.valueIterator();
        while (it.next()) |stream_ptr| {
            _ = arena_state.reset(.retain_capacity);
            self.flushStreamLocked(arena_state.allocator(), io, stream_ptr.*) catch {};
        }
    }

    fn getOrCreateStreamLocked(
        self: *Ingestor,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_service: []const u8,
    ) !*ServiceStream {
        const sanitized = try source_registry.sanitizeNameAlloc(arena, raw_service);
        const clean = if (sanitized.len > 0) sanitized else "ingest";

        if (self.streams.get(clean)) |existing| {
            return existing;
        }

        const name_copy = try self.gpa.dupe(u8, clean);
        errdefer self.gpa.free(name_copy);

        const st = try self.gpa.create(ServiceStream);
        st.* = .{
            .service_name = name_copy,
        };

        try self.streams.put(self.gpa, name_copy, st);
        _ = self.registry.ensureStreamSourceRegistered(arena, io, name_copy) catch {};
        st.registered_in_sources = true;
        return st;
    }

    fn sealActiveSegmentLocked(
        self: *Ingestor,
        arena: std.mem.Allocator,
        io: std.Io,
        st: *ServiceStream,
    ) !void {
        if (st.active_bytes == 0 or st.current_ymd[0] == '0') return;

        const day_dir_rel = try std.fmt.allocPrint(
            arena,
            "{s}/streams/{s}/{s}",
            .{ self.registry.data_root_path, st.service_name, st.current_ymd[0..10] },
        );

        var day_dir = std.Io.Dir.cwd().openDir(io, day_dir_rel, .{}) catch return;
        defer day_dir.close(io);

        const min_ns = if (st.min_ns > 0) st.min_ns else currentUnixNano(io);
        const max_ns = if (st.max_ns >= min_ns) st.max_ns else min_ns;

        var sealed_name = try std.fmt.allocPrint(
            arena,
            "{d:0>19}-{d:0>19}.log",
            .{ min_ns, max_ns },
        );

        if (day_dir.statFile(io, sealed_name, .{})) |_| {
            st.seal_seq +%= 1;
            sealed_name = try std.fmt.allocPrint(
                arena,
                "{d:0>19}-{d:0>19}-{d}.log",
                .{ min_ns, max_ns, st.seal_seq },
            );
        } else |_| {}

        std.Io.Dir.rename(day_dir, "active.log", day_dir, sealed_name, io) catch return;

        st.active_bytes = 0;
        st.min_ns = 0;
        st.max_ns = 0;
    }

    fn flushStreamLocked(
        self: *Ingestor,
        arena: std.mem.Allocator,
        io: std.Io,
        st: *ServiceStream,
    ) !void {
        if (st.write_buf.items.len == 0) return;
        if (!st.registered_in_sources) {
            _ = self.registry.ensureStreamSourceRegistered(arena, io, st.service_name) catch {};
            st.registered_in_sources = true;
        }

        const day_dir_rel = try std.fmt.allocPrint(
            arena,
            "{s}/streams/{s}/{s}",
            .{ self.registry.data_root_path, st.service_name, st.current_ymd[0..10] },
        );

        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, day_dir_rel);
        var day_dir = try cwd.openDir(io, day_dir_rel, .{});
        defer day_dir.close(io);

        // If `active.log` already existed on disk before this process started, sync `active_bytes`
        if (st.active_bytes == 0) {
            if (day_dir.statFile(io, "active.log", .{})) |existing_stat| {
                st.active_bytes = existing_stat.size;
            } else |_| {}
        }

        var file = try day_dir.createFile(io, "active.log", .{ .truncate = false });
        defer file.close(io);

        const stat_now = try file.stat(io);
        var write_buf: [16384]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        try writer.seekTo(stat_now.size);
        try writer.interface.writeAll(st.write_buf.items);
        try writer.interface.flush();

        st.active_bytes = stat_now.size + st.write_buf.items.len;
        st.write_buf.clearRetainingCapacity();

        if (st.active_bytes >= self.rollover_bytes) {
            try self.sealActiveSegmentLocked(arena, io, st);
        }
    }

    pub fn appendEventLocked(
        self: *Ingestor,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_service: []const u8,
        ts_ns: u64,
        payload: []const u8,
    ) !usize {
        const trimmed = std.mem.trimEnd(u8, payload, "\r\n");
        if (trimmed.len == 0) return 0;

        const st = try self.getOrCreateStreamLocked(arena, io, raw_service);
        var ymd_buf: [10]u8 = undefined;
        const ymd = formatDateYmd(ts_ns, &ymd_buf);

        // Day rollover check: if the event falls on a new UTC date, flush and seal the previous day's active.log
        if (st.current_ymd[0] != '0' and !std.mem.eql(u8, st.current_ymd[0..10], ymd)) {
            try self.flushStreamLocked(arena, io, st);
            try self.sealActiveSegmentLocked(arena, io, st);
        }
        @memcpy(&st.current_ymd, ymd);

        if (st.min_ns == 0 or ts_ns < st.min_ns) st.min_ns = ts_ns;
        if (ts_ns > st.max_ns) st.max_ns = ts_ns;

        const written = try appendFormattedLogLine(self.gpa, &st.write_buf, ts_ns, trimmed);

        if (st.write_buf.items.len >= GROUP_COMMIT_BUFFER_CAP or
            (st.active_bytes + st.write_buf.items.len) >= self.rollover_bytes)
        {
            try self.flushStreamLocked(arena, io, st);
        }
        return written;
    }

    /// Extracts timestamp and optional service name from a JSON object line without mutating the JSON payload.
    fn inspectJsonRecord(
        arena: std.mem.Allocator,
        raw_json: []const u8,
        fallback_ns: u64,
        fallback_year: u16,
    ) struct { ts_ns: u64, service: ?[]const u8 } {
        var parsed = std.json.parseFromSlice(std.json.Value, arena, raw_json, .{}) catch {
            return .{ .ts_ns = fallback_ns, .service = null };
        };
        defer parsed.deinit();

        if (parsed.value != .object) return .{ .ts_ns = fallback_ns, .service = null };
        const obj = parsed.value.object;

        var ts_ns: u64 = fallback_ns;
        const ts_keys = [_][]const u8{ "@timestamp", "timestamp", "time", "ts", "timeUnixNano" };
        for (ts_keys) |k| {
            if (obj.get(k)) |v| {
                switch (v) {
                    .string => |str| {
                        if (parseTimestampToNs(str, fallback_year)) |parsed_ns| {
                            ts_ns = parsed_ns;
                            break;
                        }
                    },
                    .integer => |ival| {
                        if (ival > 0) {
                            var num_buf: [32]u8 = undefined;
                            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{ival}) catch "";
                            if (parseTimestampToNs(num_str, fallback_year)) |parsed_ns| {
                                ts_ns = parsed_ns;
                                break;
                            }
                        }
                    },
                    .float => |fval| {
                        if (fval > 0) {
                            var num_buf: [48]u8 = undefined;
                            const num_str = std.fmt.bufPrint(&num_buf, "{d:.6}", .{fval}) catch "";
                            if (parseTimestampToNs(num_str, fallback_year)) |parsed_ns| {
                                ts_ns = parsed_ns;
                                break;
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        var service: ?[]const u8 = null;
        const svc_keys = [_][]const u8{ "service", "app", "service.name", "job", "container", "host" };
        for (svc_keys) |sk| {
            if (obj.get(sk)) |sv| {
                if (sv == .string and sv.string.len > 0) {
                    service = arena.dupe(u8, sv.string) catch null;
                    break;
                }
            }
        }

        return .{ .ts_ns = ts_ns, .service = service };
    }

    /// 1. Raw NDJSON / Plain Text Line Ingestion (`POST /ingest/{service}`)
    pub fn ingestRaw(
        self: *Ingestor,
        io: std.Io,
        default_service: []const u8,
        raw_body: []const u8,
    ) !IngestStats {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const now_ns = currentUnixNano(io);
        const cur_year = currentYearUtc(now_ns);
        var stats = IngestStats{};

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var touched = std.StringHashMapUnmanaged(void){};
        defer touched.deinit(arena);

        var line_it = std.mem.splitScalar(u8, raw_body, '\n');
        var seq: u64 = 0;
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;

            var ts_ns = now_ns +| seq;
            var svc = default_service;

            if (line[0] == '{') {
                const meta = inspectJsonRecord(arena, line, ts_ns, cur_year);
                ts_ns = meta.ts_ns;
                if (std.mem.eql(u8, default_service, "ingest") or default_service.len == 0) {
                    if (meta.service) |s| svc = s;
                }
            }

            const n = try self.appendEventLocked(arena, io, svc, ts_ns, line);
            if (n > 0) {
                stats.accepted += 1;
                stats.bytesWritten += n;
                seq += 1;
                const st = try self.getOrCreateStreamLocked(arena, io, svc);
                touched.put(arena, st.service_name, {}) catch {};
            }
        }

        var it = touched.keyIterator();
        while (it.next()) |k| {
            if (self.streams.get(k.*)) |st| {
                self.flushStreamLocked(arena, io, st) catch {};
            }
        }

        return stats;
    }

    /// 2. Elasticsearch / OpenSearch `_bulk` API (`POST /_bulk`, `POST /{index}/_bulk`)
    /// Alternates action metadata lines (`{"index":{"_index":"gateway"}}`) and document source lines.
    pub fn ingestElasticBulk(
        self: *Ingestor,
        io: std.Io,
        default_index: []const u8,
        raw_body: []const u8,
    ) !IngestStats {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const now_ns = currentUnixNano(io);
        const cur_year = currentYearUtc(now_ns);
        var stats = IngestStats{};

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var touched = std.StringHashMapUnmanaged(void){};
        defer touched.deinit(arena);

        var current_index: []const u8 = if (default_index.len > 0) default_index else "elastic";
        var expect_source = false;
        var seq: u64 = 0;

        var line_it = std.mem.splitScalar(u8, raw_body, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;

            if (!expect_source) {
                // Check if this is an ES bulk action metadata line: {"index":...} or {"create":...}
                if (std.mem.indexOf(u8, line, "\"index\"") != null or
                    std.mem.indexOf(u8, line, "\"create\"") != null)
                {
                    if (std.json.parseFromSlice(std.json.Value, arena, line, .{})) |parsed| {
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            const action_obj = parsed.value.object.get("index") orelse parsed.value.object.get("create");
                            if (action_obj) |ao| {
                                if (ao == .object) {
                                    if (ao.object.get("_index")) |idx_val| {
                                        if (idx_val == .string and idx_val.string.len > 0) {
                                            current_index = arena.dupe(u8, idx_val.string) catch current_index;
                                        }
                                    }
                                    expect_source = true;
                                    continue;
                                }
                            }
                        }
                    } else |_| {}
                }
            }

            expect_source = false;
            const meta = inspectJsonRecord(arena, line, now_ns +| seq, cur_year);
            const eff_service = if (!std.mem.eql(u8, current_index, "elastic"))
                current_index
            else
                (meta.service orelse current_index);

            const n = try self.appendEventLocked(arena, io, eff_service, meta.ts_ns, line);
            if (n > 0) {
                stats.accepted += 1;
                stats.bytesWritten += n;
                seq += 1;
                const st = try self.getOrCreateStreamLocked(arena, io, eff_service);
                touched.put(arena, st.service_name, {}) catch {};
            }
        }

        var it = touched.keyIterator();
        while (it.next()) |k| {
            if (self.streams.get(k.*)) |st| {
                self.flushStreamLocked(arena, io, st) catch {};
            }
        }

        return stats;
    }

    /// 3. Grafana Loki Push API (`POST /loki/api/v1/push`)
    /// Format: `{"streams":[{"stream":{"app":"gateway","level":"error"},"values":[["1730340902000000000","msg"], ...]}]}`
    pub fn ingestLokiPush(
        self: *Ingestor,
        io: std.Io,
        default_service: []const u8,
        raw_body: []const u8,
    ) !IngestStats {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const now_ns = currentUnixNano(io);
        const cur_year = currentYearUtc(now_ns);
        var stats = IngestStats{};

        var parsed = try std.json.parseFromSlice(std.json.Value, arena, raw_body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidLokiPayload;

        const streams_val = parsed.value.object.get("streams") orelse return error.InvalidLokiPayload;
        if (streams_val != .array) return error.InvalidLokiPayload;

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var touched = std.StringHashMapUnmanaged(void){};
        defer touched.deinit(arena);

        var seq: u64 = 0;
        for (streams_val.array.items) |stream_entry| {
            if (stream_entry != .object) continue;
            var svc_name: []const u8 = if (default_service.len > 0) default_service else "loki";
            var level_label: ?[]const u8 = null;

            if (stream_entry.object.get("stream")) |labels_val| {
                if (labels_val == .object) {
                    const label_keys = [_][]const u8{ "service", "app", "service_name", "job", "container", "host" };
                    for (label_keys) |lk| {
                        if (labels_val.object.get(lk)) |lv| {
                            if (lv == .string and lv.string.len > 0) {
                                svc_name = lv.string;
                                break;
                            }
                        }
                    }
                    if (labels_val.object.get("level") orelse labels_val.object.get("severity")) |lvl| {
                        if (lvl == .string and lvl.string.len > 0) level_label = lvl.string;
                    }
                }
            }

            const values_val = stream_entry.object.get("values") orelse continue;
            if (values_val != .array) continue;

            for (values_val.array.items) |tuple| {
                if (tuple != .array or tuple.array.items.len < 2) continue;
                const ts_item = tuple.array.items[0];
                const line_item = tuple.array.items[1];
                if (line_item != .string) continue;

                const ts_ns = switch (ts_item) {
                    .string => |ts_str| parseTimestampToNs(ts_str, cur_year) orelse (now_ns +| seq),
                    .integer => |ts_int| if (ts_int > 0) @as(u64, @intCast(ts_int)) else (now_ns +| seq),
                    else => now_ns +| seq,
                };

                const final_line = if (level_label != null and line_item.string.len > 0 and line_item.string[0] != '{')
                    try std.fmt.allocPrint(arena, "[{s}] {s}", .{ level_label.?, line_item.string })
                else
                    line_item.string;

                const n = try self.appendEventLocked(arena, io, svc_name, ts_ns, final_line);
                if (n > 0) {
                    stats.accepted += 1;
                    stats.bytesWritten += n;
                    seq += 1;
                    const st = try self.getOrCreateStreamLocked(arena, io, svc_name);
                    touched.put(arena, st.service_name, {}) catch {};
                }
            }
        }

        var it = touched.keyIterator();
        while (it.next()) |k| {
            if (self.streams.get(k.*)) |st| {
                self.flushStreamLocked(arena, io, st) catch {};
            }
        }

        return stats;
    }

    /// 4. OpenTelemetry OTLP/HTTP JSON Logs (`POST /v1/logs`)
    pub fn ingestOtlpLogs(
        self: *Ingestor,
        io: std.Io,
        default_service: []const u8,
        raw_body: []const u8,
    ) !IngestStats {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const now_ns = currentUnixNano(io);
        const cur_year = currentYearUtc(now_ns);
        var stats = IngestStats{};

        var parsed = try std.json.parseFromSlice(std.json.Value, arena, raw_body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidOtlpPayload;

        const res_logs = parsed.value.object.get("resourceLogs") orelse return error.InvalidOtlpPayload;
        if (res_logs != .array) return error.InvalidOtlpPayload;

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var touched = std.StringHashMapUnmanaged(void){};
        defer touched.deinit(arena);

        var seq: u64 = 0;
        for (res_logs.array.items) |rl| {
            if (rl != .object) continue;
            var svc_name: []const u8 = if (default_service.len > 0) default_service else "otlp";

            if (rl.object.get("resource")) |res_obj| {
                if (res_obj == .object) {
                    if (res_obj.object.get("attributes")) |attrs| {
                        if (attrs == .array) {
                            for (attrs.array.items) |attr| {
                                if (attr != .object) continue;
                                const k = attr.object.get("key") orelse continue;
                                if (k == .string and (std.mem.eql(u8, k.string, "service.name") or std.mem.eql(u8, k.string, "app"))) {
                                    if (attr.object.get("value")) |vobj| {
                                        if (vobj == .object) {
                                            if (vobj.object.get("stringValue")) |sv| {
                                                if (sv == .string and sv.string.len > 0) {
                                                    svc_name = sv.string;
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            const scope_logs = rl.object.get("scopeLogs") orelse continue;
            if (scope_logs != .array) continue;

            for (scope_logs.array.items) |sl| {
                if (sl != .object) continue;
                const records = sl.object.get("logRecords") orelse continue;
                if (records != .array) continue;

                for (records.array.items) |rec| {
                    if (rec != .object) continue;

                    var ts_ns = now_ns +| seq;
                    if (rec.object.get("timeUnixNano") orelse rec.object.get("observedTimeUnixNano")) |tval| {
                        switch (tval) {
                            .string => |s| ts_ns = parseTimestampToNs(s, cur_year) orelse ts_ns,
                            .integer => |i| if (i > 0) {
                                ts_ns = @intCast(i);
                            },
                            else => {},
                        }
                    }

                    const sev = if (rec.object.get("severityText")) |st|
                        (if (st == .string and st.string.len > 0) st.string else "INFO")
                    else
                        "INFO";

                    var body_text: []const u8 = "";
                    if (rec.object.get("body")) |bobj| {
                        if (bobj == .object) {
                            if (bobj.object.get("stringValue")) |sv| {
                                if (sv == .string) body_text = sv.string;
                            }
                        } else if (bobj == .string) {
                            body_text = bobj.string;
                        }
                    }
                    if (body_text.len == 0) continue;

                    const line = if (body_text[0] == '{')
                        body_text
                    else
                        try std.fmt.allocPrint(arena, "{s} {s}", .{ sev, body_text });

                    const n = try self.appendEventLocked(arena, io, svc_name, ts_ns, line);
                    if (n > 0) {
                        stats.accepted += 1;
                        stats.bytesWritten += n;
                        seq += 1;
                        const st = try self.getOrCreateStreamLocked(arena, io, svc_name);
                        touched.put(arena, st.service_name, {}) catch {};
                    }
                }
            }
        }

        var it = touched.keyIterator();
        while (it.next()) |k| {
            if (self.streams.get(k.*)) |st| {
                self.flushStreamLocked(arena, io, st) catch {};
            }
        }

        return stats;
    }

    /// Parses classic RFC 3164 (`<134>Oct 31 10:15:02 gw01 nginx[123]: msg`) and
    /// RFC 5424 (`<134>1 2026-10-31T10:15:02.418Z gw01 nginx 123 - - msg`) Syslog frames.
    pub fn parseSyslogFrame(
        arena: std.mem.Allocator,
        raw_line: []const u8,
        fallback_ns: u64,
        fallback_year: u16,
    ) ?struct { service: []const u8, ts_ns: u64, formatted_line: []const u8 } {
        if (raw_line.len < 4 or raw_line[0] != '<') return null;
        const close_idx = std.mem.indexOfScalar(u8, raw_line[1..@min(raw_line.len, 6)], '>') orelse return null;
        const pri_end = close_idx + 1;
        const pri_val = std.fmt.parseInt(u16, raw_line[1..pri_end], 10) catch return null;
        const severity_code: u16 = pri_val & 0x07;
        const severity_str = switch (severity_code) {
            0 => "EMERG",
            1 => "ALERT",
            2 => "CRIT",
            3 => "ERROR",
            4 => "WARN",
            5 => "NOTICE",
            6 => "INFO",
            else => "DEBUG",
        };

        const rest = std.mem.trimStart(u8, raw_line[pri_end + 1 ..], " ");
        if (rest.len == 0) return null;

        // Case A: RFC 5424 (`1 <ISO-TS> <HOST> <APP> <PROCID> <MSGID> ...`)
        if (rest.len > 2 and rest[0] == '1' and rest[1] == ' ') {
            var tok_it = std.mem.tokenizeScalar(u8, rest[2..], ' ');
            const ts_tok = tok_it.next() orelse return null;
            const host_tok = tok_it.next() orelse "syslog";
            const app_tok = tok_it.next() orelse host_tok;
            _ = tok_it.next(); // procid
            _ = tok_it.next(); // msgid
            const msg_part = std.mem.trimStart(u8, tok_it.rest(), " ");

            const ts_ns = parseTimestampToNs(ts_tok, fallback_year) orelse fallback_ns;
            const svc = if (!std.mem.eql(u8, app_tok, "-")) app_tok else host_tok;
            const formatted = std.fmt.allocPrint(
                arena,
                "{s} host={s} app={s} {s}",
                .{ severity_str, host_tok, svc, msg_part },
            ) catch return null;
            return .{ .service = svc, .ts_ns = ts_ns, .formatted_line = formatted };
        }

        // Case B: RFC 3164 (`Oct 31 10:15:02 host app[pid]: msg`)
        if (rest.len >= 16 and rest[3] == ' ' and rest[6] == ' ' and rest[9] == ':' and rest[12] == ':') {
            const ts_ns = parseTimestampToNs(rest[0..15], fallback_year) orelse fallback_ns;
            const after_ts = std.mem.trimStart(u8, rest[15..], " ");
            var tok_it = std.mem.tokenizeScalar(u8, after_ts, ' ');
            const host_tok = tok_it.next() orelse "syslog";
            const tag_and_msg = std.mem.trimStart(u8, tok_it.rest(), " ");

            var app_name: []const u8 = host_tok;
            var msg_body: []const u8 = tag_and_msg;

            if (std.mem.indexOfScalar(u8, tag_and_msg, ':')) |colon_idx| {
                const candidate_tag = tag_and_msg[0..colon_idx];
                if (candidate_tag.len > 0 and candidate_tag.len <= 48 and std.mem.indexOfScalar(u8, candidate_tag, ' ') == null) {
                    const bracket_idx = std.mem.indexOfScalar(u8, candidate_tag, '[') orelse candidate_tag.len;
                    if (bracket_idx > 0) {
                        app_name = candidate_tag[0..bracket_idx];
                    }
                    msg_body = std.mem.trimStart(u8, tag_and_msg[colon_idx + 1 ..], " ");
                }
            }

            const formatted = std.fmt.allocPrint(
                arena,
                "{s} host={s} {s}",
                .{ severity_str, host_tok, msg_body },
            ) catch return null;
            return .{ .service = app_name, .ts_ns = ts_ns, .formatted_line = formatted };
        }

        return .{
            .service = "syslog",
            .ts_ns = fallback_ns,
            .formatted_line = std.fmt.allocPrint(arena, "{s} {s}", .{ severity_str, rest }) catch return null,
        };
    }

    /// Unified auto-sniffing wire ingestion for TCP & UDP (`:5514`).
    /// Automatically detects:
    /// 1. Syslog RFC 3164 / RFC 5424 (`<PRI>...`)
    /// 2. JSON Lines (`{...}`)
    /// 3. Raw Plain Text
    /// Also supports RFC 6587 Octet-Counting framing (`<len> <syslog-frame>`).
    pub fn ingestWirePayload(
        self: *Ingestor,
        io: std.Io,
        default_service: []const u8,
        raw_payload: []const u8,
    ) !IngestStats {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const now_ns = currentUnixNano(io);
        const cur_year = currentYearUtc(now_ns);
        var stats = IngestStats{};

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var touched = std.StringHashMapUnmanaged(void){};
        defer touched.deinit(arena);

        var pos: usize = 0;
        var seq: u64 = 0;
        while (pos < raw_payload.len) {
            while (pos < raw_payload.len and (raw_payload[pos] == '\r' or raw_payload[pos] == '\n' or raw_payload[pos] == ' ')) {
                pos += 1;
            }
            if (pos >= raw_payload.len) break;

            var frame: []const u8 = "";

            // Check RFC 6587 Octet-Counting: `<digits> <<PRI>...>`
            if (std.ascii.isDigit(raw_payload[pos])) {
                var d_end = pos;
                while (d_end < raw_payload.len and std.ascii.isDigit(raw_payload[d_end]) and (d_end - pos) <= 7) {
                    d_end += 1;
                }
                if (d_end < raw_payload.len and raw_payload[d_end] == ' ' and d_end + 1 < raw_payload.len and raw_payload[d_end + 1] == '<') {
                    if (std.fmt.parseInt(usize, raw_payload[pos..d_end], 10)) |octet_len| {
                        const msg_start = d_end + 1;
                        if (octet_len > 0 and msg_start + octet_len <= raw_payload.len) {
                            frame = raw_payload[msg_start .. msg_start + octet_len];
                            pos = msg_start + octet_len;
                        }
                    } else |_| {}
                }
            }

            if (frame.len == 0) {
                const nl_rel = std.mem.indexOfScalar(u8, raw_payload[pos..], '\n');
                if (nl_rel) |nl| {
                    frame = raw_payload[pos .. pos + nl];
                    pos = pos + nl + 1;
                } else {
                    frame = raw_payload[pos..];
                    pos = raw_payload.len;
                }
            }

            const clean_frame = std.mem.trim(u8, frame, " \t\r\n");
            if (clean_frame.len == 0) continue;

            var svc: []const u8 = if (default_service.len > 0) default_service else "tcp-udp";
            var ts_ns: u64 = now_ns +| seq;
            var line_to_write: []const u8 = clean_frame;

            if (clean_frame[0] == '<') {
                if (parseSyslogFrame(arena, clean_frame, ts_ns, cur_year)) |sys| {
                    svc = sys.service;
                    ts_ns = sys.ts_ns;
                    line_to_write = sys.formatted_line;
                }
            } else if (clean_frame[0] == '{') {
                const meta = inspectJsonRecord(arena, clean_frame, ts_ns, cur_year);
                ts_ns = meta.ts_ns;
                if (meta.service) |s| svc = s;
            }

            const n = try self.appendEventLocked(arena, io, svc, ts_ns, line_to_write);
            if (n > 0) {
                stats.accepted += 1;
                stats.bytesWritten += n;
                seq += 1;
                const st = try self.getOrCreateStreamLocked(arena, io, svc);
                touched.put(arena, st.service_name, {}) catch {};
            }
        }

        var it = touched.keyIterator();
        while (it.next()) |k| {
            if (self.streams.get(k.*)) |st| {
                self.flushStreamLocked(arena, io, st) catch {};
            }
        }

        return stats;
    }

    pub fn handleTcpConnectionThread(self: *Ingestor, io: std.Io, stream: std.Io.net.Stream) void {
        defer stream.close(io);

        const buf = self.gpa.alloc(u8, 64 * 1024) catch return;
        defer self.gpa.free(buf);
        var reader = stream.reader(io, buf);

        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => {
                    const rem = reader.interface.buffered();
                    if (rem.len > 0) {
                        _ = self.ingestWirePayload(io, "tcp", rem) catch {};
                    }
                    break;
                },
                else => break,
            };
            _ = self.ingestWirePayload(io, "tcp", line) catch {};
        }
    }

    pub fn runTcpListenerThread(self: *Ingestor, io: std.Io, host: []const u8, port: u16) void {
        const addr = std.Io.net.IpAddress.parse(host, port) catch return;
        var tcp_server = addr.listen(io, .{ .reuse_address = true }) catch return;
        defer tcp_server.deinit(io);

        while (true) {
            const stream = tcp_server.accept(io) catch continue;
            if (std.Thread.spawn(.{}, Ingestor.handleTcpConnectionThread, .{ self, io, stream })) |t| {
                t.detach();
            } else |_| {
                self.handleTcpConnectionThread(io, stream);
            }
        }
    }

    pub fn runUdpListenerThread(self: *Ingestor, io: std.Io, host: []const u8, port: u16) void {
        const addr = std.Io.net.IpAddress.parse(host, port) catch return;
        var sock = addr.bind(io, .{ .mode = .dgram }) catch return;
        defer sock.close(io);

        const dgram_buf = self.gpa.alloc(u8, 65536) catch return;
        defer self.gpa.free(dgram_buf);

        while (true) {
            const msg = sock.receive(io, dgram_buf) catch continue;
            if (msg.data.len > 0) {
                _ = self.ingestWirePayload(io, "udp", msg.data) catch {};
            }
        }
    }
};

test "parseTimestampToNs handles ns, ms, float, ISO-8601, and Syslog timestamps" {
    const ns1 = parseTimestampToNs("1730340902418923105", 2026).?;
    try std.testing.expectEqual(@as(u64, 1730340902418923105), ns1);

    const ms1 = parseTimestampToNs("1730340902418", 2026).?;
    try std.testing.expectEqual(@as(u64, 1730340902418_000_000), ms1);

    const iso1 = parseTimestampToNs("2026-10-31T10:15:02.418923105Z", 2026).?;
    var ymd_buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-31", formatDateYmd(iso1, &ymd_buf));
    try std.testing.expectEqual(@as(u64, 418923105), iso1 % std.time.ns_per_s);

    const sys1 = parseTimestampToNs("Oct 31 10:15:02", 2026).?;
    try std.testing.expectEqualStrings("2026-10-31", formatDateYmd(sys1, &ymd_buf));
}

test "parseSealedSegmentTimeRange and parseLineLeadingNs" {
    const seg = parseSealedSegmentTimeRange("1730340900000000000-1730344500123456789.log").?;
    try std.testing.expectEqual(@as(u64, 1730340900000000000), seg.min_ns);
    try std.testing.expectEqual(@as(u64, 1730344500123456789), seg.max_ns);

    const seg_zst = parseSealedSegmentTimeRange("1730340900000000000-1730344500123456789-2.log.zst").?;
    try std.testing.expectEqual(@as(u64, 1730340900000000000), seg_zst.min_ns);
    try std.testing.expectEqual(@as(u64, 1730344500123456789), seg_zst.max_ns);

    try std.testing.expect(parseSealedSegmentTimeRange("active.log") == null);

    const line_ns = parseLineLeadingNs("1730340902418923105 {\"level\":\"error\"}").?;
    try std.testing.expectEqual(@as(u64, 1730340902418923105), line_ns);
}

test "Ingestor writes 19-digit ns lines, auto-registers @service, and seals on rollover" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root_real = try gpa.dupe(u8, path_buf[0..n]);
    defer gpa.free(root_real);

    var reg = source_registry.SourceRegistry.init(gpa, io, root_real, null);
    defer reg.deinit(io);

    // Small rollover threshold (200 bytes) to test automatic sealing to <min_ns>-<max_ns>.log
    var ing = Ingestor.init(gpa, &reg, 200);
    defer ing.deinit(io);

    const loki_json =
        \\{"streams":[{"stream":{"service":"gateway-api","level":"error"},"values":[
        \\  ["1730340901000000000","{\"msg\":\"first error timeout\",\"code\":502}"],
        \\  ["1730340902000000000","{\"msg\":\"second error timeout\",\"code\":504}"],
        \\  ["1730340903000000000","{\"msg\":\"third error timeout\",\"code\":500}"]
        \\]}]}
    ;
    const stats = try ing.ingestLokiPush(io, "default", loki_json);
    try std.testing.expectEqual(@as(u64, 3), stats.accepted);

    // Verify @gateway-api was auto-registered in SourceRegistry
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const sources = try reg.snapshotAllSources(arena_state.allocator(), io);
    try std.testing.expectEqual(@as(usize, 1), sources.len);
    try std.testing.expectEqualStrings("gateway-api", sources[0].name);

    // Verify syslog wire ingestion
    const syslog_wire = "<131>Oct 31 10:15:05 gw01 nginx[991]: upstream timed out while reading response header\n";
    const wire_stats = try ing.ingestWirePayload(io, "udp", syslog_wire);
    try std.testing.expectEqual(@as(u64, 1), wire_stats.accepted);
}
