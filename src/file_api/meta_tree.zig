const std = @import("std");
const libwebgrep = @import("libwebgrep");
const prefilter = @import("../prefilter.zig");
const paths = @import("paths.zig");

const builtin_types = paths.builtin_types;
const sanitizeRelPath = paths.sanitizeRelPath;
const isAlwaysSkippedDir = paths.isAlwaysSkippedDir;
const stringifyAlloc = paths.stringifyAlloc;

pub const PluginMetaDto = struct {
    id: []const u8,
    domain: []const u8,
    nameKey: []const u8,
    description: []const u8,
    stages: []const []const u8,
    defaultPresets: []const []const u8,
    costHint: []const u8,
};

pub const PresetMetaDto = struct {
    id: []const u8,
    nameKey: []const u8,
    description: []const u8,
    defaultPlugins: []const []const u8,
};

fn comptimeStageStrs(comptime stages: []const prefilter.Stage) []const []const u8 {
    comptime {
        var arr: [stages.len][]const u8 = undefined;
        for (stages, 0..) |st, i| arr[i] = st.asStr();
        const frozen = arr;
        return &frozen;
    }
}

fn comptimePresetStrs(comptime presets: []const prefilter.Preset) []const []const u8 {
    comptime {
        var arr: [presets.len][]const u8 = undefined;
        for (presets, 0..) |p, i| arr[i] = p.asStr();
        const frozen = arr;
        return &frozen;
    }
}

fn comptimePluginIdStrs(comptime pids: []const prefilter.PluginId) []const []const u8 {
    comptime {
        var arr: [pids.len][]const u8 = undefined;
        for (pids, 0..) |pid, i| arr[i] = pid.asStr();
        const frozen = arr;
        return &frozen;
    }
}

pub const builtin_plugins: [prefilter.PLUGIN_CATALOG.len]PluginMetaDto = blk: {
    var out: [prefilter.PLUGIN_CATALOG.len]PluginMetaDto = undefined;
    for (prefilter.PLUGIN_CATALOG, 0..) |entry, i| {
        out[i] = .{
            .id = entry.id_str,
            .domain = entry.domain.asStr(),
            .nameKey = entry.name_key,
            .description = entry.description,
            .stages = comptimeStageStrs(entry.stages),
            .defaultPresets = comptimePresetStrs(entry.default_presets),
            .costHint = entry.cost_hint,
        };
    }
    break :blk out;
};

pub const builtin_presets: [prefilter.PRESET_CATALOG.len]PresetMetaDto = blk: {
    var out: [prefilter.PRESET_CATALOG.len]PresetMetaDto = undefined;
    for (prefilter.PRESET_CATALOG, 0..) |entry, i| {
        out[i] = .{
            .id = entry.id_str,
            .nameKey = entry.name_key,
            .description = entry.description,
            .defaultPlugins = comptimePluginIdStrs(entry.default_plugins),
        };
    }
    break :blk out;
};

pub const MetaResponse = struct {
    rootLabel: []const u8,
    root: []const u8,
    engine: []const u8 = "libwebgrep 0.5.0 · SIMD",
    types: []const []const u8 = &builtin_types,
    scopes: []const []const u8 = &.{},
    plugins: []const PluginMetaDto = &builtin_plugins,
    presets: []const PresetMetaDto = &builtin_presets,
};

pub fn buildMetaJson(arena: std.mem.Allocator, root_path: []const u8, root_label: []const u8) ![]u8 {
    const resp = MetaResponse{
        .rootLabel = root_label,
        .root = root_path,
    };
    return stringifyAlloc(arena, resp);
}

pub fn buildMetaWithScopesJson(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    root_path: []const u8,
    root_label: []const u8,
) ![]u8 {
    var scopes: std.ArrayList([]const u8) = .empty;
    const max_scopes: usize = 120;

    var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
    var lister = libwebgrep.walk_list.Lister.init(root_dir, &scratch);
    var batch: [128]std.Io.Dir.Entry = undefined;

    var top_dirs: std.ArrayList([]const u8) = .empty;
    var top_files: std.ArrayList([]const u8) = .empty;

    outer: while (true) {
        const count = lister.fill(io, &batch) catch break;
        if (count == 0) break;
        for (batch[0..count]) |item| {
            if (item.name.len == 0 or item.name[0] == '.') continue;
            if (isAlwaysSkippedDir(item.name)) continue;

            var is_dir = item.kind == .directory;
            var is_file = item.kind == .file;
            if (item.kind == .sym_link or item.kind == .unknown) {
                if (root_dir.statFile(io, item.name, .{})) |st| {
                    is_dir = st.kind == .directory;
                    is_file = st.kind == .file;
                } else |_| continue;
            }
            if (is_dir) {
                try top_dirs.append(arena, try arena.dupe(u8, item.name));
            } else if (is_file) {
                try top_files.append(arena, try arena.dupe(u8, item.name));
            }
            if (top_dirs.items.len + top_files.items.len >= max_scopes) break :outer;
        }
    }

    // Add top-level directories first (and scan 1 level inside each top-level dir)
    for (top_dirs.items) |dname| {
        if (scopes.items.len >= max_scopes) break;
        try scopes.append(arena, dname);

        if (root_dir.openDir(io, dname, .{ .iterate = true })) |sub_val| {
            var sub_dir = sub_val;
            defer sub_dir.close(io);
            var sub_scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
            var sub_lister = libwebgrep.walk_list.Lister.init(sub_dir, &sub_scratch);
            var sub_batch: [64]std.Io.Dir.Entry = undefined;
            while (scopes.items.len < max_scopes) {
                const sc = sub_lister.fill(io, &sub_batch) catch break;
                if (sc == 0) break;
                for (sub_batch[0..sc]) |sub_item| {
                    if (sub_item.name.len == 0 or sub_item.name[0] == '.') continue;
                    if (isAlwaysSkippedDir(sub_item.name)) continue;
                    if (scopes.items.len >= max_scopes) break;
                    const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dname, sub_item.name });
                    try scopes.append(arena, rel);
                }
            }
        } else |_| {}
    }

    for (top_files.items) |fname| {
        if (scopes.items.len >= max_scopes) break;
        try scopes.append(arena, fname);
    }

    const resp = MetaResponse{
        .rootLabel = root_label,
        .root = root_path,
        .scopes = scopes.items,
    };
    return stringifyAlloc(arena, resp);
}

pub const TreeEntry = struct {
    name: []const u8,
    path: []const u8,
    dir: bool,
    size: u64,

    pub fn lessThan(_: void, a: TreeEntry, b: TreeEntry) bool {
        if (a.dir != b.dir) return a.dir; // directories first
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

pub const TreeResponse = struct {
    path: []const u8,
    truncated: bool,
    entries: []const TreeEntry,
};

pub fn buildTreeJson(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    rel_path_raw: []const u8,
) ![]u8 {
    const clean_rel = try sanitizeRelPath(rel_path_raw);
    const sub_path = if (clean_rel.len == 0) "." else clean_rel;

    var dir = try root_dir.openDir(io, sub_path, .{ .iterate = true });
    defer dir.close(io);

    var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
    var lister = libwebgrep.walk_list.Lister.init(dir, &scratch);
    var batch: [128]std.Io.Dir.Entry = undefined;

    var entries: std.ArrayList(TreeEntry) = .empty;
    var truncated = false;
    const max_entries: usize = 1000;

    outer: while (true) {
        const count = try lister.fill(io, &batch);
        if (count == 0) break;
        for (batch[0..count]) |item| {
            if (item.name.len == 0) continue;
            if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
            if (isAlwaysSkippedDir(item.name)) continue;

            if (entries.items.len >= max_entries) {
                truncated = true;
                break :outer;
            }

            var is_dir = item.kind == .directory;
            var size: u64 = 0;

            if (item.kind == .file) {
                if (dir.statFile(io, item.name, .{})) |st| {
                    size = st.size;
                } else |_| {}
            } else if (item.kind == .sym_link or item.kind == .unknown) {
                if (dir.statFile(io, item.name, .{})) |st| {
                    is_dir = st.kind == .directory;
                    if (!is_dir) size = st.size;
                } else |_| {
                    continue;
                }
            }

            const name_duped = try arena.dupe(u8, item.name);
            const entry_path = if (clean_rel.len == 0)
                name_duped
            else
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ clean_rel, name_duped });

            try entries.append(arena, .{
                .name = name_duped,
                .path = entry_path,
                .dir = is_dir,
                .size = size,
            });
        }
    }

    std.mem.sort(TreeEntry, entries.items, {}, TreeEntry.lessThan);

    const resp = TreeResponse{
        .path = clean_rel,
        .truncated = truncated,
        .entries = entries.items,
    };
    return stringifyAlloc(arena, resp);
}
