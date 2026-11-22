const std = @import("std");
const libwebgrep = @import("libwebgrep");

pub const MatcherUnion = union(enum) {
    literal: libwebgrep.Finder,
    multi: libwebgrep.Multi,
    regex: libwebgrep.Regex,

    pub fn deinit(self: *MatcherUnion) void {
        switch (self.*) {
            .literal => {},
            .multi => |*m| m.deinit(),
            .regex => |*r| r.deinit(),
        }
    }
};

pub fn parseCaseMode(case_str: []const u8) libwebgrep.CaseMode {
    if (std.mem.eql(u8, case_str, "sensitive")) return .sensitive;
    if (std.mem.eql(u8, case_str, "insensitive")) return .insensitive;
    return .smart;
}

pub fn hasRegexMeta(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '\\', '.', '*', '+', '?', '^', '$', '(', ')', '[', ']', '{', '}', '|' => return true,
            else => {},
        }
    }
    return false;
}

pub fn hasAsciiUpper(s: []const u8) bool {
    for (s) |c| {
        if (c >= 'A' and c <= 'Z') return true;
    }
    return false;
}

pub const ScopedModifier = struct {
    pattern: []const u8,
    case_mode: libwebgrep.CaseMode,
};

pub fn escapeRegexLiteralAlloc(arena: std.mem.Allocator, lit: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, lit.len * 2);
    for (lit) |c| {
        switch (c) {
            '\\', '.', '*', '+', '?', '^', '$', '(', ')', '[', ']', '{', '}', '|' => {
                try out.append(arena, '\\');
                try out.append(arena, c);
            },
            else => try out.append(arena, c),
        }
    }
    return out.items;
}

/// Parses scoped `$` modifiers: `$r(...)`, `$c(...)`, `$w(...)`, `$rc(...)`, `$rw(...)`, `$cw(...)`, `$rcw(...)`.
/// Only the content inside `$(...)` has regex (`r`), case-sensitive (`c`), or whole-word (`w`) applied;
/// all tokens outside `$(...)` remain pure unmodified literals.
pub fn parseScopedModifier(
    arena: std.mem.Allocator,
    s: []const u8,
    default_case: libwebgrep.CaseMode,
) ?ScopedModifier {
    if (s.len >= 4 and s[0] == '$') {
        if (std.mem.indexOfScalar(u8, s[1..], '(')) |rel_open| {
            const open_idx = rel_open + 1;
            const flag_part = s[1..open_idx];
            var has_r = false;
            var has_c = false;
            var has_w = false;
            var valid_flag = flag_part.len > 0;

            if (std.ascii.eqlIgnoreCase(flag_part, "re") or
                std.ascii.eqlIgnoreCase(flag_part, "regex") or
                std.mem.eql(u8, flag_part, ".*"))
            {
                has_r = true;
            } else if (std.ascii.eqlIgnoreCase(flag_part, "case") or
                std.ascii.eqlIgnoreCase(flag_part, "aa") or
                std.ascii.eqlIgnoreCase(flag_part, "s"))
            {
                has_c = true;
            } else if (std.ascii.eqlIgnoreCase(flag_part, "word") or
                std.ascii.eqlIgnoreCase(flag_part, "b") or
                std.mem.eql(u8, flag_part, "\\b"))
            {
                has_w = true;
            } else {
                for (flag_part) |ch| {
                    const lower = std.ascii.toLower(ch);
                    if (lower == 'r') {
                        has_r = true;
                    } else if (lower == 'c') {
                        has_c = true;
                    } else if (lower == 'w') {
                        has_w = true;
                    } else {
                        valid_flag = false;
                        break;
                    }
                }
            }

            if (valid_flag and (has_r or has_c or has_w)) {
                const inner_start = open_idx + 1;
                const inner_end = if (s.len > inner_start and s[s.len - 1] == ')') s.len - 1 else s.len;
                if (inner_end > inner_start) {
                    const raw_inner = s[inner_start..inner_end];
                    const base_pat = if (has_r)
                        raw_inner
                    else
                        (escapeRegexLiteralAlloc(arena, raw_inner) catch return null);

                    const final_pat = if (has_w) blk: {
                        if (has_r and std.mem.indexOfScalar(u8, base_pat, '|') != null) {
                            break :blk std.fmt.allocPrint(arena, "\\b(?:{s})\\b", .{base_pat}) catch return null;
                        } else {
                            break :blk std.fmt.allocPrint(arena, "\\b{s}\\b", .{base_pat}) catch return null;
                        }
                    } else base_pat;

                    return .{
                        .pattern = final_pat,
                        .case_mode = if (has_c) .sensitive else default_case,
                    };
                }
            }
        }
    }
    return null;
}

/// Caller-configured engine limits for `libwebgrep v0.5.0`.
/// Since `libwebgrep v0.5.0` removed internal hardcoded upper caps (`*_hard_cap`),

/// Computes the SIMD prefilter selectivity score for a compiled regex (`libwebgrep v0.5.0`).
/// Higher scores indicate stronger fixed-literal or Teddy multi-literal anchors (`Finder` / `Multi` at 20+ GB/s)
pub fn computeRegexSelectivity(re: *const libwebgrep.Regex) usize {
    const req_len = if (re.requiredLiteral()) |rl| rl.bytes.len else 0;
    const tail_len = re.tail_literal_bytes.len;
    if (re.req_is_exact) return req_len * 10 + 5;
    if (req_len > 0) {
        const dfa_bonus: usize = if (re.dfa_is_exact) 4 else if (re.precomputed_dfa != null) 2 else 0;
        return req_len * 8 + tail_len * 4 + dfa_bonus;
    }
    if (re.alt_prefilter != null and re.alt_literal_slices.len > 0) {
        var min_alt_len: usize = std.math.maxInt(usize);
        for (re.alt_literal_slices) |branch| {
            if (branch.len < min_alt_len) min_alt_len = branch.len;
        }
        if (min_alt_len != std.math.maxInt(usize) and min_alt_len > 0) {
            if (re.alt_is_exact) return min_alt_len * 9 + 3;
            const dfa_bonus: usize = if (re.precomputed_dfa != null) 2 else 0;
            return min_alt_len * 7 + dfa_bonus;
        }
    }
    if (re.precomputed_dfa != null) {
        return if (re.dfa_is_exact) 3 else 2;
    }
    return 1;
}

pub fn computeLiteralSelectivity(lit: []const u8) usize {
    return lit.len * 10 + 5;
}
