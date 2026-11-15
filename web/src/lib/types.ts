export type SearchMode = 'literal' | 'multi' | 'regex';
export type CaseMode = 'smart' | 'sensitive' | 'insensitive';

export type BuiltinTimePreset =
  | ''
  | '15m'
  | '1h'
  | '6h'
  | '24h'
  | 'today'
  | 'yesterday'
  | '7d'
  | '30d';
/** Built-in preset or custom range spec (e.g. `2026-11-13 10:00:00..2026-11-14 12:30:00`). */
export type TimePreset = BuiltinTimePreset | (string & {});

export interface SearchInputFlags {
  caseSensitive: boolean;
  wholeWord: boolean;
  isRegex: boolean;
  isExclude?: boolean;
}

export interface QueryStep {
  text: string;
  exclude: boolean;
  caseSensitive: boolean;
  wholeWord: boolean;
  isRegex: boolean;
}

export type TimeFilterMode = 'source' | 'content' | 'mtime';

export interface ScopeFilter {
  /** Data source IDs or names; empty = all enabled sources. */
  sources: string[];
  /** Excluded source IDs or names (`!id` in wire `globs`). */
  excludedSources?: string[];
  /** File type IDs (e.g. `zig`, `log`, `json`); empty = all types. */
  types: string[];
  /** Quick time window; `''` = any time. */
  timePreset: TimePreset;
  /** Which timestamp dimension `timePreset` filters against: `'content'` (line timestamps) or `'mtime'` (file mtime). */
  timeMode?: TimeFilterMode;
  /** Optional custom line-timestamp format (`""` = auto, strftime mask, `json:<field>`, or `regex:<pat>`). */
  timeFormat?: string;
}

export interface MetaResponse {
  rootLabel: string;
  root: string;
  engine: string;
  types: string[];
  scopes?: string[];
}

export interface FileLine {
  n: number;
  text: string;
}

export interface FileResponse {
  path: string;
  startLine: number;
  totalLines: number;
  binary: boolean;
  eof: boolean;
  lines: FileLine[];
}

export interface HitSpan {
  start: number;
  end: number;
}

export interface HitItem {
  file: string;
  line: number;
  col: number;
  text: string;
  prevText?: string | null;
  nextText?: string | null;
  replaced?: string | null;
  isContext?: boolean;
  spans: HitSpan[];
}

export type SourceKind = 'dir' | 'file' | 'docker' | (string & {});

export interface SourceKindMeta {
  kind: SourceKind;
  label: string;
}

export interface SourceConfig {
  path: string;
  endpoint?: string | null;
  timeFormat?: string | null;
}

export interface DataSourceItem {
  id: string;
  kind: SourceKind;
  name: string;
  enabled: boolean;
  ready: boolean;
  summary: string;
  config: SourceConfig;
  path: string;
  exists: boolean;
}

export type DataSourceEntry = DataSourceItem;

export interface SourcesResponse {
  kinds?: SourceKindMeta[];
  searchCount?: number;
  sources: DataSourceItem[];
}

export interface DirSuggestEntry {
  name: string;
  path: string;
  isDir?: boolean;
}

export interface DirSuggestResponse {
  kind?: SourceKind;
  entries: DirSuggestEntry[];
}

export interface WsSearchMessage {
  type: 'search';
  id: number;
  tenant: string;
  /** Wire terms produced by `compileSearchQuery` (`$c(…)` / `$r(…)` / `$w(…)`). */
  pattern: string;
  mode: SearchMode;
  case: CaseMode;
  contains: string[];
  excludes: string[];
  context: number;
  sources?: string[];
  types?: string[];
  /** Data source exclusions (`!id`). */
  globs: string[];
  /** File / path patterns (`!` = exclude). */
  fileGlobs: string[];
  hidden: boolean;
  respectIgnore: boolean;
  maxResults: number;
  nearbyLines: number;
  timeStartMs?: number;
  timeEndMs?: number;
  timeMode?: TimeFilterMode;
  timeFormat?: string;
  tzOffsetMin?: number;
}

export interface TimePreviewResponse {
  validFormat: boolean;
  matched: boolean;
  epochMs?: number | null;
  isoUtc?: string | null;
  localDisplay?: string | null;
  errorMessage?: string | null;
  error?: string | null;
}

export interface WsCancelMessage {
  type: 'cancel';
  id: number;
}

export type WsIncomingMessage =
  | {
      type: 'hits';
      id: number;
      items: HitItem[];
    }
  | {
      type: 'progress';
      id: number;
      filesSearched: number;
      filesMatched: number;
      matches: number;
      bytesSearched: number;
    }
  | {
      type: 'done';
      id: number;
      elapsedMs: number;
      filesSearched: number;
      filesMatched: number;
      totalMatches: number;
      matchedLines: number;
      bytesSearched: number;
      limitHit: string | boolean;
      searchCount?: number;
      cacheHit?: string;
      nearbyLines?: number;
    }
  | {
      type: 'error';
      id: number;
      message: string;
    };

export interface FileHitGroup {
  file: string;
  items: HitItem[];
  matchCount: number;
  collapsed: boolean;
}

export interface SearchHistoryEntry {
  id: string;
  steps: QueryStep[];
  draft: QueryStep | null;
  scope: ScopeFilter;
  label: string;
  timestamp: number;
}

