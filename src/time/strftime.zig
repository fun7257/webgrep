const std = @import("std");
const calendar = @import("calendar.zig");
const universal = @import("universal.zig");
const picture_compile = @import("picture_compile.zig");

const FallbackTimeContext = calendar.FallbackTimeContext;
const PrefixEpochCache = calendar.PrefixEpochCache;
const daysInMonth = calendar.daysInMonth;
const civilToEpochSeconds = calendar.civilToEpochSeconds;
const parseMonthNamePrefix = calendar.parseMonthNamePrefix;
const parseMonthAbbrev = calendar.parseMonthAbbrev;
const parseWeekdayPrefix = calendar.parseWeekdayPrefix;
const parse1Or2Digits = calendar.parse1Or2Digits;
const parseAmPm = calendar.parseAmPm;
const apply12Hour = calendar.apply12Hour;
const parseExplicitTz = calendar.parseExplicitTz;
const parseExplicitTzStrict = calendar.parseExplicitTzStrict;
const parseFractionDigitsNs = calendar.parseFractionDigitsNs;
const finalizeCivilToNs = calendar.finalizeCivilToNs;
const parseOptionalFracAmPmTz = calendar.parseOptionalFracAmPmTz;
const sliceAtLineEnd = universal.sliceAtLineEnd;
const eqLower = picture_compile.eqLower;
const parse2Digits = calendar.parse2Digits;
const parse4Digits = calendar.parse4Digits;

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
        return picture_compile.compilePicture(&prog, arena, spec, err_msg_out);
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

    pub fn tooMany(err_msg_out: *?[]const u8) ?StrftimeProg {
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
