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

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = exe_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "libwebgrep", .module = libwebgrep_mod },
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
