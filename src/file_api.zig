const std = @import("std");
const libwebgrep = @import("libwebgrep");

pub const PathError = error{
    InvalidPath,
};

pub const builtin_types = [_][]const u8{
    "zig", "ts", "js", "json", "md", "py", "rust", "go",
    "c", "cpp", "css", "html", "sh", "toml", "yaml", "txt",
};

/// Strictly sanitizes a relative path from client input.
/// Rejects leading '/', '\', NUL bytes, and any '..' or empty internal segments.
/// Normalizes "." to "".
pub fn sanitizeRelPath(raw: []const u8) PathError![]const u8 {
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

pub const MetaResponse = struct {
    rootLabel: []const u8,
    root: []const u8,
    engine: []const u8 = "libwebgrep 0.1.0",
    types: []const []const u8 = &builtin_types,
    scopes: []const []const u8 = &.{},
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
    lines: []const FileLine,
};

pub fn hasCompressedExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".gz") or
        std.mem.endsWith(u8, path, ".zst") or
        std.mem.endsWith(u8, path, ".xz");
}

pub fn looksCompressedBytes(raw: []const u8) bool {
    if (raw.len >= 2 and raw[0] == 0x1f and raw[1] == 0x8b) return true; // gzip
    if (raw.len >= 4 and raw[0] == 0x28 and raw[1] == 0xb5 and raw[2] == 0x2f and raw[3] == 0xfd) return true; // zstd
    if (raw.len >= 6 and raw[0] == 0xfd and raw[1] == '7' and raw[2] == 'z' and raw[3] == 'X' and raw[4] == 'Z' and raw[5] == 0x00) return true; // xz
    return false;
}

pub fn buildSliceFileJson(
    arena: std.mem.Allocator,
    source_name: []const u8,
    raw_bytes: []const u8,
    target_line_raw: u64,
    context_raw: u64,
) ![]u8 {
    const line: u64 = @max(target_line_raw, 1);
    const context: u64 = std.math.clamp(context_raw, 0, 300);
    const start_line: u64 = if (line > context) line - context else 1;
    const end_line: u64 = line +| context;
    const max_file_bytes: usize = 128 * 1024 * 1024;

    var content: []const u8 = raw_bytes;
    if (hasCompressedExtension(source_name) or looksCompressedBytes(raw_bytes)) {
        var dec_out: u64 = 0;
        var offset_map = libwebgrep.decompress.OffsetMap{};
        defer offset_map.deinit(arena);
        if (libwebgrep.decompress.decompressSlice(
            arena,
            raw_bytes,
            .auto,
            0,
            max_file_bytes,
            null,
            &dec_out,
            &offset_map,
        )) |maybe_dec| {
            if (maybe_dec) |dec_slice| {
                content = dec_slice;
            }
        } else |_| {}
    }

    const sniff_len = @min(content.len, 8192);
    if (std.mem.indexOfScalar(u8, content[0..sniff_len], 0) != null) {
        return stringifyAlloc(arena, FileResponse{
            .path = source_name,
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
        if (context == 0 and line_no >= end_line) break;
        pos = nl + 1;
    }

    const effective_start = if (lines.items.len > 0) lines.items[0].n else 1;
    const is_eof = end_line >= line_no;

    return stringifyAlloc(arena, FileResponse{
        .path = source_name,
        .startLine = effective_start,
        .totalLines = line_no,
        .binary = false,
        .eof = is_eof,
        .lines = lines.items,
    });
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
    const clean_rel = try sanitizeRelPath(rel_path_raw);
    if (clean_rel.len == 0) return error.InvalidPath;

    const line: u64 = @max(target_line_raw, 1);
    const context: u64 = std.math.clamp(context_raw, 0, 300);
    const start_line: u64 = if (line > context) line - context else 1;
    const end_line: u64 = line +| context;

    var file = try root_dir.openFile(io, clean_rel, .{ .allow_directory = false });
    defer file.close(io);

    const st = try file.stat(io);
    if (st.kind == .directory) return error.IsDir;

    const max_file_bytes: usize = 128 * 1024 * 1024;
    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const raw_bytes = file_reader.interface.allocRemaining(arena, .limited(max_file_bytes)) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.StreamTooLong => blk: {
            // Read up to max_file_bytes if file is larger than 16 MiB.
            const partial = try arena.alloc(u8, max_file_bytes);
            var r2 = file.reader(io, &.{});
            const n = r2.interface.readSliceShort(partial) catch |e2| switch (e2) {
                error.ReadFailed => return r2.err.?,
            };
            break :blk partial[0..n];
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    var content: []const u8 = raw_bytes;
    if (hasCompressedExtension(clean_rel)) {
        var dec_out: u64 = 0;
        var offset_map = libwebgrep.decompress.OffsetMap{};
        defer offset_map.deinit(arena);
        if (libwebgrep.decompress.decompressSlice(
            arena,
            raw_bytes,
            .auto,
            0,
            max_file_bytes,
            null,
            &dec_out,
            &offset_map,
        )) |maybe_dec| {
            if (maybe_dec) |dec_slice| {
                content = dec_slice;
            }
        } else |_| {}
    }

    // Check first 8 KiB for NUL byte -> binary detection.
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
        if (context == 0 and line_no >= end_line) break;
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

    try std.testing.expectError(error.InvalidPath, sanitizeRelPath(".."));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("../etc/passwd"));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("src/../../etc"));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("/etc/passwd"));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("src\\main.zig"));
    try std.testing.expectError(error.InvalidPath, sanitizeRelPath("src/\x00main.zig"));
}

test "decodeQueryParam and getQueryParamAlloc" {
    const val = (try getQueryParamAlloc(std.testing.allocator, "path=src%2Fmain.zig&line=42", "path")).?;
    defer std.testing.allocator.free(val);
    try std.testing.expectEqualStrings("src/main.zig", val);
}
