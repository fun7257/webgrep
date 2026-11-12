export type SearchMode = 'literal' | 'multi' | 'regex';
export type CaseMode = 'smart' | 'sensitive' | 'insensitive';

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

export type SourceKind = 'dir' | 'file' | string;

export interface SourceKindMeta {
  kind: SourceKind;
  label: string;
}

export interface SourceConfig {
  path: string;
  endpoint?: string | null;
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
  /** Wire terms produced by `parseSearchQuery` (`$c(…)` / `$r(…)` encode case & regex per term). */
  pattern: string;
  mode: SearchMode;
  case: CaseMode;
  contains: string[];
  excludes: string[];
  context: number;
  /** Data source names from `@src` / `-@src` (`!` = exclude). */
  globs: string[];
  /** File / path patterns from `@*.rs` / `@src/` (`!` = exclude). */
  fileGlobs: string[];
  hidden: boolean;
  respectIgnore: boolean;
  maxResults: number;
  /** Nearby-lines fallback radius when no single line contains every term (0 = strict single line). */
  nearbyLines: number;
  timeStartMs?: number;
  timeEndMs?: number;
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
  pattern: string;
  mode: SearchMode;
  contains: string[];
  excludes: string[];
  replacement?: string;
  timestamp: number;
}

