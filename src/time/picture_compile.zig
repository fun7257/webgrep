const std = @import("std");
const strftime = @import("strftime.zig");

const StrftimeProg = strftime.StrftimeProg;
const MAX_STRFTIME_OPS = strftime.MAX_STRFTIME_OPS;
const MAX_STRFTIME_LIT_BYTES = strftime.MAX_STRFTIME_LIT_BYTES;
const TimeOpTag = strftime.TimeOpTag;
const TimeOp = strftime.TimeOp;

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

pub fn eqLower(a: []const u8, comptime b_lower: []const u8) bool {
    return a.len == b_lower.len and std.ascii.eqlIgnoreCase(a, b_lower);
}

pub fn compilePicture(
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
        if (prog.op_len >= MAX_STRFTIME_OPS) return StrftimeProg.tooMany(err_msg_out);
        prog.ops[prog.op_len] = op;
        prog.op_len += 1;
    }

    if (directive_count == 0) {
        err_msg_out.* = "Time format must contain date or time specifiers (e.g. yyyy-MM-dd HH:mm:ss or yyyy-hm)";
        return null;
    }
    return prog;
}
