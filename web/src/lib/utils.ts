/**
 * Clean facade barrel re-exporting formatting, highlight segmentation,
 * structured analysis, and code syntax highlighting utilities.
 */

export {
  cn,
  copyTextToClipboard,
  detectInlineEpochHint,
  extractLeadingNanoTimestamp,
  formatBytes,
  formatMs,
  formatThroughput,
  skipLeadingNanoTimestampOffset,
  splitFilePath,
  type NanoTimestampInfo,
} from './format.ts';

export {
  buildHighlightSegments,
  getCachedHighlightSegments,
  type HighlightSegment,
} from './highlight/segments.ts';

export {
  analyzeStructuredLine,
  decodeHumanEscapes,
  formatContextRecordPretty,
  universalPrettyStructure,
  type StructuredAnalysis,
} from './structured/analyzer.ts';

export {
  highlightCodeWithMatches,
  syntaxKindToClass,
  type CodeHighlightSegment,
  type SyntaxTokenKind,
} from './highlight/syntax.ts';
