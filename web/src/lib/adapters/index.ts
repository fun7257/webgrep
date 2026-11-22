export type {
  CodeDirStat,
  CodeLangStat,
  CodeLanguageInfo,
  CodeStreamStats,
  CodeVirtualItem,
  CodeVirtualLayout,
  FastLogProbe,
  HeadlessAdapter,
  LineRowProbe,
  LogVirtualLayout,
  ParsedLineMeta,
  ParsedLogRecord,
  RowActionIconKind,
  RowActionItem,
  RowLayoutMetrics,
  RowMeasureContext,
  ViewAdapterId,
} from './types.ts';

export {
  extractLineTime,
  formatLogTimestamp,
  preserveLargeJsonIntegers,
  probeLogLineFast,
  type FormattedLogTimestamp,
} from './log-parser.ts';

export {
  LINE_BREADCRUMB_H,
  buildLogVirtualLayout,
  estimateLineColumns,
  logAdapter,
  measureLineHitRow,
  parseHitFileMeta,
  parseLineLogMeta,
} from './log-adapter.ts';

export {
  CODE_EXT_MAP,
  CODE_HEADER_HEIGHT,
  CodeStreamStatsTracker,
  buildCodeVirtualLayout,
  codeAdapter,
  detectCodeLanguage,
  extractCodeDirectory,
  measureCodeHitRow,
} from './code-adapter.ts';

export { indexAtY } from './virtual-math.ts';

export {
  HEADLESS_ADAPTERS,
  getCachedLogProbe,
  getCachedParsedLog,
  getCachedPlainMeta,
  getCachedPlainProbe,
  getHeadlessAdapter,
  resolveBatchViewAdapter,
  resolveHitAdapterId,
  resolvePathAdapterId,
  resolveSourceAdapterId,
  resolveSourceForHit,
} from './registry.ts';
