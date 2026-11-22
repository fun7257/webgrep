const std = @import("std");
const libwebgrep = @import("libwebgrep");
const paths = @import("paths.zig");

const default_archive_options = paths.default_archive_options;
const detectArchiveFormat = paths.detectArchiveFormat;
const detectCompression = paths.detectCompression;
const sanitizeUtf8Truncated = paths.sanitizeUtf8Truncated;
const sanitizeArchiveEntryPath = paths.sanitizeArchiveEntryPath;
const sanitizePlainRelPath = paths.sanitizePlainRelPath;

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

pub fn detectBomlessUtf16(sample: []const u8) ?libwebgrep.Encoding {
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

/// Returns true when a non-strict-UTF-8 byte slice is predominantly valid UTF-8
/// multi-byte sequences (e.g. a UTF-8 log line truncated mid-character by a byte cap
/// or containing an isolated bad byte), so we must NOT mis-transcode it as GBK.
fn looksMostlyUtf8(sample: []const u8) bool {
    var valid_mb_bytes: usize = 0;
    var invalid_bytes: usize = 0;
    var i: usize = 0;
    while (i < sample.len) {
        const b = sample[i];
        if (b < 0x80) {
            i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
            invalid_bytes += 1;
            i += 1;
            continue;
        };
        if (i + seq_len <= sample.len) {
            if (std.unicode.utf8Decode(sample[i .. i + seq_len])) |_| {
                valid_mb_bytes += seq_len;
                i += seq_len;
                continue;
            } else |_| {}
        }
        invalid_bytes += 1;
        i += 1;
    }
    return valid_mb_bytes > 0 and valid_mb_bytes >= invalid_bytes * 2;
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
        // Guard: if the slice is predominantly valid UTF-8 (e.g. a log line truncated
        // mid-character at its byte limit), keep it as UTF-8 so sanitizeUtf8Truncated
        // only replaces the broken byte(s) instead of turning all CJK into GBK mojibake.
        if (!looksMostlyUtf8(current[0..@min(current.len, 16384)])) {
            if (libwebgrep.searcher.pipeline_mod.materialize(current, .{
                .allocator = arena,
                .compression = .none,
                .encoding = .gbk,
                .max_decode_bytes = max_bytes,
            })) |gbk_prep| {
                return gbk_prep.bytes;
            } else |_| {}
        }
    }

    return current;
}

pub fn decodeSingleLineAlloc(arena: std.mem.Allocator, raw_line: []const u8) ![]const u8 {
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
