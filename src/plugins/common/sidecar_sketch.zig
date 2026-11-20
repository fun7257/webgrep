const std = @import("std");
const prefilter = @import("../../prefilter.zig");

pub const Verdict = prefilter.Verdict;
pub const FileMeta = prefilter.FileMeta;
pub const QueryPredicates = prefilter.QueryPredicates;

pub const NUM_SHARDS: usize = 64;
pub const SLOTS_PER_SHARD: usize = 16;
pub const SKETCH_FILENAME = "sidecar_sketches_v1.bin";
const FILE_MAGIC: [8]u8 = .{ 'W', 'G', 'S', 'K', '0', '0', '0', '1' };
const FILE_VERSION: u32 = 1;

/// 256-bit (`[4]u64`) ASCII lowercase-folded trigram Bloom filter.
/// Every consecutive 3-byte window `(b0, b1, b2)` is ASCII-lowercased before hashing,
/// making it sound for both case-insensitive AND case-sensitive queries.
pub const TrigramBloom = struct {
    words: [4]u64 = .{ 0, 0, 0, 0 },

    inline fn hashTrigram(c0: u8, c1: u8, c2: u8) struct { b0: u8, b1: u8 } {
        const tri: u32 = @as(u32, c0) | (@as(u32, c1) << 8) | (@as(u32, c2) << 16);
        var x: u64 = @as(u64, tri) ^ 0x9e3779b97f4a7c15;
        x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
        x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
        x = x ^ (x >> 31);
        return .{
            .b0 = @truncate(x),
            .b1 = @truncate(x >> 8),
        };
    }

    inline fn setBit(self: *TrigramBloom, bit_idx: u8) void {
        const word_idx: usize = bit_idx >> 6;
        const bit: u6 = @truncate(bit_idx);
        self.words[word_idx] |= (@as(u64, 1) << bit);
    }

    inline fn hasBit(self: TrigramBloom, bit_idx: u8) bool {
        const word_idx: usize = bit_idx >> 6;
        const bit: u6 = @truncate(bit_idx);
        return (self.words[word_idx] & (@as(u64, 1) << bit)) != 0;
    }

    pub fn addSlice(self: *TrigramBloom, data: []const u8) void {
        if (data.len < 3) return;
        var c0 = std.ascii.toLower(data[0]);
        var c1 = std.ascii.toLower(data[1]);
        for (data[2..]) |raw_b| {
            const c2 = std.ascii.toLower(raw_b);
            const h = hashTrigram(c0, c1, c2);
            self.setBit(h.b0);
            self.setBit(h.b1);
            c0 = c1;
            c1 = c2;
        }
    }

    pub fn merge(self: *TrigramBloom, other: TrigramBloom) void {
        inline for (0..4) |i| {
            self.words[i] |= other.words[i];
        }
    }

    /// Returns `false` ONLY when at least one trigram of `anchor` is provably absent.
    /// Anchors `< 3` bytes cannot form a trigram and always return `true`.
    pub fn mightContain(self: TrigramBloom, anchor: []const u8, case_insensitive: bool) bool {
        _ = case_insensitive; // Bloom stores lowercase-folded trigrams, sound for both sensitive & insensitive
        if (anchor.len < 3) return true;
        var c0 = std.ascii.toLower(anchor[0]);
        var c1 = std.ascii.toLower(anchor[1]);
        for (anchor[2..]) |raw_b| {
            const c2 = std.ascii.toLower(raw_b);
            const h = hashTrigram(c0, c1, c2);
            if (!self.hasBit(h.b0) or !self.hasBit(h.b1)) return false;
            c0 = c1;
            c1 = c2;
        }
        return true;
    }

    pub fn isEmpty(self: TrigramBloom) bool {
        return (self.words[0] | self.words[1] | self.words[2] | self.words[3]) == 0;
    }
};

pub const SketchKey = struct {
    dev: u64,
    ino: u64,
    size_bytes: u64,
    mtime_ns: i96,

    pub fn fromFileMeta(meta: FileMeta) ?SketchKey {
        if (meta.inode == 0 or meta.mtime_ns <= 0) return null;
        return .{
            .dev = meta.dev,
            .ino = meta.inode,
            .size_bytes = meta.size_bytes,
            .mtime_ns = meta.mtime_ns,
        };
    }

    pub fn eql(a: SketchKey, b: SketchKey) bool {
        return a.dev == b.dev and
            a.ino == b.ino and
            a.size_bytes == b.size_bytes and
            a.mtime_ns == b.mtime_ns;
    }

    pub fn shardIndex(self: SketchKey) usize {
        var h: u64 = self.ino *% 0x9e3779b97f4a7c15;
        h ^= self.dev *% 0xbf58476d1ce4e5b9;
        h ^= self.size_bytes *% 0x94d049bb133111eb;
        const mt_lo: u64 = @truncate(@as(u128, @bitCast(@as(i128, self.mtime_ns))));
        h ^= mt_lo;
        h ^= h >> 33;
        return @intCast(h % NUM_SHARDS);
    }
};

pub const SketchEntry = struct {
    bloom: TrigramBloom = .{},
    has_bloom: bool = false,
    has_timestamps: bool = false,
    has_ts_bounds: bool = false,
    min_ts_ns: u64 = 0,
    max_ts_ns: u64 = 0,
};

const Slot = struct {
    valid: bool = false,
    key: SketchKey = .{ .dev = 0, .ino = 0, .size_bytes = 0, .mtime_ns = 0 },
    entry: SketchEntry = .{},
    access_tick: u32 = 0,
};

const Shard = struct {
    spin: std.atomic.Value(u8) = .init(0),
    tick: u32 = 0,
    slots: [SLOTS_PER_SHARD]Slot = @splat(.{}),

    fn lock(self: *Shard) void {
        while (self.spin.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Shard) void {
        self.spin.store(0, .release);
    }
};

/// Sharded, striped concurrent in-memory sketch store keyed by `(dev, ino, size_bytes, mtime_ns)`.
/// Never writes inside user source directories; optional binary persistence only accepts an explicit `cache_dir`.
pub const SketchStore = struct {
    shards: [NUM_SHARDS]Shard = @splat(.{}),

    pub fn deinit(self: *SketchStore, gpa: std.mem.Allocator) void {
        _ = gpa;
        self.clear();
    }

    pub fn clear(self: *SketchStore) void {
        for (&self.shards) |*sh| {
            sh.lock();
            defer sh.unlock();
            for (&sh.slots) |*sl| {
                sl.valid = false;
            }
            sh.tick = 0;
        }
    }

    pub fn get(self: *SketchStore, key: SketchKey) ?SketchEntry {
        const sh = &self.shards[key.shardIndex()];
        sh.lock();
        defer sh.unlock();

        for (&sh.slots) |*sl| {
            if (sl.valid and sl.key.eql(key)) {
                sh.tick +%= 1;
                sl.access_tick = sh.tick;
                return sl.entry;
            }
        }
        return null;
    }

    pub fn upsert(self: *SketchStore, key: SketchKey, incoming: SketchEntry) void {
        const sh = &self.shards[key.shardIndex()];
        sh.lock();
        defer sh.unlock();

        sh.tick +%= 1;
        var empty_idx: ?usize = null;
        var evict_idx: usize = 0;
        var oldest_tick: u32 = std.math.maxInt(u32);

        for (&sh.slots, 0..) |*sl, idx| {
            if (sl.valid and sl.key.eql(key)) {
                // Merge monotonically: preserve bloom/bounds if either old or new has them
                if (incoming.has_bloom) {
                    if (sl.entry.has_bloom) {
                        sl.entry.bloom.merge(incoming.bloom);
                    } else {
                        sl.entry.bloom = incoming.bloom;
                        sl.entry.has_bloom = true;
                    }
                }
                if (incoming.has_ts_bounds) {
                    if (!sl.entry.has_ts_bounds) {
                        sl.entry.has_ts_bounds = true;
                        sl.entry.has_timestamps = incoming.has_timestamps;
                        sl.entry.min_ts_ns = incoming.min_ts_ns;
                        sl.entry.max_ts_ns = incoming.max_ts_ns;
                    } else if (incoming.has_timestamps) {
                        if (!sl.entry.has_timestamps) {
                            sl.entry.has_timestamps = true;
                            sl.entry.min_ts_ns = incoming.min_ts_ns;
                            sl.entry.max_ts_ns = incoming.max_ts_ns;
                        } else {
                            sl.entry.min_ts_ns = @min(sl.entry.min_ts_ns, incoming.min_ts_ns);
                            sl.entry.max_ts_ns = @max(sl.entry.max_ts_ns, incoming.max_ts_ns);
                        }
                    }
                }
                sl.access_tick = sh.tick;
                return;
            }
            if (!sl.valid and empty_idx == null) {
                empty_idx = idx;
            }
            if (sl.valid and sl.access_tick <= oldest_tick) {
                oldest_tick = sl.access_tick;
                evict_idx = idx;
            }
        }

        const target = empty_idx orelse evict_idx;
        sh.slots[target] = .{
            .valid = true,
            .key = key,
            .entry = incoming,
            .access_tick = sh.tick,
        };
    }

    pub fn recordFullFile(
        self: *SketchStore,
        meta: FileMeta,
        content: []const u8,
        min_ts_ns: ?u64,
        max_ts_ns: ?u64,
        has_timestamps: bool,
    ) void {
        const key = SketchKey.fromFileMeta(meta) orelse return;
        var bloom = TrigramBloom{};
        bloom.addSlice(content);
        self.upsert(key, .{
            .bloom = bloom,
            .has_bloom = true,
            .has_timestamps = has_timestamps and min_ts_ns != null and max_ts_ns != null,
            .has_ts_bounds = true,
            .min_ts_ns = min_ts_ns orelse 0,
            .max_ts_ns = max_ts_ns orelse 0,
        });
    }

    pub fn countEntries(self: *SketchStore) usize {
        var total: usize = 0;
        for (&self.shards) |*sh| {
            sh.lock();
            defer sh.unlock();
            for (sh.slots) |sl| {
                if (sl.valid) total += 1;
            }
        }
        return total;
    }

    const DiskRecord = extern struct {
        dev: u64,
        ino: u64,
        size_bytes: u64,
        mtime_ns_lo: u64,
        mtime_ns_hi: i32,
        flags: u8,
        reserved: [3]u8 = .{ 0, 0, 0 },
        min_ts_ns: u64,
        max_ts_ns: u64,
        bloom: [4]u64,
    };

    const DiskHeader = extern struct {
        magic: [8]u8,
        version: u32,
        count: u32,
        records_wyhash: u64,
    };

    /// Saves all valid sketch entries into `<cache_dir>/sidecar_sketches_v1.bin`.
    /// Callers MUST pass an app-owned cache directory (e.g. `<data_dir>/sketches`), NEVER a user source dir.
    pub fn saveToCacheDir(self: *SketchStore, gpa: std.mem.Allocator, io: std.Io, cache_dir_path: []const u8) !void {
        if (cache_dir_path.len == 0) return;

        var records: std.ArrayList(DiskRecord) = .empty;
        defer records.deinit(gpa);

        for (&self.shards) |*sh| {
            sh.lock();
            defer sh.unlock();
            for (sh.slots) |sl| {
                if (!sl.valid) continue;
                const mt_bits: u128 = @bitCast(@as(i128, sl.key.mtime_ns));
                const lo: u64 = @truncate(mt_bits);
                const hi: i32 = @truncate(@as(i128, sl.key.mtime_ns) >> 64);
                var flags: u8 = 0;
                if (sl.entry.has_bloom) flags |= 1;
                if (sl.entry.has_timestamps) flags |= 2;
                if (sl.entry.has_ts_bounds) flags |= 4;
                try records.append(gpa, .{
                    .dev = sl.key.dev,
                    .ino = sl.key.ino,
                    .size_bytes = sl.key.size_bytes,
                    .mtime_ns_lo = lo,
                    .mtime_ns_hi = hi,
                    .flags = flags,
                    .min_ts_ns = sl.entry.min_ts_ns,
                    .max_ts_ns = sl.entry.max_ts_ns,
                    .bloom = sl.entry.bloom.words,
                });
            }
        }

        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, cache_dir_path);
        var dir = try cwd.openDir(io, cache_dir_path, .{});
        defer dir.close(io);

        const rec_bytes = std.mem.sliceAsBytes(records.items);
        const hdr = DiskHeader{
            .magic = FILE_MAGIC,
            .version = FILE_VERSION,
            .count = @intCast(records.items.len),
            .records_wyhash = std.hash.Wyhash.hash(0x5747534b, rec_bytes),
        };

        const tmp_name = SKETCH_FILENAME ++ ".tmp";
        {
            var file = try dir.createFile(io, tmp_name, .{ .truncate = true });
            defer file.close(io);
            var wbuf: [16384]u8 = undefined;
            var fw = file.writer(io, &wbuf);
            try fw.interface.writeAll(std.mem.asBytes(&hdr));
            if (rec_bytes.len > 0) {
                try fw.interface.writeAll(rec_bytes);
            }
            try fw.interface.flush();
        }
        try dir.rename(tmp_name, dir, SKETCH_FILENAME, io);
    }

    /// Loads sketch entries from `<cache_dir>/sidecar_sketches_v1.bin`.
    /// Silently ignores missing/corrupt/version-mismatched files (cold start safe).
    pub fn loadFromCacheDir(self: *SketchStore, gpa: std.mem.Allocator, io: std.Io, cache_dir_path: []const u8) void {
        if (cache_dir_path.len == 0) return;

        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(io, cache_dir_path, .{}) catch return;
        defer dir.close(io);

        var file = dir.openFile(io, SKETCH_FILENAME, .{ .allow_directory = false }) catch return;
        defer file.close(io);

        var rbuf: [8192]u8 = undefined;
        var fr = file.reader(io, &rbuf);
        const max_bytes = @sizeOf(DiskHeader) + (NUM_SHARDS * SLOTS_PER_SHARD * @sizeOf(DiskRecord));
        const raw = fr.interface.allocRemaining(gpa, .limited(max_bytes + 1024)) catch return;
        defer gpa.free(raw);

        if (raw.len < @sizeOf(DiskHeader)) return;
        const hdr: *const DiskHeader = @ptrCast(@alignCast(raw[0..@sizeOf(DiskHeader)].ptr));
        if (!std.mem.eql(u8, &hdr.magic, &FILE_MAGIC)) return;
        if (hdr.version != FILE_VERSION) return;

        const expected_rec_bytes = @as(usize, hdr.count) * @sizeOf(DiskRecord);
        if (raw.len < @sizeOf(DiskHeader) + expected_rec_bytes) return;
        const rec_bytes = raw[@sizeOf(DiskHeader) .. @sizeOf(DiskHeader) + expected_rec_bytes];
        const actual_hash = std.hash.Wyhash.hash(0x5747534b, rec_bytes);
        if (actual_hash != hdr.records_wyhash) return;

        const recs: []const DiskRecord = @alignCast(std.mem.bytesAsSlice(DiskRecord, rec_bytes));
        for (recs) |r| {
            const mt_i128: i128 = (@as(i128, r.mtime_ns_hi) << 64) | @as(i128, r.mtime_ns_lo);
            const mt: i96 = @truncate(mt_i128);
            const key = SketchKey{
                .dev = r.dev,
                .ino = r.ino,
                .size_bytes = r.size_bytes,
                .mtime_ns = mt,
            };
            self.upsert(key, .{
                .bloom = .{ .words = r.bloom },
                .has_bloom = (r.flags & 1) != 0,
                .has_timestamps = (r.flags & 2) != 0,
                .has_ts_bounds = (r.flags & 4) != 0,
                .min_ts_ns = r.min_ts_ns,
                .max_ts_ns = r.max_ts_ns,
            });
        }
    }
};

/// Priority 35 (`sidecar_sketch`): prunes files whose cached full-file sketch provably proves
/// either (a) observed `[min_ts_ns, max_ts_ns]` is disjoint from `[time_start_ns, time_end_ns]`,
/// or (b) any required `literal_anchor` (`>= 3` bytes) is absent from the 256-bit trigram Bloom filter.
pub fn eval(store: *SketchStore, meta: FileMeta, preds: QueryPredicates) Verdict {
    const key = SketchKey.fromFileMeta(meta) orelse return .keep;
    const entry = store.get(key) orelse return .keep;

    // 1. Observed timestamp interval pruning (only when file actually has timestamps)
    if (preds.hasTimeRange() and entry.has_ts_bounds and entry.has_timestamps) {
        if (preds.time_start_ns > 0 and entry.max_ts_ns < preds.time_start_ns) {
            return .skip;
        }
        if (preds.time_end_ns > 0 and entry.min_ts_ns > preds.time_end_ns) {
            return .skip;
        }
    }

    // 2. Literal anchor trigram Bloom pruning (>= 3 bytes)
    if (entry.has_bloom and preds.literal_anchors.len > 0) {
        for (preds.literal_anchors, 0..) |anchor, idx| {
            if (anchor.len < 3) continue;
            const ci = if (idx < preds.anchor_case_flags.len)
                preds.anchor_case_flags[idx]
            else
                preds.anchors_case_insensitive;
            if (!entry.bloom.mightContain(anchor, ci)) {
                return .skip;
            }
        }
    }

    return .keep;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "sidecar_sketch: 256-bit trigram Bloom, timestamp bounds, mtime invalidation, and cache_dir persistence" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &path_buf);
    const cache_dir = try std.fmt.allocPrint(gpa, "{s}/sketches", .{path_buf[0..tmp_len]});
    defer gpa.free(cache_dir);

    var store = SketchStore{};
    defer store.deinit(gpa);

    const log_body = "2026-11-18T09:15:00Z ERROR InfluxDB_Timeout upstream=db-1\n" ++
        "2026-11-18T09:45:00Z INFO Recovery complete\n";
    const t_09_15: u64 = 1_795_000_000_000_000_000;
    const t_09_45: u64 = t_09_15 + 1_800 * std.time.ns_per_s;

    const meta = FileMeta{
        .rel_path = "logs/db.log",
        .size_bytes = log_body.len,
        .mtime_ns = @intCast(t_09_45),
        .inode = 9001,
        .dev = 7,
    };

    store.recordFullFile(meta, log_body, t_09_15, t_09_45, true);

    // 1. Matching anchor (case-insensitive & case-sensitive) and overlapping window -> KEEP
    try std.testing.expectEqual(Verdict.keep, eval(&store, meta, .{
        .time_start_ns = t_09_15,
        .time_end_ns = t_09_45,
        .literal_anchors = &.{"influxdb_timeout"},
        .anchors_case_insensitive = true,
    }));
    try std.testing.expectEqual(Verdict.keep, eval(&store, meta, .{
        .literal_anchors = &.{"InfluxDB_Timeout"},
        .anchors_case_insensitive = false,
    }));

    // 2. Missing anchor >= 3 bytes -> SKIP
    try std.testing.expectEqual(Verdict.skip, eval(&store, meta, .{
        .literal_anchors = &.{"PostgreSQL_Fatal"},
    }));

    // 3. Short anchor < 3 bytes -> KEEP (Monotone Superset Law)
    try std.testing.expectEqual(Verdict.keep, eval(&store, meta, .{
        .literal_anchors = &.{"zz"},
    }));

    // 4. Disjoint observed timestamps -> SKIP
    try std.testing.expectEqual(Verdict.skip, eval(&store, meta, .{
        .time_start_ns = t_09_45 + 60 * std.time.ns_per_s,
        .time_end_ns = t_09_45 + 3600 * std.time.ns_per_s,
    }));

    // 5. File modification (`size_bytes` or `mtime_ns` changes) -> cache miss -> KEEP
    var modified_meta = meta;
    modified_meta.size_bytes += 12;
    try std.testing.expectEqual(Verdict.keep, eval(&store, modified_meta, .{
        .literal_anchors = &.{"PostgreSQL_Fatal"},
    }));

    // 6. Save & reload strictly inside `cache_dir`
    try store.saveToCacheDir(gpa, io, cache_dir);
    var store2 = SketchStore{};
    defer store2.deinit(gpa);
    store2.loadFromCacheDir(gpa, io, cache_dir);
    try std.testing.expectEqual(@as(usize, 1), store2.countEntries());
    try std.testing.expectEqual(Verdict.skip, eval(&store2, meta, .{
        .literal_anchors = &.{"PostgreSQL_Fatal"},
    }));
}

test "sidecar_sketch: concurrent multi-thread striped access is race-free" {
    const gpa = std.testing.allocator;
    var store = SketchStore{};
    defer store.deinit(gpa);

    const Worker = struct {
        fn run(st: *SketchStore, tid: usize) void {
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                const ino: u64 = @intCast(tid * 100 + i + 1);
                const m = FileMeta{
                    .rel_path = "concurrent.log",
                    .size_bytes = 128,
                    .mtime_ns = 1_795_000_000_000_000_000,
                    .inode = ino,
                    .dev = 1,
                };
                st.recordFullFile(m, "2026-11-18T09:30:00Z ERROR worker_alpha_token\n", 1_795_000_000_000_000_000, 1_795_000_000_000_000_000, true);
                _ = eval(st, m, .{ .literal_anchors = &.{"worker_alpha_token"} });
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &store, idx });
    }
    for (threads) |t| t.join();
    try std.testing.expect(store.countEntries() > 0);
}
