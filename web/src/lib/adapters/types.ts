import type { DataSourceItem, HitItem, ViewAdapterId, ViewModePreference } from '../types.ts';

export type { ViewAdapterId, ViewModePreference };

export type LogLevel = 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace' | 'unknown';

export type LogFormat = 'ndjson' | 'truncated-json' | 'docker-json' | 'kv' | 'text-log';

export interface LogKeyField {
  key: string;
  label: string;
  value: string;
  role: 'trace' | 'identity' | 'http' | 'metric' | 'error' | 'extra';
  filterToken: string;
}

export interface LogHttpMeta {
  method?: string;
  route?: string;
  uri?: string;
  status?: number;
  latencyText?: string;
  sizeText?: string;
  ip?: string;
  host?: string;
}

export interface FastLogProbe {
  isLog: boolean;
  dateKey: string;
  level: LogLevel;
  levelFilterToken: string;
  category: string;
  categoryFilterToken: string;
  estimatedSummaryCols: number;
  hasLongPayload: boolean;
}

export interface ParsedLogRecord {
  kind: 'log';
  format: LogFormat;
  /** Fixed-width HH:MM:SS.mmm (padded to 3 fractional digits for tabular-nums alignment). */
  timeShort: string;
  /** YYYY-MM-DD (or MM-DD) for date-change display & tooltips. */
  timeDate: string;
  /** Full human timestamp e.g. "2026-09-11 08:00:00.010 +08:00". */
  timeFull: string;
  timeRaw: string;
  level: LogLevel;
  /** FTL | ERR | WRN | INF | DBG | TRC | '' */
  levelBadge: string;
  /** Exact literal token for backend libwebgrep filtering e.g. `"l":"error"` or `level=error`. */
  levelFilterToken: string;
  category: string;
  categoryFilterToken: string;
  /** Primary readable headline (message / error / HTTP method+route / clean KV summary). */
  summary: string;
  /** Distinct error text if present alongside message or standalone error detail. */
  errorText: string;
  http?: LogHttpMeta;
  traceId: string;
  traceKey: string;
  traceFilterToken: string;
  /** High-signal non-empty compact fields (excluding empty strings). */
  keyFields: LogKeyField[];
  /** True for hard-truncated JSON lines (e.g. 4984B lines in test.log). */
  truncated: boolean;
  truncatedTail?: string;
  structuredData?: Record<string, unknown>;
  remainingFields?: Record<string, unknown>;
  /** Underlying text used for fallback match-centered excerpt if match lives outside summary. */
  rawRestText: string;
}

export interface PlainRowProbe {
  cols: number;
  budget: number;
}

export interface ParsedPlainRecord {
  kind: 'plain';
  srcName: string;
  dirLabel: string;
  fileName: string;
  timeLabel: string;
  timeNs: string;
}

export type ParsedRecord = ParsedLogRecord | ParsedPlainRecord;

export interface RowMeasureContext {
  fontPx: number;
  lineHeight: number;
  baseHitPad: number;
  maxPreviewLines: number;
  wordWrap: boolean;
  charsPerLine: number;
  isCompact: boolean;
  density: 'compact' | 'comfortable';
}

export interface RowLayoutMetrics {
  lines: number;
  height: number;
}

/**
 * Pure headless adapter descriptor (zero Svelte/DOM imports) powering routing,
 * inspector context behavior, and surface-level selection.
 */
export interface HeadlessAdapter {
  readonly id: ViewAdapterId;
  readonly order: number;
  /** Surrounding context lines to auto-fetch for Inspector (0 = single-line fast path; 12 = code snippet). */
  readonly inspectContextLines: number;
  /** Whether InspectorHeader displays the Structured/Raw toggle button. */
  readonly supportsStructuredToggle: boolean;
  classifyHit(item: HitItem, source?: DataSourceItem): number;
  getFormattedCopyText?(lineText: string, hit: HitItem | null): string | null;
}

export interface ViewAdapter<TProbe = unknown, TRecord extends ParsedRecord = ParsedRecord>
  extends HeadlessAdapter {
  detectConfidence(item: HitItem, source?: DataSourceItem): number;
  probeFast(item: HitItem, source?: DataSourceItem): TProbe;
  parse(item: HitItem, source?: DataSourceItem): TRecord;
  measureRow(probe: TProbe, item: HitItem, ctx: RowMeasureContext): RowLayoutMetrics;
}

export interface AdapterBatchSummary {
  activeAdapter: ViewAdapterId;
  detectedDominant: ViewAdapterId;
  isMixed: boolean;
  sampleCount: number;
  sampleCounts: Record<ViewAdapterId, number>;
}

export interface LogLevelStat {
  level: LogLevel;
  badge: string;
  count: number;
  filterToken: string;
}

export interface LogCategoryStat {
  category: string;
  count: number;
  filterToken: string;
}

export interface LogStreamStats {
  totalScanned: number;
  logCount: number;
  levels: LogLevelStat[];
  topCategories: LogCategoryStat[];
}

export type LogVirtualItem =
  | {
      kind: 'date';
      key: string;
      dateKey: string;
      height: number;
    }
  | {
      kind: 'hit';
      key: string;
      hitIdx: number;
      item: HitItem;
      isNativeLog: boolean;
      lines: number;
      height: number;
    };

export interface LogVirtualLayout {
  items: LogVirtualItem[];
  offsets: Float64Array;
  hitIdxToVirtualIdx: Int32Array;
  totalHeight: number;
  denseLogMode: boolean;
}

export interface CodeLanguageInfo {
  id: string;
  label: string;
  ext: string;
}

export interface CodeLangStat {
  id: string;
  label: string;
  count: number;
}

export interface CodeDirStat {
  dir: string;
  count: number;
}

export interface CodeStreamStats {
  totalScanned: number;
  fileCount: number;
  languages: CodeLangStat[];
  topDirs: CodeDirStat[];
}

export type CodeVirtualItem =
  | {
      kind: 'file-header';
      key: string;
      file: string;
      srcName: string;
      showSrc: boolean;
      dirLabel: string;
      fileName: string;
      lang: CodeLanguageInfo | null;
      matchCount: number;
      collapsed: boolean;
      firstHitIdx: number;
      height: number;
    }
  | {
      kind: 'hit';
      key: string;
      hitIdx: number;
      item: HitItem;
      srcName: string;
      fileName: string;
      lang: CodeLanguageInfo | null;
      lines: number;
      height: number;
    };

export interface CodeVirtualLayout {
  items: CodeVirtualItem[];
  offsets: Float64Array;
  hitIdxToVirtualIdx: Int32Array;
  totalHeight: number;
  matchedHitCount: number;
  visibleFileCount: number;
  totalFileCount: number;
  allCollapsed: boolean;
}

export type RowActionIconKind =
  | 'copy'
  | 'copy-path'
  | 'trace'
  | 'context'
  | 'solo-source'
  | 'exclude-source';

export interface RowActionItem {
  id: string;
  label: string;
  title: string;
  iconKind: RowActionIconKind;
  accent?: boolean;
  run: () => void;
}
