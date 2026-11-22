import { flushSync } from 'svelte';
import type {
  DataSourceItem,
  DirSuggestEntry,
  FileHitGroup,
  FileLine,
  FileResponse,
  HitItem,
  McpCallLogItem,
  McpCapabilityItem,
  McpStateResponse,
  McpStats,
  MetaResponse,
  QueryStep,
  ScopeFilter,
  SearchHistoryEntry,
  SearchMode,
  SourceKind,
  SourcesResponse,
  TimePreset,
  TimePreviewResponse,
  ViewAdapterId,
  WsIncomingMessage,
} from './types';
import {
  getHeadlessAdapter,
  resolveBatchViewAdapter,
  resolvePathAdapterId,
} from './adapters/index.ts';
import { messages, type Locale } from './i18n';
import { DEFAULT_MCP_MAX_LOGS, clampMcpMaxLogs } from './mcp';
import {
  DEFAULT_CONTEXT_AUTO_LOAD_PACE,
  DEFAULT_CONTEXT_STEP_LINES,
  DEFAULT_INITIAL_CONTEXT_LINES,
  computeDownwardFetchWindow,
  computeInitialFetchWindow,
  computeMergedContextBounds,
  computeUpwardFetchWindow,
  type ContextAutoLoadPace,
} from './context-window';
import {
  compileSearchQuery,
  createQueryStep,
  formatHistoryLabel,
  normalizeStep,
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
import {
  extractShareReplayFromUrl,
  stripShareParamFromUrl,
  type ShareReplayState,
} from './share';
import {
  computeEnabledSourcesSyncSig,
  normalizeMetaPrefilterCatalog,
} from './prefilter';
import { L0StepCache, type InflightCacheMeta, type L0CacheEntry } from './l0-cache';
import {
  clearHistoryFromStorage,
  getBrowserLocalStorage,
  getBrowserSessionStorage,
  loadCachedSourcesFromStorage,
  loadHistoryFromStorage,
  loadSettingsFromStorage,
  loadThemeFromStorage,
  sanitizeTenantId,
  saveCachedSourcesToStorage,
  saveHistoryToStorage,
  saveSettingsToStorage,
  saveThemeToStorage,
  upsertHistoryEntry,
  type PersistedSettings,
} from './state/persistence';
import {
  fetchAuthStatus,
  postAuthLogin,
  postAuthLogout,
  postClearMcpLogs,
  postDeleteSource,
  postMcpConfig,
  postTimePreview,
  postToggleAllSources,
  postToggleSource,
  postUpsertSource,
  requestDirSuggestions,
  requestFileWindow,
  requestMcpState,
  requestMeta,
  requestSources,
  type UpsertSourcePayload,
} from './state/api-client';
import {
  FileContextLruCache,
  buildFileContextCacheKey,
  collapseAllGroups,
  isPossiblyTruncatedHitText,
  mergeContextBatchResult,
  mergeHitChunks,
  normalizeDoneTelemetry,
  resolveAnchorByteHint,
  toggleGroupCollapseAt,
} from './state/stream-buffer';
import {
  buildAppendedStepList,
  buildEditedStepState,
  buildSearchRequestPlan,
  buildWorkbenchShareUrl,
  computeActiveSources,
  computeTimeBasisSummary,
  normalizeScopeSourceLists,
  resolveSourceIdOrName,
  sameSourceList,
  type ExecutedQuerySnapshot,
} from './state/query-actions';
import { SearchWsTransport } from './state/ws-transport';

export type DrawerPanelId = 'sources' | 'mcp' | 'shortcuts' | 'settings' | 'context';

export interface ExecuteSearchOptions {
  forceRefresh?: boolean;
  recordInHistory?: boolean;
  replayTimeRange?: { startMs: number; endMs: number };
  keepShareUrl?: boolean;
}

class WorkbenchState {
  // Authentication & Session Gate
  authState = $state<'checking' | 'locked' | 'unlocking' | 'authenticated'>('checking');
  authRequired = $state<boolean>(false);
  mcpTokenRequired = $state<boolean>(false);
  authSubmitting = $state<boolean>(false);
  authError = $state<string | null>(null);
  authShakeTick = $state<number>(0);
  workspaceEnteredFromLogin = $state<boolean>(false);
  private unlockTimer: ReturnType<typeof setTimeout> | null = null;

  // Workspace Metadata, Frame Pacing & WebSocket Transport
  meta = $state<MetaResponse>({
    rootLabel: 'webgrep',
    root: '.',
    engine: 'libwebgrep 0.5.0 · SIMD',
    types: [],
  });
  prefilterCatalog = $derived(normalizeMetaPrefilterCatalog(this.meta));
  wsStatus = $state<'connecting' | 'connected' | 'reconnecting' | 'offline'>('connecting');
  wsDegraded = $state<boolean>(false);
  frameProfile = $state.raw<FrameProfile>(buildFrameProfileForHz(60));
  private pendingSearchOnOpen = false;
  private pendingReplayTimeRange: { startMs: number; endMs: number } | undefined = undefined;
  private lifecycleBound = false;
  private stopFrameProbe: (() => void) | null = null;
  private readonly rawFetch = (input: RequestInfo | URL, init?: RequestInit) => fetch(input, init);
  private readonly apiFetcher = (input: RequestInfo | URL, init?: RequestInit) =>
    this.apiFetch(input, init);
  private readonly wsTransport = new SearchWsTransport({
    canConnect: () =>
      !(this.authRequired && this.authState !== 'authenticated' && this.authState !== 'unlocking'),
    shouldReconnect: () =>
      !(this.authRequired && (this.authState === 'locked' || this.authState === 'checking')),
    shouldVerifySessionOnDisconnect: () =>
      this.authRequired && this.authState === 'authenticated',
    getCurrentSearchId: () => this.currentSearchId,
    onStatusChange: (status) => {
      this.wsStatus = status;
    },
    onDegradedChange: (degraded) => {
      this.wsDegraded = degraded;
    },
    onOpen: (isReconnect) => {
      if (isReconnect || !this.sourcesLoaded) {
        void this.fetchMeta();
        void this.fetchSources();
        void this.fetchMcpState();
      }
      if (this.pendingSearchOnOpen && this.hasExecutableQuery) {
        this.pendingSearchOnOpen = false;
        const replayTimeRange = this.pendingReplayTimeRange;
        this.pendingReplayTimeRange = undefined;
        this.executeSearch({
          forceRefresh: false,
          recordInHistory: false,
          keepShareUrl: Boolean(replayTimeRange),
          replayTimeRange,
        });
      }
    },
    onMcpStatePush: (state) => {
      this.applyMcpState(state);
    },
    onSearchMessage: (msg) => {
      this.handleWsMessage(msg);
    },
    onVerifySessionOnDisconnect: () => {
      void this.verifySessionOnDisconnect();
    },
    onDisconnectSearchReset: () => {
      this.isSearching = false;
    },
  });

  // Structured Search State & Engine Settings
  steps = $state<QueryStep[]>([]);
  pattern = $state<string>('');
  caseSensitive = $state<boolean>(false);
  wholeWord = $state<boolean>(false);
  isRegex = $state<boolean>(false);
  scope = $state<ScopeFilter>({
    sources: [],
    excludedSources: [],
    types: [],
    timePreset: '',
  });
  readonly mode: SearchMode = 'literal';
  hidden = $state<boolean>(false);
  respectIgnore = $state<boolean>(false);
  maxResults = $state<number>(20000);

  // Execution & Streaming Telemetry
  currentSearchId = $state<number>(0);
  searchCount = $state<number>(0);
  isSearching = $state<boolean>(false);
  errorMessage = $state<string | null>(null);
  filesSearched = $state<number>(0);
  filesMatched = $state<number>(0);
  totalMatches = $state<number>(0);
  matchedLines = $state<number>(0);
  bytesSearched = $state<number>(0);
  filesPruned = $state<number>(0);
  bytesSaved = $state<number>(0);
  elapsedMs = $state<number>(0);
  limitHit = $state<boolean>(false);
  cacheHit = $state<string>('none');
  hasSearchedOnce = $state<boolean>(false);
  fileGroups = $state.raw<FileHitGroup[]>([]);
  flatHits = $state.raw<HitItem[]>([]);
  private cancelledSearchId = -1;
  private lastExecutedKey = '';
  private lastExecutedHadDraft = false;
  private lastExecutedSnapshot: ExecutedQuerySnapshot | null = null;
  private pendingShareReplay: ShareReplayState | null = null;
  private pendingReplayTarget: { path: string; line: number } | null = null;
  private displayedTimeStartMs = 0;
  private groupIndexByFile = new Map<string, number>();
  private pendingChunks: HitItem[][] = [];
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private flushRaf: number | null = null;
  private awaitingFirstChunk = false;

  // L0 Step LRU Cache + Source Revision
  private l0Store = new L0StepCache();
  private get sourceRevision(): number {
    return this.l0Store.sourceRevision;
  }
  private lastEnabledSourcesSig = '';
  private inflightCacheKeys = new Map<number, InflightCacheMeta>();

  // Data Sources & Drawers
  tenant = $state<string>('default');
  sources = $state.raw<DataSourceItem[]>([]);
  sourcesLoading = $state<boolean>(false);
  sourcesLoaded = $state<boolean>(false);
  addSourceModalOpen = $state<boolean>(false);
  drawerPanel = $state<DrawerPanelId | null>(null);
  sourceAddOpen = $state<boolean>(false);
  mobileScopeOpen = $state<boolean>(false);
  rightDrawerOpen = $derived<boolean>(this.drawerPanel !== null);
  settingsOpen = $derived<boolean>(this.drawerPanel === 'settings');
  sourcesDrawerOpen = $derived<boolean>(this.drawerPanel === 'sources');
  mcpDrawerOpen = $derived<boolean>(this.drawerPanel === 'mcp');
  shortcutsDrawerOpen = $derived<boolean>(this.drawerPanel === 'shortcuts');
  contextDrawerOpen = $derived<boolean>(this.drawerPanel === 'context');
  enabledSourceCount = $derived<number>(
    this.sources.reduce((acc, s) => acc + (s.enabled ? 1 : 0), 0)
  );
  sourceById = $derived.by(() => new Map(this.sources.map((s) => [s.id, s])));
  sourceByName = $derived.by(() => new Map(this.sources.map((s) => [s.name.toLowerCase(), s])));

  // Active Hit, Right Inspector & File Context LRU
  activeHitIndex = $state<number>(-1);
  inspectedHit = $state.raw<HitItem | null>(null);
  scrollToActiveTick = $state<number>(0);
  inspectedPath = $state<string | null>(null);
  inspectedLine = $state<number>(1);
  inspectedFile = $state<FileResponse | null>(null);
  inspectorLoading = $state<boolean>(false);
  inspectorError = $state<string | null>(null);
  inspectorTab = $state<'structured' | 'raw'>('structured');
  private fileContextCache = new FileContextLruCache();
  private inspectSeq = 0;
  private inspectAbort: AbortController | null = null;
  private inspectorRaf: number | null = null;

  // Slide-out Surrounding Records Drawer
  contextPath = $state<string | null>(null);
  contextAnchorLine = $state<number>(1);
  contextLines = $state.raw<FileLine[]>([]);
  contextTotalLines = $state<number>(0);
  contextEof = $state<boolean>(false);
  contextBinary = $state<boolean>(false);
  contextLoadingInitial = $state<boolean>(false);
  contextLoadingBefore = $state<boolean>(false);
  contextLoadingAfter = $state<boolean>(false);
  contextError = $state<string | null>(null);
  contextCenterTick = $state<number>(0);
  contextPrettyMode = $state<boolean>(false);
  private contextSeq = 0;
  private contextAbort: AbortController | null = null;
  private contextFirstByte: number | null = null;
  private contextNextByte: number | null = null;

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
  scopeSidebarOpen = $derived<boolean>(
    this.isCompact ? this.mobileScopeOpen : this.leftSidebarOpen
  );
  hasActiveScope = $derived<boolean>(
    this.scope.timePreset !== '' ||
      this.scope.sources.length > 0 ||
      (this.scope.excludedSources?.length ?? 0) > 0
  );
  isTouch = $state<boolean>(false);
  insertToken: ((token: string) => void) | null = null;
  codeFontSize = $state<number>(13.5);
  wordWrap = $state<boolean>(true);
  previewLines = $state<number>(3);
  contextInitialLines = $state<number>(DEFAULT_INITIAL_CONTEXT_LINES);
  contextStepLines = $state<number>(DEFAULT_CONTEXT_STEP_LINES);
  contextAutoLoadPace = $state<ContextAutoLoadPace>(DEFAULT_CONTEXT_AUTO_LOAD_PACE);
  resultDensity = $state<'compact' | 'comfortable'>('comfortable');
  activeViewAdapter = $derived<ViewAdapterId>(
    resolveBatchViewAdapter(
      this.flatHits,
      this.sourceByName,
      computeActiveSources(this.sources, this.scope)
    )
  );
  activeInspectorAdapter = $derived<ViewAdapterId>(
    this.inspectedPath
      ? resolvePathAdapterId(this.inspectedPath, this.sourceByName)
      : this.activeViewAdapter
  );
  activeInspectContextLines = $derived<number>(
    getHeadlessAdapter(this.activeInspectorAdapter).inspectContextLines
  );
  collapsedFilesSet = $derived.by(() => {
    const set = new Set<string>();
    for (const g of this.fileGroups) {
      if (g.collapsed) set.add(g.file);
    }
    return set;
  });
  searchHistory = $state<SearchHistoryEntry[]>([]);

  // MCP Service State
  mcpEnabled = $state<boolean>(true);
  mcpMaxLogs = $state<number>(DEFAULT_MCP_MAX_LOGS);
  mcpEndpointPath = $state<string>('/mcp');
  mcpProtocolVersion = $state<string>('2025-03-26');
  mcpStats = $state<McpStats>({ totalCalls: 0, errorCalls: 0, lastCallMs: 0 });
  mcpCapabilities = $state.raw<McpCapabilityItem[]>([]);
  mcpLogs = $state.raw<McpCallLogItem[]>([]);
  mcpLoaded = $state<boolean>(false);
  private mcpConfigTimer: ReturnType<typeof setTimeout> | null = null;

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
          exclude: false,
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
  hasAnyQueryInput = $derived<boolean>(
    this.steps.length > 0 ||
      this.pattern.trim().length > 0 ||
      this.scope.timePreset !== ''
  );
  hasExecutableQuery = $derived<boolean>(this.compiledQuery.hasExecutableQuery);
  hasRegexActive = $derived<boolean>(this.isRegex || this.steps.some((s) => s.isRegex));
  hasCaseActive = $derived<boolean>(
    this.caseSensitive || this.steps.some((s) => s.caseSensitive)
  );
  hasWordActive = $derived<boolean>(this.wholeWord || this.steps.some((s) => s.wholeWord));
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
    if (typeof window !== 'undefined' && this.pendingShareReplay === null) {
      this.pendingShareReplay = extractShareReplayFromUrl(window.location.href);
    }
    if (typeof window !== 'undefined' && !this.lifecycleBound) {
      this.lifecycleBound = true;
      applyFrameProfileCssVars(this.frameProfile);
      this.stopFrameProbe = startAdaptiveFrameProbe((profile) => {
        this.frameProfile = profile;
      });
      window.addEventListener('beforeunload', () => {
        this.wsTransport.handleBeforeUnload();
        this.stopFrameProbe?.();
        this.stopFrameProbe = null;
        if (this.mcpConfigTimer) {
          clearTimeout(this.mcpConfigTimer);
          this.mcpConfigTimer = null;
        }
        if (this.unlockTimer) {
          clearTimeout(this.unlockTimer);
          this.unlockTimer = null;
        }
      });
      window.addEventListener('pagehide', (e) => {
        this.wsTransport.handlePageHide(e.persisted);
      });
      window.addEventListener('pageshow', (e) => {
        this.wsTransport.handlePageShow();
        if (e.persisted && (!this.authRequired || this.authState === 'authenticated')) {
          this.connectWebSocket();
          void this.fetchSources();
          void this.fetchMcpState();
        }
      });
    }
    void this.bootstrapAuth();
  }

  // Drawer & Sidebar Coordination
  private openDrawerPanel(panel: DrawerPanelId, expandAdd = false) {
    this.abortContextFetch();
    this.paletteOpen = false;
    this.mobileScopeOpen = false;
    this.sourceAddOpen = expandAdd;
    this.drawerPanel = panel;
  }

  openSourcesDrawer(expandAdd = false) {
    this.openDrawerPanel('sources', expandAdd);
  }

  openMcpDrawer() {
    this.openDrawerPanel('mcp');
    void this.fetchMcpState();
  }

  openShortcutsDrawer() {
    this.openDrawerPanel('shortcuts');
  }

  openSettingsDrawer() {
    this.openDrawerPanel('settings');
  }

  toggleScopeSidebar() {
    if (this.isCompact) {
      this.mobileScopeOpen = !this.mobileScopeOpen;
      if (this.mobileScopeOpen) {
        this.paletteOpen = false;
        this.closeRightDrawer();
      }
    } else {
      this.leftSidebarOpen = !this.leftSidebarOpen;
    }
  }

  closeMobileScope() {
    this.mobileScopeOpen = false;
  }

  openTimePicker() {
    this.paletteOpen = false;
    this.closeRightDrawer();
    if (this.isCompact) {
      this.mobileScopeOpen = true;
    } else {
      this.leftSidebarOpen = true;
    }
  }

  closeTimePicker() {
    this.mobileScopeOpen = false;
  }

  closeSettings() {
    if (this.drawerPanel === 'settings') {
      this.drawerPanel = null;
    }
  }

  closeRightDrawer() {
    this.abortContextFetch();
    this.sourceAddOpen = false;
    this.drawerPanel = null;
  }

  openSourceManager() {
    this.openSourcesDrawer(false);
  }

  openAddSourceModal() {
    this.openSourcesDrawer(true);
  }

  openSettings(tab: 'general' | 'sources' | 'add-source' | 'shortcuts' = 'general') {
    if (tab === 'sources') {
      this.openSourcesDrawer(false);
    } else if (tab === 'add-source') {
      this.openSourcesDrawer(true);
    } else if (tab === 'shortcuts') {
      this.openShortcutsDrawer();
    } else {
      this.openSettingsDrawer();
    }
  }

  // Auth & Session Lifecycle
  private async apiFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    const res = await fetch(input, { credentials: 'same-origin', ...init });
    if (res.status === 401 && this.authRequired) {
      this.handleSessionExpired();
    }
    return res;
  }

  private startAuthenticatedSession() {
    this.loadCachedSources();
    void this.fetchMeta();
    void this.fetchMcpState();
    this.connectWebSocket();
    const replay = this.pendingShareReplay;
    this.pendingShareReplay = null;
    if (replay) {
      void this.fetchSources().then(() => {
        this.applyShareReplay(replay);
      });
    } else {
      void this.fetchSources();
    }
  }

  private resetForAuthLock() {
    if (this.unlockTimer) {
      clearTimeout(this.unlockTimer);
      this.unlockTimer = null;
    }
    this.closeRightDrawer();
    this.paletteOpen = false;
    this.mobileScopeOpen = false;
    this.clearSearch();
    this.wsTransport.closeForLock();
    this.invalidateCaches();
    this.sources = [];
    this.sourcesLoaded = false;
    this.authError = null;
    this.workspaceEnteredFromLogin = false;
    this.authState = 'locked';
  }

  private handleSessionExpired() {
    if (this.authState !== 'locked' && this.authState !== 'checking') {
      this.resetForAuthLock();
    }
  }

  async bootstrapAuth() {
    const data = await fetchAuthStatus(this.rawFetch);
    if (data) {
      this.authRequired = Boolean(data.authRequired);
      this.mcpTokenRequired = Boolean(data.mcpTokenRequired);
      if (!this.authRequired || data.authenticated) {
        this.authState = 'authenticated';
        this.startAuthenticatedSession();
        return;
      }
      this.authError = null;
      this.authState = 'locked';
      return;
    }
    this.authState = 'authenticated';
    this.startAuthenticatedSession();
  }

  async submitLogin(password: string): Promise<boolean> {
    if (!password || this.authSubmitting) return false;
    this.authSubmitting = true;
    this.authError = null;
    const result = await postAuthLogin(this.rawFetch, password);
    if (!result.ok) {
      this.authError = result.invalidPassword
        ? this.t.auth.invalidPassword
        : this.t.auth.networkError;
      this.authShakeTick += 1;
      this.authSubmitting = false;
      return false;
    }
    if (typeof result.data.mcpTokenRequired === 'boolean') {
      this.mcpTokenRequired = result.data.mcpTokenRequired;
    }
    this.authRequired = true;
    this.authSubmitting = false;
    this.workspaceEnteredFromLogin = true;
    this.startAuthenticatedSession();

    const reduceMotion =
      typeof window !== 'undefined' &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduceMotion) {
      this.authState = 'authenticated';
    } else {
      this.authState = 'unlocking';
      if (this.unlockTimer) clearTimeout(this.unlockTimer);
      this.unlockTimer = setTimeout(() => {
        this.unlockTimer = null;
        if (this.authState === 'unlocking') {
          this.authState = 'authenticated';
        }
      }, 190);
    }
    return true;
  }

  async logout() {
    if (!this.authRequired) return;
    this.resetForAuthLock();
    await postAuthLogout(this.rawFetch);
  }

  private async verifySessionOnDisconnect() {
    const data = await fetchAuthStatus(this.rawFetch);
    if (data && data.authRequired && !data.authenticated) {
      this.handleSessionExpired();
    }
  }

  // Share Replay
  private clearShareUrlParamIfPresent() {
    if (typeof window === 'undefined') return;
    try {
      const url = new URL(window.location.href);
      if (url.searchParams.has('share')) {
        window.history.replaceState(
          window.history.state,
          '',
          stripShareParamFromUrl(window.location.href)
        );
      }
    } catch {
      // ignore history errors
    }
  }

  buildPreviewShareUrl(baseHref: string): string {
    return buildWorkbenchShareUrl({
      baseHref,
      hasSearchedOnce: this.hasSearchedOnce,
      lastExecutedSnapshot: this.lastExecutedSnapshot,
      steps: this.steps,
      draftStep: this.draftStep,
      scope: this.scope,
      displayedTimeStartMs: this.displayedTimeStartMs,
      hidden: this.hidden,
      respectIgnore: this.respectIgnore,
      maxResults: this.maxResults,
      inspectedHit: this.inspectedHit,
      activeHit: this.activeHit,
      inspectedPath: this.inspectedPath,
      inspectedLine: this.inspectedLine,
      flatHits: this.flatHits,
      sources: this.sources,
      sourceById: this.sourceById,
      contextPrettyMode: this.contextPrettyMode,
      inspectorRaw: this.inspectorTab === 'raw',
      openContext: this.contextDrawerOpen,
      mtimeCount: this.getEffectiveTimeBasisSummary().mtimeCount,
    });
  }

  applyShareReplay(replay: ShareReplayState) {
    this.steps = replay.steps.map((s) => createQueryStep(s.text, s));
    this.applyDraftStep(replay.draft);
    this.scope = {
      sources: replay.sources.map((s) => resolveSourceIdOrName(this.sources, s)),
      excludedSources: replay.excludedSources.map((s) => resolveSourceIdOrName(this.sources, s)),
      types: [],
      timePreset: replay.timePreset,
    };
    this.hidden = replay.hidden;
    this.respectIgnore = replay.respectIgnore;
    this.maxResults = replay.maxResults;
    this.contextPrettyMode = replay.contextPretty;
    this.inspectorTab = replay.inspectorRaw ? 'raw' : 'structured';
    this.saveSettings();
    this.pendingReplayTarget = replay.contextPath
      ? { path: replay.contextPath, line: replay.contextAnchorLine }
      : null;
    const replayTimeRange =
      replay.timeStartMs > 0 || replay.timeEndMs > 0
        ? { startMs: replay.timeStartMs, endMs: replay.timeEndMs }
        : undefined;

    if (replay.contextPath) {
      this.displayedTimeStartMs = replay.timeStartMs;
      this.rightInspectorOpen = true;
      if (this.isCompact) {
        this.detailOpen = true;
      }
      void this.inspectFileAtLine(
        replay.contextPath,
        replay.contextAnchorLine,
        false,
        replay.contextAnchorByte
      );
      if (replay.openContext) {
        void this.openContextDrawer(
          replay.contextPath,
          replay.contextAnchorLine,
          replay.contextAnchorByte
        );
      }
    }

    this.executeSearch({
      forceRefresh: false,
      recordInHistory: true,
      keepShareUrl: true,
      replayTimeRange,
    });
  }

  // Caches, Settings, Theme & History Persistence
  private invalidateCaches() {
    this.l0Store.invalidate();
    this.fileContextCache.clear();
    this.lastExecutedKey = '';
  }

  private currentSettingsSnapshot(): PersistedSettings {
    return {
      locale: this.locale,
      tenant: this.tenant,
      respectIgnore: this.respectIgnore,
      hidden: this.hidden,
      previewLines: this.previewLines,
      contextInitialLines: this.contextInitialLines,
      contextStepLines: this.contextStepLines,
      contextAutoLoadPace: this.contextAutoLoadPace,
      mcpMaxLogs: this.mcpMaxLogs,
      maxResults: this.maxResults,
      codeFontSize: this.codeFontSize,
      wordWrap: this.wordWrap,
      resultDensity: this.resultDensity,
    };
  }

  private loadSettings() {
    const loaded = loadSettingsFromStorage(
      getBrowserLocalStorage(),
      getBrowserSessionStorage(),
      this.currentSettingsSnapshot()
    );
    if (!loaded) return;
    this.locale = loaded.locale;
    this.tenant = loaded.tenant;
    this.respectIgnore = loaded.respectIgnore;
    this.hidden = loaded.hidden;
    this.previewLines = loaded.previewLines;
    this.contextInitialLines = loaded.contextInitialLines;
    this.contextStepLines = loaded.contextStepLines;
    this.contextAutoLoadPace = loaded.contextAutoLoadPace;
    this.mcpMaxLogs = loaded.mcpMaxLogs;
    this.maxResults = loaded.maxResults;
    this.codeFontSize = loaded.codeFontSize;
    this.wordWrap = loaded.wordWrap;
    this.resultDensity = loaded.resultDensity;
  }

  setTenant(nextTenant: string) {
    const clean = sanitizeTenantId(nextTenant);
    if (clean === this.tenant) return;
    this.tenant = clean;
    this.invalidateCaches();
    this.saveSettings();
    void this.fetchSources();
    if (this.hasSearchedOnce && this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: true });
    }
  }

  toggleLocale() {
    this.locale = this.locale === 'zh' ? 'en' : 'zh';
    this.saveSettings();
  }

  saveSettings() {
    saveSettingsToStorage(getBrowserLocalStorage(), this.currentSettingsSnapshot());
  }

  resetSettings() {
    this.respectIgnore = false;
    this.hidden = false;
    this.previewLines = 3;
    this.contextInitialLines = DEFAULT_INITIAL_CONTEXT_LINES;
    this.contextStepLines = DEFAULT_CONTEXT_STEP_LINES;
    this.contextAutoLoadPace = DEFAULT_CONTEXT_AUTO_LOAD_PACE;
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
    this.darkMode = loadThemeFromStorage(getBrowserLocalStorage(), getBrowserSessionStorage());
    this.applyThemeClass();
  }

  toggleTheme() {
    this.darkMode = !this.darkMode;
    this.applyThemeClass();
    saveThemeToStorage(getBrowserLocalStorage(), this.darkMode);
  }

  private applyThemeClass() {
    if (typeof document !== 'undefined') {
      document.documentElement.classList.toggle('dark', this.darkMode);
    }
  }

  private loadHistory() {
    this.searchHistory = loadHistoryFromStorage(getBrowserLocalStorage());
  }

  private recordHistory(historyId: string) {
    const normSteps = this.steps.map(normalizeStep).filter((s) => s.text.length > 0);
    const normDraft = this.draftStep;
    if (normSteps.length === 0 && !normDraft && !this.scope.timePreset) return;
    const label =
      formatHistoryLabel(normSteps, normDraft) ||
      (this.scope.timePreset
        ? formatTimeScopeLabel(this.scope.timePreset, this.t.scopeBar.timeLabels)
        : '');
    if (!label) return;
    this.searchHistory = upsertHistoryEntry(this.searchHistory, {
      id: historyId,
      steps: normSteps,
      draft: normDraft,
      label,
      timestamp: Date.now(),
      scope: {
        sources: [...this.scope.sources],
        excludedSources: [...(this.scope.excludedSources ?? [])],
        types: [],
        timePreset: this.scope.timePreset,
      },
    });
    saveHistoryToStorage(getBrowserLocalStorage(), this.searchHistory);
  }

  removeHistoryEntry(id: string) {
    this.searchHistory = this.searchHistory.filter((h) => h.id !== id);
    saveHistoryToStorage(getBrowserLocalStorage(), this.searchHistory);
  }

  clearHistory() {
    this.searchHistory = [];
    clearHistoryFromStorage(getBrowserLocalStorage());
  }

  // Meta, Sources & MCP API Actions
  async fetchMeta() {
    const data = await requestMeta(this.apiFetcher);
    if (data) {
      this.meta = data;
    }
  }

  private loadCachedSources() {
    if (this.sourcesLoaded) return;
    const valid = loadCachedSourcesFromStorage(getBrowserLocalStorage());
    if (valid.length > 0 && this.sources.length === 0) {
      this.sources = valid;
      this.lastEnabledSourcesSig = computeEnabledSourcesSyncSig(valid);
    }
  }

  private applySourcesResponse(data: SourcesResponse) {
    if (typeof data.searchCount === 'number' && data.searchCount >= 0) {
      this.searchCount = data.searchCount;
    }
    if (Array.isArray(data.sources)) {
      const nextSig = computeEnabledSourcesSyncSig(data.sources);
      if (this.lastEnabledSourcesSig && nextSig !== this.lastEnabledSourcesSig) {
        this.invalidateCaches();
      }
      this.lastEnabledSourcesSig = nextSig;
      this.sources = data.sources;
      this.sourcesLoaded = true;
      saveCachedSourcesToStorage(getBrowserLocalStorage(), data.sources);
    }
  }

  private handleMutatedSources(data: SourcesResponse | null) {
    if (!data) return;
    this.invalidateCaches();
    this.applySourcesResponse(data);
    if (this.hasSearchedOnce && this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: true });
    }
  }

  async fetchSources() {
    this.sourcesLoading = true;
    try {
      const data = await requestSources(this.apiFetcher);
      if (data) {
        this.applySourcesResponse(data);
      }
    } finally {
      this.sourcesLoading = false;
    }
  }

  async upsertDirectorySource(payload: UpsertSourcePayload) {
    this.handleMutatedSources(await postUpsertSource(this.apiFetcher, payload));
  }

  async toggleSourceEnabled(id: string) {
    this.handleMutatedSources(await postToggleSource(this.apiFetcher, id));
  }

  async toggleAllSourcesEnabled(enabled: boolean) {
    this.handleMutatedSources(await postToggleAllSources(this.apiFetcher, enabled));
  }

  async removeSource(id: string) {
    const data = await postDeleteSource(this.apiFetcher, id);
    if (!data) return;
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

  async fetchDirSuggestions(queryPath: string, kind: SourceKind = 'dir'): Promise<DirSuggestEntry[]> {
    return requestDirSuggestions(this.apiFetcher, queryPath, kind);
  }

  private applyMcpState(data: Partial<McpStateResponse>) {
    if (typeof data.enabled === 'boolean') {
      this.mcpEnabled = data.enabled;
    }
    if (typeof data.maxLogs === 'number' && Number.isFinite(data.maxLogs)) {
      this.mcpMaxLogs = clampMcpMaxLogs(data.maxLogs, DEFAULT_MCP_MAX_LOGS);
      this.saveSettings();
    }
    if (typeof data.endpointPath === 'string' && data.endpointPath.length > 0) {
      this.mcpEndpointPath = data.endpointPath;
    }
    if (typeof data.protocolVersion === 'string' && data.protocolVersion.length > 0) {
      this.mcpProtocolVersion = data.protocolVersion;
    }
    if (typeof data.tokenRequired === 'boolean') {
      this.mcpTokenRequired = data.tokenRequired;
    }
    if (data.stats && typeof data.stats === 'object') {
      this.mcpStats = {
        totalCalls: Number(data.stats.totalCalls) || 0,
        errorCalls: Number(data.stats.errorCalls) || 0,
        lastCallMs: Number(data.stats.lastCallMs) || 0,
      };
    }
    if (Array.isArray(data.capabilities)) {
      this.mcpCapabilities = data.capabilities;
    }
    if (Array.isArray(data.logs)) {
      this.mcpLogs = data.logs;
    }
    this.mcpLoaded = true;
  }

  async fetchMcpState() {
    const data = await requestMcpState(this.apiFetcher);
    if (data) {
      this.applyMcpState(data);
    }
  }

  async setMcpEnabled(enabled: boolean) {
    this.mcpEnabled = enabled;
    const data = await postMcpConfig(this.apiFetcher, { enabled });
    if (data) {
      this.applyMcpState(data);
    }
  }

  setMcpMaxLogs(rawMax: number) {
    this.mcpMaxLogs = clampMcpMaxLogs(rawMax, DEFAULT_MCP_MAX_LOGS);
    this.saveSettings();
    if (this.mcpConfigTimer !== null) {
      clearTimeout(this.mcpConfigTimer);
    }
    this.mcpConfigTimer = setTimeout(() => {
      this.mcpConfigTimer = null;
      void postMcpConfig(this.apiFetcher, { maxLogs: this.mcpMaxLogs }).then((data) => {
        if (data) {
          this.applyMcpState(data);
        }
      });
    }, 220);
  }

  async clearMcpLogs() {
    const data = await postClearMcpLogs(this.apiFetcher);
    if (data) {
      this.applyMcpState(data);
    }
  }

  // Flag Toggles, Progressive Query Steps & Scope Actions
  toggleCaseSensitive() {
    this.caseSensitive = !this.caseSensitive;
  }

  toggleWholeWord() {
    this.wholeWord = !this.wholeWord;
  }

  toggleRegexMode() {
    this.isRegex = !this.isRegex;
  }

  private resetDraft() {
    this.pattern = '';
    this.caseSensitive = false;
    this.wholeWord = false;
    this.isRegex = false;
  }

  private applyDraftStep(step: QueryStep | null) {
    if (!step) {
      this.resetDraft();
      return;
    }
    this.pattern = step.text;
    this.caseSensitive = step.caseSensitive;
    this.wholeWord = step.wholeWord;
    this.isRegex = step.isRegex;
  }

  private clearToIdle() {
    this.cancelSearch();
    this.resetResultBuffer();
    this.hasSearchedOnce = false;
    this.lastExecutedKey = '';
  }

  submitSearch() {
    const plan = this.buildPlan(Date.now());
    if (!plan) return;
    const isRepeat =
      this.hasSearchedOnce && !this.isSearching && plan.keys.exactKey === this.lastExecutedKey;
    this.executeSearch({ forceRefresh: isRepeat, recordInHistory: true });
  }

  commitCurrentPattern(): boolean {
    const step = this.draftStep;
    if (!step) {
      if (this.hasExecutableQuery) {
        this.executeSearch({ forceRefresh: false, recordInHistory: true });
      }
      return false;
    }
    if (!this.steps.some((s) => stepsEqual(s, step))) {
      this.steps = [...this.steps, step];
    }
    this.resetDraft();
    this.executeSearch({ forceRefresh: false, recordInHistory: true });
    return true;
  }

  editStepInSearchBox(idx: number) {
    const next = buildEditedStepState(this.steps, idx, this.draftStep);
    if (!next) return;
    this.steps = next.steps;
    this.pattern = next.pattern;
    this.caseSensitive = next.caseSensitive;
    this.wholeWord = next.wholeWord;
    this.isRegex = next.isRegex;
  }

  removeStep(idx: number) {
    if (idx < 0 || idx >= this.steps.length) return;
    this.steps = this.steps.filter((_, i) => i !== idx);
    if (this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: false, recordInHistory: false });
    } else {
      this.clearToIdle();
    }
  }

  clearDraftInput() {
    this.resetDraft();
    if (this.hasSearchedOnce && this.lastExecutedHadDraft) {
      if (this.hasExecutableQuery) {
        this.executeSearch({ forceRefresh: false, recordInHistory: false });
      } else {
        this.clearToIdle();
      }
    }
  }

  appendSearchTerm(term: string) {
    const next = buildAppendedStepList(this.steps, this.draftStep, term, {
      exclude: false,
      timePreset: this.scope.timePreset,
    });
    if (!next) return;
    this.steps = next;
    this.resetDraft();
    this.executeSearch({ forceRefresh: false, recordInHistory: true });
  }

  excludeSearchTerm(term: string) {
    const next = buildAppendedStepList(this.steps, this.draftStep, term, {
      exclude: true,
      timePreset: this.scope.timePreset,
    });
    if (!next) return;
    this.steps = next;
    this.resetDraft();
    this.executeSearch({ forceRefresh: false, recordInHistory: true });
  }

  replaceSearchWithLiteral(term: string) {
    const clean = term.trim();
    if (!clean) return;
    this.steps = [];
    this.resetDraft();
    this.pattern = clean;
    this.executeSearch({ forceRefresh: false, recordInHistory: true });
  }

  applyHistoryEntry(entry: SearchHistoryEntry) {
    this.steps = entry.steps.map((s) => createQueryStep(s.text, s));
    this.applyDraftStep(entry.draft);
    this.scope = {
      sources: [...entry.scope.sources],
      excludedSources: [...(entry.scope.excludedSources ?? [])],
      types: [],
      timePreset: entry.scope.timePreset,
    };
    this.executeSearch({ forceRefresh: false, recordInHistory: true });
  }

  setScopeSources(sources: readonly string[], excludedSources: readonly string[] = []) {
    const { sources: nextSources, excludedSources: nextExcluded } = normalizeScopeSourceLists(
      sources,
      excludedSources
    );
    if (
      sameSourceList(this.scope.sources, nextSources) &&
      sameSourceList(this.scope.excludedSources ?? [], nextExcluded)
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
    this.selectSingleScopeSource(resolveSourceIdOrName(this.sources, name));
  }

  toggleScopeSource(id: string) {
    const next = toggleMultiSourceSelection(this.scope, id);
    this.setScopeSources(next.sources, next.excludedSources);
  }

  toggleScopeSourceByName(name: string) {
    this.toggleScopeSource(resolveSourceIdOrName(this.sources, name));
  }

  toggleExcludeScopeSource(id: string) {
    const next = toggleExcludeSourceSelection(this.scope, id);
    this.setScopeSources(next.sources, next.excludedSources);
  }

  toggleExcludeScopeSourceByName(name: string) {
    this.toggleExcludeScopeSource(resolveSourceIdOrName(this.sources, name));
  }

  scopeSourceFromMenu(name: string, exclude: boolean) {
    const idOrName = resolveSourceIdOrName(this.sources, name);
    if (exclude) {
      const curEx = this.scope.excludedSources ?? [];
      this.setScopeSources(
        this.scope.sources.filter((x) => x !== idOrName),
        curEx.includes(idOrName) ? curEx : [...curEx, idOrName]
      );
    } else {
      this.setScopeSources([idOrName], []);
    }
  }

  clearScopeSources() {
    this.setScopeSources([], []);
  }

  setScopeTime(preset: TimePreset) {
    this.scope = { ...this.scope, timePreset: preset };
    if (this.hasExecutableQuery && (this.hasSearchedOnce || preset !== '')) {
      this.executeSearch({ forceRefresh: false, recordInHistory: !this.hasSearchedOnce });
    } else if (this.hasSearchedOnce && !this.hasExecutableQuery) {
      this.clearToIdle();
    }
  }

  clearScopeAll() {
    this.scope = { sources: [], excludedSources: [], types: [], timePreset: '' };
    if (this.hasSearchedOnce && this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: false, recordInHistory: false });
    } else if (!this.hasExecutableQuery) {
      this.clearToIdle();
    }
  }

  resetAllFilters() {
    const firstPos = this.compiledQuery.activeSteps.find((s) => !s.exclude);
    this.steps = [];
    this.resetDraft();
    this.pattern = firstPos ? firstPos.text : '';
    this.isRegex = Boolean(firstPos?.isRegex);
    this.scope = { sources: [], excludedSources: [], types: [], timePreset: '' };
    if (this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: false, recordInHistory: false });
    } else {
      this.clearToIdle();
    }
  }

  applyResultFix(fix: ResultFix) {
    if (fix.steps !== undefined) {
      this.steps = fix.steps.map((s) => createQueryStep(s.text, s));
    }
    if (fix.draft !== undefined) {
      this.applyDraftStep(fix.draft);
    }
    if (fix.scopePatch) {
      this.scope = { ...this.scope, ...fix.scopePatch };
    }
    if (this.hasExecutableQuery) {
      this.executeSearch({ forceRefresh: false, recordInHistory: false });
    }
  }

  // Search Execution, L0 Cache & 120Hz Stream Flusher
  connectWebSocket() {
    this.wsTransport.connect();
  }

  cancelSearch() {
    if (this.isSearching) {
      this.flushPendingHitsSync();
      this.awaitingFirstChunk = false;
      this.cancelledSearchId = this.currentSearchId;
      this.inflightCacheKeys.delete(this.currentSearchId);
      this.wsTransport.sendCancel(this.currentSearchId);
    }
    this.isSearching = false;
  }

  clearSearch() {
    this.cancelSearch();
    this.steps = [];
    this.resetDraft();
    this.lastExecutedKey = '';
    this.lastExecutedHadDraft = false;
    this.lastExecutedSnapshot = null;
    this.pendingReplayTarget = null;
    this.pendingReplayTimeRange = undefined;
    this.clearShareUrlParamIfPresent();
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
    this.filesPruned = 0;
    this.bytesSaved = 0;
    this.elapsedMs = 0;
    this.limitHit = false;
    this.cacheHit = 'none';
    this.displayedTimeStartMs = 0;
  }

  getEffectiveTimeBasisSummary(): { contentCount: number; mtimeCount: number } {
    return computeTimeBasisSummary(computeActiveSources(this.sources, this.scope));
  }

  private buildPlan(nowMs: number, replayTimeRange?: { startMs: number; endMs: number }) {
    return buildSearchRequestPlan({
      steps: this.steps,
      draftStep: this.draftStep,
      scope: this.scope,
      sources: this.sources,
      tenant: this.tenant,
      mode: this.mode,
      hidden: this.hidden,
      respectIgnore: this.respectIgnore,
      maxResults: this.maxResults,
      replayTimeRange,
      nowMs,
    });
  }

  private putL0Entry(meta: InflightCacheMeta) {
    this.l0Store.put(meta, {
      fileGroups: this.fileGroups,
      flatHits: this.flatHits,
      filesSearched: this.filesSearched,
      filesMatched: this.filesMatched,
      totalMatches: this.totalMatches,
      matchedLines: this.matchedLines,
      bytesSearched: this.bytesSearched,
      filesPruned: this.filesPruned,
      bytesSaved: this.bytesSaved,
      limitHit: this.limitHit,
    });
  }

  private selectPostSearchHit() {
    if (this.pendingReplayTarget) {
      const target = this.pendingReplayTarget;
      this.pendingReplayTarget = null;
      const matchedIdx = this.flatHits.findIndex(
        (h) => h.file === target.path && h.line === target.line
      );
      if (matchedIdx >= 0) {
        this.selectHitByIndex(matchedIdx, false);
        this.scrollToActiveTick += 1;
        return;
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
    this.filesPruned = entry.filesPruned;
    this.bytesSaved = entry.bytesSaved;
    this.elapsedMs = 0.05;
    this.limitHit = entry.limitHit;
    this.cacheHit = 'l0-instant';
    this.lastExecutedKey = entry.exactKey;
    this.lastExecutedHadDraft = hadDraft;
    this.displayedTimeStartMs = entry.timeStartMs;
    this.selectPostSearchHit();
  }

  executeSearch(opts: ExecuteSearchOptions = {}) {
    if (!opts.keepShareUrl) {
      this.clearShareUrlParamIfPresent();
      this.pendingReplayTarget = null;
      this.pendingReplayTimeRange = undefined;
    }

    const nowMs = Date.now();
    const plan = this.buildPlan(nowMs, opts.replayTimeRange);
    if (!plan) {
      this.cancelSearch();
      this.resetResultBuffer();
      this.hasSearchedOnce = false;
      this.lastExecutedSnapshot = null;
      this.errorMessage = null;
      return;
    }

    this.lastExecutedSnapshot = plan.snapshot;
    if (opts.recordInHistory) {
      this.recordHistory(plan.keys.historyId);
    }

    if (!opts.forceRefresh && !opts.replayTimeRange) {
      const l0Hit = this.l0Store.findValid(
        plan.keys.exactKey,
        plan.keys.baseKey,
        this.maxResults,
        nowMs
      );
      if (l0Hit) {
        this.cancelSearch();
        this.currentSearchId += 1;
        this.restoreFromL0Entry(l0Hit, this.draftStep !== null);
        return;
      }
    }

    if (!this.wsTransport.isOpen()) {
      this.pendingSearchOnOpen = true;
      this.pendingReplayTimeRange = opts.replayTimeRange;
      this.connectWebSocket();
      return;
    }

    this.currentSearchId += 1;
    const searchId = this.currentSearchId;
    this.inflightCacheKeys.set(searchId, {
      exactKey: plan.keys.exactKey,
      baseKey: plan.keys.baseKey,
      sourceRevision: this.sourceRevision,
      hadDraft: this.draftStep !== null,
      maxResults: this.maxResults,
      timeStartMs: plan.timeStartMs,
    });
    if (this.inflightCacheKeys.size > 32) {
      const oldestKey = this.inflightCacheKeys.keys().next().value;
      if (oldestKey !== undefined) {
        this.inflightCacheKeys.delete(oldestKey);
      }
    }

    // Stale-While-Revalidate: keep existing results on screen until the first batch or done arrives
    this.clearFlushSchedule();
    this.pendingChunks = [];
    this.awaitingFirstChunk = true;
    this.errorMessage = null;
    this.isSearching = true;
    this.hasSearchedOnce = true;

    this.wsTransport.sendSearch(plan.buildWsPayload(searchId));
  }

  async previewTimeFormat(format: string, sample: string): Promise<TimePreviewResponse> {
    return postTimePreview(this.apiFetcher, format, sample);
  }

  private handleWsMessage(msg: WsIncomingMessage) {
    if (msg.id !== this.currentSearchId || msg.id === this.cancelledSearchId) {
      if (msg.type === 'done' || msg.type === 'error') {
        this.inflightCacheKeys.delete(msg.id);
      }
      return;
    }

    if (msg.type === 'hits') {
      if (Array.isArray(msg.items) && msg.items.length > 0) {
        this.pendingChunks.push(msg.items);
        this.scheduleFlushHits(
          this.awaitingFirstChunk
            ? this.frameProfile.firstFlushLeadMs
            : this.frameProfile.steadyFlushLeadMs
        );
      }
    } else if (msg.type === 'progress') {
      if (!this.awaitingFirstChunk) {
        this.filesSearched = msg.filesSearched ?? this.filesSearched;
        this.filesMatched = msg.filesMatched ?? this.filesMatched;
        this.totalMatches = msg.matches ?? this.totalMatches;
        this.bytesSearched = msg.bytesSearched ?? this.bytesSearched;
      }
    } else if (msg.type === 'done') {
      const meta = this.inflightCacheKeys.get(msg.id);
      this.inflightCacheKeys.delete(msg.id);
      if (this.awaitingFirstChunk && this.pendingChunks.length === 0) {
        this.resetResultBuffer();
      } else {
        this.flushPendingHitsSync();
      }

      const done = normalizeDoneTelemetry(msg, this.flatHits.length);
      this.isSearching = false;
      this.elapsedMs = done.elapsedMs;
      this.filesSearched = done.filesSearched ?? this.filesSearched;
      this.filesMatched = done.filesMatched ?? this.filesMatched;
      this.totalMatches = done.totalMatches ?? this.totalMatches;
      this.matchedLines = done.matchedLines;
      this.bytesSearched = done.bytesSearched ?? this.bytesSearched;
      this.filesPruned = done.filesPruned;
      this.bytesSaved = done.bytesSaved;
      this.limitHit = done.limitHit;
      this.cacheHit = done.cacheHit;
      if (done.searchCount !== null) {
        this.searchCount = done.searchCount;
      }

      if (meta) {
        this.lastExecutedKey = meta.exactKey;
        this.lastExecutedHadDraft = meta.hadDraft;
        this.displayedTimeStartMs = meta.timeStartMs;
        if (meta.sourceRevision === this.sourceRevision) {
          this.putL0Entry(meta);
        }
      }
      this.selectPostSearchHit();
    } else if (msg.type === 'error') {
      this.inflightCacheKeys.delete(msg.id);
      if (this.awaitingFirstChunk && this.pendingChunks.length === 0) {
        this.resetResultBuffer();
      } else {
        this.flushPendingHitsSync();
      }
      this.isSearching = false;
      this.errorMessage = msg.message || 'Search error';
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
      this.displayedTimeStartMs =
        this.inflightCacheKeys.get(this.currentSearchId)?.timeStartMs ?? 0;
      this.clearInspectorSchedule();
      this.groupIndexByFile.clear();
      this.fileGroups = [];
      this.flatHits = [];
      this.activeHitIndex = -1;
      this.inspectedHit = null;
      this.filesMatched = 0;
      this.totalMatches = 0;
      this.matchedLines = 0;
      this.filesPruned = 0;
      this.bytesSaved = 0;
    }

    const merged = mergeHitChunks(
      this.fileGroups,
      this.flatHits,
      this.groupIndexByFile,
      chunks
    );
    this.fileGroups = merged.fileGroups;
    this.flatHits = merged.flatHits;
    this.filesMatched = Math.max(this.filesMatched, merged.fileGroups.length);
    this.matchedLines = Math.max(this.matchedLines, merged.flatHits.length);
    this.totalMatches = Math.max(this.totalMatches, this.totalMatches + merged.addedMatches);
  }

  // Group Collapse, Hit Selection, Inspector & Context Drawer
  toggleFileGroupCollapse(filePath: string) {
    const idx = this.groupIndexByFile.get(filePath);
    if (idx === undefined) return;
    const next = toggleGroupCollapseAt(this.fileGroups, idx);
    if (next !== this.fileGroups) {
      this.fileGroups = next;
    }
  }

  setAllGroupsCollapsed(collapsed: boolean) {
    this.fileGroups = collapseAllGroups(this.fileGroups, collapsed);
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

  previewSelectHitByIndex(index: number) {
    if (index >= 0 && index < this.flatHits.length) {
      this.activeHitIndex = index;
    }
  }

  private commitInspectedHit(hit: HitItem, forceOpenInspector: boolean) {
    this.inspectedHit = hit;
    this.inspectedPath = hit.file;
    this.inspectedLine = hit.line;
    this.inspectorError = null;
    const ctxLines = this.activeInspectContextLines;
    if (ctxLines === 0 && !isPossiblyTruncatedHitText(hit.text)) {
      this.inspectAbort?.abort();
      this.inspectAbort = null;
      this.inspectSeq += 1;
      this.inspectedFile = null;
      this.inspectorLoading = false;
      return;
    }
    void this.inspectFileAtLine(hit.file, hit.line, forceOpenInspector, hit.byteOffset, ctxLines);
  }

  selectHitByIndex(index: number, forceOpenInspector = false, deferInspector = false) {
    if (index < 0 || index >= this.flatHits.length) return;
    this.activeHitIndex = index;
    const hit = this.flatHits[index];
    if (!hit) return;

    const gIdx = this.groupIndexByFile.get(hit.file);
    if (gIdx !== undefined && this.fileGroups[gIdx]?.collapsed) {
      this.fileGroups = toggleGroupCollapseAt(this.fileGroups, gIdx);
    }
    if (forceOpenInspector) {
      this.detailOpen = true;
      if (!this.rightInspectorOpen) {
        this.rightInspectorOpen = true;
      }
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
    const next = Math.max(0, Math.min(this.flatHits.length - 1, this.activeHitIndex + delta));
    this.selectHitByIndex(next, false, rapid);
    this.scrollToActiveTick += 1;
  }

  toggleInspectorPane() {
    if (!this.rightInspectorOpen) {
      this.rightInspectorOpen = true;
      if (!this.inspectedPath && this.flatHits.length > 0) {
        this.selectHitByIndex(this.activeHitIndex >= 0 ? this.activeHitIndex : 0, true);
      }
    } else {
      this.rightInspectorOpen = false;
    }
  }

  private abortContextFetch() {
    this.contextAbort?.abort();
    this.contextAbort = null;
    this.contextSeq += 1;
    this.contextLoadingInitial = false;
    this.contextLoadingBefore = false;
    this.contextLoadingAfter = false;
  }

  private fetchFileWindow(
    filePath: string,
    opts: {
      line: number;
      context: number;
      startLine?: number;
      endLine?: number;
      anchorLine?: number;
      anchorByte?: number | null;
    },
    signal: AbortSignal
  ): Promise<FileResponse> {
    return requestFileWindow(this.apiFetcher, {
      tenant: this.tenant,
      filePath,
      ...opts,
      signal,
    });
  }

  async openContextDrawer(filePath?: string, line?: number, anchorByteHint?: number | null) {
    const targetPath = filePath ?? this.inspectedPath;
    if (!targetPath) return;
    const anchor = Math.max(1, line ?? (this.inspectedHit?.line ?? this.inspectedLine));

    this.paletteOpen = false;
    this.mobileScopeOpen = false;
    this.sourceAddOpen = false;
    this.drawerPanel = 'context';

    this.abortContextFetch();
    const controller = new AbortController();
    this.contextAbort = controller;
    const seq = this.contextSeq;

    this.contextPath = targetPath;
    this.contextAnchorLine = anchor;
    this.contextLines = [];
    this.contextTotalLines = 0;
    this.contextEof = false;
    this.contextBinary = false;
    this.contextError = null;
    this.contextFirstByte = null;
    this.contextNextByte = null;
    this.contextLoadingInitial = true;

    const resolvedByte = resolveAnchorByteHint(
      anchorByteHint,
      this.inspectedHit,
      targetPath,
      anchor
    );
    try {
      const win = computeInitialFetchWindow(anchor, this.contextInitialLines);
      const data = await this.fetchFileWindow(
        targetPath,
        {
          line: win.line,
          context: win.context,
          startLine: win.targetStart,
          endLine: win.targetEnd,
          anchorLine: resolvedByte !== undefined ? anchor : undefined,
          anchorByte: resolvedByte,
        },
        controller.signal
      );
      if (seq !== this.contextSeq) return;
      const bounds = computeMergedContextBounds(data.lines, data.totalLines, data.eof);
      this.contextLines = data.lines;
      this.contextTotalLines = bounds.totalLines;
      this.contextEof = bounds.eof;
      this.contextBinary = data.binary;
      this.contextFirstByte = typeof data.firstByte === 'number' ? data.firstByte : null;
      this.contextNextByte = typeof data.nextByte === 'number' ? data.nextByte : null;
      this.contextCenterTick += 1;
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') return;
      if (seq === this.contextSeq) {
        this.contextError = err instanceof Error ? err.message : 'Failed to load context';
      }
    } finally {
      if (seq === this.contextSeq) {
        this.contextLoadingInitial = false;
      }
    }
  }

  async loadContextMore(
    direction: 'before' | 'after',
    captureScrollAnchor?: () => (() => void) | undefined
  ) {
    const targetPath = this.contextPath;
    if (
      !targetPath ||
      this.contextBinary ||
      this.contextLoadingInitial ||
      this.contextLoadingBefore ||
      this.contextLoadingAfter
    ) {
      return;
    }

    const firstLine = this.contextLines.length > 0 ? this.contextLines[0].n : this.contextAnchorLine;
    const lastLine =
      this.contextLines.length > 0
        ? this.contextLines[this.contextLines.length - 1].n
        : this.contextAnchorLine;
    const win =
      direction === 'before'
        ? computeUpwardFetchWindow(firstLine, this.contextStepLines)
        : computeDownwardFetchWindow(
            lastLine,
            this.contextTotalLines,
            this.contextEof,
            this.contextStepLines
          );
    if (!win) return;

    const controller = new AbortController();
    this.contextAbort = controller;
    const seq = ++this.contextSeq;
    this.contextError = null;
    if (direction === 'before') {
      this.contextLoadingBefore = true;
    } else {
      this.contextLoadingAfter = true;
    }

    const reqAnchorLine = direction === 'before' ? firstLine : lastLine + 1;
    const reqAnchorByte =
      direction === 'before' ? this.contextFirstByte : this.contextNextByte;
    try {
      const data = await this.fetchFileWindow(
        targetPath,
        {
          line: win.line,
          context: win.context,
          startLine: win.targetStart,
          endLine: win.targetEnd,
          anchorLine: reqAnchorByte !== null ? reqAnchorLine : undefined,
          anchorByte: reqAnchorByte,
        },
        controller.signal
      );
      if (seq !== this.contextSeq) return;

      const merged = mergeContextBatchResult(
        this.contextLines,
        this.contextTotalLines,
        this.contextEof,
        data,
        win,
        direction
      );
      if (merged.firstByte !== undefined) {
        this.contextFirstByte = merged.firstByte;
      }
      if (merged.nextByte !== undefined) {
        this.contextNextByte = merged.nextByte;
      }
      const restoreScroll = direction === 'before' ? captureScrollAnchor?.() : undefined;
      flushSync(() => {
        this.contextLines = merged.lines;
        this.contextTotalLines = merged.totalLines;
        this.contextEof = merged.eof;
      });
      restoreScroll?.();
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') return;
      if (seq === this.contextSeq) {
        this.contextError = err instanceof Error ? err.message : 'Failed to load more context';
      }
    } finally {
      if (seq === this.contextSeq) {
        this.contextLoadingBefore = false;
        this.contextLoadingAfter = false;
      }
    }
  }

  async inspectFileAtLine(
    filePath: string,
    line = 1,
    forceOpen = true,
    anchorByteHint?: number | null,
    contextLines?: number
  ) {
    const targetLine = Math.max(1, line);
    const ctx = Math.max(0, Math.floor(contextLines ?? this.activeInspectContextLines));
    if (
      this.inspectedHit &&
      (this.inspectedHit.file !== filePath || this.inspectedHit.line !== targetLine)
    ) {
      this.inspectedHit = null;
    }

    const cacheKey = buildFileContextCacheKey(this.tenant, filePath, targetLine, ctx);

    if (forceOpen) {
      this.detailOpen = true;
      if (!this.rightInspectorOpen) {
        this.rightInspectorOpen = true;
      }
    }

    const cached = this.fileContextCache.get(cacheKey, targetLine, this.sourceRevision);
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
      const hitByte = resolveAnchorByteHint(
        anchorByteHint,
        this.inspectedHit,
        filePath,
        targetLine
      );
      const win = ctx > 0 ? computeInitialFetchWindow(targetLine, ctx) : null;
      const data = await this.fetchFileWindow(
        filePath,
        win
          ? {
              line: win.line,
              context: win.context,
              startLine: win.targetStart,
              endLine: win.targetEnd,
              anchorLine: hitByte !== undefined ? targetLine : undefined,
              anchorByte: hitByte,
            }
          : hitByte !== undefined
            ? {
                line: targetLine,
                context: 0,
                startLine: targetLine,
                endLine: targetLine,
                anchorLine: targetLine,
                anchorByte: hitByte,
              }
            : { line: targetLine, context: 0 },
        controller.signal
      );
      if (seq !== this.inspectSeq) return;
      if (reqRevision === this.sourceRevision) {
        this.fileContextCache.put(cacheKey, data, this.sourceRevision);
      }
      this.inspectedFile = data;
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') return;
      if (seq === this.inspectSeq) {
        this.inspectorError = err instanceof Error ? err.message : 'Failed to load file context';
      }
    } finally {
      if (seq === this.inspectSeq) {
        this.inspectorLoading = false;
      }
    }
  }
}

export const workbench = new WorkbenchState();
