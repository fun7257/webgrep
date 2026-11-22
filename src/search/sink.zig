const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");
const prefilter = @import("../prefilter.zig");
const time_parser = @import("../time_parser.zig");
const protocol = @import("protocol.zig");
const limits = @import("limits.zig");
const types = @import("types.zig");
const worker_mod = @import("worker.zig");

const WorkerContext = worker_mod.WorkerContext;
const FileTask = types.FileTask;
const HitItem = protocol.HitItem;
const HitSpan = protocol.HitSpan;
const formatArchiveVirtualPathAlloc = limits.formatArchiveVirtualPathAlloc;

pub const FileSink = struct {
    worker: *WorkerContext,
    task: *FileTask,
    rel_path: []const u8,
    source_id: []const u8 = "",
    source_name: []const u8 = "",
    current_archive_entry: []const u8 = "",
    case_insensitive: bool = true,
    file_had_match: bool = false,
    base_line_offset: u64 = 0,
    sub_start_offset: u64 = 0,
    full_mapped_slice: ?[]const u8 = null,
    check_line_timestamps: bool = false,
    file_has_timestamps: bool = false,
    fallback_ctx: time_parser.FallbackTimeContext = .{},
    has_last_line_ts: bool = false,
    last_line_ns: u64 = 0,
    meta: prefilter.FileMeta = .{ .rel_path = "" },
    preds: prefilter.QueryPredicates = .{},
    hooks: prefilter.TimeHooks = .{},
    line_state: prefilter.LineState = .{},
    task_is_mtime_summary_only: bool = false,

    pub fn control(self: *const FileSink) libwebgrep.Flow {
        return if (self.task.paused_at_soft_quota) .pause else .stop;
    }

    pub fn toLineEvent(self: *FileSink, line: libwebgrep.Line) libwebgrep.LineEvent {
        const u16_column = if (line.matches.len > 0)
            @as(u64, line.matches[0].u16_start) + 1
        else
            line.u16_column;
        return .{
            .source_id = if (self.current_archive_entry.len > 0) self.current_archive_entry else self.rel_path,
            .line_number = line.number orelse 0,
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
        return self.event(.{ .match = self.toLineEvent(line) }) == .cont;
    }

    pub fn context(self: *FileSink, line: libwebgrep.Line) bool {
        return self.event(.{ .context = self.toLineEvent(line) }) == .cont;
    }

    pub fn progress(self: *FileSink, bytes_searched: u64, match_count: u64, matched_lines: u64) bool {
        return self.event(.{ .progress = .{
            .source_id = self.rel_path,
            .bytes_searched = bytes_searched,
            .matches = match_count,
            .matched_lines = matched_lines,
        } }) == .cont;
    }

    pub fn event(self: *FileSink, ev: libwebgrep.Event) libwebgrep.Flow {
        const runner = self.worker.runner;
        if (runner.shouldStop()) return .stop;

        const is_archive = (self.task.archive_format != null);

        switch (ev) {
            .begin => |b| {
                self.last_line_ns = 0;
                self.has_last_line_ts = false;
                if (is_archive) {
                    self.line_state.reset();
                    self.current_archive_entry = b.source_id;
                }
                return .cont;
            },
            .match => |line| {
                const raw_line_no = if (line.line_number > 0) line.line_number else 1;
                const line_no = raw_line_no + self.base_line_offset;
                if (!is_archive and line_no <= self.task.resume_after_line) {
                    return .cont;
                }

                var eff_meta = self.meta;
                if (is_archive) {
                    const entry_path = if (line.source_id.len > 0) line.source_id else self.current_archive_entry;
                    if (!runner.archiveEntryMatchesPathGlobs(self.rel_path, self.task.base_name, entry_path)) {
                        return .cont;
                    }
                    eff_meta.is_archive_entry = true;
                    eff_meta.is_archive_container = false;
                    eff_meta.rel_path = entry_path;
                    eff_meta.base_name = std.fs.path.basename(entry_path);
                }

                const need_line_filter = (runner.time_start_ns > 0 or runner.time_end_ns > 0 or self.preds.kv_predicates.len > 0);
                if (need_line_filter) {
                    const raw_text = if (line.text.len > 0) line.text else line.bytes;
                    if (self.task_is_mtime_summary_only) {
                        if (self.preds.kv_predicates.len > 0) {
                            var kv_only_preds = self.preds;
                            kv_only_preds.time_start_ns = 0;
                            kv_only_preds.time_end_ns = 0;
                            if (!prefilter.filterLine(&self.task.plugin_chain, raw_text, eff_meta, kv_only_preds, &self.line_state, self.hooks)) {
                                return .cont;
                            }
                        }
                    } else {
                        if (!is_archive and self.full_mapped_slice != null and self.preds.hasTimeRange() and self.task.plugin_chain.has(.line_time)) {
                            if (time_parser.isLikelyContinuationLine(raw_text)) {
                                if (self.task.line_time_parser.parseLine(
                                    raw_text,
                                    self.fallback_ctx,
                                    &self.worker.time_regex_scratch,
                                    &self.worker.time_prefix_cache,
                                ) == null) {
                                    const mapped = self.full_mapped_slice.?;
                                    const start_off_usize: usize = @intCast(@min(self.sub_start_offset, @as(u64, mapped.len)));
                                    const rel_off: usize = @intCast(@min(line.absolute_offset, mapped.len -| start_off_usize));
                                    const abs_pos = start_off_usize + rel_off;
                                    const line_start = time_parser.findLineStartAtOrBefore(mapped, @min(abs_pos, mapped.len));
                                    if (time_parser.findLineTimestampWithLookbehind(
                                        mapped,
                                        line_start,
                                        self.task.line_time_parser,
                                        self.fallback_ctx,
                                        &self.worker.time_regex_scratch,
                                        &self.worker.time_prefix_cache,
                                    )) |parent_ns| {
                                        self.line_state.prev_ts_ns = parent_ns;
                                        self.line_state.saw_any_timestamp = true;
                                        self.line_state.prev_in_range = (self.preds.time_start_ns == 0 or parent_ns >= self.preds.time_start_ns) and
                                            (self.preds.time_end_ns == 0 or parent_ns <= self.preds.time_end_ns);
                                    }
                                }
                            }
                        }
                        if (!prefilter.filterLine(&self.task.plugin_chain, raw_text, eff_meta, self.preds, &self.line_state, self.hooks)) {
                            return .cont;
                        }
                    }
                }

                const max_res = runner.req.maxResults;
                if (max_res > 0 and runner.total_matches.load(.monotonic) >= max_res) {
                    runner.hit_max_results.store(true, .release);
                    return .stop;
                }

                const prev_total = runner.total_matches.fetchAdd(1, .monotonic);
                if (max_res > 0 and prev_total >= max_res) {
                    _ = runner.total_matches.fetchSub(1, .monotonic);
                    runner.hit_max_results.store(true, .release);
                    return .stop;
                }

                self.file_had_match = true;
                self.task.emitted_in_file += 1;
                if (!is_archive) {
                    self.task.resume_after_line = line_no;
                }
                const emitted_now = self.task.emitted_in_file;
                _ = runner.matched_lines.fetchAdd(1, .monotonic);

                var adjusted_line = line;
                adjusted_line.line_number = line_no;
                self.appendLineEvent(adjusted_line, false, 0) catch {
                    return .stop;
                };

                self.worker.maybeFlushStreaming(false);
                if (runner.send_failed.load(.acquire)) return .stop;

                if (max_res > 0 and prev_total + 1 >= max_res) {
                    runner.hit_max_results.store(true, .release);
                    return .stop;
                }

                if (!is_archive and self.task.soft_quota > 0 and emitted_now >= self.task.soft_quota) {
                    self.task.paused_at_soft_quota = true;
                    return .pause;
                }
                return .cont;
            },
            .context => |line| {
                const raw_line_no = if (line.line_number > 0) line.line_number else 1;
                const line_no = raw_line_no + self.base_line_offset;
                if (!is_archive and line_no <= self.task.resume_after_line) {
                    return .cont;
                }
                if (is_archive) {
                    const entry_path = if (line.source_id.len > 0) line.source_id else self.current_archive_entry;
                    if (!runner.archiveEntryMatchesPathGlobs(self.rel_path, self.task.base_name, entry_path)) {
                        return .cont;
                    }
                }
                var adjusted_line = line;
                adjusted_line.line_number = line_no;
                self.appendLineEvent(adjusted_line, true, 0) catch {
                    return .stop;
                };
                self.worker.maybeFlushStreaming(false);
                if (runner.send_failed.load(.acquire)) return .stop;
                return .cont;
            },
            .progress => |prog| {
                if (!is_archive and prog.bytes_searched > self.task.phase_bytes) {
                    _ = runner.bytes_searched.fetchAdd(prog.bytes_searched - self.task.phase_bytes, .monotonic);
                    self.task.phase_bytes = prog.bytes_searched;
                }
                self.worker.maybeFlushStreaming(true);
                runner.maybeSendProgress(0);
                return if (runner.shouldStop()) .stop else .cont;
            },
            else => return .cont,
        }
    }

    pub fn appendLineEvent(self: *FileSink, line: libwebgrep.LineEvent, is_context: bool, max_spans: usize) !void {
        const arena = self.worker.batch_arena.allocator();
        const is_archive = (self.task.archive_format != null);
        const file_duped = if (is_archive) blk_vpath: {
            const raw_entry = if (line.source_id.len > 0 and !std.mem.eql(u8, line.source_id, self.rel_path))
                line.source_id
            else
                self.current_archive_entry;
            const entry_path = std.mem.trimStart(u8, raw_entry, "./");
            if (entry_path.len > 0) {
                break :blk_vpath try formatArchiveVirtualPathAlloc(arena, self.rel_path, entry_path);
            }
            break :blk_vpath try arena.dupe(u8, self.rel_path);
        } else try arena.dupe(u8, self.rel_path);

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
            } else if (runner.swapped_primary_finder) |*pf| {
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

        const hit_byte_offset: ?u64 = if (!is_archive and file_api.detectCompression(self.task.base_name) == null)
            self.sub_start_offset +| line.raw_offset
        else
            null;

        try self.worker.batch_items.append(self.worker.runner.gpa, .{
            .file = file_duped,
            .line = if (line.line_number > 0) line.line_number else 1,
            .col = col,
            .text = text_duped,
            .prevText = null,
            .nextText = null,
            .replaced = replaced_duped,
            .isContext = is_context,
            .byteOffset = hit_byte_offset,
            .spans = spans_list.items,
        });
    }

    pub fn utf8ByteToUtf16Offset(text: []const u8, byte_idx: usize) usize {
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
