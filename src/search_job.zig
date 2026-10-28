const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("file_api.zig");
const source_registry = @import("source_registry.zig");

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
    maxPerFile: u64 = 500,
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

/// Computes the SIMD prefilter selectivity score for a compiled regex.
/// Higher scores indicate stronger fixed-literal anchors (`Finder` at 20+ GB/s),
/// while unanchored NFAs (`\d+`, `\w+`, `[a-z]+`) with no required literal score 1.
fn computeRegexSelectivity(re: *const libwebgrep.Regex) usize {
    const req_len = if (re.requiredLiteral()) |rl| rl.bytes.len else 0;
    const tail_len = re.tail_literal_bytes.len;
    if (re.req_is_exact) return req_len * 10 + 5;
    if (req_len > 0) return req_len * 8 + tail_len * 4;
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

    // If pattern is empty and neither invert nor contains is active, complete immediately with 0 hits.
    if (req.pattern.len == 0 and !req.invert and req.contains.len == 0) {
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
        !req.wholeLine and
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
    };
    defer runner.file_tasks.deinit(job_arena);

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
                try runner.enqueueTask(null, clean_p, clean_p, base, "", "", base_literal_contains, base_literal_excludes);
            }
        }
    } else {
        try runner.walkDirectoryForSource(root_dir, null, "", "", base_literal_contains, base_literal_excludes, "");
    }

    if (!cancel_flag.load(.acquire)) {
        runner.runParallelWorkers();
    }

    if (cancel_flag.load(.acquire)) return;

    const site_search_count: u64 = if (registry) |reg| reg.recordSearch(io) else 0;

    const elapsed_ns = start_ts.untilNow(io, .awake).toNanoseconds();
    const elapsed_ms: f64 = @as(f64, @floatFromInt(@max(elapsed_ns, 0))) / 1_000_000.0;
    const limit_hit: []const u8 = if (runner.hit_max_results.load(.acquire))
        "max_results"
    else
        "none";

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
};

const JobRunner = struct {
    gpa: std.mem.Allocator,
    job_arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    req: SearchRequest,
    matcher: *MatcherUnion,
    compiled_globs: []const libwebgrep.walk_glob.Glob,
    contains_regexes: []const libwebgrep.Regex = &.{},
    excludes_regexes: []const libwebgrep.Regex = &.{},
    swapped_primary_regex_first: bool = false,
    swapped_primary_finder: ?libwebgrep.Finder = null,
    cancel_flag: *const std.atomic.Value(bool),
    sender: FrameSender,

    file_tasks: std.ArrayList(FileTask) = .empty,
    next_task_idx: std.atomic.Value(usize) = .init(0),

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
    ) !void {
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

    fn matchesSingleScopeToken(rel_path: []const u8, base_name: []const u8, token: []const u8) bool {
        const clean = std.mem.trim(u8, token, " \t");
        if (clean.len == 0) return true;

        // Fast case-insensitive substring match against full relative path
        if (!hasGlobMetachar(clean)) {
            return containsIgnoreCase(rel_path, clean);
        }

        // Strip leading/trailing '*' if there are no other metacharacters inside
        if (clean.len >= 2 and clean[0] == '*' and clean[clean.len - 1] == '*') {
            const inner = clean[1 .. clean.len - 1];
            if (!hasGlobMetachar(inner)) {
                return containsIgnoreCase(rel_path, inner);
            }
        }
        if (clean.len >= 2 and clean[0] == '*' and !hasGlobMetachar(clean[1..])) {
            const suffix = clean[1..];
            return std.ascii.endsWithIgnoreCase(rel_path, suffix) or
                containsIgnoreCase(rel_path, suffix);
        }

        const g = libwebgrep.walk_glob.classifyWithCase(clean, true);
        const rules = [_]libwebgrep.walk_glob.Glob{g};
        return libwebgrep.walk_glob.matchGlobs(&rules, rel_path, base_name, false);
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

        var entries: std.ArrayList(DirEntryItem) = .empty;
        {
            var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
            var lister = libwebgrep.walk_list.Lister.init(dir, &scratch);
            var batch: [128]std.Io.Dir.Entry = undefined;

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
        }

        std.mem.sort(DirEntryItem, entries.items, {}, DirEntryItem.lessThan);

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

                try self.enqueueTask(
                    parent_root_override,
                    child_rel,
                    virtual_rel,
                    entry.name,
                    src_id,
                    src_name,
                    effective_contains,
                    effective_excludes,
                );
            }
        }
    }

    fn runParallelWorkers(self: *JobRunner) void {
        const total_files = self.file_tasks.items.len;
        if (total_files == 0) return;

        const cpu_count = std.Thread.getCpuCount() catch 4;
        const desired_workers = @min(@max(cpu_count, 4), @min(total_files, 8));

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

    fn workerThreadMain(self: *JobRunner) void {
        var batch_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer batch_arena_state.deinit();

        var search_scratch: []u8 = &.{};
        defer if (search_scratch.len > 0) self.gpa.free(search_scratch);

        var worker = WorkerContext{
            .runner = self,
            .local_matcher = self.matcher.*,
            .batch_arena = &batch_arena_state,
            .search_scratch = &search_scratch,
            .last_flush_ts = std.Io.Clock.awake.now(self.io),
        };
        defer worker.batch_items.deinit(self.gpa);

        while (!self.shouldStop()) {
            const idx = self.next_task_idx.fetchAdd(1, .monotonic);
            if (idx >= self.file_tasks.items.len) break;
            worker.searchOneTask(self.file_tasks.items[idx]);
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
};

const WorkerContext = struct {
    runner: *JobRunner,
    local_matcher: MatcherUnion,
    batch_arena: *std.heap.ArenaAllocator,
    batch_items: std.ArrayList(HitItem) = .empty,
    search_scratch: *[]u8,
    last_flush_ts: std.Io.Timestamp,

    fn searchOneTask(self: *WorkerContext, task: FileTask) void {
        if (self.runner.shouldStop()) return;

        var opened_parent: ?std.Io.Dir = null;
        defer if (opened_parent) |*d| d.close(self.runner.io);

        const parent_dir: std.Io.Dir = if (task.parent_dir_path) |p| blk: {
            opened_parent = std.Io.Dir.cwd().openDir(self.runner.io, p, .{}) catch return;
            break :blk opened_parent.?;
        } else self.runner.root_dir;

        var file = parent_dir.openFile(self.runner.io, task.open_sub_path, .{ .allow_directory = false }) catch return;
        defer file.close(self.runner.io);

        var read_buf: [65536]u8 = undefined;
        var file_reader = file.reader(self.runner.io, &read_buf);

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
            .buffer_size = 256 * 1024,
            .progress_interval = 512 * 1024,
            .max_source_bytes = libwebgrep.SearchConfig.max_source_bytes_hard_cap,
            .max_request_bytes = libwebgrep.SearchConfig.max_request_bytes_hard_cap,
            .max_output_bytes = libwebgrep.SearchConfig.max_output_bytes_hard_cap,
            .scratch = self.search_scratch,
            .cancel = self.runner.cancel_flag,
        };

        var sink = FileSink{
            .worker = self,
            .rel_path = task.rel_path,
            .source_id = task.source_id,
            .source_name = task.source_name,
            .case_insensitive = is_case_insensitive,
        };

        const maybe_res = switch (self.local_matcher) {
            .literal => |*f| libwebgrep.searchSource(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, f, cfg),
            .multi => |*m| libwebgrep.searchSource(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, m, cfg),
            .regex => |*r| libwebgrep.searchSource(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, r, cfg),
        } catch null;

        _ = self.runner.files_searched.fetchAdd(1, .monotonic);
        if (sink.file_had_match or (if (maybe_res) |r| r.matched_lines > 0 else false)) {
            _ = self.runner.files_matched.fetchAdd(1, .monotonic);
        }
        if (maybe_res) |res| {
            const bytes = if (res.bytes_searched > 0) res.bytes_searched else res.bytes_read;
            _ = self.runner.bytes_searched.fetchAdd(bytes, .monotonic);
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

const FileSink = struct {
    worker: *WorkerContext,
    rel_path: []const u8,
    source_id: []const u8 = "",
    source_name: []const u8 = "",
    case_insensitive: bool = true,
    file_had_match: bool = false,
    file_matched_lines: u64 = 0,

    pub fn event(self: *FileSink, ev: libwebgrep.Event) bool {
        const runner = self.worker.runner;
        if (runner.shouldStop()) return false;

        switch (ev) {
            .match => |line| {
                const max_res = runner.req.maxResults;
                if (max_res > 0 and runner.total_matches.load(.monotonic) >= max_res) {
                    runner.hit_max_results.store(true, .release);
                    return false;
                }

                self.file_had_match = true;
                self.file_matched_lines += 1;

                const raw_match_count: u64 = if (runner.req.contains.len > 0)
                    1
                else if (line.matches.len > 0)
                    @intCast(line.matches.len)
                else
                    1;
                const prev_total = runner.total_matches.fetchAdd(raw_match_count, .monotonic);
                if (max_res > 0 and prev_total >= max_res) {
                    _ = runner.total_matches.fetchSub(raw_match_count, .monotonic);
                    runner.hit_max_results.store(true, .release);
                    return false;
                }

                const remaining: u64 = if (max_res > 0) max_res - prev_total else raw_match_count;
                const capped_match_count: u64 = @min(raw_match_count, remaining);
                if (capped_match_count < raw_match_count) {
                    _ = runner.total_matches.fetchSub(raw_match_count - capped_match_count, .monotonic);
                }
                _ = runner.matched_lines.fetchAdd(1, .monotonic);

                const span_limit: usize = if (runner.req.contains.len > 0) 0 else @intCast(capped_match_count);
                self.appendLineEvent(line, false, span_limit) catch {
                    return false;
                };

                self.worker.maybeFlushStreaming(false);
                if (runner.send_failed.load(.acquire)) return false;

                if (max_res > 0 and prev_total + capped_match_count >= max_res) {
                    runner.hit_max_results.store(true, .release);
                    return false;
                }
                if (runner.req.maxPerFile > 0 and self.file_matched_lines >= runner.req.maxPerFile) {
                    // Stop scanning the rest of this single file so other files still get searched
                    return false;
                }
                return true;
            },
            .context => |line| {
                self.appendLineEvent(line, true, 0) catch {
                    return false;
                };
                self.worker.maybeFlushStreaming(false);
                if (runner.send_failed.load(.acquire)) return false;
                return true;
            },
            .progress => |prog| {
                self.worker.maybeFlushStreaming(true);
                runner.maybeSendProgress(prog.bytes_searched);
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
        const text_duped = if (safe_text.ptr == raw_text.ptr)
            try arena.dupe(u8, safe_text)
        else
            safe_text;

        const replaced_duped: ?[]const u8 = if (line.replaced) |rep| blk: {
            const safe_rep = try file_api.sanitizeUtf8Truncated(arena, rep, 1024);
            break :blk if (safe_rep.ptr == rep.ptr) try arena.dupe(u8, safe_rep) else safe_rep;
        } else null;

        var spans_list: std.ArrayList(HitSpan) = .empty;
        const runner = self.worker.runner;
        if (!is_context) {
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
