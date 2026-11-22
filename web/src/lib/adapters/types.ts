import type { HitItem, ViewAdapterId } from '../types.ts';

export type { ViewAdapterId };

export interface FastLogProbe {
  isLog: boolean;
  hasTime: boolean;
  isJson: boolean;
  isKv: boolean;
  dateKey: string;
  timeShort: string;
  timeLabel: string;
  timeFull: string;
  timeRaw: string;
  bodyStart: number;
}

export interface ParsedLogRecord {
  kind: 'log';
  srcName: string;
  dirLabel: string;
  fileName: string;
  timeLabel: string;
  timeFull: string;
  timeRaw: string;
  dateKey: string;
  bodyText: string;
}

export interface LineRowProbe {
  cols: number;
  budget: number;
}

export interface ParsedLineMeta {
  srcName: string;
  dirLabel: string;
  fileName: string;
  timeLabel: string;
  timeNs: string;
}

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
 * Pure headless adapter descriptor (zero Svelte/DOM imports) bound 1:1 to a DataSource mode
 * (`'log'` for timeseries/log sources, `'code'` for codebase sources).
 */
export interface HeadlessAdapter {
  readonly id: ViewAdapterId;
  readonly order: number;
  /** Surrounding context lines to auto-fetch for Inspector (0 = single-line fast path; 12 = code snippet). */
  readonly inspectContextLines: number;
  /** Whether InspectorHeader displays the Structured/Raw toggle button. */
  readonly supportsStructuredToggle: boolean;
  getFormattedCopyText?(lineText: string, hit: HitItem | null): string | null;
}

export interface LogVirtualLayout {
  offsets: Float64Array;
  lines: Uint8Array;
  totalHeight: number;
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
