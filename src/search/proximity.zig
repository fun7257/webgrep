const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");
const search_cache = @import("../search_cache.zig");
const protocol = @import("protocol.zig");
const limits = @import("limits.zig");
const query_plan = @import("query_plan.zig");
const types = @import("types.zig");
const path_filter = @import("path_filter.zig");
const sink_mod = @import("sink.zig");
const runner_mod = @import("runner.zig");

const JobRunner = runner_mod.JobRunner;
const FileSink = sink_mod.FileSink;
const HitItem = protocol.HitItem;
const HitSpan = protocol.HitSpan;
const FileTask = types.FileTask;
const parseScopedModifier = query_plan.parseScopedModifier;
const parseCaseMode = query_plan.parseCaseMode;
const hasAsciiUpper = query_plan.hasAsciiUpper;
const containsIgnoreCase = path_filter.containsIgnoreCase;
const EngineLimits = limits.EngineLimits;
const isSingleStreamCompressed = limits.isSingleStreamCompressed;

pub fn canRunBlockProximityFallback(self: *const JobRunner) bool {
    if (self.shouldStop()) return false;
    if (self.req.nearbyLines == 0) return false;
    // Time-filtered searches stay strictly line-based (nearby lines may fall outside the window).
    if (self.time_start_ns > 0 or self.time_end_ns > 0) return false;
    if (self.kv_predicates.len > 0) return false;
    if (self.req.invert or self.req.wholeLine) return false;
    if (self.req.replacement != null and self.req.replacement.?.len > 0) return false;
    if (self.req.pattern.len == 0) return false;
    return self.req.contains.len > 0;
}

/// Runs the nearby-lines fallback after an L1/L2 cache tier produced 0 strict single-line hits.
/// Fallback results are never committed to L1/L2 (they are not single-line supersets).
pub fn tryNearbyFallbackAfterCache(self: *JobRunner) void {
    if (self.total_matches.load(.acquire) != 0 or !canRunBlockProximityFallback(self)) return;
    if (runBlockProximityFallback(self)) {
        self.should_commit_cache = false;
        self.cache_hit_tier = "nearby";
    }
}

pub fn runnerShouldStopCallback(ctx: *const anyopaque) bool {
    const self: *const JobRunner = @ptrCast(@alignCast(ctx));
    return self.shouldStop();
}

pub fn runBlockProximityFallback(self: *JobRunner) bool {
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
        if (task.archive_format != null or isSingleStreamCompressed(task.base_name)) continue;

        const pos_lit_count = task.effective_contains.len;
        const pos_re_count = self.contains_regexes.len;
        const total_preds = 1 + pos_lit_count + pos_re_count;
        if (total_preds <= 1 or total_preds > 32) continue;

        var opened_parent: ?std.Io.Dir = null;
        defer if (opened_parent) |*d| d.close(self.io);

        var hot_lease: ?search_cache.HotFileLease = null;
        defer if (hot_lease) |lease| {
            self.registry.?.search_cache.releaseHotFileSlice(self.io, lease.slot_idx);
        };

        var owned_buf: []u8 = &.{};
        defer if (owned_buf.len > 0) self.gpa.free(owned_buf);

        const raw_slice: []const u8 = blk_fs: {
            const parent_dir: std.Io.Dir = if (task.parent_dir_path) |p| blk_p: {
                opened_parent = std.Io.Dir.cwd().openDir(self.io, p, .{}) catch continue;
                break :blk_p opened_parent.?;
            } else self.root_dir;

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

            if (hot_lease) |lease| {
                break :blk_fs lease.slice;
            }
            var file = parent_dir.openFile(self.io, task.open_sub_path, .{ .allow_directory = false }) catch continue;
            defer file.close(self.io);
            const alloc_len: usize = @intCast(task.file_size);
            owned_buf = self.gpa.alloc(u8, alloc_len) catch continue;
            const n = file.readPositionalAll(self.io, owned_buf, 0) catch continue;
            break :blk_fs owned_buf[0..n];
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

            var spans_list: std.ArrayList(HitSpan) = .empty;
            collectAllQueryTermSpans(self, task, text_duped, parsed_case, &spans_list);

            const col: u64 = if (spans_list.items.len > 0)
                @intCast(spans_list.items[0].start + 1)
            else
                1;

            fallback_hits.append(self.job_arena, .{
                .file = self.job_arena.dupe(u8, task.rel_path) catch continue,
                .line = @intCast(idx + 1),
                .col = col,
                .text = text_duped,
                .prevText = null,
                .nextText = null,
                .replaced = null,
                .isContext = false,
                .byteOffset = null,
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

pub fn collectAllQueryTermSpans(
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
        .literal => |*f| {
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
        var f = libwebgrep.Finder.init(inc_lit, EngineLimits.findOptions(parsed_case)) catch continue;
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
