const std = @import("std");

pub const MAX_CACHE_ENTRIES: usize = 64;
pub const MAX_CACHE_BYTES: usize = 32 * 1024 * 1024; // 32 MB total budget for query result cache
pub const MAX_ITEMS_PER_ENTRY: usize = 20_000;
pub const MAX_NEGATIVE_FILE_ENTRIES: usize = 512;
pub const MAX_HOT_MMAP_FILES: usize = 32;
pub const MAX_HOT_FILE_MAP_BYTES: u64 = 512 * 1024 * 1024; // 512 MiB full-file mapping ceiling (never truncates files!)
pub const MAX_DIR_CACHE_ENTRIES: usize = 64;

pub const CachedSpan = struct {
    start: usize,
    end: usize,
};

pub const CachedHitItem = struct {
    file: []const u8,
    line: u64,
    col: u64,
    text: []const u8,
    replaced: ?[]const u8,
    isContext: bool,
    spans: []const CachedSpan,
    raw_item_json: []const u8 = "",
};

pub const FileMtimeRecord = struct {
    rel_path: []const u8,
    mtime_ns: i96,
    file_size: u64 = 0,
    inode: std.Io.File.INode = 0,
};

pub const CachedQueryEntry = struct {
    arena: std.heap.ArenaAllocator,
    exact_hash: u64,
    tasks_fingerprint: u64,
    heat_epoch: u64,
    pattern: []const u8,
    mode: []const u8,
    case_mode: []const u8,
    whole_word: bool,
    whole_line: bool,
    invert: bool,
    context: u32,
    has_replacement: bool,
    max_results: u64,
    contains: []const []const u8,
    excludes: []const []const u8,
    file_mtimes: []const FileMtimeRecord,
    items: []const CachedHitItem,
    raw_items_json: []const u8 = "[]",
    files_searched: u64,
    files_matched: u64,
    total_matches: u64,
    matched_lines: u64,
    bytes_searched: u64,
    limit_hit: bool,
    all_lines_exact: bool = true,
    approx_bytes: usize,
    access_tick: u64,

    pub fn deinit(self: *CachedQueryEntry) void {
        self.arena.deinit();
    }
};

pub const NegativeFileEntry = struct {
    valid: bool = false,
    rel_path_hash: u64 = 0,
    rel_path_buf: [192]u8 = undefined,
    rel_path_len: u8 = 0,
    mtime_ns: i96 = 0,
    file_size: u64 = 0,
    inode: std.Io.File.INode = 0,
    file_bytes: u64 = 0,
    pattern_buf: [128]u8 = undefined,
    pattern_len: u8 = 0,
    case_insensitive: bool = true,
    access_tick: u64 = 0,

    pub fn relPath(self: *const NegativeFileEntry) []const u8 {
        return self.rel_path_buf[0..self.rel_path_len];
    }

    pub fn pattern(self: *const NegativeFileEntry) []const u8 {
        return self.pattern_buf[0..self.pattern_len];
    }
};

pub const HotFileMapEntry = struct {
    valid: bool = false,
    stale: bool = false,
    rel_path_hash: u64 = 0,
    rel_path_buf: [192]u8 = undefined,
    rel_path_len: u8 = 0,
    mtime_ns: i96 = 0,
    file_size: u64 = 0,
    inode: std.Io.File.INode = 0,
    file: std.Io.File = undefined,
    mm: std.Io.File.MemoryMap = undefined,
    ref_count: usize = 0,
    access_tick: u64 = 0,

    pub fn relPath(self: *const HotFileMapEntry) []const u8 {
        return self.rel_path_buf[0..self.rel_path_len];
    }
};

pub const HotFileLease = struct {
    slot_idx: usize,
    slice: []const u8,
};

pub const CachedDirEntry = struct {
    name: []const u8,
    is_dir: bool,
};

pub const DirTopologySlot = struct {
    valid: bool = false,
    key_hash: u64 = 0,
    dir_mtime_ns: i96 = 0,
    dir_inode: std.Io.File.INode = 0,
    hidden: bool = false,
    arena: ?std.heap.ArenaAllocator = null,
    key_path: []const u8 = "",
    entries: []const CachedDirEntry = &.{},
    access_tick: u64 = 0,

    pub fn deinit(self: *DirTopologySlot) void {
        if (self.arena) |*a| {
            a.deinit();
            self.arena = null;
        }
        self.valid = false;
        self.entries = &.{};
        self.key_path = "";
    }
};

pub const SearchCache = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(CachedQueryEntry) = .empty,
    total_bytes: usize = 0,
    tick: u64 = 0,
    negative_files: [MAX_NEGATIVE_FILE_ENTRIES]NegativeFileEntry = @splat(.{}),
    hot_mmap_files: [MAX_HOT_MMAP_FILES]HotFileMapEntry = @splat(.{}),
    dir_slots: [MAX_DIR_CACHE_ENTRIES]DirTopologySlot = @splat(.{}),

    pub fn deinit(self: *SearchCache, gpa: std.mem.Allocator, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.entries.items) |*e| e.deinit();
        self.entries.deinit(gpa);
        self.total_bytes = 0;
        for (&self.hot_mmap_files) |*hf| {
            if (hf.valid and hf.ref_count == 0) {
                hf.mm.destroy(io);
                hf.file.close(io);
                hf.valid = false;
            }
        }
        for (&self.dir_slots) |*ds| {
            ds.deinit();
        }
    }

    pub fn clear(self: *SearchCache, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.entries.items) |*e| e.deinit();
        self.entries.clearRetainingCapacity();
        self.total_bytes = 0;
        for (&self.negative_files) |*nf| nf.valid = false;
        for (&self.hot_mmap_files) |*hf| {
            if (hf.valid) {
                if (hf.ref_count == 0) {
                    hf.mm.destroy(io);
                    hf.file.close(io);
                    hf.valid = false;
                } else {
                    hf.stale = true;
                }
            }
        }
        for (&self.dir_slots) |*ds| {
            ds.deinit();
        }
    }

    pub fn lookupDirTopology(
        self: *SearchCache,
        io: std.Io,
        caller_arena: std.mem.Allocator,
        key_path: []const u8,
        hidden: bool,
        dir_mtime_ns: i96,
        dir_inode: std.Io.File.INode,
    ) ?[]CachedDirEntry {
        if (key_path.len == 0) return null;
        const key_hash = std.hash.Wyhash.hash(@intFromBool(hidden), key_path);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (&self.dir_slots) |*ds| {
            if (!ds.valid) continue;
            if (ds.key_hash != key_hash or ds.hidden != hidden) continue;
            if (!std.mem.eql(u8, ds.key_path, key_path)) continue;
            if (ds.dir_mtime_ns != dir_mtime_ns or ds.dir_inode != dir_inode) {
                ds.deinit();
                return null;
            }
            self.tick +%= 1;
            ds.access_tick = self.tick;
            const out = caller_arena.alloc(CachedDirEntry, ds.entries.len) catch return null;
            for (ds.entries, 0..) |e, i| {
                out[i] = .{
                    .name = caller_arena.dupe(u8, e.name) catch return null,
                    .is_dir = e.is_dir,
                };
            }
            return out;
        }
        return null;
    }

    pub fn storeDirTopology(
        self: *SearchCache,
        gpa: std.mem.Allocator,
        io: std.Io,
        key_path: []const u8,
        hidden: bool,
        dir_mtime_ns: i96,
        dir_inode: std.Io.File.INode,
        entries: []const CachedDirEntry,
    ) void {
        if (key_path.len == 0 or entries.len > 4096) return;
        const key_hash = std.hash.Wyhash.hash(@intFromBool(hidden), key_path);

        var slot_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer slot_arena.deinit();
        const alloc = slot_arena.allocator();

        const kp_dup = alloc.dupe(u8, key_path) catch return;
        const entries_dup = alloc.alloc(CachedDirEntry, entries.len) catch return;
        for (entries, 0..) |e, i| {
            entries_dup[i] = .{
                .name = alloc.dupe(u8, e.name) catch return,
                .is_dir = e.is_dir,
            };
        }

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.tick +%= 1;
        var victim_idx: usize = 0;
        var oldest_tick: u64 = std.math.maxInt(u64);
        for (&self.dir_slots, 0..) |*ds, idx| {
            if (!ds.valid) {
                victim_idx = idx;
                break;
            }
            if (ds.key_hash == key_hash and ds.hidden == hidden and std.mem.eql(u8, ds.key_path, key_path)) {
                victim_idx = idx;
                break;
            }
            if (ds.access_tick < oldest_tick) {
                oldest_tick = ds.access_tick;
                victim_idx = idx;
            }
        }

        self.dir_slots[victim_idx].deinit();
        self.dir_slots[victim_idx] = .{
            .valid = true,
            .key_hash = key_hash,
            .dir_mtime_ns = dir_mtime_ns,
            .dir_inode = dir_inode,
            .hidden = hidden,
            .arena = slot_arena,
            .key_path = kp_dup,
            .entries = entries_dup,
            .access_tick = self.tick,
        };
    }

    /// Acquires a persistent read-only `MemoryMap` slice for `rel_path`, strongly validated by `(mtime_ns, file_size, inode)`.
    /// Never maps a partial/truncated prefix: if `file_size > max_map_bytes`, returns `null` so the caller streams the full file.
    /// If the file on disk changed by even 1 byte, 1ns, or inode replacement (`rename`), any previous mapping is retired and a fresh mapping is created.
    pub fn acquireHotFileSlice(
        self: *SearchCache,
        io: std.Io,
        rel_path: []const u8,
        mtime_ns: i96,
        file_size: u64,
        inode: std.Io.File.INode,
        parent_dir: std.Io.Dir,
        open_sub_path: []const u8,
        max_map_bytes: u64,
    ) ?HotFileLease {
        if (rel_path.len == 0 or rel_path.len > 192 or file_size == 0 or file_size > max_map_bytes) return null;
        const map_len: usize = std.math.cast(usize, file_size) orelse return null;
        if (map_len == 0) return null;

        const path_hash = std.hash.Wyhash.hash(0, rel_path);

        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            for (&self.hot_mmap_files, 0..) |*hf, idx| {
                if (!hf.valid or hf.stale) continue;
                if (hf.rel_path_hash != path_hash) continue;
                if (!std.mem.eql(u8, hf.relPath(), rel_path)) continue;

                if (hf.mtime_ns == mtime_ns and hf.file_size == file_size and hf.inode == inode and hf.mm.memory.len == map_len) {
                    self.tick +%= 1;
                    hf.access_tick = self.tick;
                    hf.ref_count += 1;
                    return .{
                        .slot_idx = idx,
                        .slice = hf.mm.memory[0..map_len],
                    };
                } else {
                    // File was modified or atomically replaced on disk! Retire stale mapping immediately.
                    if (hf.ref_count == 0) {
                        hf.mm.destroy(io);
                        hf.file.close(io);
                        hf.valid = false;
                    } else {
                        hf.stale = true;
                    }
                }
            }
        }

        // Cache Miss: open file, verify fstat(fd) matches (mtime_ns, file_size, inode), and create read-only MemoryMap outside the lock
        var file = parent_dir.openFile(io, open_sub_path, .{ .allow_directory = false }) catch return null;
        const st = file.stat(io) catch {
            file.close(io);
            return null;
        };
        if (st.mtime.nanoseconds != mtime_ns or st.size != file_size or st.inode != inode) {
            file.close(io);
            return null;
        }
        var mm = std.Io.File.MemoryMap.create(io, file, .{
            .len = map_len,
            .protection = .{ .read = true, .write = false },
            .populate = false,
        }) catch {
            file.close(io);
            return null;
        };

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // Find an empty slot or evict the oldest unreferenced slot
        var target_idx: ?usize = null;
        var oldest_tick: u64 = std.math.maxInt(u64);
        for (&self.hot_mmap_files, 0..) |*hf, idx| {
            if (!hf.valid) {
                target_idx = idx;
                break;
            }
            if (hf.ref_count == 0 and hf.access_tick < oldest_tick) {
                oldest_tick = hf.access_tick;
                target_idx = idx;
            }
        }

        const slot_idx = target_idx orelse {
            mm.destroy(io);
            file.close(io);
            return null;
        };

        var slot = &self.hot_mmap_files[slot_idx];
        if (slot.valid) {
            slot.mm.destroy(io);
            slot.file.close(io);
            slot.valid = false;
        }

        self.tick +%= 1;
        slot.valid = true;
        slot.stale = false;
        slot.rel_path_hash = path_hash;
        @memcpy(slot.rel_path_buf[0..rel_path.len], rel_path);
        slot.rel_path_len = @intCast(rel_path.len);
        slot.mtime_ns = mtime_ns;
        slot.file_size = file_size;
        slot.inode = inode;
        slot.file = file;
        slot.mm = mm;
        slot.ref_count = 1;
        slot.access_tick = self.tick;

        return .{
            .slot_idx = slot_idx,
            .slice = slot.mm.memory[0..map_len],
        };
    }

    pub fn releaseHotFileSlice(self: *SearchCache, io: std.Io, slot_idx: usize) void {
        if (slot_idx >= MAX_HOT_MMAP_FILES) return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var slot = &self.hot_mmap_files[slot_idx];
        if (!slot.valid) return;
        if (slot.ref_count > 0) slot.ref_count -= 1;
        if (slot.ref_count == 0 and slot.stale) {
            slot.mm.destroy(io);
            slot.file.close(io);
            slot.valid = false;
            slot.stale = false;
        }
    }

    pub fn recordZeroHitFile(
        self: *SearchCache,
        io: std.Io,
        rel_path: []const u8,
        mtime_ns: i96,
        file_size: u64,
        inode: std.Io.File.INode,
        file_bytes: u64,
        pattern: []const u8,
        case_insensitive: bool,
    ) void {
        if (rel_path.len == 0 or rel_path.len > 192) return;
        if (pattern.len < 2 or pattern.len > 128) return;

        const path_hash = std.hash.Wyhash.hash(0, rel_path);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.tick +%= 1;
        const now_tick = self.tick;

        var victim_idx: usize = 0;
        var oldest_tick: u64 = std.math.maxInt(u64);

        for (&self.negative_files, 0..) |*nf, idx| {
            if (!nf.valid) {
                victim_idx = idx;
                break;
            }
            if (nf.rel_path_hash == path_hash and
                std.mem.eql(u8, nf.relPath(), rel_path) and
                nf.case_insensitive == case_insensitive)
            {
                if (nf.mtime_ns != mtime_ns or nf.file_size != file_size or nf.inode != inode) {
                    victim_idx = idx;
                    break;
                }
                const existing_pat = nf.pattern();
                if (case_insensitive) {
                    if (containsIgnoreCase(pattern, existing_pat)) {
                        nf.access_tick = now_tick;
                        return;
                    }
                } else {
                    if (std.mem.indexOf(u8, pattern, existing_pat) != null) {
                        nf.access_tick = now_tick;
                        return;
                    }
                }
                if ((case_insensitive and containsIgnoreCase(existing_pat, pattern)) or
                    (!case_insensitive and std.mem.indexOf(u8, existing_pat, pattern) != null))
                {
                    victim_idx = idx;
                    break;
                }
            }
            if (nf.access_tick < oldest_tick) {
                oldest_tick = nf.access_tick;
                victim_idx = idx;
            }
        }

        var target = &self.negative_files[victim_idx];
        target.valid = true;
        target.rel_path_hash = path_hash;
        @memcpy(target.rel_path_buf[0..rel_path.len], rel_path);
        target.rel_path_len = @intCast(rel_path.len);
        target.mtime_ns = mtime_ns;
        target.file_size = file_size;
        target.inode = inode;
        target.file_bytes = file_bytes;
        @memcpy(target.pattern_buf[0..pattern.len], pattern);
        target.pattern_len = @intCast(pattern.len);
        target.case_insensitive = case_insensitive;
        target.access_tick = now_tick;
    }

    pub fn checkFilePrunedByNegativeCache(
        self: *SearchCache,
        io: std.Io,
        rel_path: []const u8,
        mtime_ns: i96,
        file_size: u64,
        inode: std.Io.File.INode,
        required_literals: []const []const u8,
        query_case_insensitive: bool,
    ) ?u64 {
        if (rel_path.len == 0 or rel_path.len > 192 or required_literals.len == 0) return null;
        const path_hash = std.hash.Wyhash.hash(0, rel_path);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (&self.negative_files) |*nf| {
            if (!nf.valid) continue;
            if (nf.rel_path_hash != path_hash or nf.mtime_ns != mtime_ns or nf.file_size != file_size or nf.inode != inode) continue;
            if (!std.mem.eql(u8, nf.relPath(), rel_path)) continue;

            const neg_pat = nf.pattern();
            if (nf.case_insensitive) {
                for (required_literals) |req_lit| {
                    if (req_lit.len >= neg_pat.len and containsIgnoreCase(req_lit, neg_pat)) {
                        self.tick +%= 1;
                        nf.access_tick = self.tick;
                        return nf.file_bytes;
                    }
                }
            } else if (!query_case_insensitive) {
                for (required_literals) |req_lit| {
                    if (req_lit.len >= neg_pat.len and std.mem.indexOf(u8, req_lit, neg_pat) != null) {
                        self.tick +%= 1;
                        nf.access_tick = self.tick;
                        return nf.file_bytes;
                    }
                }
            }
        }
        return null;
    }

    pub fn evictIfNeededLocked(self: *SearchCache, needed_bytes: usize) void {
        while (self.entries.items.len >= MAX_CACHE_ENTRIES or
            (self.entries.items.len > 0 and self.total_bytes + needed_bytes > MAX_CACHE_BYTES))
        {
            var oldest_idx: usize = 0;
            var oldest_tick: u64 = self.entries.items[0].access_tick;
            for (self.entries.items, 0..) |e, idx| {
                if (e.access_tick < oldest_tick) {
                    oldest_tick = e.access_tick;
                    oldest_idx = idx;
                }
            }
            var evicted = self.entries.swapRemove(oldest_idx);
            if (self.total_bytes >= evicted.approx_bytes) {
                self.total_bytes -= evicted.approx_bytes;
            } else {
                self.total_bytes = 0;
            }
            evicted.deinit();
        }
    }
};

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
