//! Public facade for the parallel search engine (`src/search/*`).
//! Re-exports protocol DTOs, limits, query helpers, and search entrypoints
//! with zero runtime overhead while keeping every submodule concise and orthogonal.

pub const protocol = @import("search/protocol.zig");
pub const limits = @import("search/limits.zig");
pub const query_plan = @import("search/query_plan.zig");
pub const types = @import("search/types.zig");
pub const path_filter = @import("search/path_filter.zig");
pub const cache_ops = @import("search/cache_ops.zig");
pub const proximity = @import("search/proximity.zig");
pub const sink = @import("search/sink.zig");
pub const worker = @import("search/worker.zig");
pub const worker_special = @import("search/worker_special.zig");
pub const runner = @import("search/runner.zig");
pub const execute = @import("search/execute.zig");

// Protocol DTOs & frame types
pub const KvPredicateDto = protocol.KvPredicateDto;
pub const SearchRequest = protocol.SearchRequest;
pub const FrameSender = protocol.FrameSender;
pub const HitSpan = protocol.HitSpan;
pub const HitItem = protocol.HitItem;
pub const HitsFrame = protocol.HitsFrame;
pub const ProgressFrame = protocol.ProgressFrame;
pub const DoneFrame = protocol.DoneFrame;
pub const ErrorFrame = protocol.ErrorFrame;

// Engine limits, archive & file-type helpers
pub const EngineLimits = limits.EngineLimits;
pub const ARCHIVE_VIRTUAL_SEP = limits.ARCHIVE_VIRTUAL_SEP;
pub const detectArchiveFormat = limits.detectArchiveFormat;
pub const formatRegexDiagnosticAlloc = limits.formatRegexDiagnosticAlloc;
pub const custom_file_types = limits.custom_file_types;

// Query parsing helpers
pub const parseCaseMode = query_plan.parseCaseMode;
pub const hasRegexMeta = query_plan.hasRegexMeta;

// Search execution entrypoints
pub const executeSearchJson = execute.executeSearchJson;
pub const executeSearch = execute.executeSearch;
pub const executeSearchWithRegistry = execute.executeSearchWithRegistry;

test {
    _ = @import("search/tests_core.zig");
    _ = @import("search/tests_features.zig");
    _ = @import("search/tests_e2e.zig");
}
