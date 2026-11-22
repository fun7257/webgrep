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
const path_filter = @import("path_filter.zig");
const cache_ops = @import("cache_ops.zig");
const proximity = @import("proximity.zig");
const worker_mod = @import("worker.zig");

const SearchRequest = protocol.SearchRequest;
const FrameSender = protocol.FrameSender;
const HitItem = protocol.HitItem;
const HitsFrame = protocol.HitsFrame;
const ProgressFrame = protocol.ProgressFrame;
const MatcherUnion = query_plan.MatcherUnion;
const FileTask = types.FileTask;
const SourcePipelineConfig = types.SourcePipelineConfig;
const WorkerContext = worker_mod.WorkerContext;
const custom_file_types = limits.custom_file_types;
const isSingleStreamCompressed = limits.isSingleStreamCompressed;
const detectArchiveFormat = limits.detectArchiveFormat;
const parseScopedModifier = query_plan.parseScopedModifier;
const parseCaseMode = query_plan.parseCaseMode;
const hasAsciiUpper = query_plan.hasAsciiUpper;

pub const JobRunner = struct {
    gpa: std.mem.Allocator,
    job_arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    registry: ?*source_registry.SourceRegistry = null,
    req: SearchRequest,
    matcher: *const MatcherUnion,
    compiled_globs: []const libwebgrep.walk_glob.Glob,
    expanded_file_globs: []const []const u8 = &.{},
    types_include: []const []const u8 = &.{},
    types_exclude: []const []const u8 = &.{},
    custom_types_table: []const libwebgrep.walk_types.Type = &custom_file_types,
    contains_regexes: []const libwebgrep.Regex = &.{},
    excludes_regexes: []const libwebgrep.Regex = &.{},
    swapped_primary_regex_first: bool = false,
    swapped_primary_finder: ?libwebgrep.Finder = null,
    cancel_flag: *const std.atomic.Value(bool),
    sender: FrameSender,
    time_start_ns: u64 = 0,
    time_end_ns: u64 = 0,
    time_mode: time_parser.TimeMode = .auto,
    tz_offset_min: i16 = 0,
    now_epoch_ms: u64 = 0,
    time_format_sig: []const u8 = "",
    default_line_time_parser: *const time_parser.CompiledTimeParser,
    is_empty_text_time_browse: bool = false,
    kv_predicates: []const prefilter.KvPredicate = &.{},
    kv_predicates_hash: u64 = 0,
    literal_anchors: []const []const u8 = &.{},
    anchor_case_flags: []const bool = &.{},
    anchors_case_insensitive: bool = true,
    plugin_sig: u64 = 0,

    visited_dir_ids: std.AutoHashMapUnmanaged(libwebgrep.walk_file_id.Id, void) = .empty,
    visited_file_ids: std.AutoHashMapUnmanaged(libwebgrep.walk_file_id.Id, void) = .empty,

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
    files_pruned: std.atomic.Value(u64) = .init(0),
    bytes_saved: std.atomic.Value(u64) = .init(0),
    bytes_scanned: std.atomic.Value(u64) = .init(0),
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

    pub fn shouldStop(self: *const JobRunner) bool {
        return self.hit_max_results.load(.acquire) or
            self.send_failed.load(.acquire) or
            self.cancel_flag.load(.acquire);
    }

    pub fn makeTaskMeta(task: *const FileTask) prefilter.FileMeta {
        return .{
            .rel_path = task.rel_path,
            .base_name = task.base_name,
            .size_bytes = task.file_size,
            .mtime_ns = task.mtime_ns,
            .inode = @intCast(task.inode),
            .dev = task.dev,
            .is_archive_container = (task.archive_format != null),
            .is_compressed = isSingleStreamCompressed(task.base_name),
            .has_custom_time_format = (task.line_time_parser.mode != .auto),
        };
    }

    pub fn makeQueryPreds(self: *const JobRunner, task: *const FileTask) prefilter.QueryPredicates {
        return .{
            .time_start_ns = self.time_start_ns,
            .time_end_ns = self.time_end_ns,
            .tz_offset_min = self.tz_offset_min,
            .now_epoch_ms = self.now_epoch_ms,
            .source_kind = task.source_kind,
            .time_mode = task.task_time_mode.toPrefilter(),
            .preset = task.plugin_chain.preset,
            .custom_plugin_mask = task.plugin_chain.active_mask,
            .literal_anchors = self.literal_anchors,
            .anchors_case_insensitive = self.anchors_case_insensitive,
            .anchor_case_flags = self.anchor_case_flags,
            .kv_predicates = self.kv_predicates,
            .allow_mtime_fallback_on_no_ts = task.allow_mtime_fallback,
            .strict_content_time = task.strict_content_time,
        };
    }

    pub fn enqueueTask(
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
        dev: u64,
        line_tp: *const time_parser.CompiledTimeParser,
        src_pipe: SourcePipelineConfig,
    ) !void {
        const archive_fmt = detectArchiveFormat(base_name);
        if (archive_fmt == null) {
            if (!self.fileMatchesPathGlobs(rel_path, base_name)) return;
        } else {
            if (!path_filter.archiveContainerAllowedByPathGlobs(self, rel_path, base_name)) return;
        }
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
            .source_kind = src_pipe.source_kind,
            .archive_format = archive_fmt,
            .effective_contains = effective_contains,
            .effective_excludes = effective_excludes,
            .line_time_parser = line_tp,
            .task_time_mode = src_pipe.task_time_mode,
            .plugin_chain = src_pipe.chain,
            .strict_content_time = src_pipe.strict_content_time,
            .allow_mtime_fallback = src_pipe.allow_mtime_fallback,
            .mtime_ns = mtime_ns,
            .file_size = file_size,
            .inode = inode,
            .dev = dev,
            .access_heat = 0,
        });
    }

    /// Computes initial file heat scores (Recency mtime + User Access Heat), sorts hotter files first,
    /// and assigns Phase 1 heat-proportional soft quotas (`Water-Filling` pass 1).
    pub fn prepareHeatAndQuotas(self: *JobRunner) void {
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

    pub fn runWaterFillingForSubset(self: *JobRunner, subset_indices: []const usize, use_soft_quota: bool) void {
        if (subset_indices.len == 0 or self.shouldStop()) return;

        const max_res = self.req.maxResults;
        const init_cur = self.total_matches.load(.acquire);
        if (max_res > 0 and init_cur >= max_res) return;

        self.active_task_indices.clearRetainingCapacity();
        for (subset_indices) |idx| {
            self.active_task_indices.appendAssumeCapacity(idx);
        }

        if (!use_soft_quota or max_res == 0 or subset_indices.len == 1) {
            for (subset_indices) |idx| {
                self.file_tasks.items[idx].soft_quota = 0;
            }
        } else {
            const remaining_init = max_res - init_cur;
            var subset_heat: u64 = 0;
            for (subset_indices) |idx| {
                subset_heat +|= self.file_tasks.items[idx].heat_score;
            }
            if (subset_heat == 0) subset_heat = 1;
            const sub_n: u64 = @intCast(subset_indices.len);
            const min_floor: u64 = @min(remaining_init, @max(@as(u64, 1), remaining_init / @max(@as(u64, 1), sub_n * 2)));
            for (subset_indices) |idx| {
                var t = &self.file_tasks.items[idx];
                const raw_share = (remaining_init * t.heat_score) / subset_heat;
                t.soft_quota = @max(min_floor, @min(remaining_init, raw_share));
            }
        }

        // Phase 1: Heat-prioritized initial proportional pass across subset candidate files
        self.executeWorkerPass();

        // Phase 2+: Iterative Dynamic Density-Weighted Water-Filling for subset files that hit their soft quota
        while (!self.shouldStop()) {
            const cur_total = self.total_matches.load(.acquire);
            if (max_res > 0 and cur_total >= max_res) break;

            self.active_task_indices.clearRetainingCapacity();
            for (subset_indices) |idx| {
                var t = &self.file_tasks.items[idx];
                if (t.paused_at_soft_quota) {
                    const denom = @max(@as(u64, 4096), t.phase_bytes);
                    const density_heat = @min(@as(u64, 2000), (t.emitted_in_file * 1024 * 1024) / denom);
                    t.heat_score = t.base_heat + density_heat;
                    self.active_task_indices.appendAssumeCapacity(idx);
                }
            }

            const overflow_count = self.active_task_indices.items.len;
            if (overflow_count == 0) break;

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
    }

    pub fn executeWorkerPass(self: *JobRunner) void {
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

    pub fn flushItemsSliceToSender(self: *JobRunner, items: []const HitItem) void {
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

    pub fn runParallelWorkers(self: *JobRunner) void {
        const total_files = self.file_tasks.items.len;
        if (total_files == 0) return;

        const tasks_fingerprint = self.computeTasksFingerprint();
        const heat_epoch: u64 = if (self.registry) |reg| reg.getHeatEpoch() else 0;
        const exact_hash = self.computeExactQueryHash(tasks_fingerprint, heat_epoch);

        // Tier L1: Exact Query Frame Replay Cache (< 0.2ms)
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

        var normal_indices: std.ArrayList(usize) = .empty;
        var colossal_indices: std.ArrayList(usize) = .empty;
        normal_indices.ensureTotalCapacity(self.job_arena, total_files) catch return;
        colossal_indices.ensureTotalCapacity(self.job_arena, total_files) catch return;

        const sketch_store = if (self.registry) |reg| reg.search_cache.getSketchStore() else null;
        for (0..total_files) |idx| {
            const t = &self.file_tasks.items[idx];
            const t_meta = makeTaskMeta(t);
            const t_preds = self.makeQueryPreds(t);
            const prune_dec: prefilter.PruneDecision = blk_prune: {
                if (t.task_time_mode != .mtime) {
                    break :blk_prune prefilter.pruneFile(&t.plugin_chain, t_meta, t_preds, sketch_store);
                }
                // In `.mtime` mode (or `.code` preset), time ranges filter file `mtime`, NOT line timestamps,
                // so `sidecar_sketch` must only check `literal_anchors` (TrigramBloom), never content `[min_ts, max_ts]`.
                const meta_dec = prefilter.pruneFile(&t.plugin_chain, t_meta, t_preds, null);
                if (meta_dec.verdict == .skip) break :blk_prune meta_dec;
                if (t.plugin_chain.has(.sidecar_sketch) and t_preds.literal_anchors.len > 0) {
                    if (sketch_store) |store| {
                        var bloom_only_preds = t_preds;
                        bloom_only_preds.time_start_ns = 0;
                        bloom_only_preds.time_end_ns = 0;
                        if (prefilter.sidecar_sketch.eval(store, t_meta, bloom_only_preds) == .skip) {
                            break :blk_prune .{ .verdict = .skip, .pruned_by = .sidecar_sketch };
                        }
                    }
                }
                break :blk_prune .{ .verdict = .keep, .pruned_by = null };
            };
            if (prune_dec.verdict == .skip) {
                t.counted_file_searched = true;
                _ = self.files_searched.fetchAdd(1, .monotonic);
                _ = self.files_pruned.fetchAdd(1, .monotonic);
                _ = self.bytes_saved.fetchAdd(t.file_size, .monotonic);
                if (prune_dec.pruned_by == .sidecar_sketch) {
                    self.pruned_by_negative_cache.store(true, .release);
                }
                continue;
            }
            if (can_use_negative_prune and self.kv_predicates.len == 0 and req_literals_len > 0 and (t.archive_format == null or self.isArchiveUnrestricted())) {
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
                    _ = self.files_pruned.fetchAdd(1, .monotonic);
                    _ = self.bytes_saved.fetchAdd(cached_bytes, .monotonic);
                    self.pruned_by_negative_cache.store(true, .release);
                    continue;
                }
            }
            if (t.isColossal()) {
                colossal_indices.appendAssumeCapacity(idx);
            } else {
                normal_indices.appendAssumeCapacity(idx);
            }
        }

        // Stage 1: Run complete Phase 1 + Phase 2+ elastic water-filling on normal files (<= 256 MiB) first
        // so multi-GB files never stall Phase 1 or delay hitting maxResults on normal files.
        if (normal_indices.items.len > 0) {
            self.runWaterFillingForSubset(normal_indices.items, true);
        }

        // Stage 2: If normal files did not exhaust maxResults, scan colossal files (> 256 MiB) without soft_quota pauses.
        if (!self.shouldStop() and colossal_indices.items.len > 0) {
            self.runWaterFillingForSubset(colossal_indices.items, false);
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
            const final_heat_epoch: u64 = if (self.registry) |reg| reg.getHeatEpoch() else heat_epoch;
            self.should_commit_cache = true;
            self.pending_exact_hash = if (final_heat_epoch == heat_epoch)
                exact_hash
            else
                self.computeExactQueryHash(tasks_fingerprint, final_heat_epoch);
            self.pending_tasks_fingerprint = tasks_fingerprint;
            self.pending_heat_epoch = final_heat_epoch;
        }
    }

    pub fn workerThreadMain(self: *JobRunner) void {
        var batch_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer batch_arena_state.deinit();

        var scratch_pool = libwebgrep.Scratch.init(self.gpa);
        defer scratch_pool.deinit();

        var worker = WorkerContext{
            .runner = self,
            .batch_arena = &batch_arena_state,
            .scratch_pool = &scratch_pool,
            .time_regex_scratch = libwebgrep.RegexScratch.init(self.gpa),
            .last_flush_ts = std.Io.Clock.awake.now(self.io),
        };
        defer worker.time_regex_scratch.deinit();
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

    pub fn maybeSendProgress(self: *JobRunner, in_file_bytes: u64) void {
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

    // --- Delegated path_filter helpers ---
    pub fn activeFileGlobs(self: *const JobRunner) []const []const u8 {
        return path_filter.activeFileGlobs(self);
    }
    pub fn fileMatchesPathGlobs(self: *const JobRunner, rel_path: []const u8, base_name: []const u8) bool {
        return path_filter.fileMatchesPathGlobs(self, rel_path, base_name);
    }
    pub fn archiveEntryMatchesPathGlobs(
        self: *const JobRunner,
        archive_rel_path: []const u8,
        archive_base_name: []const u8,
        entry_path: []const u8,
    ) bool {
        return path_filter.archiveEntryMatchesPathGlobs(self, archive_rel_path, archive_base_name, entry_path);
    }
    pub fn archiveEntryGlobs(
        self: *const JobRunner,
        archive_rel_path: []const u8,
        archive_base_name: []const u8,
    ) []const []const u8 {
        return path_filter.archiveEntryGlobs(self, archive_rel_path, archive_base_name);
    }
    pub fn matchesProjectScopeToken(src_id: []const u8, src_name: []const u8, token: []const u8) bool {
        return path_filter.matchesProjectScopeToken(src_id, src_name, token);
    }
    pub fn sourceMatchesProjectFilters(self: *const JobRunner, src_id: []const u8, src_name: []const u8) bool {
        return path_filter.sourceMatchesProjectFilters(self, src_id, src_name);
    }
    pub fn fileMatchesSourceFilters(
        self: *const JobRunner,
        src_id: []const u8,
        src_name: []const u8,
        base_name: []const u8,
    ) bool {
        return path_filter.fileMatchesSourceFilters(self, src_id, src_name, base_name);
    }
    pub fn walkDirectoryForSource(
        self: *JobRunner,
        dir: std.Io.Dir,
        parent_root_override: ?[]const u8,
        src_id: []const u8,
        src_name: []const u8,
        effective_contains: []const []const u8,
        effective_excludes: []const []const u8,
        rel_dir: []const u8,
        parent_ignore: ?*const libwebgrep.walk_ignore.Set,
        line_tp: *const time_parser.CompiledTimeParser,
        src_pipe: SourcePipelineConfig,
    ) !void {
        return path_filter.walkDirectoryForSource(
            self,
            dir,
            parent_root_override,
            src_id,
            src_name,
            effective_contains,
            effective_excludes,
            rel_dir,
            parent_ignore,
            line_tp,
            src_pipe,
        );
    }

    // --- Delegated cache_ops helpers ---
    pub fn computeTasksFingerprint(self: *const JobRunner) u64 {
        return cache_ops.computeTasksFingerprint(self);
    }
    pub fn computeExactQueryHash(self: *const JobRunner, tasks_fingerprint: u64, heat_epoch: u64) u64 {
        return cache_ops.computeExactQueryHash(self, tasks_fingerprint, heat_epoch);
    }
    pub fn tryReplayExactCache(self: *JobRunner, exact_hash: u64, tasks_fingerprint: u64, heat_epoch: u64) bool {
        return cache_ops.tryReplayExactCache(self, exact_hash, tasks_fingerprint, heat_epoch);
    }
    pub fn lineMatchesTaskPredicates(
        self: *const JobRunner,
        task: *const FileTask,
        line_text: []const u8,
        parsed_case: libwebgrep.CaseMode,
        default_case_insensitive: bool,
    ) bool {
        return cache_ops.lineMatchesTaskPredicates(self, task, line_text, parsed_case, default_case_insensitive);
    }
    pub fn isArchiveUnrestricted(self: *const JobRunner) bool {
        return cache_ops.isArchiveUnrestricted(self);
    }
    pub fn tryFilterSupersetCache(self: *JobRunner, exact_hash: u64, tasks_fingerprint: u64, heat_epoch: u64) bool {
        return cache_ops.tryFilterSupersetCache(self, exact_hash, tasks_fingerprint, heat_epoch);
    }
    pub fn commitCacheAfterDone(self: *JobRunner) void {
        cache_ops.commitCacheAfterDone(self);
    }

    // --- Delegated proximity helpers ---
    pub fn runnerShouldStopCallback(ctx: *const anyopaque) bool {
        return proximity.runnerShouldStopCallback(ctx);
    }
    pub fn canRunBlockProximityFallback(self: *const JobRunner) bool {
        return proximity.canRunBlockProximityFallback(self);
    }
    pub fn tryNearbyFallbackAfterCache(self: *JobRunner) void {
        proximity.tryNearbyFallbackAfterCache(self);
    }
    pub fn runBlockProximityFallback(self: *JobRunner) bool {
        return proximity.runBlockProximityFallback(self);
    }
};
