export type SearchMode = 'literal' | 'multi' | 'regex';
export type CaseMode = 'smart' | 'sensitive' | 'insensitive';

export type ViewAdapterId = 'log' | 'code';

export type BuiltinTimePreset =
  | ''
  | '5m'
  | '15m'
  | '30m'
  | '1h'
  | '3h'
  | '6h'
  | '12h'
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

export type PluginPreset = 'timeseries' | 'code';
export type PluginDomain = 'common' | 'log' | 'code';
export type PrefilterStage = 'source_plan' | 'file_prune' | 'window_narrow' | 'line_filter';

export interface PluginOverrides {
  enable?: string[];
  disable?: string[];
}

export interface PluginMetadata {
  id?: string;
  id_str?: string;
  domain?: PluginDomain | string;
  nameKey?: string;
  name_key?: string;
  description?: string;
  stages?: PrefilterStage[] | string[];
  defaultPresets?: (PluginPreset | string)[];
  default_presets?: (PluginPreset | string)[];
  costHint?: string;
  cost_hint?: string;
}

export interface PresetMetadata {
  id?: PluginPreset | string;
  id_str?: PluginPreset | string;
  nameKey?: string;
  name_key?: string;
  description?: string;
  defaultPlugins?: string[];
  default_plugins?: string[];
}

export interface MetaResponse {
  rootLabel: string;
  root: string;
  engine: string;
  types: string[];
  scopes?: string[];
  plugins?: PluginMetadata[];
  presets?: (PluginPreset | PresetMetadata | string)[];
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
  firstByte?: number | null;
  nextByte?: number | null;
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
  byteOffset?: number | null;
  spans: HitSpan[];
}

export type SourceKind = 'dir' | 'file' | (string & {});

export interface SourceKindMeta {
  kind: SourceKind;
  label: string;
}

export interface SourceConfig {
  path: string;
  timeFormat?: string | null;
  pluginPreset?: PluginPreset | string | null;
  plugins?: PluginOverrides | null;
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
  pluginPreset?: PluginPreset | string | null;
  plugins?: PluginOverrides | null;
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
  pluginPreset?: PluginPreset;
  plugins?: PluginOverrides;
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
      filesPruned?: number;
      bytesSaved?: number;
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

export interface McpParamMeta {
  name: string;
  type: string;
  required: boolean;
  description: string;
}

export interface McpCapabilityItem {
  name: string;
  category: string;
  description: string;
  params: McpParamMeta[];
}

export interface McpCallLogItem {
  seq: number;
  timestampMs: number;
  method: string;
  toolName: string;
  argsSummary: string;
  resultSummary: string;
  durationMs: number;
  ok: boolean;
  errorMessage: string;
  clientInfo: string;
}

export interface McpStats {
  totalCalls: number;
  errorCalls: number;
  lastCallMs: number;
}

export interface McpStateResponse {
  enabled: boolean;
  maxLogs: number;
  endpointPath: string;
  protocolVersion: string;
  tokenRequired?: boolean;
  stats: McpStats;
  capabilities: McpCapabilityItem[];
  logs: McpCallLogItem[];
}

export interface AuthStatusResponse {
  authRequired: boolean;
  authenticated: boolean;
  mcpTokenRequired: boolean;
}


