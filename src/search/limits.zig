const std = @import("std");
const libwebgrep = @import("libwebgrep");
const file_api = @import("../file_api.zig");

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

pub fn isSingleStreamCompressed(path: []const u8) bool {
    if (detectArchiveFormat(path) != null) return false;
    return file_api.hasCompressedExtension(path);
}

pub fn formatArchiveVirtualPathAlloc(
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
