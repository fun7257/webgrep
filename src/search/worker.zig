const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");
const search_cache = @import("../search_cache.zig");
const prefilter = @import("../prefilter.zig");
const time_parser = @import("../time_parser.zig");
const protocol = @import("protocol.zig");
const limits = @import("limits.zig");
const query_plan = @import("query_plan.zig");
const types = @import("types.zig");
const sink_mod = @import("sink.zig");
const worker_special = @import("worker_special.zig");
const runner_mod = @import("runner.zig");

const JobRunner = runner_mod.JobRunner;
const FileSink = sink_mod.FileSink;
const FileTask = types.FileTask;
const PositionalFileCtx = types.PositionalFileCtx;
const PositionalWindowReader = types.PositionalWindowReader;
const HitItem = protocol.HitItem;
const HitSpan = protocol.HitSpan;
const HitsFrame = protocol.HitsFrame;
const EngineLimits = limits.EngineLimits;
const isSingleStreamCompressed = limits.isSingleStreamCompressed;
const parseCaseMode = query_plan.parseCaseMode;
const hasAsciiUpper = query_plan.hasAsciiUpper;

pub const WorkerContext = struct {
    runner: *JobRunner,
    batch_arena: *std.heap.ArenaAllocator,
    batch_items: std.ArrayList(HitItem) = .empty,
    scratch_pool: *libwebgrep.Scratch,
    time_regex_scratch: libwebgrep.RegexScratch,
    time_prefix_cache: time_parser.PrefixEpochCache = .{},
    last_flush_ts: std.Io.Timestamp,

    pub fn searchOneTask(self: *WorkerContext, task: *FileTask) void {
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

        const compression: libwebgrep.Compression = if (isSingleStreamCompressed(task.base_name))
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

        // Strong Consistency Service Config:
        // Explicitly populate full EngineLimits budgets so `searchSourceSlice` / `resumeSourceSlice`
        // (which use `serviceConfig` under the hood) never fall back to the 16 MiB default cap!
        const effective_ctx = @min(self.runner.req.context, EngineLimits.max_context_lines);
        const cfg = libwebgrep.SearchConfig{
            .line_numbers = true,
            .encoding = .auto,
            .compression = compression,
            .max_compression_ratio = EngineLimits.max_compression_ratio,
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
            .context = effective_ctx,
            .max_context_lines = EngineLimits.max_context_lines,
            .max_line_len = EngineLimits.max_line_len,
            .buffer_size = libwebgrep.SearchConfig.optimalBufferSize(self.runner.active_worker_count),
            .progress_interval = 512 * 1024,
            .max_source_bytes = EngineLimits.max_source_bytes,
            .max_request_bytes = EngineLimits.max_request_bytes,
            .max_output_bytes = EngineLimits.max_output_bytes,
            .time_budget_ns = EngineLimits.time_budget_ns,
            .max_decode_bytes = EngineLimits.max_decode_bytes,
            .max_decompressed_bytes = EngineLimits.max_decompressed_bytes,
            .max_before_bytes = EngineLimits.max_before_bytes,
            .max_queued_event_bytes = EngineLimits.max_queued_event_bytes,
            .allocator = self.runner.gpa,
            .decode_allocator = self.runner.gpa,
            .scratch_pool = self.scratch_pool,
            .cancel = self.runner.cancel_flag,
        };

        const fallback_ctx = time_parser.FallbackTimeContext.fromMtimeAndTz(task.mtime_ns, self.runner.tz_offset_min);
        const task_meta = JobRunner.makeTaskMeta(task);
        const task_preds = self.runner.makeQueryPreds(task);
        var time_hook_adapter = time_parser.TimeHookAdapter{
            .parser = task.line_time_parser,
            .scratch = &self.time_regex_scratch,
            .cache = &self.time_prefix_cache,
        };
        const time_hooks = time_hook_adapter.toTimeHooks();

        var sink = FileSink{
            .worker = self,
            .task = task,
            .rel_path = task.rel_path,
            .source_id = task.source_id,
            .source_name = task.source_name,
            .case_insensitive = is_case_insensitive,
            .fallback_ctx = fallback_ctx,
            .meta = task_meta,
            .preds = task_preds,
            .hooks = time_hooks,
        };

        var hot_lease: ?search_cache.HotFileLease = null;
        if (self.runner.registry) |reg| {
            if (compression == .none and task.archive_format == null and task.file_size > 0) {
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

        var opened_fallback_file: ?std.Io.File = null;
        defer if (opened_fallback_file) |*f| f.close(self.runner.io);

        var scoped_mm: ?std.Io.File.MemoryMap = null;
        defer if (scoped_mm) |*mm| mm.destroy(self.runner.io);

        const max_scoped_map_bytes = if (task.archive_format != null)
            EngineLimits.max_archive_slice_map_bytes
        else
            search_cache.MAX_HOT_FILE_MAP_BYTES;

        const maybe_mapped_slice: ?[]const u8 = if (hot_lease) |lease|
            lease.slice
        else if (compression == .none and task.file_size > 0 and task.file_size <= max_scoped_map_bytes) blk_scoped: {
            const f = parent_dir.openFile(self.runner.io, task.open_sub_path, .{ .allow_directory = false }) catch {
                self.runner.had_scan_error.store(true, .release);
                return;
            };
            opened_fallback_file = f;
            if (std.math.cast(usize, task.file_size)) |map_len| {
                if (map_len > 0) {
                    if (std.Io.File.MemoryMap.create(self.runner.io, f, .{
                        .len = map_len,
                        .protection = .{ .read = true, .write = false },
                        .populate = false,
                    })) |mm| {
                        scoped_mm = mm;
                        break :blk_scoped scoped_mm.?.memory[0..map_len];
                    } else |_| {}
                }
            }
            break :blk_scoped null;
        } else null;

        var local_cfg = cfg;

        if (task.archive_format) |archive_fmt| {
            sink.task_is_mtime_summary_only = self.runner.is_empty_text_time_browse and task.task_time_mode == .mtime;
            if (sink.task_is_mtime_summary_only) {
                local_cfg.max_count = 1;
            }
            worker_special.searchArchiveTask(self, &sink, task, archive_fmt, maybe_mapped_slice, parent_dir, &opened_fallback_file, local_cfg);
            return;
        }

        const recordWindowTsSketch = struct {
            fn isSafeOrderedSpan(
                win: prefilter.WindowSlice,
                preds: prefilter.QueryPredicates,
                mapped_opt: ?[]const u8,
                parser: *const time_parser.CompiledTimeParser,
                fb_ctx: time_parser.FallbackTimeContext,
                re_scratch: *libwebgrep.RegexScratch,
                px_cache: *time_parser.PrefixEpochCache,
            ) ?struct { min_ns: u64, max_ns: u64 } {
                const h = win.head_ts_ns orelse return null;
                const tail = win.tail_ts_ns orelse return null;
                if (win.status == .narrowed or win.status == .empty_skip) {
                    return .{ .min_ns = @min(h, tail), .max_ns = @max(h, tail) };
                }
                if (win.status == .full_scan and h <= tail and preds.hasTimeRange()) {
                    const eff_lo = if (preds.time_start_ns > 0) (preds.time_start_ns -| preds.bisect_slop_ns) else 0;
                    const eff_hi = if (preds.time_end_ns > 0) (preds.time_end_ns +| preds.bisect_slop_ns) else 0;
                    // Only treat `.full_scan` as verified ordered if bisect wasn't skipped due to non-monotonicity:
                    if ((eff_lo == 0 or h >= eff_lo) and (eff_hi == 0 or tail <= eff_hi)) {
                        if (mapped_opt) |mapped| {
                            if (mapped.len > 0) {
                                const mid_start = time_parser.findLineStartAtOrBefore(mapped, mapped.len / 2);
                                if (time_parser.findLineTimestampWithLookbehind(mapped, mid_start, parser, fb_ctx, re_scratch, px_cache)) |mh| {
                                    if (mh +| preds.bisect_slop_ns >= h and mh <= tail +| preds.bisect_slop_ns) {
                                        return .{ .min_ns = h, .max_ns = tail };
                                    }
                                    return null;
                                }
                            }
                        }
                    }
                }
                return null;
            }

            fn run(
                runner: *JobRunner,
                meta: prefilter.FileMeta,
                t: *FileTask,
                win: prefilter.WindowSlice,
                preds: prefilter.QueryPredicates,
                mapped_opt: ?[]const u8,
                fb_ctx: time_parser.FallbackTimeContext,
                re_scratch: *libwebgrep.RegexScratch,
                px_cache: *time_parser.PrefixEpochCache,
            ) void {
                if (t.counted_window_sketch_ts) return;
                const span = isSafeOrderedSpan(win, preds, mapped_opt, t.line_time_parser, fb_ctx, re_scratch, px_cache) orelse return;
                const reg = runner.registry orelse return;
                const store = reg.search_cache.getSketchStore() orelse return;
                const key = prefilter.sidecar_sketch.SketchKey.fromFileMeta(meta) orelse return;
                t.counted_window_sketch_ts = true;
                store.upsert(key, .{
                    .has_bloom = false,
                    .has_timestamps = true,
                    .has_ts_bounds = true,
                    .min_ts_ns = span.min_ns,
                    .max_ts_ns = span.max_ns,
                });
                reg.search_cache.markSketchDirty();
            }
        };

        var resolved_win: ?prefilter.WindowSlice = task.cached_window;
        var task_is_mtime_summary_only = false;

        const maybe_res = if (maybe_mapped_slice) |mapped_slice| blk_mmap: {
            sink.full_mapped_slice = mapped_slice;
            const win = resolved_win orelse blk_nw: {
                const w = prefilter.narrowSliceWindow(&task.plugin_chain, mapped_slice, task_meta, task_preds, time_hooks);
                task.cached_window = w;
                break :blk_nw w;
            };
            resolved_win = win;
            recordWindowTsSketch.run(self.runner, task_meta, task, win, task_preds, mapped_slice, fallback_ctx, &self.time_regex_scratch, &self.time_prefix_cache);

            var full_active_slice = mapped_slice;
            switch (win.status) {
                .empty_skip => {
                    full_active_slice = mapped_slice[0..0];
                    if (!task.counted_window_savings) {
                        task.counted_window_savings = true;
                        _ = self.runner.files_pruned.fetchAdd(1, .monotonic);
                        _ = self.runner.bytes_saved.fetchAdd(task.file_size, .monotonic);
                    }
                },
                .narrowed => {
                    const sb: usize = @intCast(@min(win.start_byte, mapped_slice.len));
                    const eb: usize = @intCast(@min(win.end_byte, mapped_slice.len));
                    full_active_slice = if (sb < eb) mapped_slice[sb..eb] else mapped_slice[0..0];
                    sink.sub_start_offset = sb;
                    sink.base_line_offset = win.base_line_offset;
                    if (started_from_beginning) {
                        sink.line_state.sticky_format_id = win.sticky_format_id;
                    }
                    if (!task.counted_window_savings and win.byteLen() < task.file_size) {
                        task.counted_window_savings = true;
                        _ = self.runner.bytes_saved.fetchAdd(task.file_size - win.byteLen(), .monotonic);
                    }
                },
                .unparsed_no_ts, .full_scan => {
                    if (started_from_beginning and win.sticky_format_id != null) {
                        sink.line_state.sticky_format_id = win.sticky_format_id;
                    }
                    const fell_back_to_mtime = (win.status == .unparsed_no_ts and task.allow_mtime_fallback and !task.strict_content_time) or
                        (!task.plugin_chain.has(.time_bisect) and task.task_time_mode == .mtime);
                    if (self.runner.is_empty_text_time_browse and fell_back_to_mtime) {
                        task_is_mtime_summary_only = true;
                        sink.task_is_mtime_summary_only = true;
                        local_cfg.max_count = 1;
                    }
                },
            }

            break :blk_mmap self.searchMappedSlice(&sink, task, full_active_slice, local_cfg);
        } else blk: {
            var file = if (opened_fallback_file) |f| f else parent_dir.openFile(self.runner.io, task.open_sub_path, .{ .allow_directory = false }) catch {
                self.runner.had_scan_error.store(true, .release);
                return;
            };
            if (opened_fallback_file == null) {
                opened_fallback_file = file;
            }

            var active_cfg = local_cfg;
            if (task.paused_result) |*prev| {
                active_cfg.resume_from = prev.resume_at orelse 0;
                active_cfg.continuation = &prev.resume_state;
            }

            if (compression == .none) {
                var pos_ctx = PositionalFileCtx{
                    .io = self.runner.io,
                    .file = file,
                    .size = task.file_size,
                };
                const win = resolved_win orelse blk_nw: {
                    const w = prefilter.narrowReaderWindow(&task.plugin_chain, pos_ctx.asPositionalReader(), task_meta, task_preds, time_hooks) catch prefilter.WindowSlice{
                        .start_byte = 0,
                        .end_byte = task.file_size,
                        .status = .full_scan,
                    };
                    task.cached_window = w;
                    break :blk_nw w;
                };
                resolved_win = win;
                recordWindowTsSketch.run(self.runner, task_meta, task, win, task_preds, null, fallback_ctx, &self.time_regex_scratch, &self.time_prefix_cache);

                switch (win.status) {
                    .empty_skip => {
                        if (!task.counted_window_savings) {
                            task.counted_window_savings = true;
                            _ = self.runner.files_pruned.fetchAdd(1, .monotonic);
                            _ = self.runner.bytes_saved.fetchAdd(task.file_size, .monotonic);
                        }
                        break :blk (switch (self.runner.matcher.*) {
                            .literal => |*f| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", f, active_cfg),
                            .multi => |*m| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", m, active_cfg),
                            .regex => |*r| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", r, active_cfg),
                        } catch null);
                    },
                    .narrowed => {
                        if (!task.counted_window_savings and win.byteLen() < task.file_size) {
                            task.counted_window_savings = true;
                            _ = self.runner.bytes_saved.fetchAdd(task.file_size - win.byteLen(), .monotonic);
                        }
                        if (win.start_byte > 0 or win.end_byte < task.file_size) {
                            sink.sub_start_offset = win.start_byte;
                            sink.base_line_offset = win.base_line_offset;
                            if (started_from_beginning) {
                                sink.line_state.sticky_format_id = win.sticky_format_id;
                            }
                            var win_reader = PositionalWindowReader{
                                .io = self.runner.io,
                                .file = file,
                                .cur_pos = win.start_byte,
                                .end_pos = win.end_byte,
                            };
                            win_reader.bindInterface();
                            var bounded_cfg = active_cfg;
                            bounded_cfg.compression = .none;
                            break :blk switch (self.runner.matcher.*) {
                                .literal => |*f| libwebgrep.searchSource(FileSink, self.runner.gpa, &sink, &win_reader.interface, task.rel_path, f, bounded_cfg),
                                .multi => |*m| libwebgrep.searchSource(FileSink, self.runner.gpa, &sink, &win_reader.interface, task.rel_path, m, bounded_cfg),
                                .regex => |*r| libwebgrep.searchSource(FileSink, self.runner.gpa, &sink, &win_reader.interface, task.rel_path, r, bounded_cfg),
                            } catch null;
                        }
                    },
                    .unparsed_no_ts, .full_scan => {
                        if (started_from_beginning and win.sticky_format_id != null) {
                            sink.line_state.sticky_format_id = win.sticky_format_id;
                        }
                        const fell_back_to_mtime = (win.status == .unparsed_no_ts and task.allow_mtime_fallback and !task.strict_content_time) or
                            (!task.plugin_chain.has(.time_bisect) and task.task_time_mode == .mtime);
                        if (self.runner.is_empty_text_time_browse and fell_back_to_mtime) {
                            task_is_mtime_summary_only = true;
                            sink.task_is_mtime_summary_only = true;
                            active_cfg.max_count = 1;
                        }
                    },
                }

                break :blk switch (self.runner.matcher.*) {
                    .literal => |*f| libwebgrep.searcher.searchFile(FileSink, self.runner.gpa, self.runner.io, &sink, file, task.rel_path, f, active_cfg),
                    .multi => |*m| libwebgrep.searcher.searchFile(FileSink, self.runner.gpa, self.runner.io, &sink, file, task.rel_path, m, active_cfg),
                    .regex => |*r| libwebgrep.searcher.searchFile(FileSink, self.runner.gpa, self.runner.io, &sink, file, task.rel_path, r, active_cfg),
                } catch null;
            }

            if (self.runner.is_empty_text_time_browse and task.task_time_mode == .mtime) {
                task_is_mtime_summary_only = true;
                sink.task_is_mtime_summary_only = true;
                active_cfg.max_count = 1;
            }

            var fallback_buf: [65536]u8 = undefined;
            var file_reader = file.reader(self.runner.io, &fallback_buf);

            break :blk switch (self.runner.matcher.*) {
                .literal => |*f| libwebgrep.searchReader(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, f, active_cfg),
                .multi => |*m| libwebgrep.searchReader(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, m, active_cfg),
                .regex => |*r| libwebgrep.searchReader(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, r, active_cfg),
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
            if (res.paused) {
                task.paused_result = res;
            } else {
                task.paused_result = null;
            }
            const bytes = if (res.bytes_searched > 0) res.bytes_searched else res.bytes_read;
            if (bytes > task.phase_bytes) {
                _ = self.runner.bytes_searched.fetchAdd(bytes - task.phase_bytes, .monotonic);
                task.phase_bytes = bytes;
            }
            if (bytes > task.prev_scanned_bytes) {
                _ = self.runner.bytes_scanned.fetchAdd(bytes - task.prev_scanned_bytes, .monotonic);
                task.prev_scanned_bytes = bytes;
            }
            task_scanned_complete = (res.scanned_all or res.outcome == .binary_quit or task_is_mtime_summary_only) and res.soft_error == null and res.limit_hit == .none;
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
            task.archive_format == null)
        {
            if (self.runner.registry) |reg| {
                if (maybe_mapped_slice) |mapped_slice| {
                    if (reg.search_cache.getSketchStore()) |store| {
                        const full_window = if (resolved_win) |w|
                            (w.status != .empty_skip and ((w.start_byte == 0 and w.end_byte == mapped_slice.len) or mapped_slice.len <= 4 * 1024 * 1024))
                        else
                            true;
                        if (full_window) {
                            var min_ts: ?u64 = null;
                            var max_ts: ?u64 = null;
                            var has_ts = false;
                            if (resolved_win) |w| {
                                if (recordWindowTsSketch.isSafeOrderedSpan(
                                    w,
                                    task_preds,
                                    mapped_slice,
                                    task.line_time_parser,
                                    fallback_ctx,
                                    &self.time_regex_scratch,
                                    &self.time_prefix_cache,
                                )) |span| {
                                    min_ts = span.min_ns;
                                    max_ts = span.max_ns;
                                    has_ts = true;
                                }
                            }
                            store.recordFullFile(task_meta, mapped_slice, min_ts, max_ts, has_ts);
                            reg.search_cache.markSketchDirty();
                        }
                    }
                }
            }
        }

        if (started_from_beginning and
            task_scanned_complete and
            !self.runner.shouldStop() and
            !task.paused_at_soft_quota and
            !sink.file_had_match and
            task.emitted_in_file == 0 and
            task.archive_format == null)
        {
            if (self.runner.registry) |reg| {
                const is_plain_literal = switch (self.runner.matcher.*) {
                    .literal => true,
                    else => false,
                };
                if (is_plain_literal and
                    self.runner.time_start_ns == 0 and
                    self.runner.time_end_ns == 0 and
                    self.runner.kv_predicates.len == 0 and
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

    pub fn searchMappedSlice(
        self: *WorkerContext,
        sink: *FileSink,
        task: *FileTask,
        full_active_slice: []const u8,
        cfg: libwebgrep.SearchConfig,
    ) ?libwebgrep.Result {
        if (task.paused_result) |prev| {
            return (switch (self.runner.matcher.*) {
                .literal => |*f| libwebgrep.resumeSourceSlice(FileSink, sink, task.rel_path, full_active_slice, f, cfg, prev),
                .multi => |*m| libwebgrep.resumeSourceSlice(FileSink, sink, task.rel_path, full_active_slice, m, cfg, prev),
                .regex => |*r| libwebgrep.resumeSourceSlice(FileSink, sink, task.rel_path, full_active_slice, r, cfg, prev),
            } catch null);
        }
        return (switch (self.runner.matcher.*) {
            .literal => |*f| libwebgrep.searchSourceSlice(FileSink, sink, task.rel_path, full_active_slice, f, cfg),
            .multi => |*m| libwebgrep.searchSourceSlice(FileSink, sink, task.rel_path, full_active_slice, m, cfg),
            .regex => |*r| libwebgrep.searchSourceSlice(FileSink, sink, task.rel_path, full_active_slice, r, cfg),
        } catch null);
    }

    /// Universal real-time streaming flush rule (identical across literal, multi, and regex modes):
    /// 1. First screen batch (`batches_flushed == 0`): flush immediately on the very first match (`count >= 1`).
    /// 2. Early batches (`batches_flushed < 4`): flush at 32 items or 16ms.
    /// 3. Mid batches (`batches_flushed < 12`): flush at 128 items or 25ms.
    pub fn maybeFlushStreaming(self: *WorkerContext, force_time_check: bool) void {
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

        const item_cap: usize = if (flushed_so_far < 4)
            32
        else if (flushed_so_far < 12)
            128
        else
            512;
        if (count >= item_cap) {
            _ = self.runner.batches_flushed.fetchAdd(1, .monotonic);
            self.flushBatch() catch {
                self.runner.send_failed.store(true, .release);
            };
            return;
        }

        if (force_time_check or flushed_so_far < 4 or count >= 16) {
            const min_ns: i64 = if (flushed_so_far < 4)
                16 * std.time.ns_per_ms
            else if (flushed_so_far < 12)
                25 * std.time.ns_per_ms
            else
                35 * std.time.ns_per_ms;
            const elapsed_ns = self.last_flush_ts.untilNow(self.runner.io, .awake).toNanoseconds();
            if (elapsed_ns >= min_ns) {
                _ = self.runner.batches_flushed.fetchAdd(1, .monotonic);
                self.flushBatch() catch {
                    self.runner.send_failed.store(true, .release);
                };
            }
        }
    }

    pub fn flushBatch(self: *WorkerContext) !void {
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
                            .byteOffset = it.byteOffset,
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
