const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");
const prefilter = @import("../prefilter.zig");
const source_registry = @import("../source_registry.zig");
const time_parser = @import("../time_parser.zig");
const protocol = @import("protocol.zig");
const limits = @import("limits.zig");
const query_plan = @import("query_plan.zig");
const types = @import("types.zig");
const runner_mod = @import("runner.zig");

const KvPredicateDto = protocol.KvPredicateDto;
const SearchRequest = protocol.SearchRequest;
const FrameSender = protocol.FrameSender;
const DoneFrame = protocol.DoneFrame;
const sendError = protocol.sendError;
const EngineLimits = limits.EngineLimits;
const detectArchiveFormat = limits.detectArchiveFormat;
const formatRegexDiagnosticAlloc = limits.formatRegexDiagnosticAlloc;
const custom_file_types = limits.custom_file_types;
const MatcherUnion = query_plan.MatcherUnion;
const parseCaseMode = query_plan.parseCaseMode;
const hasRegexMeta = query_plan.hasRegexMeta;
const hasAsciiUpper = query_plan.hasAsciiUpper;
const escapeRegexLiteralAlloc = query_plan.escapeRegexLiteralAlloc;
const parseScopedModifier = query_plan.parseScopedModifier;
const computeRegexSelectivity = query_plan.computeRegexSelectivity;
const computeLiteralSelectivity = query_plan.computeLiteralSelectivity;
const SourcePipelineConfig = types.SourcePipelineConfig;
const resolveSourcePipeline = types.resolveSourcePipeline;
const TimeParserPoolEntry = types.TimeParserPoolEntry;
const JobRunner = runner_mod.JobRunner;

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

    // If pattern is empty and neither invert, contains, kvPredicates, nor time filter is active, complete immediately with 0 hits.
    if (req.pattern.len == 0 and !req.invert and req.contains.len == 0 and !has_time_filter and req.kvPredicates.len == 0) {
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

    if (req.pluginPreset) |raw_preset| {
        if (prefilter.Preset.parseStrict(raw_preset) == null) {
            try sendError(gpa, sender, req.id, "Invalid pluginPreset (expected timeseries or code)");
            return;
        }
    }
    if (req.plugins) |ov| {
        if (ov.enable) |en_list| {
            for (en_list) |raw_id| {
                const trimmed = std.mem.trim(u8, raw_id, " \t\r\n");
                if (trimmed.len > 0 and prefilter.PluginId.parse(trimmed) == null) {
                    try sendError(gpa, sender, req.id, "Invalid plugin ID in plugins.enable");
                    return;
                }
            }
        }
        if (ov.disable) |dis_list| {
            for (dis_list) |raw_id| {
                const trimmed = std.mem.trim(u8, raw_id, " \t\r\n");
                if (trimmed.len > 0 and prefilter.PluginId.parse(trimmed) == null) {
                    try sendError(gpa, sender, req.id, "Invalid plugin ID in plugins.disable");
                    return;
                }
            }
        }
    }

    var compiled_kv_list: std.ArrayList(prefilter.KvPredicate) = .empty;
    var kv_hasher = std.hash.Wyhash.init(0x6b767072_65643031);
    for (req.kvPredicates) |dto| {
        const clean_key = std.mem.trim(u8, dto.key, " \t\r\n");
        if (clean_key.len == 0) {
            try sendError(gpa, sender, req.id, "kvPredicates key cannot be empty");
            return;
        }
        const op = prefilter.KvOp.parse(dto.op) orelse {
            try sendError(gpa, sender, req.id, "Unsupported kvPredicates op (expected eq, neq, contains, gt_num, lt_num, exists)");
            return;
        };
        const num_val: ?f64 = if (op == .gt_num or op == .lt_num or op == .eq or op == .neq)
            (std.fmt.parseFloat(f64, std.mem.trim(u8, dto.value, " \t\r\n")) catch null)
        else
            null;
        if ((op == .gt_num or op == .lt_num) and (num_val == null or !std.math.isFinite(num_val.?))) {
            try sendError(gpa, sender, req.id, "Numeric kvPredicate requires a finite numeric value");
            return;
        }
        try compiled_kv_list.append(job_arena, .{
            .key = try job_arena.dupe(u8, clean_key),
            .op = op,
            .value = try job_arena.dupe(u8, dto.value),
            .num_value = num_val,
            .case_sensitive = dto.caseSensitive,
        });
        kv_hasher.update(clean_key);
        const op_b: [1]u8 = .{@intFromEnum(op)};
        kv_hasher.update(&op_b);
        kv_hasher.update(dto.value);
        const cs_b: [1]u8 = .{@intFromBool(dto.caseSensitive)};
        kv_hasher.update(&cs_b);
        kv_hasher.update("\x00");
    }
    const compiled_kv = compiled_kv_list.items;
    const kv_predicates_hash: u64 = if (compiled_kv.len > 0) kv_hasher.final() else 0;

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
            const m = libwebgrep.Multi.init(gpa, parts.items, EngineLimits.findOptions(case_mode)) catch |err| {
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
            const freeCandidates = struct {
                fn run(alloc: std.mem.Allocator, list: *std.ArrayList(Candidate)) void {
                    for (list.items) |*c| {
                        switch (c.kind) {
                            .regex => |*re| re.deinit(),
                            .literal => {},
                        }
                    }
                    list.deinit(alloc);
                }
            }.run;
            errdefer freeCandidates(gpa, &candidates);

            const classifyTerm = struct {
                fn run(
                    alloc: std.mem.Allocator,
                    arena_alloc: std.mem.Allocator,
                    snd: FrameSender,
                    req_id: u64,
                    raw_pat: []const u8,
                    regex_mode: bool,
                    cm: libwebgrep.CaseMode,
                ) !?Candidate {
                    if (parseScopedModifier(arena_alloc, raw_pat, cm)) |scoped_spec| {
                        var diag: libwebgrep.CompileDiagnostic = .{};
                        const re = libwebgrep.Regex.initDiagnostic(alloc, scoped_spec.pattern, EngineLimits.regexOptions(scoped_spec.case_mode), &diag) catch |err| {
                            const msg = try formatRegexDiagnosticAlloc(arena_alloc, scoped_spec.pattern, diag, err);
                            try sendError(alloc, snd, req_id, msg);
                            return null;
                        };
                        return .{
                            .raw = raw_pat,
                            .score = computeRegexSelectivity(&re),
                            .kind = .{ .regex = re },
                        };
                    }
                    if (regex_mode and hasRegexMeta(raw_pat)) {
                        var diag: libwebgrep.CompileDiagnostic = .{};
                        if (libwebgrep.Regex.initDiagnostic(alloc, raw_pat, EngineLimits.regexOptions(cm), &diag)) |re| {
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

            const first_cand = (try classifyTerm(gpa, job_arena, sender, req.id, req.pattern, is_regex_mode, case_mode)) orelse {
                freeCandidates(gpa, &candidates);
                return;
            };
            try candidates.append(gpa, first_cand);
            for (req.contains) |pat| {
                if (pat.len == 0) continue;
                const cand = (try classifyTerm(gpa, job_arena, sender, req.id, pat, is_regex_mode, case_mode)) orelse {
                    freeCandidates(gpa, &candidates);
                    return;
                };
                try candidates.append(gpa, cand);
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
                            swapped_primary_finder = libwebgrep.Finder.init(lit, EngineLimits.findOptions(case_mode)) catch null;
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
                    const f = libwebgrep.Finder.init(lit, EngineLimits.findOptions(case_mode)) catch |err| {
                        try sendError(gpa, sender, req.id, @errorName(err));
                        return;
                    };
                    break :blk .{ .literal = f };
                },
            }
        } else if (parseScopedModifier(job_arena, req.pattern, case_mode)) |scoped_spec| {
            var diag: libwebgrep.CompileDiagnostic = .{};
            const re = libwebgrep.Regex.initDiagnostic(gpa, scoped_spec.pattern, EngineLimits.regexOptions(scoped_spec.case_mode), &diag) catch |err| {
                const msg = try formatRegexDiagnosticAlloc(job_arena, scoped_spec.pattern, diag, err);
                try sendError(gpa, sender, req.id, msg);
                return;
            };
            break :blk .{ .regex = re };
        } else if (req.pattern.len == 0 and (has_time_filter or compiled_kv.len > 0 or req.contains.len > 0 or req.invert)) {
            var diag: libwebgrep.CompileDiagnostic = .{};
            const re = libwebgrep.Regex.initDiagnostic(gpa, "^.", EngineLimits.regexOptions(.sensitive), &diag) catch |err| {
                const msg = try formatRegexDiagnosticAlloc(job_arena, "^.", diag, err);
                try sendError(gpa, sender, req.id, msg);
                return;
            };
            break :blk .{ .regex = re };
        } else if (is_regex_mode) {
            var diag: libwebgrep.CompileDiagnostic = .{};
            const re = libwebgrep.Regex.initDiagnostic(gpa, req.pattern, EngineLimits.regexOptions(case_mode), &diag) catch |err| {
                const msg = try formatRegexDiagnosticAlloc(job_arena, req.pattern, diag, err);
                try sendError(gpa, sender, req.id, msg);
                return;
            };
            break :blk .{ .regex = re };
        } else {
            const f = libwebgrep.Finder.init(req.pattern, EngineLimits.findOptions(case_mode)) catch |err| {
                try sendError(gpa, sender, req.id, @errorName(err));
                return;
            };
            break :blk .{ .literal = f };
        }
    };
    defer matcher.deinit();

    const compiled_globs: []const libwebgrep.walk_glob.Glob = if (req.globs.len > 0)
        libwebgrep.walk_glob.compileGlobs(job_arena, req.globs, EngineLimits.globOptions()) catch |err| {
            try sendError(gpa, sender, req.id, @errorName(err));
            return;
        }
    else
        &.{};

    var expanded_file_globs_list: std.ArrayList([]const u8) = .empty;
    for (req.fileGlobs) |raw_fg| {
        const trimmed = std.mem.trim(u8, raw_fg, " \t");
        if (trimmed.len == 0) continue;
        const is_neg = trimmed[0] == '!';
        const body = if (is_neg) trimmed[1..] else trimmed;
        if (body.len == 0) continue;
        if (std.mem.indexOfScalar(u8, body, '{') != null) {
            var br_out: std.ArrayList([]u8) = .empty;
            if (libwebgrep.walk_glob.expandBracesWithOptions(job_arena, body, &br_out, EngineLimits.globOptions())) {
                for (br_out.items) |expanded_part| {
                    if (is_neg) {
                        const neg_part = try std.fmt.allocPrint(job_arena, "!{s}", .{expanded_part});
                        try expanded_file_globs_list.append(job_arena, neg_part);
                    } else {
                        try expanded_file_globs_list.append(job_arena, expanded_part);
                    }
                }
                continue;
            } else |_| {}
        }
        try expanded_file_globs_list.append(job_arena, trimmed);
    }

    var types_include_list: std.ArrayList([]const u8) = .empty;
    var types_exclude_list: std.ArrayList([]const u8) = .empty;
    var custom_types_list: std.ArrayList(libwebgrep.walk_types.Type) = .empty;
    try custom_types_list.appendSlice(job_arena, &custom_file_types);

    for (req.types) |raw_type| {
        const trimmed = std.mem.trim(u8, raw_type, " \t");
        if (trimmed.len == 0) continue;
        const is_neg = trimmed[0] == '!';
        const t_name = std.mem.trimStart(u8, if (is_neg) trimmed[1..] else trimmed, ".");
        if (t_name.len == 0) continue;
        if (is_neg) {
            try types_exclude_list.append(job_arena, t_name);
        } else {
            try types_include_list.append(job_arena, t_name);
        }
        if (libwebgrep.walk_types.findInTable(custom_types_list.items, t_name) == null) {
            const g1 = try std.fmt.allocPrint(job_arena, "*.{s}", .{t_name});
            const g2 = try std.fmt.allocPrint(job_arena, "*.{s}.gz", .{t_name});
            const g3 = try std.fmt.allocPrint(job_arena, "*.{s}.zst", .{t_name});
            const g4 = try std.fmt.allocPrint(job_arena, "*.{s}.xz", .{t_name});
            const globs_slice = try job_arena.alloc([]const u8, 4);
            globs_slice[0] = g1;
            globs_slice[1] = g2;
            globs_slice[2] = g3;
            globs_slice[3] = g4;
            try custom_types_list.append(job_arena, .{
                .name = t_name,
                .patterns = globs_slice,
            });
        }
    }

    if (!can_reorder_predicates) {
        for (req.contains) |pat| {
            if (pat.len == 0) continue;
            if (parseScopedModifier(job_arena, pat, case_mode)) |scoped_spec| {
                var diag: libwebgrep.CompileDiagnostic = .{};
                const re = libwebgrep.Regex.initDiagnostic(gpa, scoped_spec.pattern, EngineLimits.regexOptions(scoped_spec.case_mode), &diag) catch |err| {
                    const msg = try formatRegexDiagnosticAlloc(job_arena, scoped_spec.pattern, diag, err);
                    try sendError(gpa, sender, req.id, msg);
                    return;
                };
                try contains_regexes.append(gpa, re);
            } else if (is_regex_mode and hasRegexMeta(pat)) {
                var diag: libwebgrep.CompileDiagnostic = .{};
                if (libwebgrep.Regex.initDiagnostic(gpa, pat, EngineLimits.regexOptions(case_mode), &diag)) |re| {
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
            var diag: libwebgrep.CompileDiagnostic = .{};
            const re = libwebgrep.Regex.initDiagnostic(gpa, scoped_spec.pattern, EngineLimits.regexOptions(scoped_spec.case_mode), &diag) catch |err| {
                const msg = try formatRegexDiagnosticAlloc(job_arena, scoped_spec.pattern, diag, err);
                try sendError(gpa, sender, req.id, msg);
                return;
            };
            try excludes_regexes.append(gpa, re);
        } else if (is_regex_mode and hasRegexMeta(pat)) {
            var diag: libwebgrep.CompileDiagnostic = .{};
            if (libwebgrep.Regex.initDiagnostic(gpa, pat, EngineLimits.regexOptions(case_mode), &diag)) |re| {
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

    // Extract sound literal anchors (`>= 3` bytes) for `sidecar_sketch` 256-bit trigram Bloom filtering.
    var literal_anchors_list: std.ArrayList([]const u8) = .empty;
    var anchor_case_flags_list: std.ArrayList(bool) = .empty;
    if (!req.invert and !req.wholeLine) {
        if (req.pattern.len >= 3 and
            !std.mem.eql(u8, req.mode, "multi") and
            (!is_regex_mode or !hasRegexMeta(req.pattern)) and
            parseScopedModifier(job_arena, req.pattern, case_mode) == null)
        {
            const ci = switch (case_mode) {
                .insensitive => true,
                .sensitive => false,
                .smart => !hasAsciiUpper(req.pattern),
            };
            try literal_anchors_list.append(job_arena, req.pattern);
            try anchor_case_flags_list.append(job_arena, ci);
        }
        for (base_literal_contains) |lit| {
            if (lit.len < 3) continue;
            var dup = false;
            for (literal_anchors_list.items) |existing| {
                if (std.mem.eql(u8, existing, lit)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            const ci = switch (case_mode) {
                .insensitive => true,
                .sensitive => false,
                .smart => !hasAsciiUpper(lit),
            };
            try literal_anchors_list.append(job_arena, lit);
            try anchor_case_flags_list.append(job_arena, ci);
        }
    }

    const time_mode = time_parser.TimeMode.parse(req.timeMode);
    const has_time_window = (eff_time_start_ns > 0 or eff_time_end_ns > 0);
    const is_empty_text_time_browse = has_time_window and
        req.pattern.len == 0 and
        req.contains.len == 0 and
        req.excludes.len == 0 and
        !req.invert and
        compiled_kv.len == 0;
    const now_unix_ns = time_parser.currentUnixNano(io);
    const now_epoch_ms: u64 = @intCast(@max(0, @divFloor(now_unix_ns, std.time.ns_per_ms)));

    var time_parsers_pool: std.ArrayList(TimeParserPoolEntry) = .empty;
    defer {
        for (time_parsers_pool.items) |item| {
            item.ptr.deinit(gpa);
            gpa.destroy(item.ptr);
        }
        time_parsers_pool.deinit(gpa);
    }

    const default_auto_parser: *const time_parser.CompiledTimeParser = blk_def_tp: {
        const p = try gpa.create(time_parser.CompiledTimeParser);
        p.* = .{};
        errdefer gpa.destroy(p);
        try time_parsers_pool.append(gpa, .{ .key = "", .ptr = p });
        break :blk_def_tp p;
    };

    const trimmed_req_tf = std.mem.trim(u8, req.timeFormat, " \t\r\n");
    var query_line_parser: ?*const time_parser.CompiledTimeParser = null;
    if (has_time_window and time_mode != .mtime and trimmed_req_tf.len > 0) {
        var tp_err: ?[]const u8 = null;
        const p = try gpa.create(time_parser.CompiledTimeParser);
        p.* = .{};
        var ownership_transferred = false;
        defer if (!ownership_transferred) gpa.destroy(p);
        p.initInPlace(gpa, job_arena, trimmed_req_tf, &tp_err) catch |err| {
            if (err == error.InvalidTimeFormat) {
                try sendError(gpa, sender, req.id, tp_err orelse "Invalid line time format");
                return;
            }
            return err;
        };
        const key_copy = try job_arena.dupe(u8, trimmed_req_tf);
        try time_parsers_pool.append(gpa, .{ .key = key_copy, .ptr = p });
        ownership_transferred = true;
        query_line_parser = p;
    }

    var time_format_sig_buf: std.ArrayList(u8) = .empty;
    if (has_time_window and time_mode != .mtime and trimmed_req_tf.len > 0) {
        try time_format_sig_buf.appendSlice(job_arena, "q=");
        try time_format_sig_buf.appendSlice(job_arena, trimmed_req_tf);
    }

    var runner = JobRunner{
        .gpa = gpa,
        .job_arena = job_arena,
        .io = io,
        .root_dir = root_dir,
        .registry = registry,
        .req = req,
        .matcher = &matcher,
        .compiled_globs = compiled_globs,
        .expanded_file_globs = expanded_file_globs_list.items,
        .types_include = types_include_list.items,
        .types_exclude = types_exclude_list.items,
        .custom_types_table = custom_types_list.items,
        .contains_regexes = contains_regexes.items,
        .excludes_regexes = excludes_regexes.items,
        .swapped_primary_regex_first = swapped_primary_regex_first,
        .swapped_primary_finder = swapped_primary_finder,
        .cancel_flag = cancel_flag,
        .sender = sender,
        .last_progress_ts = start_ts,
        .time_start_ns = eff_time_start_ns,
        .time_end_ns = eff_time_end_ns,
        .time_mode = time_mode,
        .tz_offset_min = req.tzOffsetMin,
        .now_epoch_ms = now_epoch_ms,
        .time_format_sig = time_format_sig_buf.items,
        .default_line_time_parser = default_auto_parser,
        .is_empty_text_time_browse = is_empty_text_time_browse,
        .kv_predicates = compiled_kv,
        .kv_predicates_hash = kv_predicates_hash,
        .literal_anchors = literal_anchors_list.items,
        .anchor_case_flags = anchor_case_flags_list.items,
        .anchors_case_insensitive = switch (case_mode) {
            .insensitive => true,
            .sensitive => false,
            .smart => !hasAsciiUpper(req.pattern),
        },
        .plugin_sig = req.pluginSig,
    };
    defer runner.file_tasks.deinit(job_arena);
    defer runner.active_task_indices.deinit(job_arena);

    var plugin_sig_hasher = std.hash.Wyhash.init(0x7367_706c_7567_0001 ^ req.pluginSig);

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

            const trimmed_src_tf = std.mem.trim(u8, src.time_format, " \t\r\n");
            const src_pipe = resolveSourcePipeline(req, trimmed_req_tf, src, time_mode);
            const src_task_time_mode = src_pipe.task_time_mode;
            plugin_sig_hasher.update(src.id);
            plugin_sig_hasher.update("\x00");
            plugin_sig_hasher.update(std.mem.asBytes(&src_pipe.chain.signature));

            const src_line_parser: *const time_parser.CompiledTimeParser = blk_slp: {
                if (query_line_parser) |qp| break :blk_slp qp;
                if (has_time_window and src_task_time_mode != .mtime) {
                    if (trimmed_src_tf.len > 0) {
                        try time_format_sig_buf.append(job_arena, '|');
                        try time_format_sig_buf.appendSlice(job_arena, src.id);
                        try time_format_sig_buf.append(job_arena, '=');
                        try time_format_sig_buf.appendSlice(job_arena, trimmed_src_tf);

                        if (std.ascii.eqlIgnoreCase(trimmed_src_tf, "auto")) {
                            break :blk_slp default_auto_parser;
                        }

                        for (time_parsers_pool.items) |entry| {
                            if (std.mem.eql(u8, entry.key, trimmed_src_tf)) {
                                break :blk_slp entry.ptr;
                            }
                        }
                        var sp_err: ?[]const u8 = null;
                        const p = try gpa.create(time_parser.CompiledTimeParser);
                        p.* = .{};
                        var ownership_transferred = false;
                        defer if (!ownership_transferred) gpa.destroy(p);
                        if (p.initInPlace(gpa, job_arena, trimmed_src_tf, &sp_err)) |_| {
                            const key_copy = try job_arena.dupe(u8, trimmed_src_tf);
                            try time_parsers_pool.append(gpa, .{ .key = key_copy, .ptr = p });
                            ownership_transferred = true;
                            break :blk_slp p;
                        } else |_| {
                            break :blk_slp default_auto_parser;
                        }
                    } else if (time_mode == .source and src_task_time_mode == .content) {
                        try time_format_sig_buf.append(job_arena, '|');
                        try time_format_sig_buf.appendSlice(job_arena, src.id);
                        try time_format_sig_buf.appendSlice(job_arena, "=auto");
                        break :blk_slp default_auto_parser;
                    }
                }
                break :blk_slp default_auto_parser;
            };

            runner.visited_dir_ids.clearRetainingCapacity();
            runner.visited_file_ids.clearRetainingCapacity();

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
                        null,
                        src_line_parser,
                        src_pipe,
                    );
                    continue;
                } else |_| {}
            }

            // Single-file data source (`kind == "file"` or path pointing directly to a file)
            const parent_dir_path = std.fs.path.dirname(src.path) orelse ".";
            const base_name = std.fs.path.basename(src.path);
            if (base_name.len > 0 and runner.fileMatchesSourceFilters(src.id, src.name, base_name)) {
                const st = std.Io.Dir.cwd().statFile(io, src.path, .{}) catch continue;
                const sf_dev: u64 = blk_sf_dev: {
                    var sf = std.Io.Dir.cwd().openFile(io, src.path, .{ .allow_directory = false }) catch break :blk_sf_dev 0;
                    defer sf.close(io);
                    const fid = libwebgrep.walk_file_id.fromFile(io, sf) catch break :blk_sf_dev 0;
                    break :blk_sf_dev fid.dev;
                };
                const virtual_rel = if (src.name.len > 0)
                    try std.fmt.allocPrint(job_arena, "{s}/{s}", .{ src.name, base_name })
                else
                    base_name;
                var sf_pipe = src_pipe;
                sf_pipe.source_kind = .file;
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
                    sf_dev,
                    src_line_parser,
                    sf_pipe,
                );
            }
        }
    } else if (req.paths.len > 0) {
        const fallback_tp = query_line_parser orelse default_auto_parser;
        const fallback_pipe = resolveSourcePipeline(req, trimmed_req_tf, null, time_mode);
        plugin_sig_hasher.update(std.mem.asBytes(&fallback_pipe.chain.signature));
        for (req.paths) |raw_p| {
            if (runner.shouldStop()) break;
            const clean_p = file_api.sanitizeRelPath(raw_p) catch continue;
            if (clean_p.len == 0) {
                try runner.walkDirectoryForSource(root_dir, null, "", "", base_literal_contains, base_literal_excludes, "", null, fallback_tp, fallback_pipe);
                continue;
            }
            if (root_dir.openDir(io, clean_p, .{ .iterate = true })) |opened_dir| {
                var sub_dir = opened_dir;
                defer sub_dir.close(io);
                try runner.walkDirectoryForSource(sub_dir, null, "", "", base_literal_contains, base_literal_excludes, clean_p, null, fallback_tp, fallback_pipe);
            } else |_| {
                const base = std.fs.path.basename(clean_p);
                if (!runner.fileMatchesSourceFilters("", "", base)) continue;
                const st = root_dir.statFile(io, clean_p, .{}) catch continue;
                var sf_pipe = fallback_pipe;
                sf_pipe.source_kind = .file;
                try runner.enqueueTask(null, clean_p, clean_p, base, "", "", base_literal_contains, base_literal_excludes, st.mtime.nanoseconds, st.size, st.inode, 0, fallback_tp, sf_pipe);
            }
        }
    } else {
        const fallback_tp = query_line_parser orelse default_auto_parser;
        const fallback_pipe = resolveSourcePipeline(req, trimmed_req_tf, null, time_mode);
        plugin_sig_hasher.update(std.mem.asBytes(&fallback_pipe.chain.signature));
        try runner.walkDirectoryForSource(root_dir, null, "", "", base_literal_contains, base_literal_excludes, "", null, fallback_tp, fallback_pipe);
    }

    runner.time_format_sig = time_format_sig_buf.items;
    runner.plugin_sig = plugin_sig_hasher.final();

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
        .filesPruned = runner.files_pruned.load(.acquire),
        .bytesSaved = runner.bytes_saved.load(.acquire),
        .bytesScanned = runner.bytes_scanned.load(.acquire),
    });
    defer gpa.free(done_json);
    try sender.send(done_json);

    if (registry) |reg| {
        reg.search_cache.saveSketchStore(gpa, io);
    }
}
