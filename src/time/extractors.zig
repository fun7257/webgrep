const std = @import("std");
const libwebgrep = @import("libwebgrep");
const prefilter = @import("../prefilter.zig");
const calendar = @import("calendar.zig");
const universal = @import("universal.zig");
const strftime = @import("strftime.zig");
const slice_narrow = @import("slice_narrow.zig");

const FallbackTimeContext = calendar.FallbackTimeContext;
const PrefixEpochCache = calendar.PrefixEpochCache;
const civilToEpochSeconds = calendar.civilToEpochSeconds;
const finalizeCivilToNs = calendar.finalizeCivilToNs;
const parseMonthAbbrev = calendar.parseMonthAbbrev;
const parseExplicitTz = calendar.parseExplicitTz;
const parseFractionDigitsNs = calendar.parseFractionDigitsNs;
const parseTimestampValueNs = universal.parseTimestampValueNs;
const parseUniversalLineNs = universal.parseUniversalLineNs;
const sliceAtLineEnd = universal.sliceAtLineEnd;
const StrftimeProg = strftime.StrftimeProg;
const isLikelyContinuationLine = slice_narrow.isLikelyContinuationLine;

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
