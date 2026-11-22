const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");
const search_cache = @import("../search_cache.zig");
const source_registry = @import("../source_registry.zig");
const time_parser = @import("../time_parser.zig");
const limits = @import("limits.zig");
const types = @import("types.zig");
const runner_mod = @import("runner.zig");

const JobRunner = runner_mod.JobRunner;
const DirEntryItem = types.DirEntryItem;
const SourcePipelineConfig = types.SourcePipelineConfig;
const EngineLimits = limits.EngineLimits;
const detectArchiveFormat = limits.detectArchiveFormat;

pub fn hasGlobMetachar(s: []const u8) bool {
    for (s) |c| {
        if (c == '*' or c == '?' or c == '[' or c == '{') return true;
    }
    return false;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn activeFileGlobs(self: *const JobRunner) []const []const u8 {
    return if (self.expanded_file_globs.len > 0) self.expanded_file_globs else self.req.fileGlobs;
}

/// Applies `req.fileGlobs` (`@*.rs`, `@src/`, `-@*_test.go`) to a candidate file.
/// Positive patterns are OR-ed (at least one must match when any exist); `!` negatives always exclude.
pub fn fileMatchesPathGlobs(self: *const JobRunner, rel_path: []const u8, base_name: []const u8) bool {
    const globs = activeFileGlobs(self);
    if (globs.len == 0) return true;
    var has_positive = false;
    var positive_hit = false;
    for (globs) |raw| {
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

pub fn archiveContainerAllowedByPathGlobs(self: *const JobRunner, rel_path: []const u8, base_name: []const u8) bool {
    const globs = activeFileGlobs(self);
    if (globs.len == 0) return true;
    for (globs) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len > 1 and trimmed[0] == '!') {
            const body = trimmed[1..];
            if (matchesPathPattern(rel_path, base_name, body)) return false;
        }
    }
    return true;
}

pub fn archiveEntryMatchesPathGlobs(
    self: *const JobRunner,
    archive_rel_path: []const u8,
    archive_base_name: []const u8,
    entry_path: []const u8,
) bool {
    const globs = activeFileGlobs(self);
    if (globs.len == 0) return true;
    const entry_base = std.fs.path.basename(entry_path);
    var has_positive = false;
    var positive_hit = false;
    for (globs) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        const is_neg = trimmed.len > 0 and trimmed[0] == '!';
        const body = if (is_neg) trimmed[1..] else trimmed;
        if (body.len == 0) continue;
        const hit = matchesPathPattern(archive_rel_path, archive_base_name, body) or
            matchesPathPattern(entry_path, entry_base, body);
        if (is_neg) {
            if (hit) return false;
        } else {
            has_positive = true;
            if (hit) positive_hit = true;
        }
    }
    return !has_positive or positive_hit;
}

pub fn archiveEntryGlobs(
    self: *const JobRunner,
    archive_rel_path: []const u8,
    archive_base_name: []const u8,
) []const []const u8 {
    const globs = activeFileGlobs(self);
    if (globs.len == 0) return &.{};
    for (globs) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        const is_neg = trimmed[0] == '!';
        const body = if (is_neg) trimmed[1..] else trimmed;
        if (!is_neg and matchesPathPattern(archive_rel_path, archive_base_name, body)) {
            return &.{};
        }
        if (!hasGlobMetachar(body) or std.mem.indexOfScalar(u8, body, '/') != null) {
            return &.{};
        }
    }
    return globs;
}

/// Matches one `@` file/path pattern (case-insensitive):
/// - no glob metacharacters (`@src/`)  → substring of the relative path;
/// - no `/` (`@*.rs`, `@*_test.go`)    → glob against the file name;
/// - with `/` (`@src/*.rs`)            → glob against the relative path at any depth, since users write
///   paths relative to the project rather than to the index root.
pub fn matchesPathPattern(rel_path: []const u8, base_name: []const u8, pattern: []const u8) bool {
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
pub fn matchesOrderedPathSegments(haystack: []const u8, expr: []const u8) bool {
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

pub fn sourceMatchesProjectFilters(
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

pub fn fileMatchesSourceFilters(
    self: *const JobRunner,
    src_id: []const u8,
    src_name: []const u8,
    base_name: []const u8,
) bool {
    const is_archive = (detectArchiveFormat(base_name) != null);
    if (!is_archive and (self.types_include.len > 0 or self.types_exclude.len > 0)) {
        if (!libwebgrep.walk_types.matchesWithTable(
            self.custom_types_table,
            self.types_include,
            self.types_exclude,
            base_name,
        )) return false;
    }
    return self.sourceMatchesProjectFilters(src_id, src_name);
}

pub fn readDirFileBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    max_bytes: usize,
) ?[]u8 {
    var f = dir.openFile(io, sub_path, .{ .allow_directory = false }) catch return null;
    defer f.close(io);
    var rbuf: [4096]u8 = undefined;
    var f_reader = f.reader(io, &rbuf);
    return f_reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch null;
}

pub fn loadDirIgnoreSet(
    self: *JobRunner,
    dir: std.Io.Dir,
    rel_dir: []const u8,
    parent_ignore: ?*const libwebgrep.walk_ignore.Set,
) ?*const libwebgrep.walk_ignore.Set {
    if (!self.req.respectIgnore) return null;
    const max_ig_bytes: usize = 1024 * 1024;
    const git_exclude_bytes: ?[]u8 = if (rel_dir.len == 0)
        readDirFileBounded(self.gpa, self.io, dir, ".git/info/exclude", max_ig_bytes)
    else
        null;
    defer if (git_exclude_bytes) |b| self.gpa.free(b);

    const gitignore_bytes = readDirFileBounded(self.gpa, self.io, dir, ".gitignore", max_ig_bytes);
    defer if (gitignore_bytes) |b| self.gpa.free(b);

    const ignore_bytes = readDirFileBounded(self.gpa, self.io, dir, ".ignore", max_ig_bytes);
    defer if (ignore_bytes) |b| self.gpa.free(b);

    const rgignore_bytes = readDirFileBounded(self.gpa, self.io, dir, ".rgignore", max_ig_bytes);
    defer if (rgignore_bytes) |b| self.gpa.free(b);

    if (git_exclude_bytes == null and gitignore_bytes == null and ignore_bytes == null and rgignore_bytes == null) {
        return parent_ignore;
    }

    var ig_list: std.ArrayList(libwebgrep.walk_glob.Glob) = .empty;

    libwebgrep.walk_ignore.parseLayerInto(
        self.job_arena,
        .{
            .git_exclude = git_exclude_bytes,
            .gitignore = gitignore_bytes,
            .ignore = ignore_bytes,
            .rgignore = rgignore_bytes,
        },
        .{
            .vcs = true,
            .dot = true,
            .exclude = (rel_dir.len == 0),
            .max_rules = EngineLimits.max_glob_rules,
            .max_rule_len = EngineLimits.max_glob_rule_len,
            .max_brace_depth = EngineLimits.max_glob_brace_depth,
        },
        &ig_list,
    ) catch return parent_ignore;

    if (ig_list.items.len == 0) return parent_ignore;

    const set_ptr = self.job_arena.create(libwebgrep.walk_ignore.Set) catch return parent_ignore;
    set_ptr.* = libwebgrep.walk_ignore.build(
        self.job_arena,
        self.gpa,
        parent_ignore,
        rel_dir.len,
        &.{},
        ig_list.items,
    ) catch return parent_ignore;
    return set_ptr;
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
    if (self.shouldStop()) return;

    const dir_fid: ?libwebgrep.walk_file_id.Id = libwebgrep.walk_file_id.fromDir(dir) catch null;
    if (dir_fid) |fid| {
        if (fid.ino != 0) {
            const gop = try self.visited_dir_ids.getOrPut(self.job_arena, fid);
            if (gop.found_existing) return;
        }
    }

    const active_ignore = loadDirIgnoreSet(self, dir, rel_dir, parent_ignore);
    var ignore_scratch: [4096]u8 = undefined;

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
                        .is_symlink = false,
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
                var is_symlink = false;
                if (item.kind == .sym_link or item.kind == .unknown) {
                    has_symlink = true;
                    is_symlink = (item.kind == .sym_link);
                    const st = dir.statFile(self.io, item.name, .{}) catch continue;
                    is_dir = st.kind == .directory;
                    is_file = st.kind == .file;
                }
                if (!is_dir and !is_file) continue;

                const name_copy = try dir_arena.dupe(u8, item.name);
                try entries.append(dir_arena, .{
                    .name = name_copy,
                    .is_dir = is_dir,
                    .is_symlink = is_symlink,
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

        if (active_ignore) |ig_set| {
            if (libwebgrep.walk_ignore.isIgnored(ig_set, child_rel, entry.is_dir, &ignore_scratch)) {
                continue;
            }
        }

        if (entry.is_dir) {
            var sub_dir = dir.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close(self.io);

            try walkDirectoryForSource(self, 
                sub_dir,
                parent_root_override,
                src_id,
                src_name,
                effective_contains,
                effective_excludes,
                child_rel,
                active_ignore,
                line_tp,
                src_pipe,
            );
        } else {
            const virtual_rel = if (src_name.len > 0)
                try std.fmt.allocPrint(dir_arena, "{s}/{s}", .{ src_name, child_rel })
            else
                child_rel;

            if (!fileMatchesSourceFilters(self, src_id, src_name, entry.name)) continue;

            const st = dir.statFile(self.io, entry.name, .{}) catch continue;

            const file_fid: ?libwebgrep.walk_file_id.Id = if (entry.is_symlink) blk_sym: {
                var sym_f = dir.openFile(self.io, entry.name, .{ .allow_directory = false }) catch break :blk_sym null;
                defer sym_f.close(self.io);
                break :blk_sym libwebgrep.walk_file_id.fromFile(self.io, sym_f) catch null;
            } else if (st.inode != 0)
                libwebgrep.walk_file_id.Id{
                    .dev = if (dir_fid) |df| df.dev else 0,
                    .ino = @intCast(st.inode),
                }
            else
                null;

            if (file_fid) |ffid| {
                if (ffid.ino != 0) {
                    const fgop = try self.visited_file_ids.getOrPut(self.job_arena, ffid);
                    if (fgop.found_existing) continue;
                }
            }

            const file_dev: u64 = if (file_fid) |ffid| ffid.dev else if (dir_fid) |df| df.dev else 0;
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
                file_dev,
                line_tp,
                src_pipe,
            );
        }
    }
}
