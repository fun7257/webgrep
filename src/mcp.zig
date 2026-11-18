const std = @import("std");
const file_api = @import("file_api.zig");
const search_job = @import("search_job.zig");
const source_registry = @import("source_registry.zig");
const time_parser = @import("time_parser.zig");

pub const DEFAULT_MAX_LOGS: u32 = 20;
pub const MIN_MAX_LOGS: u32 = 1;
pub const MAX_MAX_LOGS: u32 = 200;
pub const PROTOCOL_VERSION: []const u8 = "2025-03-26";
pub const SERVER_NAME: []const u8 = "webgrep-mcp";
pub const SERVER_VERSION: []const u8 = "0.5.0";
pub const ENDPOINT_PATH: []const u8 = "/mcp";

pub fn clampMaxLogs(raw: u32) u32 {
    return @max(MIN_MAX_LOGS, @min(MAX_MAX_LOGS, raw));
}

pub const ParamMeta = struct {
    name: []const u8,
    type: []const u8,
    required: bool,
    description: []const u8,
};

pub const CapabilityMeta = struct {
    name: []const u8,
    category: []const u8,
    description: []const u8,
    params: []const ParamMeta,
};

pub const CAPABILITIES = [_]CapabilityMeta{
    .{
        .name = "webgrep_search",
        .category = "search",
        .description = "Fast SIMD/regex search across registered WebGrep sources (local dirs, files, archives, Docker logs) with same-line AND/NOT filtering and time window pruning.",
        .params = &.{
            .{ .name = "pattern", .type = "string", .required = false, .description = "Primary search pattern (literal or regex; optional when time filter is set)" },
            .{ .name = "contains", .type = "string[]", .required = false, .description = "Additional same-line required substrings/regexes (AND)" },
            .{ .name = "excludes", .type = "string[]", .required = false, .description = "Same-line excluded substrings/regexes (NOT)" },
            .{ .name = "isRegex", .type = "boolean", .required = false, .description = "Treat pattern and filters as regular expressions" },
            .{ .name = "caseSensitive", .type = "boolean", .required = false, .description = "Case-sensitive matching (default false)" },
            .{ .name = "wholeWord", .type = "boolean", .required = false, .description = "Match whole words only" },
            .{ .name = "sources", .type = "string[]", .required = false, .description = "Limit search to specific source IDs or names" },
            .{ .name = "fileGlobs", .type = "string[]", .required = false, .description = "File path globs (prefix ! to exclude)" },
            .{ .name = "types", .type = "string[]", .required = false, .description = "Language/file type filters (e.g. zig, ts, log)" },
            .{ .name = "timePreset", .type = "string", .required = false, .description = "Relative time window: 5m, 15m, 30m, 1h, 6h, 24h, today, 7d, 30d" },
            .{ .name = "timeStartMs", .type = "integer", .required = false, .description = "Inclusive Unix epoch start timestamp in ms" },
            .{ .name = "timeEndMs", .type = "integer", .required = false, .description = "Inclusive Unix epoch end timestamp in ms" },
            .{ .name = "pluginPreset", .type = "string", .required = false, .description = "Prefilter preset override: auto | timeseries | code | raw" },
            .{ .name = "plugins", .type = "object", .required = false, .description = "Per-query plugin overrides: { enable?: string[], disable?: string[] }" },
            .{ .name = "kvPredicates", .type = "object[]", .required = false, .description = "JSON/logfmt structured line predicates: [{ key, op: eq|neq|contains|gt_num|lt_num|exists, value, caseSensitive }]" },
            .{ .name = "maxResults", .type = "integer", .required = false, .description = "Max hits to return (default 50, range 1..500)" },
        },
    },
    .{
        .name = "webgrep_get_context",
        .category = "context",
        .description = "Read surrounding lines from any matched path using O(window) positional pread (supports plain files, compressed logs, archive::entry virtual paths, and Docker logs).",
        .params = &.{
            .{ .name = "path", .type = "string", .required = true, .description = "Virtual path returned by webgrep_search (e.g. source/file or source/app.tar.gz::inner)" },
            .{ .name = "line", .type = "integer", .required = false, .description = "1-based anchor line number (default 1)" },
            .{ .name = "context", .type = "integer", .required = false, .description = "Lines before and after target line (default 15, range 0..200)" },
            .{ .name = "startLine", .type = "integer", .required = false, .description = "Explicit 1-based start line override" },
            .{ .name = "endLine", .type = "integer", .required = false, .description = "Explicit 1-based end line override" },
            .{ .name = "anchorLine", .type = "integer", .required = false, .description = "Known line anchor paired with anchorByte for O(window) seek" },
            .{ .name = "anchorByte", .type = "integer", .required = false, .description = "Raw UTF-8 byte offset anchor from search hit" },
        },
    },
    .{
        .name = "webgrep_list_sources",
        .category = "sources",
        .description = "List configured WebGrep data sources with IDs, kinds (dir/file/docker), paths, readiness, and time-parsing format.",
        .params = &.{
            .{ .name = "includeDisabled", .type = "boolean", .required = false, .description = "Include disabled sources (default false)" },
        },
    },
    .{
        .name = "webgrep_status",
        .category = "status",
        .description = "Inspect WebGrep engine status, registered source counts, and live MCP invocation telemetry.",
        .params = &.{},
    },
};

pub const McpStatsDto = struct {
    totalCalls: u64,
    errorCalls: u64,
    lastCallMs: u64,
};

pub const McpCallLogDto = struct {
    seq: u64,
    timestampMs: u64,
    method: []const u8,
    toolName: []const u8,
    argsSummary: []const u8,
    resultSummary: []const u8,
    durationMs: f64,
    ok: bool,
    errorMessage: []const u8,
    clientInfo: []const u8,
};

pub const McpStateDto = struct {
    enabled: bool,
    maxLogs: u32,
    endpointPath: []const u8,
    protocolVersion: []const u8,
    tokenRequired: bool = false,
    stats: McpStatsDto,
    capabilities: []const CapabilityMeta,
    logs: []const McpCallLogDto,
};

const McpStateEnvelope = struct {
    type: []const u8 = "mcp_state",
    state: McpStateDto,
};

const PersistedMcpConfig = struct {
    version: u32 = 1,
    enabled: bool = true,
    maxLogs: u32 = DEFAULT_MAX_LOGS,
};

pub const UpdateMcpConfigRequest = struct {
    enabled: ?bool = null,
    maxLogs: ?u32 = null,
};

const OwnedLogEntry = struct {
    seq: u64,
    timestamp_ms: u64,
    method: []u8,
    tool_name: []u8,
    args_summary: []u8,
    result_summary: []u8,
    duration_ms: f64,
    ok: bool,
    error_message: []u8,
    client_info: []u8,

    fn deinit(self: *OwnedLogEntry, gpa: std.mem.Allocator) void {
        gpa.free(self.method);
        gpa.free(self.tool_name);
        gpa.free(self.args_summary);
        gpa.free(self.result_summary);
        gpa.free(self.error_message);
        gpa.free(self.client_info);
    }
};

pub const WsSubscriber = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, json_text: []const u8) anyerror!void,
};

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
                .instructions = "Use webgrep_list_sources to inspect configured directories/files/Docker sources, webgrep_search for high-speed SIMD/regex queries, and webgrep_get_context for O(window) surrounding line context.",
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
            const out = self.executeToolListSources(arena, io, include_disabled) catch |err| {
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
            const out = self.executeToolStatus(arena, io) catch |err| {
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
            const out = self.executeToolGetContext(arena, io, args_obj) catch |err| {
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
            const res = self.executeToolSearch(arena, io, args_obj) catch |err| {
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

    const ToolTextOut = struct {
        text: []const u8,
        summary: []const u8,
        ok: bool = true,
        error_message: []const u8 = "",
    };

    fn executeToolListSources(
        self: *McpService,
        arena: std.mem.Allocator,
        io: std.Io,
        include_disabled: bool,
    ) !ToolTextOut {
        const raw_json = try self.registry.buildSourcesJson(arena, io);
        if (include_disabled) {
            var parsed = std.json.parseFromSlice(source_registry.SourcesResponse, arena, raw_json, .{
                .ignore_unknown_fields = true,
            }) catch {
                return .{ .text = raw_json, .summary = "listed sources" };
            };
            defer parsed.deinit();
            const sum = try std.fmt.allocPrint(arena, "{d} sources", .{parsed.value.sources.len});
            return .{ .text = raw_json, .summary = sum };
        }

        var parsed = std.json.parseFromSlice(source_registry.SourcesResponse, arena, raw_json, .{
            .ignore_unknown_fields = true,
        }) catch {
            return .{ .text = raw_json, .summary = "listed sources" };
        };
        defer parsed.deinit();

        var filtered: std.ArrayList(source_registry.SourceInfoDto) = .empty;
        for (parsed.value.sources) |src| {
            if (src.enabled) try filtered.append(arena, src);
        }
        const filtered_json = try file_api.stringifyAlloc(arena, .{
            .searchCount = parsed.value.searchCount,
            .sources = filtered.items,
        });
        const sum = try std.fmt.allocPrint(arena, "{d}/{d} enabled sources", .{
            filtered.items.len,
            parsed.value.sources.len,
        });
        return .{ .text = filtered_json, .summary = sum };
    }

    fn executeToolStatus(self: *McpService, arena: std.mem.Allocator, io: std.Io) !ToolTextOut {
        const sources_raw = try self.registry.buildSourcesJson(arena, io);
        var enabled_count: usize = 0;
        var total_count: usize = 0;
        if (std.json.parseFromSlice(source_registry.SourcesResponse, arena, sources_raw, .{
            .ignore_unknown_fields = true,
        })) |parsed| {
            total_count = parsed.value.sources.len;
            for (parsed.value.sources) |s| {
                if (s.enabled) enabled_count += 1;
            }
        } else |_| {}

        self.mutex.lockUncancelable(io);
        const stats_snap = McpStatsDto{
            .totalCalls = self.total_calls,
            .errorCalls = self.error_calls,
            .lastCallMs = self.last_call_ms,
        };
        const max_logs = self.max_logs;
        const enabled = self.enabled;
        self.mutex.unlock(io);

        const json_out = try file_api.stringifyAlloc(arena, .{
            .engine = "libwebgrep 0.5.0",
            .protocolVersion = PROTOCOL_VERSION,
            .endpointPath = ENDPOINT_PATH,
            .mcpEnabled = enabled,
            .maxLogs = max_logs,
            .enabledSources = enabled_count,
            .totalSources = total_count,
            .searchCount = self.registry.getSearchCount(),
            .stats = stats_snap,
        });
        const sum = try std.fmt.allocPrint(arena, "{d}/{d} sources · {d} calls", .{
            enabled_count,
            total_count,
            stats_snap.totalCalls,
        });
        return .{ .text = json_out, .summary = sum };
    }

    fn executeToolGetContext(
        self: *McpService,
        arena: std.mem.Allocator,
        io: std.Io,
        args_obj: ?std.json.ObjectMap,
    ) !ToolTextOut {
        const path_raw = extractString(args_obj, "path") orelse return error.MissingPath;
        const trimmed_path = std.mem.trim(u8, path_raw, " \t\r\n");
        if (trimmed_path.len == 0) return error.MissingPath;

        const line_num: u64 = @max(@as(u64, 1), extractU64(args_obj, "line") orelse 1);
        const ctx_num: u64 = @min(@as(u64, 200), extractU64(args_obj, "context") orelse 15);
        const win_query = file_api.FileWindowQuery{
            .line = line_num,
            .context = ctx_num,
            .start_line = extractU64(args_obj, "startLine"),
            .end_line = extractU64(args_obj, "endLine"),
            .anchor_line = extractU64(args_obj, "anchorLine"),
            .anchor_byte = extractU64(args_obj, "anchorByte"),
        };

        const window_json = try self.registry.buildLinePreviewWindowJson(
            arena,
            io,
            trimmed_path,
            win_query,
            null,
        );

        var sum: []const u8 = "context loaded";
        if (std.json.parseFromSlice(file_api.FileResponse, arena, window_json, .{
            .ignore_unknown_fields = true,
        })) |parsed| {
            if (parsed.value.binary) {
                sum = "binary file";
            } else if (parsed.value.lines.len > 0) {
                const first_n = parsed.value.lines[0].n;
                const last_n = parsed.value.lines[parsed.value.lines.len - 1].n;
                sum = try std.fmt.allocPrint(arena, "lines {d}..{d} ({d})", .{
                    first_n,
                    last_n,
                    parsed.value.lines.len,
                });
            } else {
                sum = "0 lines";
            }
        } else |_| {}

        return .{ .text = window_json, .summary = sum };
    }

    fn executeToolSearch(
        self: *McpService,
        arena: std.mem.Allocator,
        io: std.Io,
        args_obj: ?std.json.ObjectMap,
    ) !ToolTextOut {
        const raw_pattern = extractString(args_obj, "pattern") orelse "";
        const is_regex = extractBool(args_obj, "isRegex") orelse false;
        const case_sensitive = extractBool(args_obj, "caseSensitive") orelse false;
        const whole_word = extractBool(args_obj, "wholeWord") orelse false;
        const hidden = extractBool(args_obj, "hidden") orelse false;
        const respect_ignore = extractBool(args_obj, "respectIgnore") orelse false;

        const max_res_raw = extractU64(args_obj, "maxResults") orelse 50;
        const max_results: u64 = @max(@as(u64, 1), @min(@as(u64, 500), max_res_raw));

        const contains = try extractStringArrayAlloc(arena, args_obj, "contains");
        const excludes = try extractStringArrayAlloc(arena, args_obj, "excludes");
        const sources = try extractStringArrayAlloc(arena, args_obj, "sources");
        const file_globs = try extractStringArrayAlloc(arena, args_obj, "fileGlobs");
        const types = try extractStringArrayAlloc(arena, args_obj, "types");
        const plugin_preset = extractString(args_obj, "pluginPreset");
        const plugins_override = try extractPluginsOverrideAlloc(arena, args_obj, "plugins");
        const kv_predicates = try extractKvPredicatesAlloc(arena, args_obj, "kvPredicates");

        var time_start_ms = extractU64(args_obj, "timeStartMs") orelse 0;
        var time_end_ms = extractU64(args_obj, "timeEndMs") orelse 0;
        if (time_start_ms == 0 and time_end_ms == 0) {
            if (extractString(args_obj, "timePreset")) |preset| {
                const now_ms: u64 = time_parser.currentUnixNano(io) / 1_000_000;
                const resolved = resolveTimePresetRangeMs(now_ms, preset);
                time_start_ms = resolved.start_ms;
                time_end_ms = resolved.end_ms;
            }
        }

        const safe_pattern = if (!is_regex)
            try escapeLiteralScopedIfNeededAlloc(arena, raw_pattern)
        else
            raw_pattern;

        const has_time = (time_start_ms > 0 or time_end_ms > 0);
        if (safe_pattern.len == 0 and contains.len == 0 and !has_time and kv_predicates.len == 0) {
            return .{
                .text = "",
                .summary = "",
                .ok = false,
                .error_message = "Provide `pattern`, `contains`, `kvPredicates`, or a time range (`timePreset` / `timeStartMs`)",
            };
        }

        // If `pattern` is omitted while `contains` has entries, promote contains[0] to primary `pattern`.
        var eff_pattern = safe_pattern;
        var eff_contains = contains;
        if (eff_pattern.len == 0 and eff_contains.len > 0) {
            eff_pattern = if (!is_regex)
                try escapeLiteralScopedIfNeededAlloc(arena, eff_contains[0])
            else
                eff_contains[0];
            eff_contains = eff_contains[1..];
        } else if (!is_regex and eff_contains.len > 0) {
            const escaped_c = try arena.alloc([]const u8, eff_contains.len);
            for (eff_contains, 0..) |c_item, idx| {
                escaped_c[idx] = try escapeLiteralScopedIfNeededAlloc(arena, c_item);
            }
            eff_contains = escaped_c;
        }
        var eff_excludes = excludes;
        if (!is_regex and eff_excludes.len > 0) {
            const escaped_e = try arena.alloc([]const u8, eff_excludes.len);
            for (eff_excludes, 0..) |e_item, idx| {
                escaped_e[idx] = try escapeLiteralScopedIfNeededAlloc(arena, e_item);
            }
            eff_excludes = escaped_e;
        }

        const search_req = search_job.SearchRequest{
            .id = 1,
            .pattern = eff_pattern,
            .mode = if (is_regex) "regex" else "literal",
            .case = if (case_sensitive) "sensitive" else "insensitive",
            .wholeWord = whole_word,
            .contains = eff_contains,
            .excludes = eff_excludes,
            .context = 0,
            .sources = sources,
            .types = types,
            .fileGlobs = file_globs,
            .hidden = hidden,
            .respectIgnore = respect_ignore,
            .maxResults = max_results,
            .timeStartMs = time_start_ms,
            .timeEndMs = time_end_ms,
            .timeMode = "source",
            .nearbyLines = 0,
            .pluginPreset = plugin_preset,
            .plugins = plugins_override,
            .kvPredicates = kv_predicates,
        };

        var collector = McpSearchCollector{
            .arena = arena,
            .max_items = @intCast(max_results),
        };
        const cancel_flag = std.atomic.Value(bool).init(false);
        try search_job.executeSearchWithRegistry(
            self.gpa,
            io,
            std.Io.Dir.cwd(),
            self.registry,
            search_req,
            &cancel_flag,
            .{
                .ctx = &collector,
                .sendFn = McpSearchCollector.onFrame,
            },
        );

        if (collector.error_message) |err_msg| {
            return .{
                .text = "",
                .summary = "",
                .ok = false,
                .error_message = err_msg,
            };
        }

        const CompactHit = struct {
            file: []const u8,
            line: u64,
            col: u64,
            byteOffset: ?u64 = null,
            text: []const u8,
        };
        const compact_hits = try arena.alloc(CompactHit, collector.hits.items.len);
        for (collector.hits.items, 0..) |h, idx| {
            compact_hits[idx] = .{
                .file = h.file,
                .line = h.line,
                .col = h.col,
                .byteOffset = h.byteOffset,
                .text = h.text,
            };
        }

        const result_json = try file_api.stringifyAlloc(arena, .{
            .totalMatches = collector.done.totalMatches,
            .matchedLines = collector.done.matchedLines,
            .filesMatched = collector.done.filesMatched,
            .filesSearched = collector.done.filesSearched,
            .bytesSearched = collector.done.bytesSearched,
            .filesPruned = collector.done.filesPruned,
            .bytesSaved = collector.done.bytesSaved,
            .bytesScanned = collector.done.bytesScanned,
            .elapsedMs = collector.done.elapsedMs,
            .limitHit = collector.done.limitHit,
            .returnedHits = compact_hits.len,
            .hits = compact_hits,
        });
        const sum = try std.fmt.allocPrint(arena, "{d} hits / {d} files ({d:.1} ms)", .{
            collector.done.totalMatches,
            collector.done.filesMatched,
            collector.done.elapsedMs,
        });
        return .{ .text = result_json, .summary = sum };
    }
};

const McpSearchCollector = struct {
    arena: std.mem.Allocator,
    max_items: usize,
    hits: std.ArrayList(search_job.HitItem) = .empty,
    done: search_job.DoneFrame = .{
        .id = 1,
        .elapsedMs = 0,
        .filesSearched = 0,
        .filesMatched = 0,
        .totalMatches = 0,
        .matchedLines = 0,
        .bytesSearched = 0,
        .limitHit = "none",
    },
    error_message: ?[]const u8 = null,

    const Envelope = struct {
        type: []const u8 = "",
    };

    fn onFrame(ctx: *anyopaque, json_text: []const u8) anyerror!void {
        const self: *McpSearchCollector = @ptrCast(@alignCast(ctx));
        var env = std.json.parseFromSlice(Envelope, self.arena, json_text, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer env.deinit();
        const msg_type = env.value.type;

        if (std.mem.eql(u8, msg_type, "hits")) {
            var parsed = std.json.parseFromSlice(search_job.HitsFrame, self.arena, json_text, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer parsed.deinit();
            for (parsed.value.items) |item| {
                if (item.isContext) continue;
                if (self.hits.items.len >= self.max_items) break;
                try self.hits.append(self.arena, .{
                    .file = try self.arena.dupe(u8, item.file),
                    .line = item.line,
                    .col = item.col,
                    .text = try self.arena.dupe(u8, item.text),
                    .replaced = null,
                    .isContext = false,
                    .byteOffset = item.byteOffset,
                    .spans = &.{},
                });
            }
        } else if (std.mem.eql(u8, msg_type, "done")) {
            var parsed = std.json.parseFromSlice(search_job.DoneFrame, self.arena, json_text, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer parsed.deinit();
            self.done = .{
                .id = parsed.value.id,
                .elapsedMs = parsed.value.elapsedMs,
                .filesSearched = parsed.value.filesSearched,
                .filesMatched = parsed.value.filesMatched,
                .totalMatches = parsed.value.totalMatches,
                .matchedLines = parsed.value.matchedLines,
                .bytesSearched = parsed.value.bytesSearched,
                .limitHit = try self.arena.dupe(u8, parsed.value.limitHit),
                .filesPruned = parsed.value.filesPruned,
                .bytesSaved = parsed.value.bytesSaved,
                .bytesScanned = parsed.value.bytesScanned,
            };
        } else if (std.mem.eql(u8, msg_type, "error")) {
            var parsed = std.json.parseFromSlice(search_job.ErrorFrame, self.arena, json_text, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer parsed.deinit();
            self.error_message = try self.arena.dupe(u8, parsed.value.message);
        }
    }
};

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

fn elapsedMsSince(io: std.Io, start_ts: std.Io.Timestamp) f64 {
    const ns = start_ts.untilNow(io, .awake).toNanoseconds();
    return @as(f64, @floatFromInt(@max(ns, 0))) / 1_000_000.0;
}

fn buildJsonRpcResultAlloc(
    arena: std.mem.Allocator,
    id_val: std.json.Value,
    result_val: anytype,
) ![]u8 {
    return file_api.stringifyAlloc(arena, .{
        .jsonrpc = "2.0",
        .id = id_val,
        .result = result_val,
    });
}

fn buildJsonRpcErrorAlloc(
    arena: std.mem.Allocator,
    id_val: std.json.Value,
    code: i32,
    message: []const u8,
) ![]u8 {
    return file_api.stringifyAlloc(arena, .{
        .jsonrpc = "2.0",
        .id = id_val,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    });
}

fn buildToolSuccessRpcAlloc(arena: std.mem.Allocator, id_val: std.json.Value, text: []const u8) ![]u8 {
    const ContentItem = struct {
        type: []const u8 = "text",
        text: []const u8,
    };
    const items = [_]ContentItem{.{ .text = text }};
    return buildJsonRpcResultAlloc(arena, id_val, .{
        .content = &items,
        .isError = false,
    });
}

fn buildToolErrorRpcAlloc(arena: std.mem.Allocator, id_val: std.json.Value, msg: []const u8) ![]u8 {
    const ContentItem = struct {
        type: []const u8 = "text",
        text: []const u8,
    };
    const items = [_]ContentItem{.{ .text = msg }};
    return buildJsonRpcResultAlloc(arena, id_val, .{
        .content = &items,
        .isError = true,
    });
}

fn buildToolsListResponseAlloc(arena: std.mem.Allocator, id_val: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };

    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try jw.write(id_val);
    try jw.objectField("result");
    try jw.beginObject();
    try jw.objectField("tools");
    try jw.beginArray();

    for (CAPABILITIES) |cap| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(cap.name);
        try jw.objectField("description");
        try jw.write(cap.description);
        try jw.objectField("inputSchema");
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("object");
        try jw.objectField("properties");
        try jw.beginObject();
        for (cap.params) |p| {
            try jw.objectField(p.name);
            try jw.beginObject();
            if (std.mem.eql(u8, p.type, "string[]")) {
                try jw.objectField("type");
                try jw.write("array");
                try jw.objectField("items");
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("string");
                try jw.endObject();
            } else if (std.mem.eql(u8, p.type, "object[]")) {
                try jw.objectField("type");
                try jw.write("array");
                try jw.objectField("items");
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("object");
                try jw.endObject();
            } else {
                try jw.objectField("type");
                try jw.write(p.type);
            }
            try jw.objectField("description");
            try jw.write(p.description);
            try jw.endObject();
        }
        try jw.endObject(); // properties

        var req_count: usize = 0;
        for (cap.params) |p| {
            if (p.required) req_count += 1;
        }
        if (req_count > 0) {
            try jw.objectField("required");
            try jw.beginArray();
            for (cap.params) |p| {
                if (p.required) try jw.write(p.name);
            }
            try jw.endArray();
        }
        try jw.endObject(); // inputSchema
        try jw.endObject(); // tool
    }

    try jw.endArray(); // tools
    try jw.endObject(); // result
    try jw.endObject();
    return out.toOwnedSlice();
}

fn extractString(obj: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const map = obj orelse return null;
    const val = map.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn extractNestedString(obj: ?std.json.ObjectMap, outer: []const u8, inner: []const u8) ?[]const u8 {
    const map = obj orelse return null;
    const outer_val = map.get(outer) orelse return null;
    return switch (outer_val) {
        .object => |m| extractString(m, inner),
        else => null,
    };
}

fn extractBool(obj: ?std.json.ObjectMap, key: []const u8) ?bool {
    const map = obj orelse return null;
    const val = map.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

fn extractU64(obj: ?std.json.ObjectMap, key: []const u8) ?u64 {
    const map = obj orelse return null;
    const val = map.get(key) orelse return null;
    return switch (val) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| if (f >= 0) @intFromFloat(@floor(f)) else null,
        else => null,
    };
}

fn extractStringArrayAlloc(
    arena: std.mem.Allocator,
    obj: ?std.json.ObjectMap,
    key: []const u8,
) ![]const []const u8 {
    const map = obj orelse return &.{};
    const val = map.get(key) orelse return &.{};
    switch (val) {
        .array => |arr| {
            var list: std.ArrayList([]const u8) = .empty;
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| {
                        if (s.len > 0) try list.append(arena, s);
                    },
                    else => {},
                }
            }
            return list.items;
        },
        .string => |s| {
            if (s.len == 0) return &.{};
            const single = try arena.alloc([]const u8, 1);
            single[0] = s;
            return single;
        },
        else => return &.{},
    }
}

fn extractPluginsOverrideAlloc(
    arena: std.mem.Allocator,
    obj: ?std.json.ObjectMap,
    key: []const u8,
) !?source_registry.PluginsOverrideDto {
    const map = obj orelse return null;
    const val = map.get(key) orelse return null;
    const inner_map = switch (val) {
        .object => |o| o,
        else => return null,
    };
    const en = try extractStringArrayAlloc(arena, inner_map, "enable");
    const dis = try extractStringArrayAlloc(arena, inner_map, "disable");
    if (en.len == 0 and dis.len == 0) return null;
    return .{
        .enable = if (en.len > 0) en else null,
        .disable = if (dis.len > 0) dis else null,
    };
}

fn extractKvPredicatesAlloc(
    arena: std.mem.Allocator,
    obj: ?std.json.ObjectMap,
    key: []const u8,
) ![]const search_job.KvPredicateDto {
    const map = obj orelse return &.{};
    const val = map.get(key) orelse return &.{};
    const arr = switch (val) {
        .array => |a| a,
        else => return &.{},
    };
    var out: std.ArrayList(search_job.KvPredicateDto) = .empty;
    for (arr.items) |item| {
        const item_map = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const k = extractString(item_map, "key") orelse "";
        const op = extractString(item_map, "op") orelse "eq";
        const cs = extractBool(item_map, "caseSensitive") orelse false;
        const v: []const u8 = if (item_map.get("value")) |vv| switch (vv) {
            .string => |s| s,
            .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
            .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
            .bool => |b| if (b) "true" else "false",
            else => "",
        } else "";
        try out.append(arena, .{
            .key = k,
            .op = op,
            .value = v,
            .caseSensitive = cs,
        });
    }
    return out.items;
}

fn formatSearchArgsSummaryAlloc(arena: std.mem.Allocator, args_obj: ?std.json.ObjectMap) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (extractString(args_obj, "pattern")) |p| {
        if (p.len > 0) try parts.append(arena, p);
    }
    if (extractBool(args_obj, "isRegex") orelse false) {
        try parts.append(arena, "[regex]");
    }
    if (extractBool(args_obj, "caseSensitive") orelse false) {
        try parts.append(arena, "[Aa]");
    }
    if (extractBool(args_obj, "wholeWord") orelse false) {
        try parts.append(arena, "[ab]");
    }
    const contains = extractStringArrayAlloc(arena, args_obj, "contains") catch &.{};
    for (contains) |c| {
        try parts.append(arena, try std.fmt.allocPrint(arena, "+{s}", .{c}));
    }
    const excludes = extractStringArrayAlloc(arena, args_obj, "excludes") catch &.{};
    for (excludes) |e| {
        try parts.append(arena, try std.fmt.allocPrint(arena, "-{s}", .{e}));
    }
    const sources = extractStringArrayAlloc(arena, args_obj, "sources") catch &.{};
    if (sources.len > 0) {
        try parts.append(arena, try std.fmt.allocPrint(arena, "sources:{d}", .{sources.len}));
    }
    if (extractString(args_obj, "timePreset")) |tp| {
        if (tp.len > 0) try parts.append(arena, try std.fmt.allocPrint(arena, "t:{s}", .{tp}));
    }
    if (parts.items.len == 0) return "{}";
    return std.mem.join(arena, " ", parts.items);
}

fn escapeLiteralScopedIfNeededAlloc(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    // Prevent literal terms resembling "$r(...)" from being interpreted as scoped modifiers by search_job.
    if (s.len >= 4 and s[0] == '$' and std.mem.indexOfScalar(u8, s[1..], '(') != null) {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "$r(");
        for (s) |ch| {
            switch (ch) {
                '\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$' => {
                    try out.append(arena, '\\');
                    try out.append(arena, ch);
                },
                else => try out.append(arena, ch),
            }
        }
        try out.append(arena, ')');
        return out.toOwnedSlice(arena);
    }
    return s;
}

const TimeRangeMs = struct {
    start_ms: u64 = 0,
    end_ms: u64 = 0,
};

fn resolveTimePresetRangeMs(now_ms: u64, preset_raw: []const u8) TimeRangeMs {
    const preset = std.mem.trim(u8, preset_raw, " \t\r\n");
    if (preset.len == 0) return .{};
    if (std.ascii.eqlIgnoreCase(preset, "today")) {
        const day_ms: u64 = 86_400_000;
        const start_day = (now_ms / day_ms) * day_ms;
        return .{ .start_ms = start_day, .end_ms = 0 };
    }
    if (std.ascii.eqlIgnoreCase(preset, "yesterday")) {
        const day_ms: u64 = 86_400_000;
        const start_today = (now_ms / day_ms) * day_ms;
        return .{
            .start_ms = if (start_today >= day_ms) start_today - day_ms else 0,
            .end_ms = start_today,
        };
    }

    const last_ch = std.ascii.toLower(preset[preset.len - 1]);
    const mult_ms: u64 = switch (last_ch) {
        's' => 1_000,
        'm' => 60_000,
        'h' => 3_600_000,
        'd' => 86_400_000,
        else => return .{},
    };
    const num = std.fmt.parseInt(u64, preset[0 .. preset.len - 1], 10) catch return .{};
    if (num == 0) return .{};
    const delta = num *| mult_ms;
    return .{
        .start_ms = if (now_ms > delta) now_ms - delta else 1,
        .end_ms = 0,
    };
}

fn truncateUtf8(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    var cut = max_bytes;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) : (cut -= 1) {}
    return s[0..cut];
}

test "McpService handles initialize, tools/list, tools/call, disabled rejection, and configurable maxLogs (default 20)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "app.log",
        .data = "2026-11-17T10:00:00Z INFO startup ok\n2026-11-17T10:01:00Z ERROR needle timeout user=alice\n2026-11-17T10:02:00Z INFO shutdown clean\n",
    });

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_len]);

    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "logs",
        .path = tmp_path,
        .enabled = true,
    });

    {
        var svc = try McpService.init(gpa, io, tmp_path, &reg);
        defer svc.deinit(io);

        // 1. Initialize handshake & notification (notification returns null).
        const init_resp = (try svc.handleRpcPayload(
            arena,
            io,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"clientInfo\":{\"name\":\"test-agent\",\"version\":\"1.0\"}}}",
            "unit-test",
        )).?;
        try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"protocolVersion\":\"2025-03-26\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"id\":1") != null);

        const notif_resp = try svc.handleRpcPayload(
            arena,
            io,
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
            "unit-test",
        );
        try std.testing.expect(notif_resp == null);

        // 2. tools/list
        const list_resp = (try svc.handleRpcPayload(
            arena,
            io,
            "{\"jsonrpc\":\"2.0\",\"id\":\"req-2\",\"method\":\"tools/list\"}",
            "unit-test",
        )).?;
        try std.testing.expect(std.mem.indexOf(u8, list_resp, "webgrep_search") != null);
        try std.testing.expect(std.mem.indexOf(u8, list_resp, "webgrep_get_context") != null);
        try std.testing.expect(std.mem.indexOf(u8, list_resp, "webgrep_list_sources") != null);

        // 3. tools/call webgrep_list_sources
        const ls_resp = (try svc.handleRpcPayload(
            arena,
            io,
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"webgrep_list_sources\",\"arguments\":{}}}",
            "unit-test",
        )).?;
        try std.testing.expect(std.mem.indexOf(u8, ls_resp, "logs") != null);

        // 4. tools/call webgrep_search
        const search_resp = (try svc.handleRpcPayload(
            arena,
            io,
            "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"webgrep_search\",\"arguments\":{\"pattern\":\"needle\",\"contains\":[\"alice\"]}}}",
            "unit-test",
        )).?;
        try std.testing.expect(std.mem.indexOf(u8, search_resp, "\\\"totalMatches\\\":1") != null);
        try std.testing.expect(std.mem.indexOf(u8, search_resp, "logs/app.log") != null);

        // 5. tools/call webgrep_get_context
        const ctx_resp = (try svc.handleRpcPayload(
            arena,
            io,
            "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"webgrep_get_context\",\"arguments\":{\"path\":\"logs/app.log\",\"line\":2,\"context\":1}}}",
            "unit-test",
        )).?;
        try std.testing.expect(std.mem.indexOf(u8, ctx_resp, "startup ok") != null);
        try std.testing.expect(std.mem.indexOf(u8, ctx_resp, "shutdown clean") != null);

        // 6. Default maxLogs == 20, test configurable maxLogs trimming + persistence.
        const state_json_1 = try svc.buildStateJson(arena, io);
        const state_1 = try std.json.parseFromSlice(McpStateDto, arena, state_json_1, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(u32, 20), state_1.value.maxLogs);
        try std.testing.expectEqual(@as(usize, 5), state_1.value.logs.len);
        // Newest-first log order
        try std.testing.expectEqualStrings("webgrep_get_context", state_1.value.logs[0].toolName);

        try svc.updateConfig(io, .{ .maxLogs = 3 });
        const state_json_2 = try svc.buildStateJson(arena, io);
        const state_2 = try std.json.parseFromSlice(McpStateDto, arena, state_json_2, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(u32, 3), state_2.value.maxLogs);
        try std.testing.expectEqual(@as(usize, 3), state_2.value.logs.len);

        // Disable MCP and verify JSON-RPC returns -32003
        try svc.updateConfig(io, .{ .enabled = false });
        const disabled_resp = (try svc.handleRpcPayload(
            arena,
            io,
            "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/list\"}",
            "unit-test",
        )).?;
        try std.testing.expect(std.mem.indexOf(u8, disabled_resp, "-32003") != null);

        // Re-enable for persistence reload check
        try svc.updateConfig(io, .{ .enabled = true, .maxLogs = 25 });
        svc.clearLogs(io);
        const state_json_cleared = try svc.buildStateJson(arena, io);
        const state_cleared = try std.json.parseFromSlice(McpStateDto, arena, state_json_cleared, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(usize, 0), state_cleared.value.logs.len);
    }

        // Reload from mcp.json and verify persisted enabled=true & maxLogs=25
    {
        var reloaded = try McpService.init(gpa, io, tmp_path, &reg);
        defer reloaded.deinit(io);
        try std.testing.expect(reloaded.isEnabled(io));
        const state_json_reloaded = try reloaded.buildStateJson(arena, io);
        const state_reloaded = try std.json.parseFromSlice(McpStateDto, arena, state_json_reloaded, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(u32, 25), state_reloaded.value.maxLogs);

        // Verify tools/list exposes prefilter & kvPredicates schema and webgrep_search honors kvPredicates + telemetry
        const list_resp = (try reloaded.handleRpcPayload(
            arena,
            io,
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}",
            "unit-test",
        )).?;
        try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"pluginPreset\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"kvPredicates\"") != null);

        const kv_f = try tmp.dir.createFile(io, "kv.jsonl", .{ .truncate = true });
        var kv_f_mut = kv_f;
        var wb: [256]u8 = undefined;
        var fw = kv_f_mut.writer(io, &wb);
        try fw.interface.writeAll("{\"level\":\"ERROR\",\"status\":503}\n{\"level\":\"INFO\",\"status\":200}\n");
        try fw.interface.flush();
        kv_f_mut.close(io);

        const kv_search_resp = (try reloaded.handleRpcPayload(
            arena,
            io,
            "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"webgrep_search\",\"arguments\":{\"pluginPreset\":\"auto\",\"kvPredicates\":[{\"key\":\"status\",\"op\":\"gt_num\",\"value\":500}]}}}",
            "unit-test",
        )).?;
        try std.testing.expect(std.mem.indexOf(u8, kv_search_resp, "\\\"totalMatches\\\":1") != null);
        try std.testing.expect(std.mem.indexOf(u8, kv_search_resp, "\\\"filesPruned\\\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, kv_search_resp, "\\\"bytesSaved\\\":") != null);
    }
}
