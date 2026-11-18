const std = @import("std");
const prefilter = @import("../prefilter.zig");

pub const Verdict = prefilter.Verdict;
pub const FileMeta = prefilter.FileMeta;
pub const QueryPredicates = prefilter.QueryPredicates;

pub fn planSource(preds: QueryPredicates) Verdict {
    _ = preds;
    return .keep;
}

pub fn eval(meta: FileMeta, preds: QueryPredicates) Verdict {
    if (preds.include_globs.len == 0 and
        preds.exclude_globs.len == 0 and
        preds.file_types.len == 0 and
        preds.exclude_file_types.len == 0)
    {
        return .keep;
    }

    const rel_path = meta.rel_path;
    const base_name = meta.effectiveBaseName();

    // 1. Explicit exclude globs always win (applies to both regular files and archive containers).
    for (preds.exclude_globs) |raw| {
        const g = stripOptionalNegation(std.mem.trim(u8, raw, " \t"));
        if (g.len == 0) continue;
        if (matchesPathPattern(rel_path, base_name, g)) return .skip;
    }

    // Also evaluate any `!`-prefixed negative patterns inside `include_globs`.
    for (preds.include_globs) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len > 1 and trimmed[0] == '!') {
            if (matchesPathPattern(rel_path, base_name, trimmed[1..])) return .skip;
        }
    }

    // For archive containers (e.g. bundle.tar.gz), positive path/type filters may target
    // inner entries rather than the archive filename itself — keep the container!
    if (meta.is_archive_container) {
        return .keep;
    }

    // 2. Positive include_globs (OR semantics across all positive patterns).
    var has_positive_glob = false;
    var positive_glob_hit = false;
    for (preds.include_globs) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0 or trimmed[0] == '!') continue;
        has_positive_glob = true;
        if (matchesPathPattern(rel_path, base_name, trimmed)) {
            positive_glob_hit = true;
            break;
        }
    }
    if (has_positive_glob and !positive_glob_hit) return .skip;

    // 3. Excluded file types (explicit `exclude_file_types` or `!type` in `file_types`).
    for (preds.exclude_file_types) |raw_t| {
        const t = cleanTypeToken(raw_t, true);
        if (t.len == 0) continue;
        if (matchesFileType(base_name, t)) return .skip;
    }
    for (preds.file_types) |raw_t| {
        const trimmed = std.mem.trim(u8, raw_t, " \t");
        if (trimmed.len > 1 and trimmed[0] == '!') {
            const t = cleanTypeToken(trimmed[1..], false);
            if (t.len > 0 and matchesFileType(base_name, t)) return .skip;
        }
    }

    // 4. Positive file types (OR semantics).
    var has_positive_type = false;
    var positive_type_hit = false;
    for (preds.file_types) |raw_t| {
        const trimmed = std.mem.trim(u8, raw_t, " \t");
        if (trimmed.len == 0 or trimmed[0] == '!') continue;
        const t = cleanTypeToken(trimmed, false);
        if (t.len == 0) continue;
        has_positive_type = true;
        if (matchesFileType(base_name, t)) {
            positive_type_hit = true;
            break;
        }
    }
    if (has_positive_type and !positive_type_hit) return .skip;

    return .keep;
}

fn stripOptionalNegation(s: []const u8) []const u8 {
    if (s.len > 0 and s[0] == '!') return s[1..];
    return s;
}

fn cleanTypeToken(raw: []const u8, allow_bang: bool) []const u8 {
    var s = std.mem.trim(u8, raw, " \t");
    if (allow_bang and s.len > 0 and s[0] == '!') s = s[1..];
    while (s.len > 0 and s[0] == '.') s = s[1..];
    return s;
}

fn hasGlobMeta(s: []const u8) bool {
    for (s) |c| {
        if (c == '*' or c == '?' or c == '[' or c == '{') return true;
    }
    return false;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

/// Zero-alloc path/glob matcher compatible with `search_job.zig`'s `@*.rs`, `@src/`, `-@*_test.go` patterns.
pub fn matchesPathPattern(rel_path: []const u8, base_name: []const u8, raw_pat: []const u8) bool {
    var pat = std.mem.trim(u8, raw_pat, " \t");
    if (pat.len == 0) return false;

    const anchored_root = pat[0] == '/';
    if (anchored_root) pat = pat[1..];
    if (pat.len == 0) return false;

    // Directory prefix pattern like `src/` or `logs/api/`
    if (pat[pat.len - 1] == '/' and !hasGlobMeta(pat)) {
        const dir_prefix = pat[0 .. pat.len - 1];
        if (dir_prefix.len == 0) return true;
        if (startsWithIgnoreCase(rel_path, pat)) return true;
        if (!anchored_root and std.mem.indexOfScalar(u8, dir_prefix, '/') == null) {
            // Segment match inside path (e.g. `node_modules/` matches `web/node_modules/a.js`)
            var seg_it = std.mem.splitScalar(u8, rel_path, '/');
            while (seg_it.next()) |seg| {
                // Only directory segments (there must be another segment after it)
                if (seg_it.peek() == null) break;
                if (std.ascii.eqlIgnoreCase(seg, dir_prefix)) return true;
            }
        }
        return false;
    }

    // Fast O(1) extension / suffix path when pattern is `*.ext` or `*.tar.gz`
    if (pat.len >= 2 and pat[0] == '*' and !hasGlobMeta(pat[1..]) and std.mem.indexOfScalar(u8, pat[1..], '/') == null) {
        return endsWithIgnoreCase(base_name, pat[1..]);
    }

    const has_slash = std.mem.indexOfScalar(u8, pat, '/') != null;
    if (!hasGlobMeta(pat)) {
        if (has_slash) {
            if (anchored_root) {
                return std.ascii.eqlIgnoreCase(rel_path, pat) or
                    (startsWithIgnoreCase(rel_path, pat) and rel_path.len > pat.len and rel_path[pat.len] == '/');
            }
            return std.ascii.eqlIgnoreCase(rel_path, pat) or
                (endsWithIgnoreCase(rel_path, pat) and rel_path.len > pat.len and rel_path[rel_path.len - pat.len - 1] == '/');
        }
        return std.ascii.eqlIgnoreCase(base_name, pat);
    }

    if (has_slash) {
        if (globMatch(pat, rel_path, false)) return true;
        if (!anchored_root and std.mem.startsWith(u8, pat, "**/")) {
            return globMatch(pat[3..], rel_path, false);
        }
        return false;
    }

    return globMatch(pat, base_name, true);
}

/// Non-recursive iterative wildcard matcher (`*`, `?`, `**`, `[abc]`, `[a-z]`), 100% zero-allocation.
pub fn globMatch(pat: []const u8, text: []const u8, single_segment: bool) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;
    var star_is_double: bool = false;

    while (ti < text.len) {
        if (pi < pat.len and pat[pi] == '*') {
            const is_double = !single_segment and pi + 1 < pat.len and pat[pi + 1] == '*';
            while (pi < pat.len and pat[pi] == '*') : (pi += 1) {}
            if (is_double and pi < pat.len and pat[pi] == '/' and ti == 0) {
                // `**/` can match zero leading path segments
                if (globMatch(pat[pi + 1 ..], text, single_segment)) return true;
            }
            star_pi = pi;
            star_ti = ti;
            star_is_double = is_double or !single_segment;
            if (single_segment) star_is_double = false;
            continue;
        }

        if (pi < pat.len) {
            if (pat[pi] == '?') {
                if (!single_segment or text[ti] != '/') {
                    pi += 1;
                    ti += 1;
                    continue;
                }
            } else if (pat[pi] == '[') {
                if (matchCharClass(pat[pi..], text[ti])) |class_len| {
                    pi += class_len;
                    ti += 1;
                    continue;
                }
            } else if (std.ascii.toLower(pat[pi]) == std.ascii.toLower(text[ti])) {
                pi += 1;
                ti += 1;
                continue;
            }
        }

        if (star_pi) |sp| {
            if (!star_is_double and text[star_ti] == '/') {
                return false;
            }
            star_ti += 1;
            ti = star_ti;
            pi = sp;
            continue;
        }
        return false;
    }

    while (pi < pat.len and pat[pi] == '*') : (pi += 1) {}
    return pi == pat.len;
}

fn matchCharClass(pat_from_bracket: []const u8, ch: u8) ?usize {
    if (pat_from_bracket.len < 3 or pat_from_bracket[0] != '[') return null;
    var i: usize = 1;
    var negated = false;
    if (pat_from_bracket[i] == '!' or pat_from_bracket[i] == '^') {
        negated = true;
        i += 1;
    }
    const lc = std.ascii.toLower(ch);
    var matched = false;
    var first = true;
    while (i < pat_from_bracket.len) {
        if (pat_from_bracket[i] == ']' and !first) {
            const ok = if (negated) !matched else matched;
            return if (ok) i + 1 else null;
        }
        first = false;
        if (i + 2 < pat_from_bracket.len and pat_from_bracket[i + 1] == '-' and pat_from_bracket[i + 2] != ']') {
            const lo = std.ascii.toLower(pat_from_bracket[i]);
            const hi = std.ascii.toLower(pat_from_bracket[i + 2]);
            if (lo <= hi and lc >= lo and lc <= hi) matched = true;
            i += 3;
        } else {
            if (std.ascii.toLower(pat_from_bracket[i]) == lc) matched = true;
            i += 1;
        }
    }
    return null;
}

const TypeRule = struct {
    name: []const u8,
    exts: []const []const u8,
};

const builtin_type_rules = [_]TypeRule{
    .{ .name = "zig", .exts = &.{ ".zig", ".zon" } },
    .{ .name = "rust", .exts = &.{".rs"} },
    .{ .name = "rs", .exts = &.{".rs"} },
    .{ .name = "ts", .exts = &.{ ".ts", ".mts", ".cts" } },
    .{ .name = "tsx", .exts = &.{".tsx"} },
    .{ .name = "js", .exts = &.{ ".js", ".mjs", ".cjs" } },
    .{ .name = "jsx", .exts = &.{".jsx"} },
    .{ .name = "svelte", .exts = &.{".svelte"} },
    .{ .name = "vue", .exts = &.{".vue"} },
    .{ .name = "py", .exts = &.{ ".py", ".pyi", ".pyw" } },
    .{ .name = "python", .exts = &.{ ".py", ".pyi", ".pyw" } },
    .{ .name = "go", .exts = &.{".go"} },
    .{ .name = "c", .exts = &.{ ".c", ".h" } },
    .{ .name = "cpp", .exts = &.{ ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", ".h" } },
    .{ .name = "h", .exts = &.{ ".h", ".hpp", ".hh" } },
    .{ .name = "java", .exts = &.{".java"} },
    .{ .name = "kt", .exts = &.{ ".kt", ".kts" } },
    .{ .name = "scala", .exts = &.{ ".scala", ".sc" } },
    .{ .name = "cs", .exts = &.{".cs"} },
    .{ .name = "swift", .exts = &.{".swift"} },
    .{ .name = "rb", .exts = &.{".rb"} },
    .{ .name = "php", .exts = &.{".php"} },
    .{ .name = "lua", .exts = &.{".lua"} },
    .{ .name = "sh", .exts = &.{ ".sh", ".bash", ".zsh", ".fish" } },
    .{ .name = "sql", .exts = &.{".sql"} },
    .{ .name = "json", .exts = &.{ ".json", ".jsonc", ".json.gz", ".json.zst", ".json.xz" } },
    .{ .name = "jsonl", .exts = &.{ ".jsonl", ".ndjson", ".jsonl.gz", ".ndjson.gz", ".jsonl.zst", ".jsonl.xz" } },
    .{ .name = "yaml", .exts = &.{ ".yaml", ".yml" } },
    .{ .name = "toml", .exts = &.{".toml"} },
    .{ .name = "xml", .exts = &.{".xml"} },
    .{ .name = "html", .exts = &.{ ".html", ".htm" } },
    .{ .name = "css", .exts = &.{".css"} },
    .{ .name = "scss", .exts = &.{".scss"} },
    .{ .name = "md", .exts = &.{ ".md", ".markdown", ".mdx" } },
    .{ .name = "txt", .exts = &.{ ".txt", ".txt.gz", ".txt.zst", ".txt.xz" } },
    .{ .name = "log", .exts = &.{ ".log", ".out", ".err", ".log.gz", ".log.zst", ".log.xz", ".out.gz", ".err.gz" } },
    .{ .name = "csv", .exts = &.{ ".csv", ".tsv", ".csv.gz", ".tsv.gz" } },
    .{ .name = "conf", .exts = &.{ ".conf", ".cfg", ".ini", ".cnf" } },
    .{ .name = "env", .exts = &.{".env"} },
    .{ .name = "proto", .exts = &.{".proto"} },
    .{ .name = "graphql", .exts = &.{ ".graphql", ".gql" } },
};

pub fn matchesFileType(base_name: []const u8, type_name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(type_name, "docker")) {
        return std.ascii.eqlIgnoreCase(base_name, "Dockerfile") or
            startsWithIgnoreCase(base_name, "Dockerfile.") or
            endsWithIgnoreCase(base_name, ".dockerfile");
    }
    if (std.ascii.eqlIgnoreCase(type_name, "make")) {
        return std.ascii.eqlIgnoreCase(base_name, "Makefile") or
            std.ascii.eqlIgnoreCase(base_name, "GNUmakefile") or
            endsWithIgnoreCase(base_name, ".mk");
    }
    if (std.ascii.eqlIgnoreCase(type_name, "env")) {
        if (std.mem.eql(u8, base_name, ".env") or startsWithIgnoreCase(base_name, ".env.")) return true;
    }

    for (builtin_type_rules) |rule| {
        if (std.ascii.eqlIgnoreCase(type_name, rule.name)) {
            for (rule.exts) |ext| {
                if (endsWithIgnoreCase(base_name, ext)) return true;
            }
            // Also check rotated logs like `app.log.1` / `app.log.1.gz` for `log`
            if (std.mem.eql(u8, rule.name, "log")) {
                if (std.mem.indexOf(u8, base_name, ".log.") != null or
                    std.mem.indexOf(u8, base_name, ".log-") != null)
                {
                    return true;
                }
            }
            return false;
        }
    }

    // Generic fallback: match `*.<type>` and `*.<type>.{gz,zst,xz}`
    if (base_name.len > type_name.len + 1) {
        if (endsWithIgnoreCase(base_name, type_name) and
            base_name[base_name.len - type_name.len - 1] == '.')
        {
            return true;
        }
    }
    const comp_suffixes = [_][]const u8{ ".gz", ".zst", ".xz" };
    for (comp_suffixes) |cs| {
        if (endsWithIgnoreCase(base_name, cs) and base_name.len > cs.len + type_name.len + 1) {
            const stem = base_name[0 .. base_name.len - cs.len];
            if (endsWithIgnoreCase(stem, type_name) and
                stem[stem.len - type_name.len - 1] == '.')
            {
                return true;
            }
        }
    }
    return false;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "path_scope: zero-alloc glob, dir prefix, type filtering, and archive container preservation" {
    const m_zig = FileMeta{ .rel_path = "src/plugins/path_scope.zig" };
    const m_log = FileMeta{ .rel_path = "logs/app-2026-11-10.log.gz", .is_compressed = true };
    const m_test = FileMeta{ .rel_path = "src/foo_test.go" };
    const m_arc = FileMeta{ .rel_path = "bundles/release.tar.gz", .is_archive_container = true };

    // Include globs + exclude globs
    const p1 = QueryPredicates{
        .include_globs = &.{"*.zig"},
        .exclude_globs = &.{"*_test.zig"},
    };
    try std.testing.expectEqual(Verdict.keep, eval(m_zig, p1));
    try std.testing.expectEqual(Verdict.skip, eval(m_log, p1));
    try std.testing.expectEqual(Verdict.skip, eval(m_test, p1));
    // Archive containers stay kept under positive globs because inner entries might match
    try std.testing.expectEqual(Verdict.keep, eval(m_arc, p1));

    // Explicit exclusion of archive container skips it
    const p_arc_excl = QueryPredicates{
        .exclude_globs = &.{"*.tar.gz"},
    };
    try std.testing.expectEqual(Verdict.skip, eval(m_arc, p_arc_excl));

    // Directory prefix + ** glob
    const p_dir = QueryPredicates{
        .include_globs = &.{"src/**"},
    };
    try std.testing.expectEqual(Verdict.keep, eval(m_zig, p_dir));
    try std.testing.expectEqual(Verdict.skip, eval(m_log, p_dir));

    // File type filters (including compressed/rotated logs & `!` negation)
    const p_types = QueryPredicates{
        .file_types = &.{"log"},
    };
    try std.testing.expectEqual(Verdict.keep, eval(m_log, p_types));
    try std.testing.expectEqual(Verdict.skip, eval(m_zig, p_types));

    const p_types_excl = QueryPredicates{
        .file_types = &.{"!zig"},
    };
    try std.testing.expectEqual(Verdict.skip, eval(m_zig, p_types_excl));
    try std.testing.expectEqual(Verdict.keep, eval(m_log, p_types_excl));
}
