const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");
const prefilter = @import("../prefilter.zig");
const time_parser = @import("../time_parser.zig");
const limits = @import("limits.zig");
const types = @import("types.zig");
const sink_mod = @import("sink.zig");
const worker_mod = @import("worker.zig");

const WorkerContext = worker_mod.WorkerContext;
const FileSink = sink_mod.FileSink;
const FileTask = types.FileTask;
const EngineLimits = limits.EngineLimits;

fn searchMappedSlice(
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

pub fn searchArchiveTask(
    self: *WorkerContext,
    sink: *FileSink,
    task: *FileTask,
    archive_fmt: libwebgrep.ArchiveFormat,
    maybe_mapped_slice: ?[]const u8,
    parent_dir: std.Io.Dir,
    opened_fallback_file: *?std.Io.File,
    cfg: libwebgrep.SearchConfig,
) void {
    if ((self.runner.time_start_ns > 0 or self.runner.time_end_ns > 0) and task.task_time_mode == .mtime) {
        if (task.mtime_ns > 0) {
            const mtime_u64: u64 = @intCast(@max(0, task.mtime_ns));
            if ((self.runner.time_start_ns > 0 and mtime_u64 < self.runner.time_start_ns) or
                (self.runner.time_end_ns > 0 and mtime_u64 > self.runner.time_end_ns))
            {
                if (!task.counted_file_searched) {
                    task.counted_file_searched = true;
                    _ = self.runner.files_searched.fetchAdd(1, .monotonic);
                }
                return;
            }
        }
    }

    var archive_search_cfg = cfg;
    archive_search_cfg.compression = .none;
    const has_time_filter = (self.runner.time_start_ns > 0 or self.runner.time_end_ns > 0);
    if (has_time_filter and task.task_time_mode != .mtime) {
        sink.check_line_timestamps = true;
        sink.file_has_timestamps = (task.task_time_mode == .content);
    }

    const tree_cfg = libwebgrep.TreeConfig{
        .search = archive_search_cfg,
        .archive = EngineLimits.archiveOptions(archive_fmt),
        .globs = self.runner.archiveEntryGlobs(task.rel_path, task.base_name),
        .iglob = true,
        .types = self.runner.types_include,
        .types_not = self.runner.types_exclude,
        .custom_types = self.runner.custom_types_table,
        .respect_gitignore = self.runner.req.respectIgnore,
        .respect_ignore = self.runner.req.respectIgnore,
        .respect_rgignore = self.runner.req.respectIgnore,
        .hidden = self.runner.req.hidden,
        .max_entries = EngineLimits.max_archive_entries,
        .max_filesize = EngineLimits.max_archive_entry_bytes,
        .max_glob_rules = EngineLimits.max_glob_rules,
        .max_glob_rule_len = EngineLimits.max_glob_rule_len,
        .max_glob_brace_depth = EngineLimits.max_glob_brace_depth,
    };

    const maybe_summary: ?libwebgrep.Summary = if (maybe_mapped_slice) |slice| blk_slice: {
        break :blk_slice (switch (self.runner.matcher.*) {
            .literal => |*f| libwebgrep.searchArchiveSlice(FileSink, self.runner.gpa, self.runner.io, sink, slice, f, tree_cfg),
            .multi => |*m| libwebgrep.searchArchiveSlice(FileSink, self.runner.gpa, self.runner.io, sink, slice, m, tree_cfg),
            .regex => |*r| libwebgrep.searchArchiveSlice(FileSink, self.runner.gpa, self.runner.io, sink, slice, r, tree_cfg),
        } catch null);
    } else blk_stream: {
        var file = if (opened_fallback_file.*) |f| f else parent_dir.openFile(self.runner.io, task.open_sub_path, .{ .allow_directory = false }) catch {
            self.runner.had_scan_error.store(true, .release);
            return;
        };
        if (opened_fallback_file.* == null) {
            opened_fallback_file.* = file;
        }
        var archive_buf: [65536]u8 = undefined;
        var file_reader = file.reader(self.runner.io, &archive_buf);
        break :blk_stream (switch (self.runner.matcher.*) {
            .literal => |*f| libwebgrep.searchArchive(FileSink, self.runner.gpa, self.runner.io, sink, &file_reader.interface, f, tree_cfg),
            .multi => |*m| libwebgrep.searchArchive(FileSink, self.runner.gpa, self.runner.io, sink, &file_reader.interface, m, tree_cfg),
            .regex => |*r| libwebgrep.searchArchive(FileSink, self.runner.gpa, self.runner.io, sink, &file_reader.interface, r, tree_cfg),
        } catch null);
    };

    if (!task.counted_file_searched) {
        task.counted_file_searched = true;
        _ = self.runner.files_searched.fetchAdd(1, .monotonic);
    }
    if (!task.counted_file_matched and (sink.file_had_match or task.emitted_in_file > 0)) {
        task.counted_file_matched = true;
        _ = self.runner.files_matched.fetchAdd(1, .monotonic);
    }

    if (maybe_summary) |summary| {
        const bytes = if (summary.bytes_searched > 0) summary.bytes_searched else task.file_size;
        if (bytes > task.phase_bytes) {
            _ = self.runner.bytes_searched.fetchAdd(bytes - task.phase_bytes, .monotonic);
            task.phase_bytes = bytes;
        }
        if (bytes > task.prev_scanned_bytes) {
            _ = self.runner.bytes_scanned.fetchAdd(bytes - task.prev_scanned_bytes, .monotonic);
            task.prev_scanned_bytes = bytes;
        }
        if (summary.sources_failed > 0 and !self.runner.shouldStop()) {
            self.runner.had_scan_error.store(true, .release);
        } else if (!self.runner.shouldStop() and
            !sink.file_had_match and
            task.emitted_in_file == 0 and
            self.runner.isArchiveUnrestricted())
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
                        sink.case_insensitive,
                    );
                }
            }
        }
    } else if (!self.runner.shouldStop()) {
        self.runner.had_scan_error.store(true, .release);
    }

    if (!self.runner.shouldStop()) {
        self.maybeFlushStreaming(true);
        self.runner.maybeSendProgress(0);
    }
}
