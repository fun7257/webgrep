const std = @import("std");
const libwebgrep = @import("libwebgrep");
const prefilter = @import("prefilter.zig");

pub const PathError = error{
    InvalidPath,
};

pub const ARCHIVE_VIRTUAL_SEP = "::";

pub const ArchiveVirtualPath = struct {
    archive_path: []const u8,
    entry_path: []const u8,
};

pub const default_archive_options = libwebgrep.ArchiveOptions{
    .format = .auto,
    .max_entries = 100_000,
    .max_entry_bytes = 64 * 1024 * 1024,
    .max_total_bytes = 256 * 1024 * 1024,
    .max_compression_ratio = 1000,
};

pub const builtin_types = [_][]const u8{
    "log",     "json",    "jsonl",  "zig",    "ts",     "tsx",  "js",   "jsx",
    "svelte",  "vue",     "py",     "go",     "rust",   "c",    "cpp",  "cs",
    "java",    "kt",      "swift",  "rb",     "php",    "sql",  "sh",   "yaml",
    "toml",    "xml",     "html",   "css",    "scss",   "md",   "txt",  "csv",
    "env",     "conf",    "docker", "proto",  "graphql","lua",
};

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

/// Detects multi-file archive formats by file extension (compound extensions checked first, case-insensitive).
pub fn detectArchiveFormat(path: []const u8) ?libwebgrep.ArchiveFormat {
    if (endsWithIgnoreCase(path, ".tar.gz") or endsWithIgnoreCase(path, ".tgz")) return .tar_gz;
    if (endsWithIgnoreCase(path, ".tar.zst") or endsWithIgnoreCase(path, ".tzst")) return .tar_zst;
    if (endsWithIgnoreCase(path, ".tar.xz") or endsWithIgnoreCase(path, ".txz")) return .tar_xz;
    if (endsWithIgnoreCase(path, ".tar")) return .tar;
    if (endsWithIgnoreCase(path, ".zip")) return .zip;
    return null;
}

pub fn isArchivePath(path: []const u8) bool {
    return detectArchiveFormat(path) != null;
}

/// Detects single-stream compression formats (.gz, .zst, .xz).
/// Always returns `null` for multi-file archives (.tar.gz, .tgz, .tar.zst, .tzst, .tar.xz, .txz, .tar, .zip).
pub fn detectCompression(path: []const u8) ?libwebgrep.Compression {
    if (detectArchiveFormat(path) != null) return null;
    if (endsWithIgnoreCase(path, ".gz")) return .gzip;
    if (endsWithIgnoreCase(path, ".zst")) return .zstd;
    if (endsWithIgnoreCase(path, ".xz")) return .xz;
    return null;
}

/// Splits a virtual archive path of the form `<archive_path>::<entry_path>`.
/// Returns `null` if `::` is absent, repeated, or either side is empty.
pub fn splitArchiveVirtualPath(rel_path: []const u8) ?ArchiveVirtualPath {
    const sep_idx = std.mem.indexOf(u8, rel_path, ARCHIVE_VIRTUAL_SEP) orelse return null;
    const archive_part = rel_path[0..sep_idx];
    const entry_part = rel_path[sep_idx + ARCHIVE_VIRTUAL_SEP.len ..];
    if (archive_part.len == 0 or entry_part.len == 0) return null;
    if (std.mem.indexOf(u8, entry_part, ARCHIVE_VIRTUAL_SEP) != null) return null;
    return .{
        .archive_path = archive_part,
        .entry_path = entry_part,
    };
}

fn sanitizePlainRelPath(raw: []const u8) PathError![]const u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, trimmed, ".")) return "";
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len == 0) return "";
    if (trimmed[0] == '/') return error.InvalidPath;

    for (trimmed) |c| {
        if (c == 0 or c == '\\') return error.InvalidPath;
    }

    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
            return error.InvalidPath;
        }
    }
    return trimmed;
}

/// Sanitizes and normalizes an archive-internal entry path using `libwebgrep.archive.sanitizeArchivePath`
/// and strict relative-segment checks. Strips leading `/` or `./` and rejects `..`, `\`, NUL, and drive letters.
pub fn sanitizeArchiveEntryPath(raw_entry: []const u8) PathError![]const u8 {
    const trimmed = std.mem.trim(u8, raw_entry, " \t\r\n");
    const maybe_clean = libwebgrep.archive.sanitizeArchivePath(trimmed) catch return error.InvalidPath;
    const clean = maybe_clean orelse return error.InvalidPath;
    const verified = try sanitizePlainRelPath(clean);
    if (verified.len == 0) return error.InvalidPath;
    return verified;
}

/// Formats `<archive_path>::<clean_entry_path>` after validating the archive entry path.
pub fn formatArchiveVirtualPathAlloc(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    entry_path: []const u8,
) ![]u8 {
    const clean_entry = try sanitizeArchiveEntryPath(entry_path);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ archive_path, ARCHIVE_VIRTUAL_SEP, clean_entry });
}

/// Strictly sanitizes a relative path (including `<archive>::<entry>` virtual paths) from client input.
/// Rejects leading '/', '\', NUL bytes, and any '..' or empty internal segments.
/// Normalizes "." to "".
pub fn sanitizeRelPath(raw: []const u8) PathError![]const u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, trimmed, ".")) return "";
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len == 0) return "";

    if (std.mem.indexOf(u8, trimmed, ARCHIVE_VIRTUAL_SEP) != null) {
        const vp = splitArchiveVirtualPath(trimmed) orelse return error.InvalidPath;
        const clean_arch = try sanitizePlainRelPath(vp.archive_path);
        if (clean_arch.len == 0 or clean_arch.len != vp.archive_path.len) return error.InvalidPath;
        const clean_entry = try sanitizeArchiveEntryPath(vp.entry_path);
        if (clean_entry.len == 0 or clean_entry.len != vp.entry_path.len) return error.InvalidPath;
        return trimmed;
    }

    return sanitizePlainRelPath(trimmed);
}

/// Decodes percent-encoded URI query component (`%XX` and `+` -> ` `).
pub fn decodeQueryParam(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '+') {
            out.appendAssumeCapacity(' ');
        } else if (c == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                out.appendAssumeCapacity(c);
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                out.appendAssumeCapacity(c);
                continue;
            };
            out.appendAssumeCapacity((hi << 4) | lo);
            i += 2;
        } else {
            out.appendAssumeCapacity(c);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn getQueryParamAlloc(allocator: std.mem.Allocator, query: []const u8, key: []const u8) !?[]u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            if (std.mem.eql(u8, pair, key)) return try allocator.dupe(u8, "");
            continue;
        };
        const k = pair[0..eq];
        const v = pair[eq + 1 ..];
        if (std.mem.eql(u8, k, key)) {
            return try decodeQueryParam(allocator, v);
        }
    }
    return null;
}

pub fn isAlwaysSkippedDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "target") or
        std.mem.eql(u8, name, "dist") or
        std.mem.eql(u8, name, "dist-ssr") or
        std.mem.eql(u8, name, ".next") or
        std.mem.eql(u8, name, ".svelte-kit") or
        std.mem.eql(u8, name, ".venv") or
        std.mem.eql(u8, name, "venv") or
        std.mem.eql(u8, name, "__pycache__") or
        std.mem.eql(u8, name, ".idea") or
        std.mem.eql(u8, name, ".DS_Store");
}

/// Truncates a slice at a safe UTF-8 boundary and replaces any invalid UTF-8 sequences with U+FFFD.
pub fn sanitizeUtf8Truncated(arena: std.mem.Allocator, input: []const u8, max_bytes: usize) ![]const u8 {
    var slice = input;
    if (slice.len > max_bytes) {
        var end = max_bytes;
        while (end > 0 and (slice[end] & 0b1100_0000) == 0b1000_0000) {
            end -= 1;
        }
        if (end > 0) {
            const seq_len = std.unicode.utf8ByteSequenceLength(slice[end]) catch 1;
            if (end + seq_len > max_bytes) {
                // Incomplete multibyte sequence at the boundary; exclude the lead byte.
            } else {
                end = max_bytes;
            }
        }
        slice = slice[0..end];
    }
    if (std.unicode.utf8ValidateSlice(slice)) return slice;

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, slice.len + 16);
    var i: usize = 0;
    while (i < slice.len) {
        const len = std.unicode.utf8ByteSequenceLength(slice[i]) catch {
            try out.appendSlice(arena, "\xEF\xBF\xBD");
            i += 1;
            continue;
        };
        if (i + len > slice.len) {
            try out.appendSlice(arena, "\xEF\xBF\xBD");
            break;
        }
        if (std.unicode.utf8Decode(slice[i .. i + len])) |_| {
            try out.appendSlice(arena, slice[i .. i + len]);
            i += len;
        } else |_| {
            try out.appendSlice(arena, "\xEF\xBF\xBD");
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

pub const PluginMetaDto = struct {
    id: []const u8,
    nameKey: []const u8,
    description: []const u8,
    stages: []const []const u8,
    defaultPresets: []const []const u8,
    costHint: []const u8,
};

pub const PresetMetaDto = struct {
    id: []const u8,
    nameKey: []const u8,
    description: []const u8,
    defaultPlugins: []const []const u8,
};

fn comptimeStageStrs(comptime stages: []const prefilter.Stage) []const []const u8 {
    comptime {
        var arr: [stages.len][]const u8 = undefined;
        for (stages, 0..) |st, i| arr[i] = st.asStr();
        const frozen = arr;
        return &frozen;
    }
}

fn comptimePresetStrs(comptime presets: []const prefilter.Preset) []const []const u8 {
    comptime {
        var arr: [presets.len][]const u8 = undefined;
        for (presets, 0..) |p, i| arr[i] = p.asStr();
        const frozen = arr;
        return &frozen;
    }
}

fn comptimePluginIdStrs(comptime pids: []const prefilter.PluginId) []const []const u8 {
    comptime {
        var arr: [pids.len][]const u8 = undefined;
        for (pids, 0..) |pid, i| arr[i] = pid.asStr();
        const frozen = arr;
        return &frozen;
    }
}

pub const builtin_plugins: [prefilter.PLUGIN_CATALOG.len]PluginMetaDto = blk: {
    var out: [prefilter.PLUGIN_CATALOG.len]PluginMetaDto = undefined;
    for (prefilter.PLUGIN_CATALOG, 0..) |entry, i| {
        out[i] = .{
            .id = entry.id_str,
            .nameKey = entry.name_key,
            .description = entry.description,
            .stages = comptimeStageStrs(entry.stages),
            .defaultPresets = comptimePresetStrs(entry.default_presets),
            .costHint = entry.cost_hint,
        };
    }
    break :blk out;
};

pub const builtin_presets: [prefilter.PRESET_CATALOG.len]PresetMetaDto = blk: {
    var out: [prefilter.PRESET_CATALOG.len]PresetMetaDto = undefined;
    for (prefilter.PRESET_CATALOG, 0..) |entry, i| {
        out[i] = .{
            .id = entry.id_str,
            .nameKey = entry.name_key,
            .description = entry.description,
            .defaultPlugins = comptimePluginIdStrs(entry.default_plugins),
        };
    }
    break :blk out;
};

pub const MetaResponse = struct {
    rootLabel: []const u8,
    root: []const u8,
    engine: []const u8 = "libwebgrep 0.5.0 · SIMD",
    types: []const []const u8 = &builtin_types,
    scopes: []const []const u8 = &.{},
    plugins: []const PluginMetaDto = &builtin_plugins,
    presets: []const PresetMetaDto = &builtin_presets,
};

pub fn buildMetaJson(arena: std.mem.Allocator, root_path: []const u8, root_label: []const u8) ![]u8 {
    const resp = MetaResponse{
        .rootLabel = root_label,
        .root = root_path,
    };
    return stringifyAlloc(arena, resp);
}

pub fn buildMetaWithScopesJson(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    root_path: []const u8,
    root_label: []const u8,
) ![]u8 {
    var scopes: std.ArrayList([]const u8) = .empty;
    const max_scopes: usize = 120;

    var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
    var lister = libwebgrep.walk_list.Lister.init(root_dir, &scratch);
    var batch: [128]std.Io.Dir.Entry = undefined;

    var top_dirs: std.ArrayList([]const u8) = .empty;
    var top_files: std.ArrayList([]const u8) = .empty;

    outer: while (true) {
        const count = lister.fill(io, &batch) catch break;
        if (count == 0) break;
        for (batch[0..count]) |item| {
            if (item.name.len == 0 or item.name[0] == '.') continue;
            if (isAlwaysSkippedDir(item.name)) continue;

            var is_dir = item.kind == .directory;
            var is_file = item.kind == .file;
            if (item.kind == .sym_link or item.kind == .unknown) {
                if (root_dir.statFile(io, item.name, .{})) |st| {
                    is_dir = st.kind == .directory;
                    is_file = st.kind == .file;
                } else |_| continue;
            }
            if (is_dir) {
                try top_dirs.append(arena, try arena.dupe(u8, item.name));
            } else if (is_file) {
                try top_files.append(arena, try arena.dupe(u8, item.name));
            }
            if (top_dirs.items.len + top_files.items.len >= max_scopes) break :outer;
        }
    }

    // Add top-level directories first (and scan 1 level inside each top-level dir)
    for (top_dirs.items) |dname| {
        if (scopes.items.len >= max_scopes) break;
        try scopes.append(arena, dname);

        if (root_dir.openDir(io, dname, .{ .iterate = true })) |sub_val| {
            var sub_dir = sub_val;
            defer sub_dir.close(io);
            var sub_scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
            var sub_lister = libwebgrep.walk_list.Lister.init(sub_dir, &sub_scratch);
            var sub_batch: [64]std.Io.Dir.Entry = undefined;
            while (scopes.items.len < max_scopes) {
                const sc = sub_lister.fill(io, &sub_batch) catch break;
                if (sc == 0) break;
                for (sub_batch[0..sc]) |sub_item| {
                    if (sub_item.name.len == 0 or sub_item.name[0] == '.') continue;
                    if (isAlwaysSkippedDir(sub_item.name)) continue;
                    if (scopes.items.len >= max_scopes) break;
                    const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dname, sub_item.name });
                    try scopes.append(arena, rel);
                }
            }
        } else |_| {}
    }

    for (top_files.items) |fname| {
        if (scopes.items.len >= max_scopes) break;
        try scopes.append(arena, fname);
    }

    const resp = MetaResponse{
        .rootLabel = root_label,
        .root = root_path,
        .scopes = scopes.items,
    };
    return stringifyAlloc(arena, resp);
}

pub const TreeEntry = struct {
    name: []const u8,
    path: []const u8,
    dir: bool,
    size: u64,

    pub fn lessThan(_: void, a: TreeEntry, b: TreeEntry) bool {
        if (a.dir != b.dir) return a.dir; // directories first
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

pub const TreeResponse = struct {
    path: []const u8,
    truncated: bool,
    entries: []const TreeEntry,
};

pub fn buildTreeJson(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    rel_path_raw: []const u8,
) ![]u8 {
    const clean_rel = try sanitizeRelPath(rel_path_raw);
    const sub_path = if (clean_rel.len == 0) "." else clean_rel;

    var dir = try root_dir.openDir(io, sub_path, .{ .iterate = true });
    defer dir.close(io);

    var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
    var lister = libwebgrep.walk_list.Lister.init(dir, &scratch);
    var batch: [128]std.Io.Dir.Entry = undefined;

    var entries: std.ArrayList(TreeEntry) = .empty;
    var truncated = false;
    const max_entries: usize = 1000;

    outer: while (true) {
        const count = try lister.fill(io, &batch);
        if (count == 0) break;
        for (batch[0..count]) |item| {
            if (item.name.len == 0) continue;
            if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
            if (isAlwaysSkippedDir(item.name)) continue;

            if (entries.items.len >= max_entries) {
                truncated = true;
                break :outer;
            }

            var is_dir = item.kind == .directory;
            var size: u64 = 0;

            if (item.kind == .file) {
                if (dir.statFile(io, item.name, .{})) |st| {
                    size = st.size;
                } else |_| {}
            } else if (item.kind == .sym_link or item.kind == .unknown) {
                if (dir.statFile(io, item.name, .{})) |st| {
                    is_dir = st.kind == .directory;
                    if (!is_dir) size = st.size;
                } else |_| {
                    continue;
                }
            }

            const name_duped = try arena.dupe(u8, item.name);
            const entry_path = if (clean_rel.len == 0)
                name_duped
            else
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ clean_rel, name_duped });

            try entries.append(arena, .{
                .name = name_duped,
                .path = entry_path,
                .dir = is_dir,
                .size = size,
            });
        }
    }

    std.mem.sort(TreeEntry, entries.items, {}, TreeEntry.lessThan);

    const resp = TreeResponse{
        .path = clean_rel,
        .truncated = truncated,
        .entries = entries.items,
    };
    return stringifyAlloc(arena, resp);
}

pub const FileLine = struct {
    n: u64,
    text: []const u8,
};

pub const FileResponse = struct {
    path: []const u8,
    startLine: u64,
    totalLines: u64,
    binary: bool,
    eof: bool,
    firstByte: ?u64 = null,
    nextByte: ?u64 = null,
    lines: []const FileLine,
};

pub const FileWindowQuery = struct {
    line: u64 = 1,
    context: u64 = 60,
    start_line: ?u64 = null,
    end_line: ?u64 = null,
    anchor_line: ?u64 = null,
    anchor_byte: ?u64 = null,

    pub const Bounds = struct {
        start_line: u64,
        end_line: u64,
        is_single_line: bool,
    };

    pub fn resolveBounds(self: FileWindowQuery) Bounds {
        if (self.start_line) |s_raw| {
            if (self.end_line) |e_raw| {
                const s = @max(s_raw, 1);
                const e = @max(s, @min(e_raw, s +| 600));
                return .{
                    .start_line = s,
                    .end_line = e,
                    .is_single_line = (s == e),
                };
            }
        }
        const line_c = @max(self.line, 1);
        const ctx_c = std.math.clamp(self.context, 0, 300);
        const s = if (line_c > ctx_c) line_c - ctx_c else 1;
        const e = line_c +| ctx_c;
        return .{
            .start_line = s,
            .end_line = e,
            .is_single_line = (ctx_c == 0),
        };
    }
};

pub fn hasCompressedExtension(path: []const u8) bool {
    return detectCompression(path) != null;
}

pub fn looksCompressedBytes(raw: []const u8) bool {
    if (raw.len >= 2 and raw[0] == 0x1f and raw[1] == 0x8b) return true; // gzip
    if (raw.len >= 4 and raw[0] == 0x28 and raw[1] == 0xb5 and raw[2] == 0x2f and raw[3] == 0xfd) return true; // zstd
    if (raw.len >= 6 and raw[0] == 0xfd and raw[1] == '7' and raw[2] == 'z' and raw[3] == 'X' and raw[4] == 'Z' and raw[5] == 0x00) return true; // xz
    return false;
}

fn lookupArchiveEntryNode(
    root: *const libwebgrep.source.Node,
    clean_entry: []const u8,
) ?*const libwebgrep.source.Node {
    if (libwebgrep.source.Memory.lookup(root, clean_entry)) |node| {
        if (node.kind == .file) return node;
    }
    if (root.kind == .directory and root.children.len == 1 and root.children[0].kind == .directory) {
        if (libwebgrep.source.Memory.lookup(root.children[0], clean_entry)) |node| {
            if (node.kind == .file) return node;
        }
    }
    return null;
}

/// Extracts a single file entry from an in-memory archive slice with zero temporary disk writes.
pub fn extractArchiveEntryFromSlice(
    arena: std.mem.Allocator,
    archive_bytes: []const u8,
    archive_path: []const u8,
    entry_path_raw: []const u8,
) ![]const u8 {
    const clean_entry = try sanitizeArchiveEntryPath(entry_path_raw);
    var opts = default_archive_options;
    if (detectArchiveFormat(archive_path)) |fmt| {
        opts.format = fmt;
    }
    var tree = libwebgrep.ArchiveTree.initFromSlice(arena, archive_bytes, opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileNotFound,
    };
    defer tree.deinit();

    if (lookupArchiveEntryNode(tree.rootNode(), clean_entry)) |node| {
        return try arena.dupe(u8, node.bytes);
    }
    return error.FileNotFound;
}

/// Extracts a single file entry from an archive inside `root_dir` using `ArchiveTree.initFromSlice`
/// (for archives <= 16 MiB) or streaming `ArchiveTree.initFromReader`, with zero temporary disk writes.
pub fn extractArchiveEntryFromDir(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    archive_rel_path: []const u8,
    entry_path_raw: []const u8,
) ![]const u8 {
    const clean_arch = try sanitizePlainRelPath(archive_rel_path);
    if (clean_arch.len == 0) return error.InvalidPath;
    const clean_entry = try sanitizeArchiveEntryPath(entry_path_raw);

    var file = try root_dir.openFile(io, clean_arch, .{ .allow_directory = false });
    defer file.close(io);

    const st = try file.stat(io);
    if (st.kind == .directory) return error.IsDir;

    var opts = default_archive_options;
    if (detectArchiveFormat(clean_arch)) |fmt| {
        opts.format = fmt;
    }

    const slice_threshold: u64 = 16 * 1024 * 1024;
    var tree: libwebgrep.ArchiveTree = undefined;
    if (st.size <= slice_threshold) {
        var read_buf: [8192]u8 = undefined;
        var file_reader = file.reader(io, &read_buf);
        const raw_bytes = file_reader.interface.allocRemaining(arena, .limited(@intCast(opts.max_total_bytes))) catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
            error.StreamTooLong => return error.FileNotFound,
            error.OutOfMemory => return error.OutOfMemory,
        };
        tree = libwebgrep.ArchiveTree.initFromSlice(arena, raw_bytes, opts) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileNotFound,
        };
    } else {
        var read_buf: [16384]u8 = undefined;
        var file_reader = file.reader(io, &read_buf);
        tree = libwebgrep.ArchiveTree.initFromReader(arena, &file_reader.interface, opts) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileNotFound,
        };
    }
    defer tree.deinit();

    if (lookupArchiveEntryNode(tree.rootNode(), clean_entry)) |node| {
        return try arena.dupe(u8, node.bytes);
    }
    return error.FileNotFound;
}

fn detectBomlessUtf16(sample: []const u8) ?libwebgrep.Encoding {
    if (sample.len < 4 or (sample.len & 1) != 0) return null;
    const pairs = sample.len / 2;
    var le_zero_hi: usize = 0;
    var be_zero_lo: usize = 0;
    for (0..pairs) |i| {
        const b0 = sample[i * 2];
        const b1 = sample[i * 2 + 1];
        if (b0 == 0 and b1 == 0) return null;
        if (b1 == 0) {
            if (b0 < 0x09 or (b0 > 0x0D and b0 < 0x20) or b0 == 0x7F) return null;
            le_zero_hi += 1;
        }
        if (b0 == 0) {
            if (b1 < 0x09 or (b1 > 0x0D and b1 < 0x20) or b1 == 0x7F) return null;
            be_zero_lo += 1;
        }
    }
    if (le_zero_hi * 10 >= pairs * 7 and be_zero_lo == 0) return .utf16le;
    if (be_zero_lo * 10 >= pairs * 7 and le_zero_hi == 0) return .utf16be;
    return null;
}

/// Uses `libwebgrep` native `Encoding` / BOM sniffing (`materialize`) to transcode UTF-8 BOM,
/// UTF-16LE/BE (with or without BOM), and GB18030/GBK text into valid UTF-8 before binary checks.
pub fn decodeTextSliceToUtf8(
    arena: std.mem.Allocator,
    input: []const u8,
    max_bytes: usize,
) ![]const u8 {
    if (input.len == 0) return input;

    const auto_prep = libwebgrep.searcher.pipeline_mod.materialize(input, .{
        .allocator = arena,
        .compression = .none,
        .encoding = .auto,
        .max_decode_bytes = max_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return input,
    };

    const current = auto_prep.bytes;
    if (auto_prep.transformed or current.ptr != input.ptr or current.len != input.len) {
        return current;
    }

    const sniff_len = @min(current.len, 8192);
    if (std.mem.indexOfScalar(u8, current[0..sniff_len], 0) != null) {
        const even_len = sniff_len & ~@as(usize, 1);
        if (detectBomlessUtf16(current[0..even_len])) |utf16_enc| {
            if (libwebgrep.searcher.pipeline_mod.materialize(current, .{
                .allocator = arena,
                .compression = .none,
                .encoding = utf16_enc,
                .max_decode_bytes = max_bytes,
            })) |u16_prep| {
                return u16_prep.bytes;
            } else |_| {}
        }
        return current;
    }

    if (!std.unicode.utf8ValidateSlice(current)) {
        if (libwebgrep.searcher.pipeline_mod.materialize(current, .{
            .allocator = arena,
            .compression = .none,
            .encoding = .gbk,
            .max_decode_bytes = max_bytes,
        })) |gbk_prep| {
            return gbk_prep.bytes;
        } else |_| {}
    }

    return current;
}

fn decodeSingleLineAlloc(arena: std.mem.Allocator, raw_line: []const u8) ![]const u8 {
    const trimmed = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
        raw_line[0 .. raw_line.len - 1]
    else
        raw_line;
    if (trimmed.len == 0) return "";
    if (trimmed.len <= 512 * 1024 and std.unicode.utf8ValidateSlice(trimmed)) {
        return try arena.dupe(u8, trimmed);
    }
    const decoded = if (trimmed.len <= 1024 * 1024)
        decodeTextSliceToUtf8(arena, trimmed, 2 * 1024 * 1024) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        trimmed;
    const safe = try sanitizeUtf8Truncated(arena, decoded, 512 * 1024);
    if (safe.len == 0) return "";
    const safe_start = @intFromPtr(safe.ptr);
    const raw_start = @intFromPtr(trimmed.ptr);
    if (safe_start >= raw_start and safe_start < raw_start + trimmed.len) {
        return try arena.dupe(u8, safe);
    }
    return safe;
}

const ScanStart = struct {
    line: u64,
    byte: u64,
};

fn validateLineAnchor(
    io: std.Io,
    file: std.Io.File,
    file_size: u64,
    content_base: u64,
    anchor_line_opt: ?u64,
    anchor_byte_opt: ?u64,
) !?u64 {
    const a_line = anchor_line_opt orelse return null;
    const a_byte = anchor_byte_opt orelse return null;
    if (a_line == 0 or a_byte >= file_size) return null;
    if (a_line == 1 and (a_byte == 0 or a_byte == content_base)) {
        return content_base;
    }
    if (a_byte <= content_base) return null;
    var prev_buf: [1]u8 = undefined;
    const n = try file.readPositionalAll(io, &prev_buf, a_byte - 1);
    if (n != 1 or prev_buf[0] != '\n') return null;
    return a_byte;
}

fn findBackwardScanStart(
    io: std.Io,
    file: std.Io.File,
    content_base: u64,
    start_line: u64,
    anchor_line: u64,
    anchor_byte: u64,
) !ScanStart {
    if (start_line >= anchor_line) return .{ .line = anchor_line, .byte = anchor_byte };
    const need_back: u64 = anchor_line - start_line;
    var end_pos: u64 = anchor_byte - 1;
    var found: u64 = 0;
    var chunk_buf: [64 * 1024]u8 = undefined;

    while (end_pos > content_base) {
        const chunk_len: usize = @intCast(@min(end_pos - content_base, chunk_buf.len));
        const chunk_start: u64 = end_pos - chunk_len;
        const n = try file.readPositionalAll(io, chunk_buf[0..chunk_len], chunk_start);
        if (n == 0) break;

        var sub_end: usize = n;
        while (sub_end > 0) {
            const nl_rel = std.mem.lastIndexOfScalar(u8, chunk_buf[0..sub_end], '\n') orelse break;
            found += 1;
            if (found == need_back) {
                return .{
                    .line = start_line,
                    .byte = chunk_start + nl_rel + 1,
                };
            }
            sub_end = nl_rel;
        }
        end_pos = chunk_start;
    }

    return .{
        .line = @max(anchor_line -| (found + 1), 1),
        .byte = content_base,
    };
}

fn countRemainingLinesFrom(
    io: std.Io,
    file: std.Io.File,
    start_offset: u64,
    file_size: u64,
) !u64 {
    if (start_offset >= file_size) return 0;
    var pos: u64 = start_offset;
    var newlines: u64 = 0;
    var last_byte: u8 = '\n';
    var buf: [64 * 1024]u8 = undefined;

    while (pos < file_size) {
        const want: usize = @intCast(@min(file_size - pos, buf.len));
        const n = try file.readPositionalAll(io, buf[0..want], pos);
        if (n == 0) break;
        newlines += std.mem.count(u8, buf[0..n], "\n");
        last_byte = buf[n - 1];
        pos += n;
    }
    if (last_byte != '\n') newlines += 1;
    return newlines;
}

/// Positional O(window) plain-file context reader (`pread` in 64 KiB chunks).
/// Returns `null` for compressed or UTF-16 streams so callers can decode via `renderDecodedSliceFileJson`.
pub fn buildPlainFileWindowJson(
    arena: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    file_size: u64,
    display_path: []const u8,
    query: FileWindowQuery,
) !?[]u8 {
    if (file_size == 0) {
        return try stringifyAlloc(arena, FileResponse{
            .path = display_path,
            .startLine = 1,
            .totalLines = 0,
            .binary = false,
            .eof = true,
            .firstByte = 0,
            .nextByte = 0,
            .lines = &.{},
        });
    }

    var head_buf: [8192]u8 = undefined;
    const sniff_len: usize = @intCast(@min(file_size, head_buf.len));
    const head_n = try file.readPositionalAll(io, head_buf[0..sniff_len], 0);
    const head = head_buf[0..head_n];

    if (looksCompressedBytes(head)) return null;
    if (std.mem.startsWith(u8, head, "\xFF\xFE") or std.mem.startsWith(u8, head, "\xFE\xFF")) return null;

    if (std.mem.indexOfScalar(u8, head, 0) != null) {
        const even_len = head.len & ~@as(usize, 1);
        if (detectBomlessUtf16(head[0..even_len]) != null) return null;
        return try stringifyAlloc(arena, FileResponse{
            .path = display_path,
            .startLine = 1,
            .totalLines = 0,
            .binary = true,
            .eof = true,
            .lines = &.{},
        });
    }

    const content_base: u64 = if (head.len >= 3 and std.mem.eql(u8, head[0..3], "\xEF\xBB\xBF")) 3 else 0;
    if (file_size <= content_base) {
        return try stringifyAlloc(arena, FileResponse{
            .path = display_path,
            .startLine = 1,
            .totalLines = 0,
            .binary = false,
            .eof = true,
            .firstByte = content_base,
            .nextByte = file_size,
            .lines = &.{},
        });
    }

    const bounds = query.resolveBounds();
    const scan_start: ScanStart = blk_start: {
        if (try validateLineAnchor(io, file, file_size, content_base, query.anchor_line, query.anchor_byte)) |eff_byte| {
            const a_line = query.anchor_line.?;
            if (bounds.start_line < a_line) {
                break :blk_start try findBackwardScanStart(io, file, content_base, bounds.start_line, a_line, eff_byte);
            }
            break :blk_start .{ .line = a_line, .byte = eff_byte };
        }
        break :blk_start .{ .line = 1, .byte = content_base };
    };

    const max_accum_line_bytes: usize = 1024 * 1024;
    var lines: std.ArrayList(FileLine) = .empty;
    var line_acc: std.ArrayList(u8) = .empty;
    var chunk_buf: [64 * 1024]u8 = undefined;

    var cur_line: u64 = scan_start.line;
    var file_pos: u64 = scan_start.byte;
    var in_line_start: u64 = scan_start.byte;
    var first_byte: ?u64 = null;
    var next_byte: u64 = file_size;
    var last_seen_line: u64 = scan_start.line -| 1;
    var reached_window_end = false;

    while (file_pos < file_size) {
        const want: usize = @intCast(@min(file_size - file_pos, chunk_buf.len));
        const n = try file.readPositionalAll(io, chunk_buf[0..want], file_pos);
        if (n == 0) break;

        var pos: usize = 0;
        while (pos < n) {
            if (std.mem.indexOfScalarPos(u8, chunk_buf[0..n], pos, '\n')) |nl| {
                last_seen_line = cur_line;
                if (cur_line < bounds.start_line) {
                    cur_line += 1;
                    pos = nl + 1;
                    in_line_start = file_pos + pos;
                } else if (cur_line <= bounds.end_line) {
                    const seg = chunk_buf[pos..nl];
                    const raw_line: []const u8 = if (line_acc.items.len > 0) blk_acc: {
                        const remain = max_accum_line_bytes -| line_acc.items.len;
                        if (remain > 0) {
                            try line_acc.appendSlice(arena, seg[0..@min(seg.len, remain)]);
                        }
                        break :blk_acc line_acc.items;
                    } else seg;

                    const safe_text = try decodeSingleLineAlloc(arena, raw_line);
                    if (first_byte == null) first_byte = in_line_start;
                    try lines.append(arena, .{
                        .n = cur_line,
                        .text = safe_text,
                    });
                    line_acc.clearRetainingCapacity();
                    next_byte = file_pos + nl + 1;

                    if (cur_line >= bounds.end_line) {
                        reached_window_end = true;
                        break;
                    }
                    cur_line += 1;
                    pos = nl + 1;
                    in_line_start = file_pos + pos;
                } else {
                    reached_window_end = true;
                    break;
                }
            } else {
                if (cur_line >= bounds.start_line and cur_line <= bounds.end_line) {
                    const tail = chunk_buf[pos..n];
                    const remain = max_accum_line_bytes -| line_acc.items.len;
                    if (remain > 0) {
                        try line_acc.appendSlice(arena, tail[0..@min(tail.len, remain)]);
                    }
                }
                pos = n;
            }
        }
        file_pos += n;
        if (reached_window_end) break;
    }

    if (!reached_window_end and in_line_start < file_size) {
        last_seen_line = cur_line;
        if (cur_line >= bounds.start_line and cur_line <= bounds.end_line) {
            const safe_text = try decodeSingleLineAlloc(arena, line_acc.items);
            if (first_byte == null) first_byte = in_line_start;
            try lines.append(arena, .{
                .n = cur_line,
                .text = safe_text,
            });
        }
        next_byte = file_size;
    }

    const is_eof = (next_byte >= file_size);
    const total_lines: u64 = if (is_eof)
        last_seen_line
    else if (!bounds.is_single_line and file_size <= 2 * 1024 * 1024)
        last_seen_line + try countRemainingLinesFrom(io, file, next_byte, file_size)
    else
        0;

    const effective_start: u64 = if (lines.items.len > 0) lines.items[0].n else 1;
    return try stringifyAlloc(arena, FileResponse{
        .path = display_path,
        .startLine = effective_start,
        .totalLines = total_lines,
        .binary = false,
        .eof = is_eof,
        .firstByte = first_byte orelse scan_start.byte,
        .nextByte = next_byte,
        .lines = lines.items,
    });
}

fn renderDecodedSliceFileJson(
    arena: std.mem.Allocator,
    display_path: []const u8,
    logical_filename: []const u8,
    raw_bytes: []const u8,
    allow_magic_decompress: bool,
    bounds: FileWindowQuery.Bounds,
) ![]u8 {
    const start_line: u64 = bounds.start_line;
    const end_line: u64 = bounds.end_line;
    const max_file_bytes: usize = 128 * 1024 * 1024;

    var content: []const u8 = raw_bytes;
    const comp_mode: ?libwebgrep.Compression = detectCompression(logical_filename) orelse
        if (allow_magic_decompress and detectArchiveFormat(logical_filename) == null and looksCompressedBytes(raw_bytes))
            .auto
        else
            null;

    if (comp_mode) |mode| {
        var dec_out: u64 = 0;
        var offset_map = libwebgrep.decompress.OffsetMap{};
        defer offset_map.deinit(arena);
        if (libwebgrep.decompress.decompressSlice(
            arena,
            raw_bytes,
            mode,
            0,
            max_file_bytes,
            1000,
            &dec_out,
            &offset_map,
        )) |maybe_dec| {
            if (maybe_dec) |dec_slice| {
                content = dec_slice;
            }
        } else |_| {}
    }

    content = try decodeTextSliceToUtf8(arena, content, max_file_bytes);

    // Check first 8 KiB for NUL byte -> binary detection (after UTF-16 BOM/encoding transcoding).
    const sniff_len = @min(content.len, 8192);
    if (std.mem.indexOfScalar(u8, content[0..sniff_len], 0) != null) {
        return stringifyAlloc(arena, FileResponse{
            .path = display_path,
            .startLine = 1,
            .totalLines = 0,
            .binary = true,
            .eof = true,
            .lines = &.{},
        });
    }

    var lines: std.ArrayList(FileLine) = .empty;
    var line_no: u64 = 0;
    var pos: usize = 0;

    while (pos < content.len) {
        line_no += 1;
        const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        var line_slice = content[pos..nl];
        if (line_slice.len > 0 and line_slice[line_slice.len - 1] == '\r') {
            line_slice = line_slice[0 .. line_slice.len - 1];
        }
        if (line_no >= start_line and line_no <= end_line) {
            const safe_text = try sanitizeUtf8Truncated(arena, line_slice, 512 * 1024);
            try lines.append(arena, .{
                .n = line_no,
                .text = safe_text,
            });
        }
        if (nl == content.len) break;
        if (bounds.is_single_line and line_no >= end_line) break;
        pos = nl + 1;
    }

    const effective_start = if (lines.items.len > 0) lines.items[0].n else 1;
    const is_eof = end_line >= line_no;

    return stringifyAlloc(arena, FileResponse{
        .path = display_path,
        .startLine = effective_start,
        .totalLines = line_no,
        .binary = false,
        .eof = is_eof,
        .lines = lines.items,
    });
}

pub fn buildSliceFileJson(
    arena: std.mem.Allocator,
    source_name: []const u8,
    raw_bytes: []const u8,
    target_line_raw: u64,
    context_raw: u64,
) ![]u8 {
    const bounds = (FileWindowQuery{
        .line = target_line_raw,
        .context = context_raw,
    }).resolveBounds();
    if (splitArchiveVirtualPath(source_name)) |vp| {
        const entry_bytes = try extractArchiveEntryFromSlice(arena, raw_bytes, vp.archive_path, vp.entry_path);
        return renderDecodedSliceFileJson(
            arena,
            source_name,
            vp.entry_path,
            entry_bytes,
            false,
            bounds,
        );
    }
    return renderDecodedSliceFileJson(
        arena,
        source_name,
        source_name,
        raw_bytes,
        true,
        bounds,
    );
}

pub fn buildFileJson(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    rel_path_raw: []const u8,
    target_line_raw: u64,
    context_raw: u64,
) ![]u8 {
    const clean_rel = try sanitizeRelPath(rel_path_raw);
    return buildFileJsonWithDisplayPath(arena, io, root_dir, clean_rel, clean_rel, target_line_raw, context_raw);
}

pub fn buildFileJsonWithDisplayPath(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    rel_path_raw: []const u8,
    display_path: []const u8,
    target_line_raw: u64,
    context_raw: u64,
) ![]u8 {
    return buildFileWindowJsonWithDisplayPath(
        arena,
        io,
        root_dir,
        rel_path_raw,
        display_path,
        .{ .line = target_line_raw, .context = context_raw },
    );
}

pub fn buildFileWindowJsonWithDisplayPath(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    rel_path_raw: []const u8,
    display_path: []const u8,
    query: FileWindowQuery,
) ![]u8 {
    const clean_rel = try sanitizeRelPath(rel_path_raw);
    if (clean_rel.len == 0) return error.InvalidPath;

    const bounds = query.resolveBounds();
    if (splitArchiveVirtualPath(clean_rel)) |vp| {
        const entry_bytes = try extractArchiveEntryFromDir(arena, io, root_dir, vp.archive_path, vp.entry_path);
        return renderDecodedSliceFileJson(
            arena,
            display_path,
            vp.entry_path,
            entry_bytes,
            false,
            bounds,
        );
    }

    var file = try root_dir.openFile(io, clean_rel, .{ .allow_directory = false });
    defer file.close(io);

    const st = try file.stat(io);
    if (st.kind == .directory) return error.IsDir;

    if (detectCompression(clean_rel) == null) {
        if (try buildPlainFileWindowJson(arena, io, file, st.size, display_path, query)) |fast_json| {
            return fast_json;
        }
    }

    const max_file_bytes: usize = 128 * 1024 * 1024;
    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const raw_bytes = file_reader.interface.allocRemaining(arena, .limited(max_file_bytes)) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.StreamTooLong => blk: {
            // Read up to max_file_bytes if compressed/UTF-16 fallback exceeds allocRemaining cap.
            const partial = try arena.alloc(u8, max_file_bytes);
            var r2 = file.reader(io, &.{});
            const n = r2.interface.readSliceShort(partial) catch |e2| switch (e2) {
                error.ReadFailed => return r2.err.?,
            };
            break :blk partial[0..n];
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    return renderDecodedSliceFileJson(
        arena,
        display_path,
        clean_rel,
        raw_bytes,
        false,
        bounds,
    );
}

pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "sanitizeRelPath rejects path traversal and accepts clean paths" {
    try std.testing.expectEqualStrings("", try sanitizeRelPath(""));
    try std.testing.expectEqualStrings("", try sanitizeRelPath("."));
    try std.testing.expectEqualStrings("src/main.zig", try sanitizeRelPath("src/main.zig"));
    try std.testing.expectEqualStrings("src/walk", try sanitizeRelPath("src/walk/"));
    try std.testing.expectEqualStrings("bundle.tar.gz::src/main.zig", try sanitizeRelPath("bundle.tar.gz::src/main.zig"));

    try std.testing.expectError(error.InvalidPath, sanitizeRelPath(".."));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("../etc/passwd"));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("src/../../etc"));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("/etc/passwd"));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("src\\main.zig"));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("src/\x00main.zig"));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("bundle.tar.gz::../etc/passwd"));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("bundle.tar.gz::/etc/passwd"));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("../bundle.tar.gz::README.md"));
}

test "detectArchiveFormat and detectCompression compound extension priority" {
    try std.testing.expectEqual(libwebgrep.ArchiveFormat.tar_gz, detectArchiveFormat("web-grep-v0.1.7.tar.gz").?);
    try std.testing.expectEqual(libwebgrep.ArchiveFormat.tar_gz, detectArchiveFormat("BUNDLE.TGZ").?);
    try std.testing.expectEqual(libwebgrep.ArchiveFormat.tar_zst, detectArchiveFormat("logs.tar.zst").?);
    try std.testing.expectEqual(libwebgrep.ArchiveFormat.tar_zst, detectArchiveFormat("logs.tzst").?);
    try std.testing.expectEqual(libwebgrep.ArchiveFormat.tar_xz, detectArchiveFormat("release.tar.xz").?);
    try std.testing.expectEqual(libwebgrep.ArchiveFormat.tar_xz, detectArchiveFormat("release.TXZ").?);
    try std.testing.expectEqual(libwebgrep.ArchiveFormat.tar, detectArchiveFormat("plain.tar").?);
    try std.testing.expectEqual(libwebgrep.ArchiveFormat.zip, detectArchiveFormat("archive.ZIP").?);
    try std.testing.expect(detectArchiveFormat("app.log.gz") == null);

    // Multi-file archives must return null from detectCompression
    try std.testing.expect(detectCompression("web-grep-v0.1.7.tar.gz") == null);
    try std.testing.expect(detectCompression("bundle.tgz") == null);
    try std.testing.expect(detectCompression("logs.tar.zst") == null);
    try std.testing.expect(detectCompression("logs.tzst") == null);
    try std.testing.expect(detectCompression("release.tar.xz") == null);
    try std.testing.expect(detectCompression("release.txz") == null);
    try std.testing.expect(detectCompression("plain.tar") == null);
    try std.testing.expect(detectCompression("archive.zip") == null);

    // Single-file compressed streams must return their Compression enum
    try std.testing.expectEqual(libwebgrep.Compression.gzip, detectCompression("app.log.gz").?);
    try std.testing.expectEqual(libwebgrep.Compression.zstd, detectCompression("app.log.ZST").?);
    try std.testing.expectEqual(libwebgrep.Compression.xz, detectCompression("app.log.xz").?);
    try std.testing.expect(detectCompression("app.log") == null);
}

test "splitArchiveVirtualPath and formatArchiveVirtualPathAlloc" {
    const vp = splitArchiveVirtualPath("dir/web-grep.tar.gz::src/main.zig").?;
    try std.testing.expectEqualStrings("dir/web-grep.tar.gz", vp.archive_path);
    try std.testing.expectEqualStrings("src/main.zig", vp.entry_path);

    try std.testing.expect(splitArchiveVirtualPath("src/main.zig") == null);
    try std.testing.expect(splitArchiveVirtualPath("::src/main.zig") == null);
    try std.testing.expect(splitArchiveVirtualPath("archive.tar::") == null);
    try std.testing.expect(splitArchiveVirtualPath("a.tar::b.tar::c.txt") == null);

    const formatted = try formatArchiveVirtualPathAlloc(std.testing.allocator, "pkg.tar.gz", "./src/lib.zig");
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("pkg.tar.gz::src/lib.zig", formatted);
    try std.testing.expectError(error.InvalidPath, formatArchiveVirtualPathAlloc(std.testing.allocator, "pkg.tar.gz", "../secret.txt"));
}

fn makeTestTarBlock(allocator: std.mem.Allocator, entry_name: []const u8, payload: []const u8) ![]u8 {
    const padded_payload = std.mem.alignForward(usize, payload.len, 512);
    const total_len = 512 + padded_payload + 1024;
    const buf = try allocator.alloc(u8, total_len);
    @memset(buf, 0);

    @memcpy(buf[0..entry_name.len], entry_name);
    @memcpy(buf[100..107], "0000644");
    @memcpy(buf[108..115], "0000000");
    @memcpy(buf[116..123], "0000000");
    _ = try std.fmt.bufPrint(buf[124..135], "{o:0>11}", .{payload.len});
    @memcpy(buf[136..147], "00000000000");
    @memset(buf[148..156], ' ');
    buf[156] = '0';
    @memcpy(buf[257..262], "ustar");
    @memcpy(buf[263..265], "00");

    var sum: u64 = 0;
    for (buf[0..512]) |b| sum += b;
    _ = try std.fmt.bufPrint(buf[148..154], "{o:0>6}", .{sum});
    buf[154] = 0;
    buf[155] = ' ';

    @memcpy(buf[512 .. 512 + payload.len], payload);
    return buf;
}

test "ArchiveTree zero-disk-landing virtual path preview and UTF-16LE/GBK transcoding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tar_bytes = try makeTestTarBlock(arena, "pkg/src/hello.zig", "const a = 1;\nconst b = 2;\nconst c = 3;\n");
    const json_str = try buildSliceFileJson(arena, "bundle.tar::pkg/src/hello.zig", tar_bytes, 2, 1);

    const parsed = try std.json.parseFromSlice(FileResponse, arena, json_str, .{});
    try std.testing.expect(!parsed.value.binary);
    try std.testing.expectEqual(@as(u64, 3), parsed.value.totalLines);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.lines.len);
    try std.testing.expectEqualStrings("const b = 2;", parsed.value.lines[1].text);

    // UTF-16LE with BOM must be transcoded to UTF-8 and NOT marked binary despite NUL bytes
    const utf16le_bytes = "\xFF\xFEh\x00e\x00l\x00l\x00o\x00\n\x00w\x00o\x00r\x00l\x00d\x00";
    const u16_json = try buildSliceFileJson(arena, "notes.txt", utf16le_bytes, 1, 5);
    const u16_parsed = try std.json.parseFromSlice(FileResponse, arena, u16_json, .{});
    try std.testing.expect(!u16_parsed.value.binary);
    try std.testing.expectEqual(@as(usize, 2), u16_parsed.value.lines.len);
    try std.testing.expectEqualStrings("hello", u16_parsed.value.lines[0].text);
    try std.testing.expectEqualStrings("world", u16_parsed.value.lines[1].text);

    // GBK/GB18030 text ("你好\n世界") must be transcoded to valid UTF-8
    const gbk_bytes = "\xC4\xE3\xBA\xC3\n\xCA\xC0\xBD\xE7";
    const gbk_json = try buildSliceFileJson(arena, "cn.txt", gbk_bytes, 1, 5);
    const gbk_parsed = try std.json.parseFromSlice(FileResponse, arena, gbk_json, .{});
    try std.testing.expect(!gbk_parsed.value.binary);
    try std.testing.expectEqualStrings("你好", gbk_parsed.value.lines[0].text);
    try std.testing.expectEqualStrings("世界", gbk_parsed.value.lines[1].text);
}

test "decodeQueryParam and getQueryParamAlloc" {
    const val = (try getQueryParamAlloc(std.testing.allocator, "path=src%2Fmain.zig&line=42", "path")).?;
    defer std.testing.allocator.free(val);
    try std.testing.expectEqualStrings("src/main.zig", val);
}

test "buildPlainFileWindowJson handles positional anchors, BOM, CRLF, long lines, and invalid fallback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 1. UTF-8 BOM + CRLF + >70 KiB chunk-crossing line
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "\xEF\xBB\xBF");
    try buf.appendSlice(arena, "alpha line 1\r\n");
    const line2_offset: u64 = buf.items.len;
    for (0..75_000) |_| {
        try buf.append(arena, 'X');
    }
    try buf.appendSlice(arena, "\r\n");
    const line3_offset: u64 = buf.items.len;
    try buf.appendSlice(arena, "gamma line 3\r\n");
    const line4_offset: u64 = buf.items.len;
    try buf.appendSlice(arena, "delta line 4"); // unterminated final line

    try tmp.dir.writeFile(io, .{ .sub_path = "bom_crlf_long.log", .data = buf.items });

    // Forward/backward from line 3 anchor
    const w_mid = try buildFileWindowJsonWithDisplayPath(arena, io, tmp.dir, "bom_crlf_long.log", "bom_crlf_long.log", .{
        .start_line = 2,
        .end_line = 4,
        .anchor_line = 3,
        .anchor_byte = line3_offset,
    });
    const p_mid = try std.json.parseFromSlice(FileResponse, arena, w_mid, .{});
    try std.testing.expect(!p_mid.value.binary);
    try std.testing.expect(p_mid.value.eof);
    try std.testing.expectEqual(@as(u64, 4), p_mid.value.totalLines);
    try std.testing.expectEqual(@as(u64, line2_offset), p_mid.value.firstByte.?);
    try std.testing.expectEqual(@as(u64, buf.items.len), p_mid.value.nextByte.?);
    try std.testing.expectEqual(@as(usize, 3), p_mid.value.lines.len);
    try std.testing.expectEqual(@as(usize, 75_000), p_mid.value.lines[0].text.len);
    try std.testing.expectEqualStrings("gamma line 3", p_mid.value.lines[1].text);
    try std.testing.expectEqualStrings("delta line 4", p_mid.value.lines[2].text);

    // Line #1 at byte 0 on BOM file + backward from line 4 clamping to line 1
    const w_top = try buildFileWindowJsonWithDisplayPath(arena, io, tmp.dir, "bom_crlf_long.log", "bom_crlf_long.log", .{
        .start_line = 1,
        .end_line = 2,
        .anchor_line = 4,
        .anchor_byte = line4_offset,
    });
    const p_top = try std.json.parseFromSlice(FileResponse, arena, w_top, .{});
    try std.testing.expect(!p_top.value.eof);
    try std.testing.expectEqual(@as(u64, 4), p_top.value.totalLines);
    try std.testing.expectEqual(@as(u64, 3), p_top.value.firstByte.?);
    try std.testing.expectEqual(@as(u64, line3_offset), p_top.value.nextByte.?);
    try std.testing.expectEqualStrings("alpha line 1", p_top.value.lines[0].text);

    // Invalid anchor_byte must safely fall back to sequential scan from byte 3
    const w_bad = try buildFileWindowJsonWithDisplayPath(arena, io, tmp.dir, "bom_crlf_long.log", "bom_crlf_long.log", .{
        .start_line = 3,
        .end_line = 3,
        .anchor_line = 3,
        .anchor_byte = line3_offset + 2,
    });
    const p_bad = try std.json.parseFromSlice(FileResponse, arena, w_bad, .{});
    try std.testing.expectEqual(@as(usize, 1), p_bad.value.lines.len);
    try std.testing.expectEqualStrings("gamma line 3", p_bad.value.lines[0].text);
}

test "buildPlainFileWindowJson avoids full-file scan on >2 MiB files and chains firstByte/nextByte cursors" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var big: std.ArrayList(u8) = .empty;
    var anchor_25000_byte: u64 = 0;
    const total_test_lines: u64 = 50_000;
    var l: u64 = 1;
    while (l <= total_test_lines) : (l += 1) {
        if (l == 25_000) anchor_25000_byte = big.items.len;
        const line_str = try std.fmt.allocPrint(arena, "log_seq_{d:0>6}_payload_padding_0123456789abcdefghijklmnopqrstuvwxyzABCDEF\n", .{l});
        try big.appendSlice(arena, line_str);
    }
    try std.testing.expect(big.items.len > 2 * 1024 * 1024);
    try tmp.dir.writeFile(io, .{ .sub_path = "big_3mb.log", .data = big.items });

    // Mid-file window around line 25,000 -> totalLines == 0 (no EOF scan), eof == false
    const w_init = try buildFileWindowJsonWithDisplayPath(arena, io, tmp.dir, "big_3mb.log", "big_3mb.log", .{
        .start_line = 24_995,
        .end_line = 25_004,
        .anchor_line = 25_000,
        .anchor_byte = anchor_25000_byte,
    });
    const p_init = try std.json.parseFromSlice(FileResponse, arena, w_init, .{});
    try std.testing.expect(!p_init.value.eof);
    try std.testing.expectEqual(@as(u64, 0), p_init.value.totalLines);
    try std.testing.expectEqual(@as(usize, 10), p_init.value.lines.len);
    try std.testing.expectEqual(@as(u64, 24_995), p_init.value.lines[0].n);
    try std.testing.expectEqual(@as(u64, 25_004), p_init.value.lines[9].n);

    // Step upward using firstByte cursor -> [24985..24994]
    const w_up = try buildFileWindowJsonWithDisplayPath(arena, io, tmp.dir, "big_3mb.log", "big_3mb.log", .{
        .start_line = 24_985,
        .end_line = 24_994,
        .anchor_line = 24_995,
        .anchor_byte = p_init.value.firstByte.?,
    });
    const p_up = try std.json.parseFromSlice(FileResponse, arena, w_up, .{});
    try std.testing.expectEqual(@as(u64, 24_985), p_up.value.lines[0].n);
    try std.testing.expectEqual(@as(u64, 24_994), p_up.value.lines[9].n);
    try std.testing.expect(std.mem.startsWith(u8, p_up.value.lines[9].text, "log_seq_024994_"));

    // Step downward using nextByte cursor -> [25005..25014]
    const w_down = try buildFileWindowJsonWithDisplayPath(arena, io, tmp.dir, "big_3mb.log", "big_3mb.log", .{
        .start_line = 25_005,
        .end_line = 25_014,
        .anchor_line = 25_005,
        .anchor_byte = p_init.value.nextByte.?,
    });
    const p_down = try std.json.parseFromSlice(FileResponse, arena, w_down, .{});
    try std.testing.expectEqual(@as(u64, 25_005), p_down.value.lines[0].n);
    try std.testing.expectEqual(@as(u64, 25_014), p_down.value.lines[9].n);
    try std.testing.expect(std.mem.startsWith(u8, p_down.value.lines[0].text, "log_seq_025005_"));

    // End of file -> reports exact totalLines and eof == true
    const w_end = try buildFileWindowJsonWithDisplayPath(arena, io, tmp.dir, "big_3mb.log", "big_3mb.log", .{
        .start_line = 49_995,
        .end_line = 50_010,
        .anchor_line = 25_005,
        .anchor_byte = p_init.value.nextByte.?,
    });
    const p_end = try std.json.parseFromSlice(FileResponse, arena, w_end, .{});
    try std.testing.expect(p_end.value.eof);
    try std.testing.expectEqual(total_test_lines, p_end.value.totalLines);
    try std.testing.expectEqual(@as(u64, 50_000), p_end.value.lines[p_end.value.lines.len - 1].n);
}

test "file_api: buildMetaJson exposes prefilter plugins and presets catalogs" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = try buildMetaJson(arena, "", "webgrep");
    const parsed = try std.json.parseFromSlice(MetaResponse, arena, json, .{
        .ignore_unknown_fields = true,
    });
    try std.testing.expectEqual(@as(usize, prefilter.PLUGIN_CATALOG.len), parsed.value.plugins.len);
    try std.testing.expectEqual(@as(usize, prefilter.PRESET_CATALOG.len), parsed.value.presets.len);
    try std.testing.expectEqualStrings("path_scope", parsed.value.plugins[0].id);
    try std.testing.expectEqualStrings("auto", parsed.value.presets[0].id);
    try std.testing.expect(parsed.value.presets[0].defaultPlugins.len > 0);
}

test "file_api: validateLineAnchor supports anchorLine=1 at narrowed mid-file byte offset" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "header line\ntarget window line 1\ntarget window line 2\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "win.log", .data = payload });

    const anchor_off: u64 = "header line\n".len;
    const w_json = try buildFileWindowJsonWithDisplayPath(arena, io, tmp.dir, "win.log", "win.log", .{
        .start_line = 1,
        .end_line = 2,
        .anchor_line = 1,
        .anchor_byte = anchor_off,
    });
    const parsed = try std.json.parseFromSlice(FileResponse, arena, w_json, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed.value.lines.len);
    try std.testing.expectEqualStrings("target window line 1", parsed.value.lines[0].text);
    try std.testing.expectEqual(@as(?u64, anchor_off), parsed.value.firstByte);
}
