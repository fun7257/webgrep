const std = @import("std");
const file_api = @import("../file_api.zig");
const search_job = @import("../search_job.zig");
const source_registry = @import("../source_registry.zig");
const time_parser = @import("../time_parser.zig");
const mcp_types = @import("types.zig");

const CAPABILITIES = mcp_types.CAPABILITIES;

pub fn elapsedMsSince(io: std.Io, start_ts: std.Io.Timestamp) f64 {
    const ns = start_ts.untilNow(io, .awake).toNanoseconds();
    return @as(f64, @floatFromInt(@max(ns, 0))) / 1_000_000.0;
}

pub fn buildJsonRpcResultAlloc(
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

pub fn buildJsonRpcErrorAlloc(
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

pub fn buildToolSuccessRpcAlloc(arena: std.mem.Allocator, id_val: std.json.Value, text: []const u8) ![]u8 {
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

pub fn buildToolErrorRpcAlloc(arena: std.mem.Allocator, id_val: std.json.Value, msg: []const u8) ![]u8 {
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

pub fn buildToolsListResponseAlloc(arena: std.mem.Allocator, id_val: std.json.Value) ![]u8 {
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

pub fn extractString(obj: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const map = obj orelse return null;
    const val = map.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn extractNestedString(obj: ?std.json.ObjectMap, outer: []const u8, inner: []const u8) ?[]const u8 {
    const map = obj orelse return null;
    const outer_val = map.get(outer) orelse return null;
    return switch (outer_val) {
        .object => |m| extractString(m, inner),
        else => null,
    };
}

pub fn extractBool(obj: ?std.json.ObjectMap, key: []const u8) ?bool {
    const map = obj orelse return null;
    const val = map.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

pub fn extractU64(obj: ?std.json.ObjectMap, key: []const u8) ?u64 {
    const map = obj orelse return null;
    const val = map.get(key) orelse return null;
    return switch (val) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| if (f >= 0) @intFromFloat(@floor(f)) else null,
        else => null,
    };
}

pub fn extractStringArrayAlloc(
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

pub fn extractPluginsOverrideAlloc(
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

pub fn extractKvPredicatesAlloc(
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

pub fn formatSearchArgsSummaryAlloc(arena: std.mem.Allocator, args_obj: ?std.json.ObjectMap) ![]const u8 {
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

pub fn escapeLiteralScopedIfNeededAlloc(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
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

pub const TimeRangeMs = struct {
    start_ms: u64 = 0,
    end_ms: u64 = 0,
};

pub fn resolveTimePresetRangeMs(now_ms: u64, preset_raw: []const u8) TimeRangeMs {
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

pub fn truncateUtf8(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    var cut = max_bytes;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) : (cut -= 1) {}
    return s[0..cut];
}
