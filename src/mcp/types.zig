const std = @import("std");

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
        .description = "Fast SIMD/regex search across registered WebGrep sources (local dirs, files, archives) with same-line AND/NOT filtering and time window pruning.",
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
            .{ .name = "pluginPreset", .type = "string", .required = false, .description = "Source mode override: timeseries (log) | code" },
            .{ .name = "plugins", .type = "object", .required = false, .description = "Per-query plugin overrides: { enable?: string[], disable?: string[] }" },
            .{ .name = "kvPredicates", .type = "object[]", .required = false, .description = "JSON/logfmt structured line predicates: [{ key, op: eq|neq|contains|gt_num|lt_num|exists, value, caseSensitive }]" },
            .{ .name = "maxResults", .type = "integer", .required = false, .description = "Max hits to return (default 50, range 1..500)" },
        },
    },
    .{
        .name = "webgrep_get_context",
        .category = "context",
        .description = "Read surrounding lines from any matched path using O(window) positional pread (supports plain files, compressed logs, and archive::entry virtual paths).",
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
        .description = "List configured WebGrep data sources with IDs, kinds (dir/file), paths, readiness, and time-parsing format.",
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

pub const McpStateEnvelope = struct {
    type: []const u8 = "mcp_state",
    state: McpStateDto,
};

pub const PersistedMcpConfig = struct {
    version: u32 = 1,
    enabled: bool = true,
    maxLogs: u32 = DEFAULT_MAX_LOGS,
};

pub const UpdateMcpConfigRequest = struct {
    enabled: ?bool = null,
    maxLogs: ?u32 = null,
};

pub const OwnedLogEntry = struct {
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

    pub fn deinit(self: *OwnedLogEntry, gpa: std.mem.Allocator) void {
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

pub const ToolTextOut = struct {
    text: []const u8,
    summary: []const u8,
    ok: bool = true,
    error_message: []const u8 = "",
};
