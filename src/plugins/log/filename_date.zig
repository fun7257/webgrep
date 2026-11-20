const std = @import("std");
const prefilter = @import("../../prefilter.zig");

pub const Verdict = prefilter.Verdict;
pub const FileMeta = prefilter.FileMeta;
pub const QueryPredicates = prefilter.QueryPredicates;
pub const Preset = prefilter.Preset;

pub const DateSpan = struct {
    /// Inclusive start in UTC nanoseconds (assuming `tz_offset_min = 0` for UTC bounds).
    utc_start_ns: u64,
    utc_end_ns: u64,
    /// Inclusive start/end assuming the filename date/hour was recorded in `preds.tz_offset_min`.
    local_start_ns: u64,
    local_end_ns: u64,
    is_hourly: bool,
};

inline fn isLeapYear(y: u16) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 31,
    };
}

fn civilToEpochSeconds(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?i64 {
    if (year < 1995 or year > 2099) return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var y: i64 = @intCast(year);
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    if (m <= 2) y -= 1;
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const adj_m: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divTrunc(153 * adj_m + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days_since_epoch: i64 = era * 146097 + doe - 719468;

    return days_since_epoch * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

inline fn parse2Digits(s: []const u8) ?u8 {
    if (s.len < 2 or !std.ascii.isDigit(s[0]) or !std.ascii.isDigit(s[1])) return null;
    return (s[0] - '0') * 10 + (s[1] - '0');
}

inline fn parse4Digits(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    var acc: u16 = 0;
    for (s[0..4]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        acc = acc * 10 + @as(u16, c - '0');
    }
    return acc;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

fn isCodeOrStaticExtension(base_name: []const u8) bool {
    const code_exts = [_][]const u8{
        ".zig",   ".zon",  ".rs",   ".ts",   ".tsx",  ".mts",  ".cts",  ".js",
        ".jsx",   ".mjs",  ".cjs",  ".svelte", ".vue", ".py",  ".go",   ".c",
        ".cc",    ".cpp",  ".cxx",  ".h",    ".hpp",  ".java", ".kt",   ".scala",
        ".cs",    ".swift", ".rb",  ".php",  ".lua",  ".sql",  ".md",   ".markdown",
        ".rst",   ".html", ".htm",  ".css",  ".scss", ".less", ".yaml", ".yml",
        ".toml",  ".xml",  ".sh",   ".zsh",  ".bash", ".ps1",  ".proto",
    };
    for (code_exts) |ext| {
        if (endsWithIgnoreCase(base_name, ext)) return true;
    }
    return false;
}

fn isRotatedOrLogFilename(base_name: []const u8, preset: Preset) bool {
    if (preset == .timeseries) {
        return !isCodeOrStaticExtension(base_name);
    }
    const log_or_archive_exts = [_][]const u8{
        ".log",   ".out",    ".err",    ".trace", ".audit", ".access",
        ".jsonl", ".ndjson", ".json",   ".csv",   ".tsv",   ".txt",
        ".gz",    ".zst",    ".xz",     ".bz2",   ".tar",   ".zip",
        ".tgz",   ".tzst",   ".txz",
    };
    for (log_or_archive_exts) |ext| {
        if (endsWithIgnoreCase(base_name, ext)) return true;
    }
    // `dateext` rotated log patterns like `app.log.2026-11-10`, `nginx.log-20261110`, `out.err-20261110`
    if (!isCodeOrStaticExtension(base_name)) {
        const log_markers = [_][]const u8{ ".log.", ".log-", ".log_", ".out.", ".out-", ".err.", ".err-" };
        for (log_markers) |mk| {
            if (std.mem.indexOf(u8, base_name, mk) != null) return true;
        }
    }
    // Numeric rotation suffix like `app-2026-11-10.log.1` or `service.2026-11-10.2`
    if (std.mem.lastIndexOfScalar(u8, base_name, '.')) |dot| {
        if (dot + 1 < base_name.len) {
            const tail = base_name[dot + 1 ..];
            if (tail.len <= 4) {
                var all_digits = true;
                for (tail) |c| {
                    if (!std.ascii.isDigit(c)) {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) return true;
            }
        }
    }
    return false;
}

fn buildDateSpan(
    year: u16,
    month: u8,
    day: u8,
    hour_opt: ?u8,
    tz_offset_min: i16,
) ?DateSpan {
    const start_hour: u8 = hour_opt orelse 0;
    const end_hour: u8 = hour_opt orelse 23;
    const utc_s = civilToEpochSeconds(year, month, day, start_hour, 0, 0) orelse return null;
    const utc_e = civilToEpochSeconds(year, month, day, end_hour, 59, 59) orelse return null;

    const clamped_min: i64 = std.math.clamp(tz_offset_min, -840, 840);
    const tz_sec: i64 = clamped_min * 60;
    const local_s = utc_s - tz_sec;
    const local_e = utc_e - tz_sec;
    if (utc_s <= 0 or local_s <= 0) return null;

    return .{
        .utc_start_ns = @as(u64, @intCast(utc_s)) * std.time.ns_per_s,
        .utc_end_ns = @as(u64, @intCast(utc_e)) * std.time.ns_per_s + 999_999_999,
        .local_start_ns = @as(u64, @intCast(local_s)) * std.time.ns_per_s,
        .local_end_ns = @as(u64, @intCast(local_e)) * std.time.ns_per_s + 999_999_999,
        .is_hourly = hour_opt != null,
    };
}

/// Extracts all date/hour stamps in `base_name` and returns their bounding span (or `null` if none).
/// Zero-allocation scanner supporting `YYYY-MM-DD`, `YYYY_MM_DD`, `YYYY.MM.DD`, `YYYYMMDD`,
/// `YYYY-MM-DD-HH`, `YYYY_MM_DD_HH`, `YYYYMMDD-HH`, `YYYYMMDDHH`, `.N` suffixes, and `.gz`/`.zst`/`.tar.gz`.
pub fn extractFilenameDateSpan(base_name: []const u8, tz_offset_min: i16) ?DateSpan {
    if (base_name.len < 8) return null;

    var combined: ?DateSpan = null;
    var i: usize = 0;
    while (i + 8 <= base_name.len) {
        if (i > 0 and std.ascii.isDigit(base_name[i - 1])) {
            i += 1;
            continue;
        }
        const c = base_name[i];
        if (c != '1' and c != '2') {
            i += 1;
            continue;
        }
        const year = parse4Digits(base_name[i..]) orelse {
            i += 1;
            continue;
        };
        if (year < 1995 or year > 2099) {
            i += 1;
            continue;
        }

        var matched_len: usize = 0;
        var span_opt: ?DateSpan = null;

        const sep = base_name[i + 4];
        if ((sep == '-' or sep == '_' or sep == '.') and i + 10 <= base_name.len and base_name[i + 7] == sep) {
            // `YYYY-MM-DD` / `YYYY_MM_DD` / `YYYY.MM.DD` + optional `[-_T]HH`
            if (parse2Digits(base_name[i + 5 .. i + 7])) |month| {
                if (parse2Digits(base_name[i + 8 .. i + 10])) |day| {
                    const after_day = i + 10;
                    if (after_day == base_name.len or !std.ascii.isDigit(base_name[after_day])) {
                        var hour_opt: ?u8 = null;
                        matched_len = 10;
                        // Optional hour `[-_T ]HH` (requires 2 digits so `.1` / `-1` rotation suffix isn't mistaken!)
                        if (after_day + 3 <= base_name.len and
                            (base_name[after_day] == '-' or base_name[after_day] == '_' or base_name[after_day] == 'T' or base_name[after_day] == ' '))
                        {
                            if (parse2Digits(base_name[after_day + 1 .. after_day + 3])) |hh| {
                                const after_hh = after_day + 3;
                                if (hh <= 23 and (after_hh == base_name.len or !std.ascii.isDigit(base_name[after_hh]))) {
                                    hour_opt = hh;
                                    matched_len = 13;
                                }
                            }
                        }
                        span_opt = buildDateSpan(year, month, day, hour_opt, tz_offset_min);
                    }
                }
            }
        } else if (std.ascii.isDigit(sep)) {
            // Compact `YYYYMMDD` or `YYYYMMDDHH` or `YYYYMMDD[-_T]HH`
            if (parse2Digits(base_name[i + 4 .. i + 6])) |month| {
                if (parse2Digits(base_name[i + 6 .. i + 8])) |day| {
                    const after_day = i + 8;
                    if (after_day + 2 <= base_name.len and std.ascii.isDigit(base_name[after_day]) and std.ascii.isDigit(base_name[after_day + 1])) {
                        // Could be 10-digit `YYYYMMDDHH` if bounded after 10 digits
                        const after_10 = after_day + 2;
                        if (after_10 == base_name.len or !std.ascii.isDigit(base_name[after_10])) {
                            if (parse2Digits(base_name[after_day..after_10])) |hh| {
                                if (hh <= 23) {
                                    matched_len = 10;
                                    span_opt = buildDateSpan(year, month, day, hh, tz_offset_min);
                                }
                            }
                        }
                    } else if (after_day == base_name.len or !std.ascii.isDigit(base_name[after_day])) {
                        var hour_opt: ?u8 = null;
                        matched_len = 8;
                        if (after_day + 3 <= base_name.len and
                            (base_name[after_day] == '-' or base_name[after_day] == '_' or base_name[after_day] == 'T'))
                        {
                            if (parse2Digits(base_name[after_day + 1 .. after_day + 3])) |hh| {
                                const after_hh = after_day + 3;
                                if (hh <= 23 and (after_hh == base_name.len or !std.ascii.isDigit(base_name[after_hh]))) {
                                    hour_opt = hh;
                                    matched_len = 11;
                                }
                            }
                        }
                        span_opt = buildDateSpan(year, month, day, hour_opt, tz_offset_min);
                    }
                }
            }
        }

        if (span_opt) |sp| {
            if (combined) |*prev| {
                prev.utc_start_ns = @min(prev.utc_start_ns, sp.utc_start_ns);
                prev.utc_end_ns = @max(prev.utc_end_ns, sp.utc_end_ns);
                prev.local_start_ns = @min(prev.local_start_ns, sp.local_start_ns);
                prev.local_end_ns = @max(prev.local_end_ns, sp.local_end_ns);
                prev.is_hourly = prev.is_hourly and sp.is_hourly;
            } else {
                combined = sp;
            }
            i += matched_len;
        } else {
            i += 1;
        }
    }

    return combined;
}

fn intervalOverlapsQuery(span_start: u64, span_end: u64, query_start: u64, query_end: u64) bool {
    if (query_start > 0 and span_end < query_start) return false;
    if (query_end > 0 and span_start > query_end) return false;
    return true;
}

/// Priority 30 (`filename_date`): prunes rotated/compressed log files whose filename date/hour
/// is provably disjoint from `[time_start_ns, time_end_ns]` before opening or decompressing.
pub fn eval(meta: FileMeta, preds: QueryPredicates) Verdict {
    if (!preds.hasTimeRange()) return .keep;

    const base_name = meta.effectiveBaseName();
    if (!isRotatedOrLogFilename(base_name, preds.preset)) return .keep;

    const span = extractFilenameDateSpan(base_name, preds.tz_offset_min) orelse return .keep;

    // Monotone Superset Law: keep if query overlaps EITHER UTC or caller-local interpretation.
    const overlaps_utc = intervalOverlapsQuery(span.utc_start_ns, span.utc_end_ns, preds.time_start_ns, preds.time_end_ns);
    const overlaps_local = intervalOverlapsQuery(span.local_start_ns, span.local_end_ns, preds.time_start_ns, preds.time_end_ns);
    if (!overlaps_utc and !overlaps_local) {
        return .skip;
    }
    return .keep;
}

// ============================================================================
// Unit Tests
// ============================================================================

fn utcNs(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) u64 {
    const sec = civilToEpochSeconds(year, month, day, hour, minute, second).?;
    return @as(u64, @intCast(sec)) * std.time.ns_per_s;
}

test "filename_date: rotated log formats, hourly pruning, compressed extensions, and code file safety" {
    const q_start = utcNs(2026, 11, 14, 9, 0, 0);
    const q_end = utcNs(2026, 11, 14, 10, 0, 0);
    const preds = QueryPredicates{
        .time_start_ns = q_start,
        .time_end_ns = q_end,
        .preset = .auto,
    };

    // Disjoint rotated logs pruned BEFORE decompression
    try std.testing.expectEqual(Verdict.skip, eval(.{ .rel_path = "logs/app-2026-11-10.log.gz", .is_compressed = true }, preds));
    try std.testing.expectEqual(Verdict.skip, eval(.{ .rel_path = "logs/app_2026_11_13.log.zst", .is_compressed = true }, preds));
    try std.testing.expectEqual(Verdict.skip, eval(.{ .rel_path = "logs/access_20261115.tar.gz", .is_archive_container = true }, preds));
    try std.testing.expectEqual(Verdict.skip, eval(.{ .rel_path = "logs/service.2026-11-10.log.1" }, preds));
    try std.testing.expectEqual(Verdict.skip, eval(.{ .rel_path = "logs/app.log.2026-11-10" }, preds));
    try std.testing.expectEqual(Verdict.skip, eval(.{ .rel_path = "logs/nginx.log-20261110" }, preds));
    try std.testing.expectEqual(Verdict.skip, eval(.{ .rel_path = "logs/app-2026-11-14-08.log.gz", .is_compressed = true }, preds));
    try std.testing.expectEqual(Verdict.skip, eval(.{ .rel_path = "logs/app_2026111411.log.xz", .is_compressed = true }, preds));

    // Overlapping rotated logs kept (including `.1` rotation suffix NOT misread as hour `01`!)
    try std.testing.expectEqual(Verdict.keep, eval(.{ .rel_path = "logs/app-2026-11-14.log.gz", .is_compressed = true }, preds));
    try std.testing.expectEqual(Verdict.keep, eval(.{ .rel_path = "logs/app-20261114-1.log.gz", .is_compressed = true }, preds));
    try std.testing.expectEqual(Verdict.keep, eval(.{ .rel_path = "logs/app-2026-11-14-09.log.gz", .is_compressed = true }, preds));

    // Multi-date span filename covers entire range -> kept
    try std.testing.expectEqual(Verdict.keep, eval(.{ .rel_path = "logs/dump-2026-11-10-to-2026-11-18.log.gz" }, preds));

    // Undated log -> kept
    try std.testing.expectEqual(Verdict.keep, eval(.{ .rel_path = "logs/app.log" }, preds));

    // Source code / SQL migration files with dates in filename are NOT pruned in .auto
    try std.testing.expectEqual(Verdict.keep, eval(.{ .rel_path = "migrations/2026-11-10_init.sql" }, preds));
    try std.testing.expectEqual(Verdict.keep, eval(.{ .rel_path = "docs/release-2026-11-10.md" }, preds));
    try std.testing.expectEqual(Verdict.keep, eval(.{ .rel_path = "src/snapshot_20261110.zig" }, preds));

    // Partial ranges (`time_start_ns` only or `time_end_ns` only)
    const p_after = QueryPredicates{ .time_start_ns = q_start, .time_end_ns = 0 };
    try std.testing.expectEqual(Verdict.skip, eval(.{ .rel_path = "app-2026-11-10.log.gz" }, p_after));
    try std.testing.expectEqual(Verdict.keep, eval(.{ .rel_path = "app-2026-11-15.log.gz" }, p_after));

    const p_before = QueryPredicates{ .time_start_ns = 0, .time_end_ns = q_end };
    try std.testing.expectEqual(Verdict.skip, eval(.{ .rel_path = "app-2026-11-15.log.gz" }, p_before));
    try std.testing.expectEqual(Verdict.keep, eval(.{ .rel_path = "app-2026-11-10.log.gz" }, p_before));
}
