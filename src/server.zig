const std = @import("std");
const file_api = @import("file_api.zig");
const search_job = @import("search_job.zig");
const source_registry = @import("source_registry.zig");

pub const ServerContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    web_dir_path: []const u8,
    registry: *source_registry.SourceRegistry,
};

pub const cors_headers = [_]std.http.Header{
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "Content-Type" },
};

pub const json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "Content-Type" },
};

pub fn handleConnectionThread(ctx: *const ServerContext, stream: std.Io.net.Stream) void {
    handleConnection(ctx, stream) catch {};
}

pub fn handleConnection(ctx: *const ServerContext, stream: std.Io.net.Stream) !void {
    defer stream.close(ctx.io);

    const read_buf = try ctx.gpa.alloc(u8, 64 * 1024);
    defer ctx.gpa.free(read_buf);
    const write_buf = try ctx.gpa.alloc(u8, 64 * 1024);
    defer ctx.gpa.free(write_buf);

    var net_reader = stream.reader(ctx.io, read_buf);
    var net_writer = stream.writer(ctx.io, write_buf);
    var http_server = std.http.Server.init(&net_reader.interface, &net_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch break;

        if (request.head.method == .OPTIONS) {
            request.respond("", .{
                .status = .no_content,
                .extra_headers = &cors_headers,
            }) catch break;
            continue;
        }

        var req_arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
        defer req_arena_state.deinit();
        const req_arena = req_arena_state.allocator();

        const method = request.head.method;
        const target_copy = try req_arena.dupe(u8, request.head.target);
        const q_idx = std.mem.indexOfScalar(u8, target_copy, '?');
        const path_part = if (q_idx) |i| target_copy[0..i] else target_copy;
        const query_part = if (q_idx) |i| target_copy[i + 1 ..] else "";

        if (std.mem.eql(u8, path_part, "/api/ws")) {
            switch (request.upgradeRequested()) {
                .websocket => |maybe_key| {
                    const key = maybe_key orelse {
                        request.respond("{\"error\":\"missing Sec-WebSocket-Key\"}", .{
                            .status = .bad_request,
                            .extra_headers = &json_headers,
                        }) catch {};
                        break;
                    };
                    var ws = request.respondWebSocket(.{ .key = key }) catch break;
                    ws.flush() catch break;
                    handleWebSocket(ctx, &ws);
                    break;
                },
                else => {
                    request.respond("{\"error\":\"websocket upgrade required\"}", .{
                        .status = .upgrade_required,
                        .extra_headers = &json_headers,
                    }) catch {};
                    break;
                },
            }
        }

        if (std.mem.eql(u8, path_part, "/api/meta")) {
            const body = file_api.buildMetaJson(req_arena, "", "webgrep") catch {
                respondErrorJson(&request, .internal_server_error, "failed to build meta");
                continue;
            };
            request.respond(body, .{
                .status = .ok,
                .extra_headers = &json_headers,
            }) catch break;
            continue;
        }

        if ((std.mem.eql(u8, path_part, "/api/sources/complete") or std.mem.eql(u8, path_part, "/api/fs/dirs")) and method == .GET) {
            const kind_param = (file_api.getQueryParamAlloc(req_arena, query_part, "kind") catch null) orelse "dir";
            const q_param = (file_api.getQueryParamAlloc(req_arena, query_part, "q") catch null) orelse
                ((file_api.getQueryParamAlloc(req_arena, query_part, "path") catch null) orelse "");
            const body = ctx.registry.buildSourceCompletionJson(req_arena, ctx.io, kind_param, q_param) catch {
                respondErrorJson(&request, .internal_server_error, "failed to complete source query");
                continue;
            };
            request.respond(body, .{
                .status = .ok,
                .extra_headers = &json_headers,
            }) catch break;
            continue;
        }

        if (std.mem.eql(u8, path_part, "/api/sources")) {
            if (method == .GET) {
                const body = ctx.registry.buildSourcesJson(req_arena, ctx.io) catch {
                    respondErrorJson(&request, .internal_server_error, "failed to list sources");
                    continue;
                };
                request.respond(body, .{
                    .status = .ok,
                    .extra_headers = &json_headers,
                }) catch break;
                continue;
            } else if (method == .DELETE) {
                const id_param = (file_api.getQueryParamAlloc(req_arena, query_part, "id") catch null) orelse "";
                if (id_param.len > 0) {
                    ctx.registry.removeSource(ctx.io, id_param) catch {};
                }
                const body = ctx.registry.buildSourcesJson(req_arena, ctx.io) catch {
                    respondErrorJson(&request, .internal_server_error, "failed to list sources");
                    continue;
                };
                request.respond(body, .{
                    .status = .ok,
                    .extra_headers = &json_headers,
                }) catch break;
                continue;
            } else if (method == .POST or method == .PUT) {
                var body_buf: [8192]u8 = undefined;
                const body_reader = request.readerExpectContinue(&body_buf) catch {
                    respondErrorJson(&request, .bad_request, "failed to read request body");
                    break;
                };
                const raw_json = body_reader.allocRemaining(req_arena, .limited(256 * 1024)) catch {
                    respondErrorJson(&request, .bad_request, "invalid request body");
                    continue;
                };

                var parsed = std.json.parseFromSlice(source_registry.UpsertSourceRequest, req_arena, raw_json, .{
                    .ignore_unknown_fields = true,
                }) catch {
                    respondErrorJson(&request, .bad_request, "invalid JSON payload");
                    continue;
                };
                defer parsed.deinit();

                ctx.registry.upsertSource(req_arena, ctx.io, parsed.value) catch |err| {
                    switch (err) {
                        error.UnsupportedSourceKind => respondErrorJson(&request, .bad_request, "不支持的数据源类型 (kind)"),
                        error.EmptyPath => respondErrorJson(&request, .bad_request, "数据源路径不能为空"),
                        error.DirectoryNotFound => respondErrorJson(&request, .bad_request, "服务端目录不存在或无访问权限"),
                        error.FileNotFound => respondErrorJson(&request, .bad_request, "服务端单文件不存在或无访问权限"),
                        error.ExpectedDirFoundFile => respondErrorJson(&request, .bad_request, "当前选择的是「目录」类型，但输入路径是一个文件"),
                        error.ExpectedFileFoundDir => respondErrorJson(&request, .bad_request, "当前选择的是「单文件」类型，但输入路径是一个目录"),
                        else => respondErrorJson(&request, .internal_server_error, @errorName(err)),
                    }
                    continue;
                };

                const resp_body = ctx.registry.buildSourcesJson(req_arena, ctx.io) catch {
                    respondErrorJson(&request, .internal_server_error, "failed to list sources");
                    continue;
                };
                request.respond(resp_body, .{
                    .status = .ok,
                    .extra_headers = &json_headers,
                }) catch break;
                continue;
            }
        }

        if (std.mem.eql(u8, path_part, "/api/sources/toggle") and method == .POST) {
            const id_param = (file_api.getQueryParamAlloc(req_arena, query_part, "id") catch null);

            var body_buf: [4096]u8 = undefined;
            var toggle_req = source_registry.ToggleSourceRequest{
                .id = id_param,
            };
            if (request.readerExpectContinue(&body_buf)) |br| {
                if (br.allocRemaining(req_arena, .limited(64 * 1024))) |raw_json| {
                    if (raw_json.len > 0) {
                        if (std.json.parseFromSlice(source_registry.ToggleSourceRequest, req_arena, raw_json, .{
                            .ignore_unknown_fields = true,
                        })) |parsed| {
                            toggle_req = parsed.value;
                        } else |_| {}
                    }
                } else |_| {}
            } else |_| {}

            ctx.registry.toggleSource(ctx.io, toggle_req) catch {};

            const resp_body = ctx.registry.buildSourcesJson(req_arena, ctx.io) catch {
                respondErrorJson(&request, .internal_server_error, "failed to list sources");
                continue;
            };
            request.respond(resp_body, .{
                .status = .ok,
                .extra_headers = &json_headers,
            }) catch break;
            continue;
        }

        if (std.mem.eql(u8, path_part, "/api/sources/delete") and method == .POST) {
            var id_val: []const u8 = (file_api.getQueryParamAlloc(req_arena, query_part, "id") catch null) orelse "";
            var body_buf: [4096]u8 = undefined;
            if (request.readerExpectContinue(&body_buf)) |br| {
                if (br.allocRemaining(req_arena, .limited(64 * 1024))) |raw_json| {
                    if (raw_json.len > 0) {
                        if (std.json.parseFromSlice(source_registry.DeleteSourceRequest, req_arena, raw_json, .{
                            .ignore_unknown_fields = true,
                        })) |parsed| {
                            if (parsed.value.id.len > 0) id_val = parsed.value.id;
                        } else |_| {}
                    }
                } else |_| {}
            } else |_| {}

            if (id_val.len > 0) {
                ctx.registry.removeSource(ctx.io, id_val) catch {};
            }
            const resp_body = ctx.registry.buildSourcesJson(req_arena, ctx.io) catch {
                respondErrorJson(&request, .internal_server_error, "failed to list sources");
                continue;
            };
            request.respond(resp_body, .{
                .status = .ok,
                .extra_headers = &json_headers,
            }) catch break;
            continue;
        }

        if (std.mem.eql(u8, path_part, "/api/file")) {
            const rel_path = (file_api.getQueryParamAlloc(req_arena, query_part, "path") catch null) orelse "";
            const line_str = (file_api.getQueryParamAlloc(req_arena, query_part, "line") catch null) orelse "1";
            const ctx_str = (file_api.getQueryParamAlloc(req_arena, query_part, "context") catch null) orelse "60";

            const line_num = std.fmt.parseInt(u64, line_str, 10) catch 1;
            const ctx_num = std.fmt.parseInt(u64, ctx_str, 10) catch 60;

            const body = ctx.registry.buildLinePreviewJson(
                req_arena,
                ctx.io,
                rel_path,
                line_num,
                ctx_num,
            ) catch |err| {
                switch (err) {
                    error.InvalidPath => respondErrorJson(&request, .bad_request, "invalid path"),
                    error.FileNotFound, error.IsDir, error.NotDir => respondErrorJson(&request, .not_found, "source or file not found"),
                    else => respondErrorJson(&request, .internal_server_error, @errorName(err)),
                }
                continue;
            };
            request.respond(body, .{
                .status = .ok,
                .extra_headers = &json_headers,
            }) catch break;
            continue;
        }

        if (std.mem.startsWith(u8, path_part, "/api/")) {
            respondErrorJson(&request, .not_found, "unknown api endpoint");
            continue;
        }

        serveStaticAsset(ctx, req_arena, &request, path_part) catch break;
    }
}

fn respondErrorJson(request: *std.http.Server.Request, status: std.http.Status, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    std.json.Stringify.value(.{ .@"error" = msg }, .{}, &writer) catch return;
    request.respond(writer.buffered(), .{
        .status = status,
        .extra_headers = &json_headers,
    }) catch {};
}

const WsChannel = struct {
    ws: *std.http.Server.WebSocket,
    io: std.Io,
    write_mutex: std.Io.Mutex = .init,
    cancel_flag: std.atomic.Value(bool) = .init(false),

    fn sendText(ctx: *anyopaque, json_text: []const u8) anyerror!void {
        const self: *WsChannel = @ptrCast(@alignCast(ctx));
        if (self.cancel_flag.load(.acquire)) return error.Cancelled;
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.cancel_flag.load(.acquire)) return error.Cancelled;
        try self.ws.writeMessage(json_text, .text);
    }

    fn sendPong(self: *WsChannel, payload: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        try self.ws.writeMessage(payload, .pong);
    }
};

fn runSearchWorker(ctx: *const ServerContext, channel: *WsChannel, json_copy: []u8) void {
    defer ctx.gpa.free(json_copy);
    const sender = search_job.FrameSender{
        .ctx = channel,
        .sendFn = WsChannel.sendText,
    };
    search_job.executeSearchJson(
        ctx.gpa,
        ctx.io,
        std.Io.Dir.cwd(),
        ctx.registry,
        json_copy,
        &channel.cancel_flag,
        sender,
    ) catch {};
}

fn handleWebSocket(ctx: *const ServerContext, ws: *std.http.Server.WebSocket) void {
    var channel = WsChannel{
        .ws = ws,
        .io = ctx.io,
    };
    var active_thread: ?std.Thread = null;
    defer {
        channel.cancel_flag.store(true, .release);
        if (active_thread) |t| t.join();
    }

    const Envelope = struct {
        type: []const u8 = "",
    };

    while (true) {
        const msg = ws.readSmallMessage() catch break;
        switch (msg.opcode) {
            .ping => {
                channel.sendPong(msg.data) catch break;
            },
            .text, .binary => {
                var env_parsed = std.json.parseFromSlice(Envelope, ctx.gpa, msg.data, .{
                    .ignore_unknown_fields = true,
                }) catch {
                    const copy = ctx.gpa.dupe(u8, msg.data) catch continue;
                    runSearchWorker(ctx, &channel, copy);
                    continue;
                };
                const msg_type = env_parsed.value.type;
                const is_cancel = std.mem.eql(u8, msg_type, "cancel");
                const is_search = std.mem.eql(u8, msg_type, "search") or msg_type.len == 0;
                env_parsed.deinit();

                if (is_cancel) {
                    channel.cancel_flag.store(true, .release);
                    if (active_thread) |t| {
                        t.join();
                        active_thread = null;
                    }
                } else if (is_search) {
                    if (active_thread) |t| {
                        channel.cancel_flag.store(true, .release);
                        t.join();
                        active_thread = null;
                    }
                    channel.cancel_flag.store(false, .release);
                    const json_copy = ctx.gpa.dupe(u8, msg.data) catch continue;
                    active_thread = std.Thread.spawn(.{}, runSearchWorker, .{ ctx, &channel, json_copy }) catch blk: {
                        runSearchWorker(ctx, &channel, json_copy);
                        break :blk null;
                    };
                }
            },
            else => {},
        }
    }
}

pub fn mimeTypeForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm"))
        return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".mjs"))
        return "application/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css"))
        return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg"))
        return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".json") or std.mem.endsWith(u8, path, ".map"))
        return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".woff2"))
        return "font/woff2";
    if (std.mem.endsWith(u8, path, ".ico"))
        return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".png"))
        return "image/png";
    if (std.mem.endsWith(u8, path, ".txt"))
        return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

const fallback_diagnostic_html =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8" />
    \\  <title>webgrep backend running</title>
    \\  <style>
    \\    body { font-family: system-ui, -apple-system, sans-serif; background: #0b0e14; color: #e6edf3; padding: 3rem; }
    \\    code { background: #161b22; padding: 0.2rem 0.4rem; border-radius: 4px; color: #79c0ff; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <h1>webgrep Zig 0.17.0 backend is online</h1>
    \\  <p>API endpoints active: <code>/api/meta</code>, <code>/api/sources</code>, <code>/api/fs/dirs</code>, <code>/api/file</code>, <code>/api/ws</code>.</p>
    \\  <p>Build frontend assets in <code>web/dist</code> or connect via Vite dev server.</p>
    \\</body>
    \\</html>
;

fn serveStaticAsset(
    ctx: *const ServerContext,
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    path_part: []const u8,
) !void {
    const stripped = if (std.mem.startsWith(u8, path_part, "/")) path_part[1..] else path_part;
    const clean_rel = file_api.sanitizeRelPath(stripped) catch {
        respondErrorJson(request, .bad_request, "invalid asset path");
        return;
    };
    const target_rel = if (clean_rel.len == 0) "index.html" else clean_rel;

    var web_dir = std.Io.Dir.cwd().openDir(ctx.io, ctx.web_dir_path, .{}) catch {
        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        };
        try request.respond(fallback_diagnostic_html, .{
            .status = .ok,
            .extra_headers = &headers,
        });
        return;
    };
    defer web_dir.close(ctx.io);

    const max_asset_bytes = std.Io.Limit.limited(32 * 1024 * 1024);
    if (web_dir.readFileAlloc(ctx.io, target_rel, arena, max_asset_bytes)) |bytes| {
        const mime = mimeTypeForPath(target_rel);
        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = mime },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        };
        try request.respond(bytes, .{
            .status = .ok,
            .extra_headers = &headers,
        });
        return;
    } else |_| {}

    if (web_dir.readFileAlloc(ctx.io, "index.html", arena, max_asset_bytes)) |index_bytes| {
        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        };
        try request.respond(index_bytes, .{
            .status = .ok,
            .extra_headers = &headers,
        });
        return;
    } else |_| {}

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "access-control-allow-origin", .value = "*" },
    };
    try request.respond(fallback_diagnostic_html, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}
