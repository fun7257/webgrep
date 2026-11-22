const std = @import("std");
const file_api = @import("../file_api.zig");
const source_registry = @import("../source_registry.zig");

pub const KvPredicateDto = struct {
    key: []const u8,
    op: []const u8 = "eq",
    value: []const u8 = "",
    caseSensitive: bool = false,
};

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
    pluginPreset: ?[]const u8 = null,
    plugins: ?source_registry.PluginsOverrideDto = null,
    kvPredicates: []const KvPredicateDto = &.{},
    pluginSig: u64 = 0,
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
    filesPruned: u64 = 0,
    bytesSaved: u64 = 0,
    bytesScanned: u64 = 0,
};

pub const ErrorFrame = struct {
    type: []const u8 = "error",
    id: u64,
    message: []const u8,
};

pub fn sendError(gpa: std.mem.Allocator, sender: FrameSender, id: u64, msg: []const u8) !void {
    const err_json = try file_api.stringifyAlloc(gpa, ErrorFrame{
        .id = id,
        .message = msg,
    });
    defer gpa.free(err_json);
    try sender.send(err_json);
}
