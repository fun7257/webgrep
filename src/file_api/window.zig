const std = @import("std");
const libwebgrep = @import("libwebgrep");
const paths = @import("paths.zig");
const archive_decode = @import("archive_decode.zig");

const sanitizeRelPath = paths.sanitizeRelPath;
const detectArchiveFormat = paths.detectArchiveFormat;
const detectCompression = paths.detectCompression;
const splitArchiveVirtualPath = paths.splitArchiveVirtualPath;
const sanitizeUtf8Truncated = paths.sanitizeUtf8Truncated;
const stringifyAlloc = paths.stringifyAlloc;
const hasCompressedExtension = archive_decode.hasCompressedExtension;
const looksCompressedBytes = archive_decode.looksCompressedBytes;
const extractArchiveEntryFromSlice = archive_decode.extractArchiveEntryFromSlice;
const extractArchiveEntryFromDir = archive_decode.extractArchiveEntryFromDir;
const detectBomlessUtf16 = archive_decode.detectBomlessUtf16;
const decodeTextSliceToUtf8 = archive_decode.decodeTextSliceToUtf8;
const decodeSingleLineAlloc = archive_decode.decodeSingleLineAlloc;

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
