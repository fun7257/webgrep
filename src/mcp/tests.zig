const std = @import("std");
const source_registry = @import("../source_registry.zig");
const types = @import("types.zig");
const service_mod = @import("service.zig");

const McpService = service_mod.McpService;
const McpStateDto = types.McpStateDto;
const DEFAULT_MAX_LOGS = types.DEFAULT_MAX_LOGS;
const PROTOCOL_VERSION = types.PROTOCOL_VERSION;

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
            "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"webgrep_search\",\"arguments\":{\"pluginPreset\":\"timeseries\",\"kvPredicates\":[{\"key\":\"status\",\"op\":\"gt_num\",\"value\":500}]}}}",
            "unit-test",
        )).?;
        try std.testing.expect(std.mem.indexOf(u8, kv_search_resp, "\\\"totalMatches\\\":1") != null);
        try std.testing.expect(std.mem.indexOf(u8, kv_search_resp, "\\\"filesPruned\\\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, kv_search_resp, "\\\"bytesSaved\\\":") != null);
    }
}
