const std = @import("std");
const calendar = @import("calendar.zig");

const FallbackTimeContext = calendar.FallbackTimeContext;
const PrefixEpochCache = calendar.PrefixEpochCache;
const CivilDateTime = calendar.CivilDateTime;
const daysInMonth = calendar.daysInMonth;
const civilToEpochSeconds = calendar.civilToEpochSeconds;
const parse2Digits = calendar.parse2Digits;
const parse4Digits = calendar.parse4Digits;
const parseLineLeadingNs = calendar.parseLineLeadingNs;
const epochSecondsToCivil = calendar.epochSecondsToCivil;
const parseMonthNamePrefix = calendar.parseMonthNamePrefix;
const parseMonthAbbrev = calendar.parseMonthAbbrev;
const parseWeekdayPrefix = calendar.parseWeekdayPrefix;
const parse1Or2Digits = calendar.parse1Or2Digits;
const parseAmPm = calendar.parseAmPm;
const apply12Hour = calendar.apply12Hour;
const ParsedTz = calendar.ParsedTz;
const parseExplicitTz = calendar.parseExplicitTz;
const parseExplicitTzStrict = calendar.parseExplicitTzStrict;
const parseFractionDigitsNs = calendar.parseFractionDigitsNs;
const finalizeCivilToNs = calendar.finalizeCivilToNs;
const parseOptionalFracAmPmTz = calendar.parseOptionalFracAmPmTz;
const parseTimeAndTail = calendar.parseTimeAndTail;
const parseCompactCalendarDigits = calendar.parseCompactCalendarDigits;

/// Attempts to parse any standard calendar timestamp starting at `s[0]`.
pub fn parseCalendarAt(
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
pub fn parseShortDateAt(s: []const u8, ctx: FallbackTimeContext) ?u64 {
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
pub fn parseLeadingTimeOnlyAt(s: []const u8, ctx: FallbackTimeContext) ?u64 {
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

pub fn findJsonKeyValue(win: []const u8, key_quoted: []const u8) ?[]const u8 {
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

pub fn sliceAtLineEnd(raw_line: []const u8) []const u8 {
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
