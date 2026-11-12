const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("file_api.zig");
const source_registry = @import("source_registry.zig");
const search_cache = @import("search_cache.zig");
const ingestor = @import("ingestor.zig");

pub const SearchRequest = struct {
    type: []const u8 = "search",
    id: u64 = 1,
    pattern: []const u8 = "",
    mode: []const u8 = "literal", // "literal" | "multi" | "regex"
    case: []const u8 = "smart", // "smart" | "sensitive" | "insensitive"
    wholeWord: bool = false,
    wholeLine: bool = false,
    invert: bool = false,
    contains: []const []const u8 = &.{},
    excludes: []const []const u8 = &.{},
    replacement: ?[]const u8 = null,
    context: u32 = 0,
    tenant: []const u8 = "default",
    sources: []const []const u8 = &.{},
    paths: []const []const u8 = &.{},
    globs: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    hidden: bool = false,
    respectIgnore: bool = false,
    maxResults: u64 = 20000,
    timeStartNs: u64 = 0,
    timeEndNs: u64 = 0,
    timeStartMs: u64 = 0,
    timeEndMs: u64 = 0,
    /// File/path filters from `@*.rs` / `@src/` / `-@*_test.go` (`!` prefix = exclude).
    /// Matched against each file's source-relative path; positives are OR-ed, negatives always win.
    fileGlobs: []const []const u8 = &.{},
    /// Radius of the nearby-lines fallback used when no single line contains every term (0 = disabled).
    nearbyLines: u32 = 15,
};

pub const FrameSender = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, json_text: []const u8) anyerror!void,

    pub fn send(self: FrameSender, json_text: []const u8) !void {
        return self.sendFn(self.ctx, json_text);
    }
};

pub const HitSpan = struct {
    start: usize,
    end: usize,
};

pub const HitItem = struct {
    file: []const u8,
    line: u64,
    col: u64,
    text: []const u8,
    prevText: ?[]const u8 = null,
    nextText: ?[]const u8 = null,
    replaced: ?[]const u8,
    isContext: bool,
    spans: []const HitSpan,
};

pub const HitsFrame = struct {
    type: []const u8 = "hits",
    id: u64,
    items: []const HitItem,
};

pub const ProgressFrame = struct {
    type: []const u8 = "progress",
    id: u64,
    filesSearched: u64,
    filesMatched: u64,
    matches: u64,
    bytesSearched: u64,
};

pub const DoneFrame = struct {
    type: []const u8 = "done",
    id: u64,
    elapsedMs: f64,
    filesSearched: u64,
    filesMatched: u64,
    totalMatches: u64,
    matchedLines: u64,
    bytesSearched: u64,
    limitHit: []const u8,
    searchCount: u64 = 0,
    cacheHit: []const u8 = "none",
    /// Non-zero when results come from the nearby-lines fallback (terms spread over ±N lines, not one line).
    nearbyLines: u32 = 0,
};

pub const ErrorFrame = struct {
    type: []const u8 = "error",
    id: u64,
    message: []const u8,
};

const MatcherUnion = union(enum) {
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

fn hasAsciiUpper(s: []const u8) bool {
    for (s) |c| {
        if (c >= 'A' and c <= 'Z') return true;
    }
    return false;
}

const ScopedModifier = struct {
    pattern: []const u8,
    case_mode: libwebgrep.CaseMode,
};

fn escapeRegexLiteralAlloc(arena: std.mem.Allocator, lit: []const u8) ![]const u8 {
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
fn parseScopedModifier(
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

/// Computes the SIMD prefilter selectivity score for a compiled regex (`libwebgrep v0.4.1`).
/// Higher scores indicate stronger fixed-literal or Teddy multi-literal anchors (`Finder` / `Multi` at 20+ GB/s)
/// and Ahead-of-Time determinized `BoundedDfa` tables (`precomputed_dfa`), while unanchored NFAs score 1..3.
fn computeRegexSelectivity(re: *const libwebgrep.Regex) usize {
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

fn computeLiteralSelectivity(lit: []const u8) usize {
    return lit.len * 10 + 5;
}

pub fn executeSearchJson(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    registry: ?*source_registry.SourceRegistry,
    raw_json: []const u8,
    cancel_flag: *const std.atomic.Value(bool),
    sender: FrameSender,
) !void {
    var parsed = std.json.parseFromSlice(SearchRequest, gpa, raw_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        try sendError(gpa, sender, 0, @errorName(err));
        return;
    };
    defer parsed.deinit();

    try executeSearchWithRegistry(gpa, io, root_dir, registry, parsed.value, cancel_flag, sender);
}

pub fn executeSearch(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    req: SearchRequest,
    cancel_flag: *const std.atomic.Value(bool),
    sender: FrameSender,
) !void {
    return executeSearchWithRegistry(gpa, io, root_dir, null, req, cancel_flag, sender);
}

pub fn executeSearchWithRegistry(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    registry: ?*source_registry.SourceRegistry,
    req: SearchRequest,
    cancel_flag: *const std.atomic.Value(bool),
    sender: FrameSender,
) !void {
    const start_ts = std.Io.Clock.awake.now(io);
    const eff_time_start_ns: u64 = if (req.timeStartNs > 0) req.timeStartNs else req.timeStartMs *| 1_000_000;
    const eff_time_end_ns: u64 = if (req.timeEndNs > 0) req.timeEndNs else req.timeEndMs *| 1_000_000;
    const has_time_filter = (eff_time_start_ns > 0 or eff_time_end_ns > 0);

    // If pattern is empty and neither invert, contains, nor time filter is active, complete immediately with 0 hits.
    if (req.pattern.len == 0 and !req.invert and req.contains.len == 0 and !has_time_filter) {
        const elapsed_ns = start_ts.untilNow(io, .awake).toNanoseconds();
        const elapsed_ms: f64 = @as(f64, @floatFromInt(@max(elapsed_ns, 0))) / 1_000_000.0;
        const done_json = try file_api.stringifyAlloc(gpa, DoneFrame{
            .id = req.id,
            .elapsedMs = elapsed_ms,
            .filesSearched = 0,
            .filesMatched = 0,
            .totalMatches = 0,
            .matchedLines = 0,
            .bytesSearched = 0,
            .limitHit = "none",
        });
        defer gpa.free(done_json);
        try sender.send(done_json);
        return;
    }

    var job_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer job_arena_state.deinit();
    const job_arena = job_arena_state.allocator();

    const case_mode = parseCaseMode(req.case);
    const is_regex_mode = std.mem.eql(u8, req.mode, "regex");

    var literal_contains_list: std.ArrayList([]const u8) = .empty;
    var literal_excludes_list: std.ArrayList([]const u8) = .empty;
    var contains_regexes: std.ArrayList(libwebgrep.Regex) = .empty;
    defer {
        for (contains_regexes.items) |*re| re.deinit();
        contains_regexes.deinit(gpa);
    }
    var excludes_regexes: std.ArrayList(libwebgrep.Regex) = .empty;
    defer {
        for (excludes_regexes.items) |*re| re.deinit();
        excludes_regexes.deinit(gpa);
    }

    const can_reorder_predicates = !std.mem.eql(u8, req.mode, "multi") and
        !req.wholeWord and
        !req.wholeLine and
        !req.invert and
        (req.replacement == null or req.replacement.?.len == 0) and
        req.pattern.len > 0 and
        req.contains.len > 0;

    var swapped_primary_regex_first: bool = false;
    var swapped_primary_finder: ?libwebgrep.Finder = null;

    var matcher: MatcherUnion = blk: {
        if (std.mem.eql(u8, req.mode, "multi")) {
            var parts: std.ArrayList([]const u8) = .empty;
            var start: usize = 0;
            var i: usize = 0;
            while (i <= req.pattern.len) : (i += 1) {
                if (i == req.pattern.len or req.pattern[i] == '\n' or req.pattern[i] == '|') {
                    var seg = req.pattern[start..i];
                    if (seg.len > 0 and seg[seg.len - 1] == '\r') seg = seg[0 .. seg.len - 1];
                    if (seg.len > 0) {
                        try parts.append(job_arena, seg);
                    }
                    start = i + 1;
                }
            }
            if (parts.items.len == 0) {
                const elapsed_ns = start_ts.untilNow(io, .awake).toNanoseconds();
                const elapsed_ms: f64 = @as(f64, @floatFromInt(@max(elapsed_ns, 0))) / 1_000_000.0;
                const done_json = try file_api.stringifyAlloc(gpa, DoneFrame{
                    .id = req.id,
                    .elapsedMs = elapsed_ms,
                    .filesSearched = 0,
                    .filesMatched = 0,
                    .totalMatches = 0,
                    .matchedLines = 0,
                    .bytesSearched = 0,
                    .limitHit = "none",
                });
                defer gpa.free(done_json);
                try sender.send(done_json);
                return;
            }
            const m = libwebgrep.Multi.init(gpa, parts.items, .{ .case = case_mode }) catch |err| {
                try sendError(gpa, sender, req.id, @errorName(err));
                return;
            };
            break :blk .{ .multi = m };
        } else if (can_reorder_predicates) {
            // Cost-Based Selectivity Planner:
            // Evaluate all positive predicates (`req.pattern` + `req.contains`), classify each as
            // either a compiled `Regex` or a literal, and elect the highest-selectivity predicate
            // (with deterministic lexicographical tie-breaking) as the primary SIMD scanner (`matcher`).
            const CandidateKind = union(enum) {
                literal: []const u8,
                regex: libwebgrep.Regex,
            };
            const Candidate = struct {
                raw: []const u8,
                score: usize,
                kind: CandidateKind,
            };
            var candidates: std.ArrayList(Candidate) = .empty;
            errdefer {
                for (candidates.items) |*c| {
                    switch (c.kind) {
                        .regex => |*re| re.deinit(),
                        .literal => {},
                    }
                }
                candidates.deinit(gpa);
            }

            const classifyTerm = struct {
                fn run(
                    alloc: std.mem.Allocator,
                    arena_alloc: std.mem.Allocator,
                    raw_pat: []const u8,
                    regex_mode: bool,
                    cm: libwebgrep.CaseMode,
                ) Candidate {
                    if (parseScopedModifier(arena_alloc, raw_pat, cm)) |scoped_spec| {
                        if (libwebgrep.Regex.init(alloc, scoped_spec.pattern, .{ .case = scoped_spec.case_mode })) |re| {
                            return .{
                                .raw = raw_pat,
                                .score = computeRegexSelectivity(&re),
                                .kind = .{ .regex = re },
                            };
                        } else |_| {}
                    }
                    if (regex_mode and hasRegexMeta(raw_pat)) {
                        if (libwebgrep.Regex.init(alloc, raw_pat, .{ .case = cm })) |re| {
                            return .{
                                .raw = raw_pat,
                                .score = computeRegexSelectivity(&re),
                                .kind = .{ .regex = re },
                            };
                        } else |_| {}
                    }
                    return .{
                        .raw = raw_pat,
                        .score = computeLiteralSelectivity(raw_pat),
                        .kind = .{ .literal = raw_pat },
                    };
                }
            }.run;

            try candidates.append(gpa, classifyTerm(gpa, job_arena, req.pattern, is_regex_mode, case_mode));
            for (req.contains) |pat| {
                if (pat.len == 0) continue;
                try candidates.append(gpa, classifyTerm(gpa, job_arena, pat, is_regex_mode, case_mode));
            }

            var best_idx: usize = 0;
            for (candidates.items, 0..) |cand, idx| {
                if (idx == 0) continue;
                const best = candidates.items[best_idx];
                if (cand.score > best.score or
                    (cand.score == best.score and std.mem.order(u8, cand.raw, best.raw) == .lt))
                {
                    best_idx = idx;
                }
            }

            for (candidates.items, 0..) |*cand, idx| {
                if (idx == best_idx) continue;
                switch (cand.kind) {
                    .regex => |re| {
                        if (idx == 0) swapped_primary_regex_first = true;
                        try contains_regexes.append(gpa, re);
                    },
                    .literal => |lit| {
                        if (idx == 0) {
                            swapped_primary_finder = libwebgrep.Finder.init(lit, .{ .case = case_mode }) catch null;
                        }
                        try literal_contains_list.append(job_arena, lit);
                    },
                }
            }

            const winner = candidates.items[best_idx];
            candidates.deinit(gpa);

            switch (winner.kind) {
                .regex => |re| break :blk .{ .regex = re },
                .literal => |lit| {
                    const f = libwebgrep.Finder.init(lit, .{ .case = case_mode }) catch |err| {
                        try sendError(gpa, sender, req.id, @errorName(err));
                        return;
                    };
                    break :blk .{ .literal = f };
                },
            }
        } else if (parseScopedModifier(job_arena, req.pattern, case_mode)) |scoped_spec| {
            const re = libwebgrep.Regex.init(gpa, scoped_spec.pattern, .{ .case = scoped_spec.case_mode }) catch |err| {
                try sendError(gpa, sender, req.id, @errorName(err));
                return;
            };
            break :blk .{ .regex = re };
        } else if (req.pattern.len == 0 and has_time_filter) {
            const re = libwebgrep.Regex.init(gpa, "^.", .{ .case = .sensitive }) catch |err| {
                try sendError(gpa, sender, req.id, @errorName(err));
                return;
            };
            break :blk .{ .regex = re };
        } else if (is_regex_mode) {
            const re = libwebgrep.Regex.init(gpa, req.pattern, .{ .case = case_mode }) catch |err| {
                try sendError(gpa, sender, req.id, @errorName(err));
                return;
            };
            break :blk .{ .regex = re };
        } else {
            const f = libwebgrep.Finder.init(req.pattern, .{ .case = case_mode }) catch |err| {
                try sendError(gpa, sender, req.id, @errorName(err));
                return;
            };
            break :blk .{ .literal = f };
        }
    };
    defer matcher.deinit();

    const compiled_globs: []const libwebgrep.walk_glob.Glob = if (req.globs.len > 0)
        libwebgrep.walk_glob.compileGlobs(job_arena, req.globs, .{}) catch |err| {
            try sendError(gpa, sender, req.id, @errorName(err));
            return;
        }
    else
        &.{};

    if (!can_reorder_predicates) {
        for (req.contains) |pat| {
            if (pat.len == 0) continue;
            if (parseScopedModifier(job_arena, pat, case_mode)) |scoped_spec| {
                if (libwebgrep.Regex.init(gpa, scoped_spec.pattern, .{ .case = scoped_spec.case_mode })) |re| {
                    try contains_regexes.append(gpa, re);
                } else |_| {
                    try literal_contains_list.append(job_arena, pat);
                }
            } else if (is_regex_mode and hasRegexMeta(pat)) {
                if (libwebgrep.Regex.init(gpa, pat, .{ .case = case_mode })) |re| {
                    try contains_regexes.append(gpa, re);
                } else |_| {
                    try literal_contains_list.append(job_arena, pat);
                }
            } else {
                try literal_contains_list.append(job_arena, pat);
            }
        }
    }

    for (req.excludes) |pat| {
        if (pat.len == 0) continue;
        if (parseScopedModifier(job_arena, pat, case_mode)) |scoped_spec| {
            if (libwebgrep.Regex.init(gpa, scoped_spec.pattern, .{ .case = scoped_spec.case_mode })) |re| {
                try excludes_regexes.append(gpa, re);
            } else |_| {
                try literal_excludes_list.append(job_arena, pat);
            }
        } else if (is_regex_mode and hasRegexMeta(pat)) {
            if (libwebgrep.Regex.init(gpa, pat, .{ .case = case_mode })) |re| {
                try excludes_regexes.append(gpa, re);
            } else |_| {
                try literal_excludes_list.append(job_arena, pat);
            }
        } else {
            try literal_excludes_list.append(job_arena, pat);
        }
    }

    const base_literal_contains = literal_contains_list.items;
    const base_literal_excludes = literal_excludes_list.items;

    var runner = JobRunner{
        .gpa = gpa,
        .job_arena = job_arena,
        .io = io,
        .root_dir = root_dir,
        .registry = registry,
        .req = req,
        .matcher = &matcher,
        .compiled_globs = compiled_globs,
        .contains_regexes = contains_regexes.items,
        .excludes_regexes = excludes_regexes.items,
        .swapped_primary_regex_first = swapped_primary_regex_first,
        .swapped_primary_finder = swapped_primary_finder,
        .cancel_flag = cancel_flag,
        .sender = sender,
        .last_progress_ts = start_ts,
        .time_start_ns = eff_time_start_ns,
        .time_end_ns = eff_time_end_ns,
    };
    defer runner.file_tasks.deinit(job_arena);
    defer runner.active_task_indices.deinit(job_arena);

    if (registry) |reg| {
        const all_sources = try reg.snapshotAllSources(job_arena, io);
        for (all_sources) |src| {
            if (runner.shouldStop()) break;
            if (!src.enabled) {
                var explicitly_selected = false;
                for (req.sources) |sid| {
                    if (std.mem.eql(u8, sid, src.id) or std.ascii.eqlIgnoreCase(sid, src.name)) {
                        explicitly_selected = true;
                        break;
                    }
                }
                if (!explicitly_selected) {
                    for (req.globs) |raw_rule| {
                        const trimmed = std.mem.trim(u8, raw_rule, " \t");
                        if (trimmed.len == 0 or trimmed[0] == '!') continue;
                        var it = std.mem.splitScalar(u8, trimmed, ',');
                        while (it.next()) |part| {
                            if (JobRunner.matchesProjectScopeToken(src.id, src.name, part)) {
                                explicitly_selected = true;
                                break;
                            }
                        }
                        if (explicitly_selected) break;
                    }
                }
                if (!explicitly_selected) continue;
            }
            if (req.sources.len > 0) {
                var matched_src = false;
                for (req.sources) |sid| {
                    if (std.mem.eql(u8, sid, src.id) or std.ascii.eqlIgnoreCase(sid, src.name)) {
                        matched_src = true;
                        break;
                    }
                }
                if (!matched_src) {
                    for (req.globs) |raw_rule| {
                        const trimmed = std.mem.trim(u8, raw_rule, " \t");
                        if (trimmed.len == 0 or trimmed[0] == '!') continue;
                        var it = std.mem.splitScalar(u8, trimmed, ',');
                        while (it.next()) |part| {
                            if (JobRunner.matchesProjectScopeToken(src.id, src.name, part)) {
                                matched_src = true;
                                break;
                            }
                        }
                        if (matched_src) break;
                    }
                }
                if (!matched_src) continue;
            }

            if (!runner.sourceMatchesProjectFilters(src.id, src.name)) continue;

            if (!std.mem.eql(u8, src.kind, "file")) {
                if (std.Io.Dir.cwd().openDir(io, src.path, .{ .iterate = true })) |opened_dir| {
                    var d = opened_dir;
                    defer d.close(io);
                    try runner.walkDirectoryForSource(
                        d,
                        src.path,
                        src.id,
                        src.name,
                        base_literal_contains,
                        base_literal_excludes,
                        "",
                    );
                    continue;
                } else |_| {}
            }

            // Single-file data source (`kind == "file"` or path pointing directly to a file)
            const parent_dir_path = std.fs.path.dirname(src.path) orelse ".";
            const base_name = std.fs.path.basename(src.path);
            if (base_name.len > 0 and runner.fileMatchesSourceFilters(src.id, src.name, base_name)) {
                const st = std.Io.Dir.cwd().statFile(io, src.path, .{}) catch continue;
                const virtual_rel = if (src.name.len > 0)
                    try std.fmt.allocPrint(job_arena, "{s}/{s}", .{ src.name, base_name })
                else
                    base_name;
                try runner.enqueueTask(
                    parent_dir_path,
                    base_name,
                    virtual_rel,
                    base_name,
                    src.id,
                    src.name,
                    base_literal_contains,
                    base_literal_excludes,
                    st.mtime.nanoseconds,
                    st.size,
                    st.inode,
                );
            }
        }
    } else if (req.paths.len > 0) {
        for (req.paths) |raw_p| {
            if (runner.shouldStop()) break;
            const clean_p = file_api.sanitizeRelPath(raw_p) catch continue;
            if (clean_p.len == 0) {
                try runner.walkDirectoryForSource(root_dir, null, "", "", base_literal_contains, base_literal_excludes, "");
                continue;
            }
            if (root_dir.openDir(io, clean_p, .{ .iterate = true })) |opened_dir| {
                var sub_dir = opened_dir;
                defer sub_dir.close(io);
                try runner.walkDirectoryForSource(sub_dir, null, "", "", base_literal_contains, base_literal_excludes, clean_p);
            } else |_| {
                const base = std.fs.path.basename(clean_p);
                if (!runner.fileMatchesSourceFilters("", "", base)) continue;
                const st = root_dir.statFile(io, clean_p, .{}) catch continue;
                try runner.enqueueTask(null, clean_p, clean_p, base, "", "", base_literal_contains, base_literal_excludes, st.mtime.nanoseconds, st.size, st.inode);
            }
        }
    } else {
        try runner.walkDirectoryForSource(root_dir, null, "", "", base_literal_contains, base_literal_excludes, "");
    }

    if (!cancel_flag.load(.acquire)) {
        runner.runParallelWorkers();
    }

    if (cancel_flag.load(.acquire)) return;

    const elapsed_ns = start_ts.untilNow(io, .awake).toNanoseconds();
    const elapsed_ms: f64 = @as(f64, @floatFromInt(@max(elapsed_ns, 0))) / 1_000_000.0;
    const limit_hit: []const u8 = if (runner.hit_max_results.load(.acquire))
        "max_results"
    else
        "none";

    // Commit L1/L2 cache BEFORE sending DoneFrame so any immediate follow-up query
    // (even on a separate WebSocket connection) is guaranteed to hit L1/L2.
    runner.commitCacheAfterDone();

    const site_search_count: u64 = if (registry) |reg| reg.recordSearch(io) else 0;

    const done_json = try file_api.stringifyAlloc(gpa, DoneFrame{
        .id = req.id,
        .elapsedMs = elapsed_ms,
        .filesSearched = runner.files_searched.load(.acquire),
        .filesMatched = runner.files_matched.load(.acquire),
        .totalMatches = runner.total_matches.load(.acquire),
        .matchedLines = runner.matched_lines.load(.acquire),
        .bytesSearched = runner.bytes_searched.load(.acquire),
        .limitHit = limit_hit,
        .searchCount = site_search_count,
        .cacheHit = runner.cache_hit_tier,
        .nearbyLines = if (runner.nearby_used) req.nearbyLines else 0,
    });
    defer gpa.free(done_json);
    try sender.send(done_json);
}

fn sendError(gpa: std.mem.Allocator, sender: FrameSender, id: u64, msg: []const u8) !void {
    const err_json = try file_api.stringifyAlloc(gpa, ErrorFrame{
        .id = id,
        .message = msg,
    });
    defer gpa.free(err_json);
    try sender.send(err_json);
}

const DirEntryItem = struct {
    name: []const u8,
    is_dir: bool,

    pub fn lessThan(_: void, a: DirEntryItem, b: DirEntryItem) bool {
        if (a.is_dir != b.is_dir) return !a.is_dir; // search files in dir first, then recurse subdirs
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

const FileTask = struct {
    parent_dir_path: ?[]const u8 = null,
    open_sub_path: []const u8,
    rel_path: []const u8,
    base_name: []const u8,
    source_id: []const u8 = "",
    source_name: []const u8 = "",
    effective_contains: []const []const u8 = &.{},
    effective_excludes: []const []const u8 = &.{},
    mtime_ns: i96 = 0,
    file_size: u64 = 0,
    inode: std.Io.File.INode = 0,
    access_heat: u64 = 0,
    base_heat: u64 = 100,
    heat_score: u64 = 100,
    soft_quota: u64 = 0,
    emitted_in_file: u64 = 0,
    resume_after_line: u64 = 0,
    phase_bytes: u64 = 0,
    paused_at_soft_quota: bool = false,
    counted_file_searched: bool = false,
    counted_file_matched: bool = false,

    pub fn hotterThan(_: void, a: FileTask, b: FileTask) bool {
        if (a.heat_score != b.heat_score) return a.heat_score > b.heat_score;
        if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
        return std.mem.order(u8, a.rel_path, b.rel_path) == .lt;
    }
};

const JobRunner = struct {
    gpa: std.mem.Allocator,
    job_arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    registry: ?*source_registry.SourceRegistry = null,
    req: SearchRequest,
    matcher: *MatcherUnion,
    compiled_globs: []const libwebgrep.walk_glob.Glob,
    contains_regexes: []const libwebgrep.Regex = &.{},
    excludes_regexes: []const libwebgrep.Regex = &.{},
    swapped_primary_regex_first: bool = false,
    swapped_primary_finder: ?libwebgrep.Finder = null,
    cancel_flag: *const std.atomic.Value(bool),
    sender: FrameSender,
    time_start_ns: u64 = 0,
    time_end_ns: u64 = 0,

    file_tasks: std.ArrayList(FileTask) = .empty,
    active_task_indices: std.ArrayList(usize) = .empty,
    next_task_idx: std.atomic.Value(usize) = .init(0),
    active_worker_count: u32 = 1,

    batches_flushed: std.atomic.Value(u64) = .init(0),
    files_searched: std.atomic.Value(u64) = .init(0),
    files_matched: std.atomic.Value(u64) = .init(0),
    total_matches: std.atomic.Value(u64) = .init(0),
    matched_lines: std.atomic.Value(u64) = .init(0),
    bytes_searched: std.atomic.Value(u64) = .init(0),
    hit_max_results: std.atomic.Value(bool) = .init(false),
    send_failed: std.atomic.Value(bool) = .init(false),

    progress_mutex: std.Io.Mutex = .init,
    last_progress_ts: std.Io.Timestamp,

    cache_hit_tier: []const u8 = "none",
    nearby_used: bool = false,
    pruned_by_negative_cache: std.atomic.Value(bool) = .init(false),
    had_non_exact_line: std.atomic.Value(bool) = .init(false),
    had_scan_error: std.atomic.Value(bool) = .init(false),
    collected_hits_mutex: std.Io.Mutex = .init,
    collected_hits: std.ArrayList(HitItem) = .empty,
    collected_hits_overflow: bool = false,
    should_commit_cache: bool = false,
    pending_exact_hash: u64 = 0,
    pending_tasks_fingerprint: u64 = 0,
    pending_heat_epoch: u64 = 0,

    fn shouldStop(self: *const JobRunner) bool {
        return self.hit_max_results.load(.acquire) or
            self.send_failed.load(.acquire) or
            self.cancel_flag.load(.acquire);
    }

    fn enqueueTask(
        self: *JobRunner,
        parent_dir_path: ?[]const u8,
        open_sub_path: []const u8,
        rel_path: []const u8,
        base_name: []const u8,
        source_id: []const u8,
        source_name: []const u8,
        effective_contains: []const []const u8,
        effective_excludes: []const []const u8,
        mtime_ns: i96,
        file_size: u64,
        inode: std.Io.File.INode,
    ) !void {
        if (!self.fileMatchesPathGlobs(rel_path, base_name)) return;
        const parent_copy = if (parent_dir_path) |p| try self.job_arena.dupe(u8, p) else null;
        const sub_copy = try self.job_arena.dupe(u8, open_sub_path);
        const rel_copy = if (std.mem.eql(u8, open_sub_path, rel_path))
            sub_copy
        else
            try self.job_arena.dupe(u8, rel_path);
        const base_copy = try self.job_arena.dupe(u8, base_name);
        try self.file_tasks.append(self.job_arena, .{
            .parent_dir_path = parent_copy,
            .open_sub_path = sub_copy,
            .rel_path = rel_copy,
            .base_name = base_copy,
            .source_id = source_id,
            .source_name = source_name,
            .effective_contains = effective_contains,
            .effective_excludes = effective_excludes,
            .mtime_ns = mtime_ns,
            .file_size = file_size,
            .inode = inode,
            .access_heat = 0,
        });
    }

    fn hasGlobMetachar(s: []const u8) bool {
        for (s) |c| {
            if (c == '*' or c == '?' or c == '[' or c == '{') return true;
        }
        return false;
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    /// Applies `req.fileGlobs` (`@*.rs`, `@src/`, `-@*_test.go`) to a candidate file.
    /// Positive patterns are OR-ed (at least one must match when any exist); `!` negatives always exclude.
    fn fileMatchesPathGlobs(self: *const JobRunner, rel_path: []const u8, base_name: []const u8) bool {
        if (self.req.fileGlobs.len == 0) return true;
        var has_positive = false;
        var positive_hit = false;
        for (self.req.fileGlobs) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t");
            const is_neg = trimmed.len > 0 and trimmed[0] == '!';
            const body = if (is_neg) trimmed[1..] else trimmed;
            if (body.len == 0) continue;
            const hit = matchesPathPattern(rel_path, base_name, body);
            if (is_neg) {
                if (hit) return false;
            } else {
                has_positive = true;
                if (hit) positive_hit = true;
            }
        }
        return !has_positive or positive_hit;
    }

    /// Matches one `@` file/path pattern (case-insensitive):
    /// - no glob metacharacters (`@src/`)  → substring of the relative path;
    /// - no `/` (`@*.rs`, `@*_test.go`)    → glob against the file name;
    /// - with `/` (`@src/*.rs`)            → glob against the relative path at any depth, since users write
    ///   paths relative to the project rather than to the index root.
    fn matchesPathPattern(rel_path: []const u8, base_name: []const u8, pattern: []const u8) bool {
        const clean = std.mem.trim(u8, pattern, " \t");
        if (clean.len == 0) return true;
        if (!hasGlobMetachar(clean)) return containsIgnoreCase(rel_path, clean);

        const glob_lib = libwebgrep.walk_glob;
        if (std.mem.indexOfScalar(u8, clean, '/') == null) {
            return glob_lib.matches(glob_lib.classifyWithCase(clean, true), rel_path, base_name, false);
        }
        var buf: [512]u8 = undefined;
        const rooted = std.mem.trimStart(u8, clean, "/");
        const anywhere = if (std.mem.startsWith(u8, rooted, "**/"))
            rooted
        else
            std.fmt.bufPrint(&buf, "**/{s}", .{rooted}) catch return false;
        var g = glob_lib.classifyWithCase(anywhere, true);
        g.anchored = true;
        return glob_lib.matches(g, rel_path, base_name, false);
    }

    /// Checks whether all '-' or '/' separated segments of `expr` appear in order inside `haystack`.
    fn matchesOrderedPathSegments(haystack: []const u8, expr: []const u8) bool {
        var pos: usize = 0;
        var start: usize = 0;
        var seg_count: usize = 0;
        var i: usize = 0;
        while (i <= expr.len) : (i += 1) {
            if (i == expr.len or expr[i] == '-' or expr[i] == '/') {
                const seg = expr[start..i];
                start = i + 1;
                if (seg.len == 0) continue;
                seg_count += 1;

                var found_at: ?usize = null;
                if (haystack.len >= pos + seg.len) {
                    var k: usize = pos;
                    while (k <= haystack.len - needleLen(seg)) : (k += 1) {
                        if (std.ascii.eqlIgnoreCase(haystack[k .. k + seg.len], seg)) {
                            found_at = k;
                            break;
                        }
                    }
                }
                if (found_at) |idx| {
                    pos = idx + seg.len;
                } else {
                    return false;
                }
            }
        }
        return seg_count > 0;
    }

    inline fn needleLen(s: []const u8) usize {
        return s.len;
    }

    /// Project-only `@` matcher: matches a project by its `name` or UUID `id` (case-insensitive).
    pub fn matchesProjectScopeToken(
        src_id: []const u8,
        src_name: []const u8,
        token: []const u8,
    ) bool {
        const clean = std.mem.trim(u8, token, " \t@/");
        if (clean.len == 0) return true;
        if (src_name.len > 0 and std.ascii.eqlIgnoreCase(clean, src_name)) return true;
        if (src_id.len > 0 and std.ascii.eqlIgnoreCase(clean, src_id)) return true;
        return false;
    }

    fn sourceMatchesProjectFilters(
        self: *const JobRunner,
        src_id: []const u8,
        src_name: []const u8,
    ) bool {
        if (src_id.len == 0 and src_name.len == 0) return true;

        // Evaluate each @project filter in req.globs with progressive AND semantics
        for (self.req.globs) |raw_rule| {
            const trimmed = std.mem.trim(u8, raw_rule, " \t");
            if (trimmed.len == 0) continue;

            const is_neg = trimmed[0] == '!';
            const body = if (is_neg) trimmed[1..] else trimmed;
            if (body.len == 0) continue;

            // Comma-separated items inside a single @projA,projB token act as OR
            var matched_any = false;
            var it = std.mem.splitScalar(u8, body, ',');
            while (it.next()) |part| {
                if (matchesProjectScopeToken(src_id, src_name, part)) {
                    matched_any = true;
                    break;
                }
            }

            if (is_neg) {
                if (matched_any) return false;
            } else {
                if (!matched_any) return false;
            }
        }
        return true;
    }

    fn fileMatchesSourceFilters(
        self: *const JobRunner,
        src_id: []const u8,
        src_name: []const u8,
        base_name: []const u8,
    ) bool {
        if (self.req.types.len > 0) {
            if (!libwebgrep.walk_types.matches(self.req.types, base_name)) return false;
        }
        if (self.time_start_ns > 0 or self.time_end_ns > 0) {
            if (ingestor.parseSealedSegmentTimeRange(base_name)) |seg| {
                if (self.time_start_ns > 0 and seg.max_ns < self.time_start_ns) return false;
                if (self.time_end_ns > 0 and seg.min_ns > self.time_end_ns) return false;
            }
        }
        return self.sourceMatchesProjectFilters(src_id, src_name);
    }

    fn walkDirectoryForSource(
        self: *JobRunner,
        dir: std.Io.Dir,
        parent_root_override: ?[]const u8,
        src_id: []const u8,
        src_name: []const u8,
        effective_contains: []const []const u8,
        effective_excludes: []const []const u8,
        rel_dir: []const u8,
    ) !void {
        if (self.shouldStop()) return;

        var dir_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer dir_arena_state.deinit();
        const dir_arena = dir_arena_state.allocator();

        const dir_stat = dir.stat(self.io) catch null;
        const dir_cache_key: []const u8 = if (self.registry != null and dir_stat != null) blk: {
            const root_tag = parent_root_override orelse src_id;
            if (rel_dir.len == 0) break :blk root_tag;
            break :blk try std.fmt.allocPrint(dir_arena, "{s}/{s}", .{ root_tag, rel_dir });
        } else "";

        var entries: std.ArrayList(DirEntryItem) = .empty;
        var loaded_from_dir_cache = false;

        if (self.registry) |reg| {
            if (dir_stat) |dst| {
                if (reg.search_cache.lookupDirTopology(
                    self.io,
                    dir_arena,
                    dir_cache_key,
                    self.req.hidden,
                    dst.mtime.nanoseconds,
                    dst.inode,
                )) |cached_entries| {
                    try entries.ensureTotalCapacity(dir_arena, cached_entries.len);
                    for (cached_entries) |ce| {
                        entries.appendAssumeCapacity(.{
                            .name = ce.name,
                            .is_dir = ce.is_dir,
                        });
                    }
                    loaded_from_dir_cache = true;
                }
            }
        }

        if (!loaded_from_dir_cache) {
            var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
            var lister = libwebgrep.walk_list.Lister.init(dir, &scratch);
            var batch: [128]std.Io.Dir.Entry = undefined;
            var has_symlink = false;

            while (true) {
                if (self.shouldStop()) return;
                const count = lister.fill(self.io, &batch) catch break;
                if (count == 0) break;

                for (batch[0..count]) |item| {
                    if (item.name.len == 0) continue;
                    if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
                    if (file_api.isAlwaysSkippedDir(item.name)) continue;
                    if (!self.req.hidden and item.name[0] == '.') continue;

                    var is_dir = item.kind == .directory;
                    var is_file = item.kind == .file;
                    if (item.kind == .sym_link or item.kind == .unknown) {
                        has_symlink = true;
                        const st = dir.statFile(self.io, item.name, .{}) catch continue;
                        is_dir = st.kind == .directory;
                        is_file = st.kind == .file;
                    }
                    if (!is_dir and !is_file) continue;

                    const name_copy = try dir_arena.dupe(u8, item.name);
                    try entries.append(dir_arena, .{
                        .name = name_copy,
                        .is_dir = is_dir,
                    });
                }
            }

            std.mem.sort(DirEntryItem, entries.items, {}, DirEntryItem.lessThan);

            if (!has_symlink) {
                if (self.registry) |reg| {
                    if (dir_stat) |dst| {
                        const cache_slice = dir_arena.alloc(search_cache.CachedDirEntry, entries.items.len) catch null;
                        if (cache_slice) |cs| {
                            for (entries.items, 0..) |e, i| {
                                cs[i] = .{ .name = e.name, .is_dir = e.is_dir };
                            }
                            reg.search_cache.storeDirTopology(
                                self.gpa,
                                self.io,
                                dir_cache_key,
                                self.req.hidden,
                                dst.mtime.nanoseconds,
                                dst.inode,
                                cs,
                            );
                        }
                    }
                }
            }
        }

        for (entries.items) |entry| {
            if (self.shouldStop()) return;

            const child_rel = if (rel_dir.len == 0)
                entry.name
            else
                try std.fmt.allocPrint(dir_arena, "{s}/{s}", .{ rel_dir, entry.name });

            if (entry.is_dir) {
                var sub_dir = dir.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
                defer sub_dir.close(self.io);

                try self.walkDirectoryForSource(
                    sub_dir,
                    parent_root_override,
                    src_id,
                    src_name,
                    effective_contains,
                    effective_excludes,
                    child_rel,
                );
            } else {
                const virtual_rel = if (src_name.len > 0)
                    try std.fmt.allocPrint(dir_arena, "{s}/{s}", .{ src_name, child_rel })
                else
                    child_rel;

                if (!self.fileMatchesSourceFilters(src_id, src_name, entry.name)) continue;

                const st = dir.statFile(self.io, entry.name, .{}) catch continue;

                try self.enqueueTask(
                    parent_root_override,
                    child_rel,
                    virtual_rel,
                    entry.name,
                    src_id,
                    src_name,
                    effective_contains,
                    effective_excludes,
                    st.mtime.nanoseconds,
                    st.size,
                    st.inode,
                );
            }
        }
    }

    /// Computes initial file heat scores (Recency mtime + User Access Heat), sorts hotter files first,
    /// and assigns Phase 1 heat-proportional soft quotas (`Water-Filling` pass 1).
    fn prepareHeatAndQuotas(self: *JobRunner) void {
        const total_files = self.file_tasks.items.len;
        if (total_files == 0) return;

        if (total_files == 1) {
            self.file_tasks.items[0].soft_quota = 0; // Single file gets 100% of maxResults directly
            return;
        }

        var min_mtime: i96 = std.math.maxInt(i96);
        var max_mtime: i96 = std.math.minInt(i96);
        var has_mtime = false;

        for (self.file_tasks.items) |t| {
            if (t.mtime_ns > 0) {
                has_mtime = true;
                if (t.mtime_ns < min_mtime) min_mtime = t.mtime_ns;
                if (t.mtime_ns > max_mtime) max_mtime = t.mtime_ns;
            }
        }

        for (self.file_tasks.items) |*t| {
            t.access_heat = if (self.registry) |reg|
                reg.getFileHeat(self.io, t.rel_path)
            else
                0;
            var recency_heat: u64 = 150;
            if (has_mtime and max_mtime > min_mtime and t.mtime_ns >= min_mtime) {
                const span: u128 = @intCast(max_mtime - min_mtime);
                const offset: u128 = @intCast(t.mtime_ns - min_mtime);
                recency_heat = @intCast((offset * 300) / span);
            }
            const base = 100 + recency_heat + @min(@as(u64, 2000), t.access_heat);
            t.base_heat = base;
            t.heat_score = base;
        }

        // Priority scheduling: hotter files are placed at the front of the queue so they are scanned first
        std.mem.sort(FileTask, self.file_tasks.items, {}, FileTask.hotterThan);

        const max_res = self.req.maxResults;
        if (max_res == 0) {
            for (self.file_tasks.items) |*t| t.soft_quota = 0;
            return;
        }

        var total_heat: u64 = 0;
        for (self.file_tasks.items) |t| {
            total_heat +|= t.heat_score;
        }
        if (total_heat == 0) total_heat = 1;

        const n_u64: u64 = @intCast(total_files);
        const min_floor: u64 = @min(max_res, @max(@as(u64, 1), max_res / @max(@as(u64, 1), n_u64 * 2)));

        for (self.file_tasks.items) |*t| {
            const raw_share = (max_res * t.heat_score) / total_heat;
            t.soft_quota = @max(min_floor, @min(max_res, raw_share));
        }
    }

    fn executeWorkerPass(self: *JobRunner) void {
        const active_count = self.active_task_indices.items.len;
        if (active_count == 0 or self.shouldStop()) return;

        self.next_task_idx.store(0, .release);

        const cpu_count = std.Thread.getCpuCount() catch 4;
        const desired_workers = @min(@max(cpu_count, 4), @min(active_count, 8));
        self.active_worker_count = @intCast(@max(desired_workers, 1));

        if (desired_workers <= 1) {
            self.workerThreadMain();
            return;
        }

        var threads: [8]?std.Thread = .{ null, null, null, null, null, null, null, null };
        const spawn_count = desired_workers - 1;
        for (0..spawn_count) |i| {
            threads[i] = std.Thread.spawn(.{}, JobRunner.workerThreadMain, .{self}) catch null;
        }

        self.workerThreadMain();

        for (0..spawn_count) |i| {
            if (threads[i]) |t| t.join();
        }
    }

    fn computeTasksFingerprint(self: *const JobRunner) u64 {
        var acc: u64 = @intCast(self.file_tasks.items.len *% 0x9e3779b97f4a7c15);
        for (self.file_tasks.items) |t| {
            const mtime_u64: u64 = @bitCast(@as(i64, @truncate(t.mtime_ns)));
            const ino_u64: u64 = @intCast(t.inode);
            const seed = mtime_u64 ^ (t.file_size *% 0x517cc1b727220a95) ^ (ino_u64 *% 0x94d049bb133111eb);
            const h = std.hash.Wyhash.hash(seed, t.rel_path);
            acc +%= h ^ (h >> 29);
        }
        return acc;
    }

    fn computeExactQueryHash(self: *const JobRunner, tasks_fingerprint: u64, heat_epoch: u64) u64 {
        var hasher = std.hash.Wyhash.init(tasks_fingerprint ^ (heat_epoch *% 0x517cc1b727220a95));
        hasher.update(self.req.pattern);
        hasher.update("\x00");
        hasher.update(self.req.mode);
        hasher.update("\x00");
        hasher.update(self.req.case);
        hasher.update("\x00");
        const flags: [6]u8 = .{
            @intFromBool(self.req.wholeWord),
            @intFromBool(self.req.wholeLine),
            @intFromBool(self.req.invert),
            @intFromBool(self.req.hidden),
            @intFromBool(self.req.respectIgnore),
            @intCast(self.req.context & 0xff),
        };
        hasher.update(&flags);
        hasher.update(std.mem.asBytes(&self.req.maxResults));
        hasher.update(std.mem.asBytes(&self.time_start_ns));
        hasher.update(std.mem.asBytes(&self.time_end_ns));
        if (self.req.replacement) |rep| {
            hasher.update(rep);
        }
        hasher.update("\x00");
        for (self.req.contains) |s| {
            hasher.update(s);
            hasher.update("\xff");
        }
        hasher.update("\x00");
        for (self.req.excludes) |s| {
            hasher.update(s);
            hasher.update("\xff");
        }
        hasher.update("\x00");
        for (self.req.globs) |s| {
            hasher.update(s);
            hasher.update("\xff");
        }
        return hasher.final();
    }

    fn flushItemsSliceToSender(self: *JobRunner, items: []const HitItem) void {
        const chunk_size: usize = 256;
        var offset: usize = 0;
        while (offset < items.len and !self.shouldStop()) {
            const end = @min(offset + chunk_size, items.len);
            const hits_json = file_api.stringifyAlloc(self.gpa, HitsFrame{
                .id = self.req.id,
                .items = items[offset..end],
            }) catch {
                self.send_failed.store(true, .release);
                return;
            };
            defer self.gpa.free(hits_json);
            self.sender.send(hits_json) catch {
                self.send_failed.store(true, .release);
                return;
            };
            offset = end;
        }
    }

    fn slicesEqual(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |sa, sb| {
            if (!std.mem.eql(u8, sa, sb)) return false;
        }
        return true;
    }

    fn tryReplayExactCache(self: *JobRunner, exact_hash: u64, tasks_fingerprint: u64, heat_epoch: u64) bool {
        const reg = self.registry orelse return false;
        var raw_items_json: []const u8 = "";
        var has_items = false;
        var files_searched: u64 = 0;
        var files_matched: u64 = 0;
        var total_matches: u64 = 0;
        var matched_lines: u64 = 0;
        var bytes_searched: u64 = 0;
        var limit_hit: bool = false;
        const req_has_replacement = (self.req.replacement != null and self.req.replacement.?.len > 0);

        {
            reg.search_cache.mutex.lockUncancelable(self.io);
            defer reg.search_cache.mutex.unlock(self.io);

            var found_entry: ?*search_cache.CachedQueryEntry = null;
            for (reg.search_cache.entries.items) |*e| {
                if (e.exact_hash != exact_hash or
                    e.tasks_fingerprint != tasks_fingerprint or
                    e.heat_epoch != heat_epoch or
                    e.max_results != self.req.maxResults or
                    e.time_start_ns != self.time_start_ns or
                    e.time_end_ns != self.time_end_ns or
                    e.whole_word != self.req.wholeWord or
                    e.whole_line != self.req.wholeLine or
                    e.invert != self.req.invert or
                    e.context != self.req.context or
                    e.has_replacement != req_has_replacement or
                    e.file_mtimes.len != self.file_tasks.items.len or
                    !std.mem.eql(u8, e.pattern, self.req.pattern) or
                    !std.mem.eql(u8, e.mode, self.req.mode) or
                    !std.mem.eql(u8, e.case_mode, self.req.case) or
                    !slicesEqual(e.contains, self.req.contains) or
                    !slicesEqual(e.excludes, self.req.excludes))
                {
                    continue;
                }

                // 100% collision-free 1:1 verification of all candidate files `(rel_path, mtime_ns, file_size, inode)`
                var files_exact = true;
                for (self.file_tasks.items) |ft| {
                    var matched_file = false;
                    for (e.file_mtimes) |fm| {
                        if (fm.mtime_ns == ft.mtime_ns and
                            fm.file_size == ft.file_size and
                            fm.inode == ft.inode and
                            std.mem.eql(u8, fm.rel_path, ft.rel_path))
                        {
                            matched_file = true;
                            break;
                        }
                    }
                    if (!matched_file) {
                        files_exact = false;
                        break;
                    }
                }
                if (!files_exact) continue;

                found_entry = e;
                break;
            }
            const entry = found_entry orelse return false;
            reg.search_cache.tick +%= 1;
            entry.access_tick = reg.search_cache.tick;

            files_searched = entry.files_searched;
            files_matched = entry.files_matched;
            total_matches = entry.total_matches;
            matched_lines = entry.matched_lines;
            bytes_searched = entry.bytes_searched;
            limit_hit = entry.limit_hit;

            if (entry.items.len > 0 and entry.raw_items_json.len > 2) {
                raw_items_json = self.job_arena.dupe(u8, entry.raw_items_json) catch return false;
                has_items = true;
            }
        }

        self.files_searched.store(files_searched, .release);
        self.files_matched.store(files_matched, .release);
        self.total_matches.store(total_matches, .release);
        self.matched_lines.store(matched_lines, .release);
        self.bytes_searched.store(bytes_searched, .release);
        self.hit_max_results.store(limit_hit, .release);

        if (has_items) {
            const frame_json = std.fmt.allocPrint(
                self.job_arena,
                "{{\"type\":\"hits\",\"id\":{d},\"items\":{s}}}",
                .{ self.req.id, raw_items_json },
            ) catch {
                self.send_failed.store(true, .release);
                return true;
            };
            self.sender.send(frame_json) catch {
                self.send_failed.store(true, .release);
            };
        }
        return true;
    }

    fn sliceIsSubset(sub: []const []const u8, sup: []const []const u8) bool {
        for (sub) |needle| {
            var found = false;
            for (sup) |cand| {
                if (std.mem.eql(u8, needle, cand)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn lineMatchesTaskPredicates(
        self: *const JobRunner,
        task: *const FileTask,
        line_text: []const u8,
        parsed_case: libwebgrep.CaseMode,
        default_case_insensitive: bool,
    ) bool {
        if (self.time_start_ns > 0 or self.time_end_ns > 0) {
            const fallback_year: u16 = if (task.mtime_ns > 0)
                ingestor.currentYearUtc(@intCast(@max(0, task.mtime_ns)))
            else
                2026;
            if (ingestor.parseUniversalLineTimestampNs(line_text, fallback_year)) |line_ns| {
                if (self.time_start_ns > 0 and line_ns < self.time_start_ns) return false;
                if (self.time_end_ns > 0 and line_ns > self.time_end_ns) return false;
            } else if (task.mtime_ns > 0) {
                const mtime_u64: u64 = @intCast(@max(0, task.mtime_ns));
                if (self.time_start_ns > 0 and mtime_u64 < self.time_start_ns) return false;
                if (self.time_end_ns > 0 and mtime_u64 > self.time_end_ns) return false;
            }
        }
        for (task.effective_excludes) |ex_lit| {
            if (ex_lit.len == 0) continue;
            const ci = switch (parsed_case) {
                .insensitive => true,
                .sensitive => false,
                .smart => !hasAsciiUpper(ex_lit),
            };
            const matched = if (ci)
                containsIgnoreCase(line_text, ex_lit)
            else
                (std.mem.indexOf(u8, line_text, ex_lit) != null);
            if (matched) return false;
        }
        for (self.excludes_regexes) |*ex_re| {
            if (ex_re.findReadOnly(line_text, 0, .leftmost_first) != null) return false;
        }
        for (task.effective_contains) |inc_lit| {
            if (inc_lit.len == 0) continue;
            const ci = switch (parsed_case) {
                .insensitive => true,
                .sensitive => false,
                .smart => !hasAsciiUpper(inc_lit),
            };
            const matched = if (ci)
                containsIgnoreCase(line_text, inc_lit)
            else
                (std.mem.indexOf(u8, line_text, inc_lit) != null);
            if (!matched) return false;
        }
        for (self.contains_regexes) |*inc_re| {
            if (inc_re.findReadOnly(line_text, 0, .leftmost_first) == null) return false;
        }
        _ = default_case_insensitive;
        switch (self.matcher.*) {
            .literal => |f_val| {
                var f = f_val;
                if (f.find(line_text, 0, .leftmost_first) == null) return false;
            },
            .multi => |*m| {
                if (m.find(line_text, 0, .leftmost_first) == null) return false;
            },
            .regex => |*r| {
                if (r.findReadOnly(line_text, 0, .leftmost_first) == null) return false;
            },
        }
        return true;
    }

    fn tryFilterSupersetCache(self: *JobRunner, exact_hash: u64, tasks_fingerprint: u64, heat_epoch: u64) bool {
        const reg = self.registry orelse return false;
        if (self.req.invert or self.req.context > 0) return false;
        if (self.req.replacement != null and self.req.replacement.?.len > 0) return false;

        const total_files = self.file_tasks.items.len;
        if (total_files == 0) return false;

        const parsed_case = parseCaseMode(self.req.case);
        const is_case_insensitive = switch (parsed_case) {
            .insensitive => true,
            .sensitive => false,
            .smart => !hasAsciiUpper(self.req.pattern),
        };

        const BucketCandidate = struct {
            item: HitItem,
            raw_json: []const u8 = "",
        };

        var per_task_buckets = self.job_arena.alloc(std.ArrayList(BucketCandidate), total_files) catch return false;
        for (0..total_files) |i| per_task_buckets[i] = .empty;
        var parent_bytes_searched: u64 = 0;
        var can_fast_splice_raw_json = false;

        {
            reg.search_cache.mutex.lockUncancelable(self.io);
            defer reg.search_cache.mutex.unlock(self.io);

            var best_entry: ?*search_cache.CachedQueryEntry = null;
            for (reg.search_cache.entries.items) |*e| {
                if (e.limit_hit or e.invert or e.context != 0 or e.has_replacement) continue;
                if (e.whole_word != self.req.wholeWord or e.whole_line != self.req.wholeLine) continue;
                if (!std.mem.eql(u8, e.mode, self.req.mode)) continue;
                if (!std.mem.eql(u8, e.case_mode, self.req.case)) continue;

                const exact_pat = std.mem.eql(u8, e.pattern, self.req.pattern);
                if (!exact_pat) {
                    if (!std.mem.eql(u8, self.req.mode, "literal") or self.req.wholeWord or self.req.wholeLine) continue;
                    if (self.req.pattern.len < e.pattern.len or e.pattern.len == 0) continue;
                    if (parseScopedModifier(self.job_arena, self.req.pattern, parsed_case) != null) continue;
                    if (parseScopedModifier(self.job_arena, e.pattern, parsed_case) != null) continue;
                    const parent_ci = switch (parsed_case) {
                        .insensitive => true,
                        .sensitive => false,
                        .smart => !hasAsciiUpper(e.pattern),
                    };
                    if (parent_ci) {
                        if (!containsIgnoreCase(self.req.pattern, e.pattern)) continue;
                    } else {
                        if (is_case_insensitive or std.mem.indexOf(u8, self.req.pattern, e.pattern) == null) continue;
                    }
                }
                if (!sliceIsSubset(e.contains, self.req.contains)) continue;
                if (!sliceIsSubset(e.excludes, self.req.excludes)) continue;
                // Superset time range must cover the requested time range
                if (e.time_start_ns > self.time_start_ns) continue;
                if (e.time_end_ns != 0 and (self.time_end_ns == 0 or e.time_end_ns < self.time_end_ns)) continue;

                // Strong Consistency Guard for >4096-byte long lines / lossy UTF-8 lines:
                // If predicates changed (`pattern`, `contains`, or `excludes`), in-memory filtering on `ci.text`
                // is only 100% sound when every cached line in `e` was stored without 4096-byte truncation!
                const predicates_changed = !exact_pat or
                    e.time_start_ns != self.time_start_ns or
                    e.time_end_ns != self.time_end_ns or
                    !slicesEqual(e.contains, self.req.contains) or
                    !slicesEqual(e.excludes, self.req.excludes);
                if (predicates_changed and !e.all_lines_exact) continue;

                // Verify that every candidate file in `self.file_tasks` was covered by `e` with identical `(mtime_ns, file_size, inode)`
                var all_files_covered = true;
                for (self.file_tasks.items) |ft| {
                    var found_file = false;
                    for (e.file_mtimes) |fm| {
                        if (fm.mtime_ns == ft.mtime_ns and
                            fm.file_size == ft.file_size and
                            fm.inode == ft.inode and
                            std.mem.eql(u8, fm.rel_path, ft.rel_path))
                        {
                            found_file = true;
                            break;
                        }
                    }
                    if (!found_file) {
                        all_files_covered = false;
                        break;
                    }
                }
                if (!all_files_covered) continue;

                if (best_entry == null or e.items.len < best_entry.?.items.len) {
                    best_entry = e;
                }
            }

            const sup = best_entry orelse return false;
            const pattern_changed = !std.mem.eql(u8, sup.pattern, self.req.pattern);
            const primary_span_finder: ?libwebgrep.Finder = if (pattern_changed)
                (libwebgrep.Finder.init(self.req.pattern, .{ .case = parsed_case }) catch return false)
            else
                null;

            can_fast_splice_raw_json = !pattern_changed;
            reg.search_cache.tick +%= 1;
            sup.access_tick = reg.search_cache.tick;
            parent_bytes_searched = sup.bytes_searched;
            self.had_non_exact_line.store(!sup.all_lines_exact, .release);

            var task_map = std.StringHashMapUnmanaged(usize){};
            defer task_map.deinit(self.job_arena);
            for (self.file_tasks.items, 0..) |ft, idx| {
                task_map.put(self.job_arena, ft.rel_path, idx) catch return false;
            }

            for (sup.items) |ci| {
                if (ci.isContext) continue;
                const task_idx = task_map.get(ci.file) orelse continue;
                const task = &self.file_tasks.items[task_idx];
                if (!self.lineMatchesTaskPredicates(task, ci.text, parsed_case, is_case_insensitive)) continue;

                const spans: []HitSpan = if (!pattern_changed) blk: {
                    const sp_slice = self.job_arena.alloc(HitSpan, ci.spans.len) catch return false;
                    for (ci.spans, 0..) |cs, si| {
                        sp_slice[si] = .{ .start = cs.start, .end = cs.end };
                    }
                    break :blk sp_slice;
                } else blk: {
                    var sp_list: std.ArrayList(HitSpan) = .empty;
                    var pf = primary_span_finder orelse break :blk &.{};
                    var bpos: usize = 0;
                    while (bpos <= ci.text.len) {
                        const hit = pf.find(ci.text, bpos, .leftmost_first) orelse break;
                        if (hit.start < bpos or hit.end > ci.text.len) break;
                        if (hit.end > hit.start) {
                            sp_list.append(self.job_arena, .{
                                .start = FileSink.utf8ByteToUtf16Offset(ci.text, hit.start),
                                .end = FileSink.utf8ByteToUtf16Offset(ci.text, hit.end),
                            }) catch return false;
                        }
                        if (hit.end <= bpos) break;
                        bpos = hit.end;
                    }
                    break :blk sp_list.items;
                };

                const raw_dup: []const u8 = if (can_fast_splice_raw_json and ci.raw_item_json.len > 0)
                    (self.job_arena.dupe(u8, ci.raw_item_json) catch "")
                else blk: {
                    can_fast_splice_raw_json = false;
                    break :blk "";
                };

                const cloned = HitItem{
                    .file = self.job_arena.dupe(u8, ci.file) catch return false,
                    .line = ci.line,
                    .col = if (spans.len > 0) spans[0].start + 1 else ci.col,
                    .text = self.job_arena.dupe(u8, ci.text) catch return false,
                    .prevText = if (ci.prevText) |pt| (self.job_arena.dupe(u8, pt) catch null) else null,
                    .nextText = if (ci.nextText) |nt| (self.job_arena.dupe(u8, nt) catch null) else null,
                    .replaced = null,
                    .isContext = false,
                    .spans = spans,
                };
                per_task_buckets[task_idx].append(self.job_arena, .{
                    .item = cloned,
                    .raw_json = raw_dup,
                }) catch return false;
            }
        }

        // Apply Two-Phase Heat-Weighted Elastic Water-Filling over in-memory buckets
        const max_res = self.req.maxResults;
        var emitted_per_task = self.job_arena.alloc(usize, total_files) catch return false;
        @memset(emitted_per_task, 0);

        var selected_raw_jsons: std.ArrayList([]const u8) = .empty;
        var total_emitted: u64 = 0;
        var limit_hit = false;

        // Phase 1: Heat-proportional soft quota
        for (self.file_tasks.items, 0..) |t, idx| {
            const bucket = per_task_buckets[idx].items;
            if (bucket.len == 0) continue;
            const cap_in_task: usize = if (t.soft_quota > 0)
                @min(bucket.len, @as(usize, @intCast(t.soft_quota)))
            else
                bucket.len;
            var take = cap_in_task;
            if (max_res > 0 and total_emitted + take > max_res) {
                take = @intCast(max_res - total_emitted);
                limit_hit = true;
            }
            for (bucket[0..take]) |cand| {
                self.collected_hits.append(self.job_arena, cand.item) catch return false;
                if (can_fast_splice_raw_json) {
                    selected_raw_jsons.append(self.job_arena, cand.raw_json) catch {
                        can_fast_splice_raw_json = false;
                    };
                }
            }
            emitted_per_task[idx] = take;
            total_emitted += take;
            if (max_res > 0 and total_emitted >= max_res) {
                if (take < bucket.len) limit_hit = true;
                break;
            }
        }

        // Phase 2+: Dynamic Water-Filling for remaining quota
        while (max_res == 0 or total_emitted < max_res) {
            var active_heat_sum: u64 = 0;
            var overflow_count: usize = 0;
            for (self.file_tasks.items, 0..) |t, idx| {
                if (emitted_per_task[idx] < per_task_buckets[idx].items.len) {
                    active_heat_sum +|= t.heat_score;
                    overflow_count += 1;
                }
            }
            if (overflow_count == 0) break;
            if (active_heat_sum == 0) active_heat_sum = 1;

            const remaining = if (max_res > 0) max_res - total_emitted else std.math.maxInt(u64);
            var seen_overflow: usize = 0;
            var allocated: u64 = 0;
            for (self.file_tasks.items, 0..) |t, idx| {
                const bucket = per_task_buckets[idx].items;
                const already = emitted_per_task[idx];
                if (already >= bucket.len) continue;
                seen_overflow += 1;

                const share: u64 = if (max_res == 0 or overflow_count == 1)
                    @intCast(bucket.len - already)
                else if (seen_overflow == overflow_count)
                    (if (remaining > allocated) remaining - allocated else 1)
                else
                    @max(@as(u64, 1), (remaining * t.heat_score) / active_heat_sum);
                allocated +|= share;

                var take: usize = @min(bucket.len - already, @as(usize, @intCast(share)));
                if (max_res > 0 and total_emitted + take >= max_res) {
                    take = @intCast(max_res - total_emitted);
                    if (already + take < bucket.len) limit_hit = true;
                }
                for (bucket[already .. already + take]) |cand| {
                    self.collected_hits.append(self.job_arena, cand.item) catch return false;
                    if (can_fast_splice_raw_json) {
                        selected_raw_jsons.append(self.job_arena, cand.raw_json) catch {
                            can_fast_splice_raw_json = false;
                        };
                    }
                }
                emitted_per_task[idx] = already + take;
                total_emitted += take;
                if (max_res > 0 and total_emitted >= max_res) break;
            }
        }

        var files_matched: u64 = 0;
        for (emitted_per_task, 0..) |em, idx| {
            if (em > 0) files_matched += 1;
            if (em < per_task_buckets[idx].items.len) limit_hit = true;
        }

        self.files_searched.store(@intCast(total_files), .release);
        self.files_matched.store(files_matched, .release);
        self.total_matches.store(total_emitted, .release);
        self.matched_lines.store(total_emitted, .release);
        self.bytes_searched.store(parent_bytes_searched, .release);
        self.hit_max_results.store(limit_hit, .release);

        if (self.collected_hits.items.len > 0) {
            if (can_fast_splice_raw_json and selected_raw_jsons.items.len == self.collected_hits.items.len) {
                var total_json_bytes: usize = 64;
                for (selected_raw_jsons.items) |rj| {
                    total_json_bytes += rj.len + 1;
                }
                var out_buf: std.ArrayList(u8) = .empty;
                if (out_buf.ensureTotalCapacity(self.job_arena, total_json_bytes)) {
                    const hdr = std.fmt.allocPrint(self.job_arena, "{{\"type\":\"hits\",\"id\":{d},\"items\":[", .{self.req.id}) catch "";
                    if (hdr.len > 0) {
                        out_buf.appendSliceAssumeCapacity(hdr);
                        for (selected_raw_jsons.items, 0..) |rj, i| {
                            if (i > 0) out_buf.appendAssumeCapacity(',');
                            out_buf.appendSliceAssumeCapacity(rj);
                        }
                        out_buf.appendSliceAssumeCapacity("]}");
                        self.sender.send(out_buf.items) catch {
                            self.send_failed.store(true, .release);
                        };
                    } else {
                        self.flushItemsSliceToSender(self.collected_hits.items);
                    }
                } else |_| {
                    self.flushItemsSliceToSender(self.collected_hits.items);
                }
            } else {
                self.flushItemsSliceToSender(self.collected_hits.items);
            }
        }
        if (!self.send_failed.load(.acquire) and !self.cancel_flag.load(.acquire)) {
            self.should_commit_cache = true;
            self.pending_exact_hash = exact_hash;
            self.pending_tasks_fingerprint = tasks_fingerprint;
            self.pending_heat_epoch = heat_epoch;
        }
        return true;
    }

    fn commitCacheAfterDone(self: *JobRunner) void {
        if (!self.should_commit_cache) return;
        if (self.send_failed.load(.acquire) or self.cancel_flag.load(.acquire) or self.had_scan_error.load(.acquire)) return;
        self.storeResultInCache(
            self.pending_exact_hash,
            self.pending_tasks_fingerprint,
            self.pending_heat_epoch,
        );
    }

    fn storeResultInCache(self: *JobRunner, exact_hash: u64, tasks_fingerprint: u64, heat_epoch: u64) void {
        const reg = self.registry orelse return;
        if (self.collected_hits_overflow or self.had_scan_error.load(.acquire)) return;
        if (self.collected_hits.items.len > search_cache.MAX_ITEMS_PER_ENTRY) return;

        var entry_arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer entry_arena.deinit();
        const alloc = entry_arena.allocator();

        const pat_copy = alloc.dupe(u8, self.req.pattern) catch return;
        const mode_copy = alloc.dupe(u8, self.req.mode) catch return;
        const case_copy = alloc.dupe(u8, self.req.case) catch return;

        const contains_copy = alloc.alloc([]const u8, self.req.contains.len) catch return;
        for (self.req.contains, 0..) |s, i| {
            contains_copy[i] = alloc.dupe(u8, s) catch return;
        }
        const excludes_copy = alloc.alloc([]const u8, self.req.excludes.len) catch return;
        for (self.req.excludes, 0..) |s, i| {
            excludes_copy[i] = alloc.dupe(u8, s) catch return;
        }

        const fm_copy = alloc.alloc(search_cache.FileMtimeRecord, self.file_tasks.items.len) catch return;
        for (self.file_tasks.items, 0..) |ft, i| {
            fm_copy[i] = .{
                .rel_path = alloc.dupe(u8, ft.rel_path) catch return,
                .mtime_ns = ft.mtime_ns,
                .file_size = ft.file_size,
                .inode = ft.inode,
            };
        }

        const raw_items_json: []const u8 = if (self.collected_hits.items.len > 0)
            (file_api.stringifyAlloc(alloc, self.collected_hits.items) catch "[]")
        else
            "[]";

        var approx_bytes: usize = 512 + self.file_tasks.items.len * 64 + raw_items_json.len;
        const items_copy = alloc.alloc(search_cache.CachedHitItem, self.collected_hits.items.len) catch return;
        for (self.collected_hits.items, 0..) |it, i| {
            const spans_copy = alloc.alloc(search_cache.CachedSpan, it.spans.len) catch return;
            for (it.spans, 0..) |sp, si| {
                spans_copy[si] = .{ .start = sp.start, .end = sp.end };
            }
            const f_dup = alloc.dupe(u8, it.file) catch return;
            const t_dup = alloc.dupe(u8, it.text) catch return;
            const prev_dup = if (it.prevText) |pt| (alloc.dupe(u8, pt) catch null) else null;
            const next_dup = if (it.nextText) |nt| (alloc.dupe(u8, nt) catch null) else null;
            const r_dup = if (it.replaced) |r| (alloc.dupe(u8, r) catch null) else null;
            items_copy[i] = .{
                .file = f_dup,
                .line = it.line,
                .col = it.col,
                .text = t_dup,
                .prevText = prev_dup,
                .nextText = next_dup,
                .replaced = r_dup,
                .isContext = it.isContext,
                .spans = spans_copy,
                .raw_item_json = "",
            };
            approx_bytes += 88 + f_dup.len + t_dup.len +
                (if (prev_dup) |p| p.len else 0) +
                (if (next_dup) |n| n.len else 0) +
                spans_copy.len * 16;
        }

        // Zero-copy slice each top-level `{...}` JSON object out of `raw_items_json`
        if (items_copy.len > 0 and raw_items_json.len > 2) {
            var item_idx: usize = 0;
            var obj_start: usize = 0;
            var depth: usize = 0;
            var in_str = false;
            var escaped = false;
            for (raw_items_json, 0..) |ch, pos| {
                if (in_str) {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == '"') {
                        in_str = false;
                    }
                    continue;
                }
                if (ch == '"') {
                    in_str = true;
                } else if (ch == '{') {
                    if (depth == 0) obj_start = pos;
                    depth += 1;
                } else if (ch == '}') {
                    if (depth > 0) {
                        depth -= 1;
                        if (depth == 0 and item_idx < items_copy.len) {
                            items_copy[item_idx].raw_item_json = raw_items_json[obj_start .. pos + 1];
                            item_idx += 1;
                        }
                    }
                }
            }
        }

        reg.search_cache.mutex.lockUncancelable(self.io);
        defer reg.search_cache.mutex.unlock(self.io);

        reg.search_cache.evictIfNeededLocked(approx_bytes);
        reg.search_cache.tick +%= 1;

        reg.search_cache.entries.append(self.gpa, .{
            .arena = entry_arena,
            .exact_hash = exact_hash,
            .tasks_fingerprint = tasks_fingerprint,
            .heat_epoch = heat_epoch,
            .pattern = pat_copy,
            .mode = mode_copy,
            .case_mode = case_copy,
            .whole_word = self.req.wholeWord,
            .whole_line = self.req.wholeLine,
            .invert = self.req.invert,
            .context = self.req.context,
            .has_replacement = (self.req.replacement != null and self.req.replacement.?.len > 0),
            .max_results = self.req.maxResults,
            .time_start_ns = self.time_start_ns,
            .time_end_ns = self.time_end_ns,
            .contains = contains_copy,
            .excludes = excludes_copy,
            .file_mtimes = fm_copy,
            .items = items_copy,
            .raw_items_json = raw_items_json,
            .files_searched = self.files_searched.load(.acquire),
            .files_matched = self.files_matched.load(.acquire),
            .total_matches = self.total_matches.load(.acquire),
            .matched_lines = self.matched_lines.load(.acquire),
            .bytes_searched = self.bytes_searched.load(.acquire),
            .limit_hit = self.hit_max_results.load(.acquire),
            .all_lines_exact = !self.had_non_exact_line.load(.acquire),
            .approx_bytes = approx_bytes,
            .access_tick = reg.search_cache.tick,
        }) catch {
            entry_arena.deinit();
            return;
        };
        reg.search_cache.total_bytes += approx_bytes;
    }

    fn runParallelWorkers(self: *JobRunner) void {
        const total_files = self.file_tasks.items.len;
        if (total_files == 0) return;

        const tasks_fingerprint = self.computeTasksFingerprint();
        const heat_epoch: u64 = if (self.registry) |reg| reg.getHeatEpoch() else 0;
        const exact_hash = self.computeExactQueryHash(tasks_fingerprint, heat_epoch);

        // Tier L1: Exact Query Frame Replay Cache (< 0.2ms)
        // Caches only ever hold strict single-line results, so a cached "0 hits" still has to try the
        // nearby-lines fallback (its results are never cached, keeping L1/L2 invariants exact).
        if (self.tryReplayExactCache(exact_hash, tasks_fingerprint, heat_epoch)) {
            self.cache_hit_tier = "exact";
            self.tryNearbyFallbackAfterCache();
            return;
        }

        self.prepareHeatAndQuotas();

        // Tier L2: Progressive Superset In-Memory Narrowing Cache (< 0.8ms)
        if (self.tryFilterSupersetCache(exact_hash, tasks_fingerprint, heat_epoch)) {
            self.cache_hit_tier = "superset";
            self.tryNearbyFallbackAfterCache();
            return;
        }

        // Tier L3: Zero-Hit File Substring Monotonic Pruning Cache
        self.active_task_indices.clearRetainingCapacity();
        self.active_task_indices.ensureTotalCapacity(self.job_arena, total_files) catch return;

        const can_use_negative_prune = (self.registry != null) and
            !self.req.invert and
            std.mem.eql(u8, self.req.mode, "literal") and
            (parseScopedModifier(self.job_arena, self.req.pattern, parseCaseMode(self.req.case)) == null);

        var req_literals_buf: [16][]const u8 = undefined;
        var req_literals_len: usize = 0;
        if (can_use_negative_prune and self.req.pattern.len >= 2) {
            req_literals_buf[0] = self.req.pattern;
            req_literals_len = 1;
            for (self.req.contains) |c_pat| {
                if (req_literals_len >= req_literals_buf.len) break;
                if (c_pat.len >= 2 and parseScopedModifier(self.job_arena, c_pat, parseCaseMode(self.req.case)) == null) {
                    req_literals_buf[req_literals_len] = c_pat;
                    req_literals_len += 1;
                }
            }
        }
        const parsed_case = parseCaseMode(self.req.case);
        const query_case_insensitive = switch (parsed_case) {
            .insensitive => true,
            .sensitive => false,
            .smart => !hasAsciiUpper(self.req.pattern),
        };

        for (0..total_files) |idx| {
            if (can_use_negative_prune and req_literals_len > 0) {
                const t = &self.file_tasks.items[idx];
                if (self.registry.?.search_cache.checkFilePrunedByNegativeCache(
                    self.io,
                    t.rel_path,
                    t.mtime_ns,
                    t.file_size,
                    t.inode,
                    req_literals_buf[0..req_literals_len],
                    query_case_insensitive,
                )) |cached_bytes| {
                    t.counted_file_searched = true;
                    _ = self.files_searched.fetchAdd(1, .monotonic);
                    _ = self.bytes_searched.fetchAdd(cached_bytes, .monotonic);
                    self.pruned_by_negative_cache.store(true, .release);
                    continue;
                }
            }
            self.active_task_indices.appendAssumeCapacity(idx);
        }

        // If L3 pruning narrowed active files down to 1, grant it 100% of maxResults in Phase 1 directly
        if (self.active_task_indices.items.len == 1) {
            self.file_tasks.items[self.active_task_indices.items[0]].soft_quota = 0;
        }

        // Phase 1: Heat-prioritized initial proportional pass across active candidate files
        self.executeWorkerPass();

        // Phase 2+: Iterative Dynamic Density-Weighted Water-Filling for files that hit their soft quota
        // while global `total_matches < maxResults`.
        while (!self.shouldStop()) {
            const max_res = self.req.maxResults;
            const cur_total = self.total_matches.load(.acquire);
            if (max_res > 0 and cur_total >= max_res) break;

            self.active_task_indices.clearRetainingCapacity();
            for (self.file_tasks.items, 0..) |*t, idx| {
                if (t.paused_at_soft_quota) {
                    const denom = @max(@as(u64, 4096), t.phase_bytes);
                    const density_heat = @min(@as(u64, 2000), (t.emitted_in_file * 1024 * 1024) / denom);
                    t.heat_score = t.base_heat + density_heat;
                    self.active_task_indices.appendAssumeCapacity(idx);
                }
            }

            const overflow_count = self.active_task_indices.items.len;
            if (overflow_count == 0) break;

            // Sort overflow indices so files with highest (base_heat + match_density) run first
            const IndexSortCtx = struct {
                tasks: []const FileTask,
                pub fn lessThan(ctx: @This(), a_idx: usize, b_idx: usize) bool {
                    return FileTask.hotterThan({}, ctx.tasks[a_idx], ctx.tasks[b_idx]);
                }
            };
            std.mem.sort(
                usize,
                self.active_task_indices.items,
                IndexSortCtx{ .tasks = self.file_tasks.items },
                IndexSortCtx.lessThan,
            );

            if (max_res == 0 or overflow_count == 1) {
                for (self.active_task_indices.items) |idx| {
                    self.file_tasks.items[idx].soft_quota = 0;
                }
            } else {
                const remaining = max_res - cur_total;
                var active_heat_sum: u64 = 0;
                for (self.active_task_indices.items) |idx| {
                    active_heat_sum +|= self.file_tasks.items[idx].heat_score;
                }
                if (active_heat_sum == 0) active_heat_sum = 1;

                var allocated: u64 = 0;
                for (self.active_task_indices.items, 0..) |idx, k| {
                    var t = &self.file_tasks.items[idx];
                    const share = if (k + 1 == overflow_count)
                        (if (remaining > allocated) remaining - allocated else 1)
                    else
                        @max(@as(u64, 1), (remaining * t.heat_score) / active_heat_sum);
                    allocated +|= share;
                    t.soft_quota = t.emitted_in_file + share;
                }
            }

            self.executeWorkerPass();
        }

        // Block-Proximity Fallback (±15 lines):
        // When a multi-keyword query (`req.contains.len > 0`, e.g. `pub fn async members`) yields 0 single-line matches
        // across all candidate files, check whether all query predicates co-occur within a ±15-line code block window.
        if (self.total_matches.load(.acquire) == 0 and self.canRunBlockProximityFallback()) {
            if (self.runBlockProximityFallback()) {
                self.cache_hit_tier = "nearby";
                return;
            }
        }

        // Feed observed query match heat back into SourceRegistry for future searches
        if (self.registry) |reg| {
            for (self.file_tasks.items) |t| {
                if (t.emitted_in_file > 0) {
                    const heat_boost = @min(@as(u64, 80), 8 + t.emitted_in_file / 16);
                    reg.recordPassiveMatchHeat(self.io, t.rel_path, heat_boost);
                }
            }
        }

        if (self.pruned_by_negative_cache.load(.acquire)) {
            self.cache_hit_tier = "pruned";
        }
        if (!self.cancel_flag.load(.acquire) and !self.send_failed.load(.acquire) and !self.had_scan_error.load(.acquire)) {
            self.should_commit_cache = true;
            self.pending_exact_hash = exact_hash;
            self.pending_tasks_fingerprint = tasks_fingerprint;
            self.pending_heat_epoch = heat_epoch;
        }
    }

    fn workerThreadMain(self: *JobRunner) void {
        var batch_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer batch_arena_state.deinit();

        var scratch_pool = libwebgrep.Scratch.init(self.gpa);
        defer scratch_pool.deinit();

        var worker = WorkerContext{
            .runner = self,
            .local_matcher = self.matcher.*,
            .batch_arena = &batch_arena_state,
            .scratch_pool = &scratch_pool,
            .last_flush_ts = std.Io.Clock.awake.now(self.io),
        };
        defer worker.batch_items.deinit(self.gpa);

        while (!self.shouldStop()) {
            const pos = self.next_task_idx.fetchAdd(1, .monotonic);
            if (pos >= self.active_task_indices.items.len) break;
            const task_idx = self.active_task_indices.items[pos];
            worker.searchOneTask(&self.file_tasks.items[task_idx]);
        }

        worker.flushBatch() catch {
            self.send_failed.store(true, .release);
        };
    }

    fn maybeSendProgress(self: *JobRunner, in_file_bytes: u64) void {
        if (self.shouldStop()) return;

        if (!self.progress_mutex.tryLock()) return;
        defer self.progress_mutex.unlock(self.io);

        const files_done = self.files_searched.load(.monotonic);
        const elapsed_ns = self.last_progress_ts.untilNow(self.io, .awake).toNanoseconds();
        if (elapsed_ns < 60 * std.time.ns_per_ms and (files_done == 0 or files_done % 200 != 0)) return;

        self.last_progress_ts = std.Io.Clock.awake.now(self.io);
        const prog_json = file_api.stringifyAlloc(self.gpa, ProgressFrame{
            .id = self.req.id,
            .filesSearched = files_done,
            .filesMatched = self.files_matched.load(.monotonic),
            .matches = self.total_matches.load(.monotonic),
            .bytesSearched = self.bytes_searched.load(.monotonic) + in_file_bytes,
        }) catch return;
        defer self.gpa.free(prog_json);
        self.sender.send(prog_json) catch {
            self.send_failed.store(true, .release);
        };
    }

    fn canRunBlockProximityFallback(self: *const JobRunner) bool {
        if (self.shouldStop()) return false;
        if (self.req.nearbyLines == 0) return false;
        // Time-filtered searches stay strictly line-based (nearby lines may fall outside the window).
        if (self.time_start_ns > 0 or self.time_end_ns > 0) return false;
        if (self.req.invert or self.req.wholeLine) return false;
        if (self.req.replacement != null and self.req.replacement.?.len > 0) return false;
        if (self.req.pattern.len == 0) return false;
        return self.req.contains.len > 0;
    }

    /// Runs the nearby-lines fallback after an L1/L2 cache tier produced 0 strict single-line hits.
    /// Fallback results are never committed to L1/L2 (they are not single-line supersets).
    fn tryNearbyFallbackAfterCache(self: *JobRunner) void {
        if (self.total_matches.load(.acquire) != 0 or !self.canRunBlockProximityFallback()) return;
        if (self.runBlockProximityFallback()) {
            self.should_commit_cache = false;
            self.cache_hit_tier = "nearby";
        }
    }

    fn runBlockProximityFallback(self: *JobRunner) bool {
        const parsed_case = parseCaseMode(self.req.case);
        const max_res = self.req.maxResults;
        const block_radius: usize = @min(@as(usize, self.req.nearbyLines), 200);
        const max_fallback_file_bytes: u64 = 16 * 1024 * 1024;

        var fallback_hits: std.ArrayList(HitItem) = .empty;
        var matched_files_count: u64 = 0;
        var limit_hit = false;

        var regex_scratch = libwebgrep.RegexScratch.init(self.gpa);
        defer regex_scratch.deinit();

        for (self.file_tasks.items) |*task| {
            if (self.shouldStop()) break;
            if (task.file_size == 0 or task.file_size > max_fallback_file_bytes) continue;
            if (file_api.hasCompressedExtension(task.base_name)) continue;

            const pos_lit_count = task.effective_contains.len;
            const pos_re_count = self.contains_regexes.len;
            const total_preds = 1 + pos_lit_count + pos_re_count;
            if (total_preds <= 1 or total_preds > 32) continue;

            var opened_parent: ?std.Io.Dir = null;
            defer if (opened_parent) |*d| d.close(self.io);

            const parent_dir: std.Io.Dir = if (task.parent_dir_path) |p| blk: {
                opened_parent = std.Io.Dir.cwd().openDir(self.io, p, .{}) catch continue;
                break :blk opened_parent.?;
            } else self.root_dir;

            var hot_lease: ?search_cache.HotFileLease = null;
            if (self.registry) |reg| {
                hot_lease = reg.search_cache.acquireHotFileSlice(
                    self.io,
                    task.rel_path,
                    task.mtime_ns,
                    task.file_size,
                    task.inode,
                    parent_dir,
                    task.open_sub_path,
                    search_cache.MAX_HOT_FILE_MAP_BYTES,
                );
            }
            defer if (hot_lease) |lease| {
                self.registry.?.search_cache.releaseHotFileSlice(self.io, lease.slot_idx);
            };

            var owned_buf: []u8 = &.{};
            defer if (owned_buf.len > 0) self.gpa.free(owned_buf);

            const raw_slice: []const u8 = if (hot_lease) |lease|
                lease.slice
            else blk_read: {
                var file = parent_dir.openFile(self.io, task.open_sub_path, .{ .allow_directory = false }) catch continue;
                defer file.close(self.io);
                const alloc_len: usize = @intCast(task.file_size);
                owned_buf = self.gpa.alloc(u8, alloc_len) catch continue;
                const n = file.readPositionalAll(self.io, owned_buf, 0) catch continue;
                break :blk_read owned_buf[0..n];
            };
            if (raw_slice.len == 0) continue;

            // Fast whole-file precheck: every positive predicate (`self.matcher`, `task.effective_contains`, `self.contains_regexes`)
            // must appear at least once in `raw_slice`. This prunes >95% of non-matching files in microseconds!
            const primary_in_file = switch (self.matcher.*) {
                .literal => |*f| (f.find(raw_slice, 0, .leftmost_first) != null),
                .multi => |*m| (m.find(raw_slice, 0, .leftmost_first) != null),
                .regex => |*r| (r.findWithScratch(raw_slice, 0, .leftmost_first, &regex_scratch) != null),
            };
            if (!primary_in_file) continue;

            var all_lits_in_file = true;
            for (task.effective_contains) |inc_lit| {
                if (inc_lit.len == 0) continue;
                const ci = switch (parsed_case) {
                    .insensitive => true,
                    .sensitive => false,
                    .smart => !hasAsciiUpper(inc_lit),
                };
                const found = if (ci)
                    containsIgnoreCase(raw_slice, inc_lit)
                else
                    (std.mem.indexOf(u8, raw_slice, inc_lit) != null);
                if (!found) {
                    all_lits_in_file = false;
                    break;
                }
            }
            if (!all_lits_in_file) continue;

            var all_res_in_file = true;
            for (self.contains_regexes) |*inc_re| {
                if (inc_re.findWithScratch(raw_slice, 0, .leftmost_first, &regex_scratch) == null) {
                    all_res_in_file = false;
                    break;
                }
            }
            if (!all_res_in_file) continue;

            const LineInfo = struct {
                text: []const u8,
                mask: u32,
                excluded: bool,
                matches_user_primary: bool,
            };
            var lines: std.ArrayList(LineInfo) = .empty;
            defer lines.deinit(self.gpa);

            const required_mask: u32 = if (total_preds == 32)
                std.math.maxInt(u32)
            else
                (@as(u32, 1) << @intCast(total_preds)) - 1;

            var pos: usize = 0;
            while (pos < raw_slice.len) {
                const nl = std.mem.indexOfScalarPos(u8, raw_slice, pos, '\n') orelse raw_slice.len;
                var line_text = raw_slice[pos..nl];
                if (line_text.len > 0 and line_text[line_text.len - 1] == '\r') {
                    line_text = line_text[0 .. line_text.len - 1];
                }
                pos = if (nl < raw_slice.len) nl + 1 else raw_slice.len;

                var excluded = false;
                for (task.effective_excludes) |ex_lit| {
                    if (ex_lit.len == 0) continue;
                    const ci = switch (parsed_case) {
                        .insensitive => true,
                        .sensitive => false,
                        .smart => !hasAsciiUpper(ex_lit),
                    };
                    if (if (ci) containsIgnoreCase(line_text, ex_lit) else (std.mem.indexOf(u8, line_text, ex_lit) != null)) {
                        excluded = true;
                        break;
                    }
                }
                if (!excluded) {
                    for (self.excludes_regexes) |*ex_re| {
                        if (ex_re.findWithScratch(line_text, 0, .leftmost_first, &regex_scratch) != null) {
                            excluded = true;
                            break;
                        }
                    }
                }

                var mask: u32 = 0;
                const m0 = switch (self.matcher.*) {
                    .literal => |*f| (f.find(line_text, 0, .leftmost_first) != null),
                    .multi => |*m| (m.find(line_text, 0, .leftmost_first) != null),
                    .regex => |*r| (r.findWithScratch(line_text, 0, .leftmost_first, &regex_scratch) != null),
                };
                if (m0) mask |= 1;

                for (task.effective_contains, 0..) |inc_lit, li| {
                    const bit_idx: u5 = @intCast(1 + li);
                    if (inc_lit.len == 0) {
                        mask |= (@as(u32, 1) << bit_idx);
                        continue;
                    }
                    const ci = switch (parsed_case) {
                        .insensitive => true,
                        .sensitive => false,
                        .smart => !hasAsciiUpper(inc_lit),
                    };
                    if (if (ci) containsIgnoreCase(line_text, inc_lit) else (std.mem.indexOf(u8, line_text, inc_lit) != null)) {
                        mask |= (@as(u32, 1) << bit_idx);
                    }
                }

                for (self.contains_regexes, 0..) |*inc_re, ri| {
                    const bit_idx: u5 = @intCast(1 + pos_lit_count + ri);
                    if (inc_re.findWithScratch(line_text, 0, .leftmost_first, &regex_scratch) != null) {
                        mask |= (@as(u32, 1) << bit_idx);
                    }
                }

                const matches_user_primary = if (self.swapped_primary_regex_first and self.contains_regexes.len > 0)
                    ((mask & (@as(u32, 1) << @intCast(1 + pos_lit_count))) != 0)
                else if (self.swapped_primary_finder) |*pf|
                    (pf.find(line_text, 0, .leftmost_first) != null)
                else
                    m0;

                lines.append(self.gpa, .{
                    .text = line_text,
                    .mask = mask,
                    .excluded = excluded,
                    .matches_user_primary = matches_user_primary,
                }) catch break;
            }

            const line_items = lines.items;
            if (line_items.len == 0) continue;

            var file_emitted: u64 = 0;
            var last_emitted_idx: ?usize = null;

            for (line_items, 0..) |li, idx| {
                if (li.excluded or li.mask == 0) continue;
                const w_start = idx -| block_radius;
                const w_end = @min(line_items.len, idx + block_radius + 1);

                var union_mask: u32 = 0;
                for (line_items[w_start..w_end]) |w_li| {
                    if (!w_li.excluded) {
                        union_mask |= w_li.mask;
                    }
                }
                if ((union_mask & required_mask) != required_mask) continue;

                // Prefer emitting anchor lines that either match at least 2 query terms (e.g. `pub(crate) async fn`)
                // or match the rarest term (`m0`) when no multi-term anchor was just emitted within 12 lines.
                const pop = @popCount(li.mask);
                const is_strong_anchor = (pop >= 2) or ((li.mask & 1) != 0 and total_preds == 2);
                if (!is_strong_anchor) continue;

                if (last_emitted_idx) |prev_idx| {
                    if (idx - prev_idx <= 4 and pop <= @popCount(line_items[prev_idx].mask)) {
                        continue;
                    }
                }
                last_emitted_idx = idx;

                const safe_text = file_api.sanitizeUtf8Truncated(self.job_arena, li.text, 4096) catch continue;
                const text_duped = if (safe_text.ptr == li.text.ptr)
                    (self.job_arena.dupe(u8, safe_text) catch continue)
                else
                    safe_text;

                var raw_prev: ?[]const u8 = null;
                {
                    var p = idx;
                    while (p > w_start) {
                        p -= 1;
                        if (!line_items[p].excluded and (line_items[p].mask & ~li.mask) != 0) {
                            raw_prev = line_items[p].text;
                            break;
                        }
                    }
                    if (raw_prev == null) {
                        var b_steps: usize = 0;
                        var bp = idx;
                        while (bp > 0 and b_steps < 3) : (b_steps += 1) {
                            bp -= 1;
                            if (std.mem.trim(u8, line_items[bp].text, " \t\r").len > 0) {
                                raw_prev = line_items[bp].text;
                                break;
                            }
                        }
                    }
                }

                var raw_next: ?[]const u8 = null;
                {
                    var n = idx + 1;
                    while (n < w_end) : (n += 1) {
                        if (!line_items[n].excluded and (line_items[n].mask & ~li.mask) != 0) {
                            raw_next = line_items[n].text;
                            break;
                        }
                    }
                    if (raw_next == null) {
                        var f_steps: usize = 0;
                        var fn_idx = idx + 1;
                        while (fn_idx < line_items.len and f_steps < 3) : ({
                            fn_idx += 1;
                            f_steps += 1;
                        }) {
                            if (std.mem.trim(u8, line_items[fn_idx].text, " \t\r").len > 0) {
                                raw_next = line_items[fn_idx].text;
                                break;
                            }
                        }
                    }
                }

                const prev_duped: ?[]const u8 = if (raw_prev) |rp| blk: {
                    const sp = file_api.sanitizeUtf8Truncated(self.job_arena, rp, 240) catch break :blk null;
                    break :blk if (sp.ptr == rp.ptr) (self.job_arena.dupe(u8, sp) catch null) else sp;
                } else null;

                const next_duped: ?[]const u8 = if (raw_next) |rn| blk: {
                    const sn = file_api.sanitizeUtf8Truncated(self.job_arena, rn, 240) catch break :blk null;
                    break :blk if (sn.ptr == rn.ptr) (self.job_arena.dupe(u8, sn) catch null) else sn;
                } else null;

                var spans_list: std.ArrayList(HitSpan) = .empty;
                self.collectAllQueryTermSpans(task, text_duped, parsed_case, &spans_list);

                const col: u64 = if (spans_list.items.len > 0)
                    @intCast(spans_list.items[0].start + 1)
                else
                    1;

                fallback_hits.append(self.job_arena, .{
                    .file = self.job_arena.dupe(u8, task.rel_path) catch continue,
                    .line = @intCast(idx + 1),
                    .col = col,
                    .text = text_duped,
                    .prevText = prev_duped,
                    .nextText = next_duped,
                    .replaced = null,
                    .isContext = false,
                    .spans = spans_list.items,
                }) catch break;

                file_emitted += 1;
                if (max_res > 0 and fallback_hits.items.len >= max_res) {
                    limit_hit = true;
                    break;
                }
            }

            if (file_emitted > 0) {
                matched_files_count += 1;
                task.emitted_in_file = file_emitted;
            }
            if (limit_hit) break;
        }

        if (fallback_hits.items.len == 0) return false;

        const total_emitted: u64 = @intCast(fallback_hits.items.len);
        self.files_matched.store(matched_files_count, .release);
        self.total_matches.store(total_emitted, .release);
        self.matched_lines.store(total_emitted, .release);
        self.hit_max_results.store(limit_hit, .release);
        self.nearby_used = true;

        self.flushItemsSliceToSender(fallback_hits.items);
        return true;
    }

    fn collectAllQueryTermSpans(
        self: *JobRunner,
        task: *const FileTask,
        text: []const u8,
        parsed_case: libwebgrep.CaseMode,
        spans_list: *std.ArrayList(HitSpan),
    ) void {
        const RawByteSpan = struct {
            start: usize,
            end: usize,
        };
        var raw_spans: std.ArrayList(RawByteSpan) = .empty;
        defer raw_spans.deinit(self.gpa);

        // 1. Primary matcher spans
        switch (self.matcher.*) {
            .literal => |f_val| {
                var f = f_val;
                var bpos: usize = 0;
                while (bpos <= text.len) {
                    const hit = f.find(text, bpos, .leftmost_first) orelse break;
                    if (hit.start < bpos or hit.end > text.len) break;
                    if (hit.end > hit.start) {
                        raw_spans.append(self.gpa, .{ .start = hit.start, .end = hit.end }) catch break;
                    }
                    if (hit.end <= bpos) break;
                    bpos = hit.end;
                }
            },
            .multi => |*m| {
                var bpos: usize = 0;
                while (bpos <= text.len) {
                    const hit = m.find(text, bpos, .leftmost_first) orelse break;
                    if (hit.start < bpos or hit.end > text.len) break;
                    if (hit.end > hit.start) {
                        raw_spans.append(self.gpa, .{ .start = hit.start, .end = hit.end }) catch break;
                    }
                    if (hit.end <= bpos) break;
                    bpos = hit.end;
                }
            },
            .regex => |*r| {
                var bpos: usize = 0;
                while (bpos <= text.len) {
                    const hit = r.findReadOnly(text, bpos, .leftmost_first) orelse break;
                    if (hit.start < bpos or hit.end > text.len) break;
                    if (hit.end > hit.start) {
                        raw_spans.append(self.gpa, .{ .start = hit.start, .end = hit.end }) catch break;
                    }
                    if (hit.end <= bpos) break;
                    bpos = hit.end;
                }
            },
        }

        // 2. Literal `effective_contains` spans
        for (task.effective_contains) |inc_lit| {
            if (inc_lit.len == 0) continue;
            var f = libwebgrep.Finder.init(inc_lit, .{ .case = parsed_case }) catch continue;
            var bpos: usize = 0;
            while (bpos <= text.len) {
                const hit = f.find(text, bpos, .leftmost_first) orelse break;
                if (hit.start < bpos or hit.end > text.len) break;
                if (hit.end > hit.start) {
                    raw_spans.append(self.gpa, .{ .start = hit.start, .end = hit.end }) catch break;
                }
                if (hit.end <= bpos) break;
                bpos = hit.end;
            }
        }

        // 3. Regex `contains_regexes` spans
        for (self.contains_regexes) |*inc_re| {
            var bpos: usize = 0;
            while (bpos <= text.len) {
                const hit = inc_re.findReadOnly(text, bpos, .leftmost_first) orelse break;
                if (hit.start < bpos or hit.end > text.len) break;
                if (hit.end > hit.start) {
                    raw_spans.append(self.gpa, .{ .start = hit.start, .end = hit.end }) catch break;
                }
                if (hit.end <= bpos) break;
                bpos = hit.end;
            }
        }

        if (raw_spans.items.len == 0) return;

        // Sort and merge overlapping byte spans
        const SortCtx = struct {
            pub fn lessThan(_: void, a: RawByteSpan, b: RawByteSpan) bool {
                if (a.start != b.start) return a.start < b.start;
                return a.end < b.end;
            }
        };
        std.mem.sort(RawByteSpan, raw_spans.items, {}, SortCtx.lessThan);

        var merged_end: usize = 0;
        for (raw_spans.items, 0..) |sp, i| {
            if (i == 0) {
                spans_list.append(self.job_arena, .{
                    .start = FileSink.utf8ByteToUtf16Offset(text, sp.start),
                    .end = FileSink.utf8ByteToUtf16Offset(text, sp.end),
                }) catch return;
                merged_end = sp.end;
            } else if (sp.start < merged_end) {
                if (sp.end > merged_end) {
                    merged_end = sp.end;
                    spans_list.items[spans_list.items.len - 1].end = FileSink.utf8ByteToUtf16Offset(text, merged_end);
                }
            } else {
                spans_list.append(self.job_arena, .{
                    .start = FileSink.utf8ByteToUtf16Offset(text, sp.start),
                    .end = FileSink.utf8ByteToUtf16Offset(text, sp.end),
                }) catch return;
                merged_end = sp.end;
            }
        }
    }
};

fn findLineStartAtOrBefore(slice: []const u8, pos: usize) usize {
    var k = @min(pos, slice.len);
    while (k > 0) {
        if (slice[k - 1] == '\n') return k;
        k -= 1;
    }
    return 0;
}

fn countNewlinesFast(slice: []const u8) u64 {
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
fn findLineTimestampWithLookbehind(slice: []const u8, line_start: usize, fallback_year: u16) ?u64 {
    if (line_start < slice.len) {
        if (ingestor.parseUniversalLineTimestampNs(slice[line_start..], fallback_year)) |ns| return ns;
    }
    var cur = line_start;
    var steps: usize = 0;
    while (cur > 0 and steps < 32) : (steps += 1) {
        const prev_start = findLineStartAtOrBefore(slice, cur - 1);
        if (ingestor.parseUniversalLineTimestampNs(slice[prev_start..cur], fallback_year)) |ns| {
            return ns;
        }
        cur = prev_start;
    }
    return null;
}

pub const NarrowedTimeSlice = struct {
    sub_slice: []const u8,
    base_line_offset: u64,
    is_time_series: bool,
};

/// Performs O(log N) binary search over an `mmap` file slice for any time-series log file
/// (19-digit ns streams, ISO-8601, RFC3339, Log4j, Slash YMD, Nginx CLF, Syslog, JSONL),
/// returning the narrowed `[sub_start..sub_end]` slice, `base_line_offset`, and `is_time_series`.
/// Non-log files (code, HTML, Markdown, plain text) return `is_time_series = false` untouched.
pub fn narrowMmapSliceByTimeRange(
    slice: []const u8,
    start_ns: u64,
    end_ns: u64,
) NarrowedTimeSlice {
    return narrowMmapSliceByTimeRangeWithYear(slice, start_ns, end_ns, 2026);
}

pub fn narrowMmapSliceByTimeRangeWithYear(
    slice: []const u8,
    start_ns: u64,
    end_ns: u64,
    fallback_year: u16,
) NarrowedTimeSlice {
    if (slice.len < 10) {
        return .{ .sub_slice = slice, .base_line_offset = 0, .is_time_series = false };
    }

    // Skip leading blank lines if any
    var first_pos: usize = 0;
    while (first_pos < slice.len and (slice[first_pos] == '\n' or slice[first_pos] == '\r')) : (first_pos += 1) {}
    if (first_pos >= slice.len) {
        return .{ .sub_slice = slice, .base_line_offset = 0, .is_time_series = false };
    }

    const first_ns = ingestor.parseUniversalLineTimestampNs(slice[first_pos..], fallback_year) orelse {
        return .{ .sub_slice = slice, .base_line_offset = 0, .is_time_series = false };
    };

    // Inspect the last timestamped line near EOF to verify monotonic time-series ordering
    var end_trim = slice.len;
    while (end_trim > first_pos and (slice[end_trim - 1] == '\n' or slice[end_trim - 1] == '\r' or slice[end_trim - 1] == ' ')) {
        end_trim -= 1;
    }
    const last_line_start = findLineStartAtOrBefore(slice, end_trim);
    const last_ns = findLineTimestampWithLookbehind(slice[0..end_trim], last_line_start, fallback_year) orelse {
        return .{ .sub_slice = slice, .base_line_offset = 0, .is_time_series = false };
    };
    if (last_ns < first_ns) {
        return .{ .sub_slice = slice, .base_line_offset = 0, .is_time_series = false };
    }

    if (start_ns == 0 and end_ns == 0) {
        return .{ .sub_slice = slice, .base_line_offset = 0, .is_time_series = true };
    }

    // Whole-file range pruning: if [first_ns, last_ns] is completely outside [start_ns, end_ns], skip entire file!
    if ((start_ns > 0 and last_ns < start_ns) or (end_ns > 0 and first_ns > end_ns)) {
        return .{ .sub_slice = slice[0..0], .base_line_offset = 0, .is_time_series = true };
    }

    var sub_start: usize = 0;
    if (start_ns > 0 and first_ns < start_ns) {
        var lo: usize = 0;
        var hi: usize = slice.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const line_start = findLineStartAtOrBefore(slice, mid);
            const line_end = if (std.mem.indexOfScalarPos(u8, slice, line_start, '\n')) |nl|
                nl + 1
            else
                slice.len;

            if (findLineTimestampWithLookbehind(slice, line_start, fallback_year)) |line_ns| {
                if (line_ns < start_ns) {
                    lo = line_end;
                } else {
                    hi = line_start;
                }
            } else {
                return .{ .sub_slice = slice, .base_line_offset = 0, .is_time_series = true };
            }
        }
        sub_start = lo;
    }

    if (sub_start >= slice.len) {
        return .{ .sub_slice = slice[0..0], .base_line_offset = 0, .is_time_series = true };
    }

    var sub_end: usize = slice.len;
    if (end_ns > 0 and last_ns > end_ns) {
        var lo: usize = sub_start;
        var hi: usize = slice.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            var line_start = findLineStartAtOrBefore(slice, mid);
            if (line_start < lo) line_start = lo;
            const line_end = if (std.mem.indexOfScalarPos(u8, slice, line_start, '\n')) |nl|
                nl + 1
            else
                slice.len;

            if (findLineTimestampWithLookbehind(slice, line_start, fallback_year)) |line_ns| {
                if (line_ns <= end_ns) {
                    lo = line_end;
                } else {
                    hi = line_start;
                }
            } else {
                return .{ .sub_slice = slice, .base_line_offset = 0, .is_time_series = true };
            }
        }
        sub_end = lo;
    }

    if (sub_start >= sub_end) {
        return .{ .sub_slice = slice[0..0], .base_line_offset = 0, .is_time_series = true };
    }

    const base_lines = if (sub_start > 0) countNewlinesFast(slice[0..sub_start]) else 0;
    return .{
        .sub_slice = slice[sub_start..sub_end],
        .base_line_offset = base_lines,
        .is_time_series = true,
    };
}

const WorkerContext = struct {
    runner: *JobRunner,
    local_matcher: MatcherUnion,
    batch_arena: *std.heap.ArenaAllocator,
    batch_items: std.ArrayList(HitItem) = .empty,
    scratch_pool: *libwebgrep.Scratch,
    last_flush_ts: std.Io.Timestamp,

    fn searchOneTask(self: *WorkerContext, task: *FileTask) void {
        if (self.runner.shouldStop()) return;

        const started_from_beginning = (task.resume_after_line == 0);
        task.paused_at_soft_quota = false;

        var opened_parent: ?std.Io.Dir = null;
        defer if (opened_parent) |*d| d.close(self.runner.io);

        const parent_dir: std.Io.Dir = if (task.parent_dir_path) |p| blk: {
            opened_parent = std.Io.Dir.cwd().openDir(self.runner.io, p, .{}) catch {
                self.runner.had_scan_error.store(true, .release);
                return;
            };
            break :blk opened_parent.?;
        } else self.runner.root_dir;

        const compression: libwebgrep.Compression = if (file_api.hasCompressedExtension(task.base_name))
            .auto
        else
            .none;

        const replacement: ?[]const u8 = if (self.runner.req.replacement) |r|
            (if (r.len > 0) r else null)
        else
            null;

        const parsed_case = parseCaseMode(self.runner.req.case);
        const is_case_insensitive = switch (parsed_case) {
            .insensitive => true,
            .sensitive => false,
            .smart => !hasAsciiUpper(self.runner.req.pattern),
        };

        // Strong Consistency Config:
        // Never cap `max_source_bytes`, `max_request_bytes`, `max_output_bytes`, or `time_budget_ns`!
        // Files > 64 MiB (e.g. 91 MB, 99 MB, 195 MB, 203 MB logs) must be scanned 100% to EOF without silent truncation.
        const cfg = libwebgrep.SearchConfig{
            .line_numbers = true,
            .compression = compression,
            .whole_word = self.runner.req.wholeWord,
            .whole_line = self.runner.req.wholeLine,
            .invert = self.runner.req.invert,
            .contains = task.effective_contains,
            .excludes = task.effective_excludes,
            .filter_case_insensitive = is_case_insensitive,
            .filter_smart_case = (parsed_case == .smart),
            .contains_regexes = self.runner.contains_regexes,
            .excludes_regexes = self.runner.excludes_regexes,
            .replacement = replacement,
            .context = @min(self.runner.req.context, libwebgrep.SearchConfig.context_lines_hard_cap),
            .buffer_size = libwebgrep.SearchConfig.optimalBufferSize(self.runner.active_worker_count),
            .progress_interval = 512 * 1024,
            .max_source_bytes = null,
            .max_request_bytes = null,
            .max_output_bytes = null,
            .time_budget_ns = null,
            .allocator = self.runner.gpa,
            .decode_allocator = self.runner.gpa,
            .scratch_pool = self.scratch_pool,
            .cancel = self.runner.cancel_flag,
        };

        const fallback_year: u16 = if (task.mtime_ns > 0)
            ingestor.currentYearUtc(@intCast(@max(0, task.mtime_ns)))
        else
            2026;

        var sink = FileSink{
            .worker = self,
            .task = task,
            .rel_path = task.rel_path,
            .source_id = task.source_id,
            .source_name = task.source_name,
            .case_insensitive = is_case_insensitive,
            .fallback_year = fallback_year,
        };

        var hot_lease: ?search_cache.HotFileLease = null;
        if (self.runner.registry) |reg| {
            if (compression == .none and task.file_size > 0) {
                hot_lease = reg.search_cache.acquireHotFileSlice(
                    self.runner.io,
                    task.rel_path,
                    task.mtime_ns,
                    task.file_size,
                    task.inode,
                    parent_dir,
                    task.open_sub_path,
                    search_cache.MAX_HOT_FILE_MAP_BYTES,
                );
            }
        }
        defer if (hot_lease) |lease| {
            self.runner.registry.?.search_cache.releaseHotFileSlice(self.runner.io, lease.slot_idx);
        };

        const has_time_filter = (self.runner.time_start_ns > 0 or self.runner.time_end_ns > 0);

        const maybe_res = if (hot_lease) |lease| blk_mmap: {
            var active_slice = lease.slice;
            sink.full_slice = lease.slice;
            if (has_time_filter) {
                const narrowed = narrowMmapSliceByTimeRangeWithYear(
                    lease.slice,
                    self.runner.time_start_ns,
                    self.runner.time_end_ns,
                    fallback_year,
                );
                sink.is_time_series = narrowed.is_time_series;
                if (narrowed.is_time_series) {
                    active_slice = narrowed.sub_slice;
                    sink.base_line_offset = narrowed.base_line_offset;
                } else if (task.mtime_ns > 0) {
                    // Document / Code / HTML file: filter at file level via stat.mtime!
                    const mtime_u64: u64 = @intCast(@max(0, task.mtime_ns));
                    if ((self.runner.time_start_ns > 0 and mtime_u64 < self.runner.time_start_ns) or
                        (self.runner.time_end_ns > 0 and mtime_u64 > self.runner.time_end_ns))
                    {
                        active_slice = lease.slice[0..0];
                    }
                }
            }
            if (active_slice.len > 0 and
                @intFromPtr(active_slice.ptr) >= @intFromPtr(lease.slice.ptr) and
                @intFromPtr(active_slice.ptr) <= @intFromPtr(lease.slice.ptr) + lease.slice.len)
            {
                sink.active_slice_offset = @intFromPtr(active_slice.ptr) - @intFromPtr(lease.slice.ptr);
            }
            break :blk_mmap (switch (self.local_matcher) {
                .literal => |*f| libwebgrep.searchSlice(FileSink, &sink, active_slice, task.rel_path, f, cfg),
                .multi => |*m| libwebgrep.searchSlice(FileSink, &sink, active_slice, task.rel_path, m, cfg),
                .regex => |*r| libwebgrep.searchSlice(FileSink, &sink, active_slice, task.rel_path, r, cfg),
            } catch null);
        } else blk: {
            var file = parent_dir.openFile(self.runner.io, task.open_sub_path, .{ .allow_directory = false }) catch {
                self.runner.had_scan_error.store(true, .release);
                return;
            };
            defer file.close(self.runner.io);
            if (compression == .none) {
                sink.open_file = file;
            }

            if (has_time_filter and compression == .none) {
                var peek_buf: [256]u8 = undefined;
                const peek_n = file.readPositionalAll(self.runner.io, &peek_buf, 0) catch 0;
                var first_pos: usize = 0;
                while (first_pos < peek_n and (peek_buf[first_pos] == '\n' or peek_buf[first_pos] == '\r')) : (first_pos += 1) {}
                sink.is_time_series = first_pos < peek_n and
                    (ingestor.parseUniversalLineTimestampNs(peek_buf[first_pos..peek_n], fallback_year) != null);
                if (!sink.is_time_series and task.mtime_ns > 0) {
                    const mtime_u64: u64 = @intCast(@max(0, task.mtime_ns));
                    if ((self.runner.time_start_ns > 0 and mtime_u64 < self.runner.time_start_ns) or
                        (self.runner.time_end_ns > 0 and mtime_u64 > self.runner.time_end_ns))
                    {
                        break :blk (switch (self.local_matcher) {
                            .literal => |*f| libwebgrep.searchSlice(FileSink, &sink, "", task.rel_path, f, cfg),
                            .multi => |*m| libwebgrep.searchSlice(FileSink, &sink, "", task.rel_path, m, cfg),
                            .regex => |*r| libwebgrep.searchSlice(FileSink, &sink, "", task.rel_path, r, cfg),
                        } catch null);
                    }
                }
            }

            var read_buf: [65536]u8 = undefined;
            var file_reader = file.reader(self.runner.io, &read_buf);

            break :blk switch (self.local_matcher) {
                .literal => |*f| libwebgrep.searchReader(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, f, cfg),
                .multi => |*m| libwebgrep.searchReader(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, m, cfg),
                .regex => |*r| libwebgrep.searchReader(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, r, cfg),
            } catch null;
        };

        if (!task.counted_file_searched) {
            task.counted_file_searched = true;
            _ = self.runner.files_searched.fetchAdd(1, .monotonic);
        }
        if (!task.counted_file_matched and (sink.file_had_match or task.emitted_in_file > 0)) {
            task.counted_file_matched = true;
            _ = self.runner.files_matched.fetchAdd(1, .monotonic);
        }

        var task_scanned_complete = false;
        if (maybe_res) |res| {
            const bytes = if (res.bytes_searched > 0) res.bytes_searched else res.bytes_read;
            if (bytes > task.phase_bytes) {
                _ = self.runner.bytes_searched.fetchAdd(bytes - task.phase_bytes, .monotonic);
                task.phase_bytes = bytes;
            }
            task_scanned_complete = res.scanned_all and res.soft_error == null and res.limit_hit == .none;
            if (!task_scanned_complete and !task.paused_at_soft_quota and !self.runner.shouldStop()) {
                self.runner.had_scan_error.store(true, .release);
            }
        } else {
            self.runner.had_scan_error.store(true, .release);
        }

        if (started_from_beginning and
            task_scanned_complete and
            !self.runner.shouldStop() and
            !task.paused_at_soft_quota and
            !sink.file_had_match and
            task.emitted_in_file == 0)
        {
            if (self.runner.registry) |reg| {
                const is_plain_literal = switch (self.local_matcher) {
                    .literal => true,
                    else => false,
                };
                if (is_plain_literal and
                    self.runner.time_start_ns == 0 and
                    self.runner.time_end_ns == 0 and
                    std.mem.eql(u8, self.runner.req.mode, "literal") and
                    !self.runner.req.invert and
                    !self.runner.req.wholeWord and
                    !self.runner.req.wholeLine and
                    task.effective_contains.len == 0 and
                    task.effective_excludes.len == 0 and
                    self.runner.contains_regexes.len == 0 and
                    self.runner.excludes_regexes.len == 0)
                {
                    reg.search_cache.recordZeroHitFile(
                        self.runner.io,
                        task.rel_path,
                        task.mtime_ns,
                        task.file_size,
                        task.inode,
                        task.phase_bytes,
                        self.runner.req.pattern,
                        is_case_insensitive,
                    );
                }
            }
        }

        if (!self.runner.shouldStop()) {
            self.maybeFlushStreaming(true);
            self.runner.maybeSendProgress(0);
        }
    }

    /// Universal real-time streaming flush rule (identical across literal, multi, and regex modes):
    /// 1. First screen batch (`batches_flushed == 0`): flush immediately on the very first match (`count >= 1`).
    /// 2. Early batches (`batches_flushed < 4`): flush at 16 items or 16ms.
    /// 3. Steady streaming (`batches_flushed >= 4`): flush at 64 items or 25ms (~40fps).
    fn maybeFlushStreaming(self: *WorkerContext, force_time_check: bool) void {
        const count = self.batch_items.items.len;
        if (count == 0 or self.runner.send_failed.load(.acquire)) return;

        const flushed_so_far = self.runner.batches_flushed.load(.monotonic);
        if (flushed_so_far == 0) {
            _ = self.runner.batches_flushed.fetchAdd(1, .monotonic);
            self.flushBatch() catch {
                self.runner.send_failed.store(true, .release);
            };
            return;
        }

        const item_cap: usize = if (flushed_so_far < 4) 16 else 64;
        if (count >= item_cap) {
            _ = self.runner.batches_flushed.fetchAdd(1, .monotonic);
            self.flushBatch() catch {
                self.runner.send_failed.store(true, .release);
            };
            return;
        }

        if (force_time_check or flushed_so_far < 4 or count >= 4) {
            const min_ns: i64 = if (flushed_so_far < 4)
                16 * std.time.ns_per_ms
            else
                25 * std.time.ns_per_ms;
            const elapsed_ns = self.last_flush_ts.untilNow(self.runner.io, .awake).toNanoseconds();
            if (elapsed_ns >= min_ns) {
                _ = self.runner.batches_flushed.fetchAdd(1, .monotonic);
                self.flushBatch() catch {
                    self.runner.send_failed.store(true, .release);
                };
            }
        }
    }

    fn flushBatch(self: *WorkerContext) !void {
        if (self.batch_items.items.len == 0) return;
        defer {
            self.batch_items.clearRetainingCapacity();
            _ = self.batch_arena.reset(.retain_capacity);
            self.last_flush_ts = std.Io.Clock.awake.now(self.runner.io);
        }
        if (self.runner.send_failed.load(.acquire)) return;

        if (self.runner.registry != null) {
            self.runner.collected_hits_mutex.lockUncancelable(self.runner.io);
            defer self.runner.collected_hits_mutex.unlock(self.runner.io);
            if (!self.runner.collected_hits_overflow) {
                if (self.runner.collected_hits.items.len + self.batch_items.items.len > search_cache.MAX_ITEMS_PER_ENTRY) {
                    self.runner.collected_hits_overflow = true;
                } else {
                    const j_arena = self.runner.job_arena;
                    for (self.batch_items.items) |it| {
                        const spans_dup = j_arena.dupe(HitSpan, it.spans) catch {
                            self.runner.collected_hits_overflow = true;
                            break;
                        };
                        const file_dup = j_arena.dupe(u8, it.file) catch {
                            self.runner.collected_hits_overflow = true;
                            break;
                        };
                        const text_dup = j_arena.dupe(u8, it.text) catch {
                            self.runner.collected_hits_overflow = true;
                            break;
                        };
                        const prev_dup = if (it.prevText) |pt| (j_arena.dupe(u8, pt) catch null) else null;
                        const next_dup = if (it.nextText) |nt| (j_arena.dupe(u8, nt) catch null) else null;
                        const rep_dup = if (it.replaced) |r| (j_arena.dupe(u8, r) catch null) else null;
                        self.runner.collected_hits.append(j_arena, .{
                            .file = file_dup,
                            .line = it.line,
                            .col = it.col,
                            .text = text_dup,
                            .prevText = prev_dup,
                            .nextText = next_dup,
                            .replaced = rep_dup,
                            .isContext = it.isContext,
                            .spans = spans_dup,
                        }) catch {
                            self.runner.collected_hits_overflow = true;
                            break;
                        };
                    }
                }
            }
        }

        const hits_json = try file_api.stringifyAlloc(self.runner.gpa, HitsFrame{
            .id = self.runner.req.id,
            .items = self.batch_items.items,
        });
        defer self.runner.gpa.free(hits_json);

        self.runner.sender.send(hits_json) catch {
            self.runner.send_failed.store(true, .release);
        };
    }
};

const NeighborLines = struct {
    prev: ?[]const u8 = null,
    next: ?[]const u8 = null,
};

fn extractNeighborLines(slice: []const u8, pos_in_line: usize, partial_head: bool, partial_tail: bool) NeighborLines {
    if (slice.len == 0 or pos_in_line > slice.len) return .{};
    const line_start = findLineStartAtOrBefore(slice, pos_in_line);
    if (line_start == 0 and partial_head) return .{};
    const line_end = std.mem.indexOfScalarPos(u8, slice, line_start, '\n') orelse slice.len;

    var prev_line: ?[]const u8 = null;
    var cur_end = line_start;
    var b_steps: usize = 0;
    while (cur_end > 0 and b_steps < 3) : (b_steps += 1) {
        const p_end = cur_end - 1;
        const p_start = findLineStartAtOrBefore(slice, p_end);
        if (p_start == 0 and partial_head) break;
        const cand = std.mem.trimEnd(u8, slice[p_start..p_end], "\r");
        if (std.mem.trim(u8, cand, " \t").len > 0) {
            prev_line = cand;
            break;
        }
        cur_end = p_start;
    }

    var next_line: ?[]const u8 = null;
    var cur_start = if (line_end < slice.len) line_end + 1 else slice.len;
    var f_steps: usize = 0;
    while (cur_start < slice.len and f_steps < 3) : (f_steps += 1) {
        const n_end_opt = std.mem.indexOfScalarPos(u8, slice, cur_start, '\n');
        if (n_end_opt == null and partial_tail) break;
        const n_end = n_end_opt orelse slice.len;
        const cand = std.mem.trimEnd(u8, slice[cur_start..n_end], "\r");
        if (std.mem.trim(u8, cand, " \t").len > 0) {
            next_line = cand;
            break;
        }
        cur_start = if (n_end < slice.len) n_end + 1 else slice.len;
    }

    return .{ .prev = prev_line, .next = next_line };
}

fn unwrapOffset(val: anytype) u64 {
    return switch (@typeInfo(@TypeOf(val))) {
        .optional => val orelse 0,
        .int, .comptime_int => @intCast(val),
        else => 0,
    };
}

const FileSink = struct {
    worker: *WorkerContext,
    task: *FileTask,
    rel_path: []const u8,
    source_id: []const u8 = "",
    source_name: []const u8 = "",
    case_insensitive: bool = true,
    file_had_match: bool = false,
    base_line_offset: u64 = 0,
    is_time_series: bool = false,
    fallback_year: u16 = 2026,
    last_line_ns: u64 = 0,
    full_slice: ?[]const u8 = null,
    active_slice_offset: usize = 0,
    open_file: ?std.Io.File = null,

    fn toLineEvent(self: *const FileSink, line: libwebgrep.Line) libwebgrep.LineEvent {
        const u16_column = if (line.matches.len > 0)
            @as(u64, line.matches[0].u16_start) + 1
        else
            line.u16_column;
        return .{
            .source_id = self.rel_path,
            .line_number = (line.number orelse 0) + self.base_line_offset,
            .column = line.column,
            .u16_column = u16_column,
            .absolute_offset = line.offset,
            .raw_offset = line.raw_offset,
            .bytes = line.bytes,
            .text = if (line.text.len == 0) line.bytes else line.text,
            .raw = if (line.raw.len == 0) line.bytes else line.raw,
            .replaced = line.replaced,
            .matches = line.matches,
            .truncated = line.truncated,
            .line_len = line.line_len,
            .window_start = line.window_start,
            .binary_status = line.binary_status,
        };
    }

    pub fn matched(self: *FileSink, line: libwebgrep.Line) bool {
        return self.event(.{ .match = self.toLineEvent(line) });
    }

    pub fn context(self: *FileSink, line: libwebgrep.Line) bool {
        return self.event(.{ .context = self.toLineEvent(line) });
    }

    pub fn progress(self: *FileSink, bytes_searched: u64, match_count: u64, matched_lines: u64) bool {
        return self.event(.{ .progress = .{
            .source_id = self.rel_path,
            .bytes_searched = bytes_searched,
            .matches = match_count,
            .matched_lines = matched_lines,
        } });
    }

    pub fn event(self: *FileSink, ev: libwebgrep.Event) bool {
        const runner = self.worker.runner;
        if (runner.shouldStop()) return false;

        switch (ev) {
            .match => |line| {
                const line_no = if (line.line_number > 0) line.line_number else 1;
                if (line_no <= self.task.resume_after_line) {
                    return true;
                }

                if ((runner.time_start_ns > 0 or runner.time_end_ns > 0) and self.is_time_series) {
                    const raw_text = if (line.text.len > 0) line.text else line.bytes;
                    const line_ns = ingestor.parseUniversalLineTimestampNs(raw_text, self.fallback_year) orelse self.last_line_ns;
                    if (line_ns > 0) {
                        self.last_line_ns = line_ns;
                        if (runner.time_start_ns > 0 and line_ns < runner.time_start_ns) return true;
                        if (runner.time_end_ns > 0 and line_ns > runner.time_end_ns) return true;
                    }
                }

                const max_res = runner.req.maxResults;
                if (max_res > 0 and runner.total_matches.load(.monotonic) >= max_res) {
                    runner.hit_max_results.store(true, .release);
                    return false;
                }

                const prev_total = runner.total_matches.fetchAdd(1, .monotonic);
                if (max_res > 0 and prev_total >= max_res) {
                    _ = runner.total_matches.fetchSub(1, .monotonic);
                    runner.hit_max_results.store(true, .release);
                    return false;
                }

                self.file_had_match = true;
                self.task.emitted_in_file += 1;
                self.task.resume_after_line = line_no;
                _ = runner.matched_lines.fetchAdd(1, .monotonic);

                self.appendLineEvent(line, false, 0) catch {
                    return false;
                };

                self.worker.maybeFlushStreaming(false);
                if (runner.send_failed.load(.acquire)) return false;

                if (max_res > 0 and prev_total + 1 >= max_res) {
                    runner.hit_max_results.store(true, .release);
                    return false;
                }

                if (self.task.soft_quota > 0 and self.task.emitted_in_file >= self.task.soft_quota) {
                    self.task.paused_at_soft_quota = true;
                    return false;
                }
                return true;
            },
            .context => |line| {
                const line_no = if (line.line_number > 0) line.line_number else 1;
                if (line_no <= self.task.resume_after_line) {
                    return true;
                }
                self.appendLineEvent(line, true, 0) catch {
                    return false;
                };
                self.worker.maybeFlushStreaming(false);
                if (runner.send_failed.load(.acquire)) return false;
                return true;
            },
            .progress => |prog| {
                if (prog.bytes_searched > self.task.phase_bytes) {
                    _ = runner.bytes_searched.fetchAdd(prog.bytes_searched - self.task.phase_bytes, .monotonic);
                    self.task.phase_bytes = prog.bytes_searched;
                }
                self.worker.maybeFlushStreaming(true);
                runner.maybeSendProgress(0);
                return !runner.shouldStop();
            },
            else => return true,
        }
    }

    fn appendLineEvent(self: *FileSink, line: libwebgrep.LineEvent, is_context: bool, max_spans: usize) !void {
        const arena = self.worker.batch_arena.allocator();
        const file_duped = try arena.dupe(u8, self.rel_path);

        const raw_text = if (line.text.len > 0) line.text else line.bytes;
        const safe_text = try file_api.sanitizeUtf8Truncated(arena, raw_text, 4096);
        if (raw_text.len > 4096 or line.truncated or safe_text.ptr != raw_text.ptr) {
            self.worker.runner.had_non_exact_line.store(true, .release);
        }
        const text_duped = if (safe_text.ptr == raw_text.ptr)
            try arena.dupe(u8, safe_text)
        else
            safe_text;

        const replaced_duped: ?[]const u8 = if (line.replaced) |rep| blk: {
            const safe_rep = try file_api.sanitizeUtf8Truncated(arena, rep, 1024);
            break :blk if (safe_rep.ptr == rep.ptr) try arena.dupe(u8, safe_rep) else safe_rep;
        } else null;

        var prev_duped: ?[]const u8 = null;
        var next_duped: ?[]const u8 = null;

        var spans_list: std.ArrayList(HitSpan) = .empty;
        const runner = self.worker.runner;
        if (!is_context) {
            const raw_off_u64 = blk_off: {
                const r_off = unwrapOffset(line.raw_offset);
                break :blk_off if (r_off > 0) r_off else unwrapOffset(line.absolute_offset);
            };
            var win_buf: [1536]u8 = undefined;
            const neighbors: NeighborLines = if (self.full_slice) |full| blk_full: {
                const slice_start = @intFromPtr(full.ptr);
                const slice_end = slice_start + full.len;
                const bytes_ptr = @intFromPtr(line.bytes.ptr);
                const approx_pos: usize = if (line.bytes.len > 0 and bytes_ptr >= slice_start and bytes_ptr <= slice_end)
                    bytes_ptr - slice_start
                else
                    @min(full.len, self.active_slice_offset + @as(usize, @intCast(raw_off_u64)));
                break :blk_full extractNeighborLines(full, approx_pos, false, false);
            } else if (self.open_file) |f| blk_file: {
                const win_start: u64 = raw_off_u64 -| 512;
                const n = f.readPositionalAll(runner.io, &win_buf, win_start) catch 0;
                if (n > 0 and raw_off_u64 >= win_start and (raw_off_u64 - win_start) <= n) {
                    break :blk_file extractNeighborLines(
                        win_buf[0..n],
                        @intCast(raw_off_u64 - win_start),
                        win_start > 0,
                        n == win_buf.len,
                    );
                }
                break :blk_file .{};
            } else .{};

            if (neighbors.prev) |rp| {
                if (file_api.sanitizeUtf8Truncated(arena, rp, 240)) |sp| {
                    prev_duped = if (sp.ptr == rp.ptr) (arena.dupe(u8, sp) catch null) else sp;
                } else |_| {}
            }
            if (neighbors.next) |rn| {
                if (file_api.sanitizeUtf8Truncated(arena, rn, 240)) |sn| {
                    next_duped = if (sn.ptr == rn.ptr) (arena.dupe(u8, sn) catch null) else sn;
                } else |_| {}
            }

            if (runner.swapped_primary_regex_first and runner.contains_regexes.len > 0) {
                const primary_re = &runner.contains_regexes[0];
                var bpos: usize = 0;
                while (bpos <= text_duped.len) {
                    const hit = primary_re.findReadOnly(text_duped, bpos, .leftmost_first) orelse break;
                    if (hit.start < bpos or hit.end > text_duped.len) break;
                    if (hit.end > hit.start) {
                        try spans_list.append(arena, .{
                            .start = utf8ByteToUtf16Offset(text_duped, hit.start),
                            .end = utf8ByteToUtf16Offset(text_duped, hit.end),
                        });
                    }
                    if (hit.end <= bpos) break;
                    bpos = hit.end;
                }
            } else if (runner.swapped_primary_finder) |pf_val| {
                var pf = pf_val;
                var bpos: usize = 0;
                while (bpos <= text_duped.len) {
                    const hit = pf.find(text_duped, bpos, .leftmost_first) orelse break;
                    if (hit.start < bpos or hit.end > text_duped.len) break;
                    if (hit.end > hit.start) {
                        try spans_list.append(arena, .{
                            .start = utf8ByteToUtf16Offset(text_duped, hit.start),
                            .end = utf8ByteToUtf16Offset(text_duped, hit.end),
                        });
                    }
                    if (hit.end <= bpos) break;
                    bpos = hit.end;
                }
            } else if (line.matches.len > 0) {
                const span_count = if (max_spans > 0) @min(line.matches.len, max_spans) else line.matches.len;
                try spans_list.ensureTotalCapacity(arena, span_count);
                for (line.matches[0..span_count]) |sp| {
                    spans_list.appendAssumeCapacity(.{
                        .start = sp.u16_start,
                        .end = sp.u16_end,
                    });
                }
            }
        }

        const col: u64 = if (spans_list.items.len > 0)
            @intCast(spans_list.items[0].start + 1)
        else
            line.u16_column orelse line.column orelse 1;

        try self.worker.batch_items.append(self.worker.runner.gpa, .{
            .file = file_duped,
            .line = if (line.line_number > 0) line.line_number else 1,
            .col = col,
            .text = text_duped,
            .prevText = prev_duped,
            .nextText = next_duped,
            .replaced = replaced_duped,
            .isContext = is_context,
            .spans = spans_list.items,
        });
    }

    fn utf8ByteToUtf16Offset(text: []const u8, byte_idx: usize) usize {
        const limit = @min(byte_idx, text.len);
        var u16_pos: usize = 0;
        var i: usize = 0;
        while (i < limit) {
            const b = text[i];
            if (b < 0x80) {
                u16_pos += 1;
                i += 1;
            } else if (b < 0xE0) {
                u16_pos += 1;
                i += @min(2, limit - i);
            } else if (b < 0xF0) {
                u16_pos += 1;
                i += @min(3, limit - i);
            } else {
                u16_pos += 2;
                i += @min(4, limit - i);
            }
        }
        return u16_pos;
    }
};

test "search_job literal, multi, regex, and replacement over root directory" {
    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        frames: std.ArrayList([]u8) = .empty,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const copy = try self.allocator.dupe(u8, json_text);
            try self.frames.append(self.allocator, copy);
        }

        fn deinit(self: *@This()) void {
            for (self.frames.items) |f| self.allocator.free(f);
            self.frames.deinit(self.allocator);
        }
    };

    var collector = Collector{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    defer collector.deinit();

    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{ .iterate = true });
    defer root_dir.close(std.testing.io);

    var cancel = std.atomic.Value(bool).init(false);

    try executeSearch(
        std.testing.allocator,
        std.testing.io,
        root_dir,
        .{
            .id = 7,
            .pattern = "sanitizeRelPath",
            .mode = "literal",
            .paths = &.{"src"},
            .types = &.{"zig"},
        },
        &cancel,
        .{ .ctx = &collector, .sendFn = Collector.send },
    );

    try std.testing.expect(collector.frames.items.len >= 2);
    // First frame should be hits, last frame should be done
    try std.testing.expect(std.mem.indexOf(u8, collector.frames.items[0], "\"type\":\"hits\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, collector.frames.items[collector.frames.items.len - 1], "\"type\":\"done\"") != null);
}

test "matchesProjectScopeToken only matches project name or UUID id" {
    const src_id = "550e8400-e29b-41d4-a716-446655440000";
    const src_name = "webgrep";

    try std.testing.expect(JobRunner.matchesProjectScopeToken(src_id, src_name, "webgrep"));
    try std.testing.expect(JobRunner.matchesProjectScopeToken(src_id, src_name, "WEBGREP"));
    try std.testing.expect(JobRunner.matchesProjectScopeToken(src_id, src_name, src_id));
    try std.testing.expect(!JobRunner.matchesProjectScopeToken(src_id, src_name, "libwebgrep"));
    try std.testing.expect(!JobRunner.matchesProjectScopeToken(src_id, src_name, "webgrep/src/main.zig"));
}

test "progressive search order commutativity: regex+literal == literal+regex and case-insensitive contains" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var root_dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer root_dir.close(io);

    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Regex first ("pub\\s+fn"), Literal second ("executesearch")
    var c1 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 1,
        .pattern = "pub\\s+fn",
        .mode = "regex",
        .case = "insensitive",
        .contains = &.{"executesearch"},
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &c1, .sendFn = Collector.send });

    // 2. Literal first ("executesearch"), Regex second ("pub\\s+fn")
    var c2 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 2,
        .pattern = "executesearch",
        .mode = "regex",
        .case = "insensitive",
        .contains = &.{"pub\\s+fn"},
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &c2, .sendFn = Collector.send });

    try std.testing.expect(c1.matched_lines > 0);
    try std.testing.expectEqual(c1.matched_lines, c2.matched_lines);

    // 3. Mixed multiple regexes + multiple literals + regex/literal excludes in 4 permutations (with smart case)
    var m1 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 3,
        .pattern = "pub\\s+fn",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "With\\w+", "executesearch", "WithRegistry(" },
        .excludes = &.{ "nonexistent_\\d+", "never_match_xyz" },
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &m1, .sendFn = Collector.send });

    var m2 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 4,
        .pattern = "With\\w+",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "executesearch", "pub\\s+fn", "WithRegistry(" },
        .excludes = &.{ "never_match_xyz", "nonexistent_\\d+" },
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &m2, .sendFn = Collector.send });

    var m3 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 5,
        .pattern = "executesearch",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "WithRegistry(", "With\\w+", "pub\\s+fn" },
        .excludes = &.{ "nonexistent_\\d+", "never_match_xyz" },
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &m3, .sendFn = Collector.send });

    var m4 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 6,
        .pattern = "WithRegistry(",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "executesearch", "With\\w+", "pub\\s+fn" },
        .excludes = &.{ "never_match_xyz", "nonexistent_\\d+" },
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &m4, .sendFn = Collector.send });

    try std.testing.expect(m1.matched_lines > 0);
    try std.testing.expectEqual(m1.matched_lines, m2.matched_lines);
    try std.testing.expectEqual(m1.matched_lines, m3.matched_lines);
    try std.testing.expectEqual(m1.matched_lines, m4.matched_lines);

    // 4. Scoped `$r(xxxxxxx)` syntax in `literal` mode, mixed with literals (including unescaped parens) and context=2
    var s1 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 7,
        .pattern = "$r(pub\\s+fn)",
        .mode = "literal",
        .case = "smart",
        .context = 2,
        .contains = &.{ "WithRegistry(", "$r(With\\w+)", "executesearch" },
        .excludes = &.{"$r(nonexistent_\\d+)"},
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &s1, .sendFn = Collector.send });

    var s2 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 8,
        .pattern = "WithRegistry(",
        .mode = "literal",
        .case = "smart",
        .context = 2,
        .contains = &.{ "$r(pub\\s+fn)", "executesearch", "$r(With\\w+)" },
        .excludes = &.{"$r(nonexistent_\\d+)"},
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &s2, .sendFn = Collector.send });

    try std.testing.expectEqual(m1.matched_lines, s1.matched_lines);
    try std.testing.expectEqual(s1.matched_lines, s2.matched_lines);
}

test "heat-weighted elastic water-filling: single file gets full maxResults and hotter file gets more quota" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    try tmp.dir.createDirPath(io, "logs");

    // Create 3 files: cold.log (200 matches), hot.log (200 matches), empty.log (0 matches)
    {
        var f_cold = try tmp.dir.createFile(io, "logs/cold.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_cold.writer(io, &w_buf);
        for (0..200) |i| {
            try fw.interface.print("record={d} tag=COMMON_HIT only_in_cold\n", .{i});
        }
        try fw.interface.flush();
        f_cold.close(io);
    }
    {
        var f_hot = try tmp.dir.createFile(io, "logs/hot.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_hot.writer(io, &w_buf);
        for (0..200) |i| {
            try fw.interface.print("record={d} tag=COMMON_HIT only_in_hot\n", .{i});
        }
        try fw.interface.flush();
        f_hot.close(io);
    }
    {
        var f_empty = try tmp.dir.createFile(io, "logs/empty.log", .{ .truncate = true });
        var w_buf: [256]u8 = undefined;
        var fw = f_empty.writer(io, &w_buf);
        try fw.interface.writeAll("unrelated line\n");
        try fw.interface.flush();
        f_empty.close(io);
    }

    const logs_dir_path = try std.fmt.allocPrint(arena, "{s}/logs", .{tmp_path});
    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "logs",
        .config = .{ .path = logs_dir_path },
        .enabled = true,
    });

    // Boost access heat of logs/hot.log significantly
    reg.recordFileHeat(io, "logs/hot.log", 1200);

    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        hot_hits: usize = 0,
        cold_hits: usize = 0,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);

            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                for (parsed.value.items) |it| {
                    if (std.mem.eql(u8, it.file, "logs/hot.log")) self.hot_hits += 1;
                    if (std.mem.eql(u8, it.file, "logs/cold.log")) self.cold_hits += 1;
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // Case 1: Only 1 file (`only_in_cold`) matches among 3 files, with maxResults = 150.
    // Even though initial Phase 1 soft quota is < 150, Phase 2 water-filling gives it all 150!
    var c_single = Collector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 10,
        .pattern = "only_in_cold",
        .maxResults = 150,
    }, &cancel, .{ .ctx = &c_single, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 150), c_single.matched_lines);
    try std.testing.expectEqual(@as(usize, 150), c_single.cold_hits);

    // Case 2: Both hot.log and cold.log match `COMMON_HIT`, with maxResults = 120.
    // hot.log (higher heat score) receives strictly more quota than cold.log, and both > 0, summing to 120!
    var c_both = Collector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 11,
        .pattern = "COMMON_HIT",
        .maxResults = 120,
    }, &cancel, .{ .ctx = &c_both, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 120), c_both.matched_lines);
    try std.testing.expectEqual(@as(usize, 120), c_both.hot_hits + c_both.cold_hits);
    try std.testing.expect(c_both.hot_hits > c_both.cold_hits);
    try std.testing.expect(c_both.cold_hits > 0);
}

test "multi-tier millisecond search cache: L1 exact, L2 progressive superset, L3 negative file pruning, and mtime invalidation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    try tmp.dir.createDirPath(io, "svc");
    {
        var f_orders = try tmp.dir.createFile(io, "svc/orders.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_orders.writer(io, &w_buf);
        for (0..50) |i| {
            const status = if (i % 2 == 0) "FULFILLED" else "CANCELLED";
            const region = if (i % 5 == 0) "APAC" else "EMEA";
            try fw.interface.print("order=ORD-2026-{d} status={s} region={s}\n", .{ i, status, region });
        }
        try fw.interface.flush();
        f_orders.close(io);
    }
    {
        var f_audit = try tmp.dir.createFile(io, "svc/audit.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_audit.writer(io, &w_buf);
        for (0..50) |i| {
            try fw.interface.print("audit=AUD-{d} action=LOGIN user=admin\n", .{i});
        }
        try fw.interface.flush();
        f_audit.close(io);
    }

    const svc_dir_path = try std.fmt.allocPrint(arena, "{s}/svc", .{tmp_path});
    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "svc",
        .config = .{ .path = svc_dir_path },
        .enabled = true,
    });

    const CacheCollector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        matched_lines: u64 = 0,
        cache_hit: [32]u8 = undefined,
        cache_hit_len: usize = 0,

        fn tier(self: *const @This()) []const u8 {
            return self.cache_hit[0..self.cache_hit_len];
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);

            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                const ch = parsed.value.cacheHit;
                const copy_len = @min(ch.len, self.cache_hit.len);
                @memcpy(self.cache_hit[0..copy_len], ch[0..copy_len]);
                self.cache_hit_len = copy_len;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Cold search for "ORD-2026-" (matches 50 lines in orders.log, 0 in audit.log, limitHit == "none")
    var c1 = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 1,
        .pattern = "ORD-2026-",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c1, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 50), c1.matched_lines);
    try std.testing.expectEqualStrings("none", c1.tier());

    // 2. Repeat identical search -> hits Tier L1 ("exact")
    var c2 = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 2,
        .pattern = "ORD-2026-",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c2, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 50), c2.matched_lines);
    try std.testing.expectEqualStrings("exact", c2.tier());

    // 3. Progressive space refinement: add contains=["FULFILLED"] and excludes=["APAC"] -> hits Tier L2 ("superset")
    var c3 = CacheCollector{ .allocator = gpa, .io = io };
    const inc = [_][]const u8{"FULFILLED"};
    const exc = [_][]const u8{"APAC"};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3,
        .pattern = "ORD-2026-",
        .contains = &inc,
        .excludes = &exc,
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c3, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 20), c3.matched_lines);
    try std.testing.expectEqualStrings("superset", c3.tier());

    // 4. Longer literal superstring "ORD-2026-10" when parent "ORD-2026-" is complete -> hits Tier L2 ("superset") in RAM!
    var c4 = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 4,
        .pattern = "ORD-2026-10",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c4, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c4.matched_lines);
    try std.testing.expectEqualStrings("superset", c4.tier());

    // 5. Truncated search ("AUD-" with maxResults = 10 -> limitHit = true, orders.log has 0 hits for "AUD-"),
    // followed by "AUD-1" -> orders.log is pruned by Tier L3 ("pruned")!
    var c5_init = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 5,
        .pattern = "AUD-",
        .maxResults = 10,
    }, &cancel, .{ .ctx = &c5_init, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 10), c5_init.matched_lines);

    var c5_pruned = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 6,
        .pattern = "AUD-15",
        .maxResults = 10,
    }, &cancel, .{ .ctx = &c5_pruned, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c5_pruned.matched_lines);
    try std.testing.expectEqualStrings("pruned", c5_pruned.tier());

    // 6. Zero Dirty-Read Verification: modify orders.log on disk (adding a 51st match "ORD-2026-99"),
    // and verify that L1/L2/L4 caches immediately detect the (mtime_ns, file_size) change on orders.log
    // (returning 51 matches instead of 50), while unmodified audit.log remains pruned by L3 ("pruned")!
    {
        var f_orders = try tmp.dir.createFile(io, "svc/orders.log", .{});
        var buf: [4096]u8 = undefined;
        var fw = f_orders.writer(io, &buf);
        for (0..50) |i| {
            const status = if (i % 2 == 0) "FULFILLED" else "PENDING";
            const region = if (i % 5 == 0) "APAC" else "EMEA";
            try fw.interface.print("2026-10-30 INFO order=ORD-2026-{d:0>2} status={s} region={s}\n", .{ i, status, region });
        }
        try fw.interface.print("2026-10-30 INFO order=ORD-2026-99 status=FULFILLED region=EMEA\n", .{});
        try fw.interface.flush();
        f_orders.close(io);
    }

    var c6_fresh = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 7,
        .pattern = "ORD-2026-",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c6_fresh, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 51), c6_fresh.matched_lines);
    try std.testing.expectEqualStrings("pruned", c6_fresh.tier());
}

test "strong consistency: >4096-byte long lines never miss L2 contains/excludes and wholeWord+contains never false-matches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    try tmp.dir.createDirPath(io, "strict");
    {
        var f_long = try tmp.dir.createFile(io, "strict/long_line.log", .{ .truncate = true });
        var w_buf: [8192]u8 = undefined;
        var fw = f_long.writer(io, &w_buf);
        try fw.interface.writeAll("PRIMARY_HEAD_TOKEN ");
        for (0..5000) |_| {
            try fw.interface.writeAll("x");
        }
        try fw.interface.writeAll(" SECONDARY_TAIL_TOKEN_AT_5000\n");
        // Second line for wholeWord + contains test: "err" is inside "my_err_code" (not a whole word!), while "LONGER_CONTAINS_ANCHOR" is present
        try fw.interface.writeAll("prefix my_err_code LONGER_CONTAINS_ANCHOR\n");
        // Third line where "err" IS a whole word and "LONGER_CONTAINS_ANCHOR" is present
        try fw.interface.writeAll("prefix err LONGER_CONTAINS_ANCHOR\n");
        try fw.interface.flush();
        f_long.close(io);
    }

    const strict_dir_path = try std.fmt.allocPrint(arena, "{s}/strict", .{tmp_path});
    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "strict",
        .config = .{ .path = strict_dir_path },
        .enabled = true,
    });

    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Search "PRIMARY_HEAD_TOKEN" first (caches the >5000-byte line whose display text was truncated to 4096 bytes)
    var c_head = Collector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 1,
        .pattern = "PRIMARY_HEAD_TOKEN",
        .maxResults = 100,
    }, &cancel, .{ .ctx = &c_head, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 1), c_head.matched_lines);

    // 2. Follow-up progressive search adding `contains = ["SECONDARY_TAIL_TOKEN_AT_5000"]` (which sits at byte 5020 > 4096).
    // Because `all_lines_exact == false`, Tier L2 refuses to filter the truncated 4096-byte preview in RAM and instead scans the full file, finding all 1 match!
    var c_tail = Collector{ .allocator = gpa, .io = io };
    const tail_inc = [_][]const u8{"SECONDARY_TAIL_TOKEN_AT_5000"};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 2,
        .pattern = "PRIMARY_HEAD_TOKEN",
        .contains = &tail_inc,
        .maxResults = 100,
    }, &cancel, .{ .ctx = &c_tail, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 1), c_tail.matched_lines);

    // 3. Verify `wholeWord = true` with a longer `contains` token only matches the line where `err` is a true whole word (1 match, not 2!)
    var c_word = Collector{ .allocator = gpa, .io = io };
    const word_inc = [_][]const u8{"LONGER_CONTAINS_ANCHOR"};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3,
        .pattern = "err",
        .wholeWord = true,
        .contains = &word_inc,
        .maxResults = 100,
    }, &cancel, .{ .ctx = &c_word, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 1), c_word.matched_lines);
}

test "strong consistency: >64MiB files (91MB, 195MB, 203MB) scan 100% to EOF and find tail needles without truncation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Only run if testdata/ large files exist in workspace
    var td_dir = std.Io.Dir.cwd().openDir(io, "testdata", .{ .iterate = true }) catch return;
    defer td_dir.close(io);
    _ = td_dir.statFile(io, "gateway-logs/access_large.kv.log", .{}) catch return;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    var td_real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const td_path_len = try td_dir.realPath(io, &td_real_buf);
    const td_abs_path = try arena.dupe(u8, td_real_buf[0..td_path_len]);

    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "testdata",
        .config = .{ .path = td_abs_path },
        .enabled = true,
    });

    const TailCollector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        matched_lines: u64 = 0,
        bytes_searched: u64 = 0,
        cache_hit: [32]u8 = undefined,
        cache_hit_len: usize = 0,

        fn tier(self: *const @This()) []const u8 {
            return self.cache_hit[0..self.cache_hit_len];
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.bytes_searched = parsed.value.bytesSearched;
                const ch = parsed.value.cacheHit;
                const copy_len = @min(ch.len, self.cache_hit.len);
                @memcpy(self.cache_hit[0..copy_len], ch[0..copy_len]);
                self.cache_hit_len = copy_len;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Tail needle `ORD-20261029-250000` across 91 MB `ecommerce_orders.jsonl:150000`, 99 MB `upstream_trace_large.log:150000`,
    // and 195 MB `transactions_large.jsonl:150000` -> must find all 3 matches (previously truncated at 64 MiB!)
    var c_91m = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 1,
        .pattern = "ORD-20261029-250000",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_91m, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_91m.matched_lines);
    try std.testing.expect(c_91m.bytes_searched > 500 * 1024 * 1024);

    // 2. Repeat identical search -> hits Tier L1 ("exact") with all 3 matches
    var c_91m_l1 = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 2,
        .pattern = "ORD-20261029-250000",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_91m_l1, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_91m_l1.matched_lines);
    try std.testing.expectEqualStrings("exact", c_91m_l1.tier());

    // 2b. Progressive L2 narrowing to `SW-INFINIBAND-800G` (at 91 MB tail of `ecommerce_orders.jsonl`) -> 1 match via Tier L2 ("superset")
    var c_91m_l2 = TailCollector{ .allocator = gpa, .io = io };
    const inc_sw = [_][]const u8{"SW-INFINIBAND-800G"};
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 20,
        .pattern = "ORD-20261029-250000",
        .contains = &inc_sw,
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_91m_l2, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_91m_l2.matched_lines);
    try std.testing.expectEqualStrings("superset", c_91m_l2.tier());

    // 3. Tail needle at the very end of 195 MB `transactions_large.jsonl` (`ORD-20261029-700000`)
    var c_195m = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 3,
        .pattern = "ORD-20261029-700000",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_195m, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_195m.matched_lines);

    // 4. Tail needle at the very end of 203 MB `access_large.kv.log` (`CRITICAL_NEEDLE_EVENT_1000000`)
    var c_203m = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 4,
        .pattern = "CRITICAL_NEEDLE_EVENT_",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_203m, .sendFn = TailCollector.send });
    try std.testing.expect(c_203m.matched_lines >= 3);

    // 5. Progressive L2 narrowing on 203 MB file (`CRITICAL_NEEDLE_EVENT_` + `contains: ["1000000"]`) -> hits Tier L2 ("superset")
    var c_203m_l2 = TailCollector{ .allocator = gpa, .io = io };
    const inc_1m = [_][]const u8{"1000000"};
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 5,
        .pattern = "CRITICAL_NEEDLE_EVENT_",
        .contains = &inc_1m,
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_203m_l2, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_203m_l2.matched_lines);
    try std.testing.expectEqualStrings("superset", c_203m_l2.tier());

    // 6. Scoped `$w(ErrorCode)` and `$cw(ErrorCode)` parity with `wholeWord: true` (`rg -s -w ErrorCode`) on testdata/
    var c_ww_native = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 6,
        .pattern = "ErrorCode",
        .case = "sensitive",
        .wholeWord = true,
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_ww_native, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_ww_native.matched_lines);

    var c_scoped_w = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 7,
        .pattern = "$w(ErrorCode)",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_scoped_w, .sendFn = TailCollector.send });
    try std.testing.expectEqual(c_ww_native.matched_lines, c_scoped_w.matched_lines);

    var c_scoped_cw = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 8,
        .pattern = "$cw(ErrorCode)",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_scoped_cw, .sendFn = TailCollector.send });
    try std.testing.expectEqual(c_ww_native.matched_lines, c_scoped_cw.matched_lines);
}

test "search_job: scoped whole-word modifiers ($w, $cw, $rw, $rcw) on indented lines match rg -w semantics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Indented code and log lines where byte 0 is space/tab or punctuation (non-word character)
    try tmp.dir.writeFile(io, .{
        .sub_path = "indented.zig",
        .data = "pub const Engine = struct {\n" ++
            "    id: u64 = 1001,\n" ++
            "    user_id: u64 = 2002,\n" ++
            "    pub fn check(id: u64) ErrorCode {\n" ++
            "        const err = ErrorCode.Timeout;\n" ++
            "        const fake = MyErrorCode;\n" ++
            "        const lower = errorcode;\n" ++
            "        // partial word first, then exact whole word on the same indented line:\n" ++
            "        const combo = ErrorCode2 + ErrorCode;\n" ++
            "        return err;\n" ++
            "    }\n" ++
            "};\n" ++
            "\tid = 4096; // tab-indented whole word + 4-digit number\n" ++
            "    code_5digits = 12345;\n" ++
            "    port = 8080;\n",
    });

    const CountCollector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        matched_lines: u64 = 0,
        total_matches: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.total_matches = parsed.value.totalMatches;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. `$w(id)` on indented lines: matches `    id: u64`, `    pub fn check(id: u64)`, and `\tid = 4096;` (3 lines),
    //    must NOT match `user_id`!
    var c_w_id = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 1,
        .pattern = "$w(id)",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_w_id, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_w_id.matched_lines);

    // 2. `$cw(ErrorCode)` (case-sensitive + whole-word): matches lines 4, 5, and 9 (`ErrorCode2 + ErrorCode`),
    //    must NOT match `MyErrorCode` (line 6) or `errorcode` (line 7)!
    var c_cw_err = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 2,
        .pattern = "$cw(ErrorCode)",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_cw_err, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_cw_err.matched_lines);

    // 3. `$w(ErrorCode)` with case="insensitive": matches lines 4, 5, 7 (`errorcode`), and 9 (`ErrorCode2 + ErrorCode`) = 4 lines
    var c_w_err_ci = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 3,
        .pattern = "$w(ErrorCode)",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_w_err_ci, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_w_err_ci.matched_lines);

    // 4. `$rw(\d{4})` (regex + whole-word): matches `1001`, `2002`, `4096`, `8080` (4 lines),
    //    must NOT match `12345` (5 digits)!
    var c_rw_digits = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 4,
        .pattern = "$rw(\\d{4})",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_rw_digits, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_rw_digits.matched_lines);

    // 5. Raw regex `\b\d{4}\b` in `mode: "regex"` on indented lines -> also 4 lines
    var c_raw_re = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 5,
        .pattern = "\\b\\d{4}\\b",
        .mode = "regex",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_raw_re, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_raw_re.matched_lines);

    // 6. Scoped `$w(...)` and `$rw(...)` inside `contains` and `excludes`
    var c_contains_w = CountCollector{ .allocator = gpa, .io = io };
    const inc_rw = [_][]const u8{"$rw(\\d{4})"};
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 6,
        .pattern = "$w(id)",
        .contains = &inc_rw,
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_contains_w, .sendFn = CountCollector.send });
    // Only `    id: u64 = 1001,` and `\tid = 4096;` have both whole-word `id` and a 4-digit number!
    try std.testing.expectEqual(@as(u64, 2), c_contains_w.matched_lines);
}

test "search_job: 19-digit nanosecond segment pruning, mmap binary search, and line numbers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "streams/gw");

    // Segment 1: [1730340001000000000, 1730340003000000000]
    try tmp.dir.writeFile(io, .{
        .sub_path = "streams/gw/1730340001000000000-1730340003000000000.log",
        .data = "1730340001000000000 ERROR old_event_1\n" ++
            "1730340002000000000 ERROR old_event_2\n" ++
            "1730340003000000000 ERROR old_event_3\n",
    });

    // Segment 2: [1730340010000000000, 1730340050000000000]
    const seg2_data =
        "1730340010000000000 ERROR mid_event_line1\n" ++
        "1730340020000000000 ERROR mid_event_line2\n" ++
        "1730340030000000000 ERROR mid_event_line3\n" ++
        "1730340040000000000 ERROR mid_event_line4\n" ++
        "1730340050000000000 ERROR mid_event_line5\n";
    try tmp.dir.writeFile(io, .{
        .sub_path = "streams/gw/1730340010000000000-1730340050000000000.log",
        .data = seg2_data,
    });

    // Direct unit test on `narrowMmapSliceByTimeRange`
    const narrowed = narrowMmapSliceByTimeRange(
        seg2_data,
        1730340020000000000,
        1730340040000000000,
    );
    try std.testing.expectEqual(@as(u64, 1), narrowed.base_line_offset);
    try std.testing.expect(std.mem.startsWith(u8, narrowed.sub_slice, "1730340020000000000 ERROR mid_event_line2\n"));
    try std.testing.expect(std.mem.endsWith(u8, narrowed.sub_slice, "1730340040000000000 ERROR mid_event_line4\n"));

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root_real = try gpa.dupe(u8, path_buf[0..n]);
    defer gpa.free(root_real);

    var reg = source_registry.SourceRegistry.init(gpa, io, root_real, null);
    defer reg.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const gw_dir_path = try std.fmt.allocPrint(arena_state.allocator(), "{s}/streams/gw", .{root_real});
    try reg.upsertSource(arena_state.allocator(), io, .{
        .kind = "dir",
        .name = "gw",
        .path = gw_dir_path,
        .enabled = true,
    });

    const LineCollector = struct {
        allocator: std.mem.Allocator,
        files_searched: u64 = 0,
        matched_lines: u64 = 0,
        first_line_no: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                if (parsed.value.items.len > 0 and self.first_line_no == 0) {
                    self.first_line_no = parsed.value.items[0].line;
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.files_searched = parsed.value.filesSearched;
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var col = LineCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 1,
        .pattern = "ERROR",
        .timeStartNs = 1730340020000000000,
        .timeEndNs = 1730340040000000000,
    }, &cancel, .{ .ctx = &col, .sendFn = LineCollector.send });

    // Segment 1 was pruned by filename without even opening it (`files_searched == 1`),
    // and inside Segment 2 only lines 2, 3, 4 matched (`matched_lines == 3`, `first_line_no == 2`)!
    try std.testing.expectEqual(@as(u64, 1), col.files_searched);
    try std.testing.expectEqual(@as(u64, 3), col.matched_lines);
    try std.testing.expectEqual(@as(u64, 2), col.first_line_no);
}

test "search_job: dual-granularity time filter on ISO-8601/Nginx/JSONL logs (with stack traces) AND code/HTML files via stat.mtime" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "mixed");

    // 1. Existing ISO-8601 / Spring Boot log with multi-line Java stack trace
    const spring_log =
        "2026-10-31 10:15:01,000 INFO  [main] Booting service\n" ++
        "2026-10-31 10:15:02,500 ERROR [worker-1] NullPointerException in PaymentService\n" ++
        "    at com.example.PaymentService.charge(PaymentService.java:88)\n" ++
        "    at com.example.OrderController.submit(OrderController.java:42)\n" ++
        "2026-10-31 10:15:05,000 INFO  [main] Shutdown complete\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "mixed/spring.log", .data = spring_log });

    // 2. Code (.zig) and HTML (.html) files (no line-level timestamps -> filtered by stat.mtime!)
    try tmp.dir.writeFile(io, .{
        .sub_path = "mixed/app.zig",
        .data = "pub fn handlePayment() void {\n    // PaymentService logic\n}\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "mixed/index.html",
        .data = "<!DOCTYPE html>\n<html><body><div class=\"PaymentService\">Pay</div></body></html>\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root_real = try gpa.dupe(u8, path_buf[0..n]);
    defer gpa.free(root_real);

    var reg = source_registry.SourceRegistry.init(gpa, io, root_real, null);
    defer reg.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const mixed_dir_path = try std.fmt.allocPrint(arena_state.allocator(), "{s}/mixed", .{root_real});
    try reg.upsertSource(arena_state.allocator(), io, .{
        .kind = "dir",
        .name = "mixed",
        .path = mixed_dir_path,
        .enabled = true,
    });

    const SimpleCollector = struct {
        allocator: std.mem.Allocator,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // A. Search `PaymentService` inside historical log window [2026-10-31T10:15:02Z, 2026-10-31T10:15:03Z]:
    //    - `spring.log` is a time-series log: matches both line 2 (`ERROR ... PaymentService`) AND line 3 (stack trace `at ... PaymentService.java:88` via lookbehind inheritance)!
    //    - `app.zig` and `index.html` have `mtime = now` (outside the narrow 1-second window if `timeEndNs` is 10:15:03Z, or inside if `timeEndNs == 0`).
    const t_start = ingestor.parseTimestampToNs("2026-10-31T10:15:02Z", 2026).?;
    const t_end = ingestor.parseTimestampToNs("2026-10-31T10:15:03Z", 2026).?;

    var col_log_window = SimpleCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 10,
        .pattern = "PaymentService",
        .timeStartNs = t_start,
        .timeEndNs = t_end,
    }, &cancel, .{ .ctx = &col_log_window, .sendFn = SimpleCollector.send });
    try std.testing.expectEqual(@as(u64, 2), col_log_window.matched_lines);

    // B. Search `PaymentService` with `timeStartNs = now - 60s` (`$t(1m)`):
    //    - `app.zig` and `index.html` were just modified (`mtime >= now - 60s`), so both code and HTML files match (1 line each = 2 lines)!
    const now_ns = ingestor.currentUnixNano(io);
    var col_recent = SimpleCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 11,
        .pattern = "PaymentService",
        .timeStartNs = now_ns -| (60 * std.time.ns_per_s),
        .timeEndNs = now_ns +| (60 * std.time.ns_per_s),
    }, &cancel, .{ .ctx = &col_recent, .sendFn = SimpleCollector.send });
    try std.testing.expectEqual(@as(u64, 2), col_recent.matched_lines);
}

test "search_job: $@(zedis-rust) pub fn async members falls back to ±15-line block proximity when terms span doc-comment and function signature" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "zedis-rust/states/server");
    const set_rs =
        "/// Performs the initial load of a Redis SET value.\n" ++
        "///\n" ++
        "/// Fetches the total cardinality (SCARD) and loads the first batch of members (up to 100).\n" ++
        "///\n" ++
        "/// # Arguments\n" ++
        "/// * `conn` - Redis asynchronous connection\n" ++
        "/// * `key` - The SET key to load\n" ++
        "pub(crate) async fn first_load_set_value(conn: &mut RedisAsyncConn, key: &str) -> Result<RedisValue> {\n" ++
        "    // Get total number of members in the SET\n" ++
        "    let size: usize = cmd(\"SCARD\").arg(key).query_async(conn).await?;\n" ++
        "}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "zedis-rust/states/server/set.rs", .data = set_rs });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root_real = try gpa.dupe(u8, path_buf[0..n]);
    defer gpa.free(root_real);

    var reg = source_registry.SourceRegistry.init(gpa, io, root_real, null);
    defer reg.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const zedis_dir_path = try std.fmt.allocPrint(arena_state.allocator(), "{s}/zedis-rust", .{root_real});
    try reg.upsertSource(arena_state.allocator(), io, .{
        .kind = "dir",
        .name = "zedis-rust",
        .path = zedis_dir_path,
        .enabled = true,
    });

    const BlockCollector = struct {
        allocator: std.mem.Allocator,
        matched_lines: u64 = 0,
        first_line_no: u64 = 0,
        span_count: usize = 0,
        nearby_lines: u32 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                if (parsed.value.items.len > 0 and self.first_line_no == 0) {
                    self.first_line_no = parsed.value.items[0].line;
                    self.span_count = parsed.value.items[0].spans.len;
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.nearby_lines = parsed.value.nearbyLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var col = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 99,
        .pattern = "pub",
        .contains = &.{ "fn", "async", "members" },
        .globs = &.{"zedis-rust"},
        .sources = &.{"other-unrelated-source"},
    }, &cancel, .{ .ctx = &col, .sendFn = BlockCollector.send });

    try std.testing.expect(col.matched_lines >= 1);
    try std.testing.expectEqual(@as(u64, 8), col.first_line_no);
    try std.testing.expect(col.span_count >= 3);
    try std.testing.expectEqual(@as(u32, 15), col.nearby_lines);

    // Same query again: L1/L2 must not have cached the fallback hits as strict single-line results,
    // and the nearby fallback must still kick in (previously a cached "0 hits" could be replayed).
    var col_again = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 100,
        .pattern = "pub",
        .contains = &.{ "fn", "async", "members" },
        .globs = &.{"zedis-rust"},
    }, &cancel, .{ .ctx = &col_again, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(col.matched_lines, col_again.matched_lines);
    try std.testing.expectEqual(@as(u32, 15), col_again.nearby_lines);

    // `nearbyLines = 0` keeps the search strictly single-line.
    var col_strict = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 101,
        .pattern = "pub",
        .contains = &.{ "fn", "async", "members" },
        .nearbyLines = 0,
    }, &cancel, .{ .ctx = &col_strict, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(@as(u64, 0), col_strict.matched_lines);
    try std.testing.expectEqual(@as(u32, 0), col_strict.nearby_lines);

    // `fileGlobs`: `@*.rs` keeps set.rs, `-@*.rs` drops it.
    var col_glob = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 102,
        .pattern = "SCARD",
        .fileGlobs = &.{"server/*.rs"},
    }, &cancel, .{ .ctx = &col_glob, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(@as(u64, 2), col_glob.matched_lines);

    var col_glob_neg = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 103,
        .pattern = "SCARD",
        .fileGlobs = &.{"!*.rs"},
    }, &cancel, .{ .ctx = &col_glob_neg, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(@as(u64, 0), col_glob_neg.matched_lines);
}

test "search_job: libwebgrep v0.4.1 alt_prefilter & precomputed_dfa selectivity planner" {
    const gpa = std.testing.allocator;

    var re_alt = try libwebgrep.Regex.init(gpa, "ERROR_CRITICAL|FATAL_PANIC", .{ .case = .sensitive });
    defer re_alt.deinit();
    try std.testing.expect(re_alt.alt_prefilter != null);
    // An 11-char exact alternation (`min_alt_len = 11`) must outscore a weak 2-char literal `in` (`25`).
    try std.testing.expect(computeRegexSelectivity(&re_alt) > computeLiteralSelectivity("in"));

    var re_dfa = try libwebgrep.Regex.init(gpa, "\\d{4}", .{ .case = .sensitive });
    defer re_dfa.deinit();
    // Unanchored digit regex has no literal prefilter and must still score lower than any 2+ char literal.
    try std.testing.expect(computeRegexSelectivity(&re_dfa) < computeLiteralSelectivity("fn"));
}
