const std = @import("std");
const prefilter = @import("../../prefilter.zig");

pub const Verdict = prefilter.Verdict;
pub const FileMeta = prefilter.FileMeta;
pub const QueryPredicates = prefilter.QueryPredicates;
pub const LineState = prefilter.LineState;
pub const TimeHooks = prefilter.TimeHooks;
pub const TimeParseResult = prefilter.TimeParseResult;
pub const KvPredicate = prefilter.KvPredicate;
pub const KvOp = prefilter.KvOp;

pub const FallbackTimeContext = struct {
    year: u16 = 2026,
    month: u8 = 1,
    day: u8 = 1,
    tz_offset_sec: i64 = 0,

    pub fn fromMetaAndPreds(meta: FileMeta, preds: QueryPredicates) FallbackTimeContext {
        const clamped_min: i16 = std.math.clamp(preds.tz_offset_min, -840, 840);
        const tz_sec: i64 = @as(i64, clamped_min) * 60;
        const mtime_ns = preds.fallbackEpochNs(meta);
        if (mtime_ns <= 0) {
            return .{ .year = 2026, .month = 1, .day = 1, .tz_offset_sec = tz_sec };
        }
        const raw_sec: i64 = @intCast(@min(@divFloor(mtime_ns, std.time.ns_per_s), std.math.maxInt(i64) - 86400));
        const civil = epochSecondsToCivil(raw_sec + tz_sec) orelse return .{ .year = 2026, .month = 1, .day = 1, .tz_offset_sec = tz_sec };
        return .{
            .year = civil.year,
            .month = civil.month,
            .day = civil.day,
            .tz_offset_sec = tz_sec,
        };
    }
};

// ============================================================================
// Calendar Math & Built-in Fast Sticky Timestamp Parser
// ============================================================================

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

pub fn civilToEpochSeconds(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?i64 {
    if (year < 1970 or year > 2261) return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    var y: i64 = @intCast(year);
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    if (m <= 2) y -= 1;
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const adj_m: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divTrunc(153 * adj_m + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days_since_epoch: i64 = era * 146097 + doe - 719468;

    return days_since_epoch * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

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

pub fn testUtcNs(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8, sub_ns: u64) u64 {
    const sec = civilToEpochSeconds(year, month, day, hour, minute, second).?;
    return @as(u64, @intCast(sec)) * std.time.ns_per_s + sub_ns;
}

pub fn sliceAtLineEnd(raw_line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, raw_line, '\n')) |nl| {
        const end = if (nl > 0 and raw_line[nl - 1] == '\r') nl - 1 else nl;
        return raw_line[0..end];
    }
    return std.mem.trimEnd(u8, raw_line, "\r");
}

inline fn parse2Digits(s: []const u8) ?u8 {
    if (s.len < 2 or !std.ascii.isDigit(s[0]) or !std.ascii.isDigit(s[1])) return null;
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

fn parse1Or2Digits(s: []const u8) ?struct { val: u8, len: usize } {
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return null;
    if (s.len >= 2 and std.ascii.isDigit(s[1])) {
        return .{ .val = (s[0] - '0') * 10 + (s[1] - '0'), .len = 2 };
    }
    return .{ .val = s[0] - '0', .len = 1 };
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

fn parseExplicitTzStrict(s: []const u8) ?struct { offset_sec: i64, len: usize } {
    if (s.len == 0) return null;
    if (s[0] == 'Z' or s[0] == 'z') {
        if (s.len == 1 or !std.ascii.isAlphanumeric(s[1])) return .{ .offset_sec = 0, .len = 1 };
        return null;
    }
    if (s.len >= 3 and (std.ascii.eqlIgnoreCase(s[0..3], "UTC") or std.ascii.eqlIgnoreCase(s[0..3], "GMT"))) {
        if (s.len == 3 or !std.ascii.isAlphanumeric(s[3])) return .{ .offset_sec = 0, .len = 3 };
        return null;
    }
    if (s[0] != '+' and s[0] != '-') return null;
    const sign: i64 = if (s[0] == '+') 1 else -1;
    const body = s[1..];
    if (body.len < 4) return null;
    const tz_h = parse2Digits(body[0..2]) orelse return null;
    if (tz_h > 23) return null;
    var tz_m: u8 = 0;
    var consumed: usize = 0;
    if (body.len >= 5 and body[2] == ':' and std.ascii.isDigit(body[3]) and std.ascii.isDigit(body[4])) {
        tz_m = parse2Digits(body[3..5]) orelse return null;
        consumed = 6;
    } else if (std.ascii.isDigit(body[2]) and std.ascii.isDigit(body[3])) {
        tz_m = parse2Digits(body[2..4]) orelse return null;
        consumed = 5;
    } else return null;
    if (tz_m > 59) return null;
    if (consumed < s.len and std.ascii.isDigit(s[consumed])) return null;
    return .{
        .offset_sec = sign * (@as(i64, tz_h) * 3600 + @as(i64, tz_m) * 60),
        .len = consumed,
    };
}

fn finalizeCivilToNs(civil_sec: i64, frac_ns: u64, explicit_tz_sec: ?i64, ctx: FallbackTimeContext) ?u64 {
    const tz_sec = explicit_tz_sec orelse ctx.tz_offset_sec;
    const utc_sec = civil_sec - tz_sec;
    if (utc_sec <= 0) return null;
    return @as(u64, @intCast(utc_sec)) *| std.time.ns_per_s +| frac_ns;
}

fn parseMonthAbbrev(s: []const u8) ?struct { month: u8, len: usize } {
    const abbr_months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    if (s.len < 3) return null;
    for (abbr_months, 1..) |m, idx| {
        if (std.ascii.eqlIgnoreCase(s[0..3], m)) {
            if (s.len == 3 or !std.ascii.isAlphabetic(s[3])) {
                return .{ .month = @intCast(idx), .len = 3 };
            }
        }
    }
    return null;
}

const FMT_LEADING_NS: u32 = 1;
const FMT_ISO_YMD: u32 = 2;
const FMT_SYSLOG: u32 = 3;
const FMT_CLF: u32 = 4;
const FMT_JSONL: u32 = 5;
const FMT_LOGFMT: u32 = 6;
const FMT_EPOCH: u32 = 7;
const FMT_TIME_ONLY: u32 = 8;

fn parseLeadingNs(line: []const u8) ?u64 {
    if (line.len < 20 or line[19] != ' ') return null;
    var acc: u64 = 0;
    for (line[0..19]) |ch| {
        if (ch < '0' or ch > '9') return null;
        acc = acc *| 10 +| @as(u64, ch - '0');
    }
    return acc;
}

fn parseIsoYmdAt(s: []const u8, ctx: FallbackTimeContext) ?u64 {
    if (s.len < 19) return null;
    if ((s[4] != '-' and s[4] != '/' and s[4] != '.') or s[7] != s[4]) return null;
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ' and s[10] != '_') return null;
    if (s[13] != ':' or s[16] != ':') return null;

    const year = parse4Digits(s[0..4]) orelse return null;
    const month = parse2Digits(s[5..7]) orelse return null;
    const day = parse2Digits(s[8..10]) orelse return null;
    const hour = parse2Digits(s[11..13]) orelse return null;
    const minute = parse2Digits(s[14..16]) orelse return null;
    const second = parse2Digits(s[17..19]) orelse return null;
    if (s.len > 19 and std.ascii.isDigit(s[19])) return null;

    var pos: usize = 19;
    var frac_ns: u64 = 0;
    if (pos + 1 < s.len and (s[pos] == '.' or s[pos] == ',') and std.ascii.isDigit(s[pos + 1])) {
        pos += 1;
        const f = parseFractionDigitsNs(s[pos..]);
        frac_ns = f.frac_ns;
        pos += f.len;
    }
    var sp = pos;
    while (sp < s.len and (s[sp] == ' ' or s[sp] == '\t')) : (sp += 1) {}
    var explicit_tz: ?i64 = null;
    if (sp < s.len) {
        if (parseExplicitTzStrict(s[sp..])) |tz| {
            explicit_tz = tz.offset_sec;
        }
    }
    const civil_sec = civilToEpochSeconds(year, month, day, hour, minute, second) orelse return null;
    return finalizeCivilToNs(civil_sec, frac_ns, explicit_tz, ctx);
}

fn parseSyslogAt(s: []const u8, ctx: FallbackTimeContext) ?u64 {
    var body = s;
    if (body.len > 0 and body[0] == '<') {
        if (std.mem.indexOfScalar(u8, body[0..@min(body.len, 8)], '>')) |gt| {
            body = std.mem.trimStart(u8, body[gt + 1 ..], " \t");
        }
    }
    if (body.len < 14) return null;
    const m_tok = parseMonthAbbrev(body) orelse return null;
    var pos: usize = m_tok.len;
    if (pos >= body.len or body[pos] != ' ') return null;
    while (pos < body.len and body[pos] == ' ') : (pos += 1) {}
    const d_tok = parse1Or2Digits(body[pos..]) orelse return null;
    pos += d_tok.len;
    while (pos < body.len and body[pos] == ' ') : (pos += 1) {}
    if (pos + 8 > body.len or body[pos + 2] != ':' or body[pos + 5] != ':') return null;
    const hour = parse2Digits(body[pos .. pos + 2]) orelse return null;
    const minute = parse2Digits(body[pos + 3 .. pos + 5]) orelse return null;
    const second = parse2Digits(body[pos + 6 .. pos + 8]) orelse return null;
    pos += 8;
    var frac_ns: u64 = 0;
    if (pos + 1 < body.len and (body[pos] == '.' or body[pos] == ',') and std.ascii.isDigit(body[pos + 1])) {
        pos += 1;
        const f = parseFractionDigitsNs(body[pos..]);
        frac_ns = f.frac_ns;
        pos += f.len;
    }
    var explicit_year: ?u16 = null;
    var sp = pos;
    while (sp < body.len and body[sp] == ' ') : (sp += 1) {}
    if (sp > pos and sp + 4 <= body.len and (body[sp] == '1' or body[sp] == '2')) {
        if (parse4Digits(body[sp..])) |y| {
            if (sp + 4 == body.len or !std.ascii.isAlphanumeric(body[sp + 4])) {
                explicit_year = y;
            }
        }
    }
    const eff_year: u16 = explicit_year orelse (if (ctx.year >= 1970) ctx.year else 2026);
    const civil_sec = civilToEpochSeconds(eff_year, m_tok.month, d_tok.val, hour, minute, second) orelse return null;
    return finalizeCivilToNs(civil_sec, frac_ns, null, ctx);
}

fn parseClfAt(s: []const u8, ctx: FallbackTimeContext) ?u64 {
    if (s.len < 20 or !std.ascii.isDigit(s[0])) return null;
    const d_tok = parse1Or2Digits(s) orelse return null;
    var pos = d_tok.len;
    if (pos >= s.len or (s[pos] != '/' and s[pos] != '-' and s[pos] != ' ')) return null;
    pos += 1;
    const m_tok = parseMonthAbbrev(s[pos..]) orelse return null;
    pos += m_tok.len;
    if (pos >= s.len or (s[pos] != '/' and s[pos] != '-' and s[pos] != ' ')) return null;
    pos += 1;
    const year = parse4Digits(s[pos..]) orelse return null;
    pos += 4;
    if (pos >= s.len or (s[pos] != ':' and s[pos] != ' ' and s[pos] != 'T')) return null;
    pos += 1;
    while (pos < s.len and s[pos] == ' ') : (pos += 1) {}
    if (pos + 8 > s.len or s[pos + 2] != ':' or s[pos + 5] != ':') return null;
    const hour = parse2Digits(s[pos .. pos + 2]) orelse return null;
    const minute = parse2Digits(s[pos + 3 .. pos + 5]) orelse return null;
    const second = parse2Digits(s[pos + 6 .. pos + 8]) orelse return null;
    pos += 8;
    var frac_ns: u64 = 0;
    if (pos + 1 < s.len and (s[pos] == '.' or s[pos] == ',') and std.ascii.isDigit(s[pos + 1])) {
        pos += 1;
        const f = parseFractionDigitsNs(s[pos..]);
        frac_ns = f.frac_ns;
        pos += f.len;
    }
    while (pos < s.len and s[pos] == ' ') : (pos += 1) {}
    var explicit_tz: ?i64 = null;
    if (pos < s.len) {
        if (parseExplicitTzStrict(s[pos..])) |tz| explicit_tz = tz.offset_sec;
    }
    const civil_sec = civilToEpochSeconds(year, m_tok.month, d_tok.val, hour, minute, second) orelse return null;
    return finalizeCivilToNs(civil_sec, frac_ns, explicit_tz, ctx);
}

fn parseEpochToken(s: []const u8) ?u64 {
    if (s.len < 9 or s.len > 24) return null;
    var dot_pos: ?usize = null;
    for (s, 0..) |c, idx| {
        if (c == '.' and dot_pos == null and idx > 0 and idx + 1 < s.len) {
            dot_pos = idx;
        } else if (!std.ascii.isDigit(c)) {
            return null;
        }
    }
    const min_sane: u64 = 946_684_800 * std.time.ns_per_s; // 2000-01-01
    const max_sane: u64 = 4_102_444_800 * std.time.ns_per_s; // 2100-01-01
    const ns: u64 = if (dot_pos) |dp| blk: {
        const sec_part = std.fmt.parseInt(u64, s[0..dp], 10) catch return null;
        if (s[0..dp].len >= 12) {
            if (s[0..dp].len >= 14) return null;
            break :blk sec_part *| std.time.ns_per_ms;
        }
        if (s[0..dp].len < 9) return null;
        const f = parseFractionDigitsNs(s[dp + 1 ..]);
        break :blk sec_part *| std.time.ns_per_s +| f.frac_ns;
    } else blk: {
        const val = std.fmt.parseInt(u64, s, 10) catch return null;
        if (s.len >= 18) break :blk val;
        if (s.len >= 15) break :blk val *| 1_000;
        if (s.len >= 12) break :blk val *| 1_000_000;
        if (s.len >= 9) break :blk val *| 1_000_000_000;
        return null;
    };
    if (ns < min_sane or ns > max_sane) return null;
    return ns;
}

fn parseTimeValueBuiltin(val: []const u8, ctx: FallbackTimeContext) ?u64 {
    const s = std.mem.trim(u8, val, " \t\r\n\"'");
    if (s.len < 8) return null;
    if (parseEpochToken(s)) |ns| return ns;
    if (parseIsoYmdAt(s, ctx)) |ns| return ns;
    if (parseClfAt(s, ctx)) |ns| return ns;
    if (parseSyslogAt(s, ctx)) |ns| return ns;
    return null;
}

fn parseByFormatId(line: []const u8, fmt_id: u32, ctx: FallbackTimeContext) ?u64 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 8) return null;
    switch (fmt_id) {
        FMT_LEADING_NS => return parseLeadingNs(line),
        FMT_ISO_YMD => {
            const scan_lim = @min(trimmed.len, 64);
            var i: usize = 0;
            while (i + 19 <= trimmed.len and i < scan_lim) : (i += 1) {
                if (i > 0 and std.ascii.isAlphanumeric(trimmed[i - 1])) continue;
                if (trimmed[i] != '1' and trimmed[i] != '2') continue;
                if (parseIsoYmdAt(trimmed[i..@min(trimmed.len, i + 48)], ctx)) |ns| return ns;
            }
            return null;
        },
        FMT_SYSLOG => {
            if (parseSyslogAt(trimmed, ctx)) |ns| return ns;
            if (trimmed[0] == '[') {
                if (std.mem.indexOfScalarPos(u8, trimmed, 1, ']')) |cl| {
                    return parseSyslogAt(std.mem.trim(u8, trimmed[1..cl], " \t"), ctx);
                }
            }
            return null;
        },
        FMT_CLF => {
            if (parseClfAt(trimmed, ctx)) |ns| return ns;
            const br_win = trimmed[0..@min(trimmed.len, 96)];
            var pos: usize = 0;
            while (std.mem.indexOfScalarPos(u8, br_win, pos, '[')) |ob| {
                if (std.mem.indexOfScalarPos(u8, br_win, ob + 1, ']')) |cb| {
                    if (parseClfAt(std.mem.trim(u8, br_win[ob + 1 .. cb], " \t"), ctx)) |ns| return ns;
                }
                pos = ob + 1;
            }
            return null;
        },
        FMT_JSONL => {
            if (trimmed[0] != '{') return null;
            const keys = [_][]const u8{
                "@timestamp", "timestamp", "time", "ts", "datetime", "date", "t",
                "_time", "logged_at", "created_at", "eventTime", "logTime", "ts_ms", "time_ms",
            };
            for (keys) |k| {
                if (extractJsonFieldRaw(trimmed[0..@min(trimmed.len, 512)], k)) |val_tok| {
                    if (val_tok.raw.len > 0) {
                        if (parseTimeValueBuiltin(val_tok.raw, ctx)) |ns| return ns;
                    }
                }
            }
            return null;
        },
        FMT_LOGFMT => {
            const lf_win = trimmed[0..@min(trimmed.len, 192)];
            const keys = [_][]const u8{ "@timestamp", "timestamp", "time", "datetime", "ts", "t" };
            for (keys) |k| {
                if (extractLogfmtFieldRaw(lf_win, k)) |val| {
                    if (parseTimeValueBuiltin(val, ctx)) |ns| return ns;
                }
            }
            return null;
        },
        FMT_EPOCH => {
            if (!std.ascii.isDigit(trimmed[0])) return null;
            var end: usize = 0;
            while (end < trimmed.len and end < 24 and (std.ascii.isDigit(trimmed[end]) or trimmed[end] == '.')) : (end += 1) {}
            if (end < 9) return null;
            if (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and trimmed[end] != ',' and trimmed[end] != '|') return null;
            return parseEpochToken(trimmed[0..end]);
        },
        FMT_TIME_ONLY => {
            var s = trimmed;
            if (s[0] == '[') {
                const cl = std.mem.indexOfScalarPos(u8, s, 1, ']') orelse return null;
                s = std.mem.trim(u8, s[1..cl], " \t");
                if (parseTimeValueBuiltin(s, ctx)) |ns| return ns;
            }
            if (s.len >= 8 and s[2] == ':' and s[5] == ':') {
                const hour = parse2Digits(s[0..2]) orelse return null;
                const minute = parse2Digits(s[3..5]) orelse return null;
                const second = parse2Digits(s[6..8]) orelse return null;
                var pos: usize = 8;
                if (pos < s.len and s[pos] == ':') return null; // MAC address guard
                var frac_ns: u64 = 0;
                if (pos + 1 < s.len and (s[pos] == '.' or s[pos] == ',') and std.ascii.isDigit(s[pos + 1])) {
                    pos += 1;
                    const f = parseFractionDigitsNs(s[pos..]);
                    frac_ns = f.frac_ns;
                    pos += f.len;
                }
                if (pos < s.len and s[pos] != ' ' and s[pos] != '\t' and s[pos] != ']' and s[pos] != '|') return null;
                const civil_sec = civilToEpochSeconds(ctx.year, ctx.month, ctx.day, hour, minute, second) orelse return null;
                return finalizeCivilToNs(civil_sec, frac_ns, null, ctx);
            }
            return null;
        },
        else => return null,
    }
}

pub fn parseLineBuiltin(
    raw_line: []const u8,
    ctx: FallbackTimeContext,
    sticky_format_id: ?u32,
) ?TimeParseResult {
    const line = sliceAtLineEnd(raw_line);
    if (line.len < 8) return null;

    // 1. Sticky format fast path
    if (sticky_format_id) |fid| {
        if (parseByFormatId(line, fid, ctx)) |ns| {
            return .{ .ts_ns = ns, .format_id = fid };
        }
    }

    // 2. Fallback ordered probe across built-in formats
    const order = [_]u32{
        FMT_LEADING_NS,
        FMT_JSONL,
        FMT_ISO_YMD,
        FMT_CLF,
        FMT_SYSLOG,
        FMT_EPOCH,
        FMT_LOGFMT,
        FMT_TIME_ONLY,
    };
    for (order) |fid| {
        if (sticky_format_id != null and fid == sticky_format_id.?) continue;
        if (parseByFormatId(line, fid, ctx)) |ns| {
            return .{ .ts_ns = ns, .format_id = fid };
        }
    }
    return null;
}

pub fn parseLineWithHooks(
    raw_line: []const u8,
    ctx: FallbackTimeContext,
    sticky_format_id: ?u32,
    hooks: TimeHooks,
) ?TimeParseResult {
    if (hooks.parseLineFn) |fn_ptr| {
        return fn_ptr(hooks.ctx, raw_line, ctx.year, ctx.month, ctx.day, @intCast(@divTrunc(ctx.tz_offset_sec, 60)), sticky_format_id);
    }
    return parseLineBuiltin(raw_line, ctx, sticky_format_id);
}

// ============================================================================
// O(1) Memoized Continuation Detection
// ============================================================================

pub fn defaultIsContinuationLine(raw_line: []const u8) bool {
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

pub fn isContinuationLine(raw_line: []const u8, hooks: TimeHooks) bool {
    if (hooks.isContinuationFn) |fn_ptr| {
        return fn_ptr(hooks.ctx, raw_line);
    }
    return defaultIsContinuationLine(raw_line);
}

/// Fast O(1) check whether an indented/continuation line could possibly carry a leading timestamp
/// (e.g., `  2026-...` or `  {"timestamp":...}`), allowing `    at Frame()` / `Caused by:` to skip parsing in O(1).
inline fn continuationCouldHaveTimestamp(raw_line: []const u8) bool {
    const line = sliceAtLineEnd(raw_line);
    if (line.len == 0) return false;
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 8) return false;
    const c = trimmed[0];
    if (std.ascii.isDigit(c) or c == '{' or c == '[' or c == '<') return true;
    // Check common logfmt timestamp prefix or 3-char month abbreviation
    if (trimmed.len >= 4 and (trimmed[3] == ' ' or trimmed[3] == '\t') and parseMonthAbbrev(trimmed) != null) return true;
    return false;
}

// ============================================================================
// Stage 4 Line Filter (`line_time`)
// ============================================================================

pub fn filterLine(
    raw_line: []const u8,
    meta: FileMeta,
    preds: QueryPredicates,
    state: *LineState,
    hooks: TimeHooks,
) bool {
    state.stats.lines_seen += 1;

    // 1. Time range filtering (when active)
    if (preds.hasTimeRange()) {
        const line = sliceAtLineEnd(raw_line);
        const is_cont = isContinuationLine(line, hooks);

        // O(1) memoized continuation fast path: skip timestamp re-parse when indented/stack frame
        // belongs to previous record and cannot itself start a timestamp.
        if (state.prev_ts_ns != null and is_cont and !continuationCouldHaveTimestamp(line)) {
            state.stats.continuations_inherited += 1;
            if (!state.prev_in_range) {
                state.stats.lines_skipped_time += 1;
                return false;
            }
        } else {
            const ctx = FallbackTimeContext.fromMetaAndPreds(meta, preds);
            const prev_sticky = state.sticky_format_id;
            if (parseLineWithHooks(line, ctx, prev_sticky, hooks)) |res| {
                if (prev_sticky != null and res.format_id != null and res.format_id.? == prev_sticky.?) {
                    state.stats.sticky_hits += 1;
                }
                if (res.format_id) |fid| {
                    state.sticky_format_id = fid;
                }
                state.recordObservedTs(res.ts_ns);

                const in_range = (preds.time_start_ns == 0 or res.ts_ns >= preds.time_start_ns) and
                    (preds.time_end_ns == 0 or res.ts_ns <= preds.time_end_ns);
                state.prev_ts_ns = res.ts_ns;
                state.prev_in_range = in_range;
                if (!in_range) {
                    state.stats.lines_skipped_time += 1;
                    return false;
                }
            } else if (state.prev_ts_ns != null and is_cont) {
                state.stats.continuations_inherited += 1;
                if (!state.prev_in_range) {
                    state.stats.lines_skipped_time += 1;
                    return false;
                }
            } else {
                // Untagged line (not a continuation of a parsed record)
                if (preds.strict_content_time or state.saw_any_timestamp) {
                    state.stats.lines_skipped_time += 1;
                    return false;
                }
                if (preds.allow_mtime_fallback_on_no_ts and preds.preset != .timeseries and meta.mtime_ns > 0) {
                    const mtime_u64: u64 = @intCast(@min(@as(i128, meta.mtime_ns), std.math.maxInt(u64)));
                    if ((preds.time_start_ns > 0 and mtime_u64 +| preds.skew_tolerance_ns < preds.time_start_ns) or
                        (preds.time_end_ns > 0 and mtime_u64 > preds.time_end_ns))
                    {
                        state.stats.lines_skipped_time += 1;
                        return false;
                    }
                }
            }
        }
    }

    // 2. Allocation-free KV predicate verification on JSON/logfmt lines
    if (preds.kv_predicates.len > 0) {
        if (!matchesKvPredicates(raw_line, preds.kv_predicates)) {
            state.stats.lines_skipped_kv += 1;
            return false;
        }
    }

    state.stats.lines_kept += 1;
    return true;
}

pub const kv_filter = @import("kv_filter.zig");
const extractJsonFieldRaw = kv_filter.extractJsonFieldRaw;
const extractLogfmtFieldRaw = kv_filter.extractLogfmtFieldRaw;
pub const matchesKvPredicates = kv_filter.matchesKvPredicates;

test {
    _ = @import("line_time_tests.zig");
}
