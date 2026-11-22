const std = @import("std");
const file_api = @import("../file_api.zig");
const source_registry = @import("../source_registry.zig");
const time_parser = @import("../time_parser.zig");
const types = @import("types.zig");
const rpc = @import("rpc_helpers.zig");
const tools = @import("tools.zig");

const DEFAULT_MAX_LOGS = types.DEFAULT_MAX_LOGS;
const PROTOCOL_VERSION = types.PROTOCOL_VERSION;
const SERVER_NAME = types.SERVER_NAME;
const SERVER_VERSION = types.SERVER_VERSION;
const ENDPOINT_PATH = types.ENDPOINT_PATH;
const clampMaxLogs = types.clampMaxLogs;
const CAPABILITIES = types.CAPABILITIES;
const McpStatsDto = types.McpStatsDto;
const McpCallLogDto = types.McpCallLogDto;
const McpStateDto = types.McpStateDto;
const McpStateEnvelope = types.McpStateEnvelope;
const PersistedMcpConfig = types.PersistedMcpConfig;
const UpdateMcpConfigRequest = types.UpdateMcpConfigRequest;
const OwnedLogEntry = types.OwnedLogEntry;
const WsSubscriber = types.WsSubscriber;
const ToolTextOut = types.ToolTextOut;
const elapsedMsSince = rpc.elapsedMsSince;
const buildJsonRpcResultAlloc = rpc.buildJsonRpcResultAlloc;
const buildJsonRpcErrorAlloc = rpc.buildJsonRpcErrorAlloc;
const buildToolSuccessRpcAlloc = rpc.buildToolSuccessRpcAlloc;
const buildToolErrorRpcAlloc = rpc.buildToolErrorRpcAlloc;
const buildToolsListResponseAlloc = rpc.buildToolsListResponseAlloc;
const extractString = rpc.extractString;
const extractNestedString = rpc.extractNestedString;
const extractBool = rpc.extractBool;
const extractU64 = rpc.extractU64;
const formatSearchArgsSummaryAlloc = rpc.formatSearchArgsSummaryAlloc;
const truncateUtf8 = rpc.truncateUtf8;

pub const McpService = struct {
    gpa: std.mem.Allocator,
    data_root_path: []u8,
    registry: *source_registry.SourceRegistry,
    mutex: std.Io.Mutex = .init,
    sub_mutex: std.Io.Mutex = .init,
    enabled: bool = true,
    max_logs: u32 = DEFAULT_MAX_LOGS,
    token_required: bool = false,
    next_seq: u64 = 1,
    total_calls: u64 = 0,
    error_calls: u64 = 0,
    last_call_ms: u64 = 0,
    logs: std.ArrayList(OwnedLogEntry) = .empty,
    subscribers: std.ArrayList(WsSubscriber) = .empty,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        data_root_path: []const u8,
        registry: *source_registry.SourceRegistry,
    ) !McpService {
        const owned_root = try gpa.dupe(u8, data_root_path);
        errdefer gpa.free(owned_root);

        var svc = McpService{
            .gpa = gpa,
            .data_root_path = owned_root,
            .registry = registry,
        };
        svc.loadFromDiskLocked(io);
        return svc;
    }

    pub fn deinit(self: *McpService, io: std.Io) void {
        self.sub_mutex.lockUncancelable(io);
        self.subscribers.deinit(self.gpa);
        self.sub_mutex.unlock(io);

        self.mutex.lockUncancelable(io);
        for (self.logs.items) |*entry| {
            entry.deinit(self.gpa);
        }
        self.logs.deinit(self.gpa);
        self.mutex.unlock(io);

        self.gpa.free(self.data_root_path);
    }

    fn loadFromDiskLocked(self: *McpService, io: std.Io) void {
        var dir = std.Io.Dir.cwd().openDir(io, self.data_root_path, .{}) catch return;
        defer dir.close(io);

        const raw = dir.readFileAlloc(io, "mcp.json", self.gpa, .limited(64 * 1024)) catch return;
        defer self.gpa.free(raw);

        var parsed = std.json.parseFromSlice(PersistedMcpConfig, self.gpa, raw, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        self.enabled = parsed.value.enabled;
        self.max_logs = clampMaxLogs(parsed.value.maxLogs);
    }

    fn saveToDiskLocked(self: *const McpService, io: std.Io) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const json_bytes = try file_api.stringifyAlloc(arena, PersistedMcpConfig{
            .version = 1,
            .enabled = self.enabled,
            .maxLogs = self.max_logs,
        });

        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, self.data_root_path) catch {};
        var data_dir = try cwd.openDir(io, self.data_root_path, .{});
        defer data_dir.close(io);

        var file = try data_dir.createFile(io, "mcp.json", .{ .truncate = true });
        defer file.close(io);

        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(io, &write_buf);
        try file_writer.interface.writeAll(json_bytes);
        try file_writer.interface.flush();
    }

    pub fn isEnabled(self: *McpService, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.enabled;
    }

    pub fn registerSubscriber(self: *McpService, io: std.Io, sub: WsSubscriber) void {
        self.sub_mutex.lockUncancelable(io);
        defer self.sub_mutex.unlock(io);
        for (self.subscribers.items) |existing| {
            if (existing.ctx == sub.ctx) return;
        }
        self.subscribers.append(self.gpa, sub) catch {};
    }

    pub fn unregisterSubscriber(self: *McpService, io: std.Io, ctx_ptr: *anyopaque) void {
        self.sub_mutex.lockUncancelable(io);
        defer self.sub_mutex.unlock(io);
        for (self.subscribers.items, 0..) |existing, idx| {
            if (existing.ctx == ctx_ptr) {
                _ = self.subscribers.orderedRemove(idx);
                return;
            }
        }
    }

    fn buildStateDtoLocked(self: *const McpService, arena: std.mem.Allocator) !McpStateDto {
        const count = self.logs.items.len;
        const dtos = try arena.alloc(McpCallLogDto, count);
        var i: usize = 0;
        // Return newest-first so live logs appear cleanly at the top.
        while (i < count) : (i += 1) {
            const src = self.logs.items[count - 1 - i];
            dtos[i] = .{
                .seq = src.seq,
                .timestampMs = src.timestamp_ms,
                .method = try arena.dupe(u8, src.method),
                .toolName = try arena.dupe(u8, src.tool_name),
                .argsSummary = try arena.dupe(u8, src.args_summary),
                .resultSummary = try arena.dupe(u8, src.result_summary),
                .durationMs = src.duration_ms,
                .ok = src.ok,
                .errorMessage = try arena.dupe(u8, src.error_message),
                .clientInfo = try arena.dupe(u8, src.client_info),
            };
        }
        return .{
            .enabled = self.enabled,
            .maxLogs = self.max_logs,
            .endpointPath = ENDPOINT_PATH,
            .protocolVersion = PROTOCOL_VERSION,
            .tokenRequired = self.token_required,
            .stats = .{
                .totalCalls = self.total_calls,
                .errorCalls = self.error_calls,
                .lastCallMs = self.last_call_ms,
            },
            .capabilities = &CAPABILITIES,
            .logs = dtos,
        };
    }

    pub fn buildStateJson(self: *McpService, arena: std.mem.Allocator, io: std.Io) ![]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const dto = try self.buildStateDtoLocked(arena);
        return file_api.stringifyAlloc(arena, dto);
    }

    fn buildBroadcastEnvelopeLocked(self: *const McpService) ![]u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const dto = try self.buildStateDtoLocked(arena);
        return file_api.stringifyAlloc(self.gpa, McpStateEnvelope{
            .state = dto,
        });
    }

    fn dispatchBroadcastPayload(self: *McpService, io: std.Io, payload: []u8) void {
        defer self.gpa.free(payload);
        // Never hold self.mutex while locking sub_mutex or sending to sockets.
        self.sub_mutex.lockUncancelable(io);
        defer self.sub_mutex.unlock(io);
        for (self.subscribers.items) |sub| {
            sub.sendFn(sub.ctx, payload) catch {};
        }
    }

    fn trimLogsLocked(self: *McpService) void {
        while (self.logs.items.len > self.max_logs) {
            var oldest = self.logs.orderedRemove(0);
            oldest.deinit(self.gpa);
        }
    }

    pub fn updateConfig(
        self: *McpService,
        io: std.Io,
        req: UpdateMcpConfigRequest,
    ) !void {
        var broadcast_payload: ?[]u8 = null;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            if (req.enabled) |en| {
                self.enabled = en;
            }
            if (req.maxLogs) |ml| {
                self.max_logs = clampMaxLogs(ml);
                self.trimLogsLocked();
            }
            self.saveToDiskLocked(io) catch {};
            broadcast_payload = self.buildBroadcastEnvelopeLocked() catch null;
        }
        if (broadcast_payload) |p| {
            self.dispatchBroadcastPayload(io, p);
        }
    }

    pub fn clearLogs(self: *McpService, io: std.Io) void {
        var broadcast_payload: ?[]u8 = null;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            for (self.logs.items) |*entry| {
                entry.deinit(self.gpa);
            }
            self.logs.clearRetainingCapacity();
            broadcast_payload = self.buildBroadcastEnvelopeLocked() catch null;
        }
        if (broadcast_payload) |p| {
            self.dispatchBroadcastPayload(io, p);
        }
    }

    pub fn recordUnauthorizedAttempt(
        self: *McpService,
        io: std.Io,
        method: []const u8,
        client_info: []const u8,
    ) void {
        self.recordCall(
            io,
            method,
            "auth",
            "",
            "",
            0.0,
            false,
            "Unauthorized: invalid or missing MCP token",
            client_info,
        );
    }

    fn recordCall(
        self: *McpService,
        io: std.Io,
        method: []const u8,
        tool_name: []const u8,
        args_summary: []const u8,
        result_summary: []const u8,
        duration_ms: f64,
        ok: bool,
        error_message: []const u8,
        client_info: []const u8,
    ) void {
        const now_ms: u64 = time_parser.currentUnixNano(io) / 1_000_000;
        var broadcast_payload: ?[]u8 = null;

        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            self.total_calls += 1;
            if (!ok) self.error_calls += 1;
            self.last_call_ms = now_ms;

            const owned = OwnedLogEntry{
                .seq = self.next_seq,
                .timestamp_ms = now_ms,
                .method = self.gpa.dupe(u8, truncateUtf8(method, 96)) catch return,
                .tool_name = self.gpa.dupe(u8, truncateUtf8(tool_name, 96)) catch return,
                .args_summary = self.gpa.dupe(u8, truncateUtf8(args_summary, 280)) catch return,
                .result_summary = self.gpa.dupe(u8, truncateUtf8(result_summary, 280)) catch return,
                .duration_ms = duration_ms,
                .ok = ok,
                .error_message = self.gpa.dupe(u8, truncateUtf8(error_message, 280)) catch return,
                .client_info = self.gpa.dupe(u8, truncateUtf8(client_info, 120)) catch return,
            };
            self.next_seq += 1;

            self.logs.append(self.gpa, owned) catch {
                var tmp = owned;
                tmp.deinit(self.gpa);
                return;
            };
            self.trimLogsLocked();
            broadcast_payload = self.buildBroadcastEnvelopeLocked() catch null;
        }

        if (broadcast_payload) |p| {
            self.dispatchBroadcastPayload(io, p);
        }
    }

    pub fn handleHttpEndpoint(
        self: *McpService,
        arena: std.mem.Allocator,
        io: std.Io,
        request: *std.http.Server.Request,
        cors_headers: []const std.http.Header,
        json_headers: []const std.http.Header,
    ) !void {
        const method = request.head.method;

        // Read headers BEFORE calling request.readerExpectContinue!
        var accept_header: []const u8 = "";
        var user_agent: []const u8 = "";
        var hdr_it = request.iterateHeaders();
        while (hdr_it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "accept")) {
                accept_header = try arena.dupe(u8, h.value);
            } else if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
                user_agent = try arena.dupe(u8, h.value);
            }
        }

        if (method == .GET) {
            const wants_sse = std.mem.indexOf(u8, accept_header, "text/event-stream") != null;
            const wants_json = std.mem.indexOf(u8, accept_header, "application/json") != null;
            if (wants_sse and !wants_json) {
                var headers_buf: [6]std.http.Header = undefined;
                var hdr_len: usize = 0;
                for (cors_headers) |h| {
                    if (hdr_len < headers_buf.len) {
                        headers_buf[hdr_len] = h;
                        hdr_len += 1;
                    }
                }
                if (hdr_len < headers_buf.len) {
                    headers_buf[hdr_len] = .{ .name = "allow", .value = "POST, DELETE, OPTIONS" };
                    hdr_len += 1;
                }
                try request.respond("", .{
                    .status = .method_not_allowed,
                    .extra_headers = headers_buf[0..hdr_len],
                });
                return;
            }
            const info_json = try file_api.stringifyAlloc(arena, .{
                .service = SERVER_NAME,
                .version = SERVER_VERSION,
                .enabled = self.isEnabled(io),
                .protocolVersion = PROTOCOL_VERSION,
                .endpoint = ENDPOINT_PATH,
            });
            try request.respond(info_json, .{
                .status = .ok,
                .extra_headers = json_headers,
            });
            return;
        }

        if (method == .DELETE) {
            try request.respond("", .{
                .status = .no_content,
                .extra_headers = cors_headers,
            });
            return;
        }

        if (method != .POST) {
            try request.respond("{\"error\":\"method not allowed\"}", .{
                .status = .method_not_allowed,
                .extra_headers = json_headers,
            });
            return;
        }

        var body_buf: [8192]u8 = undefined;
        const body_reader = request.readerExpectContinue(&body_buf) catch {
            const err_body = try buildJsonRpcErrorAlloc(arena, .null, -32700, "Failed to read request body");
            try request.respond(err_body, .{
                .status = .bad_request,
                .extra_headers = json_headers,
            });
            return;
        };
        const raw_json = body_reader.allocRemaining(arena, .limited(1024 * 1024)) catch {
            const err_body = try buildJsonRpcErrorAlloc(arena, .null, -32700, "Request body too large");
            try request.respond(err_body, .{
                .status = .bad_request,
                .extra_headers = json_headers,
            });
            return;
        };

        const maybe_resp = self.handleRpcPayload(arena, io, raw_json, user_agent) catch |err| {
            const err_body = try buildJsonRpcErrorAlloc(arena, .null, -32603, @errorName(err));
            try request.respond(err_body, .{
                .status = .internal_server_error,
                .extra_headers = json_headers,
            });
            return;
        };

        if (maybe_resp) |resp_json| {
            try request.respond(resp_json, .{
                .status = .ok,
                .extra_headers = json_headers,
            });
        } else {
            try request.respond("", .{
                .status = .accepted,
                .extra_headers = cors_headers,
            });
        }
    }

    pub fn handleRpcPayload(
        self: *McpService,
        arena: std.mem.Allocator,
        io: std.Io,
        raw_json: []const u8,
        client_hint: []const u8,
    ) !?[]u8 {
        const trimmed = std.mem.trim(u8, raw_json, " \t\r\n");
        if (trimmed.len == 0) {
            return try buildJsonRpcErrorAlloc(arena, .null, -32600, "Empty JSON-RPC payload");
        }

        var parsed = std.json.parseFromSlice(std.json.Value, arena, trimmed, .{}) catch {
            return try buildJsonRpcErrorAlloc(arena, .null, -32700, "Parse error");
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .object => return try self.handleRpcObject(arena, io, parsed.value.object, client_hint),
            .array => |arr| {
                if (arr.items.len == 0) {
                    return try buildJsonRpcErrorAlloc(arena, .null, -32600, "Empty batch request");
                }
                var out_list: std.ArrayList([]const u8) = .empty;
                for (arr.items) |item| {
                    switch (item) {
                        .object => |obj| {
                            if (try self.handleRpcObject(arena, io, obj, client_hint)) |single_json| {
                                try out_list.append(arena, single_json);
                            }
                        },
                        else => {
                            try out_list.append(arena, try buildJsonRpcErrorAlloc(arena, .null, -32600, "Invalid batch item"));
                        },
                    }
                }
                if (out_list.items.len == 0) return null;

                var buf: std.Io.Writer.Allocating = .init(arena);
                try buf.writer.writeByte('[');
                for (out_list.items, 0..) |item_json, idx| {
                    if (idx > 0) try buf.writer.writeByte(',');
                    try buf.writer.writeAll(item_json);
                }
                try buf.writer.writeByte(']');
                return try buf.toOwnedSlice();
            },
            else => return try buildJsonRpcErrorAlloc(arena, .null, -32600, "Invalid JSON-RPC request"),
        }
    }

    fn handleRpcObject(
        self: *McpService,
        arena: std.mem.Allocator,
        io: std.Io,
        obj: std.json.ObjectMap,
        client_hint: []const u8,
    ) !?[]u8 {
        const has_id = obj.get("id") != null;
        const id_val: std.json.Value = obj.get("id") orelse .null;

        const method_val = obj.get("method") orelse {
            if (!has_id) return null;
            return try buildJsonRpcErrorAlloc(arena, id_val, -32600, "Missing JSON-RPC method");
        };
        const method = switch (method_val) {
            .string => |s| s,
            else => {
                if (!has_id) return null;
                return try buildJsonRpcErrorAlloc(arena, id_val, -32600, "Invalid JSON-RPC method");
            },
        };

        const params_opt: ?std.json.ObjectMap = if (obj.get("params")) |p| switch (p) {
            .object => |m| m,
            else => null,
        } else null;

        // Notifications (no id field) produce no JSON-RPC payload.
        if (!has_id) {
            return null;
        }

        // ping works even while transitioning, or checks enabled? Allow ping as standard health probe.
        if (std.mem.eql(u8, method, "ping")) {
            return try buildJsonRpcResultAlloc(arena, id_val, .{});
        }

        if (!self.isEnabled(io)) {
            const start_ts = std.Io.Clock.awake.now(io);
            const tool_name = if (std.mem.eql(u8, method, "tools/call"))
                (extractString(params_opt, "name") orelse "")
            else
                "";
            const dur_ms = elapsedMsSince(io, start_ts);
            self.recordCall(
                io,
                method,
                tool_name,
                "",
                "service disabled",
                dur_ms,
                false,
                "WebGrep MCP service is disabled",
                client_hint,
            );
            return try buildJsonRpcErrorAlloc(arena, id_val, -32003, "WebGrep MCP service is disabled");
        }

        if (std.mem.eql(u8, method, "initialize")) {
            const start_ts = std.Io.Clock.awake.now(io);
            const req_proto = extractString(params_opt, "protocolVersion") orelse PROTOCOL_VERSION;
            const neg_proto = if (std.mem.startsWith(u8, req_proto, "202")) req_proto else PROTOCOL_VERSION;

            const client_name = extractNestedString(params_opt, "clientInfo", "name") orelse client_hint;
            const client_ver = extractNestedString(params_opt, "clientInfo", "version") orelse "";
            const full_client = if (client_name.len > 0 and client_ver.len > 0)
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ client_name, client_ver })
            else if (client_name.len > 0)
                client_name
            else
                "mcp-client";

            const result_json = try buildJsonRpcResultAlloc(arena, id_val, .{
                .protocolVersion = neg_proto,
                .capabilities = .{
                    .tools = .{
                        .listChanged = false,
                    },
                },
                .serverInfo = .{
                    .name = SERVER_NAME,
                    .version = SERVER_VERSION,
                },
                .instructions = "Use webgrep_list_sources to inspect configured directory/file sources, webgrep_search for high-speed SIMD/regex queries, and webgrep_get_context for O(window) surrounding line context.",
            });
            const dur_ms = elapsedMsSince(io, start_ts);
            self.recordCall(
                io,
                "initialize",
                "",
                neg_proto,
                "ready (4 tools)",
                dur_ms,
                true,
                "",
                full_client,
            );
            return result_json;
        }

        if (std.mem.eql(u8, method, "tools/list")) {
            const start_ts = std.Io.Clock.awake.now(io);
            const tools_json = try buildToolsListResponseAlloc(arena, id_val);
            const dur_ms = elapsedMsSince(io, start_ts);
            self.recordCall(
                io,
                "tools/list",
                "",
                "-",
                "4 tools",
                dur_ms,
                true,
                "",
                client_hint,
            );
            return tools_json;
        }

        if (std.mem.eql(u8, method, "resources/list")) {
            return try buildJsonRpcResultAlloc(arena, id_val, .{
                .resources = &[_]u8{},
            });
        }

        if (std.mem.eql(u8, method, "prompts/list")) {
            return try buildJsonRpcResultAlloc(arena, id_val, .{
                .prompts = &[_]u8{},
            });
        }

        if (std.mem.eql(u8, method, "tools/call")) {
            return try self.handleToolsCall(arena, io, id_val, params_opt, client_hint);
        }

        const start_ts = std.Io.Clock.awake.now(io);
        const dur_ms = elapsedMsSince(io, start_ts);
        self.recordCall(
            io,
            method,
            "",
            "",
            "",
            dur_ms,
            false,
            "Method not found",
            client_hint,
        );
        return try buildJsonRpcErrorAlloc(arena, id_val, -32601, "Method not found");
    }

    fn handleToolsCall(
        self: *McpService,
        arena: std.mem.Allocator,
        io: std.Io,
        id_val: std.json.Value,
        params_opt: ?std.json.ObjectMap,
        client_hint: []const u8,
    ) ![]u8 {
        const start_ts = std.Io.Clock.awake.now(io);
        const tool_name = extractString(params_opt, "name") orelse {
            const dur = elapsedMsSince(io, start_ts);
            self.recordCall(io, "tools/call", "", "", "", dur, false, "Missing tool name", client_hint);
            return try buildJsonRpcErrorAlloc(arena, id_val, -32602, "Missing tool name");
        };

        const args_obj: ?std.json.ObjectMap = if (params_opt) |pm|
            if (pm.get("arguments")) |av| switch (av) {
                .object => |ao| ao,
                else => null,
            } else null
        else
            null;

        if (std.mem.eql(u8, tool_name, "webgrep_list_sources")) {
            const include_disabled = extractBool(args_obj, "includeDisabled") orelse false;
            const args_sum = if (include_disabled) "includeDisabled=true" else "enabled only";
            const out = tools.executeToolListSources(self, arena, io, include_disabled) catch |err| {
                const dur = elapsedMsSince(io, start_ts);
                const msg = @errorName(err);
                self.recordCall(io, "tools/call", tool_name, args_sum, "", dur, false, msg, client_hint);
                return try buildToolErrorRpcAlloc(arena, id_val, msg);
            };
            const dur = elapsedMsSince(io, start_ts);
            self.recordCall(io, "tools/call", tool_name, args_sum, out.summary, dur, true, "", client_hint);
            return try buildToolSuccessRpcAlloc(arena, id_val, out.text);
        }

        if (std.mem.eql(u8, tool_name, "webgrep_status")) {
            const out = tools.executeToolStatus(self, arena, io) catch |err| {
                const dur = elapsedMsSince(io, start_ts);
                const msg = @errorName(err);
                self.recordCall(io, "tools/call", tool_name, "{}", "", dur, false, msg, client_hint);
                return try buildToolErrorRpcAlloc(arena, id_val, msg);
            };
            const dur = elapsedMsSince(io, start_ts);
            self.recordCall(io, "tools/call", tool_name, "{}", out.summary, dur, true, "", client_hint);
            return try buildToolSuccessRpcAlloc(arena, id_val, out.text);
        }

        if (std.mem.eql(u8, tool_name, "webgrep_get_context")) {
            const path_val = extractString(args_obj, "path") orelse "";
            const line_val: u64 = @max(@as(u64, 1), extractU64(args_obj, "line") orelse 1);
            const ctx_val: u64 = @min(@as(u64, 200), extractU64(args_obj, "context") orelse 15);
            const args_sum = try std.fmt.allocPrint(arena, "{s}:{d} (±{d})", .{
                truncateUtf8(path_val, 80),
                line_val,
                ctx_val,
            });
            const out = tools.executeToolGetContext(self, arena, io, args_obj) catch |err| {
                const dur = elapsedMsSince(io, start_ts);
                const msg = switch (err) {
                    error.MissingPath => "Parameter `path` is required",
                    error.InvalidPath => "Invalid path",
                    error.FileNotFound, error.IsDir, error.NotDir => "Source or file not found",
                    else => @errorName(err),
                };
                self.recordCall(io, "tools/call", tool_name, args_sum, "", dur, false, msg, client_hint);
                return try buildToolErrorRpcAlloc(arena, id_val, msg);
            };
            const dur = elapsedMsSince(io, start_ts);
            self.recordCall(io, "tools/call", tool_name, args_sum, out.summary, dur, true, "", client_hint);
            return try buildToolSuccessRpcAlloc(arena, id_val, out.text);
        }

        if (std.mem.eql(u8, tool_name, "webgrep_search")) {
            const args_sum = try formatSearchArgsSummaryAlloc(arena, args_obj);
            const res = tools.executeToolSearch(self, arena, io, args_obj) catch |err| {
                const dur = elapsedMsSince(io, start_ts);
                const msg = @errorName(err);
                self.recordCall(io, "tools/call", tool_name, args_sum, "", dur, false, msg, client_hint);
                return try buildToolErrorRpcAlloc(arena, id_val, msg);
            };
            const dur = elapsedMsSince(io, start_ts);
            if (!res.ok) {
                self.recordCall(io, "tools/call", tool_name, args_sum, "", dur, false, res.error_message, client_hint);
                return try buildToolErrorRpcAlloc(arena, id_val, res.error_message);
            }
            self.recordCall(io, "tools/call", tool_name, args_sum, res.summary, dur, true, "", client_hint);
            return try buildToolSuccessRpcAlloc(arena, id_val, res.text);
        }

        const dur = elapsedMsSince(io, start_ts);
        const unknown_msg = try std.fmt.allocPrint(arena, "Unknown tool: {s}", .{tool_name});
        self.recordCall(io, "tools/call", tool_name, "", "", dur, false, unknown_msg, client_hint);
        return try buildJsonRpcErrorAlloc(arena, id_val, -32602, unknown_msg);
    }

};
