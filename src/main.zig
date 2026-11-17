const std = @import("std");
const auth = @import("auth.zig");
const docker_logs = @import("docker_logs.zig");
const file_api = @import("file_api.zig");
const mcp = @import("mcp.zig");
const net_bind = @import("net_bind.zig");
const search_job = @import("search_job.zig");
const server = @import("server.zig");
const source_registry = @import("source_registry.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const home_dir_opt: ?[]const u8 = init.environ_map.get("HOME");
    var data_dir_arg: []const u8 = init.environ_map.get("WEBGREP_DATA_DIR") orelse "data";
    var host_arg: []const u8 = init.environ_map.get("WEBGREP_HOST") orelse net_bind.DEFAULT_HOST_SPEC;
    var port_arg: u16 = if (init.environ_map.get("WEBGREP_PORT")) |p|
        (std.fmt.parseInt(u16, p, 10) catch 8787)
    else
        8787;
    const env_web_dir = init.environ_map.get("WEBGREP_WEB_DIR");
    var web_dir_arg: []const u8 = env_web_dir orelse "web/dist";
    var web_dir_explicit: bool = (env_web_dir != null);
    var password_arg: ?[]const u8 = init.environ_map.get("WEBGREP_PASSWORD");
    var mcp_token_arg: ?[]const u8 = init.environ_map.get("WEBGREP_MCP_TOKEN");
    var mcp_stdio_mode = false;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.skip(); // executable name

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--data-dir") or std.mem.eql(u8, arg, "-d")) {
            if (args_it.next()) |val| data_dir_arg = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (args_it.next()) |val| host_arg = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (args_it.next()) |val| {
                port_arg = std.fmt.parseInt(u16, val, 10) catch port_arg;
            }
        } else if (std.mem.eql(u8, arg, "--web-dir")) {
            if (args_it.next()) |val| {
                web_dir_arg = try arena.dupe(u8, val);
                web_dir_explicit = true;
            }
        } else if (std.mem.eql(u8, arg, "--password")) {
            if (args_it.next()) |val| password_arg = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, arg, "--mcp-token")) {
            if (args_it.next()) |val| mcp_token_arg = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, arg, "--mcp") or std.mem.eql(u8, arg, "--mcp-stdio")) {
            mcp_stdio_mode = true;
        }
    }

    const auth_guard = auth.AuthGuard.init(password_arg, mcp_token_arg);

    var registry = source_registry.SourceRegistry.init(
        gpa,
        io,
        data_dir_arg,
        home_dir_opt,
    );
    registry.docker_host = init.environ_map.get("DOCKER_HOST");
    registry.xdg_runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR");
    defer registry.deinit(io);

    var mcp_service = try mcp.McpService.init(gpa, io, data_dir_arg, &registry);
    mcp_service.token_required = auth_guard.mcpTokenRequired();
    defer mcp_service.deinit(io);

    if (mcp_stdio_mode) {
        try mcp.runStdioBridge(gpa, io, &mcp_service, port_arg, mcp_token_arg);
        return;
    }

    std.debug.print(
        "webgrep auth: web_password={s}, mcp_token={s}\n",
        .{
            if (auth_guard.webPasswordRequired()) "enabled" else "disabled",
            if (auth_guard.mcpTokenRequired()) "enabled" else "disabled",
        },
    );

    const ctx = server.ServerContext{
        .gpa = gpa,
        .io = io,
        .web_dir_path = web_dir_arg,
        .web_dir_explicit = web_dir_explicit,
        .registry = &registry,
        .mcp = &mcp_service,
        .auth = auth_guard,
    };

    try net_bind.runListeners(&ctx, host_arg, port_arg);
}

test {
    _ = auth;
    _ = docker_logs;
    _ = file_api;
    _ = mcp;
    _ = net_bind;
    _ = search_job;
    _ = server;
    _ = source_registry;
    _ = @import("search_cache.zig");
    _ = @import("time_parser.zig");
}
