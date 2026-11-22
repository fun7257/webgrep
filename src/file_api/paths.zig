const std = @import("std");
const libwebgrep = @import("libwebgrep");

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

pub fn sanitizePlainRelPath(raw: []const u8) PathError![]const u8 {
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

pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}
