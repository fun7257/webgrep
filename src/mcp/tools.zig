const std = @import("std");
const file_api = @import("../file_api.zig");
const prefilter = @import("../prefilter.zig");
const search_job = @import("../search_job.zig");
const source_registry = @import("../source_registry.zig");
const time_parser = @import("../time_parser.zig");
const mcp_types = @import("types.zig");
const rpc = @import("rpc_helpers.zig");
const service_mod = @import("service.zig");

const McpService = service_mod.McpService;
const ToolTextOut = mcp_types.ToolTextOut;
const McpStatsDto = mcp_types.McpStatsDto;
const SERVER_NAME = mcp_types.SERVER_NAME;
const SERVER_VERSION = mcp_types.SERVER_VERSION;
const PROTOCOL_VERSION = mcp_types.PROTOCOL_VERSION;
const ENDPOINT_PATH = mcp_types.ENDPOINT_PATH;
const extractString = rpc.extractString;
const extractBool = rpc.extractBool;
const extractU64 = rpc.extractU64;
const extractStringArrayAlloc = rpc.extractStringArrayAlloc;
const extractPluginsOverrideAlloc = rpc.extractPluginsOverrideAlloc;
const extractKvPredicatesAlloc = rpc.extractKvPredicatesAlloc;
const escapeLiteralScopedIfNeededAlloc = rpc.escapeLiteralScopedIfNeededAlloc;
const resolveTimePresetRangeMs = rpc.resolveTimePresetRangeMs;

pub fn executeToolListSources(
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

pub fn executeToolStatus(self: *McpService, arena: std.mem.Allocator, io: std.Io) !ToolTextOut {
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

pub fn executeToolGetContext(
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

pub fn executeToolSearch(
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
