const std = @import("std");
const file_api = @import("../file_api.zig");
const types = @import("types.zig");
const store = @import("store.zig");

const SourceRegistry = store.SourceRegistry;
const SourcesResponse = types.SourcesResponse;
const DirSuggestResponse = types.DirSuggestResponse;
const isValidUuid = types.isValidUuid;

test "SourceRegistry auto-assigns UUID v4 and persists directory projects" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    var assigned_uuid: []const u8 = "";
    {
        var reg = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg.deinit(io);

        try reg.upsertSource(arena, io, .{
            .kind = "dir",
            .name = "webgrep",
            .config = .{ .path = "." },
            .enabled = true,
        });

        const snap = try reg.snapshotAllSources(arena, io);
        try std.testing.expectEqual(@as(usize, 1), snap.len);
        try std.testing.expect(isValidUuid(snap[0].id));
        assigned_uuid = try arena.dupe(u8, snap[0].id);

        const json = try reg.buildSourcesJson(arena, io);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"dir\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"webgrep\"") != null);
    }

    // Re-load from disk and verify UUID persistence
    {
        var reg2 = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg2.deinit(io);

        const snap = try reg2.snapshotAllSources(arena, io);
        try std.testing.expectEqual(@as(usize, 1), snap.len);
        try std.testing.expectEqualStrings("dir", snap[0].kind);
        try std.testing.expectEqualStrings("webgrep", snap[0].name);
        try std.testing.expectEqualStrings(assigned_uuid, snap[0].id);
    }

    // Concurrent recordSearch across multiple threads (race-free atomic + mutex persistence)
    {
        var reg3 = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg3.deinit(io);

        const Worker = struct {
            fn run(r: *SourceRegistry, w_io: std.Io) void {
                for (0..25) |_| {
                    _ = r.recordSearch(w_io);
                }
            }
        };

        var threads: [4]?std.Thread = .{ null, null, null, null };
        for (0..4) |i| {
            threads[i] = std.Thread.spawn(.{}, Worker.run, .{ &reg3, io }) catch blk: {
                Worker.run(&reg3, io);
                break :blk null;
            };
        }
        for (0..4) |i| {
            if (threads[i]) |t| t.join();
        }
        try std.testing.expectEqual(@as(u64, 100), reg3.getSearchCount());
    }

    // Verify persisted searchCount after reload
    {
        var reg4 = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg4.deinit(io);
        try std.testing.expectEqual(@as(u64, 100), reg4.getSearchCount());
    }

    // Verify single-file data source (`kind: "file"`) auto-detection, persistence, and line preview
    {
        var f = try tmp.dir.createFile(io, "events.jsonl", .{ .truncate = true });
        var w_buf: [256]u8 = undefined;
        var fw = f.writer(io, &w_buf);
        try fw.interface.writeAll("{\"id\":1,\"msg\":\"alpha\"}\n{\"id\":2,\"msg\":\"beta\"}\n");
        try fw.interface.flush();
        f.close(io);

        const single_file_path = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{tmp_path});
        var reg5 = SourceRegistry.init(gpa, io, tmp_path, null);
        defer reg5.deinit(io);

        try reg5.upsertSource(arena, io, .{
            .kind = "file",
            .name = "",
            .config = .{ .path = single_file_path },
            .enabled = true,
        });

        const snap = try reg5.snapshotAllSources(arena, io);
        try std.testing.expectEqual(@as(usize, 2), snap.len);
        try std.testing.expectEqualStrings("file", snap[1].kind);
        try std.testing.expectEqualStrings("events.jsonl", snap[1].name);

        const preview_json = try reg5.buildLinePreviewJson(arena, io, "events.jsonl/events.jsonl", 2, 1);
        try std.testing.expect(std.mem.indexOf(u8, preview_json, "beta") != null);

        // Verify zero-disk-landing archive virtual path preview (`::`) and sandbox checks
        const payload = "line1_alpha\nline2_archive_hit\nline3_omega\n";
        const padded_payload = std.mem.alignForward(usize, payload.len, 512);
        const tar_buf = try arena.alloc(u8, 512 + padded_payload + 1024);
        @memset(tar_buf, 0);
        const entry_name = "inner/app.zig";
        @memcpy(tar_buf[0..entry_name.len], entry_name);
        @memcpy(tar_buf[100..107], "0000644");
        @memcpy(tar_buf[108..115], "0000000");
        @memcpy(tar_buf[116..123], "0000000");
        _ = try std.fmt.bufPrint(tar_buf[124..135], "{o:0>11}", .{payload.len});
        @memcpy(tar_buf[136..147], "00000000000");
        @memset(tar_buf[148..156], ' ');
        tar_buf[156] = '0';
        @memcpy(tar_buf[257..262], "ustar");
        @memcpy(tar_buf[263..265], "00");
        var sum: u64 = 0;
        for (tar_buf[0..512]) |b| sum += b;
        _ = try std.fmt.bufPrint(tar_buf[148..154], "{o:0>6}", .{sum});
        tar_buf[154] = 0;
        tar_buf[155] = ' ';
        @memcpy(tar_buf[512 .. 512 + payload.len], payload);

        var tf = try tmp.dir.createFile(io, "bundle.tar", .{ .truncate = true });
        var tw_buf: [512]u8 = undefined;
        var tfw = tf.writer(io, &tw_buf);
        try tfw.interface.writeAll(tar_buf);
        try tfw.interface.flush();
        tf.close(io);

        try reg5.upsertSource(arena, io, .{
            .kind = "dir",
            .name = "tmpdir",
            .config = .{ .path = tmp_path },
            .enabled = true,
        });

        // 1) `<source_name>/<archive>::<entry>`
        const arch_preview_1 = try reg5.buildLinePreviewJson(arena, io, "tmpdir/bundle.tar::inner/app.zig", 2, 1);
        try std.testing.expect(std.mem.indexOf(u8, arch_preview_1, "line2_archive_hit") != null);

        // 2) `<archive>::<entry>` resolved from registered directory source
        const arch_preview_2 = try reg5.buildLinePreviewJson(arena, io, "bundle.tar::inner/app.zig", 2, 1);
        try std.testing.expect(std.mem.indexOf(u8, arch_preview_2, "line2_archive_hit") != null);

        // 3) Reject traversal inside entry or outside source sandbox
        try std.testing.expectError(error.InvalidPath, reg5.buildLinePreviewJson(arena, io, "tmpdir/bundle.tar::../etc/passwd", 1, 1));
        try std.testing.expectError(error.InvalidPath, reg5.buildLinePreviewJson(arena, io, "/etc/passwd", 1, 1));
    }
}

test "SourceRegistry validates and persists pluginPreset and per-source plugin overrides" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "logs", .default_dir);
    try tmp.dir.createDir(io, "data", .default_dir);

    var buf1: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &buf1);
    const tmp_root = buf1[0..tmp_len];
    const logs_path = try std.fmt.allocPrint(arena, "{s}/logs", .{tmp_root});
    const data_path = try std.fmt.allocPrint(arena, "{s}/data", .{tmp_root});

    var src_id: []const u8 = "";
    var expected_sig: u64 = 0;

    {
        var reg = SourceRegistry.init(gpa, io, data_path, null);
        defer reg.deinit(io);

        // Reject unknown preset and unknown plugin ID cleanly
        try std.testing.expectError(error.InvalidPluginPreset, reg.upsertSource(arena, io, .{
            .kind = "dir",
            .name = "bad-preset",
            .config = .{ .path = logs_path, .pluginPreset = "turbo_magic" },
        }));
        try std.testing.expectError(error.InvalidPluginId, reg.upsertSource(arena, io, .{
            .kind = "dir",
            .name = "bad-plugin",
            .config = .{
                .path = logs_path,
                .pluginPreset = "timeseries",
                .plugins = .{ .enable = &.{"nonexistent_plugin"} },
            },
        }));

        // Valid preset + deduplicated overrides persist cleanly
        try reg.upsertSource(arena, io, .{
            .kind = "dir",
            .name = "prod-logs",
            .config = .{
                .path = logs_path,
                .pluginPreset = "timeseries",
                .plugins = .{
                    .enable = &.{ "sidecar_sketch", "sidecar_sketch" },
                    .disable = &.{"mtime_window"},
                },
            },
        });

        const snap = try reg.snapshotAllSources(arena, io);
        try std.testing.expectEqual(@as(usize, 1), snap.len);
        src_id = try arena.dupe(u8, snap[0].id);
        expected_sig = snap[0].plugin_sig;
        try std.testing.expect(expected_sig != 0);
        try std.testing.expectEqualStrings("timeseries", snap[0].plugin_preset);
        try std.testing.expectEqual(@as(usize, 1), snap[0].plugins_enable.len);
        try std.testing.expectEqualStrings("sidecar_sketch", snap[0].plugins_enable[0]);
        try std.testing.expectEqual(@as(usize, 1), snap[0].plugins_disable.len);
        try std.testing.expectEqualStrings("mtime_window", snap[0].plugins_disable[0]);

        const json = try reg.buildSourcesJson(arena, io);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"pluginPreset\":\"timeseries\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"sidecar_sketch\"") != null);
    }

    // Reload from disk and verify exact persistence, then edit name preserving existing preset/plugins
    {
        var reg2 = SourceRegistry.init(gpa, io, data_path, null);
        defer reg2.deinit(io);

        const snap2 = try reg2.snapshotAllSources(arena, io);
        try std.testing.expectEqual(@as(usize, 1), snap2.len);
        try std.testing.expectEqualStrings("timeseries", snap2[0].plugin_preset);
        try std.testing.expectEqual(expected_sig, snap2[0].plugin_sig);
        try std.testing.expectEqual(@as(usize, 1), snap2[0].plugins_enable.len);
        try std.testing.expectEqual(@as(usize, 1), snap2[0].plugins_disable.len);

        // Upsert leaving pluginPreset/plugins null preserves previous values
        try reg2.upsertSource(arena, io, .{
            .id = src_id,
            .kind = "dir",
            .name = "prod-logs-renamed",
            .config = .{ .path = logs_path },
        });
        const snap3 = try reg2.snapshotAllSources(arena, io);
        try std.testing.expectEqualStrings("prod-logs-renamed", snap3[0].name);
        try std.testing.expectEqualStrings("timeseries", snap3[0].plugin_preset);
        try std.testing.expectEqual(expected_sig, snap3[0].plugin_sig);

        // Explicit clear of overrides + switching preset to "code" recomputes plugin_sig
        try reg2.upsertSource(arena, io, .{
            .id = src_id,
            .kind = "dir",
            .name = "prod-logs-renamed",
            .config = .{ .path = logs_path },
            .pluginPreset = "code",
            .plugins = .{ .enable = &.{}, .disable = &.{} },
        });
        const snap4 = try reg2.snapshotAllSources(arena, io);
        try std.testing.expectEqualStrings("code", snap4[0].plugin_preset);
        try std.testing.expectEqual(@as(usize, 0), snap4[0].plugins_enable.len);
        try std.testing.expectEqual(@as(usize, 0), snap4[0].plugins_disable.len);
        try std.testing.expect(snap4[0].plugin_sig != expected_sig);
    }
}
