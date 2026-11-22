const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");
const prefilter = @import("../prefilter.zig");
const search_cache = @import("../search_cache.zig");
const time_parser = @import("../time_parser.zig");
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
const ARCHIVE_VIRTUAL_SEP = limits.ARCHIVE_VIRTUAL_SEP;
const EngineLimits = limits.EngineLimits;
const parseCaseMode = query_plan.parseCaseMode;
const hasAsciiUpper = query_plan.hasAsciiUpper;
const parseScopedModifier = query_plan.parseScopedModifier;
const containsIgnoreCase = path_filter.containsIgnoreCase;

pub fn computeTasksFingerprint(self: *const JobRunner) u64 {
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

pub fn computeExactQueryHash(self: *const JobRunner, tasks_fingerprint: u64, heat_epoch: u64) u64 {
    var hasher = std.hash.Wyhash.init(tasks_fingerprint ^ (heat_epoch *% 0x517cc1b727220a95));
    hasher.update(self.req.pattern);
    hasher.update("\x00");
    hasher.update(self.req.mode);
    hasher.update("\x00");
    hasher.update(self.req.case);
    hasher.update("\x00");
    const flags: [5]u8 = .{
        @intFromBool(self.req.wholeWord),
        @intFromBool(self.req.wholeLine),
        @intFromBool(self.req.invert),
        @intFromBool(self.req.hidden),
        @intFromBool(self.req.respectIgnore),
    };
    hasher.update(&flags);
    hasher.update(std.mem.asBytes(&self.req.context));
    hasher.update(std.mem.asBytes(&self.req.maxResults));
    hasher.update(std.mem.asBytes(&self.req.nearbyLines));
    hasher.update(std.mem.asBytes(&self.time_start_ns));
    hasher.update(std.mem.asBytes(&self.time_end_ns));
    hasher.update(self.time_mode.asStr());
    hasher.update(self.time_format_sig);
    hasher.update(std.mem.asBytes(&self.tz_offset_min));
    hasher.update(std.mem.asBytes(&self.plugin_sig));
    hasher.update(std.mem.asBytes(&self.kv_predicates_hash));
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
    hasher.update("\x00");
    for (self.req.fileGlobs) |s| {
        hasher.update(s);
        hasher.update("\xff");
    }
    hasher.update("\x00");
    for (self.req.types) |s| {
        hasher.update(s);
        hasher.update("\xff");
    }
    hasher.update("\x00");
    for (self.req.sources) |s| {
        hasher.update(s);
        hasher.update("\xff");
    }
    return hasher.final();
}

pub fn slicesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |sa, sb| {
        if (!std.mem.eql(u8, sa, sb)) return false;
    }
    return true;
}

pub fn tryReplayExactCache(self: *JobRunner, exact_hash: u64, tasks_fingerprint: u64, heat_epoch: u64) bool {
    const reg = self.registry orelse return false;
    var raw_items_json: []const u8 = "";
    var has_items = false;
    var files_searched: u64 = 0;
    var files_matched: u64 = 0;
    var total_matches: u64 = 0;
    var matched_lines: u64 = 0;
    var bytes_searched: u64 = 0;
    var files_pruned: u64 = 0;
    var bytes_saved: u64 = 0;
    var bytes_scanned: u64 = 0;
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
                !std.mem.eql(u8, e.time_mode, self.time_mode.asStr()) or
                !std.mem.eql(u8, e.time_format_sig, self.time_format_sig) or
                e.tz_offset_min != self.tz_offset_min or
                e.plugin_sig != self.plugin_sig or
                e.kv_predicates_hash != self.kv_predicates_hash or
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
        files_pruned = entry.files_pruned;
        bytes_saved = entry.bytes_saved;
        bytes_scanned = entry.bytes_scanned;
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
    self.files_pruned.store(files_pruned, .release);
    self.bytes_saved.store(bytes_saved, .release);
    self.bytes_scanned.store(bytes_scanned, .release);
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

pub fn sliceIsSubset(sub: []const []const u8, sup: []const []const u8) bool {
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

pub fn lineMatchesTaskPredicates(
    self: *const JobRunner,
    task: *const FileTask,
    line_text: []const u8,
    parsed_case: libwebgrep.CaseMode,
    default_case_insensitive: bool,
) bool {
    if ((self.time_start_ns > 0 or self.time_end_ns > 0) and task.task_time_mode == .mtime) {
        if (task.mtime_ns > 0) {
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
        .literal => |*f| {
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

pub fn computeArchiveFilterHash(self: *const JobRunner) u64 {
    var hasher = std.hash.Wyhash.init(0x7a69675f61726368);
    const flags: [2]u8 = .{
        @intFromBool(self.req.hidden),
        @intFromBool(self.req.respectIgnore),
    };
    hasher.update(&flags);
    hasher.update("\x00");
    for (self.req.types) |s| {
        hasher.update(s);
        hasher.update("\xff");
    }
    hasher.update("\x00");
    for (self.activeFileGlobs()) |s| {
        hasher.update(s);
        hasher.update("\xff");
    }
    return hasher.final();
}

pub fn isArchiveUnrestricted(self: *const JobRunner) bool {
    return self.req.types.len == 0 and
        self.activeFileGlobs().len == 0 and
        self.req.hidden and
        !self.req.respectIgnore;
}

pub fn tryFilterSupersetCache(self: *JobRunner, exact_hash: u64, tasks_fingerprint: u64, heat_epoch: u64) bool {
    const reg = self.registry orelse return false;
    if (self.req.invert or self.req.context > 0) return false;
    if (self.req.replacement != null and self.req.replacement.?.len > 0) return false;

    const total_files = self.file_tasks.items.len;
    if (total_files == 0) return false;

    var has_archive_task = false;
    for (self.file_tasks.items) |ft| {
        if (ft.archive_format != null) {
            has_archive_task = true;
            break;
        }
    }
    const cur_arch_hash = computeArchiveFilterHash(self);

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
            if (has_archive_task and e.archive_filter_hash != cur_arch_hash and !e.archive_unrestricted) continue;

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
            if (!std.mem.eql(u8, e.time_mode, self.time_mode.asStr())) continue;
            if (!std.mem.eql(u8, e.time_format_sig, self.time_format_sig)) continue;
            if (e.tz_offset_min != self.tz_offset_min) continue;
            if (e.plugin_sig != self.plugin_sig) continue;
            if (e.kv_predicates_hash != self.kv_predicates_hash) continue;
            if (self.is_empty_text_time_browse) continue;
            if ((e.time_start_ns > 0 or e.time_end_ns > 0) and e.pattern.len == 0 and e.contains.len == 0 and e.excludes.len == 0 and !e.invert) continue;
            if (self.time_mode != .mtime) {
                // For .source/.content/.auto, exact window match preserves multi-line stack-trace inheritance
                if (e.time_start_ns != self.time_start_ns or e.time_end_ns != self.time_end_ns) continue;
            } else {
                // Superset time range must cover the requested time range
                if (e.time_start_ns > self.time_start_ns) continue;
                if (e.time_end_ns != 0 and (self.time_end_ns == 0 or e.time_end_ns < self.time_end_ns)) continue;
            }

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
            (libwebgrep.Finder.init(self.req.pattern, EngineLimits.findOptions(parsed_case)) catch return false)
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
            const sep_idx_opt = std.mem.indexOf(u8, ci.file, ARCHIVE_VIRTUAL_SEP);
            const lookup_path = if (sep_idx_opt) |sep_idx| ci.file[0..sep_idx] else ci.file;
            const task_idx = task_map.get(lookup_path) orelse continue;
            const task = &self.file_tasks.items[task_idx];
            if (prefilter.pruneFile(&task.plugin_chain, JobRunner.makeTaskMeta(task), self.makeQueryPreds(task), null).verdict == .skip) {
                continue;
            }
            if (sep_idx_opt) |sep_idx| {
                const entry_path = ci.file[sep_idx + ARCHIVE_VIRTUAL_SEP.len ..];
                const entry_base = std.fs.path.basename(entry_path);
                if (self.types_include.len > 0 or self.types_exclude.len > 0) {
                    if (!libwebgrep.walk_types.matchesWithTable(
                        self.custom_types_table,
                        self.types_include,
                        self.types_exclude,
                        entry_base,
                    )) continue;
                }
                if (!path_filter.archiveEntryMatchesPathGlobs(self, task.rel_path, task.base_name, entry_path)) continue;
            }
            if (!lineMatchesTaskPredicates(self, task, ci.text, parsed_case, is_case_insensitive)) continue;

            const spans: []HitSpan = if (!pattern_changed) blk: {
                const sp_slice = self.job_arena.alloc(HitSpan, ci.spans.len) catch return false;
                for (ci.spans, 0..) |cs, si| {
                    sp_slice[si] = .{ .start = cs.start, .end = cs.end };
                }
                break :blk sp_slice;
            } else blk: {
                var sp_list: std.ArrayList(HitSpan) = .empty;
                const pf_ptr = &(primary_span_finder orelse break :blk &.{});
                var bpos: usize = 0;
                while (bpos <= ci.text.len) {
                    const hit = pf_ptr.find(ci.text, bpos, .leftmost_first) orelse break;
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
                .byteOffset = ci.byteOffset,
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

pub fn commitCacheAfterDone(self: *JobRunner) void {
    if (!self.should_commit_cache) return;
    if (self.send_failed.load(.acquire) or self.cancel_flag.load(.acquire) or self.had_scan_error.load(.acquire)) return;
    storeResultInCache(self, 
        self.pending_exact_hash,
        self.pending_tasks_fingerprint,
        self.pending_heat_epoch,
    );
}

pub fn storeResultInCache(self: *JobRunner, exact_hash: u64, tasks_fingerprint: u64, heat_epoch: u64) void {
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
            .byteOffset = it.byteOffset,
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

    const tf_sig_copy = if (self.time_format_sig.len > 0)
        entry_arena.allocator().dupe(u8, self.time_format_sig) catch {
            entry_arena.deinit();
            return;
        }
    else
        "";

    const archive_unrestricted = isArchiveUnrestricted(self);
    const archive_filter_hash = computeArchiveFilterHash(self);

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
        .time_mode = self.time_mode.asStr(),
        .time_format_sig = tf_sig_copy,
        .tz_offset_min = self.tz_offset_min,
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
        .files_pruned = self.files_pruned.load(.acquire),
        .bytes_saved = self.bytes_saved.load(.acquire),
        .bytes_scanned = self.bytes_scanned.load(.acquire),
        .limit_hit = self.hit_max_results.load(.acquire),
        .all_lines_exact = !self.had_non_exact_line.load(.acquire),
        .archive_unrestricted = archive_unrestricted,
        .archive_filter_hash = archive_filter_hash,
        .plugin_sig = self.plugin_sig,
        .kv_predicates_hash = self.kv_predicates_hash,
        .approx_bytes = approx_bytes,
        .access_tick = reg.search_cache.tick,
    }) catch {
        entry_arena.deinit();
        return;
    };
    reg.search_cache.total_bytes += approx_bytes;
}
