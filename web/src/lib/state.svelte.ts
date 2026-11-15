import type {
  DataSourceItem,
  DirSuggestEntry,
  DirSuggestResponse,
  FileHitGroup,
  FileResponse,
  HitItem,
  MetaResponse,
  QueryStep,
  ScopeFilter,
  SearchHistoryEntry,
  SearchMode,
  SourceConfig,
  SourceKind,
  SourcesResponse,
  TimePreset,
  TimePreviewResponse,
  WsIncomingMessage,
  WsSearchMessage,
} from './types';
import { messages, type Locale } from './i18n';

export type DrawerPanelId = 'sources' | 'shortcuts' | 'settings';
import {
  buildQueryCacheKeys,
  compileSearchQuery,
  computeDockerPreviewSinceSec,
  createQueryStep,
  formatHistoryLabel,
  normalizeStep,
  parseTimeModifierSpec,
  stepsEqual,
} from './query';
import {
  applySingleSourceSelection,
  toggleExcludeSourceSelection,
  toggleMultiSourceSelection,
} from './source-picker';
import { formatTimeScopeLabel } from './time-range';
import {
  applyFrameProfileCssVars,
  buildFrameProfileForHz,
  startAdaptiveFrameProbe,
  type FrameProfile,
} from './frame';
import type { ResultFix } from './suggest';

const HISTORY_STORAGE_KEY = 'webgrep.searchHistory.v2';
const THEME_STORAGE_KEY = 'webgrep.theme.v1';
const SETTINGS_STORAGE_KEY = 'webgrep.settings.v3';
const LEGACY_SETTINGS_KEYS = ['webgrep.settings.v2'];
const SOURCES_CACHE_STORAGE_KEY = 'webgrep.sourcesCache.v1';
const WS_DEGRADED_GRACE_MS = 650;

const MAX_L0_ENTRIES = 24;
const MAX_L0_SINGLE_ROWS = 20_000;
const MAX_L0_TOTAL_ROWS = 50_000;
const L0_TTL_MS = 30_000;
const MAX_FILE_CONTEXT_CACHE = 16;

interface L0CacheEntry {
  exactKey: string;
  baseKey: string;
  sourceRevision: number;
  storedAt: number;
  timeStartMs: number;
  fileGroups: FileHitGroup[];
  flatHits: HitItem[];
  filesSearched: number;
  filesMatched: number;
  totalMatches: number;
  matchedLines: number;
  bytesSearched: number;
  limitHit: boolean;
}

interface InflightCacheMeta {
  exactKey: string;
  baseKey: string;
  sourceRevision: number;
  hadDraft: boolean;
  maxResults: number;
  timeStartMs: number;
}

interface FileContextCacheEntry {
  sourceRevision: number;
  data: FileResponse;
}

const utf8Encoder = new TextEncoder();

function isPossiblyTruncatedHitText(text: string): boolean {
  // Backend stream truncates raw_text at 4096 UTF-8 bytes; only check full byte length on long lines
  if (text.length < 1364) return false;
  return utf8Encoder.encode(text).length >= 4092;
}

export interface ExecuteSearchOptions {
  forceRefresh?: boolean;
  recordInHistory?: boolean;
}

class WorkbenchState {
  // Workspace metadata
  meta = $state<MetaResponse>({
    rootLabel: 'webgrep',
    root: '.',
    engine: 'libwebgrep 0.5.0 · SIMD',
    types: [],
  });

  // WebSocket status
  wsStatus = $state<'connecting' | 'connected' | 'reconnecting' | 'offline'>('connecting');
  wsDegraded = $state<boolean>(false);
  private ws: WebSocket | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private wsDegradedTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectAttempt = 0;
  private pendingSearchOnOpen = false;
  private isUnloading = false;
  private lifecycleBound = false;
  private stopFrameProbe: (() => void) | null = null;
  frameProfile = $state.raw<FrameProfile>(buildFrameProfileForHz(60));

  // Structured Search State: committed progressive steps + single-text draft + independent ScopeFilter
  steps = $state<QueryStep[]>([]);
  pattern = $state<string>('');
  caseSensitive = $state<boolean>(false);
  wholeWord = $state<boolean>(false);
  isRegex = $state<boolean>(false);
  draftExclude = $state<boolean>(false);
  scope = $state<ScopeFilter>({
    sources: [],
    excludedSources: [],
    types: [],
    timePreset: '',
  });
  readonly mode: SearchMode = 'literal';

  // Engine Settings
  hidden = $state<boolean>(false);
  respectIgnore = $state<boolean>(false);
  maxResults = $state<number>(20000);

  // Execution State
  currentSearchId = $state<number>(0);
  searchCount = $state<number>(0);
  isSearching = $state<boolean>(false);
  private cancelledSearchId = -1;
  private lastExecutedKey = '';
  private lastExecutedHadDraft = false;
  private displayedTimeStartMs = 0;
  errorMessage = $state<string | null>(null);

  // Telemetry & Streaming Results
  filesSearched = $state<number>(0);
  filesMatched = $state<number>(0);
  totalMatches = $state<number>(0);
  matchedLines = $state<number>(0);
  bytesSearched = $state<number>(0);
  elapsedMs = $state<number>(0);
  limitHit = $state<boolean>(false);
  cacheHit = $state<string>('none');
  hasSearchedOnce = $state<boolean>(false);

  fileGroups = $state.raw<FileHitGroup[]>([]);
  flatHits = $state.raw<HitItem[]>([]);
  private groupIndexByFile = new Map<string, number>();
  private pendingChunks: HitItem[][] = [];
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private flushRaf: number | null = null;
  private awaitingFirstChunk = false;

  // L0 Step LRU Cache + Source Revision
  private sourceRevision = 1;
  private lastEnabledSourcesSig = '';
  private l0Cache = new Map<string, L0CacheEntry>();
  private l0TotalRows = 0;
  private inflightCacheKeys = new Map<number, InflightCacheMeta>();

  // Data Sources
  tenant = $state<string>('default');
  sources = $state.raw<DataSourceItem[]>([]);
  sourcesLoading = $state<boolean>(false);
  sourcesLoaded = $state<boolean>(false);
  addSourceModalOpen = $state<boolean>(false);
  drawerPanel = $state<DrawerPanelId | null>(null);
  sourceAddOpen = $state<boolean>(false);
  sourcePickerOpen = $state<boolean>(false);
  timePickerOpen = $state<boolean>(false);

  rightDrawerOpen = $derived<boolean>(this.drawerPanel !== null);
  settingsOpen = $derived<boolean>(this.drawerPanel === 'settings');
  sourcesDrawerOpen = $derived<boolean>(this.drawerPanel === 'sources');
  shortcutsDrawerOpen = $derived<boolean>(this.drawerPanel === 'shortcuts');

  openSourcesDrawer(expandAdd = false) {
    this.paletteOpen = false;
    this.sourcePickerOpen = false;
    this.timePickerOpen = false;
    this.sourceAddOpen = expandAdd;
    this.drawerPanel = 'sources';
  }

  openShortcutsDrawer() {
    this.paletteOpen = false;
    this.sourcePickerOpen = false;
    this.timePickerOpen = false;
    this.sourceAddOpen = false;
    this.drawerPanel = 'shortcuts';
  }

  openSettingsDrawer() {
    this.paletteOpen = false;
    this.sourcePickerOpen = false;
    this.timePickerOpen = false;
    this.sourceAddOpen = false;
    this.drawerPanel = 'settings';
  }

  openSourcePicker() {
    this.paletteOpen = false;
    this.timePickerOpen = false;
    this.closeRightDrawer();
    this.sourcePickerOpen = true;
  }

  closeSourcePicker() {
    this.sourcePickerOpen = false;
  }

  toggleSourcePicker() {
    if (this.sourcePickerOpen) {
      this.closeSourcePicker();
    } else {
      this.openSourcePicker();
    }
  }

  openTimePicker() {
    this.paletteOpen = false;
    this.sourcePickerOpen = false;
    this.closeRightDrawer();
    this.timePickerOpen = true;
  }

  closeTimePicker() {
    this.timePickerOpen = false;
  }

  toggleTimePicker() {
    if (this.timePickerOpen) {
      this.closeTimePicker();
    } else {
      this.openTimePicker();
    }
  }

  closeSettings() {
    if (this.drawerPanel === 'settings') this.drawerPanel = null;
  }

  closeRightDrawer() {
    this.sourceAddOpen = false;
    this.drawerPanel = null;
  }

  openSettings(tab: 'general' | 'sources' | 'add-source' | 'shortcuts' = 'general') {
    if (tab === 'sources') this.openSourcesDrawer(false);
    else if (tab === 'add-source') this.openSourcesDrawer(true);
    else if (tab === 'shortcuts') this.openShortcutsDrawer();
    else this.openSettingsDrawer();
  }

  openSourceManager() {
    this.openSourcesDrawer(false);
  }

  openAddSourceModal() {
    this.openSourcesDrawer(true);
  }

  enabledSourceCount = $derived<number>(
    this.sources.reduce((acc, s) => acc + (s.enabled ? 1 : 0), 0)
  );

  sourceById = $derived.by(() => {
    const map = new Map<string, DataSourceItem>();
    for (const s of this.sources) {
      map.set(s.id, s);
    }
    return map;
  });

  // Active hit & Right Inspector + File Context LRU
  activeHitIndex = $state<number>(-1);
  inspectedHit = $state.raw<HitItem | null>(null);
  scrollToActiveTick = $state<number>(0);
  inspectedPath = $state<string | null>(null);
  inspectedLine = $state<number>(1);
  inspectedFile = $state<FileResponse | null>(null);
  inspectorLoading = $state<boolean>(false);
  inspectorError = $state<string | null>(null);
  inspectorTab = $state<'structured' | 'raw'>('structured');
  private fileContextCache = new Map<string, FileContextCacheEntry>();
  private inspectSeq = 0;
  private inspectAbort: AbortController | null = null;
  private inspectorRaf: number | null = null;

  // UI Layout, Theme & Client Preferences
  locale = $state<Locale>('zh');
  darkMode = $state<boolean>(true);
  leftSidebarOpen = $state<boolean>(true);
  rightInspectorOpen = $state<boolean>(true);
  leftSidebarWidth = $state<number>(260);
  rightInspectorWidth = $state<number>(520);
  paletteOpen = $state<boolean>(false);
  detailOpen = $state<boolean>(false);
  isCompact = $state<boolean>(false);
  isTouch = $state<boolean>(false);
  insertToken: ((token: string) => void) | null = null;
  codeFontSize = $state<number>(13.5);
  wordWrap = $state<boolean>(true);
  previewLines = $state<number>(3);
  resultDensity = $state<'compact' | 'comfortable'>('comfortable');
  searchHistory = $state<SearchHistoryEntry[]>([]);

  // Derived Query Signals
  t = $derived(messages[this.locale]);

  activeHit = $derived<HitItem | null>(
    this.activeHitIndex >= 0 && this.activeHitIndex < this.flatHits.length
      ? this.flatHits[this.activeHitIndex]
      : null
  );

  draftStep = $derived<QueryStep | null>(
    this.pattern.trim().length > 0
      ? normalizeStep({
          text: this.pattern,
          exclude: this.draftExclude,
          caseSensitive: this.caseSensitive,
          wholeWord: this.wholeWord,
          isRegex: this.isRegex,
        })
      : null
  );

  compiledQuery = $derived.by(() =>
    compileSearchQuery(this.steps, this.draftStep, this.scope)
  );

  primaryPattern = $derived<string>(this.compiledQuery.primaryPattern);
  contains = $derived<string[]>(this.compiledQuery.contains);
  excludes = $derived<string[]>(this.compiledQuery.excludes);

  canExcludeDraft = $derived<boolean>(
    this.steps.some((s) => !s.exclude) ||
      this.scope.timePreset !== '' ||
      this.draftExclude
  );

  hasAnyQueryInput = $derived<boolean>(
    this.steps.length > 0 ||
      this.pattern.trim().length > 0 ||
      this.scope.timePreset !== ''
  );

  hasExecutableQuery = $derived<boolean>(this.compiledQuery.hasExecutableQuery);

  hasRegexActive = $derived<boolean>(
    this.isRegex || this.steps.some((s) => s.isRegex)
  );
  hasCaseActive = $derived<boolean>(
    this.caseSensitive || this.steps.some((s) => s.caseSensitive)
  );
  hasWordActive = $derived<boolean>(
    this.wholeWord || this.steps.some((s) => s.wholeWord)
  );
  hasTimeActive = $derived<boolean>(this.scope.timePreset !== '');

  activeFilterCount = $derived<number>(
    (this.steps.length > 1 ? this.steps.length - 1 : 0) +
      this.steps.filter((s) => s.exclude).length +
      this.scope.sources.length +
      (this.scope.excludedSources?.length ?? 0) +
      (this.scope.timePreset ? 1 : 0) +
      (this.hasRegexActive ? 1 : 0) +
      (this.hasCaseActive ? 1 : 0) +
      (this.hasWordActive ? 1 : 0)
  );

  constructor() {
    if (typeof window !== 'undefined') {
      this.loadTheme();
      this.loadSettings();
      this.loadHistory();
      this.loadCachedSources();
    }
  }

  init() {
    this.loadTheme();
    this.loadSettings();
    this.loadHistory();
    this.loadCachedSources();
    if (typeof window !== 'undefined' && !this.lifecycleBound) {
      this.lifecycleBound = true;
      applyFrameProfileCssVars(this.frameProfile);
      this.stopFrameProbe = startAdaptiveFrameProbe((profile) => {
        this.frameProfile = profile;
      });
      window.addEventListener('beforeunload', () => {
        this.isUnloading = true;
        this.clearWsDegradedTimer();
        this.stopFrameProbe?.();
        this.stopFrameProbe = null;
        if (this.reconnectTimer) {
          clearTimeout(this.reconnectTimer);
          this.reconnectTimer = null;
        }
      });
      window.addEventListener('pagehide', (e) => {
        if (!e.persisted) {
          this.isUnloading = true;
          this.clearWsDegradedTimer();
        }
      });
      window.addEventListener('pageshow', (e) => {
        this.isUnloading = false;
        if (e.persisted) {
          this.connectWebSocket();
          this.fetchSources();
        }
      });
    }
    this.fetchMeta();
    this.fetchSources();
    this.connectWebSocket();
  }

  private invalidateCaches() {
    this.sourceRevision += 1;
    this.l0Cache.clear();
    this.l0TotalRows = 0;
    this.fileContextCache.clear();
    this.lastExecutedKey = '';
  }

  private readStorageWithFallback(
    primary: Storage | undefined,
    fallback: Storage | undefined,
    keys: string[]
  ): string | null {
    for (const k of keys) {
      try {
        const v = primary?.getItem(k);
        if (v) return v;
      } catch {
        // ignore storage errors
      }
    }
    for (const k of keys) {
      try {
        const v = fallback?.getItem(k);
        if (v) return v;
      } catch {
        // ignore storage errors
      }
    }
    return null;
  }

  private loadSettings() {
    try {
      const raw =
        typeof window !== 'undefined'
          ? this.readStorageWithFallback(window.localStorage, window.sessionStorage, [
              SETTINGS_STORAGE_KEY,
              ...LEGACY_SETTINGS_KEYS,
            ])
          : null;
      if (!raw) return;
      const s = JSON.parse(raw);
      if (typeof s.respectIgnore === 'boolean') this.respectIgnore = s.respectIgnore;
      if (typeof s.hidden === 'boolean') this.hidden = s.hidden;
      if (typeof s.previewLines === 'number' && Number.isFinite(s.previewLines)) {
        this.previewLines = Math.max(1, Math.min(6, Math.round(s.previewLines)));
      }
      if (typeof s.maxResults === 'number' && Number.isFinite(s.maxResults)) {
        this.maxResults = Math.max(1, Math.min(500000, Math.round(s.maxResults)));
      }
      if (typeof s.codeFontSize === 'number' && Number.isFinite(s.codeFontSize)) {
        this.codeFontSize = Math.max(10, Math.min(28, s.codeFontSize));
      }
      if (typeof s.wordWrap === 'boolean') this.wordWrap = s.wordWrap;
      if (s.resultDensity === 'compact' || s.resultDensity === 'comfortable') {
        this.resultDensity = s.resultDensity;
      }
      if (s.locale === 'zh' || s.locale === 'en') {
        this.locale = s.locale;
      }
      if (typeof s.tenant === 'string' && s.tenant.trim().length > 0) {
        this.tenant = s.tenant.trim();
      }
    } catch {
      // ignore invalid saved settings
    }
  }

  setTenant(nextTenant: string) {
    const clean =
      nextTenant
        .trim()
        .replace(/[^a-zA-Z0-9._-]/g, '-')
        .slice(0, 64) || 'default';
    if (clean === this.tenant) return;
    this.tenant = clean;
    this.invalidateCaches();
    this.saveSettings();
    this.fetchSources();
    if (this.hasSearchedOnce && this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: true });
    }
  }

  toggleLocale() {
    this.locale = this.locale === 'zh' ? 'en' : 'zh';
    this.saveSettings();
  }

  saveSettings() {
    try {
      localStorage.setItem(
        SETTINGS_STORAGE_KEY,
        JSON.stringify({
          locale: this.locale,
          tenant: this.tenant,
          respectIgnore: this.respectIgnore,
          hidden: this.hidden,
          previewLines: this.previewLines,
          maxResults: this.maxResults,
          codeFontSize: this.codeFontSize,
          wordWrap: this.wordWrap,
          resultDensity: this.resultDensity,
        })
      );
    } catch {
      // ignore storage errors
    }
  }

  resetSettings() {
    this.respectIgnore = false;
    this.hidden = false;
    this.previewLines = 3;
    this.maxResults = 20000;
    this.codeFontSize = 13.5;
    this.wordWrap = true;
    this.resultDensity = 'comfortable';
    this.saveSettings();
    if (this.hasSearchedOnce && this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: false });
    }
  }

  private loadTheme() {
    try {
      const saved =
        typeof window !== 'undefined'
          ? this.readStorageWithFallback(window.localStorage, window.sessionStorage, [
              THEME_STORAGE_KEY,
            ])
          : null;
      this.darkMode = saved === 'light' ? false : true;
    } catch {
      this.darkMode = true;
    }
    this.applyThemeClass();
  }

  toggleTheme() {
    this.darkMode = !this.darkMode;
    this.applyThemeClass();
    try {
      localStorage.setItem(THEME_STORAGE_KEY, this.darkMode ? 'dark' : 'light');
    } catch {
      // ignore storage errors
    }
  }

  private applyThemeClass() {
    if (typeof document !== 'undefined') {
      document.documentElement.classList.toggle('dark', this.darkMode);
    }
  }

  private loadHistory() {
    try {
      const raw = localStorage.getItem(HISTORY_STORAGE_KEY);
      if (!raw) return;
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed)) return;
      const valid: SearchHistoryEntry[] = [];
      for (const item of parsed) {
        if (
          item &&
          typeof item.id === 'string' &&
          typeof item.label === 'string' &&
          Array.isArray(item.steps) &&
          item.scope &&
          typeof item.scope === 'object'
        ) {
          valid.push({
            id: item.id,
            steps: item.steps.map((s: QueryStep) => createQueryStep(String(s.text ?? ''), s)),
            draft: item.draft ? createQueryStep(String(item.draft.text ?? ''), item.draft) : null,
            scope: {
              sources: Array.isArray(item.scope.sources) ? item.scope.sources : [],
              excludedSources: Array.isArray(item.scope.excludedSources)
                ? item.scope.excludedSources
                : [],
              types: [],
              timePreset: (item.scope.timePreset || '') as TimePreset,
            },
            label: item.label,
            timestamp: typeof item.timestamp === 'number' ? item.timestamp : Date.now(),
          });
        }
        if (valid.length >= 20) break;
      }
      this.searchHistory = valid;
    } catch {
      this.searchHistory = [];
    }
  }

  private recordHistory(historyId: string) {
    const normSteps = this.steps.map(normalizeStep).filter((s) => s.text.length > 0);
    const normDraft = this.draftStep;
    if (normSteps.length === 0 && !normDraft && !this.scope.timePreset) return;

    let label = formatHistoryLabel(normSteps, normDraft);
    if (!label && this.scope.timePreset) {
      label = formatTimeScopeLabel(this.scope.timePreset, this.t.scopeBar.timeLabels);
    }
    if (!label) return;

    const entry: SearchHistoryEntry = {
      id: historyId,
      steps: normSteps,
      draft: normDraft,
      scope: {
        sources: [...this.scope.sources],
        excludedSources: [...(this.scope.excludedSources ?? [])],
        types: [],
        timePreset: this.scope.timePreset,
      },
      label,
      timestamp: Date.now(),
    };

    const filtered = this.searchHistory.filter((h) => h.id !== historyId);
    this.searchHistory = [entry, ...filtered].slice(0, 20);
    try {
      localStorage.setItem(HISTORY_STORAGE_KEY, JSON.stringify(this.searchHistory));
    } catch {
      // ignore
    }
  }

  removeHistoryEntry(id: string) {
    this.searchHistory = this.searchHistory.filter((h) => h.id !== id);
    try {
      localStorage.setItem(HISTORY_STORAGE_KEY, JSON.stringify(this.searchHistory));
    } catch {
      // ignore
    }
  }

  clearHistory() {
    this.searchHistory = [];
    try {
      localStorage.removeItem(HISTORY_STORAGE_KEY);
    } catch {
      // ignore
    }
  }

  async fetchMeta() {
    try {
      const res = await fetch('/api/meta');
      if (!res.ok) return;
      const data = (await res.json()) as Partial<MetaResponse>;
      this.meta = {
        rootLabel: data.rootLabel || 'webgrep',
        root: data.root || '.',
        engine: data.engine || 'libwebgrep 0.5.0 · SIMD',
        types: Array.isArray(data.types) ? data.types : [],
        scopes: Array.isArray(data.scopes) ? data.scopes : [],
      };
    } catch {
      // keep default meta
    }
  }

  private loadCachedSources() {
    if (this.sourcesLoaded) return;
    try {
      const raw = localStorage.getItem(SOURCES_CACHE_STORAGE_KEY);
      if (!raw) return;
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed)) return;
      const valid: DataSourceItem[] = [];
      for (const item of parsed) {
        if (
          item &&
          typeof item.id === 'string' &&
          typeof item.name === 'string' &&
          typeof item.enabled === 'boolean' &&
          typeof item.exists === 'boolean'
        ) {
          valid.push(item as DataSourceItem);
        }
      }
      if (valid.length > 0 && this.sources.length === 0) {
        this.sources = valid;
        this.lastEnabledSourcesSig = valid
          .filter((s) => s.enabled)
          .map((s) => `${s.id}:${s.config?.timeFormat ?? ''}`)
          .sort()
          .join(',');
      }
    } catch {
      // ignore invalid cached sources
    }
  }

  private applySourcesResponse(data: SourcesResponse) {
    if (typeof data.searchCount === 'number' && data.searchCount >= 0) {
      this.searchCount = data.searchCount;
    }
    if (Array.isArray(data.sources)) {
      const nextSig = data.sources
        .filter((s) => s.enabled)
        .map((s) => `${s.id}:${s.config?.timeFormat ?? ''}`)
        .sort()
        .join(',');
      if (this.lastEnabledSourcesSig && nextSig !== this.lastEnabledSourcesSig) {
        this.invalidateCaches();
      }
      this.lastEnabledSourcesSig = nextSig;
      this.sources = data.sources;
      this.sourcesLoaded = true;
      try {
        localStorage.setItem(SOURCES_CACHE_STORAGE_KEY, JSON.stringify(data.sources));
      } catch {
        // ignore storage errors
      }
    }
  }

  async fetchSources() {
    this.sourcesLoading = true;
    try {
      const res = await fetch('/api/sources');
      if (res.ok) {
        const data = (await res.json()) as SourcesResponse;
        this.applySourcesResponse(data);
      }
    } catch {
      // ignore
    } finally {
      this.sourcesLoading = false;
    }
  }

  async upsertDirectorySource(payload: {
    id?: string;
    kind?: SourceKind;
    name: string;
    path?: string;
    config?: SourceConfig;
    enabled?: boolean;
    timeFormat?: string;
  }) {
    const cleanPath = (
      payload.config?.path ??
      payload.config?.endpoint ??
      payload.path ??
      ''
    ).trim();
    const resolvedTimeFormat =
      payload.timeFormat !== undefined ? payload.timeFormat.trim() : payload.config?.timeFormat;
    const res = await fetch('/api/sources', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        id: payload.id ?? null,
        kind: payload.kind ?? 'dir',
        name: payload.name.trim(),
        path: cleanPath,
        config: {
          path: cleanPath,
          endpoint: payload.config?.endpoint ?? null,
          ...(resolvedTimeFormat !== undefined ? { timeFormat: resolvedTimeFormat } : {}),
        },
        enabled: payload.enabled ?? true,
      }),
    });
    if (!res.ok) {
      const errData = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
      throw new Error(errData.error || `HTTP ${res.status}`);
    }
    const data = (await res.json()) as SourcesResponse;
    this.invalidateCaches();
    this.applySourcesResponse(data);
    if (this.hasSearchedOnce && this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: true });
    }
  }

  async toggleSourceEnabled(id: string) {
    const res = await fetch('/api/sources/toggle', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id }),
    });
    if (res.ok) {
      const data = (await res.json()) as SourcesResponse;
      this.invalidateCaches();
      this.applySourcesResponse(data);
      if (this.hasSearchedOnce && this.hasExecutableQuery) {
        this.executeSearch({ forceRefresh: true });
      }
    }
  }

  async toggleAllSourcesEnabled(enabled: boolean) {
    const res = await fetch('/api/sources/toggle', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled }),
    });
    if (res.ok) {
      const data = (await res.json()) as SourcesResponse;
      this.invalidateCaches();
      this.applySourcesResponse(data);
      if (this.hasSearchedOnce && this.hasExecutableQuery) {
        this.executeSearch({ forceRefresh: true });
      }
    }
  }

  async removeSource(id: string) {
    const res = await fetch('/api/sources/delete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id }),
    });
    if (res.ok) {
      const data = (await res.json()) as SourcesResponse;
      this.invalidateCaches();
      this.applySourcesResponse(data);
      const excluded = this.scope.excludedSources ?? [];
      if (this.scope.sources.includes(id) || excluded.includes(id)) {
        this.scope = {
          ...this.scope,
          sources: this.scope.sources.filter((x) => x !== id),
          excludedSources: excluded.filter((x) => x !== id),
        };
      }
      if (this.hasSearchedOnce && this.hasExecutableQuery) {
        this.executeSearch({ forceRefresh: true });
      }
    }
  }

  async fetchDirSuggestions(queryPath: string, kind: SourceKind = 'dir'): Promise<DirSuggestEntry[]> {
    try {
      const params = new URLSearchParams({ kind, q: queryPath });
      const res = await fetch(`/api/sources/complete?${params.toString()}`);
      if (!res.ok) return [];
      const data = (await res.json()) as DirSuggestResponse;
      return Array.isArray(data.entries) ? data.entries : [];
    } catch {
      return [];
    }
  }

  // Flag toggles (pure state mutations; executed only on Enter or + Filter)
  toggleCaseSensitive() {
    this.caseSensitive = !this.caseSensitive;
  }

  toggleWholeWord() {
    this.wholeWord = !this.wholeWord;
  }

  toggleRegexMode() {
    this.isRegex = !this.isRegex;
  }

  toggleDraftExclude() {
    if (!this.canExcludeDraft) return;
    this.draftExclude = !this.draftExclude;
  }

  /**
   * Google-style explicit Enter submission:
   * Executes the search for `[...steps, draft]` + `scope` while keeping the draft text in the box.
   * Pressing Enter again on an unchanged query forces a live backend refresh.
   */
  submitSearch() {
    if (!this.hasExecutableQuery) return;
    const keys = this.computeCurrentCacheKeys();
    const isRepeat =
      this.hasSearchedOnce && !this.isSearching && keys.exactKey === this.lastExecutedKey;
    this.executeSearch({ forceRefresh: isRepeat, recordInHistory: true });
  }

  /**
   * Locks the current single-text box input (plus `Aa`/`ab`/`.*`/`-`) as the next step
   * in `steps` (`#1 -> #2 -> #3`), clears the search box for the next level, and runs the search.
   */
  commitCurrentPattern(): boolean {
    const step = this.draftStep;
    if (!step) {
      if (this.hasExecutableQuery) {
        this.executeSearch({ forceRefresh: false, recordInHistory: true });
      }
      return false;
    }
    const alreadyExists = this.steps.some((s) => stepsEqual(s, step));
    if (!alreadyExists) {
      this.steps = [...this.steps, step];
    }
    this.pattern = '';
    this.caseSensitive = false;
    this.wholeWord = false;
    this.isRegex = false;
    this.draftExclude = false;
    this.executeSearch({ forceRefresh: false, recordInHistory: true });
    return true;
  }

  canToggleStepExclude(idx: number): boolean {
    const target = this.steps[idx];
    if (!target) return false;
    if (target.exclude) return true; // flipping `-` -> `+` always leaves a positive
    const otherPositiveStep = this.steps.some((s, i) => i !== idx && !s.exclude);
    const positiveDraft = Boolean(this.draftStep && !this.draftStep.exclude);
    return otherPositiveStep || positiveDraft || this.scope.timePreset !== '';
  }

  /** Flips include (`+`) ⇄ exclude (`-`) on a committed step and refreshes results. */
  toggleStepExclude(idx: number) {
    if (!this.canToggleStepExclude(idx)) return;
    const next = this.steps.slice();
    next[idx] = { ...next[idx], exclude: !next[idx].exclude };
    this.steps = next;
    if (this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: false, recordInHistory: true });
    }
  }

  /** Loads committed step `idx` back into the single-text search box for editing. */
  editStepInSearchBox(idx: number) {
    if (idx < 0 || idx >= this.steps.length) return;
    const target = this.steps[idx];
    const remaining = this.steps.filter((_, i) => i !== idx);
    const currentDraft = this.draftStep;
    if (currentDraft && !remaining.some((s) => stepsEqual(s, currentDraft))) {
      remaining.push(currentDraft);
    }
    this.steps = remaining;
    this.pattern = target.text;
    this.caseSensitive = target.caseSensitive;
    this.wholeWord = target.wholeWord;
    this.isRegex = target.isRegex;
    this.draftExclude = target.exclude && (this.steps.some((s) => !s.exclude) || this.scope.timePreset !== '');
  }

  /** Removes committed step `idx` and refreshes (instant L0 hit when stepping back). */
  removeStep(idx: number) {
    if (idx < 0 || idx >= this.steps.length) return;
    this.steps = this.steps.filter((_, i) => i !== idx);
    if (this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: false, recordInHistory: false });
    } else {
      this.cancelSearch();
      this.resetResultBuffer();
      this.hasSearchedOnce = false;
      this.lastExecutedKey = '';
    }
  }

  /** Clears only the current search box text & flags without removing locked steps. */
  clearDraftInput() {
    this.pattern = '';
    this.caseSensitive = false;
    this.wholeWord = false;
    this.isRegex = false;
    this.draftExclude = false;
    if (this.hasSearchedOnce && this.lastExecutedHadDraft) {
      if (this.hasExecutableQuery) {
        this.executeSearch({ forceRefresh: false, recordInHistory: false });
      } else {
        this.cancelSearch();
        this.resetResultBuffer();
        this.hasSearchedOnce = false;
        this.lastExecutedKey = '';
      }
    }
  }

  /** Locks any current draft into `steps`, appends literal positive term, clears draft, and executes. */
  appendSearchTerm(term: string) {
    const clean = term.trim();
    if (!clean) return;
    const next = this.steps.slice();
    if (this.draftStep && !next.some((s) => stepsEqual(s, this.draftStep!))) {
      next.push(this.draftStep);
    }
    const added = createQueryStep(clean, { exclude: false });
    if (!next.some((s) => stepsEqual(s, added))) {
      next.push(added);
    }
    this.steps = next;
    this.pattern = '';
    this.caseSensitive = false;
    this.wholeWord = false;
    this.isRegex = false;
    this.draftExclude = false;
    this.executeSearch({ forceRefresh: false, recordInHistory: true });
  }

  /** Locks any current draft into `steps`, appends literal excluded term, clears draft, and executes. */
  excludeSearchTerm(term: string) {
    const clean = term.trim();
    if (!clean) return;
    const next = this.steps.slice();
    if (this.draftStep && !next.some((s) => stepsEqual(s, this.draftStep!))) {
      next.push(this.draftStep);
    }
    const canEx = next.some((s) => !s.exclude) || this.scope.timePreset !== '';
    const added = createQueryStep(clean, { exclude: canEx });
    if (!next.some((s) => stepsEqual(s, added))) {
      next.push(added);
    }
    this.steps = next;
    this.pattern = '';
    this.caseSensitive = false;
    this.wholeWord = false;
    this.isRegex = false;
    this.draftExclude = false;
    this.executeSearch({ forceRefresh: false, recordInHistory: true });
  }

  /** Replaces the entire text query with a clean literal search (keeps scope filters). */
  replaceSearchWithLiteral(term: string) {
    const clean = term.trim();
    if (!clean) return;
    this.steps = [];
    this.pattern = clean;
    this.caseSensitive = false;
    this.wholeWord = false;
    this.isRegex = false;
    this.draftExclude = false;
    this.executeSearch({ forceRefresh: false, recordInHistory: true });
  }

  applyHistoryEntry(entry: SearchHistoryEntry) {
    this.steps = entry.steps.map((s) => createQueryStep(s.text, s));
    if (entry.draft) {
      this.pattern = entry.draft.text;
      this.caseSensitive = entry.draft.caseSensitive;
      this.wholeWord = entry.draft.wholeWord;
      this.isRegex = entry.draft.isRegex;
      this.draftExclude = entry.draft.exclude;
    } else {
      this.pattern = '';
      this.caseSensitive = false;
      this.wholeWord = false;
      this.isRegex = false;
      this.draftExclude = false;
    }
    this.scope = {
      sources: [...entry.scope.sources],
      excludedSources: [...(entry.scope.excludedSources ?? [])],
      types: [],
      timePreset: entry.scope.timePreset,
    };
    this.executeSearch({ forceRefresh: false, recordInHistory: true });
  }

  private resolveSourceIdOrName(nameOrId: string): string {
    const match = this.sources.find(
      (s) => s.id === nameOrId || s.name.toLowerCase() === nameOrId.toLowerCase()
    );
    return match ? match.id : nameOrId;
  }

  private sameSourceList(a: readonly string[], b: readonly string[]): boolean {
    if (a.length !== b.length) return false;
    const sa = [...a].sort();
    const sb = [...b].sort();
    for (let i = 0; i < sa.length; i++) {
      if (sa[i] !== sb[i]) return false;
    }
    return true;
  }

  // ScopeFilter actions
  setScopeSources(sources: readonly string[], excludedSources: readonly string[] = []) {
    const nextExcludedSet = new Set(excludedSources);
    const nextSources = Array.from(new Set(sources)).filter((id) => !nextExcludedSet.has(id));
    const nextExcluded = Array.from(nextExcludedSet);
    const curSources = this.scope.sources;
    const curExcluded = this.scope.excludedSources ?? [];
    if (
      this.sameSourceList(curSources, nextSources) &&
      this.sameSourceList(curExcluded, nextExcluded)
    ) {
      return;
    }
    this.scope = {
      ...this.scope,
      sources: nextSources,
      excludedSources: nextExcluded,
      types: [],
    };
    if (this.hasSearchedOnce && this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: false, recordInHistory: false });
    }
  }

  selectSingleScopeSource(id: string) {
    const next = applySingleSourceSelection(this.scope, id);
    this.setScopeSources(next.sources, next.excludedSources);
  }

  selectSingleScopeSourceByName(name: string) {
    this.selectSingleScopeSource(this.resolveSourceIdOrName(name));
  }

  toggleScopeSource(id: string) {
    const next = toggleMultiSourceSelection(this.scope, id);
    this.setScopeSources(next.sources, next.excludedSources);
  }

  toggleScopeSourceByName(name: string) {
    this.toggleScopeSource(this.resolveSourceIdOrName(name));
  }

  toggleExcludeScopeSource(id: string) {
    const next = toggleExcludeSourceSelection(this.scope, id);
    this.setScopeSources(next.sources, next.excludedSources);
  }

  toggleExcludeScopeSourceByName(name: string) {
    this.toggleExcludeScopeSource(this.resolveSourceIdOrName(name));
  }

  scopeSourceFromMenu(name: string, exclude: boolean) {
    const idOrName = this.resolveSourceIdOrName(name);
    if (exclude) {
      const curEx = this.scope.excludedSources ?? [];
      const nextEx = curEx.includes(idOrName) ? curEx : [...curEx, idOrName];
      this.setScopeSources(
        this.scope.sources.filter((x) => x !== idOrName),
        nextEx
      );
    } else {
      this.setScopeSources([idOrName], []);
    }
  }

  clearScopeSources() {
    this.setScopeSources([], []);
  }

  setScopeTime(preset: TimePreset) {
    this.scope = {
      ...this.scope,
      timePreset: preset,
    };
    if (this.hasExecutableQuery && (this.hasSearchedOnce || preset !== '')) {
      this.executeSearch({ forceRefresh: false, recordInHistory: !this.hasSearchedOnce });
    } else if (this.hasSearchedOnce && !this.hasExecutableQuery) {
      this.cancelSearch();
      this.resetResultBuffer();
      this.hasSearchedOnce = false;
      this.lastExecutedKey = '';
    }
  }

  clearScopeAll() {
    this.scope = {
      sources: [],
      excludedSources: [],
      types: [],
      timePreset: '',
    };
    if (this.hasSearchedOnce && this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: false, recordInHistory: false });
    } else if (!this.hasExecutableQuery) {
      this.cancelSearch();
      this.resetResultBuffer();
      this.hasSearchedOnce = false;
      this.lastExecutedKey = '';
    }
  }

  /** Keeps only the first positive step and clears flags + scope filters. */
  resetAllFilters() {
    const all = this.compiledQuery.activeSteps;
    const firstPos = all.find((s) => !s.exclude);
    this.steps = [];
    this.pattern = firstPos ? firstPos.text : '';
    this.caseSensitive = false;
    this.wholeWord = false;
    this.isRegex = Boolean(firstPos?.isRegex);
    this.draftExclude = false;
    this.scope = {
      sources: [],
      excludedSources: [],
      types: [],
      timePreset: '',
    };
    if (this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: false, recordInHistory: false });
    } else {
      this.cancelSearch();
      this.resetResultBuffer();
      this.hasSearchedOnce = false;
      this.lastExecutedKey = '';
    }
  }

  /** Applies a zero-result recovery action from `zeroResultFixes`. */
  applyResultFix(fix: ResultFix) {
    if (fix.steps !== undefined) {
      this.steps = fix.steps.map((s) => createQueryStep(s.text, s));
    }
    if (fix.draft !== undefined) {
      if (fix.draft) {
        this.pattern = fix.draft.text;
        this.caseSensitive = fix.draft.caseSensitive;
        this.wholeWord = fix.draft.wholeWord;
        this.isRegex = fix.draft.isRegex;
        this.draftExclude = fix.draft.exclude;
      } else {
        this.pattern = '';
        this.caseSensitive = false;
        this.wholeWord = false;
        this.isRegex = false;
        this.draftExclude = false;
      }
    }
    if (fix.scopePatch) {
      this.scope = { ...this.scope, ...fix.scopePatch };
    }
    if (this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: false, recordInHistory: false });
    }
  }

  // WebSocket management
  private clearWsDegradedTimer() {
    if (this.wsDegradedTimer !== null) {
      clearTimeout(this.wsDegradedTimer);
      this.wsDegradedTimer = null;
    }
  }

  private scheduleWsDegraded() {
    if (this.isUnloading || this.wsDegraded || this.wsDegradedTimer !== null) return;
    this.wsDegradedTimer = setTimeout(() => {
      this.wsDegradedTimer = null;
      if (!this.isUnloading && this.wsStatus !== 'connected') {
        this.wsDegraded = true;
      }
    }, WS_DEGRADED_GRACE_MS);
  }

  connectWebSocket() {
    if (typeof window === 'undefined') return;
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)) {
      return;
    }

    this.isUnloading = false;
    const protocol = window.location.protocol === 'https:' ? 'wss://' : 'ws://';
    const wsUrl = `${protocol}${window.location.host}/api/ws`;
    const isReconnect = this.reconnectAttempt > 0;
    this.wsStatus = isReconnect ? 'reconnecting' : 'connecting';
    this.scheduleWsDegraded();

    try {
      const socket = new WebSocket(wsUrl);
      this.ws = socket;

      socket.onopen = () => {
        this.clearWsDegradedTimer();
        this.wsDegraded = false;
        this.wsStatus = 'connected';
        this.reconnectAttempt = 0;
        if (isReconnect || !this.sourcesLoaded) {
          this.fetchMeta();
          this.fetchSources();
        }
        if (this.pendingSearchOnOpen && this.hasExecutableQuery) {
          this.pendingSearchOnOpen = false;
          this.executeSearch({ forceRefresh: false, recordInHistory: false });
        }
      };

      socket.onmessage = (event) => {
        try {
          const raw = typeof event.data === 'string' ? event.data : '';
          if (!raw) return;
          const idMatch = /"id":(\d+)/.exec(raw.slice(0, 48));
          if (idMatch && Number(idMatch[1]) !== this.currentSearchId) {
            return;
          }
          const msg = JSON.parse(raw) as WsIncomingMessage;
          this.handleWsMessage(msg);
        } catch {
          // ignore malformed packet
        }
      };

      socket.onerror = () => {
        // handled by onclose
      };

      socket.onclose = () => {
        this.ws = null;
        this.isSearching = false;
        if (this.isUnloading) return;
        this.wsStatus = 'reconnecting';
        this.scheduleWsDegraded();
        this.scheduleReconnect();
      };
    } catch {
      if (!this.isUnloading) {
        this.wsStatus = 'offline';
        this.wsDegraded = true;
        this.scheduleReconnect();
      }
    }
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectAttempt += 1;
    const delay = Math.min(2500, 300 * Math.pow(1.4, Math.min(6, this.reconnectAttempt)));
    this.reconnectTimer = setTimeout(() => {
      this.connectWebSocket();
    }, delay);
  }

  cancelSearch() {
    if (this.isSearching) {
      this.flushPendingHitsSync();
      this.awaitingFirstChunk = false;
      this.cancelledSearchId = this.currentSearchId;
      this.inflightCacheKeys.delete(this.currentSearchId);
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(
          JSON.stringify({
            type: 'cancel',
            id: this.currentSearchId,
          })
        );
      }
    }
    this.isSearching = false;
  }

  clearSearch() {
    this.cancelSearch();
    this.steps = [];
    this.pattern = '';
    this.caseSensitive = false;
    this.wholeWord = false;
    this.isRegex = false;
    this.draftExclude = false;
    this.lastExecutedKey = '';
    this.lastExecutedHadDraft = false;
    this.errorMessage = null;
    this.hasSearchedOnce = false;
    this.resetResultBuffer();
  }

  private clearFlushSchedule() {
    if (this.flushTimer !== null) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    if (this.flushRaf !== null && typeof cancelAnimationFrame !== 'undefined') {
      cancelAnimationFrame(this.flushRaf);
      this.flushRaf = null;
    }
  }

  private clearInspectorSchedule() {
    if (this.inspectorRaf !== null && typeof cancelAnimationFrame !== 'undefined') {
      cancelAnimationFrame(this.inspectorRaf);
      this.inspectorRaf = null;
    }
  }

  private resetResultBuffer() {
    this.clearFlushSchedule();
    this.clearInspectorSchedule();
    this.awaitingFirstChunk = false;
    this.pendingChunks = [];
    this.groupIndexByFile.clear();
    this.fileGroups = [];
    this.flatHits = [];
    this.activeHitIndex = -1;
    this.inspectedHit = null;
    this.filesSearched = 0;
    this.filesMatched = 0;
    this.totalMatches = 0;
    this.matchedLines = 0;
    this.bytesSearched = 0;
    this.elapsedMs = 0;
    this.limitHit = false;
    this.cacheHit = 'none';
    this.displayedTimeStartMs = 0;
  }

  private getEffectiveSourceIds(): string[] {
    if (this.scope.sources.length > 0) {
      return [...this.scope.sources];
    }
    return this.sources.filter((s) => s.enabled).map((s) => s.id);
  }

  private isContentTimeSource(s: DataSourceItem): boolean {
    if (s.config?.timeFormat !== undefined && s.config?.timeFormat !== null) {
      return Boolean(s.config.timeFormat.trim());
    }
    return s.kind === 'docker';
  }

  private hasActiveDockerSource(): boolean {
    return this.getActiveSources().some((s) => s.kind === 'docker');
  }

  private getActiveSources(): DataSourceItem[] {
    const excluded = new Set(this.scope.excludedSources ?? []);
    if (this.scope.sources.length > 0) {
      const selected = new Set(this.scope.sources);
      return this.sources.filter(
        (s) =>
          (selected.has(s.id) || selected.has(s.name)) &&
          !excluded.has(s.id) &&
          !excluded.has(s.name)
      );
    }
    return this.sources.filter(
      (s) => s.enabled && !excluded.has(s.id) && !excluded.has(s.name)
    );
  }

  getEffectiveTimeBasisSummary(): { contentCount: number; mtimeCount: number } {
    let contentCount = 0;
    let mtimeCount = 0;
    for (const s of this.getActiveSources()) {
      if (this.isContentTimeSource(s)) {
        contentCount += 1;
      } else {
        mtimeCount += 1;
      }
    }
    return { contentCount, mtimeCount };
  }

  private getSourceTimeFormatsSig(): string {
    return this.getActiveSources()
      .filter((s) => this.isContentTimeSource(s))
      .map((s) => `${s.id}=${s.config?.timeFormat?.trim() || 'auto'}`)
      .sort()
      .join('|');
  }

  private computeCurrentCacheKeys(nowMs = Date.now()) {
    return buildQueryCacheKeys({
      tenant: this.tenant,
      effectiveSources: this.getEffectiveSourceIds(),
      excludedSources: this.scope.excludedSources ?? [],
      types: this.scope.types,
      timePreset: this.scope.timePreset,
      timeMode: 'source',
      tzOffsetMin: -new Date().getTimezoneOffset(),
      sourceTimeFormatsSig: this.getSourceTimeFormatsSig(),
      steps: this.compiledQuery.activeSteps,
      contextLines: 0,
      hidden: this.hidden,
      respectIgnore: this.respectIgnore,
      maxResults: this.maxResults,
      nowMs,
    });
  }

  private findValidL0Entry(exactKey: string, baseKey: string, nowMs: number): L0CacheEntry | null {
    const exact = this.l0Cache.get(exactKey);
    if (exact) {
      if (exact.sourceRevision === this.sourceRevision && nowMs - exact.storedAt <= L0_TTL_MS) {
        this.l0Cache.delete(exactKey);
        this.l0Cache.set(exactKey, exact);
        return exact;
      }
      this.deleteL0Entry(exactKey, exact);
    }

    for (const [k, entry] of this.l0Cache) {
      if (
        entry.baseKey === baseKey &&
        !entry.limitHit &&
        this.maxResults >= entry.flatHits.length &&
        entry.sourceRevision === this.sourceRevision &&
        nowMs - entry.storedAt <= L0_TTL_MS
      ) {
        this.l0Cache.delete(k);
        this.l0Cache.set(k, entry);
        return entry;
      }
    }
    return null;
  }

  private deleteL0Entry(key: string, entry: L0CacheEntry) {
    this.l0Cache.delete(key);
    this.l0TotalRows = Math.max(0, this.l0TotalRows - entry.flatHits.length);
  }

  private putL0Entry(meta: InflightCacheMeta) {
    if (this.hasActiveDockerSource()) return;
    const rowCount = this.flatHits.length;
    if (rowCount > MAX_L0_SINGLE_ROWS) return;

    const existing = this.l0Cache.get(meta.exactKey);
    if (existing) {
      this.deleteL0Entry(meta.exactKey, existing);
    }

    while (
      this.l0Cache.size > 0 &&
      (this.l0Cache.size >= MAX_L0_ENTRIES || this.l0TotalRows + rowCount > MAX_L0_TOTAL_ROWS)
    ) {
      const oldest = this.l0Cache.entries().next().value;
      if (!oldest) break;
      this.deleteL0Entry(oldest[0], oldest[1]);
    }

    if (this.l0TotalRows + rowCount > MAX_L0_TOTAL_ROWS) return;

    const entry: L0CacheEntry = {
      exactKey: meta.exactKey,
      baseKey: meta.baseKey,
      sourceRevision: meta.sourceRevision,
      storedAt: Date.now(),
      timeStartMs: meta.timeStartMs,
      fileGroups: this.fileGroups,
      flatHits: this.flatHits,
      filesSearched: this.filesSearched,
      filesMatched: this.filesMatched,
      totalMatches: this.totalMatches,
      matchedLines: this.matchedLines,
      bytesSearched: this.bytesSearched,
      limitHit: this.limitHit,
    };
    this.l0Cache.set(meta.exactKey, entry);
    this.l0TotalRows += rowCount;
  }

  private restoreFromL0Entry(entry: L0CacheEntry, hadDraft: boolean) {
    this.clearFlushSchedule();
    this.clearInspectorSchedule();
    this.awaitingFirstChunk = false;
    this.pendingChunks = [];
    this.isSearching = false;
    this.errorMessage = null;
    this.hasSearchedOnce = true;

    this.groupIndexByFile.clear();
    for (let i = 0; i < entry.fileGroups.length; i++) {
      this.groupIndexByFile.set(entry.fileGroups[i].file, i);
    }
    this.fileGroups = entry.fileGroups;
    this.flatHits = entry.flatHits;
    this.activeHitIndex = -1;
    this.inspectedHit = null;
    this.filesSearched = entry.filesSearched;
    this.filesMatched = entry.filesMatched;
    this.totalMatches = entry.totalMatches;
    this.matchedLines = entry.matchedLines;
    this.bytesSearched = entry.bytesSearched;
    this.elapsedMs = 0.05;
    this.limitHit = entry.limitHit;
    this.cacheHit = 'l0-instant';
    this.lastExecutedKey = entry.exactKey;
    this.lastExecutedHadDraft = hadDraft;
    this.displayedTimeStartMs = entry.timeStartMs;

    if (
      this.flatHits.length > 0 &&
      this.rightInspectorOpen &&
      this.inspectedPath
    ) {
      const firstMatchIdx = this.flatHits.findIndex((h) => !h.isContext);
      this.selectHitByIndex(firstMatchIdx >= 0 ? firstMatchIdx : 0, false);
    }
  }

  executeSearch(opts: ExecuteSearchOptions = {}) {
    const nowMs = Date.now();
    const freshCompiled = compileSearchQuery(this.steps, this.draftStep, this.scope, nowMs);
    if (!freshCompiled.hasExecutableQuery) {
      this.cancelSearch();
      this.resetResultBuffer();
      this.hasSearchedOnce = false;
      this.errorMessage = null;
      return;
    }

    const keys = buildQueryCacheKeys({
      tenant: this.tenant,
      effectiveSources: this.getEffectiveSourceIds(),
      excludedSources: this.scope.excludedSources ?? [],
      types: this.scope.types,
      timePreset: this.scope.timePreset,
      timeMode: 'source',
      tzOffsetMin: -new Date().getTimezoneOffset(),
      sourceTimeFormatsSig: this.getSourceTimeFormatsSig(),
      steps: freshCompiled.activeSteps,
      contextLines: 0,
      hidden: this.hidden,
      respectIgnore: this.respectIgnore,
      maxResults: this.maxResults,
      nowMs,
    });

    if (opts.recordInHistory) {
      this.recordHistory(keys.historyId);
    }

    // Tier L0: True Short-Circuit Instant Cache (< 0.05ms, preserves HitItem references for WeakMap highlight cache)
    if (!opts.forceRefresh && !this.hasActiveDockerSource()) {
      const l0Hit = this.findValidL0Entry(keys.exactKey, keys.baseKey, nowMs);
      if (l0Hit) {
        this.cancelSearch();
        this.currentSearchId += 1;
        this.restoreFromL0Entry(l0Hit, this.draftStep !== null);
        return;
      }
    }

    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      this.pendingSearchOnOpen = true;
      this.connectWebSocket();
      return;
    }

    const reqTimeRange = this.scope.timePreset
      ? parseTimeModifierSpec(this.scope.timePreset, nowMs)
      : null;
    const reqTimeStartMs = reqTimeRange && reqTimeRange.startMs > 0 ? reqTimeRange.startMs : 0;

    this.currentSearchId += 1;
    const searchId = this.currentSearchId;
    this.inflightCacheKeys.set(searchId, {
      exactKey: keys.exactKey,
      baseKey: keys.baseKey,
      sourceRevision: this.sourceRevision,
      hadDraft: this.draftStep !== null,
      maxResults: this.maxResults,
      timeStartMs: reqTimeStartMs,
    });
    if (this.inflightCacheKeys.size > 32) {
      const oldestKey = this.inflightCacheKeys.keys().next().value;
      if (oldestKey !== undefined) this.inflightCacheKeys.delete(oldestKey);
    }

    // Stale-While-Revalidate: keep existing results on screen until the first batch or done arrives
    this.clearFlushSchedule();
    this.pendingChunks = [];
    this.awaitingFirstChunk = true;
    this.errorMessage = null;
    this.isSearching = true;
    this.hasSearchedOnce = true;

    const payload: WsSearchMessage = {
      type: 'search',
      id: searchId,
      tenant: this.tenant,
      pattern: freshCompiled.primaryPattern,
      mode: this.mode,
      case: 'insensitive',
      contains: freshCompiled.contains,
      excludes: freshCompiled.excludes,
      context: 0,
      sources: freshCompiled.sources,
      types: freshCompiled.types,
      globs: freshCompiled.globs,
      fileGlobs: [],
      hidden: this.hidden,
      respectIgnore: this.respectIgnore,
      maxResults: this.maxResults,
      nearbyLines: 0,
      timeStartMs: reqTimeStartMs > 0 ? reqTimeStartMs : undefined,
      timeEndMs: reqTimeRange && reqTimeRange.endMs > 0 ? reqTimeRange.endMs : undefined,
      timeMode: 'source',
      tzOffsetMin: -new Date().getTimezoneOffset(),
    };

    this.ws.send(JSON.stringify(payload));
  }

  async previewTimeFormat(format: string, sample: string): Promise<TimePreviewResponse> {
    try {
      const res = await fetch('/api/time/preview', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          format: format.trim(),
          sample,
          tzOffsetMin: -new Date().getTimezoneOffset(),
        }),
      });
      if (!res.ok) {
        const errData = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
        const msg =
          typeof errData.errorMessage === 'string'
            ? errData.errorMessage
            : typeof errData.error === 'string'
              ? errData.error
              : `HTTP ${res.status}`;
        return {
          validFormat: false,
          matched: false,
          errorMessage: msg,
        };
      }
      return (await res.json()) as TimePreviewResponse;
    } catch (err) {
      return {
        validFormat: false,
        matched: false,
        errorMessage: err instanceof Error ? err.message : 'Preview request failed',
      };
    }
  }

  private handleWsMessage(msg: WsIncomingMessage) {
    if (msg.id !== this.currentSearchId || msg.id === this.cancelledSearchId) {
      if (msg.type === 'done' || msg.type === 'error') {
        this.inflightCacheKeys.delete(msg.id);
      }
      return;
    }

    switch (msg.type) {
      case 'hits': {
        if (Array.isArray(msg.items) && msg.items.length > 0) {
          this.pendingChunks.push(msg.items);
          this.scheduleFlushHits(
            this.awaitingFirstChunk
              ? this.frameProfile.firstFlushLeadMs
              : this.frameProfile.steadyFlushLeadMs
          );
        }
        break;
      }
      case 'progress': {
        if (!this.awaitingFirstChunk) {
          this.filesSearched = msg.filesSearched ?? this.filesSearched;
          this.filesMatched = msg.filesMatched ?? this.filesMatched;
          this.totalMatches = msg.matches ?? this.totalMatches;
          this.bytesSearched = msg.bytesSearched ?? this.bytesSearched;
        }
        break;
      }
      case 'done': {
        const meta = this.inflightCacheKeys.get(msg.id);
        this.inflightCacheKeys.delete(msg.id);

        if (this.awaitingFirstChunk && this.pendingChunks.length === 0) {
          this.resetResultBuffer();
        } else {
          this.flushPendingHitsSync();
        }
        this.isSearching = false;
        this.elapsedMs = msg.elapsedMs ?? 0;
        this.filesSearched = msg.filesSearched ?? this.filesSearched;
        this.filesMatched = msg.filesMatched ?? this.filesMatched;
        this.totalMatches = msg.totalMatches ?? this.totalMatches;
        this.matchedLines = msg.matchedLines ?? this.flatHits.length;
        this.bytesSearched = msg.bytesSearched ?? this.bytesSearched;
        this.limitHit = Boolean(msg.limitHit) && String(msg.limitHit) !== 'none';
        this.cacheHit = msg.cacheHit ?? 'none';
        if (typeof msg.searchCount === 'number' && msg.searchCount > 0) {
          this.searchCount = msg.searchCount;
        }

        if (meta) {
          this.lastExecutedKey = meta.exactKey;
          this.lastExecutedHadDraft = meta.hadDraft;
          this.displayedTimeStartMs = meta.timeStartMs;
          if (meta.sourceRevision === this.sourceRevision) {
            this.putL0Entry(meta);
          }
        }

        if (
          this.activeHitIndex === -1 &&
          this.flatHits.length > 0 &&
          this.rightInspectorOpen &&
          this.inspectedPath
        ) {
          const firstMatchIdx = this.flatHits.findIndex((h) => !h.isContext);
          this.selectHitByIndex(firstMatchIdx >= 0 ? firstMatchIdx : 0, false);
        }
        break;
      }
      case 'error': {
        this.inflightCacheKeys.delete(msg.id);
        if (this.awaitingFirstChunk && this.pendingChunks.length === 0) {
          this.resetResultBuffer();
        } else {
          this.flushPendingHitsSync();
        }
        this.isSearching = false;
        this.errorMessage = msg.message || 'Search error';
        break;
      }
    }
  }

  private scheduleFlushHits(delayMs = 80) {
    if (this.flushTimer !== null || this.flushRaf !== null) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      if (typeof requestAnimationFrame !== 'undefined') {
        this.flushRaf = requestAnimationFrame(() => {
          this.flushRaf = null;
          this.flushPendingHitsSync();
        });
      } else {
        this.flushPendingHitsSync();
      }
    }, delayMs);
  }

  private flushPendingHitsSync() {
    this.clearFlushSchedule();
    if (this.pendingChunks.length === 0) return;
    const chunks = this.pendingChunks;
    this.pendingChunks = [];

    if (this.awaitingFirstChunk) {
      this.awaitingFirstChunk = false;
      this.displayedTimeStartMs = this.inflightCacheKeys.get(this.currentSearchId)?.timeStartMs ?? 0;
      this.clearInspectorSchedule();
      this.groupIndexByFile.clear();
      this.fileGroups = [];
      this.flatHits = [];
      this.activeHitIndex = -1;
      this.inspectedHit = null;
      this.filesMatched = 0;
      this.totalMatches = 0;
      this.matchedLines = 0;
    }

    const nextGroups = this.fileGroups.slice();
    const nextFlat = this.flatHits.slice();
    const touchedGroups = new Set<number>();
    let addedMatches = 0;

    for (let c = 0; c < chunks.length; c++) {
      const batch = chunks[c];
      for (let i = 0; i < batch.length; i++) {
        const item = batch[i];
        nextFlat.push(item);
        const itemMatchCount = item.isContext ? 0 : 1;
        addedMatches += itemMatchCount;
        let gIdx = this.groupIndexByFile.get(item.file);
        if (gIdx === undefined) {
          gIdx = nextGroups.length;
          this.groupIndexByFile.set(item.file, gIdx);
          touchedGroups.add(gIdx);
          nextGroups.push({
            file: item.file,
            items: [item],
            matchCount: itemMatchCount,
            collapsed: false,
          });
        } else {
          let existing = nextGroups[gIdx];
          if (!touchedGroups.has(gIdx)) {
            touchedGroups.add(gIdx);
            existing = {
              ...existing,
              items: existing.items.slice(),
            };
            nextGroups[gIdx] = existing;
          }
          existing.items.push(item);
          if (!item.isContext) {
            existing.matchCount += itemMatchCount;
          }
        }
      }
    }

    this.fileGroups = nextGroups;
    this.flatHits = nextFlat;
    this.filesMatched = Math.max(this.filesMatched, nextGroups.length);
    this.matchedLines = Math.max(this.matchedLines, nextFlat.length);
    this.totalMatches = Math.max(this.totalMatches, this.totalMatches + addedMatches);
  }

  toggleFileGroupCollapse(filePath: string) {
    const idx = this.groupIndexByFile.get(filePath);
    if (idx === undefined) return;
    const group = this.fileGroups[idx];
    if (!group) return;
    const next = this.fileGroups.slice();
    next[idx] = { ...group, collapsed: !group.collapsed };
    this.fileGroups = next;
  }

  setAllGroupsCollapsed(collapsed: boolean) {
    this.fileGroups = this.fileGroups.map((g) => ({ ...g, collapsed }));
  }

  selectHit(item: HitItem) {
    const idx = this.flatHits.findIndex(
      (h) => h.file === item.file && h.line === item.line && h.col === item.col
    );
    if (idx >= 0) {
      this.selectHitByIndex(idx, true);
    } else {
      void this.inspectFileAtLine(item.file, item.line, true);
    }
  }

  /** Updates active row index immediately on pointerdown without opening or rerendering the inspector yet. */
  previewSelectHitByIndex(index: number) {
    if (index < 0 || index >= this.flatHits.length) return;
    this.activeHitIndex = index;
  }

  private commitInspectedHit(hit: HitItem, forceOpenInspector: boolean) {
    this.inspectedHit = hit;
    this.inspectedPath = hit.file;
    this.inspectedLine = hit.line;
    this.inspectorError = null;

    if (!isPossiblyTruncatedHitText(hit.text)) {
      this.inspectAbort?.abort();
      this.inspectAbort = null;
      this.inspectSeq += 1;
      this.inspectedFile = null;
      this.inspectorLoading = false;
      return;
    }

    void this.inspectFileAtLine(hit.file, hit.line, forceOpenInspector);
  }

  selectHitByIndex(index: number, forceOpenInspector = false, deferInspector = false) {
    if (index < 0 || index >= this.flatHits.length) return;
    this.activeHitIndex = index;
    const hit = this.flatHits[index];
    if (!hit) return;

    const gIdx = this.groupIndexByFile.get(hit.file);
    if (gIdx !== undefined && this.fileGroups[gIdx]?.collapsed) {
      const next = this.fileGroups.slice();
      next[gIdx] = { ...next[gIdx], collapsed: false };
      this.fileGroups = next;
    }
    if (forceOpenInspector) {
      this.detailOpen = true;
      if (!this.rightInspectorOpen) this.rightInspectorOpen = true;
    }

    this.clearInspectorSchedule();
    if (
      (deferInspector || hit.text.length > this.frameProfile.deferInspectorThresholdChars) &&
      typeof requestAnimationFrame !== 'undefined'
    ) {
      const targetHit = hit;
      this.inspectorRaf = requestAnimationFrame(() => {
        this.inspectorRaf = null;
        if (this.activeHitIndex === index && this.flatHits[index] === targetHit) {
          this.commitInspectedHit(targetHit, forceOpenInspector);
        }
      });
      return;
    }

    this.commitInspectedHit(hit, forceOpenInspector);
  }

  navigateHits(delta: 1 | -1, rapid = false) {
    if (this.flatHits.length === 0) return;
    let next = this.activeHitIndex + delta;
    if (next < 0) next = 0;
    if (next >= this.flatHits.length) next = this.flatHits.length - 1;
    this.selectHitByIndex(next, false, rapid);
    this.scrollToActiveTick += 1;
  }

  toggleInspectorPane() {
    if (!this.rightInspectorOpen) {
      this.rightInspectorOpen = true;
      if (!this.inspectedPath && this.flatHits.length > 0) {
        const idx = this.activeHitIndex >= 0 ? this.activeHitIndex : 0;
        this.selectHitByIndex(idx, true);
      }
    } else {
      this.rightInspectorOpen = false;
    }
  }

  private getCachedFileContext(cacheKey: string, line: number): FileResponse | null {
    const cached = this.fileContextCache.get(cacheKey);
    if (!cached) return null;
    if (cached.sourceRevision !== this.sourceRevision) {
      this.fileContextCache.delete(cacheKey);
      return null;
    }
    if (cached.data.lines.some((l) => l.n === line)) {
      this.fileContextCache.delete(cacheKey);
      this.fileContextCache.set(cacheKey, cached);
      return cached.data;
    }
    return null;
  }

  private putCachedFileContext(cacheKey: string, data: FileResponse) {
    if (this.fileContextCache.has(cacheKey)) {
      this.fileContextCache.delete(cacheKey);
    } else if (this.fileContextCache.size >= MAX_FILE_CONTEXT_CACHE) {
      const oldestKey = this.fileContextCache.keys().next().value;
      if (oldestKey !== undefined) this.fileContextCache.delete(oldestKey);
    }
    this.fileContextCache.set(cacheKey, {
      sourceRevision: this.sourceRevision,
      data,
    });
  }

  private isDockerVirtualPath(filePath: string): boolean {
    const slash = filePath.indexOf('/');
    if (slash <= 0) return false;
    const prefix = filePath.slice(0, slash).toLowerCase();
    return this.sources.some((s) => s.kind === 'docker' && s.name.toLowerCase() === prefix);
  }

  async inspectFileAtLine(filePath: string, line = 1, forceOpen = true) {
    const targetLine = Math.max(1, line);
    if (this.inspectedHit && (this.inspectedHit.file !== filePath || this.inspectedHit.line !== targetLine)) {
      this.inspectedHit = null;
    }
    const dockerEpoch = this.isDockerVirtualPath(filePath) ? `\u0000${this.searchCount}` : '';
    const dockerSinceSec = computeDockerPreviewSinceSec(
      this.sources,
      filePath,
      this.displayedTimeStartMs
    );
    const dockerSincePart = dockerSinceSec !== null ? `\u0000s=${dockerSinceSec}` : '';
    const cacheKey = `${this.tenant}\u0000${filePath}\u0000${targetLine}${dockerEpoch}${dockerSincePart}`;

    if (forceOpen) {
      this.detailOpen = true;
      if (!this.rightInspectorOpen) this.rightInspectorOpen = true;
    }

    const cached = this.getCachedFileContext(cacheKey, targetLine);
    if (cached) {
      this.inspectAbort?.abort();
      this.inspectAbort = null;
      this.inspectSeq += 1;
      this.inspectedPath = filePath;
      this.inspectedLine = targetLine;
      this.inspectedFile = cached;
      this.inspectorLoading = false;
      this.inspectorError = null;
      return;
    }

    this.inspectAbort?.abort();
    const controller = new AbortController();
    this.inspectAbort = controller;
    const seq = ++this.inspectSeq;
    const reqRevision = this.sourceRevision;

    if (this.inspectedPath !== filePath || this.inspectedLine !== targetLine) {
      this.inspectedFile = null;
    }
    this.inspectedPath = filePath;
    this.inspectedLine = targetLine;
    this.inspectorLoading = true;
    this.inspectorError = null;

    try {
      const params = new URLSearchParams({
        tenant: this.tenant,
        path: filePath,
        line: String(targetLine),
        context: '0',
      });
      if (dockerSinceSec !== null) {
        params.set('since', String(dockerSinceSec));
      }
      const res = await fetch(`/api/file?${params.toString()}`, {
        signal: controller.signal,
      });
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }
      const data = (await res.json()) as FileResponse;
      if (seq !== this.inspectSeq) return;
      if (reqRevision === this.sourceRevision) {
        this.putCachedFileContext(cacheKey, data);
      }
      this.inspectedFile = data;
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') return;
      if (seq !== this.inspectSeq) return;
      this.inspectorError = err instanceof Error ? err.message : 'Failed to load file context';
    } finally {
      if (seq === this.inspectSeq) {
        this.inspectorLoading = false;
      }
    }
  }
}

export const workbench = new WorkbenchState();
