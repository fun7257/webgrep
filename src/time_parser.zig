const std = @import("std");
const libwebgrep = @import("libwebgrep");
const prefilter = @import("prefilter.zig");

pub const TimeMode = enum {
    auto,
    source,
    content,
    mtime,

    pub fn parse(raw: []const u8) TimeMode {
        const s = std.mem.trim(u8, raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(s, "source")) return .source;
        if (std.ascii.eqlIgnoreCase(s, "content")) return .content;
        if (std.ascii.eqlIgnoreCase(s, "mtime")) return .mtime;
        return .auto;
    }

    pub fn asStr(self: TimeMode) []const u8 {
        return switch (self) {
            .auto => "auto",
            .source => "source",
            .content => "content",
            .mtime => "mtime",
        };
    }

    pub fn toPrefilter(self: TimeMode) prefilter.TimeFilterMode {
        return switch (self) {
            .auto => .auto,
            .source => .source,
            .content => .content,
            .mtime => .mtime,
        };
    }
};

pub const FallbackTimeContext = struct {
    year: u16 = 2026,
    month: u8 = 1,
    day: u8 = 1,
    /// Client/query timezone offset in seconds east of UTC (e.g. +28800 for UTC+8).
    /// Applied only when a parsed timestamp does not specify an explicit timezone (`Z` or `±HH:MM`).
    tz_offset_sec: i64 = 0,

    pub fn fromMtimeAndTz(mtime_ns: i96, tz_offset_min: i16) FallbackTimeContext {
        const clamped_min: i16 = std.math.clamp(tz_offset_min, -840, 840);
        const tz_sec: i64 = @as(i64, clamped_min) * 60;
        if (mtime_ns <= 0) {
            return .{ .year = 2026, .month = 1, .day = 1, .tz_offset_sec = tz_sec };
        }
        const raw_sec: i64 = @intCast(@min(@divFloor(mtime_ns, std.time.ns_per_s), std.math.maxInt(i64) - 86400));
        const local_sec = raw_sec + tz_sec;
        const civil = epochSecondsToCivil(local_sec) orelse return .{ .year = 2026, .month = 1, .day = 1, .tz_offset_sec = tz_sec };
        return .{
            .year = civil.year,
            .month = civil.month,
            .day = civil.day,
            .tz_offset_sec = tz_sec,
        };
    }
};

/// Per-worker stack-allocated cache memoizing the 16-byte `YYYY-MM-DD HH:MM` minute civil epoch,
/// accelerating same-minute log bursts to a single slice comparison + seconds arithmetic.
pub const PrefixEpochCache = struct {
    prefix_buf: [16]u8 = undefined,
    valid: bool = false,
    minute_civil_sec: i64 = 0,
};

/// Returns the current wall-clock Unix timestamp in nanoseconds (`u64`).
pub fn currentUnixNano(io: std.Io) u64 {
    const ts = std.Io.Clock.real.now(io);
    if (ts.nanoseconds <= 0) return 1_700_000_000_000_000_000;
    return @intCast(@min(ts.nanoseconds, std.math.maxInt(u64)));
}

pub const CivilDateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

inline fn isLeapYear(y: u16) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 31,
    };
}

/// Closed-form O(1) civil-to-Unix-seconds conversion (Howard Hinnant's algorithm, valid 1970..2261).
pub fn civilToEpochSeconds(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?i64 {
    if (year < 1970 or year > 2261) return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    var y: i64 = @intCast(year);
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    if (m <= 2) y -= 1;
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const adj_m: i64 = if (m > 2) m - 3 else m + 9; // [0, 11]
    const doy: i64 = @divTrunc(153 * adj_m + 2, 5) + d - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    const days_since_epoch: i64 = era * 146097 + doe - 719468;

    return days_since_epoch * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

/// Closed-form O(1) Unix-seconds-to-civil conversion (Howard Hinnant's algorithm).
pub fn epochSecondsToCivil(epoch_sec: i64) ?CivilDateTime {
    if (epoch_sec < 0) return null;
    const days_since_epoch = @divFloor(epoch_sec, 86400);
    const sec_of_day = epoch_sec - days_since_epoch * 86400;

    const z = days_since_epoch + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    if (m <= 2) y += 1;

    if (y < 1970 or y > 2261) return null;
    const hour: u8 = @intCast(@divFloor(sec_of_day, 3600));
    const rem = @mod(sec_of_day, 3600);
    const minute: u8 = @intCast(@divFloor(rem, 60));
    const second: u8 = @intCast(@mod(rem, 60));

    return .{
        .year = @intCast(y),
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

inline fn parse2Digits(s: []const u8) ?u8 {
    if (s.len < 2) return null;
    if (!std.ascii.isDigit(s[0]) or !std.ascii.isDigit(s[1])) return null;
    return (s[0] - '0') * 10 + (s[1] - '0');
}

inline fn parse4Digits(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    var acc: u16 = 0;
    for (s[0..4]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        acc = acc * 10 + @as(u16, c - '0');
    }
    return acc;
}

fn parseMonthNamePrefix(s: []const u8) ?struct { month: u8, len: usize } {
    const full_months = [_][]const u8{
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    };
    const abbr_months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (full_months, 1..) |m, idx| {
        if (s.len >= m.len and std.ascii.eqlIgnoreCase(s[0..m.len], m)) {
            if (s.len == m.len or !std.ascii.isAlphabetic(s[m.len])) {
                return .{ .month = @intCast(idx), .len = m.len };
            }
        }
    }
    if (s.len >= 3) {
        for (abbr_months, 1..) |m, idx| {
            if (std.ascii.eqlIgnoreCase(s[0..3], m)) {
                if (s.len == 3 or !std.ascii.isAlphabetic(s[3])) {
                    return .{ .month = @intCast(idx), .len = 3 };
                }
            }
        }
    }
    return null;
}

fn parseMonthAbbrev(mon: []const u8) ?u8 {
    const res = parseMonthNamePrefix(mon) orelse return null;
    return if (res.len == mon.len) res.month else null;
}

fn parseWeekdayPrefix(s: []const u8) ?usize {
    const full_days = [_][]const u8{
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    };
    const abbr_days = [_][]const u8{
        "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun",
    };
    var matched_len: ?usize = null;
    for (full_days) |d| {
        if (s.len > d.len and std.ascii.eqlIgnoreCase(s[0..d.len], d) and
            (s[d.len] == ',' or s[d.len] == ' ' or s[d.len] == '\t'))
        {
            matched_len = d.len;
            break;
        }
    }
    if (matched_len == null) {
        for (abbr_days) |d| {
            if (s.len > d.len and std.ascii.eqlIgnoreCase(s[0..d.len], d) and
                (s[d.len] == ',' or s[d.len] == ' ' or s[d.len] == '\t'))
            {
                matched_len = d.len;
                break;
            }
        }
    }
    const base_len = matched_len orelse return null;
    var pos = base_len;
    if (pos < s.len and s[pos] == ',') pos += 1;
    while (pos < s.len and (s[pos] == ' ' or s[pos] == '\t')) : (pos += 1) {}
    return if (pos > base_len) pos else null;
}

fn parse1Or2Digits(s: []const u8) ?struct { val: u8, len: usize } {
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return null;
    if (s.len >= 2 and std.ascii.isDigit(s[1])) {
        return .{ .val = (s[0] - '0') * 10 + (s[1] - '0'), .len = 2 };
    }
    return .{ .val = s[0] - '0', .len = 1 };
}

fn parseAmPm(s: []const u8) ?struct { is_pm: bool, len: usize } {
    if (s.len < 2) return null;
    const is_am = (s[0] == 'A' or s[0] == 'a') and (s[1] == 'M' or s[1] == 'm');
    const is_pm = (s[0] == 'P' or s[0] == 'p') and (s[1] == 'M' or s[1] == 'm');
    if (!is_am and !is_pm) return null;
    if (s.len > 2 and std.ascii.isAlphanumeric(s[2])) return null;
    return .{ .is_pm = is_pm, .len = 2 };
}

fn apply12Hour(hour: u8, is_pm: bool) ?u8 {
    if (hour > 12) return null;
    if (is_pm) return if (hour == 12) 12 else hour + 12;
    return if (hour == 12) 0 else hour;
}

const ParsedTz = struct { offset_sec: i64, len: usize };

/// Parses an explicit timezone suffix starting at `s[0]` (`Z`/`z`, `UTC`/`GMT`, or `±HH[:MM]`).
/// Returns `{ offset_sec, consumed_len }` or `null` if no timezone token starts at `s[0]`.
fn parseExplicitTz(s: []const u8) ?ParsedTz {
    if (s.len == 0) return null;
    if (s[0] == 'Z' or s[0] == 'z') {
        if (s.len == 1 or !std.ascii.isAlphanumeric(s[1])) {
            return .{ .offset_sec = 0, .len = 1 };
        }
        return null;
    }
    if (s.len >= 3 and (std.ascii.eqlIgnoreCase(s[0..3], "UTC") or std.ascii.eqlIgnoreCase(s[0..3], "GMT"))) {
        if (s.len == 3 or !std.ascii.isAlphanumeric(s[3])) {
            return .{ .offset_sec = 0, .len = 3 };
        }
        return null;
    }
    if (s[0] != '+' and s[0] != '-') return null;
    const sign: i64 = if (s[0] == '+') 1 else -1;
    const body = s[1..];
    if (body.len < 2 or !std.ascii.isDigit(body[0]) or !std.ascii.isDigit(body[1])) return null;
    const tz_h = parse2Digits(body[0..2]) orelse return null;
    if (tz_h > 23) return null;
    var tz_m: u8 = 0;
    var consumed: usize = 3;
    if (body.len >= 5 and body[2] == ':' and std.ascii.isDigit(body[3]) and std.ascii.isDigit(body[4])) {
        tz_m = parse2Digits(body[3..5]) orelse return null;
        consumed = 6;
    } else if (body.len >= 4 and std.ascii.isDigit(body[2]) and std.ascii.isDigit(body[3])) {
        tz_m = parse2Digits(body[2..4]) orelse return null;
        consumed = 5;
    }
    if (tz_m > 59) return null;
    if (consumed < s.len and std.ascii.isDigit(s[consumed])) return null;
    return .{
        .offset_sec = sign * (@as(i64, tz_h) * 3600 + @as(i64, tz_m) * 60),
        .len = consumed,
    };
}

/// Parses an explicit timezone suffix requiring full syntax (`Z`, `UTC`, `GMT`, `±HH:MM`, or `±HHMM`)
/// so arbitrary `-12` counts after a timestamp are never confused with a 2-digit hour offset.
fn parseExplicitTzStrict(s: []const u8) ?ParsedTz {
    const tz = parseExplicitTz(s) orelse return null;
    if (tz.len == 3 and (s[0] == '+' or s[0] == '-')) return null;
    return tz;
}

fn parseFractionDigitsNs(s: []const u8) struct { frac_ns: u64, len: usize } {
    var pos: usize = 0;
    var frac_ns: u64 = 0;
    var mult: u64 = 100_000_000;
    while (pos < s.len and std.ascii.isDigit(s[pos])) : (pos += 1) {
        if (mult > 0) {
            frac_ns += @as(u64, s[pos] - '0') * mult;
            mult /= 10;
        }
    }
    return .{ .frac_ns = frac_ns, .len = pos };
}

fn finalizeCivilToNs(
    civil_sec: i64,
    frac_ns: u64,
    explicit_tz_sec: ?i64,
    ctx: FallbackTimeContext,
) ?u64 {
    const tz_sec = explicit_tz_sec orelse ctx.tz_offset_sec;
    const utc_sec = civil_sec - tz_sec;
    if (utc_sec <= 0) return null;
    return @as(u64, @intCast(utc_sec)) *| std.time.ns_per_s +| frac_ns;
}

/// Parses trailing `[.,]\d+` + optional `AM`/`PM` + optional timezone after `sec`/`min`,
/// updating `frac_ns`, `hour_adjust_sec` (only when `AM`/`PM` converts 12h -> 24h), and `explicit_tz`.
fn parseOptionalFracAmPmTz(
    tail: []const u8,
    base_hour: u8,
) struct { consumed: usize, frac_ns: u64, hour: u8, hour_valid: bool, explicit_tz: ?i64 } {
    var pos: usize = 0;
    var frac_ns: u64 = 0;
    if (pos + 1 < tail.len and (tail[pos] == '.' or tail[pos] == ',') and std.ascii.isDigit(tail[pos + 1])) {
        pos += 1;
        const f = parseFractionDigitsNs(tail[pos..]);
        frac_ns = f.frac_ns;
        pos += f.len;
    }

    var hour = base_hour;
    var hour_valid = true;

    // Skip spaces once; peek for AM/PM first, then timezone
    var sp = pos;
    while (sp < tail.len and (tail[sp] == ' ' or tail[sp] == '\t')) : (sp += 1) {}
    if (sp < tail.len) {
        if (parseAmPm(tail[sp..])) |ap| {
            if (apply12Hour(hour, ap.is_pm)) |h24| {
                hour = h24;
            } else {
                hour_valid = false;
            }
            pos = sp + ap.len;
            sp = pos;
            while (sp < tail.len and (tail[sp] == ' ' or tail[sp] == '\t')) : (sp += 1) {}
        }
    }

    var explicit_tz: ?i64 = null;
    if (sp < tail.len) {
        if (sp > pos) {
            if (parseExplicitTzStrict(tail[sp..])) |tz| {
                explicit_tz = tz.offset_sec;
                pos = sp + tz.len;
            }
        } else {
            // Directly attached (e.g. `Z` or `+08:00` or `-0500`)
            if (parseExplicitTzStrict(tail[pos..])) |tz| {
                explicit_tz = tz.offset_sec;
                pos += tz.len;
            }
        }
    }
    return .{
        .consumed = pos,
        .frac_ns = frac_ns,
        .hour = hour,
        .hour_valid = hour_valid,
        .explicit_tz = explicit_tz,
    };
}

/// Parses `H{1,2}:MM(:SS)?` + optional frac / AM|PM / tz starting at `s[0]`.
fn parseTimeAndTail(
    s: []const u8,
) ?struct { hour: u8, minute: u8, second: u8, frac_ns: u64, explicit_tz: ?i64, len: usize } {
    var pos: usize = 0;
    const h_tok = parse1Or2Digits(s[pos..]) orelse return null;
    const raw_hour = h_tok.val;
    if (raw_hour > 23) return null;
    pos += h_tok.len;
    if (pos >= s.len or s[pos] != ':') return null;
    pos += 1;
    const m_tok = parse1Or2Digits(s[pos..]) orelse return null;
    const minute = m_tok.val;
    if (minute > 59) return null;
    pos += m_tok.len;

    var second: u8 = 0;
    if (pos < s.len and s[pos] == ':') {
        if (pos + 3 > s.len) return null;
        second = parse2Digits(s[pos + 1 .. pos + 3]) orelse return null;
        if (second > 60) return null;
        pos += 3;
    }

    // Reject digits immediately stuck to time (e.g. `10:15:023` without dot)
    if (pos < s.len and std.ascii.isDigit(s[pos])) return null;

    const tail = parseOptionalFracAmPmTz(s[pos..], raw_hour);
    if (!tail.hour_valid) return null;
    return .{
        .hour = tail.hour,
        .minute = minute,
        .second = second,
        .frac_ns = tail.frac_ns,
        .explicit_tz = tail.explicit_tz,
        .len = pos + tail.consumed,
    };
}

/// Fast O(1) parser for a 19-digit leading Unix nanosecond timestamp (`<19-digit-ns> <payload>`).
pub inline fn parseLineLeadingNs(line: []const u8) ?u64 {
    if (line.len < 20 or line[19] != ' ') return null;
    var acc: u64 = 0;
    for (line[0..19]) |ch| {
        if (ch < '0' or ch > '9') return null;
        acc = acc *| 10 +| @as(u64, ch - '0');
    }
    return acc;
}

/// Parses 12/14/17-digit compact calendar numbers (`YYYYMMDDHHmm[ss[SSS]]`).
fn parseCompactCalendarDigits(digits: []const u8, frac_tail: []const u8, tz_tail: []const u8, ctx: FallbackTimeContext) ?u64 {
    if (digits.len != 12 and digits.len != 14 and digits.len != 17) return null;
    if (digits[0] != '1' and digits[0] != '2') return null;
    const year = parse4Digits(digits[0..4]) orelse return null;
    if (year < 1995 or year > 2099) {
        if (!(digits.len >= 14 and year >= 1970 and year <= 2099)) return null;
    }
    const month = parse2Digits(digits[4..6]) orelse return null;
    const day = parse2Digits(digits[6..8]) orelse return null;
    const hour = parse2Digits(digits[8..10]) orelse return null;
    const minute = parse2Digits(digits[10..12]) orelse return null;
    const second: u8 = if (digits.len >= 14) (parse2Digits(digits[12..14]) orelse return null) else 0;
    var frac_ns: u64 = 0;
    if (digits.len == 17) {
        const ms = std.fmt.parseInt(u64, digits[14..17], 10) catch return null;
        frac_ns = ms * 1_000_000;
    } else if (frac_tail.len > 0) {
        frac_ns = parseFractionDigitsNs(frac_tail).frac_ns;
    }
    const civil_sec = civilToEpochSeconds(year, month, day, hour, minute, second) orelse return null;
    var explicit_tz: ?i64 = null;
    if (tz_tail.len > 0) {
        const trimmed_tz = std.mem.trimStart(u8, tz_tail, " \t");
        if (parseExplicitTzStrict(trimmed_tz)) |tz| {
            explicit_tz = tz.offset_sec;
        }
    }
    return finalizeCivilToNs(civil_sec, frac_ns, explicit_tz, ctx);
}

/// Attempts to parse any standard calendar timestamp starting at `s[0]`.
fn parseCalendarAt(
    s: []const u8,
    ctx: FallbackTimeContext,
    cache: ?*PrefixEpochCache,
) ?u64 {
    if (s.len < 8) return null;

    // A. Fast-path exact 19-byte ISO-8601 / Log4j / Slash / Dot YMD: `YYYY[-/.]MM[-/.]DD[T _]HH:MM:SS...`
    if (s.len >= 19 and
        (s[4] == '-' or s[4] == '/' or s[4] == '.') and
        s[7] == s[4] and
        (s[10] == 'T' or s[10] == 't' or s[10] == ' ' or s[10] == '_') and
        s[13] == ':' and
        s[16] == ':')
    {
        if (parse2Digits(s[17..19])) |second| {
            if (second <= 60 and (s.len == 19 or !std.ascii.isDigit(s[19]))) {
                var minute_civil_sec: i64 = 0;
                var hour_parsed: u8 = 0;
                var cache_hit = false;
                if (cache != null and cache.?.valid and std.mem.eql(u8, s[0..16], &cache.?.prefix_buf)) {
                    minute_civil_sec = cache.?.minute_civil_sec;
                    hour_parsed = parse2Digits(s[11..13]) orelse 0;
                    cache_hit = true;
                } else if (parse4Digits(s[0..4])) |year| {
                    if (parse2Digits(s[5..7])) |month| {
                        if (parse2Digits(s[8..10])) |day| {
                            if (parse2Digits(s[11..13])) |hour| {
                                if (parse2Digits(s[14..16])) |minute| {
                                    if (civilToEpochSeconds(year, month, day, hour, minute, 0)) |mc| {
                                        minute_civil_sec = mc;
                                        hour_parsed = hour;
                                        if (cache) |c| {
                                            @memcpy(&c.prefix_buf, s[0..16]);
                                            c.minute_civil_sec = mc;
                                            c.valid = true;
                                        }
                                        cache_hit = true;
                                    }
                                }
                            }
                        }
                    }
                }
                if (cache_hit) {
                    const tail = parseOptionalFracAmPmTz(s[19..], hour_parsed);
                    if (!tail.hour_valid) return null;
                    var civil_sec = minute_civil_sec + @as(i64, second);
                    if (tail.hour != hour_parsed) {
                        civil_sec += (@as(i64, tail.hour) - @as(i64, hour_parsed)) * 3600;
                    }
                    return finalizeCivilToNs(civil_sec, tail.frac_ns, tail.explicit_tz, ctx);
                }
            }
        }
    }

    // B. Flexible YMD starting with `1` or `2` (`YYYY[-/.]M{1,2}[-/.]D{1,2}`, CJK `YYYY年M月D日`, compact `YYYYMMDD...`)
    if (s[0] == '1' or s[0] == '2') {
        if (parse4Digits(s[0..4])) |year| {
            if (year >= 1970 and year <= 2261 and s.len >= 8) {
                const sep = s[4];
                if (sep == '-' or sep == '/' or sep == '.') {
                    var pos: usize = 5;
                    if (parse1Or2Digits(s[pos..])) |m_tok| {
                        pos += m_tok.len;
                        if (pos < s.len and s[pos] == sep) {
                            pos += 1;
                            if (parse1Or2Digits(s[pos..])) |d_tok| {
                                pos += d_tok.len;
                                if (pos < s.len and (s[pos] == 'T' or s[pos] == 't' or s[pos] == ' ' or s[pos] == '_' or s[pos] == '-')) {
                                    const dt_sep = s[pos];
                                    pos += 1;
                                    if (parseTimeAndTail(s[pos..])) |t| {
                                        const civil_sec = civilToEpochSeconds(year, m_tok.val, d_tok.val, t.hour, t.minute, t.second) orelse return null;
                                        return finalizeCivilToNs(civil_sec, t.frac_ns, t.explicit_tz, ctx);
                                    }
                                    // Filename/log style `YYYY-MM-DD_HH-MM-SS`
                                    if ((dt_sep == '_' or dt_sep == ' ') and pos + 8 <= s.len and s[pos + 2] == '-' and s[pos + 5] == '-') {
                                        if (parse2Digits(s[pos .. pos + 2])) |hh| {
                                            if (parse2Digits(s[pos + 3 .. pos + 5])) |mm| {
                                                if (parse2Digits(s[pos + 6 .. pos + 8])) |ss| {
                                                    if (pos + 8 == s.len or !std.ascii.isDigit(s[pos + 8])) {
                                                        const civil_sec = civilToEpochSeconds(year, m_tok.val, d_tok.val, hh, mm, ss) orelse return null;
                                                        return finalizeCivilToNs(civil_sec, 0, null, ctx);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if (std.mem.startsWith(u8, s[4..], "年")) {
                    // CJK: `YYYY年M{1,2}月D{1,2}日 ...`
                    var pos: usize = 4 + "年".len;
                    if (parse1Or2Digits(s[pos..])) |m_tok| {
                        pos += m_tok.len;
                        if (std.mem.startsWith(u8, s[pos..], "月")) {
                            pos += "月".len;
                            if (parse1Or2Digits(s[pos..])) |d_tok| {
                                pos += d_tok.len;
                                if (std.mem.startsWith(u8, s[pos..], "日")) {
                                    pos += "日".len;
                                    while (pos < s.len and (s[pos] == ' ' or s[pos] == '\t' or s[pos] == 'T')) : (pos += 1) {}
                                    if (parseTimeAndTail(s[pos..])) |t| {
                                        const civil_sec = civilToEpochSeconds(year, m_tok.val, d_tok.val, t.hour, t.minute, t.second) orelse return null;
                                        return finalizeCivilToNs(civil_sec, t.frac_ns, t.explicit_tz, ctx);
                                    }
                                    // `HH时MM分(SS秒)?`
                                    if (parse1Or2Digits(s[pos..])) |h_tok| {
                                        var p2 = pos + h_tok.len;
                                        if (std.mem.startsWith(u8, s[p2..], "时")) {
                                            p2 += "时".len;
                                            if (parse1Or2Digits(s[p2..])) |min_tok| {
                                                p2 += min_tok.len;
                                                if (std.mem.startsWith(u8, s[p2..], "分")) {
                                                    p2 += "分".len;
                                                    var sec: u8 = 0;
                                                    if (parse1Or2Digits(s[p2..])) |sec_tok| {
                                                        const p3 = p2 + sec_tok.len;
                                                        if (std.mem.startsWith(u8, s[p3..], "秒")) sec = sec_tok.val;
                                                    }
                                                    const civil_sec = civilToEpochSeconds(year, m_tok.val, d_tok.val, h_tok.val, min_tok.val, sec) orelse return null;
                                                    return finalizeCivilToNs(civil_sec, 0, null, ctx);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if (std.ascii.isDigit(sep) and s.len >= 13) {
                    // Compact `YYYYMMDD` + (`T`/` `/` _`/`-`) + (`HH:MM...` or `HHMMSS`) or pure 14/17-digit
                    if (parse2Digits(s[4..6])) |month| {
                        if (parse2Digits(s[6..8])) |day| {
                            if (s.len > 8 and (s[8] == 'T' or s[8] == 't' or s[8] == ' ' or s[8] == '_' or s[8] == '-')) {
                                const rest = s[9..];
                                if (parseTimeAndTail(rest)) |t| {
                                    const civil_sec = civilToEpochSeconds(year, month, day, t.hour, t.minute, t.second) orelse return null;
                                    return finalizeCivilToNs(civil_sec, t.frac_ns, t.explicit_tz, ctx);
                                }
                                // `20261114T101502[.frac][Z|tz]` or `20261114_101502`
                                if (rest.len >= 6) {
                                    if (parse2Digits(rest[0..2])) |hh| {
                                        if (parse2Digits(rest[2..4])) |mm| {
                                            if (parse2Digits(rest[4..6])) |ss| {
                                                const tail = parseOptionalFracAmPmTz(rest[6..], hh);
                                                if (!tail.hour_valid) return null;
                                                const end_pos = 6 + tail.consumed;
                                                if (end_pos == rest.len or !std.ascii.isAlphanumeric(rest[end_pos])) {
                                                    const civil_sec = civilToEpochSeconds(year, month, day, tail.hour, mm, ss) orelse return null;
                                                    return finalizeCivilToNs(civil_sec, tail.frac_ns, tail.explicit_tz, ctx);
                                                }
                                            }
                                        }
                                    }
                                }
                            } else if (std.ascii.isDigit(s[8])) {
                                var dlen: usize = 8;
                                while (dlen < s.len and dlen < 19 and std.ascii.isDigit(s[dlen])) : (dlen += 1) {}
                                if (dlen == 14 or dlen == 17) {
                                    if (dlen == s.len or !std.ascii.isAlphanumeric(s[dlen])) {
                                        var frac_tail: []const u8 = "";
                                        var after_frac = dlen;
                                        if (dlen == 14 and dlen + 1 < s.len and (s[dlen] == '.' or s[dlen] == ',') and std.ascii.isDigit(s[dlen + 1])) {
                                            const f = parseFractionDigitsNs(s[dlen + 1 ..]);
                                            frac_tail = s[dlen + 1 .. dlen + 1 + f.len];
                                            after_frac = dlen + 1 + f.len;
                                        }
                                        if (parseCompactCalendarDigits(s[0..dlen], frac_tail, s[after_frac..], ctx)) |ns| {
                                            return ns;
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

    // Optional weekday prefix (`Sat, ` / `Sat `) for RFC 2822 & Apache ctime
    const body = if (parseWeekdayPrefix(s)) |wlen| s[wlen..] else s;

    // C. Day-MonthName-Year: CLF / Tomcat / Oracle / RFC 2822 (`14/Nov/2026:10:15:02 +0800`, `14 Nov 2026 10:15:02 GMT`, `14-Nov-2026 10:15:02`)
    if (body.len >= 16 and std.ascii.isDigit(body[0])) {
        if (parse1Or2Digits(body)) |d_tok| {
            var pos = d_tok.len;
            if (pos < body.len and (body[pos] == '/' or body[pos] == '-' or body[pos] == ' ')) {
                pos += 1;
                if (parseMonthNamePrefix(body[pos..])) |m_tok| {
                    pos += m_tok.len;
                    if (pos < body.len and (body[pos] == '/' or body[pos] == '-' or body[pos] == ' ')) {
                        pos += 1;
                        if (parse4Digits(body[pos..])) |year| {
                            pos += 4;
                            if (pos < body.len and (body[pos] == ':' or body[pos] == ' ' or body[pos] == 'T')) {
                                pos += 1;
                                while (pos < body.len and body[pos] == ' ') : (pos += 1) {}
                                if (parseTimeAndTail(body[pos..])) |t| {
                                    const civil_sec = civilToEpochSeconds(year, m_tok.month, d_tok.val, t.hour, t.minute, t.second) orelse return null;
                                    return finalizeCivilToNs(civil_sec, t.frac_ns, t.explicit_tz, ctx);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // D. MonthName-Day[-Year]: Syslog (`Nov 14 10:15:02`), Apache Error (`Sat Nov 14 10:15:02.123456 2026`), `Nov 14, 2026 10:15:02 PM`
    if (body.len >= 14 and std.ascii.isAlphabetic(body[0])) {
        if (parseMonthNamePrefix(body)) |m_tok| {
            var pos = m_tok.len;
            var sp_count: usize = 0;
            while (pos < body.len and body[pos] == ' ') : (pos += 1) sp_count += 1;
            if (sp_count >= 1) {
                if (parse1Or2Digits(body[pos..])) |d_tok| {
                    pos += d_tok.len;
                    var explicit_year: ?u16 = null;
                    if (pos < body.len and body[pos] == ',') pos += 1;
                    while (pos < body.len and body[pos] == ' ') : (pos += 1) {}
                    // Optional `YYYY` before time (e.g. `Nov 14, 2026 10:15:02 PM` or `Nov 14 2026 10:15:02`)
                    if (pos + 5 <= body.len and (body[pos] == '1' or body[pos] == '2')) {
                        if (parse4Digits(body[pos..])) |y_pre| {
                            if (pos + 4 < body.len and body[pos + 4] == ' ') {
                                explicit_year = y_pre;
                                pos += 5;
                                while (pos < body.len and body[pos] == ' ') : (pos += 1) {}
                            }
                        }
                    }
                    if (parseTimeAndTail(body[pos..])) |t| {
                        pos += t.len;
                        // Optional `YYYY` after time when year omitted before time (e.g. Apache ctime `Sat Nov 14 10:15:02.123456 2026`)
                        var final_tz = t.explicit_tz;
                        if (explicit_year == null) {
                            var sp_y = pos;
                            while (sp_y < body.len and body[sp_y] == ' ') : (sp_y += 1) {}
                            if (sp_y > pos and sp_y + 4 <= body.len and (body[sp_y] == '1' or body[sp_y] == '2')) {
                                if (parse4Digits(body[sp_y..])) |y_post| {
                                    if (sp_y + 4 == body.len or !std.ascii.isAlphanumeric(body[sp_y + 4])) {
                                        explicit_year = y_post;
                                        sp_y += 4;
                                        while (sp_y < body.len and body[sp_y] == ' ') : (sp_y += 1) {}
                                        if (final_tz == null and sp_y < body.len) {
                                            if (parseExplicitTzStrict(body[sp_y..])) |tz| final_tz = tz.offset_sec;
                                        }
                                    }
                                }
                            }
                        }
                        const eff_year: u16 = explicit_year orelse (if (ctx.year >= 1970) ctx.year else 2026);
                        const civil_sec = civilToEpochSeconds(eff_year, m_tok.month, d_tok.val, t.hour, t.minute, t.second) orelse return null;
                        return finalizeCivilToNs(civil_sec, t.frac_ns, final_tz, ctx);
                    }
                }
            }
        }
    }

    // E. Numeric DMY / MDY with 4-digit year: `DD.MM.YYYY HH:MM:SS`, `DD-MM-YYYY HH:MM:SS`, `MM/DD/YYYY HH:MM:SS`
    if (s.len >= 15 and std.ascii.isDigit(s[0])) {
        if (parse1Or2Digits(s)) |a_tok| {
            var pos = a_tok.len;
            if (pos < s.len and (s[pos] == '.' or s[pos] == '/' or s[pos] == '-')) {
                const sep = s[pos];
                pos += 1;
                if (parse1Or2Digits(s[pos..])) |b_tok| {
                    pos += b_tok.len;
                    if (pos < s.len and s[pos] == sep) {
                        pos += 1;
                        if (parse4Digits(s[pos..])) |year| {
                            if (year >= 1970 and year <= 2261) {
                                pos += 4;
                                if (pos < s.len and (s[pos] == 'T' or s[pos] == 't' or s[pos] == ' ')) {
                                    pos += 1;
                                    while (pos < s.len and s[pos] == ' ') : (pos += 1) {}
                                    if (parseTimeAndTail(s[pos..])) |t| {
                                        var month: u8 = undefined;
                                        var day: u8 = undefined;
                                        if (sep == '.' or sep == '-' or a_tok.val > 12) {
                                            day = a_tok.val;
                                            month = b_tok.val;
                                        } else {
                                            // Slash with first field <= 12: US MM/DD/YYYY
                                            month = a_tok.val;
                                            day = b_tok.val;
                                        }
                                        const civil_sec = civilToEpochSeconds(year, month, day, t.hour, t.minute, t.second) orelse return null;
                                        return finalizeCivilToNs(civil_sec, t.frac_ns, t.explicit_tz, ctx);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return null;
}

/// Parses an isolated timestamp token/value into Unix nanoseconds (`u64`) honoring `FallbackTimeContext`
/// and optional per-worker `PrefixEpochCache`.
pub fn parseTimestampValueNs(
    raw: []const u8,
    ctx: FallbackTimeContext,
    cache: ?*PrefixEpochCache,
) ?u64 {
    const s = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (s.len == 0) return null;

    // 1. Check pure integer or float timestamp (compact calendar YYYYMMDDHHmm[ss[SSS]] or Unix epoch)
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
            // Check `YYYYMMDDHHmmss.frac`
            if (dp == 14) {
                if (parseCompactCalendarDigits(s[0..14], s[dp + 1 ..], "", ctx)) |ns| return ns;
            }
            const sec_part = std.fmt.parseInt(u64, s[0..dp], 10) catch return null;
            if (s[0..dp].len >= 12) {
                if (s[0..dp].len >= 14) return null;
                return sec_part *| std.time.ns_per_ms;
            }
            if (s[0..dp].len < 9) return null;
            const frac = parseFractionDigitsNs(s[dp + 1 ..]);
            return sec_part *| std.time.ns_per_s +| frac.frac_ns;
        } else {
            if (s.len == 12 or s.len == 14 or s.len == 17) {
                if (parseCompactCalendarDigits(s, "", "", ctx)) |ns| return ns;
            }
            const val = std.fmt.parseInt(u64, s, 10) catch return null;
            if (s.len >= 18) return val; // nanoseconds
            if (s.len >= 15) return val *| 1_000; // microseconds
            if (s.len >= 12) return val *| 1_000_000; // milliseconds
            if (s.len >= 9) return val *| 1_000_000_000; // seconds
            return null;
        }
    }

    if (parseCalendarAt(s, ctx, cache)) |ns| return ns;

    // 2. Short `MM-DD HH:MM:SS` (logcat) or `YY-MM-DD HH:MM:SS` in isolated token
    if (parseShortDateAt(s, ctx)) |ns| return ns;

    return null;
}

/// Parses short yearless `MM[-/]DD HH:MM[:SS]...`, 2-digit year `YY[-/.]MM[-/.]DD HH:MM[:SS]...`,
/// or Google glog/klog `[IWEFD]MMDD HH:MM:SS[.uuuuuu]`.
fn parseShortDateAt(s: []const u8, ctx: FallbackTimeContext) ?u64 {
    const eff_year: u16 = if (ctx.year >= 1970) ctx.year else 2026;

    // Google glog / Kubernetes klog: `I1114 10:15:02.123456`
    if (s.len >= 14 and
        (s[0] == 'I' or s[0] == 'W' or s[0] == 'E' or s[0] == 'F' or s[0] == 'D') and
        s[5] == ' ')
    {
        if (parse2Digits(s[1..3])) |month| {
            if (parse2Digits(s[3..5])) |day| {
                var pos: usize = 6;
                while (pos < s.len and s[pos] == ' ') : (pos += 1) {}
                if (parseTimeAndTail(s[pos..])) |t| {
                    const civil_sec = civilToEpochSeconds(eff_year, month, day, t.hour, t.minute, t.second) orelse return null;
                    return finalizeCivilToNs(civil_sec, t.frac_ns, t.explicit_tz, ctx);
                }
            }
        }
    }

    // 2-digit year: `YY[-/.]MM[-/.]DD[T ]H:MM(:SS)?`
    if (s.len >= 14 and std.ascii.isDigit(s[0]) and std.ascii.isDigit(s[1]) and
        (s[2] == '-' or s[2] == '/' or s[2] == '.'))
    {
        const sep = s[2];
        if (parse2Digits(s[0..2])) |y2| {
            if (parse2Digits(s[3..5])) |month| {
                if (s[5] == sep) {
                    if (parse2Digits(s[6..8])) |day| {
                        if (s.len > 8 and (s[8] == 'T' or s[8] == ' ')) {
                            if (parseTimeAndTail(s[9..])) |t| {
                                const full_y: u16 = if (y2 >= 70) 1900 + @as(u16, y2) else 2000 + @as(u16, y2);
                                const civil_sec = civilToEpochSeconds(full_y, month, day, t.hour, t.minute, t.second) orelse return null;
                                return finalizeCivilToNs(civil_sec, t.frac_ns, t.explicit_tz, ctx);
                            }
                        }
                    }
                }
            }
        }
    }

    // Yearless Android logcat: `MM[-/]DD H:MM:SS`
    if (s.len >= 14 and std.ascii.isDigit(s[0]) and std.ascii.isDigit(s[1]) and
        (s[2] == '-' or s[2] == '/'))
    {
        if (parse2Digits(s[0..2])) |month| {
            if (parse2Digits(s[3..5])) |day| {
                var pos: usize = 5;
                if (pos < s.len and s[pos] == ' ') {
                    while (pos < s.len and s[pos] == ' ') : (pos += 1) {}
                    if (parseTimeAndTail(s[pos..])) |t| {
                        const civil_sec = civilToEpochSeconds(eff_year, month, day, t.hour, t.minute, t.second) orelse return null;
                        return finalizeCivilToNs(civil_sec, t.frac_ns, t.explicit_tz, ctx);
                    }
                }
            }
        }
    }

    return null;
}

/// Parses leading time-only `HH:MM:SS([.,]frac)?([Z|±tz])?` inheriting `(ctx.year, ctx.month, ctx.day)`.
fn parseLeadingTimeOnlyAt(s: []const u8, ctx: FallbackTimeContext) ?u64 {
    if (s.len < 8 or s[2] != ':' or s[5] != ':') return null;
    const t = parseTimeAndTail(s) orelse return null;
    // Must end at slice end or whitespace/delimiter so `12:34:56:78` (MAC address!) is rejected
    if (t.len < s.len) {
        const next = s[t.len];
        if (next != ' ' and next != '\t' and next != ']' and next != '|' and next != ',' and next != ';') {
            return null;
        }
    }
    const eff_y: u16 = if (ctx.year >= 1970) ctx.year else 2026;
    const eff_m: u8 = if (ctx.month >= 1 and ctx.month <= 12) ctx.month else 1;
    const eff_d: u8 = @min(if (ctx.day >= 1) ctx.day else 1, daysInMonth(eff_y, eff_m));
    const civil_sec = civilToEpochSeconds(eff_y, eff_m, eff_d, t.hour, t.minute, t.second) orelse return null;
    return finalizeCivilToNs(civil_sec, t.frac_ns, t.explicit_tz, ctx);
}

fn findJsonKeyValue(win: []const u8, key_quoted: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, win, pos, key_quoted)) |idx| {
        var after = idx + key_quoted.len;
        while (after < win.len and (win[after] == ' ' or win[after] == '\t')) : (after += 1) {}
        if (after < win.len and win[after] == ':') {
            after += 1;
            while (after < win.len and (win[after] == ' ' or win[after] == '\t')) : (after += 1) {}
            if (after >= win.len) return null;
            if (win[after] == '"') {
                const s_start = after + 1;
                const s_end = std.mem.indexOfScalarPos(u8, win, s_start, '"') orelse return null;
                return win[s_start..s_end];
            } else {
                var val_end = after;
                while (val_end < win.len and (std.ascii.isDigit(win[val_end]) or win[val_end] == '.')) : (val_end += 1) {}
                if (val_end > after) return win[after..val_end];
            }
        }
        pos = idx + key_quoted.len;
    }
    return null;
}

fn sliceAtLineEnd(raw_line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, raw_line, '\n')) |nl| {
        const end = if (nl > 0 and raw_line[nl - 1] == '\r') nl - 1 else nl;
        return raw_line[0..end];
    }
    return std.mem.trimEnd(u8, raw_line, "\r");
}

/// Universal zero-allocation timestamp sniffer for WebGrep native streams, ISO-8601, RFC3339,
/// Log4j, Slash/Dot/CJK YMD, Compact, CLF, RFC 2822, Apache ctime, Syslog, US/EU DMY/MDY,
/// Google glog/klog, Android logcat, 2-digit year, leading epoch, leading time-only, logfmt, and JSONL.
pub fn parseUniversalLineNs(
    raw_line: []const u8,
    ctx: FallbackTimeContext,
    cache: ?*PrefixEpochCache,
) ?u64 {
    const line = sliceAtLineEnd(raw_line);
    if (line.len < 8) return null;

    // 1. Fast O(1) 19-digit nanosecond prefix (`<19-digit-ns> <payload>`)
    if (parseLineLeadingNs(line)) |ns| return ns;

    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 8) return null;

    // 2. JSON Lines starting with `{`: scan first 512 bytes for common timestamp keys
    if (trimmed[0] == '{') {
        const win = trimmed[0..@min(trimmed.len, 512)];
        const keys = [_][]const u8{
            "\"@timestamp\"", "\"timestamp\"", "\"time\"",       "\"ts\"",
            "\"datetime\"",   "\"date\"",      "\"t\"",          "\"_time\"",
            "\"logged_at\"",  "\"created_at\"", "\"eventTime\"", "\"logTime\"",
            "\"start_time\"", "\"ts_ms\"",     "\"time_ms\"",    "\"timestamp_ms\"",
            "\"timeMillis\"", "\"epoch\"",
        };
        for (keys) |k| {
            if (findJsonKeyValue(win, k)) |val_slice| {
                if (parseTimestampValueNs(val_slice, ctx, cache)) |ns| return ns;
            }
        }
        return null;
    }

    // 3. Optional syslog `<PRI>` prefix (`<134>Oct 31 10:15:02...`)
    var start_at: usize = 0;
    if (trimmed[0] == '<') {
        if (std.mem.indexOfScalar(u8, trimmed[0..@min(trimmed.len, 8)], '>')) |gt| {
            start_at = gt + 1;
            while (start_at < trimmed.len and (trimmed[start_at] == ' ' or trimmed[start_at] == '\t')) : (start_at += 1) {}
        }
    }
    const after_pri = trimmed[start_at..];
    if (after_pri.len < 8) return null;

    // 4. Leading `[...]` fast-path (supports glog-like, epoch, time-only, Apache ctime, ISO/CLF inside brackets)
    if (after_pri[0] == '[') {
        if (std.mem.indexOfScalar(u8, after_pri[1..@min(after_pri.len, 64)], ']')) |rel_close| {
            const inner = std.mem.trim(u8, after_pri[1 .. 1 + rel_close], " \t");
            if (parseTimestampValueNs(inner, ctx, cache)) |ns| return ns;
            if (parseLeadingTimeOnlyAt(inner, ctx)) |ns| return ns;
        }
    }

    // 5. Line-start formats: glog (`I1114`), logcat (`11-14`), 2-digit year (`26-11-14`), leading epoch, leading `HH:MM:SS`
    if (parseShortDateAt(after_pri, ctx)) |ns| return ns;

    if (std.ascii.isDigit(after_pri[0])) {
        var tok_end: usize = 0;
        while (tok_end < after_pri.len and tok_end < 24 and
            (std.ascii.isDigit(after_pri[tok_end]) or after_pri[tok_end] == '.')) : (tok_end += 1)
        {}
        if (tok_end >= 10 and (tok_end == after_pri.len or
            after_pri[tok_end] == ' ' or after_pri[tok_end] == '\t' or
            after_pri[tok_end] == ',' or after_pri[tok_end] == '|' or
            after_pri[tok_end] == ']'))
        {
            if (parseTimestampValueNs(after_pri[0..tok_end], ctx, cache)) |ns| {
                // Guard bare leading integers to plausible years 2000..2100 unless 14/17-digit calendar
                const min_sane: u64 = 946_684_800 * std.time.ns_per_s;
                const max_sane: u64 = 4_102_444_800 * std.time.ns_per_s;
                if (ns >= min_sane and ns <= max_sane) return ns;
            }
        }
        if (parseLeadingTimeOnlyAt(after_pri, ctx)) |ns| return ns;
    }

    // 6. Scan first 64 bytes for any calendar format (`YMD`, `CJK`, `Compact`, `CLF`, `RFC2822`, `Syslog`, `Apache ctime`, `DMY/MDY`)
    const scan_limit = @min(after_pri.len, 64);
    var i: usize = 0;
    while (i + 10 <= after_pri.len and i < scan_limit) : (i += 1) {
        if (i > 0 and std.ascii.isAlphanumeric(after_pri[i - 1])) continue;
        const c = after_pri[i];
        const maybe_start = std.ascii.isDigit(c) or switch (std.ascii.toLower(c)) {
            'j', 'f', 'm', 'a', 's', 'o', 'n', 'd', 't', 'w' => true,
            else => false,
        };
        if (!maybe_start) continue;
        const cand_end = @min(after_pri.len, i + 48);
        if (parseCalendarAt(after_pri[i..cand_end], ctx, cache)) |ns| return ns;
    }

    // 7. Scan bracketed tokens beyond byte 0 (`10.0.0.1 - - [14/Nov/2026:10:15:02 +0800]`) within first 96 bytes
    const br_win = after_pri[0..@min(after_pri.len, 96)];
    var br_pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, br_win, br_pos, '[')) |open_br| {
        if (open_br + 1 < br_win.len) {
            if (std.mem.indexOfScalarPos(u8, br_win, open_br + 1, ']')) |close_br| {
                const inner = std.mem.trim(u8, br_win[open_br + 1 .. close_br], " \t");
                if (parseTimestampValueNs(inner, ctx, cache)) |ns| return ns;
            }
        }
        br_pos = open_br + 1;
    }

    // 8. `logfmt` (`key=val` within first 192 bytes)
    const lf_win = trimmed[0..@min(trimmed.len, 192)];
    const lf_keys = [_][]const u8{ "@timestamp=", "timestamp=", "time=", "datetime=", "ts=", "t=" };
    for (lf_keys) |k| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, lf_win, pos, k)) |idx| {
            if (idx == 0 or !std.ascii.isAlphanumeric(lf_win[idx - 1])) {
                const vstart = idx + k.len;
                if (vstart < lf_win.len) {
                    var val_slice: []const u8 = "";
                    if (lf_win[vstart] == '"') {
                        if (std.mem.indexOfScalarPos(u8, lf_win, vstart + 1, '"')) |vend| {
                            val_slice = lf_win[vstart + 1 .. vend];
                        }
                    } else {
                        var vend = vstart;
                        while (vend < lf_win.len and lf_win[vend] != ' ' and lf_win[vend] != '\t' and lf_win[vend] != ',' and lf_win[vend] != ';') : (vend += 1) {}
                        val_slice = lf_win[vstart..vend];
                    }
                    if (val_slice.len > 0) {
                        if (parseTimestampValueNs(val_slice, ctx, cache)) |ns| return ns;
                    }
                }
            }
            pos = idx + k.len;
        }
    }

    return null;
}

// ============================================================================
// Tier 2: Precompiled Fixed-Capacity `strftime` & Date-Picture Template Engine
// ============================================================================

pub const MAX_STRFTIME_OPS: usize = 32;
pub const MAX_STRFTIME_LIT_BYTES: usize = 128;

pub const TimeOpTag = enum {
    lit,
    ws, // one or more horizontal whitespace chars
    year4, // %Y / yyyy
    year2, // %y / yy
    month2, // %m / M / MM
    month_name, // %b / %h / %B / MMM / MMMM
    day2, // %d / d / dd
    day_space, // %e (space-padded day)
    hour2, // %H / H / HH / h / hh
    hour12, // %I / h / hh (with AM/PM)
    min2, // %M / m / mm
    sec2, // %S / s / ss
    frac, // %f / %.f / S..SSSSSSSSS / f..fffffffff
    tz, // %z / %Z / Z / z / X
    ampm, // %p / %P / a / am / pm
    epoch_s, // %s / epoch
    epoch_ms, // %Q / epoch_ms
    epoch_us, // epoch_us
    epoch_ns, // epoch_ns
};

pub const TimeOp = struct {
    tag: TimeOpTag,
    lit_start: u8 = 0,
    lit_len: u8 = 0,
    /// Hint: for `frac`: `0` = var 1..9 digits, `1` = optional dot+frac, `3/6/9` = exact width;
    /// for `month2`/`day2`/`hour2`/`hour12`/`min2`/`sec2`: `1` = flexible 1-or-2 digits, `2` = 2 digits preferred.
    param: u8 = 0,
};

pub const StrftimeProg = struct {
    ops: [MAX_STRFTIME_OPS]TimeOp = undefined,
    op_len: u8 = 0,
    lit_buf: [MAX_STRFTIME_LIT_BYTES]u8 = undefined,
    lit_len: u8 = 0,
    anchored: bool = false,

    const PicTokKind = enum {
        lit,
        ws,
        year4,
        year2,
        month_name,
        day,
        hour24,
        hour_ambig,
        month_num,
        minute,
        m_upper,
        m_lower,
        sec,
        s_upper,
        frac_f,
        tz,
        ampm,
        epoch_s,
        epoch_ms,
        epoch_us,
        epoch_ns,
    };

    const PicTok = struct {
        kind: PicTokKind,
        lit_start: u8 = 0,
        lit_len: u8 = 0,
        param: u8 = 0,
    };

    fn eqLower(a: []const u8, comptime b_lower: []const u8) bool {
        return a.len == b_lower.len and std.ascii.eqlIgnoreCase(a, b_lower);
    }

    pub fn compile(
        arena: std.mem.Allocator,
        raw_spec: []const u8,
        err_msg_out: *?[]const u8,
    ) ?StrftimeProg {
        var prog = StrftimeProg{};
        var spec = std.mem.trim(u8, raw_spec, " \t\r\n");
        if (spec.len == 0) {
            err_msg_out.* = "Time format template cannot be empty";
            return null;
        }
        if (spec[0] == '^') {
            prog.anchored = true;
            spec = spec[1..];
        }
        if (spec.len == 0) {
            err_msg_out.* = "Time format template '^' must be followed by specifiers";
            return null;
        }

        // Standalone epoch shorthands (case-insensitive)
        if (eqLower(spec, "epoch") or eqLower(spec, "unix") or eqLower(spec, "epoch_s") or eqLower(spec, "unix_s")) {
            prog.ops[0] = .{ .tag = .epoch_s };
            prog.op_len = 1;
            return prog;
        }
        if (eqLower(spec, "epoch_ms") or eqLower(spec, "unix_ms")) {
            prog.ops[0] = .{ .tag = .epoch_ms };
            prog.op_len = 1;
            return prog;
        }
        if (eqLower(spec, "epoch_us") or eqLower(spec, "unix_us")) {
            prog.ops[0] = .{ .tag = .epoch_us };
            prog.op_len = 1;
            return prog;
        }
        if (eqLower(spec, "epoch_ns") or eqLower(spec, "unix_ns")) {
            prog.ops[0] = .{ .tag = .epoch_ns };
            prog.op_len = 1;
            return prog;
        }

        if (std.mem.indexOfScalar(u8, spec, '%') != null) {
            return compileStrftime(&prog, arena, spec, err_msg_out);
        }
        return compilePicture(&prog, arena, spec, err_msg_out);
    }

    fn compileStrftime(
        prog_in: *StrftimeProg,
        arena: std.mem.Allocator,
        spec: []const u8,
        err_msg_out: *?[]const u8,
    ) ?StrftimeProg {
        var prog = prog_in.*;
        var directive_count: usize = 0;
        var lit_start: usize = 0;
        var cur_lit_open = false;

        const flushLit = struct {
            fn call(p: *StrftimeProg, start_idx: *usize, open: *bool, byte: ?u8) bool {
                if (byte) |b| {
                    if (!open.*) {
                        start_idx.* = p.lit_len;
                        open.* = true;
                    }
                    if (p.lit_len >= MAX_STRFTIME_LIT_BYTES) return false;
                    p.lit_buf[p.lit_len] = b;
                    p.lit_len += 1;
                    return true;
                } else {
                    if (open.*) {
                        if (p.op_len >= MAX_STRFTIME_OPS) return false;
                        p.ops[p.op_len] = .{
                            .tag = .lit,
                            .lit_start = @intCast(start_idx.*),
                            .lit_len = @intCast(p.lit_len - start_idx.*),
                        };
                        p.op_len += 1;
                        open.* = false;
                    }
                    return true;
                }
            }
        }.call;

        const pushOp = struct {
            fn call(p: *StrftimeProg, op: TimeOp) bool {
                if (p.op_len >= MAX_STRFTIME_OPS) return false;
                p.ops[p.op_len] = op;
                p.op_len += 1;
                return true;
            }
        }.call;

        var i: usize = 0;
        while (i < spec.len) {
            const ch = spec[i];
            if (ch == ' ' or ch == '\t') {
                if (!flushLit(&prog, &lit_start, &cur_lit_open, null)) {
                    err_msg_out.* = "Time format template exceeds maximum length";
                    return null;
                }
                while (i + 1 < spec.len and (spec[i + 1] == ' ' or spec[i + 1] == '\t')) : (i += 1) {}
                if (!pushOp(&prog, .{ .tag = .ws })) return tooMany(err_msg_out);
                i += 1;
                continue;
            }
            if (ch != '%') {
                if (!flushLit(&prog, &lit_start, &cur_lit_open, ch)) {
                    err_msg_out.* = "Time format literal section exceeds 128 bytes";
                    return null;
                }
                i += 1;
                continue;
            }
            if (i + 1 >= spec.len) {
                err_msg_out.* = "Trailing '%' in time format template";
                return null;
            }
            const next = spec[i + 1];
            if (next == '%') {
                if (!flushLit(&prog, &lit_start, &cur_lit_open, '%')) {
                    err_msg_out.* = "Time format literal section exceeds 128 bytes";
                    return null;
                }
                i += 2;
                continue;
            }

            if (!flushLit(&prog, &lit_start, &cur_lit_open, null)) return tooMany(err_msg_out);

            // Support `%3f`, `%6f`, `%9f`, `%.f`
            if ((next == '.' or next == '3' or next == '6' or next == '9') and i + 2 < spec.len and spec[i + 2] == 'f') {
                directive_count += 1;
                const param: u8 = if (next == '.') 1 else (next - '0');
                if (!pushOp(&prog, .{ .tag = .frac, .param = param })) return tooMany(err_msg_out);
                i += 3;
                continue;
            }

            switch (next) {
                'Y' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .year4 })) return tooMany(err_msg_out);
                },
                'y' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .year2 })) return tooMany(err_msg_out);
                },
                'm' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .month2, .param = 2 })) return tooMany(err_msg_out);
                },
                'b', 'h', 'B' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .month_name })) return tooMany(err_msg_out);
                },
                'd' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .day2, .param = 2 })) return tooMany(err_msg_out);
                },
                'e' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .day_space })) return tooMany(err_msg_out);
                },
                'H' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .hour2, .param = 2 })) return tooMany(err_msg_out);
                },
                'I' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .hour12, .param = 2 })) return tooMany(err_msg_out);
                },
                'M' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .min2, .param = 2 })) return tooMany(err_msg_out);
                },
                'S' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .sec2, .param = 2 })) return tooMany(err_msg_out);
                },
                'f' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .frac })) return tooMany(err_msg_out);
                },
                'z', 'Z' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .tz })) return tooMany(err_msg_out);
                },
                'p', 'P' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .ampm })) return tooMany(err_msg_out);
                },
                's' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .epoch_s })) return tooMany(err_msg_out);
                },
                'Q' => {
                    directive_count += 1;
                    if (!pushOp(&prog, .{ .tag = .epoch_ms })) return tooMany(err_msg_out);
                },
                'F' => {
                    directive_count += 3;
                    if (!pushOp(&prog, .{ .tag = .year4 })) return tooMany(err_msg_out);
                    if (!flushLit(&prog, &lit_start, &cur_lit_open, '-') or !flushLit(&prog, &lit_start, &cur_lit_open, null)) return tooMany(err_msg_out);
                    if (!pushOp(&prog, .{ .tag = .month2, .param = 2 })) return tooMany(err_msg_out);
                    if (!flushLit(&prog, &lit_start, &cur_lit_open, '-') or !flushLit(&prog, &lit_start, &cur_lit_open, null)) return tooMany(err_msg_out);
                    if (!pushOp(&prog, .{ .tag = .day2, .param = 2 })) return tooMany(err_msg_out);
                },
                'T' => {
                    directive_count += 3;
                    if (!pushOp(&prog, .{ .tag = .hour2, .param = 2 })) return tooMany(err_msg_out);
                    if (!flushLit(&prog, &lit_start, &cur_lit_open, ':') or !flushLit(&prog, &lit_start, &cur_lit_open, null)) return tooMany(err_msg_out);
                    if (!pushOp(&prog, .{ .tag = .min2, .param = 2 })) return tooMany(err_msg_out);
                    if (!flushLit(&prog, &lit_start, &cur_lit_open, ':') or !flushLit(&prog, &lit_start, &cur_lit_open, null)) return tooMany(err_msg_out);
                    if (!pushOp(&prog, .{ .tag = .sec2, .param = 2 })) return tooMany(err_msg_out);
                },
                'R' => {
                    directive_count += 2;
                    if (!pushOp(&prog, .{ .tag = .hour2, .param = 2 })) return tooMany(err_msg_out);
                    if (!flushLit(&prog, &lit_start, &cur_lit_open, ':') or !flushLit(&prog, &lit_start, &cur_lit_open, null)) return tooMany(err_msg_out);
                    if (!pushOp(&prog, .{ .tag = .min2, .param = 2 })) return tooMany(err_msg_out);
                },
                'D' => {
                    directive_count += 3;
                    if (!pushOp(&prog, .{ .tag = .month2, .param = 2 })) return tooMany(err_msg_out);
                    if (!flushLit(&prog, &lit_start, &cur_lit_open, '/') or !flushLit(&prog, &lit_start, &cur_lit_open, null)) return tooMany(err_msg_out);
                    if (!pushOp(&prog, .{ .tag = .day2, .param = 2 })) return tooMany(err_msg_out);
                    if (!flushLit(&prog, &lit_start, &cur_lit_open, '/') or !flushLit(&prog, &lit_start, &cur_lit_open, null)) return tooMany(err_msg_out);
                    if (!pushOp(&prog, .{ .tag = .year2 })) return tooMany(err_msg_out);
                },
                else => {
                    err_msg_out.* = std.fmt.allocPrint(
                        arena,
                        "Unsupported time specifier '%{c}'. Supported: %Y %y %m %b %B %d %e %H %I %M %S %f %p %z %s %Q %F %T",
                        .{next},
                    ) catch "Unsupported time format specifier";
                    return null;
                },
            }
            i += 2;
        }

        if (!flushLit(&prog, &lit_start, &cur_lit_open, null)) return tooMany(err_msg_out);
        if (directive_count == 0) {
            err_msg_out.* = "Time format must contain at least one % directive (e.g. %Y-%m-%d %H:%M:%S)";
            return null;
        }
        return prog;
    }

    fn compilePicture(
        prog_in: *StrftimeProg,
        arena: std.mem.Allocator,
        spec: []const u8,
        err_msg_out: *?[]const u8,
    ) ?StrftimeProg {
        var prog = prog_in.*;
        var toks: [MAX_STRFTIME_OPS]PicTok = undefined;
        var tok_len: usize = 0;

        const appendTokLitByte = struct {
            fn call(p: *StrftimeProg, arr: *[MAX_STRFTIME_OPS]PicTok, tlen: *usize, byte: u8, force_new: bool, err_out: *?[]const u8) bool {
                if (p.lit_len >= MAX_STRFTIME_LIT_BYTES) {
                    err_out.* = "Time format literal section exceeds 128 bytes";
                    return false;
                }
                if (!force_new and tlen.* > 0 and arr[tlen.* - 1].kind == .lit) {
                    const prev = &arr[tlen.* - 1];
                    if (@as(usize, prev.lit_start) + prev.lit_len == p.lit_len) {
                        p.lit_buf[p.lit_len] = byte;
                        p.lit_len += 1;
                        prev.lit_len += 1;
                        return true;
                    }
                }
                if (tlen.* >= MAX_STRFTIME_OPS) {
                    err_out.* = "Time format template exceeds 32 tokens";
                    return false;
                }
                const lstart = p.lit_len;
                p.lit_buf[p.lit_len] = byte;
                p.lit_len += 1;
                arr[tlen.*] = .{
                    .kind = .lit,
                    .lit_start = lstart,
                    .lit_len = 1,
                };
                tlen.* += 1;
                return true;
            }
        }.call;

        const pushTok = struct {
            fn call(arr: *[MAX_STRFTIME_OPS]PicTok, tlen: *usize, tok: PicTok, err_out: *?[]const u8) bool {
                if (tlen.* >= MAX_STRFTIME_OPS) {
                    err_out.* = "Time format template exceeds 32 tokens";
                    return false;
                }
                arr[tlen.*] = tok;
                tlen.* += 1;
                return true;
            }
        }.call;

        var i: usize = 0;
        while (i < spec.len) {
            const ch = spec[i];
            if (ch == ' ' or ch == '\t') {
                while (i + 1 < spec.len and (spec[i + 1] == ' ' or spec[i + 1] == '\t')) : (i += 1) {}
                if (!pushTok(&toks, &tok_len, .{ .kind = .ws }, err_msg_out)) return null;
                i += 1;
                continue;
            }
            if (ch == '\'' or ch == '"') {
                const quote = ch;
                i += 1;
                var closed = false;
                while (i < spec.len) {
                    if (spec[i] == quote) {
                        if (i + 1 < spec.len and spec[i + 1] == quote) {
                            if (!appendTokLitByte(&prog, &toks, &tok_len, quote, false, err_msg_out)) return null;
                            i += 2;
                            continue;
                        }
                        closed = true;
                        i += 1;
                        break;
                    }
                    if (!appendTokLitByte(&prog, &toks, &tok_len, spec[i], false, err_msg_out)) return null;
                    i += 1;
                }
                if (!closed) {
                    err_msg_out.* = "Unterminated quoted literal in time format";
                    return null;
                }
                continue;
            }
            if (!std.ascii.isAlphabetic(ch)) {
                if (!appendTokLitByte(&prog, &toks, &tok_len, ch, false, err_msg_out)) return null;
                i += 1;
                continue;
            }

            // Contiguous ASCII alphabetic run
            var run_end = i;
            while (run_end < spec.len and std.ascii.isAlphabetic(spec[run_end])) : (run_end += 1) {}

            var w = i;
            while (w < run_end) {
                const rem = spec[w..run_end];
                // Check multi-letter keyword tokens when bounded as a whole sub-word
                if (rem.len >= 5 and eqLower(rem[0..5], "month")) {
                    if (!pushTok(&toks, &tok_len, .{ .kind = .month_name }, err_msg_out)) return null;
                    w += 5;
                    continue;
                }
                if (rem.len == 3 and eqLower(rem, "mon")) {
                    if (!pushTok(&toks, &tok_len, .{ .kind = .month_name }, err_msg_out)) return null;
                    w += 3;
                    continue;
                }
                if (rem.len == 3 and eqLower(rem, "min")) {
                    if (!pushTok(&toks, &tok_len, .{ .kind = .minute, .param = 2 }, err_msg_out)) return null;
                    w += 3;
                    continue;
                }
                if (rem.len == 2 and eqLower(rem, "mi")) {
                    if (!pushTok(&toks, &tok_len, .{ .kind = .minute, .param = 1 }, err_msg_out)) return null;
                    w += 2;
                    continue;
                }
                if (rem.len == 3 and eqLower(rem, "sec")) {
                    if (!pushTok(&toks, &tok_len, .{ .kind = .sec, .param = 2 }, err_msg_out)) return null;
                    w += 3;
                    continue;
                }
                if (rem.len == 2 and (eqLower(rem, "am") or eqLower(rem, "pm") or eqLower(rem, "tt"))) {
                    if (!pushTok(&toks, &tok_len, .{ .kind = .ampm }, err_msg_out)) return null;
                    w += 2;
                    continue;
                }
                if (rem.len == 2 and eqLower(rem, "ms")) {
                    if (!pushTok(&toks, &tok_len, .{ .kind = .frac_f, .param = 3 }, err_msg_out)) return null;
                    w += 2;
                    continue;
                }
                if (rem.len == 2 and eqLower(rem, "us")) {
                    if (!pushTok(&toks, &tok_len, .{ .kind = .frac_f, .param = 6 }, err_msg_out)) return null;
                    w += 2;
                    continue;
                }
                if (rem.len == 2 and eqLower(rem, "ns")) {
                    if (!pushTok(&toks, &tok_len, .{ .kind = .frac_f, .param = 9 }, err_msg_out)) return null;
                    w += 2;
                    continue;
                }

                // Split identical letter run (`yyyy`, `MM`, `dd`, `hm` -> `h` + `m`)
                const letter = spec[w];
                var k = w + 1;
                while (k < run_end and spec[k] == letter) : (k += 1) {}
                const klen: usize = k - w;

                switch (letter) {
                    'y', 'Y' => {
                        if (klen == 4) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .year4 }, err_msg_out)) return null;
                        } else if (klen == 2) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .year2 }, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported year token '{s}' (use yyyy or yy)", .{spec[w..k]}) catch "Unsupported year token";
                            return null;
                        }
                    },
                    'M' => {
                        if (klen <= 2) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .m_upper, .param = @intCast(klen) }, err_msg_out)) return null;
                        } else if (klen <= 4) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .month_name }, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported month token '{s}'", .{spec[w..k]}) catch "Unsupported month token";
                            return null;
                        }
                    },
                    'm' => {
                        if (klen <= 2) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .m_lower, .param = @intCast(klen) }, err_msg_out)) return null;
                        } else if (klen <= 4) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .month_name }, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported month/minute token '{s}'", .{spec[w..k]}) catch "Unsupported token";
                            return null;
                        }
                    },
                    'd', 'D' => {
                        if (klen <= 2) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .day, .param = @intCast(klen) }, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported day token '{s}' (use dd or d)", .{spec[w..k]}) catch "Unsupported day token";
                            return null;
                        }
                    },
                    'H' => {
                        if (klen <= 2) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .hour24, .param = @intCast(klen) }, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported hour token '{s}' (use HH or H)", .{spec[w..k]}) catch "Unsupported hour token";
                            return null;
                        }
                    },
                    'h' => {
                        if (klen <= 2) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .hour_ambig, .param = @intCast(klen) }, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported hour token '{s}' (use hh or h)", .{spec[w..k]}) catch "Unsupported hour token";
                            return null;
                        }
                    },
                    's' => {
                        if (klen <= 2) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .sec, .param = @intCast(klen) }, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported second token '{s}' (use ss or s)", .{spec[w..k]}) catch "Unsupported second token";
                            return null;
                        }
                    },
                    'S' => {
                        if (klen <= 9) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .s_upper, .param = @intCast(klen) }, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported fraction token '{s}'", .{spec[w..k]}) catch "Unsupported fraction token";
                            return null;
                        }
                    },
                    'f', 'F' => {
                        if (klen <= 9) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .frac_f, .param = @intCast(klen) }, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported fraction token '{s}'", .{spec[w..k]}) catch "Unsupported fraction token";
                            return null;
                        }
                    },
                    'z', 'Z', 'X' => {
                        if (klen <= 3) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .tz }, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported timezone token '{s}'", .{spec[w..k]}) catch "Unsupported tz token";
                            return null;
                        }
                    },
                    'a', 'A' => {
                        if (klen <= 2) {
                            if (!pushTok(&toks, &tok_len, .{ .kind = .ampm }, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported AM/PM token '{s}'", .{spec[w..k]}) catch "Unsupported ampm token";
                            return null;
                        }
                    },
                    'T' => {
                        if (klen == 1) {
                            if (!appendTokLitByte(&prog, &toks, &tok_len, 'T', true, err_msg_out)) return null;
                        } else {
                            err_msg_out.* = std.fmt.allocPrint(arena, "Unsupported token '{s}' in time format", .{spec[w..k]}) catch "Unsupported time token";
                            return null;
                        }
                    },
                    else => {
                        err_msg_out.* = std.fmt.allocPrint(
                            arena,
                            "Unsupported token '{s}' in time format. Examples: yyyy-MM-dd HH:mm:ss, yyyy/M/d H:m, yyyy-hm, %Y-%m-%d %H:%M:%S",
                            .{spec[w..k]},
                        ) catch "Unsupported token in time format";
                        return null;
                    },
                }
                w = k;
            }
            i = run_end;
        }

        if (tok_len == 0) {
            err_msg_out.* = "Time format template cannot be empty";
            return null;
        }

        // Context scan for disambiguating M/m/h/S
        var has_ampm = false;
        var has_upper_m = false;
        for (toks[0..tok_len]) |tk| {
            if (tk.kind == .ampm) has_ampm = true;
            if (tk.kind == .m_upper) has_upper_m = true;
        }

        const prevNonWs = struct {
            fn call(arr: []const PicTok, idx: usize) ?PicTok {
                var j = idx;
                while (j > 0) {
                    j -= 1;
                    if (arr[j].kind != .ws) return arr[j];
                }
                return null;
            }
        }.call;

        const prevSig = struct {
            fn call(arr: []const PicTok, idx: usize) ?PicTok {
                var j = idx;
                while (j > 0) {
                    j -= 1;
                    if (arr[j].kind != .ws and arr[j].kind != .lit) return arr[j];
                }
                return null;
            }
        }.call;

        const nextSig = struct {
            fn call(arr: []const PicTok, idx: usize) ?PicTok {
                var j = idx + 1;
                while (j < arr.len) : (j += 1) {
                    if (arr[j].kind != .ws and arr[j].kind != .lit) return arr[j];
                }
                return null;
            }
        }.call;

        const isPrevLitSuffix = struct {
            fn call(p: *const StrftimeProg, arr: []const PicTok, idx: usize, suffix: u8) bool {
                var j = idx;
                while (j > 0) {
                    j -= 1;
                    if (arr[j].kind == .ws) continue;
                    if (arr[j].kind != .lit or arr[j].lit_len == 0) return false;
                    return p.lit_buf[arr[j].lit_start + arr[j].lit_len - 1] == suffix;
                }
                return false;
            }
        }.call;

        const slice_toks = toks[0..tok_len];
        var directive_count: usize = 0;
        var seen_month = false;
        var seen_hour = false;

        for (slice_toks, 0..) |tk, idx| {
            var op: TimeOp = undefined;
            switch (tk.kind) {
                .lit => op = .{ .tag = .lit, .lit_start = tk.lit_start, .lit_len = tk.lit_len },
                .ws => op = .{ .tag = .ws },
                .year4 => {
                    directive_count += 1;
                    op = .{ .tag = .year4 };
                },
                .year2 => {
                    directive_count += 1;
                    op = .{ .tag = .year2 };
                },
                .month_name => {
                    directive_count += 1;
                    seen_month = true;
                    op = .{ .tag = .month_name };
                },
                .month_num => {
                    directive_count += 1;
                    seen_month = true;
                    op = .{ .tag = .month2, .param = tk.param };
                },
                .day => {
                    directive_count += 1;
                    op = .{ .tag = .day2, .param = tk.param };
                },
                .hour24 => {
                    directive_count += 1;
                    seen_hour = true;
                    op = .{ .tag = .hour2, .param = tk.param };
                },
                .hour_ambig => {
                    directive_count += 1;
                    seen_hour = true;
                    op = .{ .tag = if (has_ampm) .hour12 else .hour2, .param = tk.param };
                },
                .minute => {
                    directive_count += 1;
                    op = .{ .tag = .min2, .param = tk.param };
                },
                .m_upper => {
                    directive_count += 1;
                    const ps = prevSig(slice_toks, idx);
                    const ns = nextSig(slice_toks, idx);
                    const is_hour_prev = ps != null and (ps.?.kind == .hour24 or ps.?.kind == .hour_ambig);
                    const is_sec_next = ns != null and (ns.?.kind == .sec or ns.?.kind == .s_upper);
                    if (seen_month and (isPrevLitSuffix(&prog, slice_toks, idx, ':') or is_hour_prev or is_sec_next)) {
                        op = .{ .tag = .min2, .param = tk.param };
                    } else {
                        seen_month = true;
                        op = .{ .tag = .month2, .param = tk.param };
                    }
                },
                .m_lower => {
                    directive_count += 1;
                    const ps = prevSig(slice_toks, idx);
                    const ns = nextSig(slice_toks, idx);
                    const is_hour_prev = ps != null and (ps.?.kind == .hour24 or ps.?.kind == .hour_ambig);
                    const is_sec_next = ns != null and (ns.?.kind == .sec or ns.?.kind == .s_upper);
                    const is_date_ctx = (ps != null and (ps.?.kind == .year4 or ps.?.kind == .year2 or ps.?.kind == .day)) or
                        (ns != null and ns.?.kind == .day);
                    if (isPrevLitSuffix(&prog, slice_toks, idx, ':') or is_hour_prev or is_sec_next or has_upper_m) {
                        op = .{ .tag = .min2, .param = tk.param };
                    } else if (is_date_ctx) {
                        seen_month = true;
                        op = .{ .tag = .month2, .param = tk.param };
                    } else if (seen_hour) {
                        op = .{ .tag = .min2, .param = tk.param };
                    } else {
                        seen_month = true;
                        op = .{ .tag = .month2, .param = tk.param };
                    }
                },
                .sec => {
                    directive_count += 1;
                    op = .{ .tag = .sec2, .param = tk.param };
                },
                .s_upper => {
                    directive_count += 1;
                    if (tk.param == 2 and isPrevLitSuffix(&prog, slice_toks, idx, ':')) {
                        op = .{ .tag = .sec2, .param = 2 };
                    } else {
                        const prev = prevNonWs(slice_toks, idx);
                        const after_dot = prev != null and prev.?.kind == .lit;
                        op = .{ .tag = .frac, .param = if (after_dot) 0 else tk.param };
                    }
                },
                .frac_f => {
                    directive_count += 1;
                    const prev = prevNonWs(slice_toks, idx);
                    const after_dot = prev != null and prev.?.kind == .lit;
                    op = .{ .tag = .frac, .param = if (after_dot) 0 else tk.param };
                },
                .tz => {
                    directive_count += 1;
                    op = .{ .tag = .tz };
                },
                .ampm => {
                    directive_count += 1;
                    op = .{ .tag = .ampm };
                },
                .epoch_s => {
                    directive_count += 1;
                    op = .{ .tag = .epoch_s };
                },
                .epoch_ms => {
                    directive_count += 1;
                    op = .{ .tag = .epoch_ms };
                },
                .epoch_us => {
                    directive_count += 1;
                    op = .{ .tag = .epoch_us };
                },
                .epoch_ns => {
                    directive_count += 1;
                    op = .{ .tag = .epoch_ns };
                },
            }
            if (prog.op_len >= MAX_STRFTIME_OPS) return tooMany(err_msg_out);
            prog.ops[prog.op_len] = op;
            prog.op_len += 1;
        }

        if (directive_count == 0) {
            err_msg_out.* = "Time format must contain date or time specifiers (e.g. yyyy-MM-dd HH:mm:ss or yyyy-hm)";
            return null;
        }
        return prog;
    }

    fn tooMany(err_msg_out: *?[]const u8) ?StrftimeProg {
        err_msg_out.* = "Time format template exceeds 32 tokens";
        return null;
    }

    inline fn nextIsDigitOp(self: *const StrftimeProg, op_idx: usize) bool {
        if (op_idx + 1 >= self.op_len) return false;
        return switch (self.ops[op_idx + 1].tag) {
            .year4, .year2, .month2, .day2, .day_space, .hour2, .hour12, .min2, .sec2, .frac, .epoch_s, .epoch_ms, .epoch_us, .epoch_ns => true,
            else => false,
        };
    }

    pub fn parseAt(
        self: *const StrftimeProg,
        haystack: []const u8,
        start_pos: usize,
        ctx: FallbackTimeContext,
    ) ?u64 {
        var pos = start_pos;
        var year: u16 = ctx.year;
        var month: u8 = ctx.month;
        var day: u8 = ctx.day;
        var hour: u8 = 0;
        var minute: u8 = 0;
        var second: u8 = 0;
        var frac_ns: u64 = 0;
        var explicit_tz: ?i64 = null;
        var epoch_sec_val: ?u64 = null;
        var epoch_ms_val: ?u64 = null;
        var epoch_us_val: ?u64 = null;
        var epoch_ns_val: ?u64 = null;

        var has_year = false;
        var has_month = false;
        var has_day = false;
        var has_time = false;
        var has_ampm = false;
        var ampm_is_pm = false;
        var hour_is_12 = false;

        for (self.ops[0..self.op_len], 0..) |op, idx| {
            switch (op.tag) {
                .lit => {
                    const lit = self.lit_buf[op.lit_start .. op.lit_start + op.lit_len];
                    if (pos + lit.len > haystack.len) return null;
                    if (!std.mem.eql(u8, haystack[pos .. pos + lit.len], lit)) return null;
                    pos += lit.len;
                },
                .ws => {
                    if (pos >= haystack.len or (haystack[pos] != ' ' and haystack[pos] != '\t')) return null;
                    pos += 1;
                    while (pos < haystack.len and (haystack[pos] == ' ' or haystack[pos] == '\t')) : (pos += 1) {}
                },
                .year4 => {
                    const y = parse4Digits(haystack[pos..]) orelse return null;
                    if (y < 1970 or y > 2261) return null;
                    year = y;
                    has_year = true;
                    pos += 4;
                },
                .year2 => {
                    const y2 = parse2Digits(haystack[pos..]) orelse return null;
                    year = if (y2 >= 70) 1900 + @as(u16, y2) else 2000 + @as(u16, y2);
                    has_year = true;
                    pos += 2;
                },
                .month2 => {
                    if (pos >= haystack.len or !std.ascii.isDigit(haystack[pos])) return null;
                    if (pos + 1 < haystack.len and std.ascii.isDigit(haystack[pos + 1])) {
                        month = parse2Digits(haystack[pos..]) orelse return null;
                        pos += 2;
                    } else if (!self.nextIsDigitOp(idx)) {
                        month = haystack[pos] - '0';
                        pos += 1;
                    } else {
                        return null;
                    }
                    if (month < 1 or month > 12) return null;
                    has_month = true;
                },
                .month_name => {
                    const m_res = parseMonthNamePrefix(haystack[pos..]) orelse return null;
                    month = m_res.month;
                    has_month = true;
                    pos += m_res.len;
                },
                .day2 => {
                    if (pos >= haystack.len or !std.ascii.isDigit(haystack[pos])) return null;
                    if (pos + 1 < haystack.len and std.ascii.isDigit(haystack[pos + 1])) {
                        day = parse2Digits(haystack[pos..]) orelse return null;
                        pos += 2;
                    } else if (!self.nextIsDigitOp(idx)) {
                        day = haystack[pos] - '0';
                        pos += 1;
                    } else {
                        return null;
                    }
                    if (day < 1 or day > 31) return null;
                    has_day = true;
                },
                .day_space => {
                    if (pos >= haystack.len) return null;
                    if (haystack[pos] == ' ') {
                        pos += 1;
                        if (pos >= haystack.len or !std.ascii.isDigit(haystack[pos])) return null;
                        day = haystack[pos] - '0';
                        pos += 1;
                    } else if (std.ascii.isDigit(haystack[pos])) {
                        if (pos + 1 < haystack.len and std.ascii.isDigit(haystack[pos + 1])) {
                            day = parse2Digits(haystack[pos..]) orelse return null;
                            pos += 2;
                        } else {
                            day = haystack[pos] - '0';
                            pos += 1;
                        }
                    } else {
                        return null;
                    }
                    if (day < 1 or day > 31) return null;
                    has_day = true;
                },
                .hour2, .hour12 => {
                    if (pos >= haystack.len or !std.ascii.isDigit(haystack[pos])) return null;
                    // Adjacent hour + minute without separator (e.g. `yyyy-hm` or `HHmm`): smart 2+2 / 1+2 / 1+1 split
                    if (idx + 1 < self.op_len and self.ops[idx + 1].tag == .min2) {
                        var dlen: usize = 0;
                        while (pos + dlen < haystack.len and dlen < 5 and std.ascii.isDigit(haystack[pos + dlen])) : (dlen += 1) {}
                        if (dlen >= 4) {
                            hour = parse2Digits(haystack[pos..]) orelse return null;
                            pos += 2;
                        } else if (dlen == 3 and op.param == 1) {
                            hour = haystack[pos] - '0';
                            pos += 1;
                        } else if (dlen == 2 and op.param == 1 and self.ops[idx + 1].param == 1) {
                            hour = haystack[pos] - '0';
                            pos += 1;
                        } else {
                            return null;
                        }
                    } else if (pos + 1 < haystack.len and std.ascii.isDigit(haystack[pos + 1])) {
                        hour = parse2Digits(haystack[pos..]) orelse return null;
                        pos += 2;
                    } else if (!self.nextIsDigitOp(idx)) {
                        hour = haystack[pos] - '0';
                        pos += 1;
                    } else {
                        return null;
                    }
                    if (hour > 23) return null;
                    if (op.tag == .hour12) hour_is_12 = true;
                    has_time = true;
                },
                .min2 => {
                    if (pos >= haystack.len or !std.ascii.isDigit(haystack[pos])) return null;
                    if (pos + 1 < haystack.len and std.ascii.isDigit(haystack[pos + 1])) {
                        minute = parse2Digits(haystack[pos..]) orelse return null;
                        pos += 2;
                    } else if (!self.nextIsDigitOp(idx)) {
                        minute = haystack[pos] - '0';
                        pos += 1;
                    } else {
                        return null;
                    }
                    if (minute > 59) return null;
                    has_time = true;
                },
                .sec2 => {
                    if (pos >= haystack.len or !std.ascii.isDigit(haystack[pos])) return null;
                    if (pos + 1 < haystack.len and std.ascii.isDigit(haystack[pos + 1])) {
                        second = parse2Digits(haystack[pos..]) orelse return null;
                        pos += 2;
                    } else if (!self.nextIsDigitOp(idx)) {
                        second = haystack[pos] - '0';
                        pos += 1;
                    } else {
                        return null;
                    }
                    if (second > 60) return null;
                    has_time = true;
                    // When `.sec2` is the final template token (e.g. `yyyy-MM-dd HH:mm:ss`),
                    // opportunistically honor optional `.frac` and explicit `Z`/`±HH:MM` on the line.
                    if (idx + 1 == self.op_len and pos < haystack.len and !std.ascii.isDigit(haystack[pos])) {
                        const tail = parseOptionalFracAmPmTz(haystack[pos..], hour);
                        if (tail.hour_valid) {
                            hour = tail.hour;
                            frac_ns = tail.frac_ns;
                            if (tail.explicit_tz) |etz| explicit_tz = etz;
                            pos += tail.consumed;
                        }
                    }
                },
                .frac => {
                    if (op.param == 1) {
                        if (pos < haystack.len and (haystack[pos] == '.' or haystack[pos] == ',')) {
                            pos += 1;
                        }
                    }
                    const f = parseFractionDigitsNs(haystack[pos..]);
                    if (f.len == 0) {
                        if (op.param != 1) return null;
                    } else if (op.param == 3 or op.param == 6 or op.param == 9) {
                        if (f.len < op.param) return null;
                        const sub = parseFractionDigitsNs(haystack[pos .. pos + op.param]);
                        frac_ns = sub.frac_ns;
                        pos += op.param;
                    } else {
                        frac_ns = f.frac_ns;
                        pos += f.len;
                    }
                },
                .tz => {
                    if (pos >= haystack.len) return null;
                    if (parseExplicitTz(haystack[pos..])) |tz| {
                        explicit_tz = tz.offset_sec;
                        pos += tz.len;
                    } else {
                        return null;
                    }
                },
                .ampm => {
                    const ap = parseAmPm(haystack[pos..]) orelse return null;
                    has_ampm = true;
                    ampm_is_pm = ap.is_pm;
                    pos += ap.len;
                },
                .epoch_s => {
                    var end_p = pos;
                    while (end_p < haystack.len and std.ascii.isDigit(haystack[end_p]) and (end_p - pos) < 12) : (end_p += 1) {}
                    const dlen = end_p - pos;
                    if (dlen < 9 or dlen > 11) return null;
                    epoch_sec_val = std.fmt.parseInt(u64, haystack[pos..end_p], 10) catch return null;
                    pos = end_p;
                },
                .epoch_ms => {
                    var end_p = pos;
                    while (end_p < haystack.len and std.ascii.isDigit(haystack[end_p]) and (end_p - pos) < 16) : (end_p += 1) {}
                    const dlen = end_p - pos;
                    if (dlen < 12 or dlen > 15) return null;
                    epoch_ms_val = std.fmt.parseInt(u64, haystack[pos..end_p], 10) catch return null;
                    pos = end_p;
                },
                .epoch_us => {
                    var end_p = pos;
                    while (end_p < haystack.len and std.ascii.isDigit(haystack[end_p]) and (end_p - pos) < 18) : (end_p += 1) {}
                    const dlen = end_p - pos;
                    if (dlen < 15 or dlen > 17) return null;
                    epoch_us_val = std.fmt.parseInt(u64, haystack[pos..end_p], 10) catch return null;
                    pos = end_p;
                },
                .epoch_ns => {
                    var end_p = pos;
                    while (end_p < haystack.len and std.ascii.isDigit(haystack[end_p]) and (end_p - pos) < 21) : (end_p += 1) {}
                    const dlen = end_p - pos;
                    if (dlen < 18 or dlen > 20) return null;
                    epoch_ns_val = std.fmt.parseInt(u64, haystack[pos..end_p], 10) catch return null;
                    pos = end_p;
                },
            }
        }

        if (epoch_ns_val) |ns| return ns;
        if (epoch_us_val) |us| return us *| 1_000;
        if (epoch_ms_val) |ms| return ms *| 1_000_000 +| frac_ns;
        if (epoch_sec_val) |sec| return sec *| std.time.ns_per_s +| frac_ns;
        if (!has_year and !has_month and !has_day and !has_time) return null;

        if (has_ampm or hour_is_12) {
            hour = apply12Hour(hour, ampm_is_pm) orelse return null;
        }
        if (!has_month and !has_day) {
            if (has_time) {
                month = if (ctx.month >= 1 and ctx.month <= 12) ctx.month else 1;
                day = @min(if (ctx.day >= 1) ctx.day else 1, daysInMonth(year, month));
            } else {
                month = 1;
                day = 1;
            }
        } else if (has_month and !has_day) {
            day = 1;
        } else if (!has_month and has_day) {
            month = if (ctx.month >= 1 and ctx.month <= 12) ctx.month else 1;
        }

        const civil_sec = civilToEpochSeconds(year, month, day, hour, minute, second) orelse return null;
        return finalizeCivilToNs(civil_sec, frac_ns, explicit_tz, ctx);
    }

    pub fn parseLine(self: *const StrftimeProg, raw_line: []const u8, ctx: FallbackTimeContext) ?u64 {
        const line = sliceAtLineEnd(raw_line);
        if (line.len == 0) return null;

        if (self.anchored) {
            return self.parseAt(line, 0, ctx);
        }

        const win = line[0..@min(line.len, 128)];
        const first_op = self.ops[0];
        switch (first_op.tag) {
            .lit => {
                const lit = self.lit_buf[first_op.lit_start .. first_op.lit_start + first_op.lit_len];
                if (lit.len > 0) {
                    var pos: usize = 0;
                    while (std.mem.indexOfPos(u8, win, pos, lit)) |hit_pos| {
                        if (self.parseAt(line, hit_pos, ctx)) |ns| return ns;
                        pos = hit_pos + 1;
                    }
                    return null;
                }
            },
            .year4 => {
                var pos: usize = 0;
                while (pos + 4 <= win.len) : (pos += 1) {
                    const c = win[pos];
                    if (c != '1' and c != '2') continue;
                    if (pos > 0 and std.ascii.isDigit(win[pos - 1])) continue;
                    if (self.parseAt(line, pos, ctx)) |ns| return ns;
                }
                return null;
            },
            .year2, .month2, .day2, .hour2, .hour12, .min2, .sec2, .epoch_s, .epoch_ms, .epoch_us, .epoch_ns => {
                var pos: usize = 0;
                while (pos < win.len) : (pos += 1) {
                    if (!std.ascii.isDigit(win[pos])) continue;
                    if (pos > 0 and std.ascii.isDigit(win[pos - 1])) continue;
                    if (self.parseAt(line, pos, ctx)) |ns| return ns;
                }
                return null;
            },
            .month_name => {
                var pos: usize = 0;
                while (pos < win.len) : (pos += 1) {
                    if (!std.ascii.isAlphabetic(win[pos])) continue;
                    if (pos > 0 and std.ascii.isAlphabetic(win[pos - 1])) continue;
                    if (self.parseAt(line, pos, ctx)) |ns| return ns;
                }
                return null;
            },
            else => {},
        }

        var pos: usize = 0;
        while (pos < win.len) : (pos += 1) {
            if (self.parseAt(line, pos, ctx)) |ns| return ns;
        }
        return null;
    }
};

// ============================================================================
// Tier 3: Zero-DOM `json:<field>[|<strftime>]` via SIMD `libwebgrep.Finder`
// ============================================================================

pub const MAX_JSON_PATH_DEPTH: usize = 4;

pub const JsonFieldProg = struct {
    seg_count: u8 = 0,
    needle_bufs: [MAX_JSON_PATH_DEPTH][72]u8 = undefined,
    needle_lens: [MAX_JSON_PATH_DEPTH]u8 = @splat(0),
    finders: [MAX_JSON_PATH_DEPTH]libwebgrep.Finder = undefined,
    sub_strftime: ?StrftimeProg = null,

    pub fn initInPlace(
        self: *JsonFieldProg,
        arena: std.mem.Allocator,
        spec_after_prefix: []const u8,
        err_msg_out: *?[]const u8,
    ) !void {
        const clean = std.mem.trim(u8, spec_after_prefix, " \t\r\n");
        var field_part = clean;
        var sub_part: []const u8 = "";
        if (std.mem.indexOfScalar(u8, clean, '|')) |bar| {
            field_part = std.mem.trim(u8, clean[0..bar], " \t");
            sub_part = std.mem.trim(u8, clean[bar + 1 ..], " \t");
        }
        if (field_part.len == 0) {
            err_msg_out.* = "JSON format requires a field name (e.g. json:timestamp or json:meta.ts|%Y-%m-%d %H:%M:%S)";
            return error.InvalidTimeFormat;
        }

        var sub_prog: ?StrftimeProg = null;
        if (sub_part.len > 0 and !std.ascii.eqlIgnoreCase(sub_part, "auto")) {
            sub_prog = StrftimeProg.compile(arena, sub_part, err_msg_out) orelse return error.InvalidTimeFormat;
        }

        self.seg_count = 0;
        self.sub_strftime = sub_prog;

        var it = std.mem.splitScalar(u8, field_part, '.');
        while (it.next()) |raw_seg| {
            const seg = std.mem.trim(u8, raw_seg, " \t\"'");
            if (seg.len == 0) {
                err_msg_out.* = "JSON field path cannot contain empty segments";
                return error.InvalidTimeFormat;
            }
            if (self.seg_count >= MAX_JSON_PATH_DEPTH) {
                err_msg_out.* = "JSON field path depth exceeds limit of 4";
                return error.InvalidTimeFormat;
            }
            if (seg.len + 2 > 72) {
                err_msg_out.* = "JSON field segment name exceeds 70 bytes";
                return error.InvalidTimeFormat;
            }
            const idx = self.seg_count;
            self.needle_bufs[idx][0] = '"';
            @memcpy(self.needle_bufs[idx][1 .. 1 + seg.len], seg);
            self.needle_bufs[idx][1 + seg.len] = '"';
            const nlen: u8 = @intCast(seg.len + 2);
            self.needle_lens[idx] = nlen;
            const needle_slice = self.needle_bufs[idx][0..nlen];
            self.finders[idx] = libwebgrep.Finder.init(needle_slice, .{
                .case = .sensitive,
                .max_pattern_count = 4096,
                .max_pattern_bytes = 1024 * 1024,
                .max_unicode_variants = 64,
            }) catch {
                err_msg_out.* = "Failed to initialize JSON field matcher";
                return error.InvalidTimeFormat;
            };
            self.seg_count += 1;
        }
        if (self.seg_count == 0) {
            err_msg_out.* = "JSON format requires at least one field segment";
            return error.InvalidTimeFormat;
        }
    }

    pub fn parseLine(
        self: *const JsonFieldProg,
        raw_line: []const u8,
        ctx: FallbackTimeContext,
        cache: ?*PrefixEpochCache,
    ) ?u64 {
        const line = sliceAtLineEnd(raw_line);
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len < 5) return null;

        const win = trimmed[0..@min(trimmed.len, 1024)];
        var search_start: usize = 0;

        for (0..self.seg_count) |seg_i| {
            var pos = search_start;
            var found_val_start: ?usize = null;
            while (pos < win.len) {
                const hit = self.finders[seg_i].find(win, pos, .leftmost_first) orelse return null;
                var after = hit.end;
                while (after < win.len and (win[after] == ' ' or win[after] == '\t')) : (after += 1) {}
                if (after < win.len and win[after] == ':') {
                    after += 1;
                    while (after < win.len and (win[after] == ' ' or win[after] == '\t')) : (after += 1) {}
                    if (after < win.len) {
                        found_val_start = after;
                        break;
                    }
                }
                pos = hit.end;
            }
            const val_pos = found_val_start orelse return null;
            if (seg_i + 1 < self.seg_count) {
                if (win[val_pos] != '{') return null;
                search_start = val_pos + 1;
            } else {
                var val_slice: []const u8 = "";
                if (win[val_pos] == '"') {
                    const s_start = val_pos + 1;
                    const s_end = std.mem.indexOfScalarPos(u8, win, s_start, '"') orelse return null;
                    val_slice = win[s_start..s_end];
                } else {
                    var s_end = val_pos;
                    while (s_end < win.len and (std.ascii.isDigit(win[s_end]) or win[s_end] == '.' or win[s_end] == '+' or win[s_end] == '-')) : (s_end += 1) {}
                    if (s_end <= val_pos) return null;
                    val_slice = win[val_pos..s_end];
                }

                if (self.sub_strftime) |*sf| {
                    if (sf.anchored) {
                        return sf.parseAt(val_slice, 0, ctx);
                    }
                    return sf.parseLine(val_slice, ctx);
                }
                return parseTimestampValueNs(val_slice, ctx, cache);
            }
        }
        return null;
    }
};

// ============================================================================
// Tier 4: Named-Capture `regex:<pattern>` Powered by `libwebgrep.Regex`
// ============================================================================

pub const RegexCaptureProg = struct {
    re: libwebgrep.Regex,
    idx_ts: ?usize = null,
    idx_Y: ?usize = null,
    idx_y: ?usize = null,
    idx_m: ?usize = null,
    idx_b: ?usize = null,
    idx_d: ?usize = null,
    idx_H: ?usize = null,
    idx_M: ?usize = null,
    idx_S: ?usize = null,
    idx_f: ?usize = null,
    idx_z: ?usize = null,
    idx_s: ?usize = null,
    idx_Q: ?usize = null,
    use_components: bool = false,
    sub_strftime: ?StrftimeProg = null,

    const NamedGroupMap = struct {
        rewritten: []const u8,
        names: [9][]const u8 = @splat(""),
        count: u8 = 0,

        fn indexByName(self: *const NamedGroupMap, name: []const u8) ?usize {
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                if (self.names[i].len > 0 and std.mem.eql(u8, self.names[i], name)) {
                    return i + 1;
                }
            }
            return null;
        }
    };

    /// `libwebgrep.Regex` parses standard positional groups `(...)` and `(?:...)` rather than Python
    /// `(?P<name>...)` / `(?<name>...)` syntax. Extract named capture mapping and rewrite to `(...)`.
    fn findTopLevelDoublePipe(s: []const u8) ?usize {
        var depth: usize = 0;
        var in_class = false;
        var i: usize = 0;
        while (i + 1 < s.len) {
            const c = s[i];
            if (c == '\\') {
                i += 2;
                continue;
            }
            if (in_class) {
                if (c == ']') in_class = false;
                i += 1;
                continue;
            }
            if (c == '[') {
                in_class = true;
            } else if (c == '(') {
                depth += 1;
            } else if (c == ')') {
                if (depth > 0) depth -= 1;
            } else if (depth == 0 and c == '|' and s[i + 1] == '|') {
                return i;
            }
            i += 1;
        }
        return null;
    }

    fn extractNamedGroupsAndRewrite(arena: std.mem.Allocator, raw: []const u8) !NamedGroupMap {
        var map = NamedGroupMap{ .rewritten = raw };
        var out: std.ArrayList(u8) = .empty;
        var has_rewrite = false;

        var i: usize = 0;
        var in_class = false;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\\') {
                if (has_rewrite) {
                    try out.append(arena, c);
                    if (i + 1 < raw.len) try out.append(arena, raw[i + 1]);
                }
                i += @min(2, raw.len - i);
                continue;
            }
            if (in_class) {
                if (c == ']') in_class = false;
                if (has_rewrite) try out.append(arena, c);
                i += 1;
                continue;
            }
            if (c == '[') {
                in_class = true;
                if (has_rewrite) try out.append(arena, c);
                i += 1;
                continue;
            }
            if (c == '(') {
                if (i + 1 < raw.len and raw[i + 1] == '?') {
                    const name_start_rel: ?usize = if (i + 3 < raw.len and raw[i + 2] == 'P' and raw[i + 3] == '<')
                        4
                    else if (i + 2 < raw.len and raw[i + 2] == '<' and
                        !(i + 3 < raw.len and (raw[i + 3] == '=' or raw[i + 3] == '!')))
                        3
                    else
                        null;

                    if (name_start_rel) |rel| {
                        const nstart = i + rel;
                        if (std.mem.indexOfScalarPos(u8, raw, nstart, '>')) |gt_pos| {
                            if (gt_pos > nstart) {
                                if (!has_rewrite) {
                                    has_rewrite = true;
                                    try out.appendSlice(arena, raw[0..i]);
                                }
                                try out.append(arena, '(');
                                if (map.count < 9) {
                                    map.names[map.count] = raw[nstart..gt_pos];
                                    map.count += 1;
                                }
                                i = gt_pos + 1;
                                continue;
                            }
                        }
                    }
                    if (has_rewrite) try out.appendSlice(arena, raw[i .. i + 2]);
                    i += 2;
                    continue;
                }
                if (map.count < 9) {
                    map.count += 1;
                }
                if (has_rewrite) try out.append(arena, c);
                i += 1;
                continue;
            }
            if (has_rewrite) try out.append(arena, c);
            i += 1;
        }
        if (has_rewrite) {
            map.rewritten = out.items;
        }
        return map;
    }

    pub fn init(
        gpa: std.mem.Allocator,
        diag_arena: std.mem.Allocator,
        spec_after_prefix: []const u8,
        err_msg_out: *?[]const u8,
    ) !RegexCaptureProg {
        const clean = std.mem.trim(u8, spec_after_prefix, " \t\r\n");
        if (clean.len == 0) {
            err_msg_out.* = "Regex time format cannot be empty (e.g. regex:(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}))";
            return error.InvalidTimeFormat;
        }

        var pattern_part = clean;
        var sub_prog: ?StrftimeProg = null;
        if (findTopLevelDoublePipe(clean)) |sep_idx| {
            const rhs = std.mem.trim(u8, clean[sep_idx + 2 ..], " \t");
            if (rhs.len > 0) {
                pattern_part = std.mem.trim(u8, clean[0..sep_idx], " \t");
                if (!std.ascii.eqlIgnoreCase(rhs, "auto")) {
                    sub_prog = StrftimeProg.compile(diag_arena, rhs, err_msg_out) orelse return error.InvalidTimeFormat;
                }
            }
        }
        if (pattern_part.len == 0) {
            err_msg_out.* = "Regex pattern before '||' cannot be empty";
            return error.InvalidTimeFormat;
        }

        const group_map = extractNamedGroupsAndRewrite(diag_arena, pattern_part) catch NamedGroupMap{
            .rewritten = pattern_part,
        };

        var diag: libwebgrep.CompileDiagnostic = .{};
        var re = libwebgrep.Regex.initDiagnostic(gpa, group_map.rewritten, .{
            .case = .sensitive,
            .max_inst = 32768,
            .max_repeat = 2000,
            .max_recursion_depth = 128,
            .max_pattern_count = 4096,
            .max_pattern_bytes = 1024 * 1024,
            .max_unicode_variants = 64,
            .aot_dfa_max_insts = 256,
        }, &diag) catch |err| {
            if (diag.code != .none) {
                err_msg_out.* = std.fmt.allocPrint(
                    diag_arena,
                    "Regex time format error ({s}) at col {d}: {s}",
                    .{ @tagName(diag.code), diag.column, diag.message },
                ) catch diag.message;
            } else {
                err_msg_out.* = std.fmt.allocPrint(
                    diag_arena,
                    "Regex time format error ({s})",
                    .{@errorName(err)},
                ) catch "Invalid regex time format";
            }
            return error.InvalidTimeFormat;
        };

        var prog = RegexCaptureProg{
            .re = re,
            .sub_strftime = sub_prog,
        };
        prog.idx_ts = group_map.indexByName("ts") orelse group_map.indexByName("time") orelse group_map.indexByName("timestamp") orelse re.groupIndexByName("ts") orelse re.groupIndexByName("time") orelse re.groupIndexByName("timestamp");
        prog.idx_Y = group_map.indexByName("Y") orelse group_map.indexByName("year") orelse re.groupIndexByName("Y") orelse re.groupIndexByName("year");
        prog.idx_y = group_map.indexByName("y") orelse re.groupIndexByName("y");
        prog.idx_m = group_map.indexByName("m") orelse group_map.indexByName("month") orelse re.groupIndexByName("m") orelse re.groupIndexByName("month");
        prog.idx_b = group_map.indexByName("b") orelse group_map.indexByName("mon") orelse re.groupIndexByName("b") orelse re.groupIndexByName("mon");
        prog.idx_d = group_map.indexByName("d") orelse group_map.indexByName("day") orelse re.groupIndexByName("d") orelse re.groupIndexByName("day");
        prog.idx_H = group_map.indexByName("H") orelse group_map.indexByName("hour") orelse re.groupIndexByName("H") orelse re.groupIndexByName("hour");
        prog.idx_M = group_map.indexByName("M") orelse group_map.indexByName("min") orelse group_map.indexByName("minute") orelse re.groupIndexByName("M") orelse re.groupIndexByName("min") orelse re.groupIndexByName("minute");
        prog.idx_S = group_map.indexByName("S") orelse group_map.indexByName("sec") orelse group_map.indexByName("second") orelse re.groupIndexByName("S") orelse re.groupIndexByName("sec") orelse re.groupIndexByName("second");
        prog.idx_f = group_map.indexByName("f") orelse group_map.indexByName("frac") orelse group_map.indexByName("ms") orelse re.groupIndexByName("f") orelse re.groupIndexByName("frac") orelse re.groupIndexByName("ms");
        prog.idx_z = group_map.indexByName("z") orelse group_map.indexByName("tz") orelse re.groupIndexByName("z") orelse re.groupIndexByName("tz");
        prog.idx_s = group_map.indexByName("s") orelse re.groupIndexByName("s");
        prog.idx_Q = group_map.indexByName("Q") orelse re.groupIndexByName("Q");

        prog.use_components = prog.idx_Y != null or prog.idx_y != null or prog.idx_m != null or
            prog.idx_b != null or prog.idx_d != null or prog.idx_H != null or
            prog.idx_M != null or prog.idx_S != null or prog.idx_s != null or prog.idx_Q != null;

        if (!prog.use_components and prog.idx_ts == null) {
            if (re.num_captures >= 1) {
                prog.idx_ts = 1;
            } else {
                prog.idx_ts = 0; // full match
            }
        }
        return prog;
    }

    pub fn deinit(self: *RegexCaptureProg) void {
        self.re.deinit();
    }

    inline fn capSlice(caps: libwebgrep.Captures, win: []const u8, idx_opt: ?usize) ?[]const u8 {
        const idx = idx_opt orelse return null;
        if (idx > 9) return null;
        const m = caps.group(idx) orelse return null;
        if (m.start > m.end or m.end > win.len) return null;
        return win[m.start..m.end];
    }

    pub fn parseLine(
        self: *const RegexCaptureProg,
        raw_line: []const u8,
        ctx: FallbackTimeContext,
        scratch: ?*libwebgrep.RegexScratch,
        cache: ?*PrefixEpochCache,
    ) ?u64 {
        const line = sliceAtLineEnd(raw_line);
        if (line.len == 0) return null;
        const win = line[0..@min(line.len, 256)];

        const caps = if (scratch) |sc|
            self.re.findCapturesWithScratch(win, 0, .leftmost_first, sc)
        else
            self.re.findCaptures(win, 0, .leftmost_first);

        const c = caps orelse return null;

        if (self.use_components) {
            var frac_ns: u64 = 0;
            if (capSlice(c, win, self.idx_f)) |fs| {
                const trimmed_f = std.mem.trimStart(u8, fs, ".,");
                frac_ns = parseFractionDigitsNs(trimmed_f).frac_ns;
            }
            if (capSlice(c, win, self.idx_Q)) |qs| {
                const ms = std.fmt.parseInt(u64, std.mem.trim(u8, qs, " \t"), 10) catch return null;
                return ms *| 1_000_000 +| frac_ns;
            }
            if (capSlice(c, win, self.idx_s)) |ss| {
                const sec = std.fmt.parseInt(u64, std.mem.trim(u8, ss, " \t"), 10) catch return null;
                return sec *| std.time.ns_per_s +| frac_ns;
            }

            var year: u16 = ctx.year;
            var month: u8 = ctx.month;
            var day: u8 = ctx.day;
            var hour: u8 = 0;
            var minute: u8 = 0;
            var second: u8 = 0;
            var explicit_tz: ?i64 = null;

            if (capSlice(c, win, self.idx_Y)) |ys| {
                year = std.fmt.parseInt(u16, std.mem.trim(u8, ys, " \t"), 10) catch return null;
            } else if (capSlice(c, win, self.idx_y)) |y2s| {
                const y2 = std.fmt.parseInt(u16, std.mem.trim(u8, y2s, " \t"), 10) catch return null;
                year = if (y2 >= 70) 1900 + y2 else 2000 + y2;
            }
            if (capSlice(c, win, self.idx_m)) |ms| {
                month = std.fmt.parseInt(u8, std.mem.trim(u8, ms, " \t"), 10) catch return null;
            } else if (capSlice(c, win, self.idx_b)) |bs| {
                month = parseMonthAbbrev(std.mem.trim(u8, bs, " \t")) orelse return null;
            }
            if (capSlice(c, win, self.idx_d)) |ds| {
                day = std.fmt.parseInt(u8, std.mem.trim(u8, ds, " \t"), 10) catch return null;
            }
            if (capSlice(c, win, self.idx_H)) |hs| {
                hour = std.fmt.parseInt(u8, std.mem.trim(u8, hs, " \t"), 10) catch return null;
            }
            if (capSlice(c, win, self.idx_M)) |mins| {
                minute = std.fmt.parseInt(u8, std.mem.trim(u8, mins, " \t"), 10) catch return null;
            }
            if (capSlice(c, win, self.idx_S)) |secs| {
                second = std.fmt.parseInt(u8, std.mem.trim(u8, secs, " \t"), 10) catch return null;
            }
            if (capSlice(c, win, self.idx_z)) |zs| {
                const tzs = std.mem.trim(u8, zs, " \t");
                if (parseExplicitTz(tzs)) |tz| {
                    explicit_tz = tz.offset_sec;
                } else if (std.ascii.eqlIgnoreCase(tzs, "UTC") or std.ascii.eqlIgnoreCase(tzs, "GMT")) {
                    explicit_tz = 0;
                }
            }

            const civil_sec = civilToEpochSeconds(year, month, day, hour, minute, second) orelse return null;
            return finalizeCivilToNs(civil_sec, frac_ns, explicit_tz, ctx);
        }

        const ts_slice = capSlice(c, win, self.idx_ts) orelse return null;
        if (self.sub_strftime) |*sf| {
            if (sf.anchored) return sf.parseAt(ts_slice, 0, ctx);
            return sf.parseLine(ts_slice, ctx);
        }
        return parseTimestampValueNs(ts_slice, ctx, cache);
    }
};

// ============================================================================
// Unified CompiledTimeParser (Read-Only `*const` Shared Across Workers)
// ============================================================================

pub const CompiledTimeParser = struct {
    mode: union(enum) {
        auto: void,
        strftime: StrftimeProg,
        json_field: JsonFieldProg,
        regex_capture: RegexCaptureProg,
    } = .{ .auto = {} },

    /// Initializes `self` in place at its pinned heap address (`gpa.create(CompiledTimeParser)`).
    /// NEVER copy `CompiledTimeParser` by value after initialization (internal `Finder`/`Regex` slices).
    pub fn initInPlace(
        self: *CompiledTimeParser,
        gpa: std.mem.Allocator,
        diag_arena: std.mem.Allocator,
        raw_format: []const u8,
        err_msg_out: *?[]const u8,
    ) !void {
        err_msg_out.* = null;
        const clean = std.mem.trim(u8, raw_format, " \t\r\n");
        if (clean.len == 0 or std.ascii.eqlIgnoreCase(clean, "auto")) {
            self.* = .{ .mode = .{ .auto = {} } };
            return;
        }

        if (clean.len >= 5 and std.ascii.eqlIgnoreCase(clean[0..5], "json:")) {
            self.* = .{ .mode = .{ .json_field = .{} } };
            try self.mode.json_field.initInPlace(diag_arena, clean[5..], err_msg_out);
            return;
        }

        if (clean.len >= 6 and std.ascii.eqlIgnoreCase(clean[0..6], "regex:")) {
            const re_prog = try RegexCaptureProg.init(gpa, diag_arena, clean[6..], err_msg_out);
            self.* = .{ .mode = .{ .regex_capture = re_prog } };
            return;
        }

        const sf = StrftimeProg.compile(diag_arena, clean, err_msg_out) orelse return error.InvalidTimeFormat;
        self.* = .{ .mode = .{ .strftime = sf } };
    }

    pub fn deinit(self: *CompiledTimeParser, gpa: std.mem.Allocator) void {
        _ = gpa;
        switch (self.mode) {
            .regex_capture => |*rp| rp.deinit(),
            else => {},
        }
        self.* = .{ .mode = .{ .auto = {} } };
    }

    pub fn parseLine(
        self: *const CompiledTimeParser,
        raw_line: []const u8,
        ctx: FallbackTimeContext,
        scratch: ?*libwebgrep.RegexScratch,
        cache: ?*PrefixEpochCache,
    ) ?u64 {
        return switch (self.mode) {
            .auto => parseUniversalLineNs(raw_line, ctx, cache),
            .strftime => |*sf| sf.parseLine(raw_line, ctx),
            .json_field => |*jf| jf.parseLine(raw_line, ctx, cache),
            .regex_capture => |*rp| rp.parseLine(raw_line, ctx, scratch, cache),
        };
    }
};

pub const TimeHookAdapter = struct {
    parser: *const CompiledTimeParser,
    scratch: ?*libwebgrep.RegexScratch = null,
    cache: ?*PrefixEpochCache = null,

    pub fn parseHook(
        raw_ctx: ?*anyopaque,
        line: []const u8,
        fallback_year: u16,
        fallback_month: u8,
        fallback_day: u8,
        tz_offset_min: i16,
        _: ?u32,
    ) ?prefilter.TimeParseResult {
        const self: *TimeHookAdapter = @ptrCast(@alignCast(raw_ctx orelse return null));
        const ctx = FallbackTimeContext{
            .year = fallback_year,
            .month = fallback_month,
            .day = fallback_day,
            .tz_offset_sec = @as(i64, tz_offset_min) * 60,
        };
        const ns = self.parser.parseLine(line, ctx, self.scratch, self.cache) orelse return null;
        return .{ .ts_ns = ns, .format_id = 100 };
    }

    pub fn continuationHook(_: ?*anyopaque, line: []const u8) bool {
        return isLikelyContinuationLine(line);
    }

    pub fn toTimeHooks(self: *TimeHookAdapter) prefilter.TimeHooks {
        return .{
            .ctx = self,
            .parseLineFn = if (self.parser.mode != .auto) parseHook else null,
            .isContinuationFn = continuationHook,
        };
    }
};

// ============================================================================
// Multi-Line Lookbehind, Quorum Detection & O(log N) Mmap Binary Search
// ============================================================================

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

