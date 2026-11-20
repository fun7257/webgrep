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
  LogCategoryStat,
  LogFormat,
  LogHttpMeta,
  LogKeyField,
  LogLevel,
  LogLevelStat,
  LogStreamStats,
  LogVirtualItem,
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
  formatLogTimestamp,
  normalizeLogLevel,
  parseLogLine,
  parseTruncatedJsonEnvelope,
  preserveLargeJsonIntegers,
  probeLogLineFast,
  type FormattedLogTimestamp,
} from './log-parser.ts';

export {
  LOG_DATE_DIVIDER_HEIGHT,
  buildFallbackParsedLog,
  buildLogVirtualLayout,
  logAdapter,
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
  LogStreamStatsTracker,
  VIEW_MODE_CYCLE_ORDER,
  classifyHitBestAdapter,
  doesTextContainActiveQuery,
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
