const std = @import("std");
const prefilter = @import("../prefilter.zig");

pub const PluginsOverrideDto = struct {
    enable: ?[]const []const u8 = null,
    disable: ?[]const []const u8 = null,
};

pub const SourceConfigDto = struct {
    path: []const u8 = "",
    timeFormat: ?[]const u8 = null,
    pluginPreset: ?[]const u8 = null,
    plugins: ?PluginsOverrideDto = null,
};

pub const SourceKindMetaDto = struct {
    kind: []const u8,
    label: []const u8,
};

pub const builtin_source_kinds = [_]SourceKindMetaDto{
    .{ .kind = "dir", .label = "Local Directory" },
    .{ .kind = "file", .label = "Single File" },
};

pub const SourceInfoDto = struct {
    id: []const u8,
    kind: []const u8,
    name: []const u8,
    enabled: bool,
    ready: bool,
    summary: []const u8,
    config: SourceConfigDto,
    path: []const u8,
    exists: bool,
    pluginPreset: []const u8 = "timeseries",
    plugins: ?PluginsOverrideDto = null,
};

pub const SourcesResponse = struct {
    kinds: []const SourceKindMetaDto = &builtin_source_kinds,
    searchCount: u64 = 0,
    sources: []const SourceInfoDto,
};

pub const SearchableSource = struct {
    id: []const u8,
    kind: []const u8,
    name: []const u8,
    path: []const u8,
    enabled: bool,
    time_format: []const u8 = "",
    plugin_preset: []const u8 = "timeseries",
    plugins_enable: []const []const u8 = &.{},
    plugins_disable: []const []const u8 = &.{},
    plugin_sig: u64 = 0,
};

pub const UpsertSourceRequest = struct {
    id: ?[]const u8 = null,
    kind: []const u8 = "dir",
    name: []const u8 = "",
    path: []const u8 = "",
    config: ?SourceConfigDto = null,
    enabled: bool = true,
    timeFormat: ?[]const u8 = null,
    pluginPreset: ?[]const u8 = null,
    plugins: ?PluginsOverrideDto = null,
};

pub const ToggleSourceRequest = struct {
    id: ?[]const u8 = null,
    enabled: ?bool = null,
};

pub const DeleteSourceRequest = struct {
    id: []const u8 = "",
};

pub const DirSuggestEntry = struct {
    name: []const u8,
    path: []const u8,
    isDir: bool = true,

    pub fn lessThan(_: void, a: DirSuggestEntry, b: DirSuggestEntry) bool {
        if (a.isDir != b.isDir) return a.isDir; // directories first, then files
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

pub const DirSuggestResponse = struct {
    kind: []const u8 = "dir",
    entries: []const DirSuggestEntry,
};

pub const PersistedSource = struct {
    id: []const u8 = "",
    kind: []const u8 = "dir",
    name: []const u8,
    path: []const u8 = "",
    config: ?SourceConfigDto = null,
    enabled: bool = true,
    pluginPreset: ?[]const u8 = null,
    plugins: ?PluginsOverrideDto = null,
};

pub const PersistedFile = struct {
    version: u32 = 3,
    searchCount: u64 = 0,
    sources: []const PersistedSource = &.{},
};

pub const SourceRecord = struct {
    id: []u8,
    kind: []u8,
    name: []u8,
    path: []u8,
    enabled: bool = true,
    time_format: []u8,
    plugin_preset: []u8,
    plugins_enable: [][]u8,
    plugins_disable: [][]u8,

    pub fn deinit(self: *SourceRecord, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.kind);
        gpa.free(self.name);
        gpa.free(self.path);
        gpa.free(self.time_format);
        gpa.free(self.plugin_preset);
        freeStringList(gpa, self.plugins_enable);
        freeStringList(gpa, self.plugins_disable);
    }
};

pub const RegistryError = error{
    UnsupportedSourceKind,
    EmptyPath,
    DirectoryNotFound,
    FileNotFound,
    ExpectedDirFoundFile,
    ExpectedFileFoundDir,
    InvalidPluginPreset,
    InvalidPluginId,
    DuplicateSourceName,
    SourceNotFound,
};

pub fn freeStringList(alloc: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| alloc.free(item);
    if (items.len > 0) alloc.free(items);
}

pub fn normalizePluginPresetStrict(raw_opt: ?[]const u8) !?[]const u8 {
    const raw = raw_opt orelse return null;
    const p = prefilter.Preset.parseStrict(raw) orelse return error.InvalidPluginPreset;
    return p.asStr();
}

pub fn clonePluginIdsAlloc(
    alloc: std.mem.Allocator,
    raw_list_opt: ?[]const []const u8,
    strict: bool,
) ![][]u8 {
    const raw_list = raw_list_opt orelse return alloc.alloc([]u8, 0);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |it| alloc.free(it);
        out.deinit(alloc);
    }
    for (raw_list) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) continue;
        const pid = prefilter.PluginId.parse(trimmed) orelse {
            if (strict) return error.InvalidPluginId;
            continue;
        };
        const canon = pid.asStr();
        var dup = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, canon)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const copy = try alloc.dupe(u8, canon);
        errdefer alloc.free(copy);
        try out.append(alloc, copy);
    }
    return out.toOwnedSlice(alloc);
}

pub fn makePluginsOverrideDtoFromConst(
    enable: []const []const u8,
    disable: []const []const u8,
) ?PluginsOverrideDto {
    if (enable.len == 0 and disable.len == 0) return null;
    return .{
        .enable = if (enable.len > 0) enable else null,
        .disable = if (disable.len > 0) disable else null,
    };
}

pub fn makePluginsOverrideDtoFromOwned(
    arena: std.mem.Allocator,
    enable: []const []u8,
    disable: []const []u8,
) !?PluginsOverrideDto {
    if (enable.len == 0 and disable.len == 0) return null;
    var en_const: ?[]const []const u8 = null;
    if (enable.len > 0) {
        const s = try arena.alloc([]const u8, enable.len);
        for (enable, 0..) |it, i| s[i] = it;
        en_const = s;
    }
    var dis_const: ?[]const []const u8 = null;
    if (disable.len > 0) {
        const s = try arena.alloc([]const u8, disable.len);
        for (disable, 0..) |it, i| s[i] = it;
        dis_const = s;
    }
    return .{
        .enable = en_const,
        .disable = dis_const,
    };
}

/// Generates a standard 36-character RFC 4122 UUID v4 string (`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`).
pub fn generateUuidV4Alloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant RFC 4122

    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
}

pub fn isValidUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |ch, idx| {
        if (idx == 8 or idx == 13 or idx == 18 or idx == 23) {
            if (ch != '-') return false;
        } else {
            if (!std.ascii.isHex(ch)) return false;
        }
    }
    return true;
}

pub fn sanitizeNameAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (trimmed) |ch| {
        if (ch == '/' or ch == '\\' or ch == 0 or ch == ':' or ch == '@' or std.ascii.isWhitespace(ch)) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '-') {
                try out.append(allocator, '-');
            }
        } else {
            try out.append(allocator, ch);
        }
        if (out.items.len >= 64) break;
    }
    while (out.items.len > 0 and (out.items[0] == '.' or out.items[0] == '-')) {
        _ = out.orderedRemove(0);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}
