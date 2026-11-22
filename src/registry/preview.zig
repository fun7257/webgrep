const std = @import("std");
const file_api = @import("../file_api.zig");
const store_mod = @import("store.zig");

const SourceRegistry = store_mod.SourceRegistry;

/// Resolves `<source_name>/<rel_path>` (including `<archive>::<entry>` virtual paths and sandboxed
/// source-prefixed paths) and returns a JSON line preview for InspectorPane.
pub fn buildLinePreviewJson(
    self: *SourceRegistry,
    arena: std.mem.Allocator,
    io: std.Io,
    virtual_path_raw: []const u8,
    target_line_raw: u64,
    context_raw: u64,
) ![]u8 {
    return buildLinePreviewWindowJson(
        self,
        arena,
        io,
        virtual_path_raw,
        .{ .line = target_line_raw, .context = context_raw },
    );
}

pub fn buildLinePreviewWindowJson(
    self: *SourceRegistry,
    arena: std.mem.Allocator,
    io: std.Io,
    virtual_path_raw: []const u8,
    query: file_api.FileWindowQuery,
) ![]u8 {
    var trimmed = std.mem.trim(u8, virtual_path_raw, " \t\r\n");
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len == 0) return error.InvalidPath;

    var host_raw: []const u8 = trimmed;
    var clean_entry: ?[]const u8 = null;
    if (std.mem.indexOf(u8, trimmed, file_api.ARCHIVE_VIRTUAL_SEP) != null) {
        const vp = file_api.splitArchiveVirtualPath(trimmed) orelse return error.InvalidPath;
        host_raw = vp.archive_path;
        clean_entry = try file_api.sanitizeArchiveEntryPath(vp.entry_path);
    }

    var matched_path: ?[]const u8 = null;
    var matched_kind: []const u8 = "dir";
    var inner_host_rel: []const u8 = "";
    var display_vpath: []const u8 = trimmed;

    if (host_raw.len > 0 and host_raw[0] == '/') {
        // Absolute path form: must strictly reside inside a registered source sandbox
        const abs_body = try file_api.sanitizeRelPath(host_raw[1..]);
        if (abs_body.len == 0) return error.InvalidPath;

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var best_len: usize = 0;
        for (self.sources.items) |s| {
            const s_trimmed = std.mem.trimEnd(u8, s.path, "/");
            if (s_trimmed.len == 0) continue;
            if (std.mem.eql(u8, s.kind, "file")) {
                if (std.mem.eql(u8, host_raw, s_trimmed) and s_trimmed.len > best_len) {
                    best_len = s_trimmed.len;
                    matched_path = try arena.dupe(u8, s.path);
                    matched_kind = try arena.dupe(u8, s.kind);
                    inner_host_rel = std.fs.path.basename(s_trimmed);
                }
            } else {
                if (std.mem.startsWith(u8, host_raw, s_trimmed) and
                    host_raw.len > s_trimmed.len and
                    host_raw[s_trimmed.len] == '/' and
                    s_trimmed.len > best_len)
                {
                    const rel_part = try file_api.sanitizeRelPath(host_raw[s_trimmed.len + 1 ..]);
                    if (rel_part.len > 0) {
                        best_len = s_trimmed.len;
                        matched_path = try arena.dupe(u8, s.path);
                        matched_kind = try arena.dupe(u8, s.kind);
                        inner_host_rel = rel_part;
                    }
                }
            }
        }
        if (matched_path == null) return error.InvalidPath;
    } else {
        const clean_host = try file_api.sanitizeRelPath(host_raw);
        if (clean_host.len == 0) return error.InvalidPath;
        display_vpath = if (clean_entry) |entry|
            try file_api.formatArchiveVirtualPathAlloc(arena, clean_host, entry)
        else
            clean_host;

        if (std.mem.indexOfScalar(u8, clean_host, '/')) |slash_idx| {
            const source_name = clean_host[0..slash_idx];
            const candidate_rel = clean_host[slash_idx + 1 ..];
            if (source_name.len == 0 or candidate_rel.len == 0) return error.InvalidPath;

            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            for (self.sources.items) |s| {
                if (std.ascii.eqlIgnoreCase(s.name, source_name) or std.ascii.eqlIgnoreCase(s.id, source_name)) {
                    matched_path = try arena.dupe(u8, s.path);
                    matched_kind = try arena.dupe(u8, s.kind);
                    inner_host_rel = candidate_rel;
                    break;
                }
            }
        }

        // Fallback for source-less relative paths (e.g. `web-grep-v0.1.7.tar.gz::README.md`)
        if (matched_path == null) {
            var dir_candidates: std.ArrayList([]const u8) = .empty;
            {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                for (self.sources.items) |s| {
                    const base = std.fs.path.basename(s.path);
                    if (std.mem.eql(u8, s.kind, "file") and
                        (std.ascii.eqlIgnoreCase(s.name, clean_host) or
                            std.ascii.eqlIgnoreCase(s.id, clean_host) or
                            std.ascii.eqlIgnoreCase(base, clean_host)))
                    {
                        matched_path = try arena.dupe(u8, s.path);
                        matched_kind = try arena.dupe(u8, s.kind);
                        inner_host_rel = base;
                        break;
                    }
                    if (!std.mem.eql(u8, s.kind, "file")) {
                        try dir_candidates.append(arena, try arena.dupe(u8, s.path));
                    }
                }
            }
            if (matched_path == null) {
                for (dir_candidates.items) |dpath| {
                    if (std.Io.Dir.cwd().openDir(io, dpath, .{})) |dir_val| {
                        var d = dir_val;
                        defer d.close(io);
                        if (d.statFile(io, clean_host, .{})) |st| {
                            if (st.kind != .directory) {
                                matched_path = dpath;
                                matched_kind = "dir";
                                inner_host_rel = clean_host;
                                break;
                            }
                        } else |_| {}
                    } else |_| {}
                }
            }
        }
    }

    // Boost access heat whenever a user inspects a record from this file
    self.recordFileHeat(io, display_vpath, 150);

    const src_path = matched_path orelse return error.FileNotFound;
    if (!std.mem.eql(u8, matched_kind, "file")) {
        const rel_target = if (clean_entry) |entry|
            try file_api.formatArchiveVirtualPathAlloc(arena, inner_host_rel, entry)
        else
            inner_host_rel;

        if (std.Io.Dir.cwd().openDir(io, src_path, .{})) |source_dir_val| {
            var source_dir = source_dir_val;
            defer source_dir.close(io);
            return file_api.buildFileWindowJsonWithDisplayPath(
                arena,
                io,
                source_dir,
                rel_target,
                display_vpath,
                query,
            );
        } else |_| {}
    }

    // Single-file source: open its parent directory and read `basename(src_path)` (or `basename::entry`)
    const parent_path = std.fs.path.dirname(src_path) orelse ".";
    const file_base = std.fs.path.basename(src_path);
    if (file_base.len == 0) return error.FileNotFound;

    const file_target = if (clean_entry) |entry|
        try file_api.formatArchiveVirtualPathAlloc(arena, file_base, entry)
    else
        file_base;

    var parent_dir = try std.Io.Dir.cwd().openDir(io, parent_path, .{});
    defer parent_dir.close(io);

    return file_api.buildFileWindowJsonWithDisplayPath(
        arena,
        io,
        parent_dir,
        file_target,
        display_vpath,
        query,
    );
}
