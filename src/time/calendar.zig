const std = @import("std");
const prefilter = @import("../prefilter.zig");

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

pub fn daysInMonth(year: u16, month: u8) u8 {
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

pub inline fn parse2Digits(s: []const u8) ?u8 {
    if (s.len < 2) return null;
    if (!std.ascii.isDigit(s[0]) or !std.ascii.isDigit(s[1])) return null;
    return (s[0] - '0') * 10 + (s[1] - '0');
}

pub inline fn parse4Digits(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    var acc: u16 = 0;
    for (s[0..4]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        acc = acc * 10 + @as(u16, c - '0');
    }
    return acc;
}

pub fn parseMonthNamePrefix(s: []const u8) ?struct { month: u8, len: usize } {
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

pub fn parseMonthAbbrev(mon: []const u8) ?u8 {
    const res = parseMonthNamePrefix(mon) orelse return null;
    return if (res.len == mon.len) res.month else null;
}

pub fn parseWeekdayPrefix(s: []const u8) ?usize {
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

pub fn parse1Or2Digits(s: []const u8) ?struct { val: u8, len: usize } {
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return null;
    if (s.len >= 2 and std.ascii.isDigit(s[1])) {
        return .{ .val = (s[0] - '0') * 10 + (s[1] - '0'), .len = 2 };
    }
    return .{ .val = s[0] - '0', .len = 1 };
}

pub fn parseAmPm(s: []const u8) ?struct { is_pm: bool, len: usize } {
    if (s.len < 2) return null;
    const is_am = (s[0] == 'A' or s[0] == 'a') and (s[1] == 'M' or s[1] == 'm');
    const is_pm = (s[0] == 'P' or s[0] == 'p') and (s[1] == 'M' or s[1] == 'm');
    if (!is_am and !is_pm) return null;
    if (s.len > 2 and std.ascii.isAlphanumeric(s[2])) return null;
    return .{ .is_pm = is_pm, .len = 2 };
}

pub fn apply12Hour(hour: u8, is_pm: bool) ?u8 {
    if (hour > 12) return null;
    if (is_pm) return if (hour == 12) 12 else hour + 12;
    return if (hour == 12) 0 else hour;
}

pub const ParsedTz = struct { offset_sec: i64, len: usize };

/// Parses an explicit timezone suffix starting at `s[0]` (`Z`/`z`, `UTC`/`GMT`, or `±HH[:MM]`).
/// Returns `{ offset_sec, consumed_len }` or `null` if no timezone token starts at `s[0]`.
pub fn parseExplicitTz(s: []const u8) ?ParsedTz {
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
pub fn parseExplicitTzStrict(s: []const u8) ?ParsedTz {
    const tz = parseExplicitTz(s) orelse return null;
    if (tz.len == 3 and (s[0] == '+' or s[0] == '-')) return null;
    return tz;
}

pub fn parseFractionDigitsNs(s: []const u8) struct { frac_ns: u64, len: usize } {
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

pub fn finalizeCivilToNs(
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
pub fn parseOptionalFracAmPmTz(
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
pub fn parseTimeAndTail(
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
pub fn parseCompactCalendarDigits(digits: []const u8, frac_tail: []const u8, tz_tail: []const u8, ctx: FallbackTimeContext) ?u64 {
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
