//! Public facade for multi-format timestamp parsing, strftime/picture compilation,
//! JSON/regex timestamp extractors, and binary-search slice narrowing (`src/time/*`).

pub const calendar = @import("time/calendar.zig");
pub const universal = @import("time/universal.zig");
pub const picture_compile = @import("time/picture_compile.zig");
pub const strftime = @import("time/strftime.zig");
pub const extractors = @import("time/extractors.zig");
pub const slice_narrow = @import("time/slice_narrow.zig");

pub const TimeMode = calendar.TimeMode;
pub const FallbackTimeContext = calendar.FallbackTimeContext;
pub const PrefixEpochCache = calendar.PrefixEpochCache;
pub const currentUnixNano = calendar.currentUnixNano;
pub const CivilDateTime = calendar.CivilDateTime;
pub const civilToEpochSeconds = calendar.civilToEpochSeconds;
pub const epochSecondsToCivil = calendar.epochSecondsToCivil;

pub const parseTimestampValueNs = universal.parseTimestampValueNs;
pub const parseUniversalLineNs = universal.parseUniversalLineNs;

pub const MAX_STRFTIME_OPS = strftime.MAX_STRFTIME_OPS;
pub const MAX_STRFTIME_LIT_BYTES = strftime.MAX_STRFTIME_LIT_BYTES;
pub const TimeOpTag = strftime.TimeOpTag;
pub const TimeOp = strftime.TimeOp;
pub const StrftimeProg = strftime.StrftimeProg;

pub const MAX_JSON_PATH_DEPTH = extractors.MAX_JSON_PATH_DEPTH;
pub const JsonFieldProg = extractors.JsonFieldProg;
pub const RegexCaptureProg = extractors.RegexCaptureProg;
pub const CompiledTimeParser = extractors.CompiledTimeParser;
pub const TimeHookAdapter = extractors.TimeHookAdapter;

pub const isLikelyContinuationLine = slice_narrow.isLikelyContinuationLine;
pub const findLineStartAtOrBefore = slice_narrow.findLineStartAtOrBefore;
pub const countNewlinesFast = slice_narrow.countNewlinesFast;
pub const findLineTimestampWithLookbehind = slice_narrow.findLineTimestampWithLookbehind;
pub const SliceTimeStatus = slice_narrow.SliceTimeStatus;
pub const NarrowedSlice = slice_narrow.NarrowedSlice;
pub const narrowSliceByTimeParser = slice_narrow.narrowSliceByTimeParser;
pub const TimePreviewResponse = slice_narrow.TimePreviewResponse;
pub const buildTimePreviewJson = slice_narrow.buildTimePreviewJson;

test {
    _ = @import("time/tests.zig");
}
