const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });
    const exe_optimize: std.builtin.OptimizeMode = if (optimize == .debug) .fast else optimize;

    const libwebgrep_dep = b.dependency("libwebgrep", .{
        .target = target,
        .optimize = exe_optimize,
    });
    const libwebgrep_mod = libwebgrep_dep.module("libwebgrep");

    const web_assets_mod = buildEmbeddedWebModule(b);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = exe_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "libwebgrep", .module = libwebgrep_mod },
            .{ .name = "web_assets", .module = web_assets_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "webgrep",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the webgrep HTTP + WebSocket server");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = exe_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "libwebgrep", .module = libwebgrep_mod },
            .{ .name = "web_assets", .module = web_assets_mod },
        },
    });

    const exe_tests = b.addTest(.{
        .name = "webgrep-test",
        .root_module = test_mod,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run webgrep unit tests");
    test_step.dependOn(&run_exe_tests.step);
}

fn appendEscapedZigString(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    raw: []const u8,
) !void {
    for (raw) |ch| {
        switch (ch) {
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, ch),
        }
    }
}

fn buildEmbeddedWebModule(b: *std.Build) *std.Build.Module {
    const wf = b.addWriteFiles();
    const io = b.graph.io;

    var code: std.ArrayList(u8) = .empty;
    code.appendSlice(b.allocator,
        \\const std = @import("std");
        \\
        \\pub const Asset = struct {
        \\    path: []const u8,
        \\    bytes: []const u8,
        \\};
        \\
        \\pub const assets = [_]Asset{
        \\
    ) catch @panic("OOM");

    const dist_sub = if (b.root.sub_path.len == 0) "web/dist" else b.fmt("{s}/web/dist", .{b.root.sub_path});
    if (b.root.root_dir.handle.openDir(io, dist_sub, .{ .iterate = true })) |dist_dir_val| {
        var dist_dir = dist_dir_val;
        defer dist_dir.close(io);

        var paths: std.ArrayList([]const u8) = .empty;
        var walker = dist_dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();

        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.eql(u8, entry.basename, ".DS_Store")) continue;
            const norm = b.allocator.dupe(u8, entry.path) catch @panic("OOM");
            for (norm) |*c| {
                if (c.* == '\\') c.* = '/';
            }
            paths.append(b.allocator, norm) catch @panic("OOM");
        }

        std.mem.sort([]const u8, paths.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);

        for (paths.items) |rel| {
            const src_rel = b.fmt("web/dist/{s}", .{rel});
            _ = wf.addCopyFile(b.path(src_rel), rel);
            code.appendSlice(b.allocator, "    .{ .path = \"") catch @panic("OOM");
            appendEscapedZigString(&code, b.allocator, rel) catch @panic("OOM");
            code.appendSlice(b.allocator, "\", .bytes = @embedFile(\"") catch @panic("OOM");
            appendEscapedZigString(&code, b.allocator, rel) catch @panic("OOM");
            code.appendSlice(b.allocator, "\") },\n") catch @panic("OOM");
        }
    } else |_| {}

    code.appendSlice(b.allocator,
        \\};
        \\
        \\pub fn get(rel_path: []const u8) ?[]const u8 {
        \\    for (assets) |item| {
        \\        if (std.mem.eql(u8, item.path, rel_path)) return item.bytes;
        \\    }
        \\    return null;
        \\}
        \\
    ) catch @panic("OOM");

    const assets_zig = wf.add("embedded_assets.zig", code.items);
    return b.createModule(.{
        .root_source_file = assets_zig,
    });
}
