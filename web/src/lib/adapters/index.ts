export type {
  AdapterBatchSummary,
  CodeDirStat,
  CodeLangStat,
  CodeLanguageInfo,
  CodeStreamStats,
  CodeVirtualItem,
  CodeVirtualLayout,
  FastLogProbe,
  HeadlessAdapter,
  LogVirtualLayout,
  ParsedLogRecord,
  ParsedPlainRecord,
  ParsedRecord,
  PlainRowProbe,
  RowActionIconKind,
  RowActionItem,
  RowLayoutMetrics,
  RowMeasureContext,
  ViewAdapter,
  ViewAdapterId,
  ViewModePreference,
} from './types.ts';

export {
  extractLineTime,
  formatLogTimestamp,
  preserveLargeJsonIntegers,
  probeLogLineFast,
  type FormattedLogTimestamp,
} from './log-parser.ts';

export {
  buildLogVirtualLayout,
  logAdapter,
  parseLineLogMeta,
  scoreLogConfidenceWithProbe,
} from './log-adapter.ts';

export {
  CODE_EXT_MAP,
  CODE_HEADER_HEIGHT,
  CodeStreamStatsTracker,
  buildCodeVirtualLayout,
  codeAdapter,
  detectCodeLanguage,
  extractCodeDirectory,
  isCodeOnlyPath,
  isCodeOrManifestPath,
  measureCodeHitRow,
  scoreCodeConfidence,
} from './code-adapter.ts';

export {
  PLAIN_BREADCRUMB_H,
  buildPlainVirtualLayout,
  estimatePlainColumns,
  parsePlainHitMeta,
  plainAdapter,
  type PlainVirtualLayout,
} from './plain-adapter.ts';

export { indexAtY } from './virtual-math.ts';

export {
  HEADLESS_ADAPTERS,
  VIEW_MODE_CYCLE_ORDER,
  classifyHitBestAdapter,
  getCachedLogProbe,
  getCachedParsedLog,
  getCachedPlainMeta,
  getCachedPlainProbe,
  getHeadlessAdapter,
  resolveBatchAdapterSummary,
  resolveDominantAdapter,
  resolveHitAdapterId,
  resolveSourceForHit,
} from './registry.ts';
