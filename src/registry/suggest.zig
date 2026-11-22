const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");
const types = @import("types.zig");
const store_mod = @import("store.zig");

const SourceRegistry = store_mod.SourceRegistry;
const DirSuggestEntry = types.DirSuggestEntry;
const DirSuggestResponse = types.DirSuggestResponse;

/// Generic source driver completion endpoint (`/api/sources/complete?kind=dir|file&q=...`).
pub fn buildSourceCompletionJson(
    self: *SourceRegistry,
    arena: std.mem.Allocator,
    io: std.Io,
    kind: []const u8,
    raw_query: []const u8,
) ![]u8 {
    const eff_kind = if (kind.len == 0) "dir" else kind;
    if (!std.mem.eql(u8, eff_kind, "dir") and !std.mem.eql(u8, eff_kind, "file")) {
        return file_api.stringifyAlloc(arena, DirSuggestResponse{
            .kind = eff_kind,
            .entries = &.{},
        });
    }
    return buildPathSuggestionsJson(self, arena, io, eff_kind, raw_query);
}

/// Provides server filesystem directory autocomplete (`kind == "dir"`).
pub fn buildDirSuggestionsJson(
    self: *SourceRegistry,
    arena: std.mem.Allocator,
    io: std.Io,
    raw_query: []const u8,
) ![]u8 {
    return buildPathSuggestionsJson(self, arena, io, "dir", raw_query);
}

/// Provides server filesystem path autocomplete tailored to the selected `kind` (`"dir"` or `"file"`).
pub fn buildPathSuggestionsJson(
    self: *SourceRegistry,
    arena: std.mem.Allocator,
    io: std.Io,
    kind: []const u8,
    raw_query: []const u8,
) ![]u8 {
    const is_file_mode = std.mem.eql(u8, kind, "file");
    const expanded = try self.expandTildeAlloc(arena, raw_query);
    var entries: std.ArrayList(DirSuggestEntry) = .empty;
    const max_entries: usize = 50;

    const search_target = if (expanded.len == 0) "." else expanded;
    const ends_with_sep = expanded.len > 0 and expanded[expanded.len - 1] == '/';

    // If the exact path matches the requested target type, include it first (resolved to realPath)
    if (!ends_with_sep) {
        if (std.Io.Dir.cwd().statFile(io, search_target, .{})) |exact_st| {
            if (!is_file_mode and exact_st.kind == .directory) {
                if (std.Io.Dir.cwd().openDir(io, search_target, .{ .iterate = true })) |exact_dir_val| {
                    var exact_dir = exact_dir_val;
                    defer exact_dir.close(io);
                    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                    if (exact_dir.realPath(io, &real_buf)) |n| {
                        const real_str = try arena.dupe(u8, real_buf[0..n]);
                        const base = std.fs.path.basename(real_str);
                        try entries.append(arena, .{
                            .name = if (base.len > 0) try arena.dupe(u8, base) else real_str,
                            .path = real_str,
                            .isDir = true,
                        });
                    } else |_| {}
                } else |_| {}
            } else if (is_file_mode and exact_st.kind == .file) {
                const exact_parent = std.fs.path.dirname(search_target) orelse ".";
                const exact_base = std.fs.path.basename(search_target);
                if (exact_base.len > 0) {
                    if (std.Io.Dir.cwd().openDir(io, exact_parent, .{})) |pdir_val| {
                        var pdir = pdir_val;
                        defer pdir.close(io);
                        var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        const p_real = if (pdir.realPath(io, &real_buf)) |n|
                            real_buf[0..n]
                        else |_|
                            exact_parent;
                        const real_file = if (std.mem.eql(u8, p_real, "/"))
                            try std.fmt.allocPrint(arena, "/{s}", .{exact_base})
                        else
                            try std.fmt.allocPrint(arena, "{s}/{s}", .{ p_real, exact_base });
                        try entries.append(arena, .{
                            .name = try arena.dupe(u8, exact_base),
                            .path = real_file,
                            .isDir = false,
                        });
                    } else |_| {}
                }
            }
        } else |_| {}
    }

    const exact_count = entries.items.len;

    const dir_to_open: []const u8 = if (ends_with_sep)
        search_target
    else
        (std.fs.path.dirname(search_target) orelse ".");

    const filter_prefix: []const u8 = if (ends_with_sep)
        ""
    else
        std.fs.path.basename(search_target);

    if (std.Io.Dir.cwd().openDir(io, dir_to_open, .{ .iterate = true })) |parent_val| {
        var parent_dir = parent_val;
        defer parent_dir.close(io);

        var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const parent_real = if (parent_dir.realPath(io, &real_buf)) |n|
            try arena.dupe(u8, real_buf[0..n])
        else |_|
            dir_to_open;

        var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
        var lister = libwebgrep.walk_list.Lister.init(parent_dir, &scratch);
        var batch: [64]std.Io.Dir.Entry = undefined;

        outer: while (true) {
            const count = lister.fill(io, &batch) catch break;
            if (count == 0) break;
            for (batch[0..count]) |item| {
                if (item.name.len == 0) continue;
                if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
                if (file_api.isAlwaysSkippedDir(item.name)) continue;
                if (filter_prefix.len == 0 and item.name[0] == '.') continue;
                if (filter_prefix.len > 0 and filter_prefix[0] != '.' and item.name[0] == '.') continue;

                var is_dir = item.kind == .directory;
                var is_file = item.kind == .file;
                if (item.kind == .sym_link or item.kind == .unknown) {
                    if (parent_dir.statFile(io, item.name, .{})) |st| {
                        is_dir = st.kind == .directory;
                        is_file = st.kind == .file;
                    } else |_| continue;
                }
                if (!is_file_mode) {
                    if (!is_dir) continue;
                } else {
                    if (!is_dir and !is_file) continue;
                }

                if (filter_prefix.len > 0 and !std.ascii.eqlIgnoreCase(filter_prefix, ".")) {
                    var matched = false;
                    if (item.name.len >= filter_prefix.len) {
                        var k: usize = 0;
                        while (k <= item.name.len - filter_prefix.len) : (k += 1) {
                            if (std.ascii.eqlIgnoreCase(item.name[k .. k + filter_prefix.len], filter_prefix)) {
                                matched = true;
                                break;
                            }
                        }
                    }
                    if (!matched) continue;
                }

                const full_path = if (std.mem.eql(u8, parent_real, "/"))
                    try std.fmt.allocPrint(arena, "/{s}", .{item.name})
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ parent_real, item.name });

                var dup = false;
                for (entries.items) |e| {
                    if (std.mem.eql(u8, e.path, full_path)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;

                try entries.append(arena, .{
                    .name = try arena.dupe(u8, item.name),
                    .path = full_path,
                    .isDir = is_dir,
                });
                if (entries.items.len >= 256) break :outer;
            }
        }
    } else |_| {}

    if (entries.items.len > exact_count + 1) {
        std.mem.sort(DirSuggestEntry, entries.items[exact_count..], {}, DirSuggestEntry.lessThan);
    }

    const final_entries = if (entries.items.len > max_entries)
        entries.items[0..max_entries]
    else
        entries.items;

    return file_api.stringifyAlloc(arena, DirSuggestResponse{
        .kind = if (is_file_mode) "file" else "dir",
        .entries = final_entries,
    });
}
