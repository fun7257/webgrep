const std = @import("std");
const types = @import("types.zig");
const rpc = @import("rpc_helpers.zig");
const service_mod = @import("service.zig");

const McpService = service_mod.McpService;
const ENDPOINT_PATH = types.ENDPOINT_PATH;
const buildJsonRpcErrorAlloc = rpc.buildJsonRpcErrorAlloc;

pub fn runStdioBridge(
    gpa: std.mem.Allocator,
    io: std.Io,
    local_svc: *McpService,
    daemon_port: u16,
    mcp_token: ?[]const u8,
) !void {
    const stdin_file = std.Io.File.stdin();
    const stdout_file = std.Io.File.stdout();

    const clean_token: ?[]const u8 = if (mcp_token) |raw_tok| blk: {
        const trimmed = std.mem.trim(u8, raw_tok, " \t\r\n");
        break :blk if (trimmed.len > 0) trimmed else null;
    } else null;

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(gpa);

    var client = std.http.Client{
        .allocator = gpa,
        .io = io,
    };
    defer client.deinit();

    const daemon_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/mcp", .{daemon_port});
    defer gpa.free(daemon_url);

    var read_chunk: [8192]u8 = undefined;
    while (true) {
        const n = stdin_file.readStreaming(io, &.{&read_chunk}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (n > 0) {
            try line_buf.appendSlice(gpa, read_chunk[0..n]);
        }

        while (std.mem.indexOfScalar(u8, line_buf.items, '\n')) |nl_idx| {
            const line = line_buf.items[0..nl_idx];
            try processStdioLine(gpa, io, local_svc, &client, daemon_url, clean_token, stdout_file, line);
            const rest_len = line_buf.items.len - (nl_idx + 1);
            if (rest_len > 0) {
                std.mem.copyForwards(u8, line_buf.items[0..rest_len], line_buf.items[nl_idx + 1 ..]);
            }
            line_buf.items.len = rest_len;
        }

        if (n == 0) {
            if (line_buf.items.len > 0) {
                try processStdioLine(gpa, io, local_svc, &client, daemon_url, clean_token, stdout_file, line_buf.items);
                line_buf.clearRetainingCapacity();
            }
            break;
        }
    }
}

fn processStdioLine(
    gpa: std.mem.Allocator,
    io: std.Io,
    local_svc: *McpService,
    client: *std.http.Client,
    daemon_url: []const u8,
    mcp_token: ?[]const u8,
    stdout_file: std.Io.File,
    raw_line: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
    if (trimmed.len == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Forward to running HTTP daemon first so UI sees live call logs; fallback to local service if offline.
    var resp_body_writer: std.Io.Writer.Allocating = .init(arena);
    var hdrs_buf: [4]std.http.Header = undefined;
    hdrs_buf[0] = .{ .name = "content-type", .value = "application/json" };
    hdrs_buf[1] = .{ .name = "accept", .value = "application/json, text/event-stream" };
    hdrs_buf[2] = .{ .name = "user-agent", .value = "webgrep-mcp-stdio/0.5.0" };
    var hdr_count: usize = 3;
    if (mcp_token) |tok| {
        const bearer_val = try std.fmt.allocPrint(arena, "Bearer {s}", .{tok});
        hdrs_buf[hdr_count] = .{ .name = "authorization", .value = bearer_val };
        hdr_count += 1;
    }
    const forwarded_ok = blk: {
        const res = client.fetch(.{
            .location = .{ .url = daemon_url },
            .method = .POST,
            .payload = trimmed,
            .extra_headers = hdrs_buf[0..hdr_count],
            .response_writer = &resp_body_writer.writer,
        }) catch break :blk false;
        if (res.status == .accepted) {
            return;
        }
        break :blk (res.status == .ok);
    };

    const out_json: ?[]const u8 = if (forwarded_ok)
        resp_body_writer.written()
    else
        try local_svc.handleRpcPayload(arena, io, trimmed, "stdio");

    if (out_json) |json_line| {
        if (json_line.len == 0) return;
        try stdout_file.writeStreamingAll(io, json_line);
        try stdout_file.writeStreamingAll(io, "\n");
    }
}
