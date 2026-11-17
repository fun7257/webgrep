const std = @import("std");
const libwebgrep = @import("libwebgrep");
const docker_logs = @import("docker_logs.zig");
const file_api = @import("file_api.zig");
const source_registry = @import("source_registry.zig");
const search_cache = @import("search_cache.zig");
const time_parser = @import("time_parser.zig");

pub const SearchRequest = struct {
    type: []const u8 = "search",
    id: u64 = 1,
    pattern: []const u8 = "",
    mode: []const u8 = "literal", // "literal" | "multi" | "regex"
    case: []const u8 = "smart", // "smart" | "sensitive" | "insensitive"
    wholeWord: bool = false,
    wholeLine: bool = false,
    invert: bool = false,
    contains: []const []const u8 = &.{},
    excludes: []const []const u8 = &.{},
    replacement: ?[]const u8 = null,
    context: u32 = 0,
    tenant: []const u8 = "default",
    sources: []const []const u8 = &.{},
    paths: []const []const u8 = &.{},
    globs: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    hidden: bool = false,
    respectIgnore: bool = false,
    maxResults: u64 = 20000,
    timeStartNs: u64 = 0,
    timeEndNs: u64 = 0,
    timeStartMs: u64 = 0,
    timeEndMs: u64 = 0,
    timeMode: []const u8 = "auto",
    timeFormat: []const u8 = "",
    tzOffsetMin: i16 = 0,
    /// File/path filters from `@*.rs` / `@src/` / `-@*_test.go` (`!` prefix = exclude).
    /// Matched against each file's source-relative path; positives are OR-ed, negatives always win.
    fileGlobs: []const []const u8 = &.{},
    /// Radius of the nearby-lines fallback used when no single line contains every term (0 = disabled).
    nearbyLines: u32 = 0,
};

pub const FrameSender = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, json_text: []const u8) anyerror!void,

    pub fn send(self: FrameSender, json_text: []const u8) !void {
        return self.sendFn(self.ctx, json_text);
    }
};

pub const HitSpan = struct {
    start: usize,
    end: usize,
};

pub const HitItem = struct {
    file: []const u8,
    line: u64,
    col: u64,
    text: []const u8,
    prevText: ?[]const u8 = null,
    nextText: ?[]const u8 = null,
    replaced: ?[]const u8,
    isContext: bool,
    byteOffset: ?u64 = null,
    spans: []const HitSpan,
};

pub const HitsFrame = struct {
    type: []const u8 = "hits",
    id: u64,
    items: []const HitItem,
};

pub const ProgressFrame = struct {
    type: []const u8 = "progress",
    id: u64,
    filesSearched: u64,
    filesMatched: u64,
    matches: u64,
    bytesSearched: u64,
};

pub const DoneFrame = struct {
    type: []const u8 = "done",
    id: u64,
    elapsedMs: f64,
    filesSearched: u64,
    filesMatched: u64,
    totalMatches: u64,
    matchedLines: u64,
    bytesSearched: u64,
    limitHit: []const u8,
    searchCount: u64 = 0,
    cacheHit: []const u8 = "none",
    /// Non-zero when results come from the nearby-lines fallback (terms spread over ±N lines, not one line).
    nearbyLines: u32 = 0,
};

pub const ErrorFrame = struct {
    type: []const u8 = "error",
    id: u64,
    message: []const u8,
};

const MatcherUnion = union(enum) {
    literal: libwebgrep.Finder,
    multi: libwebgrep.Multi,
    regex: libwebgrep.Regex,

    pub fn deinit(self: *MatcherUnion) void {
        switch (self.*) {
            .literal => {},
            .multi => |*m| m.deinit(),
            .regex => |*r| r.deinit(),
        }
    }
};

pub fn parseCaseMode(case_str: []const u8) libwebgrep.CaseMode {
    if (std.mem.eql(u8, case_str, "sensitive")) return .sensitive;
    if (std.mem.eql(u8, case_str, "insensitive")) return .insensitive;
    return .smart;
}

pub fn hasRegexMeta(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '\\', '.', '*', '+', '?', '^', '$', '(', ')', '[', ']', '{', '}', '|' => return true,
            else => {},
        }
    }
    return false;
}

fn hasAsciiUpper(s: []const u8) bool {
    for (s) |c| {
        if (c >= 'A' and c <= 'Z') return true;
    }
    return false;
}

const ScopedModifier = struct {
    pattern: []const u8,
    case_mode: libwebgrep.CaseMode,
};

fn escapeRegexLiteralAlloc(arena: std.mem.Allocator, lit: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, lit.len * 2);
    for (lit) |c| {
        switch (c) {
            '\\', '.', '*', '+', '?', '^', '$', '(', ')', '[', ']', '{', '}', '|' => {
                try out.append(arena, '\\');
                try out.append(arena, c);
            },
            else => try out.append(arena, c),
        }
    }
    return out.items;
}

/// Parses scoped `$` modifiers: `$r(...)`, `$c(...)`, `$w(...)`, `$rc(...)`, `$rw(...)`, `$cw(...)`, `$rcw(...)`.
/// Only the content inside `$(...)` has regex (`r`), case-sensitive (`c`), or whole-word (`w`) applied;
/// all tokens outside `$(...)` remain pure unmodified literals.
fn parseScopedModifier(
    arena: std.mem.Allocator,
    s: []const u8,
    default_case: libwebgrep.CaseMode,
) ?ScopedModifier {
    if (s.len >= 4 and s[0] == '$') {
        if (std.mem.indexOfScalar(u8, s[1..], '(')) |rel_open| {
            const open_idx = rel_open + 1;
            const flag_part = s[1..open_idx];
            var has_r = false;
            var has_c = false;
            var has_w = false;
            var valid_flag = flag_part.len > 0;

            if (std.ascii.eqlIgnoreCase(flag_part, "re") or
                std.ascii.eqlIgnoreCase(flag_part, "regex") or
                std.mem.eql(u8, flag_part, ".*"))
            {
                has_r = true;
            } else if (std.ascii.eqlIgnoreCase(flag_part, "case") or
                std.ascii.eqlIgnoreCase(flag_part, "aa") or
                std.ascii.eqlIgnoreCase(flag_part, "s"))
            {
                has_c = true;
            } else if (std.ascii.eqlIgnoreCase(flag_part, "word") or
                std.ascii.eqlIgnoreCase(flag_part, "b") or
                std.mem.eql(u8, flag_part, "\\b"))
            {
                has_w = true;
            } else {
                for (flag_part) |ch| {
                    const lower = std.ascii.toLower(ch);
                    if (lower == 'r') {
                        has_r = true;
                    } else if (lower == 'c') {
                        has_c = true;
                    } else if (lower == 'w') {
                        has_w = true;
                    } else {
                        valid_flag = false;
                        break;
                    }
                }
            }

            if (valid_flag and (has_r or has_c or has_w)) {
                const inner_start = open_idx + 1;
                const inner_end = if (s.len > inner_start and s[s.len - 1] == ')') s.len - 1 else s.len;
                if (inner_end > inner_start) {
                    const raw_inner = s[inner_start..inner_end];
                    const base_pat = if (has_r)
                        raw_inner
                    else
                        (escapeRegexLiteralAlloc(arena, raw_inner) catch return null);

                    const final_pat = if (has_w) blk: {
                        if (has_r and std.mem.indexOfScalar(u8, base_pat, '|') != null) {
                            break :blk std.fmt.allocPrint(arena, "\\b(?:{s})\\b", .{base_pat}) catch return null;
                        } else {
                            break :blk std.fmt.allocPrint(arena, "\\b{s}\\b", .{base_pat}) catch return null;
                        }
                    } else base_pat;

                    return .{
                        .pattern = final_pat,
                        .case_mode = if (has_c) .sensitive else default_case,
                    };
                }
            }
        }
    }
    return null;
}

/// Caller-configured engine limits for `libwebgrep v0.5.0`.
/// Since `libwebgrep v0.5.0` removed internal hardcoded upper caps (`*_hard_cap`),
/// `webgrep` explicitly defines and passes its own caller-level bounds.
pub const EngineLimits = struct {
    pub const max_pattern_count: usize = 4096;
    pub const max_pattern_bytes: usize = 1024 * 1024;
    pub const max_unicode_variants: usize = 64;
    pub const max_regex_inst: usize = 32768;
    pub const max_regex_repeat: usize = 2000;
    pub const max_regex_recursion_depth: usize = 128;
    pub const aot_dfa_max_insts: usize = 256;
    pub const max_context_lines: u32 = 100;
    pub const max_line_len: usize = 8 * 1024 * 1024;
    pub const max_compression_ratio: u64 = 1000;
    pub const max_source_bytes: u64 = 1024 * 1024 * 1024 * 1024;
    pub const max_request_bytes: u64 = 1024 * 1024 * 1024 * 1024;
    pub const max_output_bytes: u64 = 1024 * 1024 * 1024 * 1024;
    pub const time_budget_ns: u64 = 3600 * std.time.ns_per_s;
    pub const max_decode_bytes: usize = 1024 * 1024 * 1024;
    pub const max_decompressed_bytes: u64 = 1024 * 1024 * 1024;
    pub const max_before_bytes: usize = @as(usize, max_context_lines) * max_line_len;
    pub const max_queued_event_bytes: usize = max_line_len;
    pub const max_glob_rules: usize = 4096;
    pub const max_glob_rule_len: usize = 4096;
    pub const max_glob_brace_depth: usize = 8;
    pub const max_archive_entries: usize = 100_000;
    pub const max_archive_entry_bytes: u64 = 256 * 1024 * 1024;
    pub const max_archive_total_bytes: u64 = 1024 * 1024 * 1024;
    pub const max_archive_slice_map_bytes: u64 = 64 * 1024 * 1024;

    pub fn archiveOptions(format: libwebgrep.ArchiveFormat) libwebgrep.ArchiveOptions {
        return .{
            .format = format,
            .max_entries = max_archive_entries,
            .max_entry_bytes = max_archive_entry_bytes,
            .max_total_bytes = max_archive_total_bytes,
            .max_compression_ratio = max_compression_ratio,
        };
    }

    pub fn findOptions(case_mode: libwebgrep.CaseMode) libwebgrep.FindOptions {
        return .{
            .case = case_mode,
            .max_pattern_count = max_pattern_count,
            .max_pattern_bytes = max_pattern_bytes,
            .max_unicode_variants = max_unicode_variants,
        };
    }

    pub fn regexOptions(case_mode: libwebgrep.CaseMode) libwebgrep.RegexOptions {
        return .{
            .case = case_mode,
            .max_inst = max_regex_inst,
            .max_repeat = max_regex_repeat,
            .max_recursion_depth = max_regex_recursion_depth,
            .max_pattern_count = max_pattern_count,
            .max_pattern_bytes = max_pattern_bytes,
            .max_unicode_variants = max_unicode_variants,
            .aot_dfa_max_insts = aot_dfa_max_insts,
        };
    }

    pub fn globOptions() libwebgrep.walk_glob.CompileOptions {
        return .{
            .max_rules = max_glob_rules,
            .max_rule_len = max_glob_rule_len,
            .max_brace_depth = max_glob_brace_depth,
        };
    }
};

pub const ARCHIVE_VIRTUAL_SEP = if (@hasDecl(file_api, "ARCHIVE_VIRTUAL_SEP"))
    file_api.ARCHIVE_VIRTUAL_SEP
else
    "::";

pub fn detectArchiveFormat(path: []const u8) ?libwebgrep.ArchiveFormat {
    if (@hasDecl(file_api, "detectArchiveFormat")) {
        return file_api.detectArchiveFormat(path);
    }
    const check = struct {
        fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
            if (haystack.len < suffix.len) return false;
            return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
        }
    };
    if (check.endsWithIgnoreCase(path, ".tar.gz") or check.endsWithIgnoreCase(path, ".tgz")) return .tar_gz;
    if (check.endsWithIgnoreCase(path, ".tar.zst") or check.endsWithIgnoreCase(path, ".tzst")) return .tar_zst;
    if (check.endsWithIgnoreCase(path, ".tar.xz") or check.endsWithIgnoreCase(path, ".txz")) return .tar_xz;
    if (check.endsWithIgnoreCase(path, ".tar")) return .tar;
    if (check.endsWithIgnoreCase(path, ".zip")) return .zip;
    return null;
}

fn isSingleStreamCompressed(path: []const u8) bool {
    if (detectArchiveFormat(path) != null) return false;
    return file_api.hasCompressedExtension(path);
}

fn formatArchiveVirtualPathAlloc(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    entry_path: []const u8,
) ![]u8 {
    if (@hasDecl(file_api, "formatArchiveVirtualPathAlloc")) {
        return file_api.formatArchiveVirtualPathAlloc(allocator, archive_path, entry_path);
    }
    var clean_entry = entry_path;
    while (std.mem.startsWith(u8, clean_entry, "./")) {
        clean_entry = clean_entry[2..];
    }
    clean_entry = std.mem.trimStart(u8, clean_entry, "/");
    return std.fmt.allocPrint(allocator, "{s}" ++ ARCHIVE_VIRTUAL_SEP ++ "{s}", .{ archive_path, clean_entry });
}

pub fn formatRegexDiagnosticAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    diag: libwebgrep.CompileDiagnostic,
    fallback_err: anyerror,
) ![]u8 {
    if (diag.code != .none) {
        return std.fmt.allocPrint(
            allocator,
            "Regex compile error ({s}) at line {d}, column {d} (offset {d}): {s} in pattern \"{s}\"",
            .{ @tagName(diag.code), diag.line, diag.column, diag.offset, diag.message, pattern },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Regex compile error ({s}) in pattern \"{s}\"",
        .{ @errorName(fallback_err), pattern },
    );
}

/// Extended language & file-type table supplementing `libwebgrep.walk_types.builtin` (together 65+ types),
/// plus support for compressed log/data extensions.
pub const custom_file_types = [_]libwebgrep.walk_types.Type{
    .{ .name = "log", .patterns = &.{ "*.log", "*.log.*", "*.log.gz", "*.log.zst", "*.log.xz", "*.out", "*.err" } },
    .{ .name = "json", .patterns = &.{ "*.json", "*.jsonl", "*.ndjson", "*.jsonc", "*.json5", "*.json.gz", "*.json.zst", "*.json.xz" } },
    .{ .name = "jsonl", .patterns = &.{ "*.jsonl", "*.ndjson", "*.jsonl.gz", "*.jsonl.zst", "*.jsonl.xz" } },
    .{ .name = "txt", .patterns = &.{ "*.txt", "*.text", "*.txt.gz", "*.txt.zst", "*.txt.xz" } },
    .{ .name = "rs", .patterns = &.{"*.rs"} },
    .{ .name = "yml", .patterns = &.{ "*.yml", "*.yaml" } },
    .{ .name = "svelte", .patterns = &.{"*.svelte"} },
    .{ .name = "vue", .patterns = &.{"*.vue"} },
    .{ .name = "jsx", .patterns = &.{"*.jsx"} },
    .{ .name = "tsx", .patterns = &.{"*.tsx"} },
    .{ .name = "sql", .patterns = &.{"*.sql"} },
    .{ .name = "proto", .patterns = &.{"*.proto"} },
    .{ .name = "graphql", .patterns = &.{ "*.graphql", "*.gql" } },
    .{ .name = "gql", .patterns = &.{ "*.graphql", "*.gql" } },
    .{ .name = "xml", .patterns = &.{ "*.xml", "*.xsd", "*.xsl", "*.plist", "*.svg" } },
    .{ .name = "svg", .patterns = &.{"*.svg"} },
    .{ .name = "csv", .patterns = &.{ "*.csv", "*.tsv", "*.csv.gz", "*.csv.zst" } },
    .{ .name = "tsv", .patterns = &.{ "*.tsv", "*.tsv.gz", "*.tsv.zst" } },
    .{ .name = "ini", .patterns = &.{ "*.ini", "*.conf", "*.cfg", "*.properties" } },
    .{ .name = "conf", .patterns = &.{ "*.conf", "*.cfg", "*.ini" } },
    .{ .name = "cfg", .patterns = &.{ "*.cfg", "*.conf", "*.ini" } },
    .{ .name = "env", .patterns = &.{ ".env", ".env.*", "*.env" } },
    .{ .name = "lock", .patterns = &.{ "*.lock", "package-lock.json", "pnpm-lock.yaml", "Cargo.lock", "build.zig.zon" } },
    .{ .name = "zon", .patterns = &.{"*.zon"} },
    .{ .name = "zig", .patterns = &.{ "*.zig", "*.zon" } },
    .{ .name = "rb", .patterns = &.{ "*.rb", "*.rake", "Gemfile", "Rakefile" } },
    .{ .name = "ruby", .patterns = &.{ "*.rb", "*.rake", "Gemfile", "Rakefile" } },
    .{ .name = "php", .patterns = &.{ "*.php", "*.phtml" } },
    .{ .name = "swift", .patterns = &.{"*.swift"} },
    .{ .name = "kt", .patterns = &.{ "*.kt", "*.kts" } },
    .{ .name = "kotlin", .patterns = &.{ "*.kt", "*.kts" } },
    .{ .name = "scala", .patterns = &.{ "*.scala", "*.sc" } },
    .{ .name = "cs", .patterns = &.{ "*.cs", "*.csx" } },
    .{ .name = "csharp", .patterns = &.{ "*.cs", "*.csx" } },
    .{ .name = "lua", .patterns = &.{"*.lua"} },
    .{ .name = "dart", .patterns = &.{"*.dart"} },
    .{ .name = "ex", .patterns = &.{ "*.ex", "*.exs" } },
    .{ .name = "elixir", .patterns = &.{ "*.ex", "*.exs" } },
    .{ .name = "erl", .patterns = &.{ "*.erl", "*.hrl" } },
    .{ .name = "erlang", .patterns = &.{ "*.erl", "*.hrl" } },
    .{ .name = "hs", .patterns = &.{ "*.hs", "*.lhs" } },
    .{ .name = "haskell", .patterns = &.{ "*.hs", "*.lhs" } },
    .{ .name = "ml", .patterns = &.{ "*.ml", "*.mli" } },
    .{ .name = "ocaml", .patterns = &.{ "*.ml", "*.mli" } },
    .{ .name = "clj", .patterns = &.{ "*.clj", "*.cljs", "*.cljc", "*.edn" } },
    .{ .name = "clojure", .patterns = &.{ "*.clj", "*.cljs", "*.cljc", "*.edn" } },
    .{ .name = "r", .patterns = &.{ "*.r", "*.R", "*.Rmd" } },
    .{ .name = "jl", .patterns = &.{"*.jl"} },
    .{ .name = "julia", .patterns = &.{"*.jl"} },
    .{ .name = "pl", .patterns = &.{ "*.pl", "*.pm" } },
    .{ .name = "perl", .patterns = &.{ "*.pl", "*.pm" } },
    .{ .name = "docker", .patterns = &.{ "Dockerfile", "Dockerfile.*", "*.dockerfile", "docker-compose.yml", "docker-compose.yaml" } },
    .{ .name = "dockerfile", .patterns = &.{ "Dockerfile", "Dockerfile.*", "*.dockerfile" } },
    .{ .name = "tf", .patterns = &.{ "*.tf", "*.tfvars", "*.hcl" } },
    .{ .name = "terraform", .patterns = &.{ "*.tf", "*.tfvars", "*.hcl" } },
    .{ .name = "nix", .patterns = &.{"*.nix"} },
    .{ .name = "vim", .patterns = &.{ "*.vim", ".vimrc" } },
    .{ .name = "fish", .patterns = &.{"*.fish"} },
    .{ .name = "zsh", .patterns = &.{ "*.zsh", ".zshrc" } },
    .{ .name = "bash", .patterns = &.{ "*.bash", "*.sh", ".bashrc" } },
    .{ .name = "ps1", .patterns = &.{ "*.ps1", "*.psm1", "*.psd1" } },
    .{ .name = "powershell", .patterns = &.{ "*.ps1", "*.psm1", "*.psd1" } },
    .{ .name = "bat", .patterns = &.{ "*.bat", "*.cmd" } },
    .{ .name = "less", .patterns = &.{"*.less"} },
    .{ .name = "scss", .patterns = &.{ "*.scss", "*.sass" } },
    .{ .name = "sass", .patterns = &.{ "*.sass", "*.scss" } },
    .{ .name = "wasm", .patterns = &.{ "*.wasm", "*.wat", "*.wast" } },
    .{ .name = "sol", .patterns = &.{"*.sol"} },
};

/// Computes the SIMD prefilter selectivity score for a compiled regex (`libwebgrep v0.5.0`).
/// Higher scores indicate stronger fixed-literal or Teddy multi-literal anchors (`Finder` / `Multi` at 20+ GB/s)
/// and Ahead-of-Time determinized `BoundedDfa` tables (`precomputed_dfa`), while unanchored NFAs score 1..3.
fn computeRegexSelectivity(re: *const libwebgrep.Regex) usize {
    const req_len = if (re.requiredLiteral()) |rl| rl.bytes.len else 0;
    const tail_len = re.tail_literal_bytes.len;
    if (re.req_is_exact) return req_len * 10 + 5;
    if (req_len > 0) {
        const dfa_bonus: usize = if (re.dfa_is_exact) 4 else if (re.precomputed_dfa != null) 2 else 0;
        return req_len * 8 + tail_len * 4 + dfa_bonus;
    }
    if (re.alt_prefilter != null and re.alt_literal_slices.len > 0) {
        var min_alt_len: usize = std.math.maxInt(usize);
        for (re.alt_literal_slices) |branch| {
            if (branch.len < min_alt_len) min_alt_len = branch.len;
        }
        if (min_alt_len != std.math.maxInt(usize) and min_alt_len > 0) {
            if (re.alt_is_exact) return min_alt_len * 9 + 3;
            const dfa_bonus: usize = if (re.precomputed_dfa != null) 2 else 0;
            return min_alt_len * 7 + dfa_bonus;
        }
    }
    if (re.precomputed_dfa != null) {
        return if (re.dfa_is_exact) 3 else 2;
    }
    return 1;
}

fn computeLiteralSelectivity(lit: []const u8) usize {
    return lit.len * 10 + 5;
}

pub fn executeSearchJson(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    registry: ?*source_registry.SourceRegistry,
    raw_json: []const u8,
    cancel_flag: *const std.atomic.Value(bool),
    sender: FrameSender,
) !void {
    var parsed = std.json.parseFromSlice(SearchRequest, gpa, raw_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        try sendError(gpa, sender, 0, @errorName(err));
        return;
    };
    defer parsed.deinit();

    try executeSearchWithRegistry(gpa, io, root_dir, registry, parsed.value, cancel_flag, sender);
}

pub fn executeSearch(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    req: SearchRequest,
    cancel_flag: *const std.atomic.Value(bool),
    sender: FrameSender,
) !void {
    return executeSearchWithRegistry(gpa, io, root_dir, null, req, cancel_flag, sender);
}

pub fn executeSearchWithRegistry(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    registry: ?*source_registry.SourceRegistry,
    req: SearchRequest,
    cancel_flag: *const std.atomic.Value(bool),
    sender: FrameSender,
) !void {
    const start_ts = std.Io.Clock.awake.now(io);
    const eff_time_start_ns: u64 = if (req.timeStartNs > 0) req.timeStartNs else req.timeStartMs *| 1_000_000;
    const eff_time_end_ns: u64 = if (req.timeEndNs > 0) req.timeEndNs else req.timeEndMs *| 1_000_000;
    const has_time_filter = (eff_time_start_ns > 0 or eff_time_end_ns > 0);

    // If pattern is empty and neither invert, contains, nor time filter is active, complete immediately with 0 hits.
    if (req.pattern.len == 0 and !req.invert and req.contains.len == 0 and !has_time_filter) {
        const elapsed_ns = start_ts.untilNow(io, .awake).toNanoseconds();
        const elapsed_ms: f64 = @as(f64, @floatFromInt(@max(elapsed_ns, 0))) / 1_000_000.0;
        const done_json = try file_api.stringifyAlloc(gpa, DoneFrame{
            .id = req.id,
            .elapsedMs = elapsed_ms,
            .filesSearched = 0,
            .filesMatched = 0,
            .totalMatches = 0,
            .matchedLines = 0,
            .bytesSearched = 0,
            .limitHit = "none",
        });
        defer gpa.free(done_json);
        try sender.send(done_json);
        return;
    }

    var job_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer job_arena_state.deinit();
    const job_arena = job_arena_state.allocator();

    const case_mode = parseCaseMode(req.case);
    const is_regex_mode = std.mem.eql(u8, req.mode, "regex");

    var literal_contains_list: std.ArrayList([]const u8) = .empty;
    var literal_excludes_list: std.ArrayList([]const u8) = .empty;
    var contains_regexes: std.ArrayList(libwebgrep.Regex) = .empty;
    defer {
        for (contains_regexes.items) |*re| re.deinit();
        contains_regexes.deinit(gpa);
    }
    var excludes_regexes: std.ArrayList(libwebgrep.Regex) = .empty;
    defer {
        for (excludes_regexes.items) |*re| re.deinit();
        excludes_regexes.deinit(gpa);
    }

    const can_reorder_predicates = !std.mem.eql(u8, req.mode, "multi") and
        !req.wholeWord and
        !req.wholeLine and
        !req.invert and
        (req.replacement == null or req.replacement.?.len == 0) and
        req.pattern.len > 0 and
        req.contains.len > 0;

    var swapped_primary_regex_first: bool = false;
    var swapped_primary_finder: ?libwebgrep.Finder = null;

    var matcher: MatcherUnion = blk: {
        if (std.mem.eql(u8, req.mode, "multi")) {
            var parts: std.ArrayList([]const u8) = .empty;
            var start: usize = 0;
            var i: usize = 0;
            while (i <= req.pattern.len) : (i += 1) {
                if (i == req.pattern.len or req.pattern[i] == '\n' or req.pattern[i] == '|') {
                    var seg = req.pattern[start..i];
                    if (seg.len > 0 and seg[seg.len - 1] == '\r') seg = seg[0 .. seg.len - 1];
                    if (seg.len > 0) {
                        try parts.append(job_arena, seg);
                    }
                    start = i + 1;
                }
            }
            if (parts.items.len == 0) {
                const elapsed_ns = start_ts.untilNow(io, .awake).toNanoseconds();
                const elapsed_ms: f64 = @as(f64, @floatFromInt(@max(elapsed_ns, 0))) / 1_000_000.0;
                const done_json = try file_api.stringifyAlloc(gpa, DoneFrame{
                    .id = req.id,
                    .elapsedMs = elapsed_ms,
                    .filesSearched = 0,
                    .filesMatched = 0,
                    .totalMatches = 0,
                    .matchedLines = 0,
                    .bytesSearched = 0,
                    .limitHit = "none",
                });
                defer gpa.free(done_json);
                try sender.send(done_json);
                return;
            }
            const m = libwebgrep.Multi.init(gpa, parts.items, EngineLimits.findOptions(case_mode)) catch |err| {
                try sendError(gpa, sender, req.id, @errorName(err));
                return;
            };
            break :blk .{ .multi = m };
        } else if (can_reorder_predicates) {
            // Cost-Based Selectivity Planner:
            // Evaluate all positive predicates (`req.pattern` + `req.contains`), classify each as
            // either a compiled `Regex` or a literal, and elect the highest-selectivity predicate
            // (with deterministic lexicographical tie-breaking) as the primary SIMD scanner (`matcher`).
            const CandidateKind = union(enum) {
                literal: []const u8,
                regex: libwebgrep.Regex,
            };
            const Candidate = struct {
                raw: []const u8,
                score: usize,
                kind: CandidateKind,
            };
            var candidates: std.ArrayList(Candidate) = .empty;
            const freeCandidates = struct {
                fn run(alloc: std.mem.Allocator, list: *std.ArrayList(Candidate)) void {
                    for (list.items) |*c| {
                        switch (c.kind) {
                            .regex => |*re| re.deinit(),
                            .literal => {},
                        }
                    }
                    list.deinit(alloc);
                }
            }.run;
            errdefer freeCandidates(gpa, &candidates);

            const classifyTerm = struct {
                fn run(
                    alloc: std.mem.Allocator,
                    arena_alloc: std.mem.Allocator,
                    snd: FrameSender,
                    req_id: u64,
                    raw_pat: []const u8,
                    regex_mode: bool,
                    cm: libwebgrep.CaseMode,
                ) !?Candidate {
                    if (parseScopedModifier(arena_alloc, raw_pat, cm)) |scoped_spec| {
                        var diag: libwebgrep.CompileDiagnostic = .{};
                        const re = libwebgrep.Regex.initDiagnostic(alloc, scoped_spec.pattern, EngineLimits.regexOptions(scoped_spec.case_mode), &diag) catch |err| {
                            const msg = try formatRegexDiagnosticAlloc(arena_alloc, scoped_spec.pattern, diag, err);
                            try sendError(alloc, snd, req_id, msg);
                            return null;
                        };
                        return .{
                            .raw = raw_pat,
                            .score = computeRegexSelectivity(&re),
                            .kind = .{ .regex = re },
                        };
                    }
                    if (regex_mode and hasRegexMeta(raw_pat)) {
                        var diag: libwebgrep.CompileDiagnostic = .{};
                        if (libwebgrep.Regex.initDiagnostic(alloc, raw_pat, EngineLimits.regexOptions(cm), &diag)) |re| {
                            return .{
                                .raw = raw_pat,
                                .score = computeRegexSelectivity(&re),
                                .kind = .{ .regex = re },
                            };
                        } else |_| {}
                    }
                    return .{
                        .raw = raw_pat,
                        .score = computeLiteralSelectivity(raw_pat),
                        .kind = .{ .literal = raw_pat },
                    };
                }
            }.run;

            const first_cand = (try classifyTerm(gpa, job_arena, sender, req.id, req.pattern, is_regex_mode, case_mode)) orelse {
                freeCandidates(gpa, &candidates);
                return;
            };
            try candidates.append(gpa, first_cand);
            for (req.contains) |pat| {
                if (pat.len == 0) continue;
                const cand = (try classifyTerm(gpa, job_arena, sender, req.id, pat, is_regex_mode, case_mode)) orelse {
                    freeCandidates(gpa, &candidates);
                    return;
                };
                try candidates.append(gpa, cand);
            }

            var best_idx: usize = 0;
            for (candidates.items, 0..) |cand, idx| {
                if (idx == 0) continue;
                const best = candidates.items[best_idx];
                if (cand.score > best.score or
                    (cand.score == best.score and std.mem.order(u8, cand.raw, best.raw) == .lt))
                {
                    best_idx = idx;
                }
            }

            for (candidates.items, 0..) |*cand, idx| {
                if (idx == best_idx) continue;
                switch (cand.kind) {
                    .regex => |re| {
                        if (idx == 0) swapped_primary_regex_first = true;
                        try contains_regexes.append(gpa, re);
                    },
                    .literal => |lit| {
                        if (idx == 0) {
                            swapped_primary_finder = libwebgrep.Finder.init(lit, EngineLimits.findOptions(case_mode)) catch null;
                        }
                        try literal_contains_list.append(job_arena, lit);
                    },
                }
            }

            const winner = candidates.items[best_idx];
            candidates.deinit(gpa);

            switch (winner.kind) {
                .regex => |re| break :blk .{ .regex = re },
                .literal => |lit| {
                    const f = libwebgrep.Finder.init(lit, EngineLimits.findOptions(case_mode)) catch |err| {
                        try sendError(gpa, sender, req.id, @errorName(err));
                        return;
                    };
                    break :blk .{ .literal = f };
                },
            }
        } else if (parseScopedModifier(job_arena, req.pattern, case_mode)) |scoped_spec| {
            var diag: libwebgrep.CompileDiagnostic = .{};
            const re = libwebgrep.Regex.initDiagnostic(gpa, scoped_spec.pattern, EngineLimits.regexOptions(scoped_spec.case_mode), &diag) catch |err| {
                const msg = try formatRegexDiagnosticAlloc(job_arena, scoped_spec.pattern, diag, err);
                try sendError(gpa, sender, req.id, msg);
                return;
            };
            break :blk .{ .regex = re };
        } else if (req.pattern.len == 0 and has_time_filter) {
            var diag: libwebgrep.CompileDiagnostic = .{};
            const re = libwebgrep.Regex.initDiagnostic(gpa, "^.", EngineLimits.regexOptions(.sensitive), &diag) catch |err| {
                const msg = try formatRegexDiagnosticAlloc(job_arena, "^.", diag, err);
                try sendError(gpa, sender, req.id, msg);
                return;
            };
            break :blk .{ .regex = re };
        } else if (is_regex_mode) {
            var diag: libwebgrep.CompileDiagnostic = .{};
            const re = libwebgrep.Regex.initDiagnostic(gpa, req.pattern, EngineLimits.regexOptions(case_mode), &diag) catch |err| {
                const msg = try formatRegexDiagnosticAlloc(job_arena, req.pattern, diag, err);
                try sendError(gpa, sender, req.id, msg);
                return;
            };
            break :blk .{ .regex = re };
        } else {
            const f = libwebgrep.Finder.init(req.pattern, EngineLimits.findOptions(case_mode)) catch |err| {
                try sendError(gpa, sender, req.id, @errorName(err));
                return;
            };
            break :blk .{ .literal = f };
        }
    };
    defer matcher.deinit();

    const compiled_globs: []const libwebgrep.walk_glob.Glob = if (req.globs.len > 0)
        libwebgrep.walk_glob.compileGlobs(job_arena, req.globs, EngineLimits.globOptions()) catch |err| {
            try sendError(gpa, sender, req.id, @errorName(err));
            return;
        }
    else
        &.{};

    var expanded_file_globs_list: std.ArrayList([]const u8) = .empty;
    for (req.fileGlobs) |raw_fg| {
        const trimmed = std.mem.trim(u8, raw_fg, " \t");
        if (trimmed.len == 0) continue;
        const is_neg = trimmed[0] == '!';
        const body = if (is_neg) trimmed[1..] else trimmed;
        if (body.len == 0) continue;
        if (std.mem.indexOfScalar(u8, body, '{') != null) {
            var br_out: std.ArrayList([]u8) = .empty;
            if (libwebgrep.walk_glob.expandBracesWithOptions(job_arena, body, &br_out, EngineLimits.globOptions())) {
                for (br_out.items) |expanded_part| {
                    if (is_neg) {
                        const neg_part = try std.fmt.allocPrint(job_arena, "!{s}", .{expanded_part});
                        try expanded_file_globs_list.append(job_arena, neg_part);
                    } else {
                        try expanded_file_globs_list.append(job_arena, expanded_part);
                    }
                }
                continue;
            } else |_| {}
        }
        try expanded_file_globs_list.append(job_arena, trimmed);
    }

    var types_include_list: std.ArrayList([]const u8) = .empty;
    var types_exclude_list: std.ArrayList([]const u8) = .empty;
    var custom_types_list: std.ArrayList(libwebgrep.walk_types.Type) = .empty;
    try custom_types_list.appendSlice(job_arena, &custom_file_types);

    for (req.types) |raw_type| {
        const trimmed = std.mem.trim(u8, raw_type, " \t");
        if (trimmed.len == 0) continue;
        const is_neg = trimmed[0] == '!';
        const t_name = std.mem.trimStart(u8, if (is_neg) trimmed[1..] else trimmed, ".");
        if (t_name.len == 0) continue;
        if (is_neg) {
            try types_exclude_list.append(job_arena, t_name);
        } else {
            try types_include_list.append(job_arena, t_name);
        }
        if (libwebgrep.walk_types.findInTable(custom_types_list.items, t_name) == null) {
            const g1 = try std.fmt.allocPrint(job_arena, "*.{s}", .{t_name});
            const g2 = try std.fmt.allocPrint(job_arena, "*.{s}.gz", .{t_name});
            const g3 = try std.fmt.allocPrint(job_arena, "*.{s}.zst", .{t_name});
            const g4 = try std.fmt.allocPrint(job_arena, "*.{s}.xz", .{t_name});
            const globs_slice = try job_arena.alloc([]const u8, 4);
            globs_slice[0] = g1;
            globs_slice[1] = g2;
            globs_slice[2] = g3;
            globs_slice[3] = g4;
            try custom_types_list.append(job_arena, .{
                .name = t_name,
                .patterns = globs_slice,
            });
        }
    }

    if (!can_reorder_predicates) {
        for (req.contains) |pat| {
            if (pat.len == 0) continue;
            if (parseScopedModifier(job_arena, pat, case_mode)) |scoped_spec| {
                var diag: libwebgrep.CompileDiagnostic = .{};
                const re = libwebgrep.Regex.initDiagnostic(gpa, scoped_spec.pattern, EngineLimits.regexOptions(scoped_spec.case_mode), &diag) catch |err| {
                    const msg = try formatRegexDiagnosticAlloc(job_arena, scoped_spec.pattern, diag, err);
                    try sendError(gpa, sender, req.id, msg);
                    return;
                };
                try contains_regexes.append(gpa, re);
            } else if (is_regex_mode and hasRegexMeta(pat)) {
                var diag: libwebgrep.CompileDiagnostic = .{};
                if (libwebgrep.Regex.initDiagnostic(gpa, pat, EngineLimits.regexOptions(case_mode), &diag)) |re| {
                    try contains_regexes.append(gpa, re);
                } else |_| {
                    try literal_contains_list.append(job_arena, pat);
                }
            } else {
                try literal_contains_list.append(job_arena, pat);
            }
        }
    }

    for (req.excludes) |pat| {
        if (pat.len == 0) continue;
        if (parseScopedModifier(job_arena, pat, case_mode)) |scoped_spec| {
            var diag: libwebgrep.CompileDiagnostic = .{};
            const re = libwebgrep.Regex.initDiagnostic(gpa, scoped_spec.pattern, EngineLimits.regexOptions(scoped_spec.case_mode), &diag) catch |err| {
                const msg = try formatRegexDiagnosticAlloc(job_arena, scoped_spec.pattern, diag, err);
                try sendError(gpa, sender, req.id, msg);
                return;
            };
            try excludes_regexes.append(gpa, re);
        } else if (is_regex_mode and hasRegexMeta(pat)) {
            var diag: libwebgrep.CompileDiagnostic = .{};
            if (libwebgrep.Regex.initDiagnostic(gpa, pat, EngineLimits.regexOptions(case_mode), &diag)) |re| {
                try excludes_regexes.append(gpa, re);
            } else |_| {
                try literal_excludes_list.append(job_arena, pat);
            }
        } else {
            try literal_excludes_list.append(job_arena, pat);
        }
    }

    const base_literal_contains = literal_contains_list.items;
    const base_literal_excludes = literal_excludes_list.items;

    const time_mode = time_parser.TimeMode.parse(req.timeMode);
    const has_time_window = (eff_time_start_ns > 0 or eff_time_end_ns > 0);
    const is_empty_text_time_browse = has_time_window and
        req.pattern.len == 0 and
        req.contains.len == 0 and
        req.excludes.len == 0 and
        !req.invert;

    var time_parsers_pool: std.ArrayList(TimeParserPoolEntry) = .empty;
    defer {
        for (time_parsers_pool.items) |item| {
            item.ptr.deinit(gpa);
            gpa.destroy(item.ptr);
        }
        time_parsers_pool.deinit(gpa);
    }

    const default_auto_parser: *const time_parser.CompiledTimeParser = blk_def_tp: {
        const p = try gpa.create(time_parser.CompiledTimeParser);
        p.* = .{};
        errdefer gpa.destroy(p);
        try time_parsers_pool.append(gpa, .{ .key = "", .ptr = p });
        break :blk_def_tp p;
    };

    const trimmed_req_tf = std.mem.trim(u8, req.timeFormat, " \t\r\n");
    var query_line_parser: ?*const time_parser.CompiledTimeParser = null;
    if (has_time_window and time_mode != .mtime and trimmed_req_tf.len > 0) {
        var tp_err: ?[]const u8 = null;
        const p = try gpa.create(time_parser.CompiledTimeParser);
        p.* = .{};
        var ownership_transferred = false;
        defer if (!ownership_transferred) gpa.destroy(p);
        p.initInPlace(gpa, job_arena, trimmed_req_tf, &tp_err) catch |err| {
            if (err == error.InvalidTimeFormat) {
                try sendError(gpa, sender, req.id, tp_err orelse "Invalid line time format");
                return;
            }
            return err;
        };
        const key_copy = try job_arena.dupe(u8, trimmed_req_tf);
        try time_parsers_pool.append(gpa, .{ .key = key_copy, .ptr = p });
        ownership_transferred = true;
        query_line_parser = p;
    }

    var time_format_sig_buf: std.ArrayList(u8) = .empty;
    if (has_time_window and time_mode != .mtime and trimmed_req_tf.len > 0) {
        try time_format_sig_buf.appendSlice(job_arena, "q=");
        try time_format_sig_buf.appendSlice(job_arena, trimmed_req_tf);
    }

    var runner = JobRunner{
        .gpa = gpa,
        .job_arena = job_arena,
        .io = io,
        .root_dir = root_dir,
        .registry = registry,
        .req = req,
        .matcher = &matcher,
        .compiled_globs = compiled_globs,
        .expanded_file_globs = expanded_file_globs_list.items,
        .types_include = types_include_list.items,
        .types_exclude = types_exclude_list.items,
        .custom_types_table = custom_types_list.items,
        .contains_regexes = contains_regexes.items,
        .excludes_regexes = excludes_regexes.items,
        .swapped_primary_regex_first = swapped_primary_regex_first,
        .swapped_primary_finder = swapped_primary_finder,
        .cancel_flag = cancel_flag,
        .sender = sender,
        .last_progress_ts = start_ts,
        .time_start_ns = eff_time_start_ns,
        .time_end_ns = eff_time_end_ns,
        .time_mode = time_mode,
        .tz_offset_min = req.tzOffsetMin,
        .time_format_sig = time_format_sig_buf.items,
        .default_line_time_parser = default_auto_parser,
        .is_empty_text_time_browse = is_empty_text_time_browse,
    };
    defer runner.file_tasks.deinit(job_arena);
    defer runner.active_task_indices.deinit(job_arena);

    if (registry) |reg| {
        const all_sources = try reg.snapshotAllSources(job_arena, io);
        for (all_sources) |src| {
            if (runner.shouldStop()) break;
            if (!src.enabled) {
                var explicitly_selected = false;
                for (req.sources) |sid| {
                    if (std.mem.eql(u8, sid, src.id) or std.ascii.eqlIgnoreCase(sid, src.name)) {
                        explicitly_selected = true;
                        break;
                    }
                }
                if (!explicitly_selected) {
                    for (req.globs) |raw_rule| {
                        const trimmed = std.mem.trim(u8, raw_rule, " \t");
                        if (trimmed.len == 0 or trimmed[0] == '!') continue;
                        var it = std.mem.splitScalar(u8, trimmed, ',');
                        while (it.next()) |part| {
                            if (JobRunner.matchesProjectScopeToken(src.id, src.name, part)) {
                                explicitly_selected = true;
                                break;
                            }
                        }
                        if (explicitly_selected) break;
                    }
                }
                if (!explicitly_selected) continue;
            }
            if (req.sources.len > 0) {
                var matched_src = false;
                for (req.sources) |sid| {
                    if (std.mem.eql(u8, sid, src.id) or std.ascii.eqlIgnoreCase(sid, src.name)) {
                        matched_src = true;
                        break;
                    }
                }
                if (!matched_src) {
                    for (req.globs) |raw_rule| {
                        const trimmed = std.mem.trim(u8, raw_rule, " \t");
                        if (trimmed.len == 0 or trimmed[0] == '!') continue;
                        var it = std.mem.splitScalar(u8, trimmed, ',');
                        while (it.next()) |part| {
                            if (JobRunner.matchesProjectScopeToken(src.id, src.name, part)) {
                                matched_src = true;
                                break;
                            }
                        }
                        if (matched_src) break;
                    }
                }
                if (!matched_src) continue;
            }

            if (!runner.sourceMatchesProjectFilters(src.id, src.name)) continue;

            const trimmed_src_tf = std.mem.trim(u8, src.time_format, " \t\r\n");
            const src_task_time_mode: time_parser.TimeMode = if (time_mode == .source) blk_mode: {
                if (trimmed_src_tf.len > 0) break :blk_mode .content;
                break :blk_mode .mtime;
            } else time_mode;

            const src_line_parser: *const time_parser.CompiledTimeParser = blk_slp: {
                if (query_line_parser) |qp| break :blk_slp qp;
                if (has_time_window and src_task_time_mode != .mtime) {
                    if (trimmed_src_tf.len > 0) {
                        try time_format_sig_buf.append(job_arena, '|');
                        try time_format_sig_buf.appendSlice(job_arena, src.id);
                        try time_format_sig_buf.append(job_arena, '=');
                        try time_format_sig_buf.appendSlice(job_arena, trimmed_src_tf);

                        if (std.ascii.eqlIgnoreCase(trimmed_src_tf, "auto")) {
                            break :blk_slp default_auto_parser;
                        }

                        for (time_parsers_pool.items) |entry| {
                            if (std.mem.eql(u8, entry.key, trimmed_src_tf)) {
                                break :blk_slp entry.ptr;
                            }
                        }
                        var sp_err: ?[]const u8 = null;
                        const p = try gpa.create(time_parser.CompiledTimeParser);
                        p.* = .{};
                        var ownership_transferred = false;
                        defer if (!ownership_transferred) gpa.destroy(p);
                        if (p.initInPlace(gpa, job_arena, trimmed_src_tf, &sp_err)) |_| {
                            const key_copy = try job_arena.dupe(u8, trimmed_src_tf);
                            try time_parsers_pool.append(gpa, .{ .key = key_copy, .ptr = p });
                            ownership_transferred = true;
                            break :blk_slp p;
                        } else |_| {
                            break :blk_slp default_auto_parser;
                        }
                    } else if (time_mode == .source and src_task_time_mode == .content) {
                        try time_format_sig_buf.append(job_arena, '|');
                        try time_format_sig_buf.appendSlice(job_arena, src.id);
                        try time_format_sig_buf.appendSlice(job_arena, "=auto");
                        break :blk_slp default_auto_parser;
                    }
                }
                break :blk_slp default_auto_parser;
            };

            runner.visited_dir_ids.clearRetainingCapacity();
            runner.visited_file_ids.clearRetainingCapacity();

            if (std.mem.eql(u8, src.kind, "docker")) {
                const listed = reg.listDockerFreshForSearchAlloc(job_arena, io, src.path) catch continue;
                const allow_docker_time_pushdown = (query_line_parser == null) and
                    (src_task_time_mode != .mtime) and
                    (trimmed_src_tf.len == 0 or std.ascii.eqlIgnoreCase(trimmed_src_tf, "auto"));
                const now_i96: i96 = @intCast(time_parser.currentUnixNano(io));
                for (listed.containers) |c| {
                    if (runner.shouldStop()) break;
                    if (runner.types_include.len > 0 or runner.types_exclude.len > 0) {
                        const synthetic_log_name = try std.fmt.allocPrint(job_arena, "{s}.log", .{c.display_name});
                        if (!libwebgrep.walk_types.matchesWithTable(
                            runner.custom_types_table,
                            runner.types_include,
                            runner.types_exclude,
                            synthetic_log_name,
                        )) continue;
                    }

                    const virtual_rel = if (src.name.len > 0)
                        try std.fmt.allocPrint(job_arena, "{s}/{s}", .{ src.name, c.display_name })
                    else
                        try job_arena.dupe(u8, c.display_name);

                    if (!runner.fileMatchesPathGlobs(virtual_rel, c.display_name)) continue;

                    const eff_mtime_ns: i96 = if (c.running) @max(c.created_ns, now_i96) else c.created_ns;
                    if ((runner.time_start_ns > 0 or runner.time_end_ns > 0) and src_task_time_mode == .mtime and eff_mtime_ns > 0) {
                        const mtime_u64: u64 = @intCast(@max(0, eff_mtime_ns));
                        if ((runner.time_start_ns > 0 and mtime_u64 < runner.time_start_ns) or
                            (runner.time_end_ns > 0 and mtime_u64 > runner.time_end_ns))
                        {
                            _ = runner.files_searched.fetchAdd(1, .monotonic);
                            continue;
                        }
                    }

                    runner.has_docker_tasks = true;
                    try runner.file_tasks.append(job_arena, .{
                        .open_sub_path = c.display_name,
                        .rel_path = virtual_rel,
                        .base_name = c.display_name,
                        .source_id = src.id,
                        .source_name = src.name,
                        .docker_transport = listed.transport,
                        .docker_container_id = c.id,
                        .docker_allow_time_pushdown = allow_docker_time_pushdown,
                        .effective_contains = base_literal_contains,
                        .effective_excludes = base_literal_excludes,
                        .line_time_parser = src_line_parser,
                        .task_time_mode = src_task_time_mode,
                        .mtime_ns = eff_mtime_ns,
                    });
                }
                continue;
            }

            if (!std.mem.eql(u8, src.kind, "file")) {
                if (std.Io.Dir.cwd().openDir(io, src.path, .{ .iterate = true })) |opened_dir| {
                    var d = opened_dir;
                    defer d.close(io);
                    try runner.walkDirectoryForSource(
                        d,
                        src.path,
                        src.id,
                        src.name,
                        base_literal_contains,
                        base_literal_excludes,
                        "",
                        null,
                        src_line_parser,
                        src_task_time_mode,
                    );
                    continue;
                } else |_| {}
            }

            // Single-file data source (`kind == "file"` or path pointing directly to a file)
            const parent_dir_path = std.fs.path.dirname(src.path) orelse ".";
            const base_name = std.fs.path.basename(src.path);
            if (base_name.len > 0 and runner.fileMatchesSourceFilters(src.id, src.name, base_name)) {
                const st = std.Io.Dir.cwd().statFile(io, src.path, .{}) catch continue;
                const virtual_rel = if (src.name.len > 0)
                    try std.fmt.allocPrint(job_arena, "{s}/{s}", .{ src.name, base_name })
                else
                    base_name;
                try runner.enqueueTask(
                    parent_dir_path,
                    base_name,
                    virtual_rel,
                    base_name,
                    src.id,
                    src.name,
                    base_literal_contains,
                    base_literal_excludes,
                    st.mtime.nanoseconds,
                    st.size,
                    st.inode,
                    src_line_parser,
                    src_task_time_mode,
                );
            }
        }
    } else if (req.paths.len > 0) {
        const fallback_tp = query_line_parser orelse default_auto_parser;
        const fallback_mode: time_parser.TimeMode = if (time_mode == .source) .mtime else time_mode;
        for (req.paths) |raw_p| {
            if (runner.shouldStop()) break;
            const clean_p = file_api.sanitizeRelPath(raw_p) catch continue;
            if (clean_p.len == 0) {
                try runner.walkDirectoryForSource(root_dir, null, "", "", base_literal_contains, base_literal_excludes, "", null, fallback_tp, fallback_mode);
                continue;
            }
            if (root_dir.openDir(io, clean_p, .{ .iterate = true })) |opened_dir| {
                var sub_dir = opened_dir;
                defer sub_dir.close(io);
                try runner.walkDirectoryForSource(sub_dir, null, "", "", base_literal_contains, base_literal_excludes, clean_p, null, fallback_tp, fallback_mode);
            } else |_| {
                const base = std.fs.path.basename(clean_p);
                if (!runner.fileMatchesSourceFilters("", "", base)) continue;
                const st = root_dir.statFile(io, clean_p, .{}) catch continue;
                try runner.enqueueTask(null, clean_p, clean_p, base, "", "", base_literal_contains, base_literal_excludes, st.mtime.nanoseconds, st.size, st.inode, fallback_tp, fallback_mode);
            }
        }
    } else {
        const fallback_tp = query_line_parser orelse default_auto_parser;
        const fallback_mode: time_parser.TimeMode = if (time_mode == .source) .mtime else time_mode;
        try runner.walkDirectoryForSource(root_dir, null, "", "", base_literal_contains, base_literal_excludes, "", null, fallback_tp, fallback_mode);
    }

    runner.time_format_sig = time_format_sig_buf.items;

    if (!cancel_flag.load(.acquire)) {
        runner.runParallelWorkers();
    }

    if (cancel_flag.load(.acquire)) return;

    const elapsed_ns = start_ts.untilNow(io, .awake).toNanoseconds();
    const elapsed_ms: f64 = @as(f64, @floatFromInt(@max(elapsed_ns, 0))) / 1_000_000.0;
    const limit_hit: []const u8 = if (runner.hit_max_results.load(.acquire))
        "max_results"
    else
        "none";

    // Commit L1/L2 cache BEFORE sending DoneFrame so any immediate follow-up query
    // (even on a separate WebSocket connection) is guaranteed to hit L1/L2.
    runner.commitCacheAfterDone();

    const site_search_count: u64 = if (registry) |reg| reg.recordSearch(io) else 0;

    const done_json = try file_api.stringifyAlloc(gpa, DoneFrame{
        .id = req.id,
        .elapsedMs = elapsed_ms,
        .filesSearched = runner.files_searched.load(.acquire),
        .filesMatched = runner.files_matched.load(.acquire),
        .totalMatches = runner.total_matches.load(.acquire),
        .matchedLines = runner.matched_lines.load(.acquire),
        .bytesSearched = runner.bytes_searched.load(.acquire),
        .limitHit = limit_hit,
        .searchCount = site_search_count,
        .cacheHit = runner.cache_hit_tier,
        .nearbyLines = if (runner.nearby_used) req.nearbyLines else 0,
    });
    defer gpa.free(done_json);
    try sender.send(done_json);
}

fn sendError(gpa: std.mem.Allocator, sender: FrameSender, id: u64, msg: []const u8) !void {
    const err_json = try file_api.stringifyAlloc(gpa, ErrorFrame{
        .id = id,
        .message = msg,
    });
    defer gpa.free(err_json);
    try sender.send(err_json);
}

const DirEntryItem = struct {
    name: []const u8,
    is_dir: bool,
    is_symlink: bool = false,

    pub fn lessThan(_: void, a: DirEntryItem, b: DirEntryItem) bool {
        if (a.is_dir != b.is_dir) return !a.is_dir; // search files in dir first, then recurse subdirs
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

const FileTask = struct {
    pub const COLOSSAL_FILE_THRESHOLD: u64 = 256 * 1024 * 1024;

    parent_dir_path: ?[]const u8 = null,
    open_sub_path: []const u8,
    rel_path: []const u8,
    base_name: []const u8,
    source_id: []const u8 = "",
    source_name: []const u8 = "",
    docker_transport: ?docker_logs.Transport = null,
    docker_container_id: []const u8 = "",
    docker_allow_time_pushdown: bool = false,
    archive_format: ?libwebgrep.ArchiveFormat = null,
    effective_contains: []const []const u8 = &.{},
    effective_excludes: []const []const u8 = &.{},
    line_time_parser: *const time_parser.CompiledTimeParser,
    task_time_mode: time_parser.TimeMode = .auto,
    mtime_ns: i96 = 0,
    file_size: u64 = 0,
    inode: std.Io.File.INode = 0,
    access_heat: u64 = 0,
    base_heat: u64 = 100,
    heat_score: u64 = 100,
    soft_quota: u64 = 0,
    emitted_in_file: u64 = 0,
    resume_after_line: u64 = 0,
    paused_result: ?libwebgrep.Result = null,
    phase_bytes: u64 = 0,
    paused_at_soft_quota: bool = false,
    counted_file_searched: bool = false,
    counted_file_matched: bool = false,

    pub fn isDocker(self: FileTask) bool {
        return self.docker_transport != null;
    }

    pub fn isColossal(self: FileTask) bool {
        return self.file_size > COLOSSAL_FILE_THRESHOLD;
    }

    pub fn hotterThan(_: void, a: FileTask, b: FileTask) bool {
        const a_col = a.isColossal();
        const b_col = b.isColossal();
        if (a_col != b_col) return !a_col;
        if (a_col and b_col and a.file_size != b.file_size) return a.file_size < b.file_size;
        if (a.heat_score != b.heat_score) return a.heat_score > b.heat_score;
        if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
        return std.mem.order(u8, a.rel_path, b.rel_path) == .lt;
    }
};

const TimeParserPoolEntry = struct {
    key: []const u8,
    ptr: *time_parser.CompiledTimeParser,
};

const JobRunner = struct {
    gpa: std.mem.Allocator,
    job_arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    registry: ?*source_registry.SourceRegistry = null,
    req: SearchRequest,
    matcher: *const MatcherUnion,
    compiled_globs: []const libwebgrep.walk_glob.Glob,
    expanded_file_globs: []const []const u8 = &.{},
    types_include: []const []const u8 = &.{},
    types_exclude: []const []const u8 = &.{},
    custom_types_table: []const libwebgrep.walk_types.Type = &custom_file_types,
    contains_regexes: []const libwebgrep.Regex = &.{},
    excludes_regexes: []const libwebgrep.Regex = &.{},
    swapped_primary_regex_first: bool = false,
    swapped_primary_finder: ?libwebgrep.Finder = null,
    cancel_flag: *const std.atomic.Value(bool),
    sender: FrameSender,
    time_start_ns: u64 = 0,
    time_end_ns: u64 = 0,
    time_mode: time_parser.TimeMode = .auto,
    tz_offset_min: i16 = 0,
    time_format_sig: []const u8 = "",
    default_line_time_parser: *const time_parser.CompiledTimeParser,
    is_empty_text_time_browse: bool = false,
    has_docker_tasks: bool = false,

    visited_dir_ids: std.AutoHashMapUnmanaged(libwebgrep.walk_file_id.Id, void) = .empty,
    visited_file_ids: std.AutoHashMapUnmanaged(libwebgrep.walk_file_id.Id, void) = .empty,

    file_tasks: std.ArrayList(FileTask) = .empty,
    active_task_indices: std.ArrayList(usize) = .empty,
    next_task_idx: std.atomic.Value(usize) = .init(0),
    active_worker_count: u32 = 1,

    batches_flushed: std.atomic.Value(u64) = .init(0),
    files_searched: std.atomic.Value(u64) = .init(0),
    files_matched: std.atomic.Value(u64) = .init(0),
    total_matches: std.atomic.Value(u64) = .init(0),
    matched_lines: std.atomic.Value(u64) = .init(0),
    bytes_searched: std.atomic.Value(u64) = .init(0),
    hit_max_results: std.atomic.Value(bool) = .init(false),
    send_failed: std.atomic.Value(bool) = .init(false),

    progress_mutex: std.Io.Mutex = .init,
    last_progress_ts: std.Io.Timestamp,

    cache_hit_tier: []const u8 = "none",
    nearby_used: bool = false,
    pruned_by_negative_cache: std.atomic.Value(bool) = .init(false),
    had_non_exact_line: std.atomic.Value(bool) = .init(false),
    had_scan_error: std.atomic.Value(bool) = .init(false),
    collected_hits_mutex: std.Io.Mutex = .init,
    collected_hits: std.ArrayList(HitItem) = .empty,
    collected_hits_overflow: bool = false,
    should_commit_cache: bool = false,
    pending_exact_hash: u64 = 0,
    pending_tasks_fingerprint: u64 = 0,
    pending_heat_epoch: u64 = 0,

    fn shouldStop(self: *const JobRunner) bool {
        return self.hit_max_results.load(.acquire) or
            self.send_failed.load(.acquire) or
            self.cancel_flag.load(.acquire);
    }

    fn enqueueTask(
        self: *JobRunner,
        parent_dir_path: ?[]const u8,
        open_sub_path: []const u8,
        rel_path: []const u8,
        base_name: []const u8,
        source_id: []const u8,
        source_name: []const u8,
        effective_contains: []const []const u8,
        effective_excludes: []const []const u8,
        mtime_ns: i96,
        file_size: u64,
        inode: std.Io.File.INode,
        line_tp: *const time_parser.CompiledTimeParser,
        task_time_mode: time_parser.TimeMode,
    ) !void {
        const archive_fmt = detectArchiveFormat(base_name);
        if (archive_fmt == null) {
            if (!self.fileMatchesPathGlobs(rel_path, base_name)) return;
        } else {
            if (!self.archiveContainerAllowedByPathGlobs(rel_path, base_name)) return;
        }
        // In explicit `mtime` mode (or sources using file modified time), O(1) prune non-matching
        // files/archives before allocating tasks while keeping `files_searched` accurate.
        if ((self.time_start_ns > 0 or self.time_end_ns > 0) and task_time_mode == .mtime and mtime_ns > 0) {
            const mtime_u64: u64 = @intCast(@max(0, mtime_ns));
            if ((self.time_start_ns > 0 and mtime_u64 < self.time_start_ns) or
                (self.time_end_ns > 0 and mtime_u64 > self.time_end_ns))
            {
                _ = self.files_searched.fetchAdd(1, .monotonic);
                return;
            }
        }
        const parent_copy = if (parent_dir_path) |p| try self.job_arena.dupe(u8, p) else null;
        const sub_copy = try self.job_arena.dupe(u8, open_sub_path);
        const rel_copy = if (std.mem.eql(u8, open_sub_path, rel_path))
            sub_copy
        else
            try self.job_arena.dupe(u8, rel_path);
        const base_copy = try self.job_arena.dupe(u8, base_name);
        try self.file_tasks.append(self.job_arena, .{
            .parent_dir_path = parent_copy,
            .open_sub_path = sub_copy,
            .rel_path = rel_copy,
            .base_name = base_copy,
            .source_id = source_id,
            .source_name = source_name,
            .archive_format = archive_fmt,
            .effective_contains = effective_contains,
            .effective_excludes = effective_excludes,
            .line_time_parser = line_tp,
            .task_time_mode = task_time_mode,
            .mtime_ns = mtime_ns,
            .file_size = file_size,
            .inode = inode,
            .access_heat = 0,
        });
    }

    fn hasGlobMetachar(s: []const u8) bool {
        for (s) |c| {
            if (c == '*' or c == '?' or c == '[' or c == '{') return true;
        }
        return false;
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    fn activeFileGlobs(self: *const JobRunner) []const []const u8 {
        return if (self.expanded_file_globs.len > 0) self.expanded_file_globs else self.req.fileGlobs;
    }

    /// Applies `req.fileGlobs` (`@*.rs`, `@src/`, `-@*_test.go`) to a candidate file.
    /// Positive patterns are OR-ed (at least one must match when any exist); `!` negatives always exclude.
    fn fileMatchesPathGlobs(self: *const JobRunner, rel_path: []const u8, base_name: []const u8) bool {
        const globs = self.activeFileGlobs();
        if (globs.len == 0) return true;
        var has_positive = false;
        var positive_hit = false;
        for (globs) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t");
            const is_neg = trimmed.len > 0 and trimmed[0] == '!';
            const body = if (is_neg) trimmed[1..] else trimmed;
            if (body.len == 0) continue;
            const hit = matchesPathPattern(rel_path, base_name, body);
            if (is_neg) {
                if (hit) return false;
            } else {
                has_positive = true;
                if (hit) positive_hit = true;
            }
        }
        return !has_positive or positive_hit;
    }

    fn archiveContainerAllowedByPathGlobs(self: *const JobRunner, rel_path: []const u8, base_name: []const u8) bool {
        const globs = self.activeFileGlobs();
        if (globs.len == 0) return true;
        for (globs) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len > 1 and trimmed[0] == '!') {
                const body = trimmed[1..];
                if (matchesPathPattern(rel_path, base_name, body)) return false;
            }
        }
        return true;
    }

    fn archiveEntryMatchesPathGlobs(
        self: *const JobRunner,
        archive_rel_path: []const u8,
        archive_base_name: []const u8,
        entry_path: []const u8,
    ) bool {
        const globs = self.activeFileGlobs();
        if (globs.len == 0) return true;
        const entry_base = std.fs.path.basename(entry_path);
        var has_positive = false;
        var positive_hit = false;
        for (globs) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t");
            const is_neg = trimmed.len > 0 and trimmed[0] == '!';
            const body = if (is_neg) trimmed[1..] else trimmed;
            if (body.len == 0) continue;
            const hit = matchesPathPattern(archive_rel_path, archive_base_name, body) or
                matchesPathPattern(entry_path, entry_base, body);
            if (is_neg) {
                if (hit) return false;
            } else {
                has_positive = true;
                if (hit) positive_hit = true;
            }
        }
        return !has_positive or positive_hit;
    }

    fn archiveEntryGlobs(
        self: *const JobRunner,
        archive_rel_path: []const u8,
        archive_base_name: []const u8,
    ) []const []const u8 {
        const globs = self.activeFileGlobs();
        if (globs.len == 0) return &.{};
        for (globs) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len == 0) continue;
            const is_neg = trimmed[0] == '!';
            const body = if (is_neg) trimmed[1..] else trimmed;
            if (!is_neg and matchesPathPattern(archive_rel_path, archive_base_name, body)) {
                return &.{};
            }
            if (!hasGlobMetachar(body) or std.mem.indexOfScalar(u8, body, '/') != null) {
                return &.{};
            }
        }
        return globs;
    }

    /// Matches one `@` file/path pattern (case-insensitive):
    /// - no glob metacharacters (`@src/`)  → substring of the relative path;
    /// - no `/` (`@*.rs`, `@*_test.go`)    → glob against the file name;
    /// - with `/` (`@src/*.rs`)            → glob against the relative path at any depth, since users write
    ///   paths relative to the project rather than to the index root.
    fn matchesPathPattern(rel_path: []const u8, base_name: []const u8, pattern: []const u8) bool {
        const clean = std.mem.trim(u8, pattern, " \t");
        if (clean.len == 0) return true;
        if (!hasGlobMetachar(clean)) return containsIgnoreCase(rel_path, clean);

        const glob_lib = libwebgrep.walk_glob;
        if (std.mem.indexOfScalar(u8, clean, '/') == null) {
            return glob_lib.matches(glob_lib.classifyWithCase(clean, true), rel_path, base_name, false);
        }
        var buf: [512]u8 = undefined;
        const rooted = std.mem.trimStart(u8, clean, "/");
        const anywhere = if (std.mem.startsWith(u8, rooted, "**/"))
            rooted
        else
            std.fmt.bufPrint(&buf, "**/{s}", .{rooted}) catch return false;
        var g = glob_lib.classifyWithCase(anywhere, true);
        g.anchored = true;
        return glob_lib.matches(g, rel_path, base_name, false);
    }

    /// Checks whether all '-' or '/' separated segments of `expr` appear in order inside `haystack`.
    fn matchesOrderedPathSegments(haystack: []const u8, expr: []const u8) bool {
        var pos: usize = 0;
        var start: usize = 0;
        var seg_count: usize = 0;
        var i: usize = 0;
        while (i <= expr.len) : (i += 1) {
            if (i == expr.len or expr[i] == '-' or expr[i] == '/') {
                const seg = expr[start..i];
                start = i + 1;
                if (seg.len == 0) continue;
                seg_count += 1;

                var found_at: ?usize = null;
                if (haystack.len >= pos + seg.len) {
                    var k: usize = pos;
                    while (k <= haystack.len - needleLen(seg)) : (k += 1) {
                        if (std.ascii.eqlIgnoreCase(haystack[k .. k + seg.len], seg)) {
                            found_at = k;
                            break;
                        }
                    }
                }
                if (found_at) |idx| {
                    pos = idx + seg.len;
                } else {
                    return false;
                }
            }
        }
        return seg_count > 0;
    }

    inline fn needleLen(s: []const u8) usize {
        return s.len;
    }

    /// Project-only `@` matcher: matches a project by its `name` or UUID `id` (case-insensitive).
    pub fn matchesProjectScopeToken(
        src_id: []const u8,
        src_name: []const u8,
        token: []const u8,
    ) bool {
        const clean = std.mem.trim(u8, token, " \t@/");
        if (clean.len == 0) return true;
        if (src_name.len > 0 and std.ascii.eqlIgnoreCase(clean, src_name)) return true;
        if (src_id.len > 0 and std.ascii.eqlIgnoreCase(clean, src_id)) return true;
        return false;
    }

    fn sourceMatchesProjectFilters(
        self: *const JobRunner,
        src_id: []const u8,
        src_name: []const u8,
    ) bool {
        if (src_id.len == 0 and src_name.len == 0) return true;

        // Evaluate each @project filter in req.globs with progressive AND semantics
        for (self.req.globs) |raw_rule| {
            const trimmed = std.mem.trim(u8, raw_rule, " \t");
            if (trimmed.len == 0) continue;

            const is_neg = trimmed[0] == '!';
            const body = if (is_neg) trimmed[1..] else trimmed;
            if (body.len == 0) continue;

            // Comma-separated items inside a single @projA,projB token act as OR
            var matched_any = false;
            var it = std.mem.splitScalar(u8, body, ',');
            while (it.next()) |part| {
                if (matchesProjectScopeToken(src_id, src_name, part)) {
                    matched_any = true;
                    break;
                }
            }

            if (is_neg) {
                if (matched_any) return false;
            } else {
                if (!matched_any) return false;
            }
        }
        return true;
    }

    fn fileMatchesSourceFilters(
        self: *const JobRunner,
        src_id: []const u8,
        src_name: []const u8,
        base_name: []const u8,
    ) bool {
        const is_archive = (detectArchiveFormat(base_name) != null);
        if (!is_archive and (self.types_include.len > 0 or self.types_exclude.len > 0)) {
            if (!libwebgrep.walk_types.matchesWithTable(
                self.custom_types_table,
                self.types_include,
                self.types_exclude,
                base_name,
            )) return false;
        }
        return self.sourceMatchesProjectFilters(src_id, src_name);
    }

    fn readDirFileBounded(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        sub_path: []const u8,
        max_bytes: usize,
    ) ?[]u8 {
        var f = dir.openFile(io, sub_path, .{ .allow_directory = false }) catch return null;
        defer f.close(io);
        var rbuf: [4096]u8 = undefined;
        var f_reader = f.reader(io, &rbuf);
        return f_reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch null;
    }

    fn loadDirIgnoreSet(
        self: *JobRunner,
        dir: std.Io.Dir,
        rel_dir: []const u8,
        parent_ignore: ?*const libwebgrep.walk_ignore.Set,
    ) ?*const libwebgrep.walk_ignore.Set {
        if (!self.req.respectIgnore) return null;
        const max_ig_bytes: usize = 1024 * 1024;
        const git_exclude_bytes: ?[]u8 = if (rel_dir.len == 0)
            readDirFileBounded(self.gpa, self.io, dir, ".git/info/exclude", max_ig_bytes)
        else
            null;
        defer if (git_exclude_bytes) |b| self.gpa.free(b);

        const gitignore_bytes = readDirFileBounded(self.gpa, self.io, dir, ".gitignore", max_ig_bytes);
        defer if (gitignore_bytes) |b| self.gpa.free(b);

        const ignore_bytes = readDirFileBounded(self.gpa, self.io, dir, ".ignore", max_ig_bytes);
        defer if (ignore_bytes) |b| self.gpa.free(b);

        const rgignore_bytes = readDirFileBounded(self.gpa, self.io, dir, ".rgignore", max_ig_bytes);
        defer if (rgignore_bytes) |b| self.gpa.free(b);

        if (git_exclude_bytes == null and gitignore_bytes == null and ignore_bytes == null and rgignore_bytes == null) {
            return parent_ignore;
        }

        var ig_list: std.ArrayList(libwebgrep.walk_glob.Glob) = .empty;

        libwebgrep.walk_ignore.parseLayerInto(
            self.job_arena,
            .{
                .git_exclude = git_exclude_bytes,
                .gitignore = gitignore_bytes,
                .ignore = ignore_bytes,
                .rgignore = rgignore_bytes,
            },
            .{
                .vcs = true,
                .dot = true,
                .exclude = (rel_dir.len == 0),
                .max_rules = EngineLimits.max_glob_rules,
                .max_rule_len = EngineLimits.max_glob_rule_len,
                .max_brace_depth = EngineLimits.max_glob_brace_depth,
            },
            &ig_list,
        ) catch return parent_ignore;

        if (ig_list.items.len == 0) return parent_ignore;

        const set_ptr = self.job_arena.create(libwebgrep.walk_ignore.Set) catch return parent_ignore;
        set_ptr.* = libwebgrep.walk_ignore.build(
            self.job_arena,
            self.gpa,
            parent_ignore,
            rel_dir.len,
            &.{},
            ig_list.items,
        ) catch return parent_ignore;
        return set_ptr;
    }

    fn walkDirectoryForSource(
        self: *JobRunner,
        dir: std.Io.Dir,
        parent_root_override: ?[]const u8,
        src_id: []const u8,
        src_name: []const u8,
        effective_contains: []const []const u8,
        effective_excludes: []const []const u8,
        rel_dir: []const u8,
        parent_ignore: ?*const libwebgrep.walk_ignore.Set,
        line_tp: *const time_parser.CompiledTimeParser,
        task_time_mode: time_parser.TimeMode,
    ) !void {
        if (self.shouldStop()) return;

        const dir_fid: ?libwebgrep.walk_file_id.Id = libwebgrep.walk_file_id.fromDir(dir) catch null;
        if (dir_fid) |fid| {
            if (fid.ino != 0) {
                const gop = try self.visited_dir_ids.getOrPut(self.job_arena, fid);
                if (gop.found_existing) return;
            }
        }

        const active_ignore = self.loadDirIgnoreSet(dir, rel_dir, parent_ignore);
        var ignore_scratch: [4096]u8 = undefined;

        var dir_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer dir_arena_state.deinit();
        const dir_arena = dir_arena_state.allocator();

        const dir_stat = dir.stat(self.io) catch null;
        const dir_cache_key: []const u8 = if (self.registry != null and dir_stat != null) blk: {
            const root_tag = parent_root_override orelse src_id;
            if (rel_dir.len == 0) break :blk root_tag;
            break :blk try std.fmt.allocPrint(dir_arena, "{s}/{s}", .{ root_tag, rel_dir });
        } else "";

        var entries: std.ArrayList(DirEntryItem) = .empty;
        var loaded_from_dir_cache = false;

        if (self.registry) |reg| {
            if (dir_stat) |dst| {
                if (reg.search_cache.lookupDirTopology(
                    self.io,
                    dir_arena,
                    dir_cache_key,
                    self.req.hidden,
                    dst.mtime.nanoseconds,
                    dst.inode,
                )) |cached_entries| {
                    try entries.ensureTotalCapacity(dir_arena, cached_entries.len);
                    for (cached_entries) |ce| {
                        entries.appendAssumeCapacity(.{
                            .name = ce.name,
                            .is_dir = ce.is_dir,
                            .is_symlink = false,
                        });
                    }
                    loaded_from_dir_cache = true;
                }
            }
        }

        if (!loaded_from_dir_cache) {
            var scratch: [libwebgrep.walk_list.buffer_len]u8 align(@alignOf(usize)) = undefined;
            var lister = libwebgrep.walk_list.Lister.init(dir, &scratch);
            var batch: [128]std.Io.Dir.Entry = undefined;
            var has_symlink = false;

            while (true) {
                if (self.shouldStop()) return;
                const count = lister.fill(self.io, &batch) catch break;
                if (count == 0) break;

                for (batch[0..count]) |item| {
                    if (item.name.len == 0) continue;
                    if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
                    if (file_api.isAlwaysSkippedDir(item.name)) continue;
                    if (!self.req.hidden and item.name[0] == '.') continue;

                    var is_dir = item.kind == .directory;
                    var is_file = item.kind == .file;
                    var is_symlink = false;
                    if (item.kind == .sym_link or item.kind == .unknown) {
                        has_symlink = true;
                        is_symlink = (item.kind == .sym_link);
                        const st = dir.statFile(self.io, item.name, .{}) catch continue;
                        is_dir = st.kind == .directory;
                        is_file = st.kind == .file;
                    }
                    if (!is_dir and !is_file) continue;

                    const name_copy = try dir_arena.dupe(u8, item.name);
                    try entries.append(dir_arena, .{
                        .name = name_copy,
                        .is_dir = is_dir,
                        .is_symlink = is_symlink,
                    });
                }
            }

            std.mem.sort(DirEntryItem, entries.items, {}, DirEntryItem.lessThan);

            if (!has_symlink) {
                if (self.registry) |reg| {
                    if (dir_stat) |dst| {
                        const cache_slice = dir_arena.alloc(search_cache.CachedDirEntry, entries.items.len) catch null;
                        if (cache_slice) |cs| {
                            for (entries.items, 0..) |e, i| {
                                cs[i] = .{ .name = e.name, .is_dir = e.is_dir };
                            }
                            reg.search_cache.storeDirTopology(
                                self.gpa,
                                self.io,
                                dir_cache_key,
                                self.req.hidden,
                                dst.mtime.nanoseconds,
                                dst.inode,
                                cs,
                            );
                        }
                    }
                }
            }
        }

        for (entries.items) |entry| {
            if (self.shouldStop()) return;

            const child_rel = if (rel_dir.len == 0)
                entry.name
            else
                try std.fmt.allocPrint(dir_arena, "{s}/{s}", .{ rel_dir, entry.name });

            if (active_ignore) |ig_set| {
                if (libwebgrep.walk_ignore.isIgnored(ig_set, child_rel, entry.is_dir, &ignore_scratch)) {
                    continue;
                }
            }

            if (entry.is_dir) {
                var sub_dir = dir.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
                defer sub_dir.close(self.io);

                try self.walkDirectoryForSource(
                    sub_dir,
                    parent_root_override,
                    src_id,
                    src_name,
                    effective_contains,
                    effective_excludes,
                    child_rel,
                    active_ignore,
                    line_tp,
                    task_time_mode,
                );
            } else {
                const virtual_rel = if (src_name.len > 0)
                    try std.fmt.allocPrint(dir_arena, "{s}/{s}", .{ src_name, child_rel })
                else
                    child_rel;

                if (!self.fileMatchesSourceFilters(src_id, src_name, entry.name)) continue;

                const st = dir.statFile(self.io, entry.name, .{}) catch continue;

                const file_fid: ?libwebgrep.walk_file_id.Id = if (entry.is_symlink) blk_sym: {
                    var sym_f = dir.openFile(self.io, entry.name, .{ .allow_directory = false }) catch break :blk_sym null;
                    defer sym_f.close(self.io);
                    break :blk_sym libwebgrep.walk_file_id.fromFile(self.io, sym_f) catch null;
                } else if (st.inode != 0)
                    libwebgrep.walk_file_id.Id{
                        .dev = if (dir_fid) |df| df.dev else 0,
                        .ino = @intCast(st.inode),
                    }
                else
                    null;

                if (file_fid) |ffid| {
                    if (ffid.ino != 0) {
                        const fgop = try self.visited_file_ids.getOrPut(self.job_arena, ffid);
                        if (fgop.found_existing) continue;
                    }
                }

                try self.enqueueTask(
                    parent_root_override,
                    child_rel,
                    virtual_rel,
                    entry.name,
                    src_id,
                    src_name,
                    effective_contains,
                    effective_excludes,
                    st.mtime.nanoseconds,
                    st.size,
                    st.inode,
                    line_tp,
                    task_time_mode,
                );
            }
        }
    }

    /// Computes initial file heat scores (Recency mtime + User Access Heat), sorts hotter files first,
    /// and assigns Phase 1 heat-proportional soft quotas (`Water-Filling` pass 1).
    fn prepareHeatAndQuotas(self: *JobRunner) void {
        const total_files = self.file_tasks.items.len;
        if (total_files == 0) return;

        if (total_files == 1) {
            self.file_tasks.items[0].soft_quota = 0; // Single file gets 100% of maxResults directly
            return;
        }

        var min_mtime: i96 = std.math.maxInt(i96);
        var max_mtime: i96 = std.math.minInt(i96);
        var has_mtime = false;

        for (self.file_tasks.items) |t| {
            if (t.mtime_ns > 0) {
                has_mtime = true;
                if (t.mtime_ns < min_mtime) min_mtime = t.mtime_ns;
                if (t.mtime_ns > max_mtime) max_mtime = t.mtime_ns;
            }
        }

        for (self.file_tasks.items) |*t| {
            t.access_heat = if (self.registry) |reg|
                reg.getFileHeat(self.io, t.rel_path)
            else
                0;
            var recency_heat: u64 = 150;
            if (has_mtime and max_mtime > min_mtime and t.mtime_ns >= min_mtime) {
                const span: u128 = @intCast(max_mtime - min_mtime);
                const offset: u128 = @intCast(t.mtime_ns - min_mtime);
                recency_heat = @intCast((offset * 300) / span);
            }
            const base = 100 + recency_heat + @min(@as(u64, 2000), t.access_heat);
            t.base_heat = base;
            t.heat_score = base;
        }

        // Priority scheduling: hotter files are placed at the front of the queue so they are scanned first
        std.mem.sort(FileTask, self.file_tasks.items, {}, FileTask.hotterThan);

        const max_res = self.req.maxResults;
        if (max_res == 0) {
            for (self.file_tasks.items) |*t| t.soft_quota = 0;
            return;
        }

        var total_heat: u64 = 0;
        for (self.file_tasks.items) |t| {
            total_heat +|= t.heat_score;
        }
        if (total_heat == 0) total_heat = 1;

        const n_u64: u64 = @intCast(total_files);
        const min_floor: u64 = @min(max_res, @max(@as(u64, 1), max_res / @max(@as(u64, 1), n_u64 * 2)));

        for (self.file_tasks.items) |*t| {
            const raw_share = (max_res * t.heat_score) / total_heat;
            t.soft_quota = @max(min_floor, @min(max_res, raw_share));
        }
    }

    fn runWaterFillingForSubset(self: *JobRunner, subset_indices: []const usize, use_soft_quota: bool) void {
        if (subset_indices.len == 0 or self.shouldStop()) return;

        const max_res = self.req.maxResults;
        const init_cur = self.total_matches.load(.acquire);
        if (max_res > 0 and init_cur >= max_res) return;

        self.active_task_indices.clearRetainingCapacity();
        for (subset_indices) |idx| {
            self.active_task_indices.appendAssumeCapacity(idx);
        }

        if (!use_soft_quota or max_res == 0 or subset_indices.len == 1) {
            for (subset_indices) |idx| {
                self.file_tasks.items[idx].soft_quota = 0;
            }
        } else {
            const remaining_init = max_res - init_cur;
            var subset_heat: u64 = 0;
            for (subset_indices) |idx| {
                subset_heat +|= self.file_tasks.items[idx].heat_score;
            }
            if (subset_heat == 0) subset_heat = 1;
            const sub_n: u64 = @intCast(subset_indices.len);
            const min_floor: u64 = @min(remaining_init, @max(@as(u64, 1), remaining_init / @max(@as(u64, 1), sub_n * 2)));
            for (subset_indices) |idx| {
                var t = &self.file_tasks.items[idx];
                const raw_share = (remaining_init * t.heat_score) / subset_heat;
                t.soft_quota = @max(min_floor, @min(remaining_init, raw_share));
            }
        }

        // Phase 1: Heat-prioritized initial proportional pass across subset candidate files
        self.executeWorkerPass();

        // Phase 2+: Iterative Dynamic Density-Weighted Water-Filling for subset files that hit their soft quota
        while (!self.shouldStop()) {
            const cur_total = self.total_matches.load(.acquire);
            if (max_res > 0 and cur_total >= max_res) break;

            self.active_task_indices.clearRetainingCapacity();
            for (subset_indices) |idx| {
                var t = &self.file_tasks.items[idx];
                if (t.paused_at_soft_quota) {
                    const denom = @max(@as(u64, 4096), t.phase_bytes);
                    const density_heat = @min(@as(u64, 2000), (t.emitted_in_file * 1024 * 1024) / denom);
                    t.heat_score = t.base_heat + density_heat;
                    self.active_task_indices.appendAssumeCapacity(idx);
                }
            }

            const overflow_count = self.active_task_indices.items.len;
            if (overflow_count == 0) break;

            const IndexSortCtx = struct {
                tasks: []const FileTask,
                pub fn lessThan(ctx: @This(), a_idx: usize, b_idx: usize) bool {
                    return FileTask.hotterThan({}, ctx.tasks[a_idx], ctx.tasks[b_idx]);
                }
            };
            std.mem.sort(
                usize,
                self.active_task_indices.items,
                IndexSortCtx{ .tasks = self.file_tasks.items },
                IndexSortCtx.lessThan,
            );

            if (max_res == 0 or overflow_count == 1) {
                for (self.active_task_indices.items) |idx| {
                    self.file_tasks.items[idx].soft_quota = 0;
                }
            } else {
                const remaining = max_res - cur_total;
                var active_heat_sum: u64 = 0;
                for (self.active_task_indices.items) |idx| {
                    active_heat_sum +|= self.file_tasks.items[idx].heat_score;
                }
                if (active_heat_sum == 0) active_heat_sum = 1;

                var allocated: u64 = 0;
                for (self.active_task_indices.items, 0..) |idx, k| {
                    var t = &self.file_tasks.items[idx];
                    const share = if (k + 1 == overflow_count)
                        (if (remaining > allocated) remaining - allocated else 1)
                    else
                        @max(@as(u64, 1), (remaining * t.heat_score) / active_heat_sum);
                    allocated +|= share;
                    t.soft_quota = t.emitted_in_file + share;
                }
            }

            self.executeWorkerPass();
        }
    }

    fn executeWorkerPass(self: *JobRunner) void {
        const active_count = self.active_task_indices.items.len;
        if (active_count == 0 or self.shouldStop()) return;

        self.next_task_idx.store(0, .release);

        const cpu_count = std.Thread.getCpuCount() catch 4;
        const desired_workers = @min(@max(cpu_count, 4), @min(active_count, 8));
        self.active_worker_count = @intCast(@max(desired_workers, 1));

        if (desired_workers <= 1) {
            self.workerThreadMain();
            return;
        }

        var threads: [8]?std.Thread = .{ null, null, null, null, null, null, null, null };
        const spawn_count = desired_workers - 1;
        for (0..spawn_count) |i| {
            threads[i] = std.Thread.spawn(.{}, JobRunner.workerThreadMain, .{self}) catch null;
        }

        self.workerThreadMain();

        for (0..spawn_count) |i| {
            if (threads[i]) |t| t.join();
        }
    }

    fn computeTasksFingerprint(self: *const JobRunner) u64 {
        var acc: u64 = @intCast(self.file_tasks.items.len *% 0x9e3779b97f4a7c15);
        for (self.file_tasks.items) |t| {
            const mtime_u64: u64 = @bitCast(@as(i64, @truncate(t.mtime_ns)));
            const ino_u64: u64 = @intCast(t.inode);
            const seed = mtime_u64 ^ (t.file_size *% 0x517cc1b727220a95) ^ (ino_u64 *% 0x94d049bb133111eb);
            const h = std.hash.Wyhash.hash(seed, t.rel_path);
            acc +%= h ^ (h >> 29);
        }
        return acc;
    }

    fn computeExactQueryHash(self: *const JobRunner, tasks_fingerprint: u64, heat_epoch: u64) u64 {
        var hasher = std.hash.Wyhash.init(tasks_fingerprint ^ (heat_epoch *% 0x517cc1b727220a95));
        hasher.update(self.req.pattern);
        hasher.update("\x00");
        hasher.update(self.req.mode);
        hasher.update("\x00");
        hasher.update(self.req.case);
        hasher.update("\x00");
        const flags: [5]u8 = .{
            @intFromBool(self.req.wholeWord),
            @intFromBool(self.req.wholeLine),
            @intFromBool(self.req.invert),
            @intFromBool(self.req.hidden),
            @intFromBool(self.req.respectIgnore),
        };
        hasher.update(&flags);
        hasher.update(std.mem.asBytes(&self.req.context));
        hasher.update(std.mem.asBytes(&self.req.maxResults));
        hasher.update(std.mem.asBytes(&self.req.nearbyLines));
        hasher.update(std.mem.asBytes(&self.time_start_ns));
        hasher.update(std.mem.asBytes(&self.time_end_ns));
        hasher.update(self.time_mode.asStr());
        hasher.update(self.time_format_sig);
        hasher.update(std.mem.asBytes(&self.tz_offset_min));
        if (self.req.replacement) |rep| {
            hasher.update(rep);
        }
        hasher.update("\x00");
        for (self.req.contains) |s| {
            hasher.update(s);
            hasher.update("\xff");
        }
        hasher.update("\x00");
        for (self.req.excludes) |s| {
            hasher.update(s);
            hasher.update("\xff");
        }
        hasher.update("\x00");
        for (self.req.globs) |s| {
            hasher.update(s);
            hasher.update("\xff");
        }
        hasher.update("\x00");
        for (self.req.fileGlobs) |s| {
            hasher.update(s);
            hasher.update("\xff");
        }
        hasher.update("\x00");
        for (self.req.types) |s| {
            hasher.update(s);
            hasher.update("\xff");
        }
        hasher.update("\x00");
        for (self.req.sources) |s| {
            hasher.update(s);
            hasher.update("\xff");
        }
        return hasher.final();
    }

    fn flushItemsSliceToSender(self: *JobRunner, items: []const HitItem) void {
        const chunk_size: usize = 256;
        var offset: usize = 0;
        while (offset < items.len and !self.shouldStop()) {
            const end = @min(offset + chunk_size, items.len);
            const hits_json = file_api.stringifyAlloc(self.gpa, HitsFrame{
                .id = self.req.id,
                .items = items[offset..end],
            }) catch {
                self.send_failed.store(true, .release);
                return;
            };
            defer self.gpa.free(hits_json);
            self.sender.send(hits_json) catch {
                self.send_failed.store(true, .release);
                return;
            };
            offset = end;
        }
    }

    fn slicesEqual(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |sa, sb| {
            if (!std.mem.eql(u8, sa, sb)) return false;
        }
        return true;
    }

    fn tryReplayExactCache(self: *JobRunner, exact_hash: u64, tasks_fingerprint: u64, heat_epoch: u64) bool {
        const reg = self.registry orelse return false;
        var raw_items_json: []const u8 = "";
        var has_items = false;
        var files_searched: u64 = 0;
        var files_matched: u64 = 0;
        var total_matches: u64 = 0;
        var matched_lines: u64 = 0;
        var bytes_searched: u64 = 0;
        var limit_hit: bool = false;
        const req_has_replacement = (self.req.replacement != null and self.req.replacement.?.len > 0);

        {
            reg.search_cache.mutex.lockUncancelable(self.io);
            defer reg.search_cache.mutex.unlock(self.io);

            var found_entry: ?*search_cache.CachedQueryEntry = null;
            for (reg.search_cache.entries.items) |*e| {
                if (e.exact_hash != exact_hash or
                    e.tasks_fingerprint != tasks_fingerprint or
                    e.heat_epoch != heat_epoch or
                    e.max_results != self.req.maxResults or
                    e.time_start_ns != self.time_start_ns or
                    e.time_end_ns != self.time_end_ns or
                    !std.mem.eql(u8, e.time_mode, self.time_mode.asStr()) or
                    !std.mem.eql(u8, e.time_format_sig, self.time_format_sig) or
                    e.tz_offset_min != self.tz_offset_min or
                    e.whole_word != self.req.wholeWord or
                    e.whole_line != self.req.wholeLine or
                    e.invert != self.req.invert or
                    e.context != self.req.context or
                    e.has_replacement != req_has_replacement or
                    e.file_mtimes.len != self.file_tasks.items.len or
                    !std.mem.eql(u8, e.pattern, self.req.pattern) or
                    !std.mem.eql(u8, e.mode, self.req.mode) or
                    !std.mem.eql(u8, e.case_mode, self.req.case) or
                    !slicesEqual(e.contains, self.req.contains) or
                    !slicesEqual(e.excludes, self.req.excludes))
                {
                    continue;
                }

                // 100% collision-free 1:1 verification of all candidate files `(rel_path, mtime_ns, file_size, inode)`
                var files_exact = true;
                for (self.file_tasks.items) |ft| {
                    var matched_file = false;
                    for (e.file_mtimes) |fm| {
                        if (fm.mtime_ns == ft.mtime_ns and
                            fm.file_size == ft.file_size and
                            fm.inode == ft.inode and
                            std.mem.eql(u8, fm.rel_path, ft.rel_path))
                        {
                            matched_file = true;
                            break;
                        }
                    }
                    if (!matched_file) {
                        files_exact = false;
                        break;
                    }
                }
                if (!files_exact) continue;

                found_entry = e;
                break;
            }
            const entry = found_entry orelse return false;
            reg.search_cache.tick +%= 1;
            entry.access_tick = reg.search_cache.tick;

            files_searched = entry.files_searched;
            files_matched = entry.files_matched;
            total_matches = entry.total_matches;
            matched_lines = entry.matched_lines;
            bytes_searched = entry.bytes_searched;
            limit_hit = entry.limit_hit;

            if (entry.items.len > 0 and entry.raw_items_json.len > 2) {
                raw_items_json = self.job_arena.dupe(u8, entry.raw_items_json) catch return false;
                has_items = true;
            }
        }

        self.files_searched.store(files_searched, .release);
        self.files_matched.store(files_matched, .release);
        self.total_matches.store(total_matches, .release);
        self.matched_lines.store(matched_lines, .release);
        self.bytes_searched.store(bytes_searched, .release);
        self.hit_max_results.store(limit_hit, .release);

        if (has_items) {
            const frame_json = std.fmt.allocPrint(
                self.job_arena,
                "{{\"type\":\"hits\",\"id\":{d},\"items\":{s}}}",
                .{ self.req.id, raw_items_json },
            ) catch {
                self.send_failed.store(true, .release);
                return true;
            };
            self.sender.send(frame_json) catch {
                self.send_failed.store(true, .release);
            };
        }
        return true;
    }

    fn sliceIsSubset(sub: []const []const u8, sup: []const []const u8) bool {
        for (sub) |needle| {
            var found = false;
            for (sup) |cand| {
                if (std.mem.eql(u8, needle, cand)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn lineMatchesTaskPredicates(
        self: *const JobRunner,
        task: *const FileTask,
        line_text: []const u8,
        parsed_case: libwebgrep.CaseMode,
        default_case_insensitive: bool,
    ) bool {
        if ((self.time_start_ns > 0 or self.time_end_ns > 0) and task.task_time_mode == .mtime) {
            if (task.mtime_ns > 0) {
                const mtime_u64: u64 = @intCast(@max(0, task.mtime_ns));
                if (self.time_start_ns > 0 and mtime_u64 < self.time_start_ns) return false;
                if (self.time_end_ns > 0 and mtime_u64 > self.time_end_ns) return false;
            }
        }
        for (task.effective_excludes) |ex_lit| {
            if (ex_lit.len == 0) continue;
            const ci = switch (parsed_case) {
                .insensitive => true,
                .sensitive => false,
                .smart => !hasAsciiUpper(ex_lit),
            };
            const matched = if (ci)
                containsIgnoreCase(line_text, ex_lit)
            else
                (std.mem.indexOf(u8, line_text, ex_lit) != null);
            if (matched) return false;
        }
        for (self.excludes_regexes) |*ex_re| {
            if (ex_re.findReadOnly(line_text, 0, .leftmost_first) != null) return false;
        }
        for (task.effective_contains) |inc_lit| {
            if (inc_lit.len == 0) continue;
            const ci = switch (parsed_case) {
                .insensitive => true,
                .sensitive => false,
                .smart => !hasAsciiUpper(inc_lit),
            };
            const matched = if (ci)
                containsIgnoreCase(line_text, inc_lit)
            else
                (std.mem.indexOf(u8, line_text, inc_lit) != null);
            if (!matched) return false;
        }
        for (self.contains_regexes) |*inc_re| {
            if (inc_re.findReadOnly(line_text, 0, .leftmost_first) == null) return false;
        }
        _ = default_case_insensitive;
        switch (self.matcher.*) {
            .literal => |*f| {
                if (f.find(line_text, 0, .leftmost_first) == null) return false;
            },
            .multi => |*m| {
                if (m.find(line_text, 0, .leftmost_first) == null) return false;
            },
            .regex => |*r| {
                if (r.findReadOnly(line_text, 0, .leftmost_first) == null) return false;
            },
        }
        return true;
    }

    fn computeArchiveFilterHash(self: *const JobRunner) u64 {
        var hasher = std.hash.Wyhash.init(0x7a69675f61726368);
        const flags: [2]u8 = .{
            @intFromBool(self.req.hidden),
            @intFromBool(self.req.respectIgnore),
        };
        hasher.update(&flags);
        hasher.update("\x00");
        for (self.req.types) |s| {
            hasher.update(s);
            hasher.update("\xff");
        }
        hasher.update("\x00");
        for (self.activeFileGlobs()) |s| {
            hasher.update(s);
            hasher.update("\xff");
        }
        return hasher.final();
    }

    fn isArchiveUnrestricted(self: *const JobRunner) bool {
        return self.req.types.len == 0 and
            self.activeFileGlobs().len == 0 and
            self.req.hidden and
            !self.req.respectIgnore;
    }

    fn tryFilterSupersetCache(self: *JobRunner, exact_hash: u64, tasks_fingerprint: u64, heat_epoch: u64) bool {
        const reg = self.registry orelse return false;
        if (self.req.invert or self.req.context > 0) return false;
        if (self.req.replacement != null and self.req.replacement.?.len > 0) return false;

        const total_files = self.file_tasks.items.len;
        if (total_files == 0) return false;

        var has_archive_task = false;
        for (self.file_tasks.items) |ft| {
            if (ft.archive_format != null) {
                has_archive_task = true;
                break;
            }
        }
        const cur_arch_hash = self.computeArchiveFilterHash();

        const parsed_case = parseCaseMode(self.req.case);
        const is_case_insensitive = switch (parsed_case) {
            .insensitive => true,
            .sensitive => false,
            .smart => !hasAsciiUpper(self.req.pattern),
        };

        const BucketCandidate = struct {
            item: HitItem,
            raw_json: []const u8 = "",
        };

        var per_task_buckets = self.job_arena.alloc(std.ArrayList(BucketCandidate), total_files) catch return false;
        for (0..total_files) |i| per_task_buckets[i] = .empty;
        var parent_bytes_searched: u64 = 0;
        var can_fast_splice_raw_json = false;

        {
            reg.search_cache.mutex.lockUncancelable(self.io);
            defer reg.search_cache.mutex.unlock(self.io);

            var best_entry: ?*search_cache.CachedQueryEntry = null;
            for (reg.search_cache.entries.items) |*e| {
                if (e.limit_hit or e.invert or e.context != 0 or e.has_replacement) continue;
                if (e.whole_word != self.req.wholeWord or e.whole_line != self.req.wholeLine) continue;
                if (!std.mem.eql(u8, e.mode, self.req.mode)) continue;
                if (!std.mem.eql(u8, e.case_mode, self.req.case)) continue;
                if (has_archive_task and e.archive_filter_hash != cur_arch_hash and !e.archive_unrestricted) continue;

                const exact_pat = std.mem.eql(u8, e.pattern, self.req.pattern);
                if (!exact_pat) {
                    if (!std.mem.eql(u8, self.req.mode, "literal") or self.req.wholeWord or self.req.wholeLine) continue;
                    if (self.req.pattern.len < e.pattern.len or e.pattern.len == 0) continue;
                    if (parseScopedModifier(self.job_arena, self.req.pattern, parsed_case) != null) continue;
                    if (parseScopedModifier(self.job_arena, e.pattern, parsed_case) != null) continue;
                    const parent_ci = switch (parsed_case) {
                        .insensitive => true,
                        .sensitive => false,
                        .smart => !hasAsciiUpper(e.pattern),
                    };
                    if (parent_ci) {
                        if (!containsIgnoreCase(self.req.pattern, e.pattern)) continue;
                    } else {
                        if (is_case_insensitive or std.mem.indexOf(u8, self.req.pattern, e.pattern) == null) continue;
                    }
                }
                if (!sliceIsSubset(e.contains, self.req.contains)) continue;
                if (!sliceIsSubset(e.excludes, self.req.excludes)) continue;
                if (!std.mem.eql(u8, e.time_mode, self.time_mode.asStr())) continue;
                if (!std.mem.eql(u8, e.time_format_sig, self.time_format_sig)) continue;
                if (e.tz_offset_min != self.tz_offset_min) continue;
                if (self.is_empty_text_time_browse) continue;
                if ((e.time_start_ns > 0 or e.time_end_ns > 0) and e.pattern.len == 0 and e.contains.len == 0 and e.excludes.len == 0 and !e.invert) continue;
                if (self.time_mode != .mtime) {
                    // For .source/.content/.auto, exact window match preserves multi-line stack-trace inheritance
                    if (e.time_start_ns != self.time_start_ns or e.time_end_ns != self.time_end_ns) continue;
                } else {
                    // Superset time range must cover the requested time range
                    if (e.time_start_ns > self.time_start_ns) continue;
                    if (e.time_end_ns != 0 and (self.time_end_ns == 0 or e.time_end_ns < self.time_end_ns)) continue;
                }

                // Strong Consistency Guard for >4096-byte long lines / lossy UTF-8 lines:
                // If predicates changed (`pattern`, `contains`, or `excludes`), in-memory filtering on `ci.text`
                // is only 100% sound when every cached line in `e` was stored without 4096-byte truncation!
                const predicates_changed = !exact_pat or
                    e.time_start_ns != self.time_start_ns or
                    e.time_end_ns != self.time_end_ns or
                    !slicesEqual(e.contains, self.req.contains) or
                    !slicesEqual(e.excludes, self.req.excludes);
                if (predicates_changed and !e.all_lines_exact) continue;

                // Verify that every candidate file in `self.file_tasks` was covered by `e` with identical `(mtime_ns, file_size, inode)`
                var all_files_covered = true;
                for (self.file_tasks.items) |ft| {
                    var found_file = false;
                    for (e.file_mtimes) |fm| {
                        if (fm.mtime_ns == ft.mtime_ns and
                            fm.file_size == ft.file_size and
                            fm.inode == ft.inode and
                            std.mem.eql(u8, fm.rel_path, ft.rel_path))
                        {
                            found_file = true;
                            break;
                        }
                    }
                    if (!found_file) {
                        all_files_covered = false;
                        break;
                    }
                }
                if (!all_files_covered) continue;

                if (best_entry == null or e.items.len < best_entry.?.items.len) {
                    best_entry = e;
                }
            }

            const sup = best_entry orelse return false;
            const pattern_changed = !std.mem.eql(u8, sup.pattern, self.req.pattern);
            const primary_span_finder: ?libwebgrep.Finder = if (pattern_changed)
                (libwebgrep.Finder.init(self.req.pattern, EngineLimits.findOptions(parsed_case)) catch return false)
            else
                null;

            can_fast_splice_raw_json = !pattern_changed;
            reg.search_cache.tick +%= 1;
            sup.access_tick = reg.search_cache.tick;
            parent_bytes_searched = sup.bytes_searched;
            self.had_non_exact_line.store(!sup.all_lines_exact, .release);

            var task_map = std.StringHashMapUnmanaged(usize){};
            defer task_map.deinit(self.job_arena);
            for (self.file_tasks.items, 0..) |ft, idx| {
                task_map.put(self.job_arena, ft.rel_path, idx) catch return false;
            }

            for (sup.items) |ci| {
                if (ci.isContext) continue;
                const sep_idx_opt = std.mem.indexOf(u8, ci.file, ARCHIVE_VIRTUAL_SEP);
                const lookup_path = if (sep_idx_opt) |sep_idx| ci.file[0..sep_idx] else ci.file;
                const task_idx = task_map.get(lookup_path) orelse continue;
                const task = &self.file_tasks.items[task_idx];
                if (sep_idx_opt) |sep_idx| {
                    const entry_path = ci.file[sep_idx + ARCHIVE_VIRTUAL_SEP.len ..];
                    const entry_base = std.fs.path.basename(entry_path);
                    if (self.types_include.len > 0 or self.types_exclude.len > 0) {
                        if (!libwebgrep.walk_types.matchesWithTable(
                            self.custom_types_table,
                            self.types_include,
                            self.types_exclude,
                            entry_base,
                        )) continue;
                    }
                    if (!self.archiveEntryMatchesPathGlobs(task.rel_path, task.base_name, entry_path)) continue;
                }
                if (!self.lineMatchesTaskPredicates(task, ci.text, parsed_case, is_case_insensitive)) continue;

                const spans: []HitSpan = if (!pattern_changed) blk: {
                    const sp_slice = self.job_arena.alloc(HitSpan, ci.spans.len) catch return false;
                    for (ci.spans, 0..) |cs, si| {
                        sp_slice[si] = .{ .start = cs.start, .end = cs.end };
                    }
                    break :blk sp_slice;
                } else blk: {
                    var sp_list: std.ArrayList(HitSpan) = .empty;
                    const pf_ptr = &(primary_span_finder orelse break :blk &.{});
                    var bpos: usize = 0;
                    while (bpos <= ci.text.len) {
                        const hit = pf_ptr.find(ci.text, bpos, .leftmost_first) orelse break;
                        if (hit.start < bpos or hit.end > ci.text.len) break;
                        if (hit.end > hit.start) {
                            sp_list.append(self.job_arena, .{
                                .start = FileSink.utf8ByteToUtf16Offset(ci.text, hit.start),
                                .end = FileSink.utf8ByteToUtf16Offset(ci.text, hit.end),
                            }) catch return false;
                        }
                        if (hit.end <= bpos) break;
                        bpos = hit.end;
                    }
                    break :blk sp_list.items;
                };

                const raw_dup: []const u8 = if (can_fast_splice_raw_json and ci.raw_item_json.len > 0)
                    (self.job_arena.dupe(u8, ci.raw_item_json) catch "")
                else blk: {
                    can_fast_splice_raw_json = false;
                    break :blk "";
                };

                const cloned = HitItem{
                    .file = self.job_arena.dupe(u8, ci.file) catch return false,
                    .line = ci.line,
                    .col = if (spans.len > 0) spans[0].start + 1 else ci.col,
                    .text = self.job_arena.dupe(u8, ci.text) catch return false,
                    .prevText = if (ci.prevText) |pt| (self.job_arena.dupe(u8, pt) catch null) else null,
                    .nextText = if (ci.nextText) |nt| (self.job_arena.dupe(u8, nt) catch null) else null,
                    .replaced = null,
                    .isContext = false,
                    .byteOffset = ci.byteOffset,
                    .spans = spans,
                };
                per_task_buckets[task_idx].append(self.job_arena, .{
                    .item = cloned,
                    .raw_json = raw_dup,
                }) catch return false;
            }
        }

        // Apply Two-Phase Heat-Weighted Elastic Water-Filling over in-memory buckets
        const max_res = self.req.maxResults;
        var emitted_per_task = self.job_arena.alloc(usize, total_files) catch return false;
        @memset(emitted_per_task, 0);

        var selected_raw_jsons: std.ArrayList([]const u8) = .empty;
        var total_emitted: u64 = 0;
        var limit_hit = false;

        // Phase 1: Heat-proportional soft quota
        for (self.file_tasks.items, 0..) |t, idx| {
            const bucket = per_task_buckets[idx].items;
            if (bucket.len == 0) continue;
            const cap_in_task: usize = if (t.soft_quota > 0)
                @min(bucket.len, @as(usize, @intCast(t.soft_quota)))
            else
                bucket.len;
            var take = cap_in_task;
            if (max_res > 0 and total_emitted + take > max_res) {
                take = @intCast(max_res - total_emitted);
                limit_hit = true;
            }
            for (bucket[0..take]) |cand| {
                self.collected_hits.append(self.job_arena, cand.item) catch return false;
                if (can_fast_splice_raw_json) {
                    selected_raw_jsons.append(self.job_arena, cand.raw_json) catch {
                        can_fast_splice_raw_json = false;
                    };
                }
            }
            emitted_per_task[idx] = take;
            total_emitted += take;
            if (max_res > 0 and total_emitted >= max_res) {
                if (take < bucket.len) limit_hit = true;
                break;
            }
        }

        // Phase 2+: Dynamic Water-Filling for remaining quota
        while (max_res == 0 or total_emitted < max_res) {
            var active_heat_sum: u64 = 0;
            var overflow_count: usize = 0;
            for (self.file_tasks.items, 0..) |t, idx| {
                if (emitted_per_task[idx] < per_task_buckets[idx].items.len) {
                    active_heat_sum +|= t.heat_score;
                    overflow_count += 1;
                }
            }
            if (overflow_count == 0) break;
            if (active_heat_sum == 0) active_heat_sum = 1;

            const remaining = if (max_res > 0) max_res - total_emitted else std.math.maxInt(u64);
            var seen_overflow: usize = 0;
            var allocated: u64 = 0;
            for (self.file_tasks.items, 0..) |t, idx| {
                const bucket = per_task_buckets[idx].items;
                const already = emitted_per_task[idx];
                if (already >= bucket.len) continue;
                seen_overflow += 1;

                const share: u64 = if (max_res == 0 or overflow_count == 1)
                    @intCast(bucket.len - already)
                else if (seen_overflow == overflow_count)
                    (if (remaining > allocated) remaining - allocated else 1)
                else
                    @max(@as(u64, 1), (remaining * t.heat_score) / active_heat_sum);
                allocated +|= share;

                var take: usize = @min(bucket.len - already, @as(usize, @intCast(share)));
                if (max_res > 0 and total_emitted + take >= max_res) {
                    take = @intCast(max_res - total_emitted);
                    if (already + take < bucket.len) limit_hit = true;
                }
                for (bucket[already .. already + take]) |cand| {
                    self.collected_hits.append(self.job_arena, cand.item) catch return false;
                    if (can_fast_splice_raw_json) {
                        selected_raw_jsons.append(self.job_arena, cand.raw_json) catch {
                            can_fast_splice_raw_json = false;
                        };
                    }
                }
                emitted_per_task[idx] = already + take;
                total_emitted += take;
                if (max_res > 0 and total_emitted >= max_res) break;
            }
        }

        var files_matched: u64 = 0;
        for (emitted_per_task, 0..) |em, idx| {
            if (em > 0) files_matched += 1;
            if (em < per_task_buckets[idx].items.len) limit_hit = true;
        }

        self.files_searched.store(@intCast(total_files), .release);
        self.files_matched.store(files_matched, .release);
        self.total_matches.store(total_emitted, .release);
        self.matched_lines.store(total_emitted, .release);
        self.bytes_searched.store(parent_bytes_searched, .release);
        self.hit_max_results.store(limit_hit, .release);

        if (self.collected_hits.items.len > 0) {
            if (can_fast_splice_raw_json and selected_raw_jsons.items.len == self.collected_hits.items.len) {
                var total_json_bytes: usize = 64;
                for (selected_raw_jsons.items) |rj| {
                    total_json_bytes += rj.len + 1;
                }
                var out_buf: std.ArrayList(u8) = .empty;
                if (out_buf.ensureTotalCapacity(self.job_arena, total_json_bytes)) {
                    const hdr = std.fmt.allocPrint(self.job_arena, "{{\"type\":\"hits\",\"id\":{d},\"items\":[", .{self.req.id}) catch "";
                    if (hdr.len > 0) {
                        out_buf.appendSliceAssumeCapacity(hdr);
                        for (selected_raw_jsons.items, 0..) |rj, i| {
                            if (i > 0) out_buf.appendAssumeCapacity(',');
                            out_buf.appendSliceAssumeCapacity(rj);
                        }
                        out_buf.appendSliceAssumeCapacity("]}");
                        self.sender.send(out_buf.items) catch {
                            self.send_failed.store(true, .release);
                        };
                    } else {
                        self.flushItemsSliceToSender(self.collected_hits.items);
                    }
                } else |_| {
                    self.flushItemsSliceToSender(self.collected_hits.items);
                }
            } else {
                self.flushItemsSliceToSender(self.collected_hits.items);
            }
        }
        if (!self.send_failed.load(.acquire) and !self.cancel_flag.load(.acquire)) {
            self.should_commit_cache = true;
            self.pending_exact_hash = exact_hash;
            self.pending_tasks_fingerprint = tasks_fingerprint;
            self.pending_heat_epoch = heat_epoch;
        }
        return true;
    }

    fn commitCacheAfterDone(self: *JobRunner) void {
        if (!self.should_commit_cache) return;
        if (self.send_failed.load(.acquire) or self.cancel_flag.load(.acquire) or self.had_scan_error.load(.acquire)) return;
        self.storeResultInCache(
            self.pending_exact_hash,
            self.pending_tasks_fingerprint,
            self.pending_heat_epoch,
        );
    }

    fn storeResultInCache(self: *JobRunner, exact_hash: u64, tasks_fingerprint: u64, heat_epoch: u64) void {
        const reg = self.registry orelse return;
        if (self.collected_hits_overflow or self.had_scan_error.load(.acquire)) return;
        if (self.collected_hits.items.len > search_cache.MAX_ITEMS_PER_ENTRY) return;

        var entry_arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer entry_arena.deinit();
        const alloc = entry_arena.allocator();

        const pat_copy = alloc.dupe(u8, self.req.pattern) catch return;
        const mode_copy = alloc.dupe(u8, self.req.mode) catch return;
        const case_copy = alloc.dupe(u8, self.req.case) catch return;

        const contains_copy = alloc.alloc([]const u8, self.req.contains.len) catch return;
        for (self.req.contains, 0..) |s, i| {
            contains_copy[i] = alloc.dupe(u8, s) catch return;
        }
        const excludes_copy = alloc.alloc([]const u8, self.req.excludes.len) catch return;
        for (self.req.excludes, 0..) |s, i| {
            excludes_copy[i] = alloc.dupe(u8, s) catch return;
        }

        const fm_copy = alloc.alloc(search_cache.FileMtimeRecord, self.file_tasks.items.len) catch return;
        for (self.file_tasks.items, 0..) |ft, i| {
            fm_copy[i] = .{
                .rel_path = alloc.dupe(u8, ft.rel_path) catch return,
                .mtime_ns = ft.mtime_ns,
                .file_size = ft.file_size,
                .inode = ft.inode,
            };
        }

        const raw_items_json: []const u8 = if (self.collected_hits.items.len > 0)
            (file_api.stringifyAlloc(alloc, self.collected_hits.items) catch "[]")
        else
            "[]";

        var approx_bytes: usize = 512 + self.file_tasks.items.len * 64 + raw_items_json.len;
        const items_copy = alloc.alloc(search_cache.CachedHitItem, self.collected_hits.items.len) catch return;
        for (self.collected_hits.items, 0..) |it, i| {
            const spans_copy = alloc.alloc(search_cache.CachedSpan, it.spans.len) catch return;
            for (it.spans, 0..) |sp, si| {
                spans_copy[si] = .{ .start = sp.start, .end = sp.end };
            }
            const f_dup = alloc.dupe(u8, it.file) catch return;
            const t_dup = alloc.dupe(u8, it.text) catch return;
            const prev_dup = if (it.prevText) |pt| (alloc.dupe(u8, pt) catch null) else null;
            const next_dup = if (it.nextText) |nt| (alloc.dupe(u8, nt) catch null) else null;
            const r_dup = if (it.replaced) |r| (alloc.dupe(u8, r) catch null) else null;
            items_copy[i] = .{
                .file = f_dup,
                .line = it.line,
                .col = it.col,
                .text = t_dup,
                .prevText = prev_dup,
                .nextText = next_dup,
                .replaced = r_dup,
                .isContext = it.isContext,
                .byteOffset = it.byteOffset,
                .spans = spans_copy,
                .raw_item_json = "",
            };
            approx_bytes += 88 + f_dup.len + t_dup.len +
                (if (prev_dup) |p| p.len else 0) +
                (if (next_dup) |n| n.len else 0) +
                spans_copy.len * 16;
        }

        // Zero-copy slice each top-level `{...}` JSON object out of `raw_items_json`
        if (items_copy.len > 0 and raw_items_json.len > 2) {
            var item_idx: usize = 0;
            var obj_start: usize = 0;
            var depth: usize = 0;
            var in_str = false;
            var escaped = false;
            for (raw_items_json, 0..) |ch, pos| {
                if (in_str) {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == '"') {
                        in_str = false;
                    }
                    continue;
                }
                if (ch == '"') {
                    in_str = true;
                } else if (ch == '{') {
                    if (depth == 0) obj_start = pos;
                    depth += 1;
                } else if (ch == '}') {
                    if (depth > 0) {
                        depth -= 1;
                        if (depth == 0 and item_idx < items_copy.len) {
                            items_copy[item_idx].raw_item_json = raw_items_json[obj_start .. pos + 1];
                            item_idx += 1;
                        }
                    }
                }
            }
        }

        const tf_sig_copy = if (self.time_format_sig.len > 0)
            entry_arena.allocator().dupe(u8, self.time_format_sig) catch {
                entry_arena.deinit();
                return;
            }
        else
            "";

        const archive_unrestricted = self.isArchiveUnrestricted();
        const archive_filter_hash = self.computeArchiveFilterHash();

        reg.search_cache.mutex.lockUncancelable(self.io);
        defer reg.search_cache.mutex.unlock(self.io);

        reg.search_cache.evictIfNeededLocked(approx_bytes);
        reg.search_cache.tick +%= 1;

        reg.search_cache.entries.append(self.gpa, .{
            .arena = entry_arena,
            .exact_hash = exact_hash,
            .tasks_fingerprint = tasks_fingerprint,
            .heat_epoch = heat_epoch,
            .pattern = pat_copy,
            .mode = mode_copy,
            .case_mode = case_copy,
            .whole_word = self.req.wholeWord,
            .whole_line = self.req.wholeLine,
            .invert = self.req.invert,
            .context = self.req.context,
            .has_replacement = (self.req.replacement != null and self.req.replacement.?.len > 0),
            .max_results = self.req.maxResults,
            .time_start_ns = self.time_start_ns,
            .time_end_ns = self.time_end_ns,
            .time_mode = self.time_mode.asStr(),
            .time_format_sig = tf_sig_copy,
            .tz_offset_min = self.tz_offset_min,
            .contains = contains_copy,
            .excludes = excludes_copy,
            .file_mtimes = fm_copy,
            .items = items_copy,
            .raw_items_json = raw_items_json,
            .files_searched = self.files_searched.load(.acquire),
            .files_matched = self.files_matched.load(.acquire),
            .total_matches = self.total_matches.load(.acquire),
            .matched_lines = self.matched_lines.load(.acquire),
            .bytes_searched = self.bytes_searched.load(.acquire),
            .limit_hit = self.hit_max_results.load(.acquire),
            .all_lines_exact = !self.had_non_exact_line.load(.acquire),
            .archive_unrestricted = archive_unrestricted,
            .archive_filter_hash = archive_filter_hash,
            .approx_bytes = approx_bytes,
            .access_tick = reg.search_cache.tick,
        }) catch {
            entry_arena.deinit();
            return;
        };
        reg.search_cache.total_bytes += approx_bytes;
    }

    fn runParallelWorkers(self: *JobRunner) void {
        const total_files = self.file_tasks.items.len;
        if (total_files == 0) return;

        const tasks_fingerprint = self.computeTasksFingerprint();
        const heat_epoch: u64 = if (self.registry) |reg| reg.getHeatEpoch() else 0;
        const exact_hash = self.computeExactQueryHash(tasks_fingerprint, heat_epoch);

        // Tier L1: Exact Query Frame Replay Cache (< 0.2ms)
        // Live Docker streams append continuously without static (inode, size, mtime), so jobs touching Docker bypass L1/L2/L3.
        if (!self.has_docker_tasks and self.tryReplayExactCache(exact_hash, tasks_fingerprint, heat_epoch)) {
            self.cache_hit_tier = "exact";
            self.tryNearbyFallbackAfterCache();
            return;
        }

        self.prepareHeatAndQuotas();

        // Tier L2: Progressive Superset In-Memory Narrowing Cache (< 0.8ms)
        if (!self.has_docker_tasks and self.tryFilterSupersetCache(exact_hash, tasks_fingerprint, heat_epoch)) {
            self.cache_hit_tier = "superset";
            self.tryNearbyFallbackAfterCache();
            return;
        }

        // Tier L3: Zero-Hit File Substring Monotonic Pruning Cache
        self.active_task_indices.clearRetainingCapacity();
        self.active_task_indices.ensureTotalCapacity(self.job_arena, total_files) catch return;

        const can_use_negative_prune = (self.registry != null) and
            !self.req.invert and
            std.mem.eql(u8, self.req.mode, "literal") and
            (parseScopedModifier(self.job_arena, self.req.pattern, parseCaseMode(self.req.case)) == null);

        var req_literals_buf: [16][]const u8 = undefined;
        var req_literals_len: usize = 0;
        if (can_use_negative_prune and self.req.pattern.len >= 2) {
            req_literals_buf[0] = self.req.pattern;
            req_literals_len = 1;
            for (self.req.contains) |c_pat| {
                if (req_literals_len >= req_literals_buf.len) break;
                if (c_pat.len >= 2 and parseScopedModifier(self.job_arena, c_pat, parseCaseMode(self.req.case)) == null) {
                    req_literals_buf[req_literals_len] = c_pat;
                    req_literals_len += 1;
                }
            }
        }
        const parsed_case = parseCaseMode(self.req.case);
        const query_case_insensitive = switch (parsed_case) {
            .insensitive => true,
            .sensitive => false,
            .smart => !hasAsciiUpper(self.req.pattern),
        };

        var normal_indices: std.ArrayList(usize) = .empty;
        var colossal_indices: std.ArrayList(usize) = .empty;
        normal_indices.ensureTotalCapacity(self.job_arena, total_files) catch return;
        colossal_indices.ensureTotalCapacity(self.job_arena, total_files) catch return;

        for (0..total_files) |idx| {
            const t = &self.file_tasks.items[idx];
            if (!t.isDocker() and can_use_negative_prune and req_literals_len > 0 and (t.archive_format == null or self.isArchiveUnrestricted())) {
                if (self.registry.?.search_cache.checkFilePrunedByNegativeCache(
                    self.io,
                    t.rel_path,
                    t.mtime_ns,
                    t.file_size,
                    t.inode,
                    req_literals_buf[0..req_literals_len],
                    query_case_insensitive,
                )) |cached_bytes| {
                    t.counted_file_searched = true;
                    _ = self.files_searched.fetchAdd(1, .monotonic);
                    _ = self.bytes_searched.fetchAdd(cached_bytes, .monotonic);
                    self.pruned_by_negative_cache.store(true, .release);
                    continue;
                }
            }
            if (t.isColossal()) {
                colossal_indices.appendAssumeCapacity(idx);
            } else {
                normal_indices.appendAssumeCapacity(idx);
            }
        }

        // Stage 1: Run complete Phase 1 + Phase 2+ elastic water-filling on normal files (<= 256 MiB) first
        // so multi-GB files never stall Phase 1 or delay hitting maxResults on normal files.
        if (normal_indices.items.len > 0) {
            self.runWaterFillingForSubset(normal_indices.items, true);
        }

        // Stage 2: If normal files did not exhaust maxResults, scan colossal files (> 256 MiB) without soft_quota pauses.
        if (!self.shouldStop() and colossal_indices.items.len > 0) {
            self.runWaterFillingForSubset(colossal_indices.items, false);
        }

        // Block-Proximity Fallback (±15 lines):
        // When a multi-keyword query (`req.contains.len > 0`, e.g. `pub fn async members`) yields 0 single-line matches
        // across all candidate files, check whether all query predicates co-occur within a ±15-line code block window.
        if (self.total_matches.load(.acquire) == 0 and self.canRunBlockProximityFallback()) {
            if (self.runBlockProximityFallback()) {
                self.cache_hit_tier = "nearby";
                return;
            }
        }

        // Feed observed query match heat back into SourceRegistry for future searches
        if (self.registry) |reg| {
            for (self.file_tasks.items) |t| {
                if (t.emitted_in_file > 0) {
                    const heat_boost = @min(@as(u64, 80), 8 + t.emitted_in_file / 16);
                    reg.recordPassiveMatchHeat(self.io, t.rel_path, heat_boost);
                }
            }
        }

        if (self.pruned_by_negative_cache.load(.acquire)) {
            self.cache_hit_tier = "pruned";
        }
        if (!self.has_docker_tasks and !self.cancel_flag.load(.acquire) and !self.send_failed.load(.acquire) and !self.had_scan_error.load(.acquire)) {
            const final_heat_epoch: u64 = if (self.registry) |reg| reg.getHeatEpoch() else heat_epoch;
            self.should_commit_cache = true;
            self.pending_exact_hash = if (final_heat_epoch == heat_epoch)
                exact_hash
            else
                self.computeExactQueryHash(tasks_fingerprint, final_heat_epoch);
            self.pending_tasks_fingerprint = tasks_fingerprint;
            self.pending_heat_epoch = final_heat_epoch;
        }
    }

    fn workerThreadMain(self: *JobRunner) void {
        var batch_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer batch_arena_state.deinit();

        var scratch_pool = libwebgrep.Scratch.init(self.gpa);
        defer scratch_pool.deinit();

        var worker = WorkerContext{
            .runner = self,
            .batch_arena = &batch_arena_state,
            .scratch_pool = &scratch_pool,
            .time_regex_scratch = libwebgrep.RegexScratch.init(self.gpa),
            .last_flush_ts = std.Io.Clock.awake.now(self.io),
        };
        defer worker.time_regex_scratch.deinit();
        defer worker.batch_items.deinit(self.gpa);

        while (!self.shouldStop()) {
            const pos = self.next_task_idx.fetchAdd(1, .monotonic);
            if (pos >= self.active_task_indices.items.len) break;
            const task_idx = self.active_task_indices.items[pos];
            worker.searchOneTask(&self.file_tasks.items[task_idx]);
        }

        worker.flushBatch() catch {
            self.send_failed.store(true, .release);
        };
    }

    fn maybeSendProgress(self: *JobRunner, in_file_bytes: u64) void {
        if (self.shouldStop()) return;

        if (!self.progress_mutex.tryLock()) return;
        defer self.progress_mutex.unlock(self.io);

        const files_done = self.files_searched.load(.monotonic);
        const elapsed_ns = self.last_progress_ts.untilNow(self.io, .awake).toNanoseconds();
        if (elapsed_ns < 60 * std.time.ns_per_ms and (files_done == 0 or files_done % 200 != 0)) return;

        self.last_progress_ts = std.Io.Clock.awake.now(self.io);
        const prog_json = file_api.stringifyAlloc(self.gpa, ProgressFrame{
            .id = self.req.id,
            .filesSearched = files_done,
            .filesMatched = self.files_matched.load(.monotonic),
            .matches = self.total_matches.load(.monotonic),
            .bytesSearched = self.bytes_searched.load(.monotonic) + in_file_bytes,
        }) catch return;
        defer self.gpa.free(prog_json);
        self.sender.send(prog_json) catch {
            self.send_failed.store(true, .release);
        };
    }

    fn canRunBlockProximityFallback(self: *const JobRunner) bool {
        if (self.shouldStop()) return false;
        if (self.req.nearbyLines == 0) return false;
        // Time-filtered searches stay strictly line-based (nearby lines may fall outside the window).
        if (self.time_start_ns > 0 or self.time_end_ns > 0) return false;
        if (self.req.invert or self.req.wholeLine) return false;
        if (self.req.replacement != null and self.req.replacement.?.len > 0) return false;
        if (self.req.pattern.len == 0) return false;
        return self.req.contains.len > 0;
    }

    /// Runs the nearby-lines fallback after an L1/L2 cache tier produced 0 strict single-line hits.
    /// Fallback results are never committed to L1/L2 (they are not single-line supersets).
    fn tryNearbyFallbackAfterCache(self: *JobRunner) void {
        if (self.total_matches.load(.acquire) != 0 or !self.canRunBlockProximityFallback()) return;
        if (self.runBlockProximityFallback()) {
            self.should_commit_cache = false;
            self.cache_hit_tier = "nearby";
        }
    }

    fn runnerShouldStopCallback(ctx: *const anyopaque) bool {
        const self: *const JobRunner = @ptrCast(@alignCast(ctx));
        return self.shouldStop();
    }

    fn readBoundedStreamPrefixAlloc(
        gpa: std.mem.Allocator,
        reader: *std.Io.Reader,
        max_bytes: usize,
    ) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);

        var chunk: [32768]u8 = undefined;
        while (buf.items.len < max_bytes) {
            const want = @min(chunk.len, max_bytes - buf.items.len);
            const n = docker_logs.readReaderSome(reader, chunk[0..want]) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            try buf.appendSlice(gpa, chunk[0..n]);
        }

        if (buf.items.len == max_bytes) {
            var probe: [1]u8 = undefined;
            const extra = docker_logs.readReaderSome(reader, &probe) catch 0;
            if (extra > 0) {
                if (std.mem.lastIndexOfScalar(u8, buf.items, '\n')) |last_nl| {
                    buf.shrinkRetainingCapacity(last_nl + 1);
                }
            }
        }

        return buf.toOwnedSlice(gpa);
    }

    fn runBlockProximityFallback(self: *JobRunner) bool {
        const parsed_case = parseCaseMode(self.req.case);
        const max_res = self.req.maxResults;
        const block_radius: usize = @min(@as(usize, self.req.nearbyLines), 200);
        const max_fallback_file_bytes: u64 = 16 * 1024 * 1024;

        var fallback_hits: std.ArrayList(HitItem) = .empty;
        var matched_files_count: u64 = 0;
        var limit_hit = false;

        var regex_scratch = libwebgrep.RegexScratch.init(self.gpa);
        defer regex_scratch.deinit();

        for (self.file_tasks.items) |*task| {
            if (self.shouldStop()) break;
            if (!task.isDocker()) {
                if (task.file_size == 0 or task.file_size > max_fallback_file_bytes) continue;
                if (task.archive_format != null or isSingleStreamCompressed(task.base_name)) continue;
            }

            const pos_lit_count = task.effective_contains.len;
            const pos_re_count = self.contains_regexes.len;
            const total_preds = 1 + pos_lit_count + pos_re_count;
            if (total_preds <= 1 or total_preds > 32) continue;

            var opened_parent: ?std.Io.Dir = null;
            defer if (opened_parent) |*d| d.close(self.io);

            var hot_lease: ?search_cache.HotFileLease = null;
            defer if (hot_lease) |lease| {
                self.registry.?.search_cache.releaseHotFileSlice(self.io, lease.slot_idx);
            };

            var owned_buf: []u8 = &.{};
            defer if (owned_buf.len > 0) self.gpa.free(owned_buf);

            const raw_slice: []const u8 = if (task.isDocker()) blk_docker: {
                var log_reader = docker_logs.DockerLogReader.create(
                    self.gpa,
                    self.io,
                    task.docker_transport.?,
                    task.docker_container_id,
                    .{
                        .max_line_len = EngineLimits.max_line_len,
                        .cancel_flag = self.cancel_flag,
                        .stop_ctx = self,
                        .stop_fn = runnerShouldStopCallback,
                    },
                ) catch continue;
                defer log_reader.destroy();
                owned_buf = readBoundedStreamPrefixAlloc(
                    self.gpa,
                    &log_reader.interface,
                    @intCast(max_fallback_file_bytes),
                ) catch continue;
                break :blk_docker owned_buf;
            } else blk_fs: {
                const parent_dir: std.Io.Dir = if (task.parent_dir_path) |p| blk_p: {
                    opened_parent = std.Io.Dir.cwd().openDir(self.io, p, .{}) catch continue;
                    break :blk_p opened_parent.?;
                } else self.root_dir;

                if (self.registry) |reg| {
                    hot_lease = reg.search_cache.acquireHotFileSlice(
                        self.io,
                        task.rel_path,
                        task.mtime_ns,
                        task.file_size,
                        task.inode,
                        parent_dir,
                        task.open_sub_path,
                        search_cache.MAX_HOT_FILE_MAP_BYTES,
                    );
                }

                if (hot_lease) |lease| {
                    break :blk_fs lease.slice;
                }
                var file = parent_dir.openFile(self.io, task.open_sub_path, .{ .allow_directory = false }) catch continue;
                defer file.close(self.io);
                const alloc_len: usize = @intCast(task.file_size);
                owned_buf = self.gpa.alloc(u8, alloc_len) catch continue;
                const n = file.readPositionalAll(self.io, owned_buf, 0) catch continue;
                break :blk_fs owned_buf[0..n];
            };
            if (raw_slice.len == 0) continue;

            // Fast whole-file precheck: every positive predicate (`self.matcher`, `task.effective_contains`, `self.contains_regexes`)
            // must appear at least once in `raw_slice`. This prunes >95% of non-matching files in microseconds!
            const primary_in_file = switch (self.matcher.*) {
                .literal => |*f| (f.find(raw_slice, 0, .leftmost_first) != null),
                .multi => |*m| (m.find(raw_slice, 0, .leftmost_first) != null),
                .regex => |*r| (r.findWithScratch(raw_slice, 0, .leftmost_first, &regex_scratch) != null),
            };
            if (!primary_in_file) continue;

            var all_lits_in_file = true;
            for (task.effective_contains) |inc_lit| {
                if (inc_lit.len == 0) continue;
                const ci = switch (parsed_case) {
                    .insensitive => true,
                    .sensitive => false,
                    .smart => !hasAsciiUpper(inc_lit),
                };
                const found = if (ci)
                    containsIgnoreCase(raw_slice, inc_lit)
                else
                    (std.mem.indexOf(u8, raw_slice, inc_lit) != null);
                if (!found) {
                    all_lits_in_file = false;
                    break;
                }
            }
            if (!all_lits_in_file) continue;

            var all_res_in_file = true;
            for (self.contains_regexes) |*inc_re| {
                if (inc_re.findWithScratch(raw_slice, 0, .leftmost_first, &regex_scratch) == null) {
                    all_res_in_file = false;
                    break;
                }
            }
            if (!all_res_in_file) continue;

            const LineInfo = struct {
                text: []const u8,
                mask: u32,
                excluded: bool,
                matches_user_primary: bool,
            };
            var lines: std.ArrayList(LineInfo) = .empty;
            defer lines.deinit(self.gpa);

            const required_mask: u32 = if (total_preds == 32)
                std.math.maxInt(u32)
            else
                (@as(u32, 1) << @intCast(total_preds)) - 1;

            var pos: usize = 0;
            while (pos < raw_slice.len) {
                const nl = std.mem.indexOfScalarPos(u8, raw_slice, pos, '\n') orelse raw_slice.len;
                var line_text = raw_slice[pos..nl];
                if (line_text.len > 0 and line_text[line_text.len - 1] == '\r') {
                    line_text = line_text[0 .. line_text.len - 1];
                }
                pos = if (nl < raw_slice.len) nl + 1 else raw_slice.len;

                var excluded = false;
                for (task.effective_excludes) |ex_lit| {
                    if (ex_lit.len == 0) continue;
                    const ci = switch (parsed_case) {
                        .insensitive => true,
                        .sensitive => false,
                        .smart => !hasAsciiUpper(ex_lit),
                    };
                    if (if (ci) containsIgnoreCase(line_text, ex_lit) else (std.mem.indexOf(u8, line_text, ex_lit) != null)) {
                        excluded = true;
                        break;
                    }
                }
                if (!excluded) {
                    for (self.excludes_regexes) |*ex_re| {
                        if (ex_re.findWithScratch(line_text, 0, .leftmost_first, &regex_scratch) != null) {
                            excluded = true;
                            break;
                        }
                    }
                }

                var mask: u32 = 0;
                const m0 = switch (self.matcher.*) {
                    .literal => |*f| (f.find(line_text, 0, .leftmost_first) != null),
                    .multi => |*m| (m.find(line_text, 0, .leftmost_first) != null),
                    .regex => |*r| (r.findWithScratch(line_text, 0, .leftmost_first, &regex_scratch) != null),
                };
                if (m0) mask |= 1;

                for (task.effective_contains, 0..) |inc_lit, li| {
                    const bit_idx: u5 = @intCast(1 + li);
                    if (inc_lit.len == 0) {
                        mask |= (@as(u32, 1) << bit_idx);
                        continue;
                    }
                    const ci = switch (parsed_case) {
                        .insensitive => true,
                        .sensitive => false,
                        .smart => !hasAsciiUpper(inc_lit),
                    };
                    if (if (ci) containsIgnoreCase(line_text, inc_lit) else (std.mem.indexOf(u8, line_text, inc_lit) != null)) {
                        mask |= (@as(u32, 1) << bit_idx);
                    }
                }

                for (self.contains_regexes, 0..) |*inc_re, ri| {
                    const bit_idx: u5 = @intCast(1 + pos_lit_count + ri);
                    if (inc_re.findWithScratch(line_text, 0, .leftmost_first, &regex_scratch) != null) {
                        mask |= (@as(u32, 1) << bit_idx);
                    }
                }

                const matches_user_primary = if (self.swapped_primary_regex_first and self.contains_regexes.len > 0)
                    ((mask & (@as(u32, 1) << @intCast(1 + pos_lit_count))) != 0)
                else if (self.swapped_primary_finder) |*pf|
                    (pf.find(line_text, 0, .leftmost_first) != null)
                else
                    m0;

                lines.append(self.gpa, .{
                    .text = line_text,
                    .mask = mask,
                    .excluded = excluded,
                    .matches_user_primary = matches_user_primary,
                }) catch break;
            }

            const line_items = lines.items;
            if (line_items.len == 0) continue;

            var file_emitted: u64 = 0;
            var last_emitted_idx: ?usize = null;

            for (line_items, 0..) |li, idx| {
                if (li.excluded or li.mask == 0) continue;
                const w_start = idx -| block_radius;
                const w_end = @min(line_items.len, idx + block_radius + 1);

                var union_mask: u32 = 0;
                for (line_items[w_start..w_end]) |w_li| {
                    if (!w_li.excluded) {
                        union_mask |= w_li.mask;
                    }
                }
                if ((union_mask & required_mask) != required_mask) continue;

                // Prefer emitting anchor lines that either match at least 2 query terms (e.g. `pub(crate) async fn`)
                // or match the rarest term (`m0`) when no multi-term anchor was just emitted within 12 lines.
                const pop = @popCount(li.mask);
                const is_strong_anchor = (pop >= 2) or ((li.mask & 1) != 0 and total_preds == 2);
                if (!is_strong_anchor) continue;

                if (last_emitted_idx) |prev_idx| {
                    if (idx - prev_idx <= 4 and pop <= @popCount(line_items[prev_idx].mask)) {
                        continue;
                    }
                }
                last_emitted_idx = idx;

                const safe_text = file_api.sanitizeUtf8Truncated(self.job_arena, li.text, 4096) catch continue;
                const text_duped = if (safe_text.ptr == li.text.ptr)
                    (self.job_arena.dupe(u8, safe_text) catch continue)
                else
                    safe_text;

                var spans_list: std.ArrayList(HitSpan) = .empty;
                self.collectAllQueryTermSpans(task, text_duped, parsed_case, &spans_list);

                const col: u64 = if (spans_list.items.len > 0)
                    @intCast(spans_list.items[0].start + 1)
                else
                    1;

                fallback_hits.append(self.job_arena, .{
                    .file = self.job_arena.dupe(u8, task.rel_path) catch continue,
                    .line = @intCast(idx + 1),
                    .col = col,
                    .text = text_duped,
                    .prevText = null,
                    .nextText = null,
                    .replaced = null,
                    .isContext = false,
                    .byteOffset = null,
                    .spans = spans_list.items,
                }) catch break;

                file_emitted += 1;
                if (max_res > 0 and fallback_hits.items.len >= max_res) {
                    limit_hit = true;
                    break;
                }
            }

            if (file_emitted > 0) {
                matched_files_count += 1;
                task.emitted_in_file = file_emitted;
            }
            if (limit_hit) break;
        }

        if (fallback_hits.items.len == 0) return false;

        const total_emitted: u64 = @intCast(fallback_hits.items.len);
        self.files_matched.store(matched_files_count, .release);
        self.total_matches.store(total_emitted, .release);
        self.matched_lines.store(total_emitted, .release);
        self.hit_max_results.store(limit_hit, .release);
        self.nearby_used = true;

        self.flushItemsSliceToSender(fallback_hits.items);
        return true;
    }

    fn collectAllQueryTermSpans(
        self: *JobRunner,
        task: *const FileTask,
        text: []const u8,
        parsed_case: libwebgrep.CaseMode,
        spans_list: *std.ArrayList(HitSpan),
    ) void {
        const RawByteSpan = struct {
            start: usize,
            end: usize,
        };
        var raw_spans: std.ArrayList(RawByteSpan) = .empty;
        defer raw_spans.deinit(self.gpa);

        // 1. Primary matcher spans
        switch (self.matcher.*) {
            .literal => |*f| {
                var bpos: usize = 0;
                while (bpos <= text.len) {
                    const hit = f.find(text, bpos, .leftmost_first) orelse break;
                    if (hit.start < bpos or hit.end > text.len) break;
                    if (hit.end > hit.start) {
                        raw_spans.append(self.gpa, .{ .start = hit.start, .end = hit.end }) catch break;
                    }
                    if (hit.end <= bpos) break;
                    bpos = hit.end;
                }
            },
            .multi => |*m| {
                var bpos: usize = 0;
                while (bpos <= text.len) {
                    const hit = m.find(text, bpos, .leftmost_first) orelse break;
                    if (hit.start < bpos or hit.end > text.len) break;
                    if (hit.end > hit.start) {
                        raw_spans.append(self.gpa, .{ .start = hit.start, .end = hit.end }) catch break;
                    }
                    if (hit.end <= bpos) break;
                    bpos = hit.end;
                }
            },
            .regex => |*r| {
                var bpos: usize = 0;
                while (bpos <= text.len) {
                    const hit = r.findReadOnly(text, bpos, .leftmost_first) orelse break;
                    if (hit.start < bpos or hit.end > text.len) break;
                    if (hit.end > hit.start) {
                        raw_spans.append(self.gpa, .{ .start = hit.start, .end = hit.end }) catch break;
                    }
                    if (hit.end <= bpos) break;
                    bpos = hit.end;
                }
            },
        }

        // 2. Literal `effective_contains` spans
        for (task.effective_contains) |inc_lit| {
            if (inc_lit.len == 0) continue;
            var f = libwebgrep.Finder.init(inc_lit, EngineLimits.findOptions(parsed_case)) catch continue;
            var bpos: usize = 0;
            while (bpos <= text.len) {
                const hit = f.find(text, bpos, .leftmost_first) orelse break;
                if (hit.start < bpos or hit.end > text.len) break;
                if (hit.end > hit.start) {
                    raw_spans.append(self.gpa, .{ .start = hit.start, .end = hit.end }) catch break;
                }
                if (hit.end <= bpos) break;
                bpos = hit.end;
            }
        }

        // 3. Regex `contains_regexes` spans
        for (self.contains_regexes) |*inc_re| {
            var bpos: usize = 0;
            while (bpos <= text.len) {
                const hit = inc_re.findReadOnly(text, bpos, .leftmost_first) orelse break;
                if (hit.start < bpos or hit.end > text.len) break;
                if (hit.end > hit.start) {
                    raw_spans.append(self.gpa, .{ .start = hit.start, .end = hit.end }) catch break;
                }
                if (hit.end <= bpos) break;
                bpos = hit.end;
            }
        }

        if (raw_spans.items.len == 0) return;

        // Sort and merge overlapping byte spans
        const SortCtx = struct {
            pub fn lessThan(_: void, a: RawByteSpan, b: RawByteSpan) bool {
                if (a.start != b.start) return a.start < b.start;
                return a.end < b.end;
            }
        };
        std.mem.sort(RawByteSpan, raw_spans.items, {}, SortCtx.lessThan);

        var merged_end: usize = 0;
        for (raw_spans.items, 0..) |sp, i| {
            if (i == 0) {
                spans_list.append(self.job_arena, .{
                    .start = FileSink.utf8ByteToUtf16Offset(text, sp.start),
                    .end = FileSink.utf8ByteToUtf16Offset(text, sp.end),
                }) catch return;
                merged_end = sp.end;
            } else if (sp.start < merged_end) {
                if (sp.end > merged_end) {
                    merged_end = sp.end;
                    spans_list.items[spans_list.items.len - 1].end = FileSink.utf8ByteToUtf16Offset(text, merged_end);
                }
            } else {
                spans_list.append(self.job_arena, .{
                    .start = FileSink.utf8ByteToUtf16Offset(text, sp.start),
                    .end = FileSink.utf8ByteToUtf16Offset(text, sp.end),
                }) catch return;
                merged_end = sp.end;
            }
        }
    }
};

const WorkerContext = struct {
    runner: *JobRunner,
    batch_arena: *std.heap.ArenaAllocator,
    batch_items: std.ArrayList(HitItem) = .empty,
    scratch_pool: *libwebgrep.Scratch,
    time_regex_scratch: libwebgrep.RegexScratch,
    time_prefix_cache: time_parser.PrefixEpochCache = .{},
    last_flush_ts: std.Io.Timestamp,

    fn searchOneTask(self: *WorkerContext, task: *FileTask) void {
        if (self.runner.shouldStop()) return;

        const started_from_beginning = (task.resume_after_line == 0);
        task.paused_at_soft_quota = false;

        var opened_parent: ?std.Io.Dir = null;
        defer if (opened_parent) |*d| d.close(self.runner.io);

        const parent_dir: std.Io.Dir = if (task.parent_dir_path) |p| blk: {
            opened_parent = std.Io.Dir.cwd().openDir(self.runner.io, p, .{}) catch {
                self.runner.had_scan_error.store(true, .release);
                return;
            };
            break :blk opened_parent.?;
        } else self.runner.root_dir;

        const compression: libwebgrep.Compression = if (isSingleStreamCompressed(task.base_name))
            .auto
        else
            .none;

        const replacement: ?[]const u8 = if (self.runner.req.replacement) |r|
            (if (r.len > 0) r else null)
        else
            null;

        const parsed_case = parseCaseMode(self.runner.req.case);
        const is_case_insensitive = switch (parsed_case) {
            .insensitive => true,
            .sensitive => false,
            .smart => !hasAsciiUpper(self.runner.req.pattern),
        };

        // Strong Consistency Service Config:
        // Explicitly populate full EngineLimits budgets so `searchSourceSlice` / `resumeSourceSlice`
        // (which use `serviceConfig` under the hood) never fall back to the 16 MiB default cap!
        const effective_ctx = @min(self.runner.req.context, EngineLimits.max_context_lines);
        const cfg = libwebgrep.SearchConfig{
            .line_numbers = true,
            .encoding = .auto,
            .compression = compression,
            .max_compression_ratio = EngineLimits.max_compression_ratio,
            .whole_word = self.runner.req.wholeWord,
            .whole_line = self.runner.req.wholeLine,
            .invert = self.runner.req.invert,
            .contains = task.effective_contains,
            .excludes = task.effective_excludes,
            .filter_case_insensitive = is_case_insensitive,
            .filter_smart_case = (parsed_case == .smart),
            .contains_regexes = self.runner.contains_regexes,
            .excludes_regexes = self.runner.excludes_regexes,
            .replacement = replacement,
            .context = effective_ctx,
            .max_context_lines = EngineLimits.max_context_lines,
            .max_line_len = EngineLimits.max_line_len,
            .buffer_size = libwebgrep.SearchConfig.optimalBufferSize(self.runner.active_worker_count),
            .progress_interval = 512 * 1024,
            .max_source_bytes = EngineLimits.max_source_bytes,
            .max_request_bytes = EngineLimits.max_request_bytes,
            .max_output_bytes = EngineLimits.max_output_bytes,
            .time_budget_ns = EngineLimits.time_budget_ns,
            .max_decode_bytes = EngineLimits.max_decode_bytes,
            .max_decompressed_bytes = EngineLimits.max_decompressed_bytes,
            .max_before_bytes = EngineLimits.max_before_bytes,
            .max_queued_event_bytes = EngineLimits.max_queued_event_bytes,
            .allocator = self.runner.gpa,
            .decode_allocator = self.runner.gpa,
            .scratch_pool = self.scratch_pool,
            .cancel = self.runner.cancel_flag,
        };

        const fallback_ctx = time_parser.FallbackTimeContext.fromMtimeAndTz(task.mtime_ns, self.runner.tz_offset_min);

        var sink = FileSink{
            .worker = self,
            .task = task,
            .rel_path = task.rel_path,
            .source_id = task.source_id,
            .source_name = task.source_name,
            .case_insensitive = is_case_insensitive,
            .fallback_ctx = fallback_ctx,
        };

        if (task.isDocker()) {
            const task_is_mtime_summary_only_docker = self.runner.is_empty_text_time_browse and task.task_time_mode == .mtime;
            var docker_local_cfg = cfg;
            if (task_is_mtime_summary_only_docker) {
                docker_local_cfg.max_count = 1;
            }
            self.searchDockerTask(&sink, task, docker_local_cfg, task_is_mtime_summary_only_docker);
            return;
        }

        var hot_lease: ?search_cache.HotFileLease = null;
        if (self.runner.registry) |reg| {
            if (compression == .none and task.archive_format == null and task.file_size > 0) {
                hot_lease = reg.search_cache.acquireHotFileSlice(
                    self.runner.io,
                    task.rel_path,
                    task.mtime_ns,
                    task.file_size,
                    task.inode,
                    parent_dir,
                    task.open_sub_path,
                    search_cache.MAX_HOT_FILE_MAP_BYTES,
                );
            }
        }
        defer if (hot_lease) |lease| {
            self.runner.registry.?.search_cache.releaseHotFileSlice(self.runner.io, lease.slot_idx);
        };

        const has_time_filter = (self.runner.time_start_ns > 0 or self.runner.time_end_ns > 0);

        var opened_fallback_file: ?std.Io.File = null;
        defer if (opened_fallback_file) |*f| f.close(self.runner.io);

        var scoped_mm: ?std.Io.File.MemoryMap = null;
        defer if (scoped_mm) |*mm| mm.destroy(self.runner.io);

        const max_scoped_map_bytes = if (task.archive_format != null)
            EngineLimits.max_archive_slice_map_bytes
        else
            search_cache.MAX_HOT_FILE_MAP_BYTES;

        const maybe_mapped_slice: ?[]const u8 = if (hot_lease) |lease|
            lease.slice
        else if (compression == .none and task.file_size > 0 and task.file_size <= max_scoped_map_bytes) blk_scoped: {
            const f = parent_dir.openFile(self.runner.io, task.open_sub_path, .{ .allow_directory = false }) catch {
                self.runner.had_scan_error.store(true, .release);
                return;
            };
            opened_fallback_file = f;
            if (std.math.cast(usize, task.file_size)) |map_len| {
                if (map_len > 0) {
                    if (std.Io.File.MemoryMap.create(self.runner.io, f, .{
                        .len = map_len,
                        .protection = .{ .read = true, .write = false },
                        .populate = false,
                    })) |mm| {
                        scoped_mm = mm;
                        break :blk_scoped scoped_mm.?.memory[0..map_len];
                    } else |_| {}
                }
            }
            break :blk_scoped null;
        } else null;

        const task_is_mtime_summary_only = self.runner.is_empty_text_time_browse and task.task_time_mode == .mtime;
        var local_cfg = cfg;
        if (task_is_mtime_summary_only) {
            local_cfg.max_count = 1;
        }

        if (task.archive_format) |archive_fmt| {
            self.searchArchiveTask(&sink, task, archive_fmt, maybe_mapped_slice, parent_dir, &opened_fallback_file, local_cfg);
            return;
        }

        const maybe_res = if (maybe_mapped_slice) |mapped_slice| blk_mmap: {
            sink.full_mapped_slice = mapped_slice;
            var full_active_slice = mapped_slice;
            if (has_time_filter) {
                switch (task.task_time_mode) {
                    .mtime => {
                        sink.check_line_timestamps = false;
                        if (task.mtime_ns > 0) {
                            const mtime_u64: u64 = @intCast(@max(0, task.mtime_ns));
                            if ((self.runner.time_start_ns > 0 and mtime_u64 < self.runner.time_start_ns) or
                                (self.runner.time_end_ns > 0 and mtime_u64 > self.runner.time_end_ns))
                            {
                                full_active_slice = mapped_slice[0..0];
                            }
                        }
                    },
                    .content => {
                        const narrowed = time_parser.narrowSliceByTimeParser(
                            mapped_slice,
                            task.line_time_parser,
                            self.runner.time_start_ns,
                            self.runner.time_end_ns,
                            fallback_ctx,
                            &self.time_regex_scratch,
                            &self.time_prefix_cache,
                            5 * std.time.ns_per_s,
                        );
                        switch (narrowed.status) {
                            .no_timestamps => {
                                full_active_slice = mapped_slice[0..0];
                                sink.check_line_timestamps = false;
                                sink.file_has_timestamps = false;
                            },
                            .ordered_series => {
                                full_active_slice = narrowed.sub_slice;
                                sink.sub_start_offset = narrowed.sub_start;
                                sink.base_line_offset = narrowed.base_line_offset;
                                sink.check_line_timestamps = true;
                                sink.file_has_timestamps = true;
                            },
                            .unordered_has_ts => {
                                full_active_slice = mapped_slice;
                                sink.check_line_timestamps = true;
                                sink.file_has_timestamps = true;
                            },
                        }
                    },
                    .auto, .source => {
                        const narrowed = time_parser.narrowSliceByTimeParser(
                            mapped_slice,
                            task.line_time_parser,
                            self.runner.time_start_ns,
                            self.runner.time_end_ns,
                            fallback_ctx,
                            &self.time_regex_scratch,
                            &self.time_prefix_cache,
                            5 * std.time.ns_per_s,
                        );
                        switch (narrowed.status) {
                            .ordered_series => {
                                full_active_slice = narrowed.sub_slice;
                                sink.sub_start_offset = narrowed.sub_start;
                                sink.base_line_offset = narrowed.base_line_offset;
                                sink.check_line_timestamps = true;
                                sink.file_has_timestamps = true;
                            },
                            .unordered_has_ts => {
                                full_active_slice = mapped_slice;
                                sink.check_line_timestamps = true;
                                sink.file_has_timestamps = true;
                            },
                            .no_timestamps => {
                                sink.check_line_timestamps = false;
                                sink.file_has_timestamps = false;
                                if (task.mtime_ns > 0) {
                                    const mtime_u64: u64 = @intCast(@max(0, task.mtime_ns));
                                    if ((self.runner.time_start_ns > 0 and mtime_u64 < self.runner.time_start_ns) or
                                        (self.runner.time_end_ns > 0 and mtime_u64 > self.runner.time_end_ns))
                                    {
                                        full_active_slice = mapped_slice[0..0];
                                    }
                                }
                            },
                        }
                    },
                }
            }

            break :blk_mmap self.searchMappedSlice(&sink, task, full_active_slice, local_cfg);
        } else blk: {
            var file = if (opened_fallback_file) |f| f else parent_dir.openFile(self.runner.io, task.open_sub_path, .{ .allow_directory = false }) catch {
                self.runner.had_scan_error.store(true, .release);
                return;
            };
            if (opened_fallback_file == null) {
                opened_fallback_file = file;
            }

            if (has_time_filter) {
                if (task.task_time_mode == .mtime) {
                    sink.check_line_timestamps = false;
                    if (task.mtime_ns > 0) {
                        const mtime_u64: u64 = @intCast(@max(0, task.mtime_ns));
                        if ((self.runner.time_start_ns > 0 and mtime_u64 < self.runner.time_start_ns) or
                            (self.runner.time_end_ns > 0 and mtime_u64 > self.runner.time_end_ns))
                        {
                            break :blk (switch (self.runner.matcher.*) {
                                .literal => |*f| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", f, local_cfg),
                                .multi => |*m| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", m, local_cfg),
                                .regex => |*r| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", r, local_cfg),
                            } catch null);
                        }
                    }
                } else if (compression == .none) {
                    var peek_buf: [16 * 1024]u8 = undefined;
                    const peek_n = file.readPositionalAll(self.runner.io, &peek_buf, 0) catch 0;
                    var has_ts = false;
                    var pos: usize = 0;
                    var lines_checked: usize = 0;
                    while (pos < peek_n and lines_checked < 64) {
                        while (pos < peek_n and (peek_buf[pos] == '\n' or peek_buf[pos] == '\r')) : (pos += 1) {}
                        if (pos >= peek_n) break;
                        const nl = std.mem.indexOfScalarPos(u8, peek_buf[0..peek_n], pos, '\n') orelse peek_n;
                        const peek_line = peek_buf[pos..nl];
                        if (peek_line.len > 0) {
                            lines_checked += 1;
                            if (task.line_time_parser.parseLine(peek_line, fallback_ctx, &self.time_regex_scratch, &self.time_prefix_cache) != null) {
                                has_ts = true;
                                break;
                            }
                        }
                        pos = if (nl < peek_n) nl + 1 else peek_n;
                    }
                    sink.file_has_timestamps = has_ts;
                    if (task.task_time_mode == .content) {
                        sink.check_line_timestamps = true;
                        if (!has_ts and self.runner.req.pattern.len == 0) {
                            break :blk (switch (self.runner.matcher.*) {
                                .literal => |*f| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", f, local_cfg),
                                .multi => |*m| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", m, local_cfg),
                                .regex => |*r| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", r, local_cfg),
                            } catch null);
                        }
                    } else {
                        sink.check_line_timestamps = has_ts;
                        if (!has_ts and task.mtime_ns > 0) {
                            const mtime_u64: u64 = @intCast(@max(0, task.mtime_ns));
                            if ((self.runner.time_start_ns > 0 and mtime_u64 < self.runner.time_start_ns) or
                                (self.runner.time_end_ns > 0 and mtime_u64 > self.runner.time_end_ns))
                            {
                                break :blk (switch (self.runner.matcher.*) {
                                    .literal => |*f| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", f, local_cfg),
                                    .multi => |*m| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", m, local_cfg),
                                    .regex => |*r| libwebgrep.searchSourceSlice(FileSink, &sink, task.rel_path, "", r, local_cfg),
                                } catch null);
                            }
                        }
                    }
                } else {
                    sink.check_line_timestamps = true;
                    sink.file_has_timestamps = (task.task_time_mode == .content);
                }
            }

            var active_cfg = local_cfg;
            if (task.paused_result) |*prev| {
                active_cfg.resume_from = prev.resume_at orelse 0;
                active_cfg.continuation = &prev.resume_state;
            }

            if (compression == .none) {
                break :blk switch (self.runner.matcher.*) {
                    .literal => |*f| libwebgrep.searcher.searchFile(FileSink, self.runner.gpa, self.runner.io, &sink, file, task.rel_path, f, active_cfg),
                    .multi => |*m| libwebgrep.searcher.searchFile(FileSink, self.runner.gpa, self.runner.io, &sink, file, task.rel_path, m, active_cfg),
                    .regex => |*r| libwebgrep.searcher.searchFile(FileSink, self.runner.gpa, self.runner.io, &sink, file, task.rel_path, r, active_cfg),
                } catch null;
            }

            var fallback_buf: [65536]u8 = undefined;
            var file_reader = file.reader(self.runner.io, &fallback_buf);

            break :blk switch (self.runner.matcher.*) {
                .literal => |*f| libwebgrep.searchReader(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, f, active_cfg),
                .multi => |*m| libwebgrep.searchReader(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, m, active_cfg),
                .regex => |*r| libwebgrep.searchReader(FileSink, self.runner.gpa, &sink, &file_reader.interface, task.rel_path, r, active_cfg),
            } catch null;
        };

        if (!task.counted_file_searched) {
            task.counted_file_searched = true;
            _ = self.runner.files_searched.fetchAdd(1, .monotonic);
        }
        if (!task.counted_file_matched and (sink.file_had_match or task.emitted_in_file > 0)) {
            task.counted_file_matched = true;
            _ = self.runner.files_matched.fetchAdd(1, .monotonic);
        }

        var task_scanned_complete = false;
        if (maybe_res) |res| {
            if (res.paused) {
                task.paused_result = res;
            } else {
                task.paused_result = null;
            }
            const bytes = if (res.bytes_searched > 0) res.bytes_searched else res.bytes_read;
            if (bytes > task.phase_bytes) {
                _ = self.runner.bytes_searched.fetchAdd(bytes - task.phase_bytes, .monotonic);
                task.phase_bytes = bytes;
            }
            task_scanned_complete = (res.scanned_all or res.outcome == .binary_quit or task_is_mtime_summary_only) and res.soft_error == null and res.limit_hit == .none;
            if (!task_scanned_complete and !task.paused_at_soft_quota and !self.runner.shouldStop()) {
                self.runner.had_scan_error.store(true, .release);
            }
        } else {
            self.runner.had_scan_error.store(true, .release);
        }

        if (started_from_beginning and
            task_scanned_complete and
            !self.runner.shouldStop() and
            !task.paused_at_soft_quota and
            !sink.file_had_match and
            task.emitted_in_file == 0 and
            task.archive_format == null)
        {
            if (self.runner.registry) |reg| {
                const is_plain_literal = switch (self.runner.matcher.*) {
                    .literal => true,
                    else => false,
                };
                if (is_plain_literal and
                    self.runner.time_start_ns == 0 and
                    self.runner.time_end_ns == 0 and
                    std.mem.eql(u8, self.runner.req.mode, "literal") and
                    !self.runner.req.invert and
                    !self.runner.req.wholeWord and
                    !self.runner.req.wholeLine and
                    task.effective_contains.len == 0 and
                    task.effective_excludes.len == 0 and
                    self.runner.contains_regexes.len == 0 and
                    self.runner.excludes_regexes.len == 0)
                {
                    reg.search_cache.recordZeroHitFile(
                        self.runner.io,
                        task.rel_path,
                        task.mtime_ns,
                        task.file_size,
                        task.inode,
                        task.phase_bytes,
                        self.runner.req.pattern,
                        is_case_insensitive,
                    );
                }
            }
        }

        if (!self.runner.shouldStop()) {
            self.maybeFlushStreaming(true);
            self.runner.maybeSendProgress(0);
        }
    }

    fn searchDockerTask(
        self: *WorkerContext,
        sink: *FileSink,
        task: *FileTask,
        local_cfg: libwebgrep.SearchConfig,
        task_is_mtime_summary_only: bool,
    ) void {
        const has_time_filter = (self.runner.time_start_ns > 0 or self.runner.time_end_ns > 0);
        if (has_time_filter) {
            if (task.task_time_mode == .mtime) {
                sink.check_line_timestamps = false;
                sink.file_has_timestamps = false;
            } else {
                sink.check_line_timestamps = true;
                sink.file_has_timestamps = true;
            }
        }

        // Push `[since, until]` bounds down to `/containers/{id}/logs` ONLY when auto-detecting
        // RFC3339Nano content timestamps (matching frontend `/api/file?since=` so 1-based line numbers align 1:1).
        const can_push_time = has_time_filter and
            task.docker_allow_time_pushdown and
            task.task_time_mode != .mtime and
            task.line_time_parser.mode == .auto;
        const since_sec: ?u64 = if (can_push_time and self.runner.time_start_ns > 0) blk_s: {
            const s = (self.runner.time_start_ns / std.time.ns_per_s) -| 2;
            break :blk_s if (s > 0) s else null;
        } else null;
        const until_sec: ?u64 = if (can_push_time and self.runner.time_end_ns > 0)
            (self.runner.time_end_ns / std.time.ns_per_s) +| 2
        else
            null;

        var log_reader = docker_logs.DockerLogReader.create(
            self.runner.gpa,
            self.runner.io,
            task.docker_transport.?,
            task.docker_container_id,
            .{
                .since_sec = since_sec,
                .until_sec = until_sec,
                .max_line_len = EngineLimits.max_line_len,
                .cancel_flag = self.runner.cancel_flag,
                .stop_ctx = self.runner,
                .stop_fn = JobRunner.runnerShouldStopCallback,
            },
        ) catch |err| {
            if (err == error.ContainerNotFound or err == error.LogsUnsupportedByDriver) {
                if (!task.counted_file_searched) {
                    task.counted_file_searched = true;
                    _ = self.runner.files_searched.fetchAdd(1, .monotonic);
                }
                return;
            }
            if (err != error.Canceled and !self.runner.shouldStop()) {
                self.runner.had_scan_error.store(true, .release);
            }
            return;
        };
        defer log_reader.destroy();

        var docker_cfg = local_cfg;
        docker_cfg.compression = .none;

        const maybe_res: ?libwebgrep.Result = switch (self.runner.matcher.*) {
            .literal => |*f| libwebgrep.searchSource(FileSink, self.runner.gpa, sink, &log_reader.interface, task.rel_path, f, docker_cfg) catch null,
            .multi => |*m| libwebgrep.searchSource(FileSink, self.runner.gpa, sink, &log_reader.interface, task.rel_path, m, docker_cfg) catch null,
            .regex => |*r| libwebgrep.searchSource(FileSink, self.runner.gpa, sink, &log_reader.interface, task.rel_path, r, docker_cfg) catch null,
        };

        if (!task.counted_file_searched) {
            task.counted_file_searched = true;
            _ = self.runner.files_searched.fetchAdd(1, .monotonic);
        }
        if (!task.counted_file_matched and (sink.file_had_match or task.emitted_in_file > 0)) {
            task.counted_file_matched = true;
            _ = self.runner.files_matched.fetchAdd(1, .monotonic);
        }

        if (maybe_res) |res| {
            const bytes = if (res.bytes_searched > 0) res.bytes_searched else res.bytes_read;
            if (bytes > task.phase_bytes) {
                _ = self.runner.bytes_searched.fetchAdd(bytes - task.phase_bytes, .monotonic);
                task.phase_bytes = bytes;
            }
            const ok = (res.scanned_all or res.outcome == .binary_quit or task_is_mtime_summary_only) and
                res.soft_error == null and
                res.limit_hit == .none and
                !log_reader.had_error;
            if (!ok and !self.runner.shouldStop()) {
                self.runner.had_scan_error.store(true, .release);
            }
        } else if (!self.runner.shouldStop()) {
            self.runner.had_scan_error.store(true, .release);
        }

        if (!self.runner.shouldStop()) {
            self.maybeFlushStreaming(true);
            self.runner.maybeSendProgress(0);
        }
    }

    fn searchMappedSlice(
        self: *WorkerContext,
        sink: *FileSink,
        task: *FileTask,
        full_active_slice: []const u8,
        cfg: libwebgrep.SearchConfig,
    ) ?libwebgrep.Result {
        if (task.paused_result) |prev| {
            return (switch (self.runner.matcher.*) {
                .literal => |*f| libwebgrep.resumeSourceSlice(FileSink, sink, task.rel_path, full_active_slice, f, cfg, prev),
                .multi => |*m| libwebgrep.resumeSourceSlice(FileSink, sink, task.rel_path, full_active_slice, m, cfg, prev),
                .regex => |*r| libwebgrep.resumeSourceSlice(FileSink, sink, task.rel_path, full_active_slice, r, cfg, prev),
            } catch null);
        }
        return (switch (self.runner.matcher.*) {
            .literal => |*f| libwebgrep.searchSourceSlice(FileSink, sink, task.rel_path, full_active_slice, f, cfg),
            .multi => |*m| libwebgrep.searchSourceSlice(FileSink, sink, task.rel_path, full_active_slice, m, cfg),
            .regex => |*r| libwebgrep.searchSourceSlice(FileSink, sink, task.rel_path, full_active_slice, r, cfg),
        } catch null);
    }

    fn searchArchiveTask(
        self: *WorkerContext,
        sink: *FileSink,
        task: *FileTask,
        archive_fmt: libwebgrep.ArchiveFormat,
        maybe_mapped_slice: ?[]const u8,
        parent_dir: std.Io.Dir,
        opened_fallback_file: *?std.Io.File,
        cfg: libwebgrep.SearchConfig,
    ) void {
        if ((self.runner.time_start_ns > 0 or self.runner.time_end_ns > 0) and task.task_time_mode == .mtime) {
            if (task.mtime_ns > 0) {
                const mtime_u64: u64 = @intCast(@max(0, task.mtime_ns));
                if ((self.runner.time_start_ns > 0 and mtime_u64 < self.runner.time_start_ns) or
                    (self.runner.time_end_ns > 0 and mtime_u64 > self.runner.time_end_ns))
                {
                    if (!task.counted_file_searched) {
                        task.counted_file_searched = true;
                        _ = self.runner.files_searched.fetchAdd(1, .monotonic);
                    }
                    return;
                }
            }
        }

        var archive_search_cfg = cfg;
        archive_search_cfg.compression = .none;
        const has_time_filter = (self.runner.time_start_ns > 0 or self.runner.time_end_ns > 0);
        if (has_time_filter and task.task_time_mode != .mtime) {
            sink.check_line_timestamps = true;
            sink.file_has_timestamps = (task.task_time_mode == .content);
        }

        const tree_cfg = libwebgrep.TreeConfig{
            .search = archive_search_cfg,
            .archive = EngineLimits.archiveOptions(archive_fmt),
            .globs = self.runner.archiveEntryGlobs(task.rel_path, task.base_name),
            .iglob = true,
            .types = self.runner.types_include,
            .types_not = self.runner.types_exclude,
            .custom_types = self.runner.custom_types_table,
            .respect_gitignore = self.runner.req.respectIgnore,
            .respect_ignore = self.runner.req.respectIgnore,
            .respect_rgignore = self.runner.req.respectIgnore,
            .hidden = self.runner.req.hidden,
            .max_entries = EngineLimits.max_archive_entries,
            .max_filesize = EngineLimits.max_archive_entry_bytes,
            .max_glob_rules = EngineLimits.max_glob_rules,
            .max_glob_rule_len = EngineLimits.max_glob_rule_len,
            .max_glob_brace_depth = EngineLimits.max_glob_brace_depth,
        };

        const maybe_summary: ?libwebgrep.Summary = if (maybe_mapped_slice) |slice| blk_slice: {
            break :blk_slice (switch (self.runner.matcher.*) {
                .literal => |*f| libwebgrep.searchArchiveSlice(FileSink, self.runner.gpa, self.runner.io, sink, slice, f, tree_cfg),
                .multi => |*m| libwebgrep.searchArchiveSlice(FileSink, self.runner.gpa, self.runner.io, sink, slice, m, tree_cfg),
                .regex => |*r| libwebgrep.searchArchiveSlice(FileSink, self.runner.gpa, self.runner.io, sink, slice, r, tree_cfg),
            } catch null);
        } else blk_stream: {
            var file = if (opened_fallback_file.*) |f| f else parent_dir.openFile(self.runner.io, task.open_sub_path, .{ .allow_directory = false }) catch {
                self.runner.had_scan_error.store(true, .release);
                return;
            };
            if (opened_fallback_file.* == null) {
                opened_fallback_file.* = file;
            }
            var archive_buf: [65536]u8 = undefined;
            var file_reader = file.reader(self.runner.io, &archive_buf);
            break :blk_stream (switch (self.runner.matcher.*) {
                .literal => |*f| libwebgrep.searchArchive(FileSink, self.runner.gpa, self.runner.io, sink, &file_reader.interface, f, tree_cfg),
                .multi => |*m| libwebgrep.searchArchive(FileSink, self.runner.gpa, self.runner.io, sink, &file_reader.interface, m, tree_cfg),
                .regex => |*r| libwebgrep.searchArchive(FileSink, self.runner.gpa, self.runner.io, sink, &file_reader.interface, r, tree_cfg),
            } catch null);
        };

        if (!task.counted_file_searched) {
            task.counted_file_searched = true;
            _ = self.runner.files_searched.fetchAdd(1, .monotonic);
        }
        if (!task.counted_file_matched and (sink.file_had_match or task.emitted_in_file > 0)) {
            task.counted_file_matched = true;
            _ = self.runner.files_matched.fetchAdd(1, .monotonic);
        }

        if (maybe_summary) |summary| {
            const bytes = if (summary.bytes_searched > 0) summary.bytes_searched else task.file_size;
            if (bytes > task.phase_bytes) {
                _ = self.runner.bytes_searched.fetchAdd(bytes - task.phase_bytes, .monotonic);
                task.phase_bytes = bytes;
            }
            if (summary.sources_failed > 0 and !self.runner.shouldStop()) {
                self.runner.had_scan_error.store(true, .release);
            } else if (!self.runner.shouldStop() and
                !sink.file_had_match and
                task.emitted_in_file == 0 and
                self.runner.isArchiveUnrestricted())
            {
                if (self.runner.registry) |reg| {
                    const is_plain_literal = switch (self.runner.matcher.*) {
                        .literal => true,
                        else => false,
                    };
                    if (is_plain_literal and
                        self.runner.time_start_ns == 0 and
                        self.runner.time_end_ns == 0 and
                        std.mem.eql(u8, self.runner.req.mode, "literal") and
                        !self.runner.req.invert and
                        !self.runner.req.wholeWord and
                        !self.runner.req.wholeLine and
                        task.effective_contains.len == 0 and
                        task.effective_excludes.len == 0 and
                        self.runner.contains_regexes.len == 0 and
                        self.runner.excludes_regexes.len == 0)
                    {
                        reg.search_cache.recordZeroHitFile(
                            self.runner.io,
                            task.rel_path,
                            task.mtime_ns,
                            task.file_size,
                            task.inode,
                            task.phase_bytes,
                            self.runner.req.pattern,
                            sink.case_insensitive,
                        );
                    }
                }
            }
        } else if (!self.runner.shouldStop()) {
            self.runner.had_scan_error.store(true, .release);
        }

        if (!self.runner.shouldStop()) {
            self.maybeFlushStreaming(true);
            self.runner.maybeSendProgress(0);
        }
    }

    /// Universal real-time streaming flush rule (identical across literal, multi, and regex modes):
    /// 1. First screen batch (`batches_flushed == 0`): flush immediately on the very first match (`count >= 1`).
    /// 2. Early batches (`batches_flushed < 4`): flush at 32 items or 16ms.
    /// 3. Mid batches (`batches_flushed < 12`): flush at 128 items or 25ms.
    /// 4. Steady high-volume streaming (`batches_flushed >= 12`): flush at 512 items or 35ms (cuts 20k-record frames by 7x).
    fn maybeFlushStreaming(self: *WorkerContext, force_time_check: bool) void {
        const count = self.batch_items.items.len;
        if (count == 0 or self.runner.send_failed.load(.acquire)) return;

        const flushed_so_far = self.runner.batches_flushed.load(.monotonic);
        if (flushed_so_far == 0) {
            _ = self.runner.batches_flushed.fetchAdd(1, .monotonic);
            self.flushBatch() catch {
                self.runner.send_failed.store(true, .release);
            };
            return;
        }

        const item_cap: usize = if (flushed_so_far < 4)
            32
        else if (flushed_so_far < 12)
            128
        else
            512;
        if (count >= item_cap) {
            _ = self.runner.batches_flushed.fetchAdd(1, .monotonic);
            self.flushBatch() catch {
                self.runner.send_failed.store(true, .release);
            };
            return;
        }

        if (force_time_check or flushed_so_far < 4 or count >= 16) {
            const min_ns: i64 = if (flushed_so_far < 4)
                16 * std.time.ns_per_ms
            else if (flushed_so_far < 12)
                25 * std.time.ns_per_ms
            else
                35 * std.time.ns_per_ms;
            const elapsed_ns = self.last_flush_ts.untilNow(self.runner.io, .awake).toNanoseconds();
            if (elapsed_ns >= min_ns) {
                _ = self.runner.batches_flushed.fetchAdd(1, .monotonic);
                self.flushBatch() catch {
                    self.runner.send_failed.store(true, .release);
                };
            }
        }
    }

    fn flushBatch(self: *WorkerContext) !void {
        if (self.batch_items.items.len == 0) return;
        defer {
            self.batch_items.clearRetainingCapacity();
            _ = self.batch_arena.reset(.retain_capacity);
            self.last_flush_ts = std.Io.Clock.awake.now(self.runner.io);
        }
        if (self.runner.send_failed.load(.acquire)) return;

        if (self.runner.registry != null) {
            self.runner.collected_hits_mutex.lockUncancelable(self.runner.io);
            defer self.runner.collected_hits_mutex.unlock(self.runner.io);
            if (!self.runner.collected_hits_overflow) {
                if (self.runner.collected_hits.items.len + self.batch_items.items.len > search_cache.MAX_ITEMS_PER_ENTRY) {
                    self.runner.collected_hits_overflow = true;
                } else {
                    const j_arena = self.runner.job_arena;
                    for (self.batch_items.items) |it| {
                        const spans_dup = j_arena.dupe(HitSpan, it.spans) catch {
                            self.runner.collected_hits_overflow = true;
                            break;
                        };
                        const file_dup = j_arena.dupe(u8, it.file) catch {
                            self.runner.collected_hits_overflow = true;
                            break;
                        };
                        const text_dup = j_arena.dupe(u8, it.text) catch {
                            self.runner.collected_hits_overflow = true;
                            break;
                        };
                        const prev_dup = if (it.prevText) |pt| (j_arena.dupe(u8, pt) catch null) else null;
                        const next_dup = if (it.nextText) |nt| (j_arena.dupe(u8, nt) catch null) else null;
                        const rep_dup = if (it.replaced) |r| (j_arena.dupe(u8, r) catch null) else null;
                        self.runner.collected_hits.append(j_arena, .{
                            .file = file_dup,
                            .line = it.line,
                            .col = it.col,
                            .text = text_dup,
                            .prevText = prev_dup,
                            .nextText = next_dup,
                            .replaced = rep_dup,
                            .isContext = it.isContext,
                            .byteOffset = it.byteOffset,
                            .spans = spans_dup,
                        }) catch {
                            self.runner.collected_hits_overflow = true;
                            break;
                        };
                    }
                }
            }
        }

        const hits_json = try file_api.stringifyAlloc(self.runner.gpa, HitsFrame{
            .id = self.runner.req.id,
            .items = self.batch_items.items,
        });
        defer self.runner.gpa.free(hits_json);

        self.runner.sender.send(hits_json) catch {
            self.runner.send_failed.store(true, .release);
        };
    }
};

const FileSink = struct {
    worker: *WorkerContext,
    task: *FileTask,
    rel_path: []const u8,
    source_id: []const u8 = "",
    source_name: []const u8 = "",
    current_archive_entry: []const u8 = "",
    case_insensitive: bool = true,
    file_had_match: bool = false,
    base_line_offset: u64 = 0,
    sub_start_offset: usize = 0,
    full_mapped_slice: ?[]const u8 = null,
    check_line_timestamps: bool = false,
    file_has_timestamps: bool = false,
    fallback_ctx: time_parser.FallbackTimeContext = .{},
    has_last_line_ts: bool = false,
    last_line_ns: u64 = 0,

    pub fn control(self: *const FileSink) libwebgrep.Flow {
        return if (self.task.paused_at_soft_quota) .pause else .stop;
    }

    fn toLineEvent(self: *FileSink, line: libwebgrep.Line) libwebgrep.LineEvent {
        const u16_column = if (line.matches.len > 0)
            @as(u64, line.matches[0].u16_start) + 1
        else
            line.u16_column;
        return .{
            .source_id = if (self.current_archive_entry.len > 0) self.current_archive_entry else self.rel_path,
            .line_number = line.number orelse 0,
            .column = line.column,
            .u16_column = u16_column,
            .absolute_offset = line.offset,
            .raw_offset = line.raw_offset,
            .bytes = line.bytes,
            .text = if (line.text.len == 0) line.bytes else line.text,
            .raw = if (line.raw.len == 0) line.bytes else line.raw,
            .replaced = line.replaced,
            .matches = line.matches,
            .truncated = line.truncated,
            .line_len = line.line_len,
            .window_start = line.window_start,
            .binary_status = line.binary_status,
        };
    }

    pub fn matched(self: *FileSink, line: libwebgrep.Line) bool {
        return self.event(.{ .match = self.toLineEvent(line) }) == .cont;
    }

    pub fn context(self: *FileSink, line: libwebgrep.Line) bool {
        return self.event(.{ .context = self.toLineEvent(line) }) == .cont;
    }

    pub fn progress(self: *FileSink, bytes_searched: u64, match_count: u64, matched_lines: u64) bool {
        return self.event(.{ .progress = .{
            .source_id = self.rel_path,
            .bytes_searched = bytes_searched,
            .matches = match_count,
            .matched_lines = matched_lines,
        } }) == .cont;
    }

    pub fn event(self: *FileSink, ev: libwebgrep.Event) libwebgrep.Flow {
        const runner = self.worker.runner;
        if (runner.shouldStop()) return .stop;

        const is_archive = (self.task.archive_format != null);

        switch (ev) {
            .begin => |b| {
                self.last_line_ns = 0;
                self.has_last_line_ts = false;
                if (is_archive) {
                    self.current_archive_entry = b.source_id;
                }
                return .cont;
            },
            .match => |line| {
                const raw_line_no = if (line.line_number > 0) line.line_number else 1;
                const line_no = raw_line_no + self.base_line_offset;
                if (!is_archive and line_no <= self.task.resume_after_line) {
                    return .cont;
                }

                if (is_archive) {
                    const entry_path = if (line.source_id.len > 0) line.source_id else self.current_archive_entry;
                    if (!runner.archiveEntryMatchesPathGlobs(self.rel_path, self.task.base_name, entry_path)) {
                        return .cont;
                    }
                }

                if ((runner.time_start_ns > 0 or runner.time_end_ns > 0) and self.check_line_timestamps) {
                    const raw_text = if (line.text.len > 0) line.text else line.bytes;
                    var maybe_line_ns = self.task.line_time_parser.parseLine(
                        raw_text,
                        self.fallback_ctx,
                        &self.worker.time_regex_scratch,
                        &self.worker.time_prefix_cache,
                    );
                    if (maybe_line_ns == null and !is_archive) {
                        if (self.full_mapped_slice) |mapped| {
                            const rel_off: usize = @intCast(@min(line.absolute_offset, mapped.len -| self.sub_start_offset));
                            const abs_pos = self.sub_start_offset + rel_off;
                            const line_start = time_parser.findLineStartAtOrBefore(mapped, @min(abs_pos, mapped.len));
                            maybe_line_ns = time_parser.findLineTimestampWithLookbehind(
                                mapped,
                                line_start,
                                self.task.line_time_parser,
                                self.fallback_ctx,
                                &self.worker.time_regex_scratch,
                                &self.worker.time_prefix_cache,
                            );
                        }
                    }
                    if (maybe_line_ns == null and self.has_last_line_ts and time_parser.isLikelyContinuationLine(raw_text)) {
                        maybe_line_ns = self.last_line_ns;
                    }
                    if (maybe_line_ns) |line_ns| {
                        self.last_line_ns = line_ns;
                        self.has_last_line_ts = true;
                        if (runner.time_start_ns > 0 and line_ns < runner.time_start_ns) return .cont;
                        if (runner.time_end_ns > 0 and line_ns > runner.time_end_ns) return .cont;
                    } else if (self.task.task_time_mode == .content or self.file_has_timestamps) {
                        return .cont;
                    } else if (self.task.mtime_ns > 0) {
                        const mtime_u64: u64 = @intCast(@max(0, self.task.mtime_ns));
                        if (runner.time_start_ns > 0 and mtime_u64 < runner.time_start_ns) return .cont;
                        if (runner.time_end_ns > 0 and mtime_u64 > runner.time_end_ns) return .cont;
                    }
                }

                const max_res = runner.req.maxResults;
                if (max_res > 0 and runner.total_matches.load(.monotonic) >= max_res) {
                    runner.hit_max_results.store(true, .release);
                    return .stop;
                }

                const prev_total = runner.total_matches.fetchAdd(1, .monotonic);
                if (max_res > 0 and prev_total >= max_res) {
                    _ = runner.total_matches.fetchSub(1, .monotonic);
                    runner.hit_max_results.store(true, .release);
                    return .stop;
                }

                self.file_had_match = true;
                self.task.emitted_in_file += 1;
                if (!is_archive) {
                    self.task.resume_after_line = line_no;
                }
                const emitted_now = self.task.emitted_in_file;
                _ = runner.matched_lines.fetchAdd(1, .monotonic);

                var adjusted_line = line;
                adjusted_line.line_number = line_no;
                self.appendLineEvent(adjusted_line, false, 0) catch {
                    return .stop;
                };

                self.worker.maybeFlushStreaming(false);
                if (runner.send_failed.load(.acquire)) return .stop;

                if (max_res > 0 and prev_total + 1 >= max_res) {
                    runner.hit_max_results.store(true, .release);
                    return .stop;
                }

                if (!is_archive and !self.task.isDocker() and self.task.soft_quota > 0 and emitted_now >= self.task.soft_quota) {
                    self.task.paused_at_soft_quota = true;
                    return .pause;
                }
                return .cont;
            },
            .context => |line| {
                const raw_line_no = if (line.line_number > 0) line.line_number else 1;
                const line_no = raw_line_no + self.base_line_offset;
                if (!is_archive and line_no <= self.task.resume_after_line) {
                    return .cont;
                }
                if (is_archive) {
                    const entry_path = if (line.source_id.len > 0) line.source_id else self.current_archive_entry;
                    if (!runner.archiveEntryMatchesPathGlobs(self.rel_path, self.task.base_name, entry_path)) {
                        return .cont;
                    }
                }
                var adjusted_line = line;
                adjusted_line.line_number = line_no;
                self.appendLineEvent(adjusted_line, true, 0) catch {
                    return .stop;
                };
                self.worker.maybeFlushStreaming(false);
                if (runner.send_failed.load(.acquire)) return .stop;
                return .cont;
            },
            .progress => |prog| {
                if (!is_archive and prog.bytes_searched > self.task.phase_bytes) {
                    _ = runner.bytes_searched.fetchAdd(prog.bytes_searched - self.task.phase_bytes, .monotonic);
                    self.task.phase_bytes = prog.bytes_searched;
                }
                self.worker.maybeFlushStreaming(true);
                runner.maybeSendProgress(0);
                return if (runner.shouldStop()) .stop else .cont;
            },
            else => return .cont,
        }
    }

    fn appendLineEvent(self: *FileSink, line: libwebgrep.LineEvent, is_context: bool, max_spans: usize) !void {
        const arena = self.worker.batch_arena.allocator();
        const is_archive = (self.task.archive_format != null);
        const file_duped = if (is_archive) blk_vpath: {
            const raw_entry = if (line.source_id.len > 0 and !std.mem.eql(u8, line.source_id, self.rel_path))
                line.source_id
            else
                self.current_archive_entry;
            const entry_path = std.mem.trimStart(u8, raw_entry, "./");
            if (entry_path.len > 0) {
                break :blk_vpath try formatArchiveVirtualPathAlloc(arena, self.rel_path, entry_path);
            }
            break :blk_vpath try arena.dupe(u8, self.rel_path);
        } else try arena.dupe(u8, self.rel_path);

        const raw_text = if (line.text.len > 0) line.text else line.bytes;
        const safe_text = try file_api.sanitizeUtf8Truncated(arena, raw_text, 4096);
        if (raw_text.len > 4096 or line.truncated or safe_text.ptr != raw_text.ptr) {
            self.worker.runner.had_non_exact_line.store(true, .release);
        }
        const text_duped = if (safe_text.ptr == raw_text.ptr)
            try arena.dupe(u8, safe_text)
        else
            safe_text;

        const replaced_duped: ?[]const u8 = if (line.replaced) |rep| blk: {
            const safe_rep = try file_api.sanitizeUtf8Truncated(arena, rep, 1024);
            break :blk if (safe_rep.ptr == rep.ptr) try arena.dupe(u8, safe_rep) else safe_rep;
        } else null;

        var spans_list: std.ArrayList(HitSpan) = .empty;
        const runner = self.worker.runner;
        if (!is_context) {
            if (runner.swapped_primary_regex_first and runner.contains_regexes.len > 0) {
                const primary_re = &runner.contains_regexes[0];
                var bpos: usize = 0;
                while (bpos <= text_duped.len) {
                    const hit = primary_re.findReadOnly(text_duped, bpos, .leftmost_first) orelse break;
                    if (hit.start < bpos or hit.end > text_duped.len) break;
                    if (hit.end > hit.start) {
                        try spans_list.append(arena, .{
                            .start = utf8ByteToUtf16Offset(text_duped, hit.start),
                            .end = utf8ByteToUtf16Offset(text_duped, hit.end),
                        });
                    }
                    if (hit.end <= bpos) break;
                    bpos = hit.end;
                }
            } else if (runner.swapped_primary_finder) |*pf| {
                var bpos: usize = 0;
                while (bpos <= text_duped.len) {
                    const hit = pf.find(text_duped, bpos, .leftmost_first) orelse break;
                    if (hit.start < bpos or hit.end > text_duped.len) break;
                    if (hit.end > hit.start) {
                        try spans_list.append(arena, .{
                            .start = utf8ByteToUtf16Offset(text_duped, hit.start),
                            .end = utf8ByteToUtf16Offset(text_duped, hit.end),
                        });
                    }
                    if (hit.end <= bpos) break;
                    bpos = hit.end;
                }
            } else if (line.matches.len > 0) {
                const span_count = if (max_spans > 0) @min(line.matches.len, max_spans) else line.matches.len;
                try spans_list.ensureTotalCapacity(arena, span_count);
                for (line.matches[0..span_count]) |sp| {
                    spans_list.appendAssumeCapacity(.{
                        .start = sp.u16_start,
                        .end = sp.u16_end,
                    });
                }
            }
        }

        const col: u64 = if (spans_list.items.len > 0)
            @intCast(spans_list.items[0].start + 1)
        else
            line.u16_column orelse line.column orelse 1;

        const hit_byte_offset: ?u64 = if (!is_archive and !self.task.isDocker() and file_api.detectCompression(self.task.base_name) == null)
            @as(u64, self.sub_start_offset) +| line.raw_offset
        else
            null;

        try self.worker.batch_items.append(self.worker.runner.gpa, .{
            .file = file_duped,
            .line = if (line.line_number > 0) line.line_number else 1,
            .col = col,
            .text = text_duped,
            .prevText = null,
            .nextText = null,
            .replaced = replaced_duped,
            .isContext = is_context,
            .byteOffset = hit_byte_offset,
            .spans = spans_list.items,
        });
    }

    fn utf8ByteToUtf16Offset(text: []const u8, byte_idx: usize) usize {
        const limit = @min(byte_idx, text.len);
        var u16_pos: usize = 0;
        var i: usize = 0;
        while (i < limit) {
            const b = text[i];
            if (b < 0x80) {
                u16_pos += 1;
                i += 1;
            } else if (b < 0xE0) {
                u16_pos += 1;
                i += @min(2, limit - i);
            } else if (b < 0xF0) {
                u16_pos += 1;
                i += @min(3, limit - i);
            } else {
                u16_pos += 2;
                i += @min(4, limit - i);
            }
        }
        return u16_pos;
    }
};

test "search_job literal, multi, regex, and replacement over root directory" {
    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        frames: std.ArrayList([]u8) = .empty,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const copy = try self.allocator.dupe(u8, json_text);
            try self.frames.append(self.allocator, copy);
        }

        fn deinit(self: *@This()) void {
            for (self.frames.items) |f| self.allocator.free(f);
            self.frames.deinit(self.allocator);
        }
    };

    var collector = Collector{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    defer collector.deinit();

    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{ .iterate = true });
    defer root_dir.close(std.testing.io);

    var cancel = std.atomic.Value(bool).init(false);

    try executeSearch(
        std.testing.allocator,
        std.testing.io,
        root_dir,
        .{
            .id = 7,
            .pattern = "sanitizeRelPath",
            .mode = "literal",
            .paths = &.{"src"},
            .types = &.{"zig"},
        },
        &cancel,
        .{ .ctx = &collector, .sendFn = Collector.send },
    );

    try std.testing.expect(collector.frames.items.len >= 2);
    // First frame should be hits, last frame should be done
    try std.testing.expect(std.mem.indexOf(u8, collector.frames.items[0], "\"type\":\"hits\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, collector.frames.items[collector.frames.items.len - 1], "\"type\":\"done\"") != null);
}

test "matchesProjectScopeToken only matches project name or UUID id" {
    const src_id = "550e8400-e29b-41d4-a716-446655440000";
    const src_name = "webgrep";

    try std.testing.expect(JobRunner.matchesProjectScopeToken(src_id, src_name, "webgrep"));
    try std.testing.expect(JobRunner.matchesProjectScopeToken(src_id, src_name, "WEBGREP"));
    try std.testing.expect(JobRunner.matchesProjectScopeToken(src_id, src_name, src_id));
    try std.testing.expect(!JobRunner.matchesProjectScopeToken(src_id, src_name, "libwebgrep"));
    try std.testing.expect(!JobRunner.matchesProjectScopeToken(src_id, src_name, "webgrep/src/main.zig"));
}

test "progressive search order commutativity: regex+literal == literal+regex and case-insensitive contains" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var root_dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer root_dir.close(io);

    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Regex first ("pub\\s+fn"), Literal second ("executesearch")
    var c1 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 1,
        .pattern = "pub\\s+fn",
        .mode = "regex",
        .case = "insensitive",
        .contains = &.{"executesearch"},
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &c1, .sendFn = Collector.send });

    // 2. Literal first ("executesearch"), Regex second ("pub\\s+fn")
    var c2 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 2,
        .pattern = "executesearch",
        .mode = "regex",
        .case = "insensitive",
        .contains = &.{"pub\\s+fn"},
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &c2, .sendFn = Collector.send });

    try std.testing.expect(c1.matched_lines > 0);
    try std.testing.expectEqual(c1.matched_lines, c2.matched_lines);

    // 3. Mixed multiple regexes + multiple literals + regex/literal excludes in 4 permutations (with smart case)
    var m1 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 3,
        .pattern = "pub\\s+fn",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "With\\w+", "executesearch", "WithRegistry(" },
        .excludes = &.{ "nonexistent_\\d+", "never_match_xyz" },
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &m1, .sendFn = Collector.send });

    var m2 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 4,
        .pattern = "With\\w+",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "executesearch", "pub\\s+fn", "WithRegistry(" },
        .excludes = &.{ "never_match_xyz", "nonexistent_\\d+" },
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &m2, .sendFn = Collector.send });

    var m3 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 5,
        .pattern = "executesearch",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "WithRegistry(", "With\\w+", "pub\\s+fn" },
        .excludes = &.{ "nonexistent_\\d+", "never_match_xyz" },
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &m3, .sendFn = Collector.send });

    var m4 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 6,
        .pattern = "WithRegistry(",
        .mode = "regex",
        .case = "smart",
        .contains = &.{ "executesearch", "With\\w+", "pub\\s+fn" },
        .excludes = &.{ "never_match_xyz", "nonexistent_\\d+" },
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &m4, .sendFn = Collector.send });

    try std.testing.expect(m1.matched_lines > 0);
    try std.testing.expectEqual(m1.matched_lines, m2.matched_lines);
    try std.testing.expectEqual(m1.matched_lines, m3.matched_lines);
    try std.testing.expectEqual(m1.matched_lines, m4.matched_lines);

    // 4. Scoped `$r(xxxxxxx)` syntax in `literal` mode, mixed with literals (including unescaped parens) and context=2
    var s1 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 7,
        .pattern = "$r(pub\\s+fn)",
        .mode = "literal",
        .case = "smart",
        .context = 2,
        .contains = &.{ "WithRegistry(", "$r(With\\w+)", "executesearch" },
        .excludes = &.{"$r(nonexistent_\\d+)"},
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &s1, .sendFn = Collector.send });

    var s2 = Collector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, root_dir, .{
        .id = 8,
        .pattern = "WithRegistry(",
        .mode = "literal",
        .case = "smart",
        .context = 2,
        .contains = &.{ "$r(pub\\s+fn)", "executesearch", "$r(With\\w+)" },
        .excludes = &.{"$r(nonexistent_\\d+)"},
        .paths = &.{"src/search_job.zig"},
    }, &cancel, .{ .ctx = &s2, .sendFn = Collector.send });

    try std.testing.expectEqual(m1.matched_lines, s1.matched_lines);
    try std.testing.expectEqual(s1.matched_lines, s2.matched_lines);
}

test "heat-weighted elastic water-filling: single file gets full maxResults and hotter file gets more quota" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    try tmp.dir.createDirPath(io, "logs");

    // Create 3 files: cold.log (200 matches), hot.log (200 matches), empty.log (0 matches)
    {
        var f_cold = try tmp.dir.createFile(io, "logs/cold.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_cold.writer(io, &w_buf);
        for (0..200) |i| {
            try fw.interface.print("record={d} tag=COMMON_HIT only_in_cold\n", .{i});
        }
        try fw.interface.flush();
        f_cold.close(io);
    }
    {
        var f_hot = try tmp.dir.createFile(io, "logs/hot.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_hot.writer(io, &w_buf);
        for (0..200) |i| {
            try fw.interface.print("record={d} tag=COMMON_HIT only_in_hot\n", .{i});
        }
        try fw.interface.flush();
        f_hot.close(io);
    }
    {
        var f_empty = try tmp.dir.createFile(io, "logs/empty.log", .{ .truncate = true });
        var w_buf: [256]u8 = undefined;
        var fw = f_empty.writer(io, &w_buf);
        try fw.interface.writeAll("unrelated line\n");
        try fw.interface.flush();
        f_empty.close(io);
    }

    const logs_dir_path = try std.fmt.allocPrint(arena, "{s}/logs", .{tmp_path});
    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "logs",
        .config = .{ .path = logs_dir_path },
        .enabled = true,
    });

    // Boost access heat of logs/hot.log significantly
    reg.recordFileHeat(io, "logs/hot.log", 1200);

    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        hot_hits: usize = 0,
        cold_hits: usize = 0,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);

            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                for (parsed.value.items) |it| {
                    if (std.mem.eql(u8, it.file, "logs/hot.log")) self.hot_hits += 1;
                    if (std.mem.eql(u8, it.file, "logs/cold.log")) self.cold_hits += 1;
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // Case 1: Only 1 file (`only_in_cold`) matches among 3 files, with maxResults = 150.
    // Even though initial Phase 1 soft quota is < 150, Phase 2 water-filling gives it all 150!
    var c_single = Collector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 10,
        .pattern = "only_in_cold",
        .maxResults = 150,
    }, &cancel, .{ .ctx = &c_single, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 150), c_single.matched_lines);
    try std.testing.expectEqual(@as(usize, 150), c_single.cold_hits);

    // Case 2: Both hot.log and cold.log match `COMMON_HIT`, with maxResults = 120.
    // hot.log (higher heat score) receives strictly more quota than cold.log, and both > 0, summing to 120!
    var c_both = Collector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 11,
        .pattern = "COMMON_HIT",
        .maxResults = 120,
    }, &cancel, .{ .ctx = &c_both, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 120), c_both.matched_lines);
    try std.testing.expectEqual(@as(usize, 120), c_both.hot_hits + c_both.cold_hits);
    try std.testing.expect(c_both.hot_hits > c_both.cold_hits);
    try std.testing.expect(c_both.cold_hits > 0);
}

test "multi-tier millisecond search cache: L1 exact, L2 progressive superset, L3 negative file pruning, and mtime invalidation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    try tmp.dir.createDirPath(io, "svc");
    {
        var f_orders = try tmp.dir.createFile(io, "svc/orders.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_orders.writer(io, &w_buf);
        for (0..50) |i| {
            const status = if (i % 2 == 0) "FULFILLED" else "CANCELLED";
            const region = if (i % 5 == 0) "APAC" else "EMEA";
            try fw.interface.print("order=ORD-2026-{d} status={s} region={s}\n", .{ i, status, region });
        }
        try fw.interface.flush();
        f_orders.close(io);
    }
    {
        var f_audit = try tmp.dir.createFile(io, "svc/audit.log", .{ .truncate = true });
        var w_buf: [4096]u8 = undefined;
        var fw = f_audit.writer(io, &w_buf);
        for (0..50) |i| {
            try fw.interface.print("audit=AUD-{d} action=LOGIN user=admin\n", .{i});
        }
        try fw.interface.flush();
        f_audit.close(io);
    }

    const svc_dir_path = try std.fmt.allocPrint(arena, "{s}/svc", .{tmp_path});
    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "svc",
        .config = .{ .path = svc_dir_path },
        .enabled = true,
    });

    const CacheCollector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        matched_lines: u64 = 0,
        cache_hit: [32]u8 = undefined,
        cache_hit_len: usize = 0,

        fn tier(self: *const @This()) []const u8 {
            return self.cache_hit[0..self.cache_hit_len];
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);

            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                const ch = parsed.value.cacheHit;
                const copy_len = @min(ch.len, self.cache_hit.len);
                @memcpy(self.cache_hit[0..copy_len], ch[0..copy_len]);
                self.cache_hit_len = copy_len;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Cold search for "ORD-2026-" (matches 50 lines in orders.log, 0 in audit.log, limitHit == "none")
    var c1 = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 1,
        .pattern = "ORD-2026-",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c1, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 50), c1.matched_lines);
    try std.testing.expectEqualStrings("none", c1.tier());

    // 2. Repeat identical search -> hits Tier L1 ("exact")
    var c2 = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 2,
        .pattern = "ORD-2026-",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c2, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 50), c2.matched_lines);
    try std.testing.expectEqualStrings("exact", c2.tier());

    // 3. Progressive space refinement: add contains=["FULFILLED"] and excludes=["APAC"] -> hits Tier L2 ("superset")
    var c3 = CacheCollector{ .allocator = gpa, .io = io };
    const inc = [_][]const u8{"FULFILLED"};
    const exc = [_][]const u8{"APAC"};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3,
        .pattern = "ORD-2026-",
        .contains = &inc,
        .excludes = &exc,
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c3, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 20), c3.matched_lines);
    try std.testing.expectEqualStrings("superset", c3.tier());

    // 4. Longer literal superstring "ORD-2026-10" when parent "ORD-2026-" is complete -> hits Tier L2 ("superset") in RAM!
    var c4 = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 4,
        .pattern = "ORD-2026-10",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c4, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c4.matched_lines);
    try std.testing.expectEqualStrings("superset", c4.tier());

    // 5. Truncated search ("AUD-" with maxResults = 10 -> limitHit = true, orders.log has 0 hits for "AUD-"),
    // followed by "AUD-1" -> orders.log is pruned by Tier L3 ("pruned")!
    var c5_init = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 5,
        .pattern = "AUD-",
        .maxResults = 10,
    }, &cancel, .{ .ctx = &c5_init, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 10), c5_init.matched_lines);

    var c5_pruned = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 6,
        .pattern = "AUD-15",
        .maxResults = 10,
    }, &cancel, .{ .ctx = &c5_pruned, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c5_pruned.matched_lines);
    try std.testing.expectEqualStrings("pruned", c5_pruned.tier());

    // 6. Zero Dirty-Read Verification: modify orders.log on disk (adding a 51st match "ORD-2026-99"),
    // and verify that L1/L2/L4 caches immediately detect the (mtime_ns, file_size) change on orders.log
    // (returning 51 matches instead of 50), while unmodified audit.log remains pruned by L3 ("pruned")!
    {
        var f_orders = try tmp.dir.createFile(io, "svc/orders.log", .{});
        var buf: [4096]u8 = undefined;
        var fw = f_orders.writer(io, &buf);
        for (0..50) |i| {
            const status = if (i % 2 == 0) "FULFILLED" else "PENDING";
            const region = if (i % 5 == 0) "APAC" else "EMEA";
            try fw.interface.print("2026-10-30 INFO order=ORD-2026-{d:0>2} status={s} region={s}\n", .{ i, status, region });
        }
        try fw.interface.print("2026-10-30 INFO order=ORD-2026-99 status=FULFILLED region=EMEA\n", .{});
        try fw.interface.flush();
        f_orders.close(io);
    }

    var c6_fresh = CacheCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 7,
        .pattern = "ORD-2026-",
        .maxResults = 500,
    }, &cancel, .{ .ctx = &c6_fresh, .sendFn = CacheCollector.send });
    try std.testing.expectEqual(@as(u64, 51), c6_fresh.matched_lines);
    try std.testing.expectEqualStrings("pruned", c6_fresh.tier());
}

test "strong consistency: >4096-byte long lines never miss L2 contains/excludes and wholeWord+contains never false-matches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    try tmp.dir.createDirPath(io, "strict");
    {
        var f_long = try tmp.dir.createFile(io, "strict/long_line.log", .{ .truncate = true });
        var w_buf: [8192]u8 = undefined;
        var fw = f_long.writer(io, &w_buf);
        try fw.interface.writeAll("PRIMARY_HEAD_TOKEN ");
        for (0..5000) |_| {
            try fw.interface.writeAll("x");
        }
        try fw.interface.writeAll(" SECONDARY_TAIL_TOKEN_AT_5000\n");
        // Second line for wholeWord + contains test: "err" is inside "my_err_code" (not a whole word!), while "LONGER_CONTAINS_ANCHOR" is present
        try fw.interface.writeAll("prefix my_err_code LONGER_CONTAINS_ANCHOR\n");
        // Third line where "err" IS a whole word and "LONGER_CONTAINS_ANCHOR" is present
        try fw.interface.writeAll("prefix err LONGER_CONTAINS_ANCHOR\n");
        try fw.interface.flush();
        f_long.close(io);
    }

    const strict_dir_path = try std.fmt.allocPrint(arena, "{s}/strict", .{tmp_path});
    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "strict",
        .config = .{ .path = strict_dir_path },
        .enabled = true,
    });

    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Search "PRIMARY_HEAD_TOKEN" first (caches the >5000-byte line whose display text was truncated to 4096 bytes)
    var c_head = Collector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 1,
        .pattern = "PRIMARY_HEAD_TOKEN",
        .maxResults = 100,
    }, &cancel, .{ .ctx = &c_head, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 1), c_head.matched_lines);

    // 2. Follow-up progressive search adding `contains = ["SECONDARY_TAIL_TOKEN_AT_5000"]` (which sits at byte 5020 > 4096).
    // Because `all_lines_exact == false`, Tier L2 refuses to filter the truncated 4096-byte preview in RAM and instead scans the full file, finding all 1 match!
    var c_tail = Collector{ .allocator = gpa, .io = io };
    const tail_inc = [_][]const u8{"SECONDARY_TAIL_TOKEN_AT_5000"};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 2,
        .pattern = "PRIMARY_HEAD_TOKEN",
        .contains = &tail_inc,
        .maxResults = 100,
    }, &cancel, .{ .ctx = &c_tail, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 1), c_tail.matched_lines);

    // 3. Verify `wholeWord = true` with a longer `contains` token only matches the line where `err` is a true whole word (1 match, not 2!)
    var c_word = Collector{ .allocator = gpa, .io = io };
    const word_inc = [_][]const u8{"LONGER_CONTAINS_ANCHOR"};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 3,
        .pattern = "err",
        .wholeWord = true,
        .contains = &word_inc,
        .maxResults = 100,
    }, &cancel, .{ .ctx = &c_word, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 1), c_word.matched_lines);
}

test "strong consistency: >64MiB files (91MB, 195MB, 203MB) scan 100% to EOF and find tail needles without truncation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Only run if testdata/ large files exist in workspace
    var td_dir = std.Io.Dir.cwd().openDir(io, "testdata", .{ .iterate = true }) catch return;
    defer td_dir.close(io);
    _ = td_dir.statFile(io, "gateway-logs/access_large.kv.log", .{}) catch return;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    var td_real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const td_path_len = try td_dir.realPath(io, &td_real_buf);
    const td_abs_path = try arena.dupe(u8, td_real_buf[0..td_path_len]);

    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "testdata",
        .config = .{ .path = td_abs_path },
        .enabled = true,
    });

    const TailCollector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        matched_lines: u64 = 0,
        bytes_searched: u64 = 0,
        cache_hit: [32]u8 = undefined,
        cache_hit_len: usize = 0,

        fn tier(self: *const @This()) []const u8 {
            return self.cache_hit[0..self.cache_hit_len];
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.bytes_searched = parsed.value.bytesSearched;
                const ch = parsed.value.cacheHit;
                const copy_len = @min(ch.len, self.cache_hit.len);
                @memcpy(self.cache_hit[0..copy_len], ch[0..copy_len]);
                self.cache_hit_len = copy_len;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Tail needle `ORD-20261029-250000` across 91 MB `ecommerce_orders.jsonl:150000`, 99 MB `upstream_trace_large.log:150000`,
    // and 195 MB `transactions_large.jsonl:150000` -> must find all 3 matches (previously truncated at 64 MiB!)
    var c_91m = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 1,
        .pattern = "ORD-20261029-250000",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_91m, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_91m.matched_lines);
    try std.testing.expect(c_91m.bytes_searched > 500 * 1024 * 1024);

    // 2. Repeat identical search -> hits Tier L1 ("exact") with all 3 matches
    var c_91m_l1 = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 2,
        .pattern = "ORD-20261029-250000",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_91m_l1, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_91m_l1.matched_lines);
    try std.testing.expectEqualStrings("exact", c_91m_l1.tier());

    // 2b. Progressive L2 narrowing to `SW-INFINIBAND-800G` (at 91 MB tail of `ecommerce_orders.jsonl`) -> 1 match via Tier L2 ("superset")
    var c_91m_l2 = TailCollector{ .allocator = gpa, .io = io };
    const inc_sw = [_][]const u8{"SW-INFINIBAND-800G"};
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 20,
        .pattern = "ORD-20261029-250000",
        .contains = &inc_sw,
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_91m_l2, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_91m_l2.matched_lines);
    try std.testing.expectEqualStrings("superset", c_91m_l2.tier());

    // 3. Tail needle at the very end of 195 MB `transactions_large.jsonl` (`ORD-20261029-700000`)
    var c_195m = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 3,
        .pattern = "ORD-20261029-700000",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_195m, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_195m.matched_lines);

    // 4. Tail needle at the very end of 203 MB `access_large.kv.log` (`CRITICAL_NEEDLE_EVENT_1000000`)
    var c_203m = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 4,
        .pattern = "CRITICAL_NEEDLE_EVENT_",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_203m, .sendFn = TailCollector.send });
    try std.testing.expect(c_203m.matched_lines >= 3);

    // 5. Progressive L2 narrowing on 203 MB file (`CRITICAL_NEEDLE_EVENT_` + `contains: ["1000000"]`) -> hits Tier L2 ("superset")
    var c_203m_l2 = TailCollector{ .allocator = gpa, .io = io };
    const inc_1m = [_][]const u8{"1000000"};
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 5,
        .pattern = "CRITICAL_NEEDLE_EVENT_",
        .contains = &inc_1m,
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_203m_l2, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_203m_l2.matched_lines);
    try std.testing.expectEqualStrings("superset", c_203m_l2.tier());

    // 6. Scoped `$w(ErrorCode)` and `$cw(ErrorCode)` parity with `wholeWord: true` (`rg -s -w ErrorCode`) on testdata/
    var c_ww_native = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 6,
        .pattern = "ErrorCode",
        .case = "sensitive",
        .wholeWord = true,
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_ww_native, .sendFn = TailCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_ww_native.matched_lines);

    var c_scoped_w = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 7,
        .pattern = "$w(ErrorCode)",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_scoped_w, .sendFn = TailCollector.send });
    try std.testing.expectEqual(c_ww_native.matched_lines, c_scoped_w.matched_lines);

    var c_scoped_cw = TailCollector{ .allocator = gpa, .io = io };
    try executeSearchWithRegistry(gpa, io, td_dir, &reg, .{
        .id = 8,
        .pattern = "$cw(ErrorCode)",
        .maxResults = 5000,
    }, &cancel, .{ .ctx = &c_scoped_cw, .sendFn = TailCollector.send });
    try std.testing.expectEqual(c_ww_native.matched_lines, c_scoped_cw.matched_lines);
}

test "search_job: scoped whole-word modifiers ($w, $cw, $rw, $rcw) on indented lines match rg -w semantics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Indented code and log lines where byte 0 is space/tab or punctuation (non-word character)
    try tmp.dir.writeFile(io, .{
        .sub_path = "indented.zig",
        .data = "pub const Engine = struct {\n" ++
            "    id: u64 = 1001,\n" ++
            "    user_id: u64 = 2002,\n" ++
            "    pub fn check(id: u64) ErrorCode {\n" ++
            "        const err = ErrorCode.Timeout;\n" ++
            "        const fake = MyErrorCode;\n" ++
            "        const lower = errorcode;\n" ++
            "        // partial word first, then exact whole word on the same indented line:\n" ++
            "        const combo = ErrorCode2 + ErrorCode;\n" ++
            "        return err;\n" ++
            "    }\n" ++
            "};\n" ++
            "\tid = 4096; // tab-indented whole word + 4-digit number\n" ++
            "    code_5digits = 12345;\n" ++
            "    port = 8080;\n",
    });

    const CountCollector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        matched_lines: u64 = 0,
        total_matches: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.total_matches = parsed.value.totalMatches;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. `$w(id)` on indented lines: matches `    id: u64`, `    pub fn check(id: u64)`, and `\tid = 4096;` (3 lines),
    //    must NOT match `user_id`!
    var c_w_id = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 1,
        .pattern = "$w(id)",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_w_id, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_w_id.matched_lines);

    // 2. `$cw(ErrorCode)` (case-sensitive + whole-word): matches lines 4, 5, and 9 (`ErrorCode2 + ErrorCode`),
    //    must NOT match `MyErrorCode` (line 6) or `errorcode` (line 7)!
    var c_cw_err = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 2,
        .pattern = "$cw(ErrorCode)",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_cw_err, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 3), c_cw_err.matched_lines);

    // 3. `$w(ErrorCode)` with case="insensitive": matches lines 4, 5, 7 (`errorcode`), and 9 (`ErrorCode2 + ErrorCode`) = 4 lines
    var c_w_err_ci = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 3,
        .pattern = "$w(ErrorCode)",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_w_err_ci, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_w_err_ci.matched_lines);

    // 4. `$rw(\d{4})` (regex + whole-word): matches `1001`, `2002`, `4096`, `8080` (4 lines),
    //    must NOT match `12345` (5 digits)!
    var c_rw_digits = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 4,
        .pattern = "$rw(\\d{4})",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_rw_digits, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_rw_digits.matched_lines);

    // 5. Raw regex `\b\d{4}\b` in `mode: "regex"` on indented lines -> also 4 lines
    var c_raw_re = CountCollector{ .allocator = gpa, .io = io };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 5,
        .pattern = "\\b\\d{4}\\b",
        .mode = "regex",
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_raw_re, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_raw_re.matched_lines);

    // 6. Scoped `$w(...)` and `$rw(...)` inside `contains` and `excludes`
    var c_contains_w = CountCollector{ .allocator = gpa, .io = io };
    const inc_rw = [_][]const u8{"$rw(\\d{4})"};
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 6,
        .pattern = "$w(id)",
        .contains = &inc_rw,
        .case = "insensitive",
    }, &cancel, .{ .ctx = &c_contains_w, .sendFn = CountCollector.send });
    // Only `    id: u64 = 1001,` and `\tid = 4096;` have both whole-word `id` and a 4-digit number!
    try std.testing.expectEqual(@as(u64, 2), c_contains_w.matched_lines);
}

test "search_job: dual-granularity time filter on ISO-8601/Nginx/JSONL logs (with stack traces) AND code/HTML files via stat.mtime" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "mixed");

    // 1. Existing ISO-8601 / Spring Boot log with multi-line Java stack trace
    const spring_log =
        "2026-10-31 10:15:01,000 INFO  [main] Booting service\n" ++
        "2026-10-31 10:15:02,500 ERROR [worker-1] NullPointerException in PaymentService\n" ++
        "    at com.example.PaymentService.charge(PaymentService.java:88)\n" ++
        "    at com.example.OrderController.submit(OrderController.java:42)\n" ++
        "2026-10-31 10:15:05,000 INFO  [main] Shutdown complete\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "mixed/spring.log", .data = spring_log });

    // 2. Code (.zig) and HTML (.html) files (no line-level timestamps -> filtered by stat.mtime!)
    try tmp.dir.writeFile(io, .{
        .sub_path = "mixed/app.zig",
        .data = "pub fn handlePayment() void {\n    // PaymentService logic\n}\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "mixed/index.html",
        .data = "<!DOCTYPE html>\n<html><body><div class=\"PaymentService\">Pay</div></body></html>\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root_real = try gpa.dupe(u8, path_buf[0..n]);
    defer gpa.free(root_real);

    var reg = source_registry.SourceRegistry.init(gpa, io, root_real, null);
    defer reg.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const mixed_dir_path = try std.fmt.allocPrint(arena_state.allocator(), "{s}/mixed", .{root_real});
    try reg.upsertSource(arena_state.allocator(), io, .{
        .kind = "dir",
        .name = "mixed",
        .path = mixed_dir_path,
        .enabled = true,
    });

    const SimpleCollector = struct {
        allocator: std.mem.Allocator,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // A. Search `PaymentService` inside historical log window [2026-10-31T10:15:02Z, 2026-10-31T10:15:03Z]:
    //    - `spring.log` is a time-series log: matches both line 2 (`ERROR ... PaymentService`) AND line 3 (stack trace `at ... PaymentService.java:88` via lookbehind inheritance)!
    //    - `app.zig` and `index.html` have `mtime = now` (outside the narrow 1-second window if `timeEndNs` is 10:15:03Z, or inside if `timeEndNs == 0`).
    const t_start = time_parser.parseTimestampValueNs("2026-10-31T10:15:02Z", .{}, null).?;
    const t_end = time_parser.parseTimestampValueNs("2026-10-31T10:15:03Z", .{}, null).?;

    var col_log_window = SimpleCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 10,
        .pattern = "PaymentService",
        .timeStartNs = t_start,
        .timeEndNs = t_end,
    }, &cancel, .{ .ctx = &col_log_window, .sendFn = SimpleCollector.send });
    try std.testing.expectEqual(@as(u64, 2), col_log_window.matched_lines);

    // B. Search `PaymentService` with `timeStartNs = now - 60s` (`$t(1m)`):
    //    - `app.zig` and `index.html` were just modified (`mtime >= now - 60s`), so both code and HTML files match (1 line each = 2 lines)!
    const now_ns = time_parser.currentUnixNano(io);
    var col_recent = SimpleCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 11,
        .pattern = "PaymentService",
        .timeStartNs = now_ns -| (60 * std.time.ns_per_s),
        .timeEndNs = now_ns +| (60 * std.time.ns_per_s),
    }, &cancel, .{ .ctx = &col_recent, .sendFn = SimpleCollector.send });
    try std.testing.expectEqual(@as(u64, 2), col_recent.matched_lines);
}

test "search_job: $@(zedis-rust) pub fn async members falls back to ±15-line block proximity when terms span doc-comment and function signature" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "zedis-rust/states/server");
    const set_rs =
        "/// Performs the initial load of a Redis SET value.\n" ++
        "///\n" ++
        "/// Fetches the total cardinality (SCARD) and loads the first batch of members (up to 100).\n" ++
        "///\n" ++
        "/// # Arguments\n" ++
        "/// * `conn` - Redis asynchronous connection\n" ++
        "/// * `key` - The SET key to load\n" ++
        "pub(crate) async fn first_load_set_value(conn: &mut RedisAsyncConn, key: &str) -> Result<RedisValue> {\n" ++
        "    // Get total number of members in the SET\n" ++
        "    let size: usize = cmd(\"SCARD\").arg(key).query_async(conn).await?;\n" ++
        "}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "zedis-rust/states/server/set.rs", .data = set_rs });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root_real = try gpa.dupe(u8, path_buf[0..n]);
    defer gpa.free(root_real);

    var reg = source_registry.SourceRegistry.init(gpa, io, root_real, null);
    defer reg.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const zedis_dir_path = try std.fmt.allocPrint(arena_state.allocator(), "{s}/zedis-rust", .{root_real});
    try reg.upsertSource(arena_state.allocator(), io, .{
        .kind = "dir",
        .name = "zedis-rust",
        .path = zedis_dir_path,
        .enabled = true,
    });

    const BlockCollector = struct {
        allocator: std.mem.Allocator,
        matched_lines: u64 = 0,
        first_line_no: u64 = 0,
        span_count: usize = 0,
        nearby_lines: u32 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                if (parsed.value.items.len > 0 and self.first_line_no == 0) {
                    self.first_line_no = parsed.value.items[0].line;
                    self.span_count = parsed.value.items[0].spans.len;
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.nearby_lines = parsed.value.nearbyLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // Default (`nearbyLines = 0`) keeps the search strictly single-line.
    var col_default_strict = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 98,
        .pattern = "pub",
        .contains = &.{ "fn", "async", "members" },
        .globs = &.{"zedis-rust"},
    }, &cancel, .{ .ctx = &col_default_strict, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(@as(u64, 0), col_default_strict.matched_lines);
    try std.testing.expectEqual(@as(u32, 0), col_default_strict.nearby_lines);

    var col = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 99,
        .pattern = "pub",
        .contains = &.{ "fn", "async", "members" },
        .globs = &.{"zedis-rust"},
        .sources = &.{"other-unrelated-source"},
        .nearbyLines = 15,
    }, &cancel, .{ .ctx = &col, .sendFn = BlockCollector.send });

    try std.testing.expect(col.matched_lines >= 1);
    try std.testing.expectEqual(@as(u64, 8), col.first_line_no);
    try std.testing.expect(col.span_count >= 3);
    try std.testing.expectEqual(@as(u32, 15), col.nearby_lines);

    // Same query again: L1/L2 must not have cached the fallback hits as strict single-line results,
    // and the nearby fallback must still kick in (previously a cached "0 hits" could be replayed).
    var col_again = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 100,
        .pattern = "pub",
        .contains = &.{ "fn", "async", "members" },
        .globs = &.{"zedis-rust"},
        .nearbyLines = 15,
    }, &cancel, .{ .ctx = &col_again, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(col.matched_lines, col_again.matched_lines);
    try std.testing.expectEqual(@as(u32, 15), col_again.nearby_lines);

    // `nearbyLines = 0` keeps the search strictly single-line.
    var col_strict = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 101,
        .pattern = "pub",
        .contains = &.{ "fn", "async", "members" },
        .nearbyLines = 0,
    }, &cancel, .{ .ctx = &col_strict, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(@as(u64, 0), col_strict.matched_lines);
    try std.testing.expectEqual(@as(u32, 0), col_strict.nearby_lines);

    // `fileGlobs`: `@*.rs` keeps set.rs, `-@*.rs` drops it.
    var col_glob = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 102,
        .pattern = "SCARD",
        .fileGlobs = &.{"server/*.rs"},
    }, &cancel, .{ .ctx = &col_glob, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(@as(u64, 2), col_glob.matched_lines);

    var col_glob_neg = BlockCollector{ .allocator = gpa };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 103,
        .pattern = "SCARD",
        .fileGlobs = &.{"!*.rs"},
    }, &cancel, .{ .ctx = &col_glob_neg, .sendFn = BlockCollector.send });
    try std.testing.expectEqual(@as(u64, 0), col_glob_neg.matched_lines);
}

test "search_job: libwebgrep v0.5.0 alt_prefilter & precomputed_dfa selectivity planner" {
    const gpa = std.testing.allocator;

    var re_alt = try libwebgrep.Regex.init(gpa, "ERROR_CRITICAL|FATAL_PANIC", EngineLimits.regexOptions(.sensitive));
    defer re_alt.deinit();
    try std.testing.expect(re_alt.alt_prefilter != null);
    // An 11-char exact alternation (`min_alt_len = 11`) must outscore a weak 2-char literal `in` (`25`).
    try std.testing.expect(computeRegexSelectivity(&re_alt) > computeLiteralSelectivity("in"));

    var re_dfa = try libwebgrep.Regex.init(gpa, "\\d{4}", EngineLimits.regexOptions(.sensitive));
    defer re_dfa.deinit();
    // Unanchored digit regex has no literal prefilter and must still score lower than any 2+ char literal.
    try std.testing.expect(computeRegexSelectivity(&re_dfa) < computeLiteralSelectivity("fn"));
}

test "search_job: libwebgrep v0.5.0 caller-configured limits (context > 10 & regex repeat > 1000)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file_buf: std.ArrayList(u8) = .empty;
    defer file_buf.deinit(gpa);
    for (1..26) |line_idx| {
        const line_str = try std.fmt.allocPrint(gpa, "ctx_before_{d:0>2}\n", .{line_idx});
        defer gpa.free(line_str);
        try file_buf.appendSlice(gpa, line_str);
    }
    try file_buf.appendSlice(gpa, "MATCH_TARGET_V050\n");
    for (1..26) |line_idx| {
        const line_str = try std.fmt.allocPrint(gpa, "ctx_after_{d:0>2}\n", .{line_idx});
        defer gpa.free(line_str);
        try file_buf.appendSlice(gpa, line_str);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "deep_context.log", .data = file_buf.items });

    const CtxCollector = struct {
        allocator: std.mem.Allocator,
        hit_items: usize = 0,
        ctx_items: usize = 0,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                for (parsed.value.items) |it| {
                    if (it.isContext) {
                        self.ctx_items += 1;
                    } else {
                        self.hit_items += 1;
                    }
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var col = CtxCollector{ .allocator = gpa };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 500,
        .pattern = "MATCH_TARGET_V050",
        .context = 20, // Exceeds former v0.4.1 hardcoded cap of 10!
    }, &cancel, .{ .ctx = &col, .sendFn = CtxCollector.send });

    try std.testing.expectEqual(@as(u64, 1), col.matched_lines);
    try std.testing.expectEqual(@as(usize, 1), col.hit_items);
    try std.testing.expectEqual(@as(usize, 40), col.ctx_items); // 20 before + 20 after

    // Verify EngineLimits.regexOptions allows repeat > 1000
    var re_repeat = try libwebgrep.Regex.init(gpa, "x{1200}", EngineLimits.regexOptions(.sensitive));
    defer re_repeat.deinit();
}

fn writeTestTarOctal(field: []u8, val: u64) void {
    @memset(field, '0');
    if (field.len > 0) field[field.len - 1] = 0;
    var v = val;
    var idx: usize = if (field.len >= 2) field.len - 2 else 0;
    while (v > 0) {
        field[idx] = @intCast('0' + (v & 7));
        v >>= 3;
        if (idx == 0) break;
        idx -= 1;
    }
}

fn finalizeTestTarHeader(header: *[512]u8) void {
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    @memset(header[148..156], ' ');
    var sum: u64 = 0;
    for (header) |b| sum += b;
    writeTestTarOctal(header[148..155], sum);
    header[155] = ' ';
}

fn appendTestTarEntry(out: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const u8, typeflag: u8, data: []const u8) !void {
    var header: [512]u8 = @splat(0);
    const name_len = @min(path.len, 100);
    @memcpy(header[0..name_len], path[0..name_len]);
    writeTestTarOctal(header[100..108], 0o644);
    writeTestTarOctal(header[108..116], 0);
    writeTestTarOctal(header[116..124], 0);
    writeTestTarOctal(header[124..136], if (typeflag == '0') data.len else 0);
    writeTestTarOctal(header[136..148], 0);
    header[156] = typeflag;
    finalizeTestTarHeader(&header);
    try out.appendSlice(allocator, &header);
    if (typeflag == '0' and data.len > 0) {
        try out.appendSlice(allocator, data);
        const rem = data.len % 512;
        if (rem != 0) {
            const pad = 512 - rem;
            try out.appendNTimes(allocator, 0, pad);
        }
    }
}

test "search_job: libwebgrep v0.5.0 zero-disk-landing archive direct search (:: virtual path & TreeConfig filters)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tar_bytes: std.ArrayList(u8) = .empty;
    defer tar_bytes.deinit(gpa);
    try appendTestTarEntry(&tar_bytes, gpa, "src/engine.zig", '0', "pub fn archive_needle() void {}\n");
    try appendTestTarEntry(&tar_bytes, gpa, "docs/guide.md", '0', "# archive_needle documentation\n");
    try tar_bytes.appendNTimes(gpa, 0, 1024);

    try tmp.dir.writeFile(io, .{ .sub_path = "bundle.tar", .data = tar_bytes.items });

    const ArchiveHitCollector = struct {
        allocator: std.mem.Allocator,
        files: std.ArrayList([]u8) = .empty,
        matched_lines: u64 = 0,

        fn deinit(self: *@This()) void {
            for (self.files.items) |f| self.allocator.free(f);
            self.files.deinit(self.allocator);
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                for (parsed.value.items) |it| {
                    try self.files.append(self.allocator, try self.allocator.dupe(u8, it.file));
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Unfiltered archive search returns both entries formatted as `bundle.tar::<entry_path>`
    var col_all = ArchiveHitCollector{ .allocator = gpa };
    defer col_all.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 601,
        .pattern = "archive_needle",
    }, &cancel, .{ .ctx = &col_all, .sendFn = ArchiveHitCollector.send });

    try std.testing.expectEqual(@as(u64, 2), col_all.matched_lines);
    try std.testing.expectEqual(@as(usize, 2), col_all.files.items.len);
    var saw_zig = false;
    var saw_md = false;
    for (col_all.files.items) |vpath| {
        if (std.mem.eql(u8, vpath, "bundle.tar::src/engine.zig")) saw_zig = true;
        if (std.mem.eql(u8, vpath, "bundle.tar::docs/guide.md")) saw_md = true;
    }
    try std.testing.expect(saw_zig and saw_md);

    // 2. `types = &.{"zig"}` filters inside the archive via TreeConfig, keeping only `bundle.tar::src/engine.zig`
    var col_zig = ArchiveHitCollector{ .allocator = gpa };
    defer col_zig.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 602,
        .pattern = "archive_needle",
        .types = &.{"zig"},
    }, &cancel, .{ .ctx = &col_zig, .sendFn = ArchiveHitCollector.send });

    try std.testing.expectEqual(@as(u64, 1), col_zig.matched_lines);
    try std.testing.expectEqual(@as(usize, 1), col_zig.files.items.len);
    try std.testing.expectEqualStrings("bundle.tar::src/engine.zig", col_zig.files.items[0]);
}

test "search_job: libwebgrep v0.5.0 structured CompileDiagnostic regex error reporting" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.txt", .data = "hello world\n" });

    const ErrCollector = struct {
        allocator: std.mem.Allocator,
        error_msg: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.error_msg) |m| self.allocator.free(m);
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"error\"") != null) {
                var parsed = try std.json.parseFromSlice(ErrorFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                if (self.error_msg) |old| self.allocator.free(old);
                self.error_msg = try self.allocator.dupe(u8, parsed.value.message);
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var err_col = ErrCollector{ .allocator = gpa };
    defer err_col.deinit();

    try executeSearch(gpa, io, tmp.dir, .{
        .id = 603,
        .pattern = "[unclosed",
        .mode = "regex",
    }, &cancel, .{ .ctx = &err_col, .sendFn = ErrCollector.send });

    try std.testing.expect(err_col.error_msg != null);
    const msg = err_col.error_msg.?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "Regex compile error") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "line 1, column ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "offset ") != null);
}

test "search_job: libwebgrep v0.5.0 walk_types, walk_ignore (.gitignore), walk_glob brace expansion, and UTF-16LE BOM Encoding.auto" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "ignored_dir/\n*_ignored.rs\n" });
    try tmp.dir.createDirPath(io, "ignored_dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "ignored_dir/secret.rs", .data = "walk_target_v050 in ignored dir\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skip_ignored.rs", .data = "walk_target_v050 in ignored file\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.rs", .data = "fn walk_target_v050() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "script.py", .data = "def walk_target_v050(): pass\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "walk_target_v050 in plain text\n" });

    // UTF-16LE with BOM (`0xFF, 0xFE`) containing "utf16_bom_target\n"
    const utf16le_bytes = [_]u8{
        0xFF, 0xFE,
        'u',  0x00,
        't',  0x00,
        'f',  0x00,
        '1',  0x00,
        '6',  0x00,
        '_',  0x00,
        'b',  0x00,
        'o',  0x00,
        'm',  0x00,
        '_',  0x00,
        't',  0x00,
        'a',  0x00,
        'r',  0x00,
        'g',  0x00,
        'e',  0x00,
        't',  0x00,
        '\n', 0x00,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "unicode_log.log", .data = &utf16le_bytes });

    const CountCollector = struct {
        allocator: std.mem.Allocator,
        matched_lines: u64 = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. `respectIgnore = true` + brace-expanded `fileGlobs = &.{"*.{rs,py}"}` -> matches `keep.rs` and `script.py` (2 lines), skipping `.gitignore` matches and `notes.txt`!
    var col_ignore = CountCollector{ .allocator = gpa };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 604,
        .pattern = "walk_target_v050",
        .respectIgnore = true,
        .fileGlobs = &.{"*.{rs,py}"},
    }, &cancel, .{ .ctx = &col_ignore, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 2), col_ignore.matched_lines);

    // 2. `walk_types` built-in language alias (`rust`) + `respectIgnore = true` -> matches only `keep.rs` (1 line)
    var col_rust = CountCollector{ .allocator = gpa };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 605,
        .pattern = "walk_target_v050",
        .respectIgnore = true,
        .types = &.{"rust"},
    }, &cancel, .{ .ctx = &col_rust, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 1), col_rust.matched_lines);

    // 3. UTF-16LE BOM automatic transcoding via `Encoding.auto` + `searchSourceSlice`
    var col_utf16 = CountCollector{ .allocator = gpa };
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 606,
        .pattern = "utf16_bom_target",
    }, &cancel, .{ .ctx = &col_utf16, .sendFn = CountCollector.send });
    try std.testing.expectEqual(@as(u64, 1), col_utf16.matched_lines);
}

test "search_job: strict single-line matching, literal spaces, explicit $c/$w/$r/$rcw flags, and invalid scoped regex error frame" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sample_data =
        "2026-11-12 [INFO] ErrorCode 404 retry in 50ms\n" ++
        "2026-11-12 [INFO] errorcode 4040 retry in 50ms\n" ++
        "2026-11-12 [WARN] ErrorCode2 404 retry in 50ms\n" ++
        "2026-11-12 [ERROR] $r([unclosed) literal line\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "strict.log", .data = sample_data });

    const TestCollector = struct {
        allocator: std.mem.Allocator,
        matched_lines: u64 = 0,
        error_msg: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.error_msg) |m| self.allocator.free(m);
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"error\"") != null) {
                var parsed = try std.json.parseFromSlice(ErrorFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                if (self.error_msg) |old| self.allocator.free(old);
                self.error_msg = try self.allocator.dupe(u8, parsed.value.message);
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // (a) Plain case-insensitive search with literal spaces matches all 3 lines containing "retry in 50ms" and "errorcode"
    var col_plain = TestCollector{ .allocator = gpa };
    defer col_plain.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 701,
        .pattern = "ErrorCode",
        .case = "insensitive",
        .contains = &.{"retry in 50ms"},
    }, &cancel, .{ .ctx = &col_plain, .sendFn = TestCollector.send });
    try std.testing.expectEqual(@as(u64, 3), col_plain.matched_lines);

    // (b) Explicit `$c(ErrorCode)` + `$w(ErrorCode)` (`$cw(ErrorCode)`) + `$rcw(404)` matches only line 1
    var col_scoped = TestCollector{ .allocator = gpa };
    defer col_scoped.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 702,
        .pattern = "$cw(ErrorCode)",
        .case = "insensitive",
        .contains = &.{ "$rcw(\\d{3})", "retry in 50ms" },
    }, &cancel, .{ .ctx = &col_scoped, .sendFn = TestCollector.send });
    try std.testing.expectEqual(@as(u64, 1), col_scoped.matched_lines);

    // (c) Invalid `$r([unclosed)` in `contains` or `excludes` emits an error frame instead of falling back to literal
    var col_bad_contains = TestCollector{ .allocator = gpa };
    defer col_bad_contains.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 703,
        .pattern = "2026-11-12",
        .case = "insensitive",
        .contains = &.{"$r([unclosed)"},
    }, &cancel, .{ .ctx = &col_bad_contains, .sendFn = TestCollector.send });
    try std.testing.expect(col_bad_contains.error_msg != null);
    try std.testing.expectEqual(@as(u64, 0), col_bad_contains.matched_lines);

    var col_bad_excludes = TestCollector{ .allocator = gpa };
    defer col_bad_excludes.deinit();
    try executeSearch(gpa, io, tmp.dir, .{
        .id = 704,
        .pattern = "2026-11-12",
        .case = "insensitive",
        .excludes = &.{"$r([unclosed)"},
    }, &cancel, .{ .ctx = &col_bad_excludes, .sendFn = TestCollector.send });
    try std.testing.expect(col_bad_excludes.error_msg != null);
    try std.testing.expectEqual(@as(u64, 0), col_bad_excludes.matched_lines);
}

test "search_job: orthogonal content vs mtime, mtime 1-line summary, per-source/query timeFormat, lookbehind, and cache isolation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "data");
    try tmp.dir.createDirPath(io, "logs_src");
    try tmp.dir.createDirPath(io, "json_src");

    // 1. Mixed directory: log (timestamps + stack trace), zig code, markdown, and custom bracketed format
    const app_log =
        "2026-11-14T10:00:00Z INFO start\n" ++
        "2026-11-14T10:05:00Z ERROR boom_in_window\n" ++
        "    at com.example.Service.handle(Service.java:42)\n" ++
        "2026-11-14T10:20:00Z ERROR outside_window\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "logs_src/app.log", .data = app_log });
    try tmp.dir.writeFile(io, .{
        .sub_path = "logs_src/code.zig",
        .data = "const boom_in_window = 1;\nconst Service_handle = 2;\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "logs_src/notes.md",
        .data = "# Notes\nboom_in_window documentation\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "logs_src/custom.txt",
        .data = "TS=[14@11@2026 10:05:00] custom_regex_hit\nTS=[14@11@2026 10:20:00] custom_regex_miss\n",
    });

    // 2. JSON source with nested epoch timestamp
    const sec_1005: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 14, 10, 5, 0).?);
    const sec_1020: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 14, 10, 20, 0).?);
    const json_data = try std.fmt.allocPrint(
        arena,
        "{{\"meta\":{{\"ts\":{d}}},\"msg\":\"json_boom\"}}\n{{\"meta\":{{\"ts\":{d}}},\"msg\":\"json_outside\"}}\n",
        .{ sec_1005, sec_1020 },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "json_src/events.jsonl", .data = json_data });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buf);
    const root_real = path_buf[0..root_len];

    const data_path = try std.fmt.allocPrint(arena, "{s}/data", .{root_real});
    const logs_path = try std.fmt.allocPrint(arena, "{s}/logs_src", .{root_real});
    const json_path = try std.fmt.allocPrint(arena, "{s}/json_src", .{root_real});

    var reg = source_registry.SourceRegistry.init(gpa, io, data_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "logs_src",
        .config = .{ .path = logs_path },
        .enabled = true,
    });
    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "json_src",
        .config = .{ .path = json_path, .timeFormat = "json:meta.ts" },
        .enabled = true,
    });

    const st_app = try tmp.dir.statFile(io, "logs_src/app.log", .{});
    const file_mtime_ms: u64 = @intCast(@max(0, @divFloor(st_app.mtime.nanoseconds, std.time.ns_per_ms)));

    const E2ECollector = struct {
        allocator: std.mem.Allocator,
        files_searched: u64 = 0,
        files_matched: u64 = 0,
        matched_lines: u64 = 0,
        cache_hit: [32]u8 = undefined,
        cache_hit_len: usize = 0,
        error_msg: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.error_msg) |m| self.allocator.free(m);
        }

        fn cacheTier(self: *const @This()) []const u8 {
            return self.cache_hit[0..self.cache_hit_len];
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.files_searched = parsed.value.filesSearched;
                self.files_matched = parsed.value.filesMatched;
                self.matched_lines = parsed.value.matchedLines;
                const cp_len = @min(parsed.value.cacheHit.len, self.cache_hit.len);
                @memcpy(self.cache_hit[0..cp_len], parsed.value.cacheHit[0..cp_len]);
                self.cache_hit_len = cp_len;
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"error\"") != null) {
                var parsed = try std.json.parseFromSlice(ErrorFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                if (self.error_msg) |old| self.allocator.free(old);
                self.error_msg = try self.allocator.dupe(u8, parsed.value.message);
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    const win_lo_ms: u64 = (sec_1005 - 60) * 1000;
    const win_hi_ms: u64 = (sec_1005 + 60) * 1000;

    // (a) `timeMode = "content"` strictly excludes untimestamped code.zig / notes.md (NO mtime fallback)
    var c_content = E2ECollector{ .allocator = gpa };
    defer c_content.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 801,
        .pattern = "boom_in_window",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_content, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_content.files_matched);
    try std.testing.expectEqual(@as(u64, 1), c_content.matched_lines);

    // (b) `timeMode = "mtime"` with empty query emits 1 summary line per mtime-matched file (all 4 files in logs_src)
    var c_mtime_summary = E2ECollector{ .allocator = gpa };
    defer c_mtime_summary.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 802,
        .pattern = "",
        .sources = &.{"logs_src"},
        .timeMode = "mtime",
        .timeStartMs = file_mtime_ms - 60_000,
        .timeEndMs = file_mtime_ms + 60_000,
    }, &cancel, .{ .ctx = &c_mtime_summary, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 4), c_mtime_summary.files_matched);
    try std.testing.expectEqual(@as(u64, 4), c_mtime_summary.matched_lines);

    // (c) Stack-trace continuation lookbehind when parent timestamped line does NOT contain the query keyword
    var c_stack = E2ECollector{ .allocator = gpa };
    defer c_stack.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 803,
        .pattern = "Service.java",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_stack, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_stack.matched_lines);

    // Stack frame must NOT leak into a later window that starts after 10:05:00
    var c_stack_miss = E2ECollector{ .allocator = gpa };
    defer c_stack_miss.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 804,
        .pattern = "Service.java",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeStartMs = (sec_1005 + 60) * 1000,
        .timeEndMs = (sec_1020 + 60) * 1000,
    }, &cancel, .{ .ctx = &c_stack_miss, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 0), c_stack_miss.matched_lines);

    // (d) Per-source `config.timeFormat` ("json:meta.ts") + L1 exact replay check
    var c_json1 = E2ECollector{ .allocator = gpa };
    defer c_json1.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 805,
        .pattern = "json_",
        .sources = &.{"json_src"},
        .timeMode = "content",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_json1, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 1), c_json1.matched_lines);

    var c_json2 = E2ECollector{ .allocator = gpa };
    defer c_json2.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 806,
        .pattern = "json_",
        .sources = &.{"json_src"},
        .timeMode = "content",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_json2, .sendFn = E2ECollector.send });
    try std.testing.expectEqualStrings("exact", c_json2.cacheTier());
    try std.testing.expectEqual(@as(u64, 1), c_json2.matched_lines);

    // (e) Query-level `regex:` override & cache isolation against empty `timeFormat`
    var c_custom_none = E2ECollector{ .allocator = gpa };
    defer c_custom_none.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 807,
        .pattern = "custom_regex",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeFormat = "",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_custom_none, .sendFn = E2ECollector.send });
    try std.testing.expectEqual(@as(u64, 0), c_custom_none.matched_lines);

    var c_custom_re = E2ECollector{ .allocator = gpa };
    defer c_custom_re.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 808,
        .pattern = "custom_regex",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeFormat = "regex:TS=\\[(?P<d>\\d{2})@(?P<m>\\d{2})@(?P<Y>\\d{4}) (?P<H>\\d{2}):(?P<M>\\d{2}):(?P<S>\\d{2})\\]",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_custom_re, .sendFn = E2ECollector.send });
    try std.testing.expect(!std.mem.eql(u8, c_custom_re.cacheTier(), "exact"));
    try std.testing.expectEqual(@as(u64, 1), c_custom_re.matched_lines);

    // (f) Invalid regex timeFormat returns CompileDiagnostic error frame
    var c_bad_tf = E2ECollector{ .allocator = gpa };
    defer c_bad_tf.deinit();
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 809,
        .pattern = "custom_regex",
        .sources = &.{"logs_src"},
        .timeMode = "content",
        .timeFormat = "regex:(unclosed",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c_bad_tf, .sendFn = E2ECollector.send });
    try std.testing.expect(c_bad_tf.error_msg != null);
    try std.testing.expectEqual(@as(u64, 0), c_bad_tf.matched_lines);
}

test "search_job: per-source non-stacked timeMode=source across mtime code source and content log sources" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "data");
    try tmp.dir.createDirPath(io, "code_src");
    try tmp.dir.createDirPath(io, "auto_log_src");
    try tmp.dir.createDirPath(io, "json_src");

    // 1. Code source (no timeFormat -> mtime only; historical logs inside must match file mtime, NOT line time)
    try tmp.dir.writeFile(io, .{
        .sub_path = "code_src/main.zig",
        .data = "pub fn boot() void {}\npub fn shutdown() void {}\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "code_src/README.md",
        .data = "# Overview\nHistorical 2020-01-01T00:00:00Z example\n",
    });

    // 2. Auto log source (timeFormat = "auto" -> line time ONLY, file mtime is NOW >> historical window 10:04..10:06!)
    try tmp.dir.writeFile(io, .{
        .sub_path = "auto_log_src/service.log",
        .data = "2026-11-14T10:01:00Z INFO startup\n" ++
            "2026-11-14T10:04:30Z ERROR hit_one\n" ++
            "2026-11-14T10:05:15Z ERROR hit_two\n" ++
            "2026-11-14T10:20:00Z ERROR outside_hi\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "auto_log_src/untimestamped.txt",
        .data = "plain text hit_one without timestamp\n",
    });

    // 3. Custom JSON source (timeFormat = "json:meta.ts" -> line time ONLY)
    const sec_1005: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 14, 10, 5, 0).?);
    const sec_1020: u64 = @intCast(time_parser.civilToEpochSeconds(2026, 11, 14, 10, 20, 0).?);
    const json_data = try std.fmt.allocPrint(
        arena,
        "{{\"meta\":{{\"ts\":{d}}},\"msg\":\"hit_json\"}}\n{{\"meta\":{{\"ts\":{d}}},\"msg\":\"miss_json\"}}\n",
        .{ sec_1005, sec_1020 },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "json_src/events.jsonl", .data = json_data });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buf);
    const root_real = path_buf[0..root_len];

    const data_path = try std.fmt.allocPrint(arena, "{s}/data", .{root_real});
    const code_path = try std.fmt.allocPrint(arena, "{s}/code_src", .{root_real});
    const auto_log_path = try std.fmt.allocPrint(arena, "{s}/auto_log_src", .{root_real});
    const json_path = try std.fmt.allocPrint(arena, "{s}/json_src", .{root_real});

    var reg = source_registry.SourceRegistry.init(gpa, io, data_path, null);
    defer reg.deinit(io);

    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "code_src",
        .config = .{ .path = code_path },
        .enabled = true,
    });
    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "auto_log_src",
        .config = .{ .path = auto_log_path, .timeFormat = "auto" },
        .enabled = true,
    });
    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "json_src",
        .config = .{ .path = json_path, .timeFormat = "json:meta.ts" },
        .enabled = true,
    });

    const st_code = try tmp.dir.statFile(io, "code_src/main.zig", .{});
    const mtime_ms: u64 = @intCast(@max(0, @divFloor(st_code.mtime.nanoseconds, std.time.ns_per_ms)));

    const Collector = struct {
        matched_lines: u64 = 0,
        files_matched: u64 = 0,
        cache_hit: [16]u8 = undefined,
        cache_len: usize = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, std.heap.page_allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.files_matched = parsed.value.filesMatched;
                const n = @min(parsed.value.cacheHit.len, self.cache_hit.len);
                @memcpy(self.cache_hit[0..n], parsed.value.cacheHit[0..n]);
                self.cache_len = n;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    const win_lo_ms: u64 = (sec_1005 - 60) * 1000;
    const win_hi_ms: u64 = (sec_1005 + 60) * 1000;

    // 1. Historical window [10:04, 10:06]:
    //    - `auto_log_src` & `json_src` match their in-line timestamps (2 + 1 = 3 lines), ignoring file mtime (> now)!
    //    - untimestamped.txt inside `auto_log_src` returns 0 hits (strict line time).
    //    - `code_src` (mtime mode) is pruned by mtime because mtime (~now) > win_hi_ms -> 0 hits!
    var c1 = Collector{};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 901,
        .pattern = "hit_",
        .sources = &.{ "code_src", "auto_log_src", "json_src" },
        .timeMode = "source",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c1, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 2), c1.files_matched);
    try std.testing.expectEqual(@as(u64, 3), c1.matched_lines);

    // 2. Empty-keyword time browse over [10:04, 10:06] emits ALL matching log lines from content-time sources
    //    (2 lines in service.log + 1 line in events.jsonl = 3 lines), while `code_src` is excluded by mtime.
    var c2 = Collector{};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 902,
        .pattern = "",
        .sources = &.{ "code_src", "auto_log_src", "json_src" },
        .timeMode = "source",
        .timeStartMs = win_lo_ms,
        .timeEndMs = win_hi_ms,
    }, &cancel, .{ .ctx = &c2, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 2), c2.files_matched);
    try std.testing.expectEqual(@as(u64, 3), c2.matched_lines);

    // 3. Recent window around `mtime` + empty pattern:
    //    - `code_src` emits exactly 1 summary line per mtime-matched file (2 files -> 2 lines)!
    var c3 = Collector{};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 903,
        .pattern = "",
        .sources = &.{"code_src"},
        .timeMode = "source",
        .timeStartMs = mtime_ms - 60_000,
        .timeEndMs = mtime_ms + 60_000,
    }, &cancel, .{ .ctx = &c3, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 2), c3.files_matched);
    try std.testing.expectEqual(@as(u64, 2), c3.matched_lines);

    // 4. Switching `code_src` to `timeFormat = "auto"` via upsertSource isolates cache via `time_format_sig`
    //    and now evaluates `code_src` strictly by line time -> untimestamped `main.zig` & `README.md` emit 0 lines!
    try reg.upsertSource(arena, io, .{
        .kind = "dir",
        .name = "code_src",
        .config = .{ .path = code_path, .timeFormat = "auto" },
        .enabled = true,
    });
    var c4 = Collector{};
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 904,
        .pattern = "",
        .sources = &.{"code_src"},
        .timeMode = "source",
        .timeStartMs = mtime_ms - 60_000,
        .timeEndMs = mtime_ms + 60_000,
    }, &cancel, .{ .ctx = &c4, .sendFn = Collector.send });
    try std.testing.expectEqual(@as(u64, 0), c4.matched_lines);
}

test "Docker E2E search: multi-level convergence, >16KiB demux, file-type filter, line-time until pushdown, 501 tolerance, and live-append cache bypass" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    const sock_rel_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/sj.sock", .{tmp.sub_path});
    const ua = try std.Io.net.UnixAddress.init(sock_rel_path);
    var srv = try ua.listen(io, .{});

    const MockServer = struct {
        server: *std.Io.net.Server,
        io: std.Io,
        stop: std.atomic.Value(bool) = .init(false),
        live_appended: std.atomic.Value(bool) = .init(false),
        uri_mu: std.Io.Mutex = .init,
        last_logs_uri: [512]u8 = undefined,
        last_logs_uri_len: usize = 0,

        fn run(ctx: *@This()) void {
            const alloc = std.heap.page_allocator;
            while (!ctx.stop.load(.acquire)) {
                const conn = ctx.server.accept(ctx.io) catch break;
                ctx.handleConn(alloc, conn) catch {};
            }
        }

        fn snapshotLastUri(ctx: *@This(), out: []u8) []const u8 {
            ctx.uri_mu.lockUncancelable(ctx.io);
            defer ctx.uri_mu.unlock(ctx.io);
            const n = @min(out.len, ctx.last_logs_uri_len);
            @memcpy(out[0..n], ctx.last_logs_uri[0..n]);
            return out[0..n];
        }

        fn handleConn(ctx: *@This(), alloc: std.mem.Allocator, conn: std.Io.net.Stream) !void {
            defer conn.close(ctx.io);
            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var r = conn.reader(ctx.io, &rbuf);
            var w = conn.writer(ctx.io, &wbuf);

            var req_buf: [2048]u8 = undefined;
            var total: usize = 0;
            while (total < req_buf.len) {
                const n = docker_logs.readReaderSome(&r.interface, req_buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (docker_logs.findHeaderEnd(req_buf[0..total]) != null) break;
            }
            const req_head = req_buf[0..total];
            const line_end = std.mem.indexOfScalar(u8, req_head, '\n') orelse return;
            const first_line = std.mem.trimEnd(u8, req_head[0..line_end], "\r");

            if (std.mem.indexOf(u8, first_line, "GET /_ping ") != null) {
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK");
                try w.interface.flush();
                return;
            }

            if (std.mem.indexOf(u8, first_line, "GET /containers/json") != null) {
                const body =
                    \\[
                    \\  {"Id":"1111111111112222222222223333333333334444444444445555555555556666","Names":["/gateway"],"Image":"envoy:v1.31","State":"running","Status":"Up 1h","Created":1763114400},
                    \\  {"Id":"2222222222223333333333334444444444445555555555556666777777778888","Names":["/worker-tty"],"Image":"alpine:3.20","State":"running","Status":"Up 1h","Created":1763114400},
                    \\  {"Id":"3333333333334444444444445555555555556666666666667777777777778888","Names":["/no-log-driver"],"Image":"pause:3.9","State":"running","Status":"Up 1h","Created":1763114400}
                    \\]
                ;
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n");
                try docker_logs.writeChunkedBody(&w.interface, body, 64);
                try w.interface.flush();
                return;
            }

            if (std.mem.indexOf(u8, first_line, "/logs") != null) {
                ctx.uri_mu.lockUncancelable(ctx.io);
                const copy_n = @min(first_line.len, ctx.last_logs_uri.len);
                @memcpy(ctx.last_logs_uri[0..copy_n], first_line[0..copy_n]);
                ctx.last_logs_uri_len = copy_n;
                ctx.uri_mu.unlock(ctx.io);
            }

            // Container 1: `gateway` (multiplexed stdout + stderr + >16 KiB split line + optional live append)
            if (std.mem.indexOf(u8, first_line, "/containers/111111111111") != null) {
                var since_filter_sec: ?u64 = null;
                if (std.mem.indexOf(u8, first_line, "since=")) |s_idx| {
                    const rest = first_line[s_idx + 6 ..];
                    var end_idx: usize = 0;
                    while (end_idx < rest.len and std.ascii.isDigit(rest[end_idx])) : (end_idx += 1) {}
                    if (end_idx > 0) {
                        since_filter_sec = std.fmt.parseInt(u64, rest[0..end_idx], 10) catch null;
                    }
                }
                var tp_line1 = time_parser.CompiledTimeParser{};
                const line1_sec: u64 = @intCast(@divFloor(
                    tp_line1.parseLine("2026-11-14T10:00:00Z", .{}, null, null).?,
                    std.time.ns_per_s,
                ));

                var mux: std.ArrayList(u8) = .empty;
                defer mux.deinit(alloc);

                // Line 1 (10:00:00Z, stdout) — honored by Docker `--since`
                if (since_filter_sec == null or line1_sec >= since_filter_sec.?) {
                    try docker_logs.appendDockerMuxFrame(
                        alloc,
                        &mux,
                        1,
                        "2026-11-14T10:00:00.100000000Z {\"service\":\"gateway\",\"status\":200,\"trace\":\"TR-100\",\"env\":\"prod\"}\n",
                    );
                }

                // Split >16 KiB stdout frame (10:05:00.250Z) + interleaved stderr frame (flushes as Line 2) + continuation stdout frame (flushes as Line 3)
                var part1: std.ArrayList(u8) = .empty;
                defer part1.deinit(alloc);
                try part1.appendSlice(alloc, "2026-11-14T10:05:00.250000000Z {\"service\":\"gateway\",\"status\":502,\"trace\":\"TR-200\",\"pad\":\"");
                try part1.appendNTimes(alloc, 'X', 16420);
                try docker_logs.appendDockerMuxFrame(alloc, &mux, 1, part1.items);

                // Line 2 (10:05:00.600Z, stderr)
                try docker_logs.appendDockerMuxFrame(
                    alloc,
                    &mux,
                    2,
                    "2026-11-14T10:05:00.600000000Z [STDERR] status=502 trace=TR-201 env=prod debug_noise\n",
                );

                // Line 3 continuation (duplicate Docker timestamp stripped!)
                try docker_logs.appendDockerMuxFrame(
                    alloc,
                    &mux,
                    1,
                    "2026-11-14T10:05:00.250000000Z _SPLIT_END\",\"env\":\"prod\"}\n",
                );

                // Line 4 (10:10:00Z, stdout)
                try docker_logs.appendDockerMuxFrame(
                    alloc,
                    &mux,
                    1,
                    "2026-11-14T10:10:00.900000000Z {\"service\":\"gateway\",\"status\":502,\"trace\":\"TR-300\",\"env\":\"staging\"}\n",
                );

                // Optional live-appended Line 5
                if (ctx.live_appended.load(.acquire)) {
                    try docker_logs.appendDockerMuxFrame(
                        alloc,
                        &mux,
                        1,
                        "2026-11-14T10:12:00.000000000Z {\"service\":\"gateway\",\"status\":502,\"trace\":\"TR-LIVE-999\",\"env\":\"prod\"}\n",
                    );
                }

                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\nTransfer-Encoding: chunked\r\n\r\n");
                try docker_logs.writeChunkedBody(&w.interface, mux.items, 53);
                try w.interface.flush();
                return;
            }

            // Container 2: `worker-tty` (Tty: true raw-stream)
            if (std.mem.indexOf(u8, first_line, "/containers/222222222222") != null) {
                const raw_tty = "2026-11-14T10:05:30.000000000Z worker status=502 trace=TR-TTY env=prod\r\n";
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\nTransfer-Encoding: chunked\r\n\r\n");
                try docker_logs.writeChunkedBody(&w.interface, raw_tty, 19);
                try w.interface.flush();
                return;
            }

            // Container 3: `no-log-driver` (`--log-driver=none` returns HTTP 501)
            if (std.mem.indexOf(u8, first_line, "/containers/333333333333") != null) {
                const msg = "{\"message\":\"configured logging driver does not support reading\"}";
                try w.interface.print("HTTP/1.1 501 Not Implemented\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ msg.len, msg });
                try w.interface.flush();
                return;
            }

            try w.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            try w.interface.flush();
        }
    };

    var mock = MockServer{ .server = &srv, .io = io };
    const srv_thread = try std.Thread.spawn(.{}, MockServer.run, .{&mock});
    defer {
        mock.stop.store(true, .release);
        if (ua.connect(io)) |wake_conn| {
            wake_conn.close(io);
        } else |_| {}
        srv.deinit(io);
        srv_thread.join();
    }

    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);
    reg.docker_host = sock_rel_path;

    try reg.upsertSource(arena, io, .{
        .kind = "docker",
        .name = "docker",
        .config = .{ .path = "auto" },
        .enabled = true,
    });

    const Collector = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mu: std.Io.Mutex = .init,
        matched_lines: u64 = 0,
        files_matched: u64 = 0,
        files_searched: u64 = 0,
        gateway_lines: std.ArrayList(u64) = .empty,
        cache_hit: [32]u8 = undefined,
        cache_len: usize = 0,

        fn deinit(self: *@This()) void {
            self.gateway_lines.deinit(self.allocator);
        }

        fn tier(self: *const @This()) []const u8 {
            return self.cache_hit[0..self.cache_len];
        }

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);

            if (std.mem.indexOf(u8, json_text, "\"type\":\"hits\"") != null) {
                var parsed = try std.json.parseFromSlice(HitsFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                for (parsed.value.items) |it| {
                    if (std.mem.eql(u8, it.file, "docker/gateway")) {
                        try self.gateway_lines.append(self.allocator, it.line);
                    }
                }
            } else if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, self.allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.matched_lines = parsed.value.matchedLines;
                self.files_matched = parsed.value.filesMatched;
                self.files_searched = parsed.value.filesSearched;
                const ch = parsed.value.cacheHit;
                const n = @min(ch.len, self.cache_hit.len);
                @memcpy(self.cache_hit[0..n], ch[0..n]);
                self.cache_len = n;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);

    // 1. Multi-level same-line convergence (`502` + `prod` - `debug_noise`) across >16 KiB multiplexed + raw TTY + 501 container
    {
        var c1 = Collector{ .allocator = gpa, .io = io };
        defer c1.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
            .id = 1001,
            .pattern = "502",
            .contains = &.{"prod"},
            .excludes = &.{"debug_noise"},
        }, &cancel, .{ .ctx = &c1, .sendFn = Collector.send });

        try std.testing.expectEqual(@as(u64, 3), c1.files_searched);
        try std.testing.expectEqual(@as(u64, 2), c1.files_matched);
        try std.testing.expectEqual(@as(u64, 2), c1.matched_lines);
        try std.testing.expectEqualStrings("none", c1.tier());
        try std.testing.expectEqual(@as(usize, 1), c1.gateway_lines.items.len);
        try std.testing.expectEqual(@as(u64, 3), c1.gateway_lines.items[0]);

        // `/api/file` line 3 on `docker/gateway` must match the exact >16 KiB reassembled record
        const preview_l3 = try reg.buildLinePreviewJson(arena, io, "docker/gateway", 3, 0);
        try std.testing.expect(std.mem.indexOf(u8, preview_l3, "TR-200") != null);
        try std.testing.expect(std.mem.indexOf(u8, preview_l3, "_SPLIT_END") != null);
    }

    // 2. Scope file-type filter: `types = ["log"]` matches Docker containers, `types = ["zig"]` excludes them
    {
        var c_log = Collector{ .allocator = gpa, .io = io };
        defer c_log.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
            .id = 1002,
            .pattern = "TR-100",
            .types = &.{"log"},
        }, &cancel, .{ .ctx = &c_log, .sendFn = Collector.send });
        try std.testing.expectEqual(@as(u64, 1), c_log.matched_lines);

        var c_zig = Collector{ .allocator = gpa, .io = io };
        defer c_zig.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
            .id = 1003,
            .pattern = "TR-100",
            .types = &.{"zig"},
        }, &cancel, .{ .ctx = &c_zig, .sendFn = Collector.send });
        try std.testing.expectEqual(@as(u64, 0), c_zig.matched_lines);
    }

    // 3. Nanosecond line-timestamp window [10:04:00Z, 10:06:00Z] pushes BOTH `since=` and `until=` in `.auto`
    // mode and aligns 1:1 with `/api/file?since=`, while non-auto `timeFormat` skips `since`/`until` pushdown!
    {
        var tp = time_parser.CompiledTimeParser{};
        const lo_ns = tp.parseLine("2026-11-14T10:04:00Z", .{}, null, null).?;
        const hi_ns = tp.parseLine("2026-11-14T10:06:00Z", .{}, null, null).?;
        const expected_since_sec = (@as(u64, @intCast(lo_ns)) / std.time.ns_per_s) -| 2;

        var c_time = Collector{ .allocator = gpa, .io = io };
        defer c_time.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
            .id = 1004,
            .pattern = "TR-",
            .timeMode = "source",
            .timeStartMs = lo_ns / std.time.ns_per_ms,
            .timeEndMs = hi_ns / std.time.ns_per_ms,
        }, &cancel, .{ .ctx = &c_time, .sendFn = Collector.send });

        var uri_scratch: [512]u8 = undefined;
        const seen_uri = mock.snapshotLastUri(&uri_scratch);
        try std.testing.expect(std.mem.indexOf(u8, seen_uri, "until=") != null);
        try std.testing.expect(std.mem.indexOf(u8, seen_uri, "since=") != null);

        // With `since=10:03:58Z`, `gateway` emits lines 1 & 2 (10:05:00Z) + `worker-tty` line 1 (10:05:30Z) = 3 matches!
        try std.testing.expectEqual(@as(u64, 3), c_time.matched_lines);
        try std.testing.expectEqual(@as(usize, 2), c_time.gateway_lines.items.len);
        try std.testing.expectEqual(@as(u64, 1), c_time.gateway_lines.items[0]);
        try std.testing.expectEqual(@as(u64, 2), c_time.gateway_lines.items[1]);

        const aligned_preview = try reg.buildLinePreviewJsonWithSince(
            arena,
            io,
            "docker/gateway",
            c_time.gateway_lines.items[1],
            0,
            expected_since_sec,
        );
        try std.testing.expect(std.mem.indexOf(u8, aligned_preview, "_SPLIT_END") != null);

        // Non-auto `timeFormat` must NOT push `since=` or `until=`
        var c_custom = Collector{ .allocator = gpa, .io = io };
        defer c_custom.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
            .id = 1014,
            .pattern = "TR-",
            .timeMode = "content",
            .timeFormat = "%Y-%m-%dT%H:%M:%S",
            .timeStartMs = lo_ns / std.time.ns_per_ms,
            .timeEndMs = hi_ns / std.time.ns_per_ms,
        }, &cancel, .{ .ctx = &c_custom, .sendFn = Collector.send });

        const seen_custom_uri = mock.snapshotLastUri(&uri_scratch);
        try std.testing.expect(std.mem.indexOf(u8, seen_custom_uri, "since=") == null);
        try std.testing.expect(std.mem.indexOf(u8, seen_custom_uri, "until=") == null);
        try std.testing.expectEqual(@as(u64, 3), c_custom.matched_lines);
        try std.testing.expectEqual(@as(u64, 3), c_custom.gateway_lines.items[1]);
    }

    // 4. Live-append cache bypass: appending a new line to a running container is immediately visible on repeat query (`cacheHit == "none"`)
    {
        var c_before = Collector{ .allocator = gpa, .io = io };
        defer c_before.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
            .id = 1005,
            .pattern = "TR-LIVE-999",
        }, &cancel, .{ .ctx = &c_before, .sendFn = Collector.send });
        try std.testing.expectEqual(@as(u64, 0), c_before.matched_lines);
        try std.testing.expectEqualStrings("none", c_before.tier());

        mock.live_appended.store(true, .release);

        var c_after = Collector{ .allocator = gpa, .io = io };
        defer c_after.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
            .id = 1006,
            .pattern = "TR-LIVE-999",
        }, &cancel, .{ .ctx = &c_after, .sendFn = Collector.send });
        try std.testing.expectEqual(@as(u64, 1), c_after.matched_lines);
        try std.testing.expectEqualStrings("none", c_after.tier());
        try std.testing.expectEqual(@as(u64, 5), c_after.gateway_lines.items[0]);
    }

    // 5. Multi-line proximity (`nearbyLines > 0`) matches terms spanning adjacent Docker container lines in RAM (zero disk writes)
    {
        var c_strict = Collector{ .allocator = gpa, .io = io };
        defer c_strict.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
            .id = 1007,
            .pattern = "TR-300",
            .contains = &.{"TR-LIVE-999"},
            .nearbyLines = 0,
        }, &cancel, .{ .ctx = &c_strict, .sendFn = Collector.send });
        try std.testing.expectEqual(@as(u64, 0), c_strict.matched_lines);

        var c_nearby = Collector{ .allocator = gpa, .io = io };
        defer c_nearby.deinit();
        try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
            .id = 1008,
            .pattern = "TR-300",
            .contains = &.{"TR-LIVE-999"},
            .nearbyLines = 5,
        }, &cancel, .{ .ctx = &c_nearby, .sendFn = Collector.send });
        try std.testing.expectEqual(@as(u64, 1), c_nearby.matched_lines);
        try std.testing.expectEqualStrings("nearby", c_nearby.tier());
    }
}

test "Docker E2E search: >16 MiB stream nearbyLines bounded prefix read matches without StreamTooLarge" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_path = try arena.dupe(u8, real_buf[0..tmp_path_len]);

    const sock_rel_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/big.sock", .{tmp.sub_path});
    const ua = try std.Io.net.UnixAddress.init(sock_rel_path);
    var srv = try ua.listen(io, .{});

    const BigServer = struct {
        server: *std.Io.net.Server,
        io: std.Io,
        stop: std.atomic.Value(bool) = .init(false),

        fn run(ctx: *@This()) void {
            while (!ctx.stop.load(.acquire)) {
                const conn = ctx.server.accept(ctx.io) catch break;
                ctx.handleConn(conn) catch {};
            }
        }

        fn handleConn(ctx: *@This(), conn: std.Io.net.Stream) !void {
            defer conn.close(ctx.io);
            var rbuf: [2048]u8 = undefined;
            var wbuf: [32768]u8 = undefined;
            var r = conn.reader(ctx.io, &rbuf);
            var w = conn.writer(ctx.io, &wbuf);

            var req_buf: [2048]u8 = undefined;
            var total: usize = 0;
            while (total < req_buf.len) {
                const n = docker_logs.readReaderSome(&r.interface, req_buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (docker_logs.findHeaderEnd(req_buf[0..total]) != null) break;
            }
            const req_head = req_buf[0..total];
            const line_end = std.mem.indexOfScalar(u8, req_head, '\n') orelse return;
            const first_line = std.mem.trimEnd(u8, req_head[0..line_end], "\r");

            if (std.mem.indexOf(u8, first_line, "GET /_ping ") != null) {
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK");
                try w.interface.flush();
                return;
            }
            if (std.mem.indexOf(u8, first_line, "GET /containers/json") != null) {
                const body =
                    \\[{"Id":"4444444444445555555555556666666666667777777777778888888888889999","Names":["/big-stream"],"Image":"nginx:latest","State":"running","Status":"Up","Created":1763114400}]
                ;
                try w.interface.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
                try w.interface.flush();
                return;
            }
            if (std.mem.indexOf(u8, first_line, "/containers/444444444444") != null) {
                const head_lines =
                    "2026-11-14T10:00:00Z ALPHA_PREFIX_HIT\n" ++
                    "2026-11-14T10:00:01Z BETA_PREFIX_HIT\n";
                const pad_line = "2026-11-14T10:00:02Z pad_filler_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n";
                const pad_repeats: usize = 165_000; // ~16.5 MiB > 16 MiB
                const total_len: usize = head_lines.len + pad_repeats * pad_line.len;
                try w.interface.print(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\nContent-Length: {d}\r\n\r\n",
                    .{total_len},
                );
                try w.interface.writeAll(head_lines);
                var i: usize = 0;
                while (i < pad_repeats) : (i += 1) {
                    try w.interface.writeAll(pad_line);
                }
                try w.interface.flush();
                return;
            }
            try w.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            try w.interface.flush();
        }
    };

    var mock = BigServer{ .server = &srv, .io = io };
    const th = try std.Thread.spawn(.{}, BigServer.run, .{&mock});
    defer {
        mock.stop.store(true, .release);
        if (ua.connect(io)) |wc| wc.close(io) else |_| {}
        srv.deinit(io);
        th.join();
    }

    var reg = source_registry.SourceRegistry.init(gpa, io, tmp_path, null);
    defer reg.deinit(io);
    reg.docker_host = sock_rel_path;
    try reg.upsertSource(arena, io, .{
        .kind = "docker",
        .name = "docker",
        .config = .{ .path = "auto" },
        .enabled = true,
    });

    const DoneCollector = struct {
        io: std.Io,
        mu: std.Io.Mutex = .init,
        matched_lines: u64 = 0,
        tier_buf: [32]u8 = undefined,
        tier_len: usize = 0,

        fn send(ctx: *anyopaque, json_text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, json_text, "\"type\":\"done\"") != null) {
                var parsed = try std.json.parseFromSlice(DoneFrame, std.heap.page_allocator, json_text, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                self.matched_lines = parsed.value.matchedLines;
                const tn = @min(parsed.value.cacheHit.len, self.tier_buf.len);
                @memcpy(self.tier_buf[0..tn], parsed.value.cacheHit[0..tn]);
                self.tier_len = tn;
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var col = DoneCollector{ .io = io };
    try executeSearchWithRegistry(gpa, io, tmp.dir, &reg, .{
        .id = 2001,
        .pattern = "ALPHA_PREFIX_HIT",
        .contains = &.{"BETA_PREFIX_HIT"},
        .nearbyLines = 5,
    }, &cancel, .{ .ctx = &col, .sendFn = DoneCollector.send });

    try std.testing.expectEqual(@as(u64, 1), col.matched_lines);
    try std.testing.expectEqualStrings("nearby", col.tier_buf[0..col.tier_len]);
}
