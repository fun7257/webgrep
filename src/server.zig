const std = @import("std");
const web_assets = @import("web_assets");
const auth_mod = @import("auth.zig");
const file_api = @import("file_api.zig");
const mcp_mod = @import("mcp.zig");
const search_job = @import("search_job.zig");
const source_registry = @import("source_registry.zig");
const time_parser = @import("time_parser.zig");

pub const ServerContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    web_dir_path: []const u8,
    web_dir_explicit: bool = false,
    registry: *source_registry.SourceRegistry,
    mcp: ?*mcp_mod.McpService = null,
    auth: auth_mod.AuthGuard = .{},
};

pub const cors_headers = [_]std.http.Header{
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version, Authorization, X-MCP-Token" },
    .{ .name = "access-control-expose-headers", .value = "Mcp-Session-Id, MCP-Protocol-Version" },
};

pub const json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version, Authorization, X-MCP-Token" },
    .{ .name = "access-control-expose-headers", .value = "Mcp-Session-Id, MCP-Protocol-Version" },
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

        // Must inspect headers BEFORE readerExpectContinue or respondWebSocket.
        var cookie_hdr: []const u8 = "";
        var auth_hdr: []const u8 = "";
        var x_mcp_token_hdr: []const u8 = "";
        var x_forwarded_proto_hdr: []const u8 = "";
        var user_agent_hdr: []const u8 = "";
        {
            var hdr_it = request.iterateHeaders();
            while (hdr_it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
                    cookie_hdr = try req_arena.dupe(u8, h.value);
                } else if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                    auth_hdr = try req_arena.dupe(u8, h.value);
                } else if (std.ascii.eqlIgnoreCase(h.name, "x-mcp-token")) {
                    x_mcp_token_hdr = try req_arena.dupe(u8, h.value);
                } else if (std.ascii.eqlIgnoreCase(h.name, "x-forwarded-proto")) {
                    x_forwarded_proto_hdr = try req_arena.dupe(u8, h.value);
                } else if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
                    user_agent_hdr = try req_arena.dupe(u8, h.value);
                }
            }
        }
        const now_sec: u64 = time_parser.currentUnixNano(ctx.io) / 1_000_000_000;

        if (std.mem.eql(u8, path_part, "/api/auth/status") and method == .GET) {
            const status_body = file_api.stringifyAlloc(req_arena, auth_mod.AuthStatusDto{
                .authRequired = ctx.auth.webPasswordRequired(),
                .authenticated = ctx.auth.isWebRequestAuthenticated(cookie_hdr, auth_hdr, now_sec),
                .mcpTokenRequired = ctx.auth.mcpTokenRequired(),
            }) catch {
                respondErrorJson(&request, .internal_server_error, "failed to encode auth status");
                continue;
            };
            request.respond(status_body, .{
                .status = .ok,
                .extra_headers = &json_headers,
            }) catch break;
            continue;
        }

        if (std.mem.eql(u8, path_part, "/api/auth/login") and method == .POST) {
            if (!ctx.auth.webPasswordRequired()) {
                const body = file_api.stringifyAlloc(req_arena, .{
                    .ok = true,
                    .authRequired = false,
                    .authenticated = true,
                    .mcpTokenRequired = ctx.auth.mcpTokenRequired(),
                }) catch "{\"ok\":true}";
                request.respond(body, .{
                    .status = .ok,
                    .extra_headers = &json_headers,
                }) catch break;
                continue;
            }

            var body_buf: [2048]u8 = undefined;
            const body_reader = request.readerExpectContinue(&body_buf) catch {
                respondErrorJson(&request, .bad_request, "failed to read request body");
                break;
            };
            const raw_json = body_reader.allocRemaining(req_arena, .limited(16 * 1024)) catch {
                respondErrorJson(&request, .bad_request, "invalid request body");
                continue;
            };
            var parsed = std.json.parseFromSlice(auth_mod.LoginRequest, req_arena, raw_json, .{
                .ignore_unknown_fields = true,
            }) catch {
                respondErrorJson(&request, .bad_request, "invalid JSON payload");
                continue;
            };
            defer parsed.deinit();

            const pw_candidate = parsed.value.password orelse "";
            if (!ctx.auth.verifyWebPassword(pw_candidate)) {
                request.respond("{\"ok\":false,\"error\":\"Invalid password\"}", .{
                    .status = .unauthorized,
                    .extra_headers = &json_headers,
                }) catch break;
                continue;
            }

            const tok = ctx.auth.issueSessionTokenAlloc(req_arena, ctx.io, now_sec) catch {
                respondErrorJson(&request, .internal_server_error, "failed to issue session");
                continue;
            };
            const is_https = std.ascii.eqlIgnoreCase(std.mem.trim(u8, x_forwarded_proto_hdr, " \t\r\n"), "https");
            const set_cookie = auth_mod.buildSetCookieHeaderAlloc(req_arena, tok, is_https) catch {
                respondErrorJson(&request, .internal_server_error, "failed to build cookie");
                continue;
            };
            var resp_hdrs: [json_headers.len + 1]std.http.Header = undefined;
            @memcpy(resp_hdrs[0..json_headers.len], &json_headers);
            resp_hdrs[json_headers.len] = .{ .name = "set-cookie", .value = set_cookie };

            const ok_body = file_api.stringifyAlloc(req_arena, .{
                .ok = true,
                .authRequired = true,
                .authenticated = true,
                .mcpTokenRequired = ctx.auth.mcpTokenRequired(),
            }) catch "{\"ok\":true}";
            request.respond(ok_body, .{
                .status = .ok,
                .extra_headers = &resp_hdrs,
            }) catch break;
            continue;
        }

        if (std.mem.eql(u8, path_part, "/api/auth/logout") and method == .POST) {
            var resp_hdrs: [json_headers.len + 1]std.http.Header = undefined;
            @memcpy(resp_hdrs[0..json_headers.len], &json_headers);
            resp_hdrs[json_headers.len] = .{ .name = "set-cookie", .value = auth_mod.buildClearCookieHeader() };
            request.respond("{\"ok\":true}", .{
                .status = .ok,
                .extra_headers = &resp_hdrs,
            }) catch break;
            continue;
        }

        if (std.mem.eql(u8, path_part, "/mcp")) {
            const mcp_authorized = blk: {
                if (!ctx.auth.mcpTokenRequired()) break :blk true;
                if (ctx.auth.isMcpRequestAuthenticated(auth_hdr, x_mcp_token_hdr)) break :blk true;
                if (file_api.getQueryParamAlloc(req_arena, query_part, "token") catch null) |q_tok| {
                    if (q_tok.len > 0 and ctx.auth.verifyMcpToken(q_tok)) break :blk true;
                }
                break :blk false;
            };
            if (!mcp_authorized) {
                if (ctx.mcp) |mcp_svc| {
                    mcp_svc.recordUnauthorizedAttempt(ctx.io, @tagName(method), user_agent_hdr);
                }
                var unauth_hdrs: [json_headers.len + 1]std.http.Header = undefined;
                @memcpy(unauth_hdrs[0..json_headers.len], &json_headers);
                unauth_hdrs[json_headers.len] = .{ .name = "www-authenticate", .value = "Bearer realm=\"webgrep-mcp\"" };
                request.respond(
                    "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"Unauthorized: invalid or missing MCP token\"}}",
                    .{
                        .status = .unauthorized,
                        .extra_headers = &unauth_hdrs,
                    },
                ) catch break;
                continue;
            }
            if (ctx.mcp) |mcp_svc| {
                mcp_svc.handleHttpEndpoint(req_arena, ctx.io, &request, &cors_headers, &json_headers) catch break;
            } else {
                respondErrorJson(&request, .not_found, "MCP service disabled");
            }
            continue;
        }

        if (!ctx.auth.isWebRequestAuthenticated(cookie_hdr, auth_hdr, now_sec)) {
            if (std.mem.eql(u8, path_part, "/api/ws") or std.mem.startsWith(u8, path_part, "/api/")) {
                respondErrorJson(&request, .unauthorized, "unauthorized");
                if (std.mem.eql(u8, path_part, "/api/ws")) break;
                continue;
            }
        }

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

        if (std.mem.eql(u8, path_part, "/api/mcp") and method == .GET) {
            if (ctx.mcp) |mcp_svc| {
                const body = mcp_svc.buildStateJson(req_arena, ctx.io) catch {
                    respondErrorJson(&request, .internal_server_error, "failed to read MCP state");
                    continue;
                };
                request.respond(body, .{
                    .status = .ok,
                    .extra_headers = &json_headers,
                }) catch break;
            } else {
                respondErrorJson(&request, .not_found, "MCP service disabled");
            }
            continue;
        }

        if (std.mem.eql(u8, path_part, "/api/mcp/config") and (method == .POST or method == .PUT)) {
            const mcp_svc = ctx.mcp orelse {
                respondErrorJson(&request, .not_found, "MCP service disabled");
                continue;
            };
            var body_buf: [4096]u8 = undefined;
            const body_reader = request.readerExpectContinue(&body_buf) catch {
                respondErrorJson(&request, .bad_request, "failed to read request body");
                break;
            };
            const raw_json = body_reader.allocRemaining(req_arena, .limited(64 * 1024)) catch {
                respondErrorJson(&request, .bad_request, "invalid request body");
                continue;
            };
            var parsed = std.json.parseFromSlice(mcp_mod.UpdateMcpConfigRequest, req_arena, raw_json, .{
                .ignore_unknown_fields = true,
            }) catch {
                respondErrorJson(&request, .bad_request, "invalid JSON payload");
                continue;
            };
            defer parsed.deinit();

            mcp_svc.updateConfig(ctx.io, parsed.value) catch {
                respondErrorJson(&request, .internal_server_error, "failed to update MCP config");
                continue;
            };
            const resp_body = mcp_svc.buildStateJson(req_arena, ctx.io) catch {
                respondErrorJson(&request, .internal_server_error, "failed to read MCP state");
                continue;
            };
            request.respond(resp_body, .{
                .status = .ok,
                .extra_headers = &json_headers,
            }) catch break;
            continue;
        }

        if ((std.mem.eql(u8, path_part, "/api/mcp/logs/clear") and method == .POST) or
            (std.mem.eql(u8, path_part, "/api/mcp/logs") and method == .DELETE))
        {
            const mcp_svc = ctx.mcp orelse {
                respondErrorJson(&request, .not_found, "MCP service disabled");
                continue;
            };
            mcp_svc.clearLogs(ctx.io);
            const resp_body = mcp_svc.buildStateJson(req_arena, ctx.io) catch {
                respondErrorJson(&request, .internal_server_error, "failed to read MCP state");
                continue;
            };
            request.respond(resp_body, .{
                .status = .ok,
                .extra_headers = &json_headers,
            }) catch break;
            continue;
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

                const maybe_tf: ?[]const u8 = if (parsed.value.config) |cfg|
                    cfg.timeFormat
                else
                    parsed.value.timeFormat;
                if (maybe_tf) |raw_tf| {
                    const trimmed_tf = std.mem.trim(u8, raw_tf[0..@min(raw_tf.len, 256)], " \t\r\n");
                    if (trimmed_tf.len > 0 and !std.ascii.eqlIgnoreCase(trimmed_tf, "auto")) {
                        var tp_err: ?[]const u8 = null;
                        const tp = ctx.gpa.create(time_parser.CompiledTimeParser) catch {
                            respondErrorJson(&request, .internal_server_error, "OOM validating time format");
                            continue;
                        };
                        tp.* = .{};
                        defer {
                            tp.deinit(ctx.gpa);
                            ctx.gpa.destroy(tp);
                        }
                        tp.initInPlace(ctx.gpa, req_arena, trimmed_tf, &tp_err) catch {
                            respondErrorJson(&request, .bad_request, tp_err orelse "无效的行时间解析格式");
                            continue;
                        };
                    }
                }

                ctx.registry.upsertSource(req_arena, ctx.io, parsed.value) catch |err| {
                    switch (err) {
                        error.UnsupportedSourceKind => respondErrorJson(&request, .bad_request, "不支持的数据源类型 (kind)"),
                        error.EmptyPath => respondErrorJson(&request, .bad_request, "数据源路径不能为空"),
                        error.DirectoryNotFound => respondErrorJson(&request, .bad_request, "服务端目录不存在或无访问权限"),
                        error.FileNotFound => respondErrorJson(&request, .bad_request, "服务端单文件不存在或无访问权限"),
                        error.ExpectedDirFoundFile => respondErrorJson(&request, .bad_request, "当前选择的是「目录」类型，但输入路径是一个文件"),
                        error.ExpectedFileFoundDir => respondErrorJson(&request, .bad_request, "当前选择的是「单文件」类型，但输入路径是一个目录"),
                        error.DockerUnavailable => respondErrorJson(&request, .bad_request, "未检测到可用的 Docker 守护进程或目标容器（请确认 Docker / OrbStack / Colima 已启动且 Socket 可访问）"),
                        error.InvalidDockerEndpoint => respondErrorJson(&request, .bad_request, "无效的 Docker 连接地址（支持留空自动识别、unix://、tcp:// 或容器目录路径）"),
                        error.InvalidPluginPreset => respondErrorJson(&request, .bad_request, "无效的预过滤预设 (pluginPreset)"),
                        error.InvalidPluginId => respondErrorJson(&request, .bad_request, "包含未知的预过滤插件 ID"),
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

        if (std.mem.eql(u8, path_part, "/api/time/preview")) {
            const TimePreviewRequest = struct {
                format: []const u8 = "",
                sample: []const u8 = "",
                tzOffsetMin: i16 = 0,
            };
            var format_val: []const u8 = (file_api.getQueryParamAlloc(req_arena, query_part, "format") catch null) orelse "";
            var sample_val: []const u8 = (file_api.getQueryParamAlloc(req_arena, query_part, "sample") catch null) orelse "";
            var tz_val: i16 = 0;
            if (file_api.getQueryParamAlloc(req_arena, query_part, "tzOffsetMin") catch null) |tz_str| {
                tz_val = std.fmt.parseInt(i16, tz_str, 10) catch 0;
            }
            if (method == .POST) {
                var body_buf: [4096]u8 = undefined;
                if (request.readerExpectContinue(&body_buf)) |br| {
                    if (br.allocRemaining(req_arena, .limited(64 * 1024))) |raw_json| {
                        if (raw_json.len > 0) {
                            if (std.json.parseFromSlice(TimePreviewRequest, req_arena, raw_json, .{
                                .ignore_unknown_fields = true,
                            })) |parsed| {
                                format_val = parsed.value.format;
                                sample_val = parsed.value.sample;
                                tz_val = parsed.value.tzOffsetMin;
                            } else |_| {}
                        }
                    } else |_| {}
                } else |_| {}
            }

            const now_ns = time_parser.currentUnixNano(ctx.io);
            const body = time_parser.buildTimePreviewJson(
                ctx.gpa,
                req_arena,
                format_val,
                sample_val,
                tz_val,
                now_ns,
            ) catch |err| {
                respondErrorJson(&request, .internal_server_error, @errorName(err));
                continue;
            };
            request.respond(body, .{
                .status = .ok,
                .extra_headers = &json_headers,
            }) catch break;
            continue;
        }

        if (std.mem.eql(u8, path_part, "/api/file") or std.mem.eql(u8, path_part, "/api/context")) {
            const rel_path = (file_api.getQueryParamAlloc(req_arena, query_part, "path") catch null) orelse "";
            const line_str = (file_api.getQueryParamAlloc(req_arena, query_part, "line") catch null) orelse "1";
            const ctx_str = (file_api.getQueryParamAlloc(req_arena, query_part, "context") catch null) orelse "60";
            const since_str_opt = file_api.getQueryParamAlloc(req_arena, query_part, "since") catch null;

            const line_num = std.fmt.parseInt(u64, line_str, 10) catch 1;
            const ctx_num = std.fmt.parseInt(u64, ctx_str, 10) catch 60;
            const parseOptU64 = struct {
                fn get(arena: std.mem.Allocator, qp: []const u8, name: []const u8) ?u64 {
                    const raw = (file_api.getQueryParamAlloc(arena, qp, name) catch null) orelse return null;
                    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                    if (trimmed.len == 0) return null;
                    return std.fmt.parseInt(u64, trimmed, 10) catch null;
                }
            }.get;
            const since_sec: ?u64 = blk_since: {
                const parsed_s = if (since_str_opt) |ss| blk_inner: {
                    const trimmed_ss = std.mem.trim(u8, ss, " \t\r\n");
                    if (trimmed_ss.len == 0) break :blk_inner null;
                    break :blk_inner std.fmt.parseInt(u64, trimmed_ss, 10) catch null;
                } else null;
                break :blk_since if (parsed_s) |ps| if (ps > 0) ps else null else null;
            };

            const win_query = file_api.FileWindowQuery{
                .line = line_num,
                .context = ctx_num,
                .start_line = parseOptU64(req_arena, query_part, "startLine"),
                .end_line = parseOptU64(req_arena, query_part, "endLine"),
                .anchor_line = parseOptU64(req_arena, query_part, "anchorLine"),
                .anchor_byte = parseOptU64(req_arena, query_part, "anchorByte"),
            };

            const body = ctx.registry.buildLinePreviewWindowJson(
                req_arena,
                ctx.io,
                rel_path,
                win_query,
                since_sec,
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
    if (ctx.mcp) |mcp_svc| {
        mcp_svc.registerSubscriber(ctx.io, .{
            .ctx = &channel,
            .sendFn = WsChannel.sendText,
        });
    }
    var active_thread: ?std.Thread = null;
    defer {
        channel.cancel_flag.store(true, .release);
        if (ctx.mcp) |mcp_svc| {
            mcp_svc.unregisterSubscriber(ctx.io, &channel);
        }
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
    \\  <p>API endpoints active: <code>/api/meta</code>, <code>/api/sources</code>, <code>/api/fs/dirs</code>, <code>/api/file</code>, <code>/api/ws</code>, <code>/api/mcp</code>, <code>/mcp</code>.</p>
    \\  <p>Build frontend assets in <code>web/dist</code> or connect via Vite dev server.</p>
    \\</body>
    \\</html>
;

fn respondStaticBytes(
    request: *std.http.Server.Request,
    bytes: []const u8,
    mime: []const u8,
) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = mime },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "access-control-allow-origin", .value = "*" },
    };
    try request.respond(bytes, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn tryServeDiskAsset(
    ctx: *const ServerContext,
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    target_rel: []const u8,
) !bool {
    var web_dir = std.Io.Dir.cwd().openDir(ctx.io, ctx.web_dir_path, .{}) catch return false;
    defer web_dir.close(ctx.io);

    const max_asset_bytes = std.Io.Limit.limited(32 * 1024 * 1024);
    if (web_dir.readFileAlloc(ctx.io, target_rel, arena, max_asset_bytes)) |bytes| {
        try respondStaticBytes(request, bytes, mimeTypeForPath(target_rel));
        return true;
    } else |_| {}

    if (web_dir.readFileAlloc(ctx.io, "index.html", arena, max_asset_bytes)) |index_bytes| {
        try respondStaticBytes(request, index_bytes, "text/html; charset=utf-8");
        return true;
    } else |_| {}

    return false;
}

fn tryServeEmbeddedAsset(
    request: *std.http.Server.Request,
    target_rel: []const u8,
) !bool {
    if (web_assets.assets.len == 0) return false;
    if (web_assets.get(target_rel)) |bytes| {
        try respondStaticBytes(request, bytes, mimeTypeForPath(target_rel));
        return true;
    }
    if (web_assets.get("index.html")) |index_bytes| {
        try respondStaticBytes(request, index_bytes, "text/html; charset=utf-8");
        return true;
    }
    return false;
}

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

    if (ctx.web_dir_explicit) {
        if (try tryServeDiskAsset(ctx, arena, request, target_rel)) return;
        if (try tryServeEmbeddedAsset(request, target_rel)) return;
    } else {
        if (try tryServeEmbeddedAsset(request, target_rel)) return;
        if (try tryServeDiskAsset(ctx, arena, request, target_rel)) return;
    }

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "access-control-allow-origin", .value = "*" },
    };
    try request.respond(fallback_diagnostic_html, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

test "embedded web_assets lookup and mime types" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeTypeForPath("index.html"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", mimeTypeForPath("assets/app.js"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", mimeTypeForPath("assets/app.css"));
    if (web_assets.assets.len > 0) {
        const html = web_assets.get("index.html") orelse return error.MissingEmbeddedIndexHtml;
        try std.testing.expect(std.mem.indexOf(u8, html, "<html") != null);
    }
}
