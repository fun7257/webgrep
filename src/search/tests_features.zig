const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");
const prefilter = @import("../prefilter.zig");
const source_registry = @import("../source_registry.zig");
const search_cache = @import("../search_cache.zig");
const time_parser = @import("../time_parser.zig");
const protocol = @import("protocol.zig");
const limits = @import("limits.zig");
const query_plan = @import("query_plan.zig");
const types = @import("types.zig");
const runner_mod = @import("runner.zig");
const execute = @import("execute.zig");

const KvPredicateDto = protocol.KvPredicateDto;
const SearchRequest = protocol.SearchRequest;
const FrameSender = protocol.FrameSender;
const HitSpan = protocol.HitSpan;
const HitItem = protocol.HitItem;
const HitsFrame = protocol.HitsFrame;
const ProgressFrame = protocol.ProgressFrame;
const DoneFrame = protocol.DoneFrame;
const ErrorFrame = protocol.ErrorFrame;
const EngineLimits = limits.EngineLimits;
const ARCHIVE_VIRTUAL_SEP = limits.ARCHIVE_VIRTUAL_SEP;
const detectArchiveFormat = limits.detectArchiveFormat;
const formatRegexDiagnosticAlloc = limits.formatRegexDiagnosticAlloc;
const custom_file_types = limits.custom_file_types;
const parseCaseMode = query_plan.parseCaseMode;
const hasRegexMeta = query_plan.hasRegexMeta;
const computeRegexSelectivity = query_plan.computeRegexSelectivity;
const computeLiteralSelectivity = query_plan.computeLiteralSelectivity;
const PositionalWindowReader = types.PositionalWindowReader;
const JobRunner = runner_mod.JobRunner;
const executeSearchJson = execute.executeSearchJson;
const executeSearch = execute.executeSearch;
const executeSearchWithRegistry = execute.executeSearchWithRegistry;

test "search_job: libwebgrep v0.5.0 alt_prefilter & precomputed_dfa selectivity planner" {
    const gpa = std.testing.allocator;

    var re_alt = try libwebgrep.Regex.init(gpa, "ERROR_CRITICAL|FATAL_PANIC", EngineLimits.regexOptions(.sensitive));
    defer re_alt.deinit();
    try std.testing.expect(re_alt.alt_prefilter != null);
    // An 11-char exact alternation (`min_alt_len = 11`) must outscore a weak 2-char literal `in` (`25`).
    try std.testing.expect(computeRegexSelectivity(&re_alt) > computeLiteralSelectivity("in"));

    var re_dfa = try libwebgrep.Regex.init(gpa, "\\d{4}", EngineLimits.regexOptions(.sensitive));
    defer re_dfa.deinit();
    // Unanchored digit regex has no literal prefilter and must still score lower than any 2+ char literal.
    try std.testing.expect(computeRegexSelectivity(&re_dfa) < computeLiteralSelectivity("fn"));
}

test "search_job: libwebgrep v0.5.0 caller-configured limits (context > 10 & regex repeat > 1000)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file_buf: std.ArrayList(u8) = .empty;
    defer file_buf.deinit(gpa);
    for (1..26) |line_idx| {
        const line_str = try std.fmt.allocPrint(gpa, "ctx_before_{d:0>2}\n", .{line_idx});
        defer gpa.free(line_str);
        try file_buf.appendSlice(gpa, line_str);
    }
    try file_buf.appendSlice(gpa, "MATCH_TARGET_V050\n");
    for (1..26) |line_idx| {
        const line_str = try std.fmt.allocPrint(gpa, "ctx_after_{d:0>2}\n", .{line_idx});
        defer gpa.free(line_str);
        try file_buf.appendSlice(gpa, line_str);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "deep_context.log", .data = file_buf.items });

    const CtxCollector = struct {
        allocator: std.mem.Allocator,
        hit_items: usize = 0,
        ctx_items: usize = 0,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                for (parsed.value.items) |it| {
                    if (it.isContext) {
                        self.ctx_items += 1;
                    } else {
                        self.hit_items += 1;
                    }
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var col = CtxCollector{ .allocator = gpa };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 500,
        .pattern = "MATCH_TARGET_V050",
        .context = 20, // Exceeds former v0.4.1 hardcoded cap of 10!
    }, &cancel, .{ .ctx = &col, .sendFn = CtxCollector.send });

    try std.testing.expectEqual(@as(u64, 1), col.matched_lines);
    try std.testing.expectEqual(@as(usize, 1), col.hit_items);
    try std.testing.expectEqual(@as(usize, 40), col.ctx_items); // 20 before + 20 after

    // Verify EngineLimits.regexOptions allows repeat > 1000
    var re_repeat = try libwebgrep.Regex.init(gpa, "x{1200}", EngineLimits.regexOptions(.sensitive));
    defer re_repeat.deinit();
}

fn writeTestTarOctal(field: []u8, val: u64) void {
    @memset(field, '0');
    if (field.len > 0) field[field.len - 1] = 0;
    var v = val;
    var idx: usize = if (field.len >= 2) field.len - 2 else 0;
    while (v > 0) {
        field[idx] = @intCast('0' + (v & 7));
        v >>= 3;
        if (idx == 0) break;
        idx -= 1;
    }
}

fn finalizeTestTarHeader(header: *[512]u8) void {
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    @memset(header[148..156], ' ');
    var sum: u64 = 0;
    for (header) |b| sum += b;
    writeTestTarOctal(header[148..155], sum);
    header[155] = ' ';
}

fn appendTestTarEntry(out: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const u8, typeflag: u8, data: []const u8) !void {
    var header: [512]u8 = @splat(0);
    const name_len = @min(path.len, 100);
    @memcpy(header[0..name_len], path[0..name_len]);
    writeTestTarOctal(header[100..108], 0o644);
    writeTestTarOctal(header[108..116], 0);
    writeTestTarOctal(header[116..124], 0);
    writeTestTarOctal(header[124..136], if (typeflag == '0') data.len else 0);
    writeTestTarOctal(header[136..148], 0);
    header[156] = typeflag;
    finalizeTestTarHeader(&header);
    try out.appendSlice(allocator, &header);
    if (typeflag == '0' and data.len > 0) {
        try out.appendSlice(allocator, data);
        const rem = data.len % 512;
        if (rem != 0) {
            const pad = 512 - rem;
            try out.appendNTimes(allocator, 0, pad);
        }
    }
}

test "search_job: libwebgrep v0.5.0 zero-disk-landing archive direct search (:: virtual path & TreeConfig filters)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tar_bytes: std.ArrayList(u8) = .empty;
    defer tar_bytes.deinit(gpa);
    try appendTestTarEntry(&tar_bytes, gpa, "src/engine.zig", '0', "pub fn archive_needle() void {}\n");
    try appendTestTarEntry(&tar_bytes, gpa, "docs/guide.md", '0', "# archive_needle documentation\n");
    try tar_bytes.appendNTimes(gpa, 0, 1024);

    try tmp.dir.writeFile(io, .{ .sub_path = "bundle.tar", .data = tar_bytes.items });

    const ArchiveHitCollector = struct {
        allocator: std.mem.Allocator,
        files: std.ArrayList([]u8) = .empty,
        matched_lines: u64 = 0,

        fn deinit(self: *@This()) void {
            for (self.files.items) |f| self.allocator.free(f);
            self.files.deinit(self.allocator);
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                for (parsed.value.items) |it| {
                    try self.files.append(self.allocator, try self.allocator.dupe(u8, it.file));
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Unfiltered archive search returns both entries formatted as `bundle.tar::<entry_path>`
    var col_all = ArchiveHitCollector{ .allocator = gpa };
    defer col_all.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 601,
        .pattern = "archive_needle",
    }, &cancel, .{ .ctx = &col_all, .sendFn = ArchiveHitCollector.send });

    try std.testing.expectEqual(@as(u64, 2), col_all.matched_lines);
    try std.testing.expectEqual(@as(usize, 2), col_all.files.items.len);
    var saw_zig = false;
    var saw_md = false;
    for (col_all.files.items) |vpath| {
        if (std.mem.eql(u8, vpath, "bundle.tar::src/engine.zig")) saw_zig = true;
        if (std.mem.eql(u8, vpath, "bundle.tar::docs/guide.md")) saw_md = true;
    }
    try std.testing.expect(saw_zig and saw_md);

    // 2. `types = &.{"zig"}` filters inside the archive via TreeConfig, keeping only `bundle.tar::src/engine.zig`
    var col_zig = ArchiveHitCollector{ .allocator = gpa };
    defer col_zig.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 602,
        .pattern = "archive_needle",
        .types = &.{"zig"},
    }, &cancel, .{ .ctx = &col_zig, .sendFn = ArchiveHitCollector.send });

    try std.testing.expectEqual(@as(u64, 1), col_zig.matched_lines);
    try std.testing.expectEqual(@as(usize, 1), col_zig.files.items.len);
    try std.testing.expectEqualStrings("bundle.tar::src/engine.zig", col_zig.files.items[0]);
}

test "search_job: libwebgrep v0.5.0 structured CompileDiagnostic regex error reporting" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.txt", .data = "hello world\n" });

    const ErrCollector = struct {
        allocator: std.mem.Allocator,
        error_msg: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.error_msg) |m| self.allocator.free(m);
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"error\"") != null) {
                var parsed = try std.json.parseFromSlice(ErrorFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                if (self.error_msg) |old| self.allocator.free(old);
                self.error_msg = try self.allocator.dupe(u8, parsed.value.message);
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var err_col = ErrCollector{ .allocator = gpa };
    defer err_col.deinit();

    try executeSearch(gpa, io, tmp.dir, .{
        .id = 603,
        .pattern = "[unclosed",
        .mode = "regex",
    }, &cancel, .{ .ctx = &err_col, .sendFn = ErrCollector.send });

    try std.testing.expect(err_col.error_msg != null);
    const msg = err_col.error_msg.?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "Regex compile error") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "line 1, column ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "offset ") != null);
}

test "search_job: libwebgrep v0.5.0 walk_types, walk_ignore (.gitignore), walk_glob brace expansion, and UTF-16LE BOM Encoding.auto" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "ignored_dir/\n*_ignored.rs\n" });
    try tmp.dir.createDirPath(io, "ignored_dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "ignored_dir/secret.rs", .data = "walk_target_v050 in ignored dir\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skip_ignored.rs", .data = "walk_target_v050 in ignored file\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.rs", .data = "fn walk_target_v050() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "script.py", .data = "def walk_target_v050(): pass\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "walk_target_v050 in plain text\n" });

    // UTF-16LE with BOM (`0xFF, 0xFE`) containing "utf16_bom_target\n"
    const utf16le_bytes = [_]u8{
        0xFF, 0xFE,
        'u',  0x00,
        't',  0x00,
        'f',  0x00,
        '1',  0x00,
        '6',  0x00,
        '_',  0x00,
        'b',  0x00,
        'o',  0x00,
        'm',  0x00,
        '_',  0x00,
        't',  0x00,
        'a',  0x00,
        'r',  0x00,
        'g',  0x00,
        'e',  0x00,
        't',  0x00,
        '\n', 0x00,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "unicode_log.log", .data = &utf16le_bytes });

    const CountCollector = struct {
        allocator: std.mem.Allocator,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. `respectIgnore = true` + brace-expanded `fileGlobs = &.{"*.{rs,py}"}` -> matches `keep.rs` and `script.py` (2 lines), skipping `.gitignore` matches and `notes.txt`!
    var col_ignore = CountCollector{ .allocator = gpa };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 604,
        .pattern = "walk_target_v050",
        .respectIgnore = true,
        .fileGlobs = &.{"*.{rs,py}"},
    }, &cancel, .{ .ctx = &col_ignore, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 2), col_ignore.matched_lines);

    // 2. `walk_types` built-in language alias (`rust`) + `respectIgnore = true` -> matches only `keep.rs` (1 line)
    var col_rust = CountCollector{ .allocator = gpa };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 605,
        .pattern = "walk_target_v050",
        .respectIgnore = true,
        .types = &.{"rust"},
    }, &cancel, .{ .ctx = &col_rust, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 1), col_rust.matched_lines);

    // 3. UTF-16LE BOM automatic transcoding via `Encoding.auto` + `searchSourceSlice`
    var col_utf16 = CountCollector{ .allocator = gpa };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 606,
        .pattern = "utf16_bom_target",
    }, &cancel, .{ .ctx = &col_utf16, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 1), col_utf16.matched_lines);
}

test "search_job: strict single-line matching, literal spaces, explicit $c/$w/$r/$rcw flags, and invalid scoped regex error frame" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sample_data =
        "2026-11-12 [INFO] ErrorCode 404 retry in 50ms\n" ++
        "2026-11-12 [INFO] errorcode 4040 retry in 50ms\n" ++
        "2026-11-12 [WARN] ErrorCode2 404 retry in 50ms\n" ++
        "2026-11-12 [ERROR] $r([unclosed) literal line\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "strict.log", .data = sample_data });

    const TestCollector = struct {
        allocator: std.mem.Allocator,
        matched_lines: u64 = 0,
        error_msg: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.error_msg) |m| self.allocator.free(m);
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"error\"") != null) {
                var parsed = try std.json.parseFromSlice(ErrorFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                if (self.error_msg) |old| self.allocator.free(old);
                self.error_msg = try self.allocator.dupe(u8, parsed.value.message);
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // (a) Plain case-insensitive search with literal spaces matches all 3 lines containing "retry in 50ms" and "errorcode"
    var col_plain = TestCollector{ .allocator = gpa };
    defer col_plain.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 701,
        .pattern = "ErrorCode",
        .case = "insensitive",
        .contains = &.{"retry in 50ms"},
    }, &cancel, .{ .ctx = &col_plain, .sendFn = TestCollector.send });
    try std.testing.expectEqual(@as(u64, 3), col_plain.matched_lines);

    // (b) Explicit `$c(ErrorCode)` + `$w(ErrorCode)` (`$cw(ErrorCode)`) + `$rcw(404)` matches only line 1
    var col_scoped = TestCollector{ .allocator = gpa };
    defer col_scoped.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 702,
        .pattern = "$cw(ErrorCode)",
        .case = "insensitive",
        .contains = &.{ "$rcw(\\d{3})", "retry in 50ms" },
    }, &cancel, .{ .ctx = &col_scoped, .sendFn = TestCollector.send });
    try std.testing.expectEqual(@as(u64, 1), col_scoped.matched_lines);

    // (c) Invalid `$r([unclosed)` in `contains` or `excludes` emits an error frame instead of falling back to literal
    var col_bad_contains = TestCollector{ .allocator = gpa };
    defer col_bad_contains.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 703,
        .pattern = "2026-11-12",
        .case = "insensitive",
        .contains = &.{"$r([unclosed)"},
    }, &cancel, .{ .ctx = &col_bad_contains, .sendFn = TestCollector.send });
    try std.testing.expect(col_bad_contains.error_msg != null);
    try std.testing.expectEqual(@as(u64, 0), col_bad_contains.matched_lines);

    var col_bad_excludes = TestCollector{ .allocator = gpa };
    defer col_bad_excludes.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 704,
        .pattern = "2026-11-12",
        .case = "insensitive",
        .excludes = &.{"$r([unclosed)"},
    }, &cancel, .{ .ctx = &col_bad_excludes, .sendFn = TestCollector.send });
    try std.testing.expect(col_bad_excludes.error_msg != null);
    try std.testing.expectEqual(@as(u64, 0), col_bad_excludes.matched_lines);
}

test "search_job: orthogonal content vs mtime, mtime 1-line summary, per-source/query timeFormat, lookbehind, and cache isolation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "data");
    try tmp.dir.createDirPath(io, "logs_src");
    try tmp.dir.createDirPath(io, "json_src");

    // 1. Mixed directory: log (timestamps + stack trace), zig code, markdown, and custom bracketed format
    const app_log =
        "2026-11-14T10:00:00Z INFO start\n" ++
        "2026-11-14T10:05:00Z ERROR boom_in_window\n" ++
        "    at com.example.Service.handle(Service.java:42)\n" ++
        "2026-11-14T10:20:00Z ERROR outside_window\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "logs_src/app.log", .data = app_log });
    try tmp.dir.writeFile(io, .{
        .sub_path = "logs_src/code.zig",
        .data = "const boom_in_window = 1;\nconst Service_handle = 2;\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "logs_src/notes.md",
        .data = "# Notes\nboom_in_window documentation\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "logs_src/custom.txt",
        .data = "TS=[14@11@2026 10:05:00] custom_regex_hit\nTS=[14@11@2026 10:20:00] custom_regex_miss\n",
    });

    // 2. JSON source with nested epoch timestamp
    const sec_1005: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 14, 10, 5, 0).?);
    const sec_1020: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 14, 10, 20, 0).?);
    const json_data = try std.fmt.allocPrint(
        arena,
        "{{\"meta\":{{\"ts\":{d}}},\"msg\":\"json_boom\"}}\n{{\"meta\":{{\"ts\":{d}}},\"msg\":\"json_outside\"}}\n",
        .{ sec_1005, sec_1020 },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "json_src/events.jsonl", .data = json_data });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buf);
    const root_real = path_buf[0..root_len];

    const data_path = try std.fmt.allocPrint(arena, "{s}/data", .{root_real});
    const logs_path = try std.fmt.allocPrint(arena, "{s}/logs_src", .{root_real});
    const json_path = try std.fmt.allocPrint(arena, "{s}/json_src", .{root_real});

    var reg = source_registry.SourceRegistry.init(gpa, io, data_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "logs_src",
        .config = .{ .path = logs_path },
        .enabled = true,
    });
    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "json_src",
        .config = .{ .path = json_path, .timeFormat = "json:meta.ts" },
        .enabled = true,
    });

    const st_app = try tmp.dir.statFile(io, "logs_src/app.log", .{});
    const file_mtime_ms: u64 = @intCast(@max(0, @divFloor(st_app.mtime.nanoseconds, std.time.ns_per_ms)));

    const E2ECollector = struct {
        allocator: std.mem.Allocator,
        files_searched: u64 = 0,
        files_matched: u64 = 0,
        matched_lines: u64 = 0,
        cache_hit: [32]u8 = undefined,
        cache_hit_len: usize = 0,
        error_msg: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.error_msg) |m| self.allocator.free(m);
        }

        fn cacheTier(self: *const @This()) []const u8 {
            return self.cache_hit[0..self.cache_hit_len];
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.files_searched = parsed.value.filesSearched;
                self.files_matched = parsed.value.filesMatched;
                self.matched_lines = parsed.value.matchedLines;
                const cp_len = @min(parsed.value.cacheHit.len, self.cache_hit.len);
                @memcpy(self.cache_hit[0..cp_len], parsed.value.cacheHit[0..cp_len]);
                self.cache_hit_len = cp_len;
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"error\"") != null) {
                var parsed = try std.json.parseFromSlice(ErrorFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                if (self.error_msg) |old| self.allocator.free(old);
                self.error_msg = try self.allocator.dupe(u8, parsed.value.message);
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    const win_lo_ms: u64 = (sec_1005 - 60) * 1000;
    const win_hi_ms: u64 = (sec_1005 + 60) * 1000;

    // (a) `timeMode = "content"` strictly excludes untimestamped code.zig / notes.md (NO mtime fallback)
    var c_content = E2ECollector{ .allocator = gpa };
    defer c_content.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 801,
        .pattern = "boom_in_window",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_content, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_content.files_matched);
    try std.testing.expectEqual(@as(u64, 1), c_content.matched_lines);

    // (b) `timeMode = "mtime"` with empty query emits 1 summary line per mtime-matched file (all 4 files in logs_src)
    var c_mtime_summary = E2ECollector{ .allocator = gpa };
    defer c_mtime_summary.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 802,
        .pattern = "",
        .sources = &.{"logs_src"},
        .timeMode = "mtime",
        .timeStartMs = file_mtime_ms - 60_000,
        .timeEndMs = file_mtime_ms + 60_000,
    }, &cancel, .{ .ctx = &c_mtime_summary, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_mtime_summary.files_matched);
    try std.testing.expectEqual(@as(u64, 4), c_mtime_summary.matched_lines);

    // (c) Stack-trace continuation lookbehind when parent timestamped line does NOT contain the query keyword
    var c_stack = E2ECollector{ .allocator = gpa };
    defer c_stack.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 803,
        .pattern = "Service.java",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_stack, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_stack.matched_lines);

    // Stack frame must NOT leak into a later window that starts after 10:05:00
    var c_stack_miss = E2ECollector{ .allocator = gpa };
    defer c_stack_miss.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 804,
        .pattern = "Service.java",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeStartMs = (sec_1005 + 60) * 1000,
        .timeEndMs = (sec_1020 + 60) * 1000,
    }, &cancel, .{ .ctx = &c_stack_miss, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 0), c_stack_miss.matched_lines);

    // (d) Per-source `config.timeFormat` ("json:meta.ts") + L1 exact replay check
    var c_json1 = E2ECollector{ .allocator = gpa };
    defer c_json1.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 805,
        .pattern = "json_",
        .sources = &.{"json_src"},
        .timeMode = "content",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_json1, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_json1.matched_lines);

    var c_json2 = E2ECollector{ .allocator = gpa };
    defer c_json2.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 806,
        .pattern = "json_",
        .sources = &.{"json_src"},
        .timeMode = "content",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_json2, .sendFn = E2ECollector.send });
    try std.testing.expectEqualStrings("exact", c_json2.cacheTier());
    try std.testing.expectEqual(@as(u64, 1), c_json2.matched_lines);

    // (e) Query-level `regex:` override & cache isolation against empty `timeFormat`
    var c_custom_none = E2ECollector{ .allocator = gpa };
    defer c_custom_none.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 807,
        .pattern = "custom_regex",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeFormat = "",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_custom_none, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 0), c_custom_none.matched_lines);

    var c_custom_re = E2ECollector{ .allocator = gpa };
    defer c_custom_re.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 808,
        .pattern = "custom_regex",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeFormat = "regex:TS=\\[(?P<d>\\d{2})@(?P<m>\\d{2})@(?P<Y>\\d{4}) (?P<H>\\d{2}):(?P<M>\\d{2}):(?P<S>\\d{2})\\]",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_custom_re, .sendFn = E2ECollector.send });
    try std.testing.expect(!std.mem.eql(u8, c_custom_re.cacheTier(), "exact"));
    try std.testing.expectEqual(@as(u64, 1), c_custom_re.matched_lines);

    // (f) Invalid regex timeFormat returns CompileDiagnostic error frame
    var c_bad_tf = E2ECollector{ .allocator = gpa };
    defer c_bad_tf.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 809,
        .pattern = "custom_regex",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeFormat = "regex:(unclosed",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_bad_tf, .sendFn = E2ECollector.send });
    try std.testing.expect(c_bad_tf.error_msg != null);
    try std.testing.expectEqual(@as(u64, 0), c_bad_tf.matched_lines);
}

test "search_job: per-source non-stacked timeMode=source across mtime code source and content log sources" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "data");
    try tmp.dir.createDirPath(io, "code_src");
    try tmp.dir.createDirPath(io, "auto_log_src");
    try tmp.dir.createDirPath(io, "json_src");

    // 1. Code source (pluginPreset = "code", no timeFormat -> mtime only; historical logs inside must match file mtime, NOT line time)
    try tmp.dir.writeFile(io, .{
        .sub_path = "code_src/main.zig",
        .data = "pub fn boot() void {}\npub fn shutdown() void {}\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "code_src/README.md",
        .data = "# Overview\nHistorical 2020-01-01T00:00:00Z example\n",
    });

    // 2. Auto log source (timeFormat = "auto" -> line time ONLY, file mtime is NOW >> historical window 10:04..10:06!)
    try tmp.dir.writeFile(io, .{
        .sub_path = "auto_log_src/service.log",
        .data = "2026-11-14T10:01:00Z INFO startup\n" ++
            "2026-11-14T10:04:30Z ERROR hit_one\n" ++
            "2026-11-14T10:05:15Z ERROR hit_two\n" ++
            "2026-11-14T10:20:00Z ERROR outside_hi\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "auto_log_src/untimestamped.txt",
        .data = "plain text hit_one without timestamp\n",
    });

    // 3. Custom JSON source (timeFormat = "json:meta.ts" -> line time ONLY)
    const sec_1005: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 14, 10, 5, 0).?);
    const sec_1020: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 14, 10, 20, 0).?);
    const json_data = try std.fmt.allocPrint(
        arena,
        "{{\"meta\":{{\"ts\":{d}}},\"msg\":\"hit_json\"}}\n{{\"meta\":{{\"ts\":{d}}},\"msg\":\"miss_json\"}}\n",
        .{ sec_1005, sec_1020 },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "json_src/events.jsonl", .data = json_data });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buf);
    const root_real = path_buf[0..root_len];

    const data_path = try std.fmt.allocPrint(arena, "{s}/data", .{root_real});
    const code_path = try std.fmt.allocPrint(arena, "{s}/code_src", .{root_real});
    const auto_log_path = try std.fmt.allocPrint(arena, "{s}/auto_log_src", .{root_real});
    const json_path = try std.fmt.allocPrint(arena, "{s}/json_src", .{root_real});

    var reg = source_registry.SourceRegistry.init(gpa, io, data_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "code_src",
        .config = .{ .path = code_path, .pluginPreset = "code" },
        .enabled = true,
    });
    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "auto_log_src",
        .config = .{ .path = auto_log_path, .timeFormat = "auto" },
        .enabled = true,
    });
    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "json_src",
        .config = .{ .path = json_path, .timeFormat = "json:meta.ts" },
        .enabled = true,
    });

    const st_code = try tmp.dir.statFile(io, "code_src/main.zig", .{});
    const mtime_ms: u64 = @intCast(@max(0, @divFloor(st_code.mtime.nanoseconds, std.time.ns_per_ms)));

    const Collector = struct {
        matched_lines: u64 = 0,
        files_matched: u64 = 0,
        cache_hit: [16]u8 = undefined,
        cache_len: usize = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, std.heap.page_allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.files_matched = parsed.value.filesMatched;
                const n = @min(parsed.value.cacheHit.len, self.cache_hit.len);
                @memcpy(self.cache_hit[0..n], parsed.value.cacheHit[0..n]);
                self.cache_len = n;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    const win_lo_ms: u64 = (sec_1005 - 60) * 1000;
    const win_hi_ms: u64 = (sec_1005 + 60) * 1000;

    // 1. Historical window [10:04, 10:06]:
    //    - `auto_log_src` & `json_src` match their in-line timestamps (2 + 1 = 3 lines), ignoring file mtime (> now)!
    //    - untimestamped.txt inside `auto_log_src` returns 0 hits (strict line time).
    //    - `code_src` (mtime mode) is pruned by mtime because mtime (~now) > win_hi_ms -> 0 hits!
    var c1 = Collector{};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 901,
        .pattern = "hit_",
        .sources = &.{ "code_src", "auto_log_src", "json_src" },
        .timeMode = "source",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c1, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 2), c1.files_matched);
    try std.testing.expectEqual(@as(u64, 3), c1.matched_lines);

    // 2. Empty-keyword time browse over [10:04, 10:06] emits ALL matching log lines from content-time sources
    //    (2 lines in service.log + 1 line in events.jsonl = 3 lines), while `code_src` is excluded by mtime.
    var c2 = Collector{};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 902,
        .pattern = "",
        .sources = &.{ "code_src", "auto_log_src", "json_src" },
        .timeMode = "source",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c2, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 2), c2.files_matched);
    try std.testing.expectEqual(@as(u64, 3), c2.matched_lines);

    // 3. Recent window around `mtime` + empty pattern:
    //    - `code_src` emits exactly 1 summary line per mtime-matched file (2 files -> 2 lines)!
    var c3 = Collector{};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 903,
        .pattern = "",
        .sources = &.{"code_src"},
        .timeMode = "source",
        .timeStartMs = mtime_ms - 60_000,
        .timeEndMs = mtime_ms + 60_000,
    }, &cancel, .{ .ctx = &c3, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 2), c3.files_matched);
    try std.testing.expectEqual(@as(u64, 2), c3.matched_lines);

    // 4. Switching `code_src` to `pluginPreset = "timeseries"` + `timeFormat = "auto"` via upsertSource isolates cache via `pluginSig`/`time_format_sig`
    //    and now evaluates `code_src` strictly by line time -> untimestamped `main.zig` & `README.md` emit 0 lines!
    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "code_src",
        .config = .{ .path = code_path, .timeFormat = "auto", .pluginPreset = "timeseries" },
        .enabled = true,
    });
    var c4 = Collector{};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 904,
        .pattern = "",
        .sources = &.{"code_src"},
        .timeMode = "source",
        .timeStartMs = mtime_ms - 60_000,
        .timeEndMs = mtime_ms + 60_000,
    }, &cancel, .{ .ctx = &c4, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 0), c4.matched_lines);
}
