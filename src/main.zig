const std = @import("std");
const file_api = @import("file_api.zig");
const search_job = @import("search_job.zig");
const server = @import("server.zig");
const source_registry = @import("source_registry.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const home_dir_opt: ?[]const u8 = init.environ_map.get("HOME");
    var data_dir_arg: []const u8 = init.environ_map.get("WEBGREP_DATA_DIR") orelse "data";
    var host_arg: []const u8 = init.environ_map.get("WEBGREP_HOST") orelse "127.0.0.1";
    var port_arg: u16 = if (init.environ_map.get("WEBGREP_PORT")) |p|
        (std.fmt.parseInt(u16, p, 10) catch 8787)
    else
        8787;
    var web_dir_arg: []const u8 = init.environ_map.get("WEBGREP_WEB_DIR") orelse "web/dist";

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
            if (args_it.next()) |val| web_dir_arg = try arena.dupe(u8, val);
        }
    }

    var registry = source_registry.SourceRegistry.init(
        gpa,
        io,
        data_dir_arg,
        home_dir_opt,
    );
    defer registry.deinit(io);

    const ctx = server.ServerContext{
        .gpa = gpa,
        .io = io,
        .web_dir_path = web_dir_arg,
        .registry = &registry,
    };

    const addr = try std.Io.net.IpAddress.parse(host_arg, port_arg);
    var net_server = try addr.listen(io, .{ .reuse_address = true });
    defer net_server.deinit(io);

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    stdout_writer.interface.print(
        "webgrep listening on http://{s}:{d}\n",
        .{ host_arg, port_arg },
    ) catch {};
    stdout_writer.interface.flush() catch {};

    while (true) {
        const stream = net_server.accept(io) catch continue;
        if (std.Thread.spawn(.{}, server.handleConnectionThread, .{ &ctx, stream })) |t| {
            t.detach();
        } else |_| {
            server.handleConnectionThread(&ctx, stream);
        }
    }
}

test {
    _ = file_api;
    _ = search_job;
    _ = server;
    _ = source_registry;
}
