const std = @import("std");
const libwebgrep = @import("libwebgrep");
const prefilter = @import("../prefilter.zig");
const paths = @import("paths.zig");
const meta_tree = @import("meta_tree.zig");
const archive_decode = @import("archive_decode.zig");
const window = @import("window.zig");

const ARCHIVE_VIRTUAL_SEP = paths.ARCHIVE_VIRTUAL_SEP;
const detectArchiveFormat = paths.detectArchiveFormat;
const isArchivePath = paths.isArchivePath;
const detectCompression = paths.detectCompression;
const splitArchiveVirtualPath = paths.splitArchiveVirtualPath;
const formatArchiveVirtualPathAlloc = paths.formatArchiveVirtualPathAlloc;
const sanitizeRelPath = paths.sanitizeRelPath;
const decodeQueryParam = paths.decodeQueryParam;
const getQueryParamAlloc = paths.getQueryParamAlloc;
const MetaResponse = meta_tree.MetaResponse;
const buildMetaJson = meta_tree.buildMetaJson;
const FileResponse = window.FileResponse;
const buildPlainFileWindowJson = window.buildPlainFileWindowJson;
const buildSliceFileJson = window.buildSliceFileJson;
const buildFileJson = window.buildFileJson;
const buildFileWindowJsonWithDisplayPath = window.buildFileWindowJsonWithDisplayPath;

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
    try std.testing.expectEqualStrings("common", parsed.value.plugins[0].domain);
    try std.testing.expectEqualStrings("code", parsed.value.plugins[2].domain);
    try std.testing.expectEqualStrings("log", parsed.value.plugins[3].domain);
    try std.testing.expectEqualStrings("timeseries", parsed.value.presets[0].id);
    try std.testing.expectEqualStrings("code", parsed.value.presets[1].id);
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

test "file_api: truncated UTF-8 CJK line stays UTF-8 instead of GBK mojibake while true GBK still decodes" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1. UTF-8 JSON line truncated mid-character (0xE5 = first byte of '出') must NOT be mis-decoded as GBK.
    const truncated_utf8 = "{\"etf\":\"ETF权限设置\",\"logout\":\"退\xe5";
    const decoded_utf8 = try archive_decode.decodeSingleLineAlloc(arena, truncated_utf8);
    try std.testing.expect(std.mem.indexOf(u8, decoded_utf8, "ETF权限设置") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded_utf8, "退") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(decoded_utf8));

    // 2. Genuine GBK Chinese text ("测试日志") must still transcode cleanly to UTF-8.
    const gbk_line = "\xb2\xe2\xca\xd4\xc8\xd5\xd6\xbe";
    const decoded_gbk = try archive_decode.decodeSingleLineAlloc(arena, gbk_line);
    try std.testing.expectEqualStrings("测试日志", decoded_gbk);
}
