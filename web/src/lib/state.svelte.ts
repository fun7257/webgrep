import type {
  CaseMode,
  DataSourceItem,
  DirSuggestEntry,
  DirSuggestResponse,
  FileHitGroup,
  FileResponse,
  HitItem,
  MetaResponse,
  SearchHistoryEntry,
  SearchMode,
  SearchPreset,
  SourceConfig,
  SourceKind,
  SourcesResponse,
  WsIncomingMessage,
  WsSearchMessage,
} from './types';
import { KNOWN_FILE_TYPES } from './utils';
import { messages, type Locale } from './i18n';

const HISTORY_STORAGE_KEY = 'webgrep.searchHistory.v1';
const THEME_STORAGE_KEY = 'webgrep.theme.v1';
const SETTINGS_STORAGE_KEY = 'webgrep.settings.v2';

export interface ParsedDollarFlags {
  regex: boolean;
  caseSensitive: boolean;
  wholeWord: boolean;
}

export function parseDollarFlags(raw: string): ParsedDollarFlags | null {
  if (!raw.startsWith('$') || raw.length < 2) return null;
  const body = raw.slice(1).toLowerCase();

  if (body === 'r' || body === 're' || body === 'regex' || body === '.*') {
    return { regex: true, caseSensitive: false, wholeWord: false };
  }
  if (body === 'c' || body === 'case' || body === 'aa' || body === 's') {
    return { regex: false, caseSensitive: true, wholeWord: false };
  }
  if (body === 'w' || body === 'word' || body === 'b' || body === '\\b') {
    return { regex: false, caseSensitive: false, wholeWord: true };
  }
  // Support combined shorthand flags such as $rc, $rw, $cw, $rcw (in any order)
  if (body.length >= 2 && body.length <= 3 && /^[rcw]+$/.test(body)) {
    return {
      regex: body.includes('r'),
      caseSensitive: body.includes('c'),
      wholeWord: body.includes('w'),
    };
  }

  return null;
}

export const BUILTIN_PRESETS: SearchPreset[] = [
  {
    id: 'simd-multi',
    label: 'Multi OR · SIMD Engines',
    description: 'Search multiple patterns simultaneously via Teddy / Aho-Corasick',
    pattern: 'Finder|Multi|Regex',
    mode: 'multi',
    caseMode: 'sensitive',
  },
  {
    id: 'chained-and-not',
    label: 'Chained AND + NOT',
    description: 'Find pub fn declarations containing Search without test lines',
    pattern: 'pub fn',
    mode: 'literal',
    caseMode: 'sensitive',
    contains: ['Search'],
    excludes: ['test'],
  },
  {
    id: 'replace-preview',
    label: 'Live Replace Preview',
    description: 'Preview non-destructive inline replacement across matches',
    pattern: 'SearchConfig',
    mode: 'literal',
    caseMode: 'sensitive',
    replacement: 'QueryOptions',
  },
  {
    id: 'regex-fn',
    label: 'Regex · Function Signatures',
    description: 'Linear-time Thompson NFA regex with SIMD prefilter',
    pattern: 'pub\\s+fn\\s+[a-zA-Z0-9_]+',
    mode: 'regex',
    caseMode: 'sensitive',
  },
];

class WorkbenchState {
  // Workspace metadata
  meta = $state<MetaResponse>({
    rootLabel: 'webgrep',
    root: '.',
    engine: 'libwebgrep 0.1.0 · SIMD',
    types: KNOWN_FILE_TYPES.map((t) => t.id),
  });

  // WebSocket status
  wsStatus = $state<'connecting' | 'connected' | 'reconnecting' | 'offline'>('connecting');
  private ws: WebSocket | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectAttempt = 0;

  // Search parameters
  pattern = $state<string>('');
  private _baseMode = $state<SearchMode>('literal');
  private _baseCaseMode = $state<CaseMode>('insensitive');
  private _baseWholeWord = $state<boolean>(false);
  wholeLine = $state<boolean>(false);
  invert = $state<boolean>(false);

  // Instant-effect line filters
  containsInput = $state<string>('');
  excludesInput = $state<string>('');
  replacement = $state<string>('');
  contextLines = $state<number>(0);
  filtersExpanded = $state<boolean>(false);

  // Scope & file filters
  selectedTypes = $state<string[]>([]);
  globsInput = $state<string>('');
  selectedPaths = $state<string[]>([]);
  hidden = $state<boolean>(false);
  respectIgnore = $state<boolean>(false);
  maxResults = $state<number>(20000);

  // Execution mode
  liveSearch = $state<boolean>(true);
  debounceMs = $state<number>(150);
  private debounceTimer: ReturnType<typeof setTimeout> | null = null;
  currentSearchId = $state<number>(0);
  searchCount = $state<number>(0);
  isSearching = $state<boolean>(false);
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
  private activeQueryCacheKey = '';
  private l0Cache = new Map<
    string,
    {
      fileGroups: FileHitGroup[];
      flatHits: HitItem[];
      filesSearched: number;
      filesMatched: number;
      totalMatches: number;
      matchedLines: number;
      bytesSearched: number;
      limitHit: boolean;
    }
  >();

  // Data Sources (Project Source Registry with UUID)
  tenant = $state<string>('default');
  sources = $state.raw<DataSourceItem[]>([]);
  selectedSources = $state<string[]>([]);
  sourcesLoading = $state<boolean>(false);
  sourceManagerOpen = $state<boolean>(false);
  addSourceModalOpen = $state<boolean>(false);
  settingsTab = $state<'general' | 'sources' | 'add-source' | 'shortcuts'>('general');

  openSettings(tab: 'general' | 'sources' | 'add-source' | 'shortcuts' = 'general') {
    this.settingsTab = tab;
    this.settingsOpen = true;
  }

  openSourceManager() {
    this.openSettings('sources');
  }

  openAddSourceModal() {
    this.openSettings('add-source');
  }

  enabledSourceCount = $derived<number>(
    this.sources.reduce((acc, s) => acc + (s.enabled ? 1 : 0), 0)
  );

  sourceByName = $derived.by(() => {
    const map = new Map<string, DataSourceItem>();
    for (const s of this.sources) {
      map.set(s.name.toLowerCase(), s);
    }
    return map;
  });

  // Active hit & Right Inspector
  activeHitIndex = $state<number>(-1);
  scrollToActiveTick = $state<number>(0);
  inspectedPath = $state<string | null>(null);
  inspectedLine = $state<number>(1);
  inspectorContext = $state<number>(0);
  inspectedFile = $state<FileResponse | null>(null);
  inspectorLoading = $state<boolean>(false);
  inspectorError = $state<string | null>(null);
  inspectorTab = $state<'structured' | 'raw'>('structured');

  // UI Layout, Theme & Real-Time Settings
  locale = $state<Locale>('zh');
  darkMode = $state<boolean>(true);
  leftSidebarOpen = $state<boolean>(true);
  rightInspectorOpen = $state<boolean>(true);
  leftSidebarWidth = $state<number>(260);
  rightInspectorWidth = $state<number>(520);
  settingsOpen = $state<boolean>(false);
  paletteOpen = $state<boolean>(false);
  /** Compact (mobile) layout: full-screen detail view is shown only after an explicit open. */
  detailOpen = $state<boolean>(false);
  /** True when viewport < 768px: stacked list/detail navigation, bottom sheets, symbol bar. */
  isCompact = $state<boolean>(false);
  codeFontSize = $state<number>(13.5);
  wordWrap = $state<boolean>(true);
  resultDensity = $state<'compact' | 'comfortable'>('comfortable');
  searchHistory = $state<SearchHistoryEntry[]>([]);

  // Derived properties
  t = $derived(messages[this.locale]);

  activeHit = $derived<HitItem | null>(
    this.activeHitIndex >= 0 && this.activeHitIndex < this.flatHits.length
      ? this.flatHits[this.activeHitIndex]
      : null
  );

  parsedQuery = $derived.by(() => {
    const raw = this.pattern;
    interface RawToken {
      raw: string;
      quoted: boolean;
    }
    const rawTokens: RawToken[] = [];
    let i = 0;
    const n = raw.length;

    while (i < n) {
      while (i < n && /\s/.test(raw[i])) i++;
      if (i >= n) break;
      const start = i;
      const firstCh = raw[i];
      const quoted = firstCh === '"' || firstCh === "'";

      // Check for scoped `$r(xxxxxxx)`, `$c(xxxxxxx)`, `$w(xxxxxxx)`, `$rc(...)`, `$cw(...)`, `$rw(...)`, `$rcw(...)` with balanced parentheses
      const scopedMatch = /^([-+!]?)(\$[a-zA-Z.*]+)\(/.exec(raw.slice(i));
      if (scopedMatch) {
        const dFlags = parseDollarFlags(scopedMatch[2]);
        if (dFlags) {
          const openParenPos = i + scopedMatch[0].length - 1;
          let depth = 1;
          let p = openParenPos + 1;
          let inCharClass = false;
          let classStart = -1;
          while (p < n && depth > 0) {
            const c = raw[p];
            if (c === '\\' && p + 1 < n) {
              p += 2;
              continue;
            }
            if (inCharClass) {
              if (
                c === ']' &&
                p > classStart + 1 &&
                !(p === classStart + 2 && (raw[classStart + 1] === '^' || raw[classStart + 1] === '!'))
              ) {
                inCharClass = false;
              }
              p++;
              continue;
            }
            if (c === '[') {
              inCharClass = true;
              classStart = p;
            } else if (c === '(') {
              depth++;
            } else if (c === ')') {
              depth--;
            }
            p++;
          }
          i = p;
          rawTokens.push({ raw: raw.slice(start, i), quoted: false });
          continue;
        }
      }

      let inQuote: string | null = null;
      let inBracket = false;
      let bracketStart = -1;
      let parenDepth = 0;

      // Pre-check if any '[' or '(' from `start` has a matching closing delimiter before end of string
      const hasClosingFrom = (openPos: number, openCh: string, closeCh: string): boolean => {
        let depth = 0;
        for (let p = openPos; p < n; p++) {
          const c = raw[p];
          if (c === '\\' && p + 1 < n) {
            p++;
            continue;
          }
          if (c === openCh) depth++;
          else if (c === closeCh) {
            depth--;
            if (depth <= 0) return true;
          }
        }
        return false;
      };

      while (i < n) {
        const ch = raw[i];
        if (inQuote) {
          if (ch === '\\' && i + 1 < n) {
            i += 2;
            continue;
          }
          if (ch === inQuote) {
            inQuote = null;
          }
          i++;
        } else if (inBracket) {
          if (ch === '\\' && i + 1 < n) {
            i += 2;
            continue;
          }
          // In regex `[...]`, a `]` immediately after `[` or `[^` is a literal `]`, not closing the class
          if (
            ch === ']' &&
            i > bracketStart + 1 &&
            !(i === bracketStart + 2 && (raw[bracketStart + 1] === '^' || raw[bracketStart + 1] === '!'))
          ) {
            inBracket = false;
          }
          i++;
        } else {
          // Escaped whitespace (`\ `) stays inside the current token
          if (ch === '\\' && i + 1 < n && /\s/.test(raw[i + 1])) {
            i += 2;
            continue;
          }
          if (ch === '"' || ch === "'") {
            inQuote = ch;
            i++;
          } else if (ch === '[' && hasClosingFrom(i, '[', ']')) {
            inBracket = true;
            bracketStart = i;
            i++;
          } else if (ch === '(' && hasClosingFrom(i, '(', ')')) {
            parenDepth++;
            i++;
          } else if (ch === ')' && parenDepth > 0) {
            parenDepth--;
            i++;
          } else if (/\s/.test(ch) && parenDepth === 0) {
            break;
          } else {
            i++;
          }
        }
      }
      rawTokens.push({ raw: raw.slice(start, i), quoted });
    }

    const stripQuotes = (s: string): string => {
      if (
        s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'")))
      ) {
        return s.slice(1, -1);
      }
      return s;
    };

    const normalizeGlobItem = (body: string, negate: boolean): string => {
      const clean = body.trim();
      if (!clean) return '';
      const neg = negate || clean.startsWith('!') ? '!' : '';
      const core = clean.startsWith('!') ? clean.slice(1) : clean;
      if (!core) return '';
      return `${neg}${core}`;
    };

    const splitGlobList = (val: string): string[] => {
      const items: string[] = [];
      let cur = '';
      let braceDepth = 0;
      for (let j = 0; j < val.length; j++) {
        const ch = val[j];
        if (ch === '{') braceDepth++;
        else if (ch === '}' && braceDepth > 0) braceDepth--;
        if (braceDepth === 0 && ch === ',') {
          if (cur.trim()) items.push(cur.trim());
          cur = '';
        } else {
          cur += ch;
        }
      }
      if (cur.trim()) items.push(cur.trim());
      return items;
    };

    interface ClassifiedToken {
      raw: string;
      kind: 'primary' | 'include' | 'exclude' | 'file' | 'exclude-file' | 'flag';
      value: string;
      forceLiteral?: boolean;
    }

    const parseScopedDollarToken = (
      s: string
    ): { prefix: string; flags: ParsedDollarFlags; inner: string } | null => {
      const m =
        /^([-+!]?)(\$[a-zA-Z.*]+)\(([\s\S]*)\)$/.exec(s) ??
        /^([-+!]?)(\$[a-zA-Z.*]+)\(([\s\S]*)$/.exec(s);
      if (!m) return null;
      const df = parseDollarFlags(m[2]);
      if (!df) return null;
      return {
        prefix: m[1],
        flags: df,
        inner: m[3],
      };
    };

    // Pass 1: Detect scoped `$r(...)`, `$c(...)`, `$w(...)`, `$rc(...)`, `$rw(...)`, `$cw(...)`, `$rcw(...)`
    let flagRegex = false;
    let hasScopedRegex = false;
    let flagCase = false;
    let flagWord = false;
    for (const tok of rawTokens) {
      if (tok.quoted) continue;
      const scoped = parseScopedDollarToken(tok.raw);
      if (scoped) {
        if (scoped.inner.length > 0 && scoped.flags.regex) {
          hasScopedRegex = true;
        }
        continue;
      }
    }

    const isRegexMode = flagRegex || this._baseMode === 'regex';

    const normalizeUnquotedValue = (s: string): string => {
      if (isRegexMode) return s;
      // In literal mode, unescape leading `\-`, `\+`, `\@`, `\$` and inline escaped spaces `\ `
      let out = s.replace(/\\(\s)/g, '$1');
      if (/^\\[-+@$]/.test(out)) {
        out = out.slice(1);
      }
      return out;
    };

    const classified: ClassifiedToken[] = [];

    for (const tok of rawTokens) {
      if (tok.quoted) {
        const inner = stripQuotes(tok.raw);
        const hasDoubledQuotes =
          (tok.raw.startsWith('""') && tok.raw.endsWith('""')) ||
          (tok.raw.startsWith("''") && tok.raw.endsWith("''"));
        // Single quotes `"..."` group spaces or escape special prefixes (`"-v"`), while doubled quotes `""...""` search literal quotes
        const v = hasDoubledQuotes ? inner : inner || tok.raw;
        if (v) {
          classified.push({
            raw: tok.raw,
            kind: 'primary',
            value: v,
            forceLiteral: hasDoubledQuotes,
          });
        }
        continue;
      }

      // Scoped `$r(...)`, `$c(...)`, `$w(...)`, `$rc(...)`, `$rw(...)`, `$cw(...)`, `$rcw(...)`
      const scoped = parseScopedDollarToken(tok.raw);
      if (scoped) {
        if (!scoped.inner) {
          // Ignore empty `$r()`, `$c()`, `$w()` while user is typing inside parentheses
          continue;
        }
        const flagCode =
          `${scoped.flags.regex ? 'r' : ''}${scoped.flags.caseSensitive ? 'c' : ''}${scoped.flags.wholeWord ? 'w' : ''}` ||
          'r';
        const canonicalScoped = `$${flagCode}(${scoped.inner})`;
        if (scoped.prefix === '-' || scoped.prefix === '!') {
          classified.push({ raw: tok.raw, kind: 'exclude', value: canonicalScoped });
        } else if (scoped.prefix === '+') {
          classified.push({ raw: tok.raw, kind: 'include', value: canonicalScoped });
        } else {
          classified.push({ raw: tok.raw, kind: 'primary', value: canonicalScoped });
        }
        continue;
      }

      // Ignore bare '$' or incomplete '$r' / '$c' / '$w' while the user is choosing from the $ autocomplete dropdown
      if (
        /^[-+!]?\$$/.test(tok.raw) ||
        (tok.raw.startsWith('$') && parseDollarFlags(tok.raw) !== null) ||
        ((tok.raw.startsWith('-$') || tok.raw.startsWith('+$') || tok.raw.startsWith('!$')) &&
          parseDollarFlags(tok.raw.slice(1)) !== null)
      ) {
        continue;
      }

      // Primary @scope syntax (plus backward-compatible f: / f： syntax)
      const atMatch = /^@(.+)$/.exec(tok.raw);
      if (atMatch) {
        const v = stripQuotes(atMatch[1]);
        if (v) classified.push({ raw: tok.raw, kind: 'file', value: v });
        continue;
      }

      const negAtMatch = /^[-!]@(.+)$/.exec(tok.raw);
      if (negAtMatch) {
        const v = stripQuotes(negAtMatch[1]);
        if (v) classified.push({ raw: tok.raw, kind: 'exclude-file', value: v });
        continue;
      }

      const fileMatch = /^(?:f|file)[:：](.*)$/i.exec(tok.raw);
      if (fileMatch) {
        const v = stripQuotes(fileMatch[1]);
        if (v) classified.push({ raw: tok.raw, kind: 'file', value: v });
        continue;
      }

      const negFileMatch = /^(?:[-!]f|[-!]file)[:：](.*)$/i.exec(tok.raw);
      if (negFileMatch) {
        const v = stripQuotes(negFileMatch[1]);
        if (v) classified.push({ raw: tok.raw, kind: 'exclude-file', value: v });
        continue;
      }

      // Ignore bare '@' while the user is choosing from the autocomplete dropdown
      if (tok.raw === '@' || tok.raw === '-@' || tok.raw === '!@') {
        continue;
      }

      if (tok.raw.startsWith('+')) {
        const v = normalizeUnquotedValue(stripQuotes(tok.raw.slice(1)));
        if (v) classified.push({ raw: tok.raw, kind: 'include', value: v });
        continue;
      }

      if (tok.raw.startsWith('-')) {
        const v = normalizeUnquotedValue(stripQuotes(tok.raw.slice(1)));
        if (v) classified.push({ raw: tok.raw, kind: 'exclude', value: v });
        continue;
      }

      classified.push({
        raw: tok.raw,
        kind: 'primary',
        value: normalizeUnquotedValue(tok.raw),
      });
    }

    // If user typed only a leading "-1" or "+86" with no other primary token, treat the first token as primary
    const hasPrimary = classified.some((c) => c.kind === 'primary');
    if (
      !hasPrimary &&
      classified.length > 0 &&
      (classified[0].kind === 'include' || classified[0].kind === 'exclude')
    ) {
      classified[0] = {
        raw: classified[0].raw,
        kind: 'primary',
        value: classified[0].raw,
      };
    }

    const primaryTokens: { token: ClassifiedToken; afterRegexFlag: boolean }[] = [];
    const contains: string[] = [];
    const excludes: string[] = [];
    const globs: string[] = [];
    const modifiers: ClassifiedToken[] = [];

    let prevWasRegexFlag = false;
    for (const c of classified) {
      if (c.kind === 'primary') {
        primaryTokens.push({ token: c, afterRegexFlag: prevWasRegexFlag });
        prevWasRegexFlag = false;
      } else if (c.kind === 'include') {
        contains.push(c.value);
        modifiers.push(c);
        prevWasRegexFlag = false;
      } else if (c.kind === 'exclude') {
        excludes.push(c.value);
        modifiers.push(c);
        prevWasRegexFlag = false;
      } else if (c.kind === 'file') {
        for (const item of splitGlobList(c.value)) {
          const norm = normalizeGlobItem(item, false);
          if (norm) globs.push(norm);
        }
        modifiers.push(c);
        prevWasRegexFlag = false;
      } else if (c.kind === 'exclude-file') {
        for (const item of splitGlobList(c.value)) {
          const norm = normalizeGlobItem(item, true);
          if (norm) globs.push(norm);
        }
        modifiers.push(c);
        prevWasRegexFlag = false;
      } else if (c.kind === 'flag') {
        modifiers.push(c);
        const df = parseDollarFlags(c.raw);
        prevWasRegexFlag = Boolean(df?.regex);
      }
    }

    // Browser-style progressive search with order-commutative regex + literal resolution:
    // When regex mode ($r) is active and the user enters both a literal token and a regex token
    // in any order (e.g. `$r fn\s+\w+ search` OR `search $r fn\s+\w+` OR `search fn\s+\w+ $r`),
    // elect the regex token as `primaryPattern` so both orders produce 100% identical results.
    const hasRegexSyntax = (s: string): boolean => /[\\.*+?^${}()|[\]]/.test(s);
    const isValidRegex = (s: string): boolean => {
      try {
        new RegExp(s);
        return true;
      } catch {
        return false;
      }
    };

    let finalPrimary = '';
    if (primaryTokens.length > 0) {
      let primaryIdx = 0;
      if (isRegexMode && primaryTokens.length > 1) {
        const flaggedValidRegexIdx = primaryTokens.findIndex(
          (p) => !p.token.forceLiteral && p.afterRegexFlag && hasRegexSyntax(p.token.value) && isValidRegex(p.token.value)
        );
        const anyValidRegexIdx = primaryTokens.findIndex(
          (p) => !p.token.forceLiteral && hasRegexSyntax(p.token.value) && isValidRegex(p.token.value)
        );
        const flaggedRegexIdx = primaryTokens.findIndex(
          (p) => !p.token.forceLiteral && p.afterRegexFlag && hasRegexSyntax(p.token.value)
        );
        const anyRegexIdx = primaryTokens.findIndex(
          (p) => !p.token.forceLiteral && hasRegexSyntax(p.token.value)
        );
        const flaggedIdx = primaryTokens.findIndex((p) => p.afterRegexFlag);
        if (flaggedValidRegexIdx >= 0) {
          primaryIdx = flaggedValidRegexIdx;
        } else if (anyValidRegexIdx >= 0) {
          primaryIdx = anyValidRegexIdx;
        } else if (flaggedRegexIdx >= 0) {
          primaryIdx = flaggedRegexIdx;
        } else if (anyRegexIdx >= 0) {
          primaryIdx = anyRegexIdx;
        } else if (flaggedIdx >= 0) {
          primaryIdx = flaggedIdx;
        }
      }

      finalPrimary = primaryTokens[primaryIdx].token.value;
      for (let k = 0; k < primaryTokens.length; k++) {
        if (k === primaryIdx) continue;
        const pt = primaryTokens[k].token;
        contains.push(pt.value);
        modifiers.push({
          raw: pt.raw,
          kind: 'include',
          value: pt.value,
        });
      }
    }

    return {
      primaryPattern: finalPrimary,
      contains,
      excludes,
      globs,
      modifiers,
      flagRegex,
      hasScopedRegex,
      flagCase,
      flagWord,
    };
  });

  mode = $derived<SearchMode>(this.parsedQuery.flagRegex ? 'regex' : this._baseMode);
  hasRegexActive = $derived<boolean>(this.mode === 'regex' || this.parsedQuery.hasScopedRegex);
  caseMode = $derived<CaseMode>(this.parsedQuery.flagCase ? 'sensitive' : this._baseCaseMode);
  wholeWord = $derived<boolean>(this.parsedQuery.flagWord || this._baseWholeWord);

  primaryPattern = $derived<string>(this.parsedQuery.primaryPattern);
  contains = $derived<string[]>(this.parsedQuery.contains);
  excludes = $derived<string[]>(this.parsedQuery.excludes);
  parsedGlobs = $derived<string[]>(this.parsedQuery.globs);
  inlineModifiers = $derived(this.parsedQuery.modifiers);

  activeFilterCount = $derived<number>(
    this.contains.length +
      this.excludes.length +
      this.parsedGlobs.length +
      (this.hasRegexActive ? 1 : 0) +
      (this.caseMode === 'sensitive' ? 1 : 0) +
      (this.wholeWord ? 1 : 0)
  );

  init() {
    this.loadTheme();
    this.loadSettings();
    this.loadHistory();
    this.fetchMeta();
    this.fetchSources();
    this.connectWebSocket();
  }

  private loadSettings() {
    try {
      const raw = sessionStorage.getItem(SETTINGS_STORAGE_KEY);
      if (!raw) return;
      const s = JSON.parse(raw);
      if (typeof s.liveSearch === 'boolean') this.liveSearch = s.liveSearch;
      if (typeof s.debounceMs === 'number' && Number.isFinite(s.debounceMs)) {
        this.debounceMs = Math.max(0, Math.min(5000, Math.round(s.debounceMs)));
      }
      if (typeof s.respectIgnore === 'boolean') this.respectIgnore = s.respectIgnore;
      if (typeof s.hidden === 'boolean') this.hidden = s.hidden;
      if (typeof s.contextLines === 'number' && Number.isFinite(s.contextLines)) {
        this.contextLines = Math.max(0, Math.min(10, Math.round(s.contextLines)));
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
    const clean = nextTenant
      .trim()
      .replace(/[^a-zA-Z0-9._-]/g, '-')
      .slice(0, 64) || 'default';
    if (clean === this.tenant) return;
    this.tenant = clean;
    this.selectedSources = [];
    this.saveSettings();
    this.fetchSources();
    if (this.pattern.trim().length > 0) {
      this.scheduleSearch(true);
    }
  }

  toggleLocale() {
    this.locale = this.locale === 'zh' ? 'en' : 'zh';
    this.saveSettings();
  }

  saveSettings() {
    try {
      sessionStorage.setItem(
        SETTINGS_STORAGE_KEY,
        JSON.stringify({
          locale: this.locale,
          tenant: this.tenant,
          liveSearch: this.liveSearch,
          debounceMs: this.debounceMs,
          respectIgnore: this.respectIgnore,
          hidden: this.hidden,
          contextLines: this.contextLines,
          maxResults: this.maxResults,
          codeFontSize: this.codeFontSize,
          wordWrap: this.wordWrap,
          resultDensity: this.resultDensity,
          inspectorContext: this.inspectorContext,
        })
      );
    } catch {
      // ignore storage errors
    }
  }

  resetSettings() {
    this.liveSearch = true;
    this.debounceMs = 120;
    this.respectIgnore = false;
    this.hidden = false;
    this.contextLines = 0;
    this.maxResults = 20000;
    this.codeFontSize = 13.5;
    this.wordWrap = true;
    this.resultDensity = 'comfortable';
    this.inspectorContext = 0;
    this.saveSettings();
    if (this.pattern.trim().length > 0) {
      this.executeSearch();
    }
  }

  private loadTheme() {
    try {
      const saved = sessionStorage.getItem(THEME_STORAGE_KEY);
      if (saved === 'light') {
        this.darkMode = false;
      } else {
        this.darkMode = true;
      }
    } catch {
      this.darkMode = true;
    }
    this.applyThemeClass();
  }

  toggleTheme() {
    this.darkMode = !this.darkMode;
    this.applyThemeClass();
    try {
      sessionStorage.setItem(THEME_STORAGE_KEY, this.darkMode ? 'dark' : 'light');
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
      if (raw) {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) {
          this.searchHistory = parsed.slice(0, 20);
        }
      }
    } catch {
      this.searchHistory = [];
    }
  }

  private recordHistory() {
    const pat = this.pattern.trim();
    if (!pat) return;
    const entry: SearchHistoryEntry = {
      pattern: pat,
      mode: this.mode,
      caseMode: this.caseMode,
      wholeWord: this.wholeWord,
      contains: [...this.contains],
      excludes: [...this.excludes],
      replacement: this.replacement,
      timestamp: Date.now(),
    };
    const filtered = this.searchHistory.filter(
      (h) => !(h.pattern === entry.pattern && h.mode === entry.mode)
    );
    this.searchHistory = [entry, ...filtered].slice(0, 20);
    try {
      localStorage.setItem(HISTORY_STORAGE_KEY, JSON.stringify(this.searchHistory));
    } catch {
      // ignore
    }
  }

  removeHistoryEntry(pattern: string, mode: SearchMode) {
    this.searchHistory = this.searchHistory.filter(
      (h) => !(h.pattern === pattern && h.mode === mode)
    );
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
        engine: data.engine || 'libwebgrep 0.1.0 · SIMD',
        types:
          Array.isArray(data.types) && data.types.length > 0
            ? data.types
            : KNOWN_FILE_TYPES.map((t) => t.id),
        scopes: Array.isArray(data.scopes) ? data.scopes : [],
      };
    } catch {
      // keep default meta
    }
  }

  togglePathScope(pathStr: string) {
    if (this.selectedPaths.includes(pathStr)) {
      this.selectedPaths = this.selectedPaths.filter((p) => p !== pathStr);
    } else {
      this.selectedPaths = [...this.selectedPaths, pathStr];
    }
    this.scheduleSearch(true);
  }

  private applySourcesResponse(data: SourcesResponse) {
    if (typeof data.searchCount === 'number' && data.searchCount >= 0) {
      this.searchCount = data.searchCount;
    }
    if (Array.isArray(data.sources)) {
      this.sources = data.sources;
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
  }) {
    const cleanPath = (payload.config?.path ?? payload.path ?? '').trim();
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
        },
        enabled: payload.enabled ?? true,
      }),
    });
    if (!res.ok) {
      const errData = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
      throw new Error(errData.error || `HTTP ${res.status}`);
    }
    const data = (await res.json()) as SourcesResponse;
    this.applySourcesResponse(data);
    if (this.pattern.trim().length > 0) {
      this.scheduleSearch(true);
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
      this.applySourcesResponse(data);
      if (this.pattern.trim().length > 0) {
        this.scheduleSearch(true);
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
      this.applySourcesResponse(data);
      if (this.pattern.trim().length > 0) {
        this.scheduleSearch(true);
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
      this.applySourcesResponse(data);
      this.selectedSources = this.selectedSources.filter((s) => s !== id);
      if (this.pattern.trim().length > 0) {
        this.scheduleSearch(true);
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

  toggleSourceScope(id: string) {
    if (this.selectedSources.includes(id)) {
      this.selectedSources = this.selectedSources.filter((s) => s !== id);
    } else {
      this.selectedSources = [...this.selectedSources, id];
    }
    this.scheduleSearch(true);
  }

  clearScope() {
    if (this.selectedPaths.length === 0 && this.selectedSources.length === 0) return;
    this.selectedPaths = [];
    this.selectedSources = [];
    this.scheduleSearch(true);
  }

  toggleFileType(typeId: string) {
    if (this.selectedTypes.includes(typeId)) {
      this.selectedTypes = this.selectedTypes.filter((t) => t !== typeId);
    } else {
      this.selectedTypes = [...this.selectedTypes, typeId];
    }
    this.scheduleSearch(true);
  }

  clearFileTypes() {
    if (this.selectedTypes.length === 0) return;
    this.selectedTypes = [];
    this.scheduleSearch(true);
  }

  toggleFlag(flag: 'r' | 'c' | 'w') {
    const scopedRegex = new RegExp(`([-+!]?)\\$([a-zA-Z.*]+)\\(([^)]*)\\)`, 'g');
    let hadFlag = false;
    const nextPattern = this.pattern.replace(
      scopedRegex,
      (full, prefix: string, rawFlags: string, inner: string) => {
        const df = parseDollarFlags(`$${rawFlags}`);
        if (!df) return full;
        const hasTarget =
          (flag === 'r' && df.regex) ||
          (flag === 'c' && df.caseSensitive) ||
          (flag === 'w' && df.wholeWord);
        if (!hasTarget) return full;
        hadFlag = true;
        const keepR = flag === 'r' ? false : df.regex;
        const keepC = flag === 'c' ? false : df.caseSensitive;
        const keepW = flag === 'w' ? false : df.wholeWord;
        const rem = `${keepR ? 'r' : ''}${keepC ? 'c' : ''}${keepW ? 'w' : ''}`;
        return rem ? `${prefix}$${rem}(${inner})` : `${prefix}${inner}`;
      }
    );

    if (hadFlag) {
      this.pattern = nextPattern.replace(/\s{2,}/g, ' ').trim();
    } else {
      const trimmed = this.pattern.trim();
      if (!trimmed) {
        this.pattern = `$${flag}()`;
      } else if (!/\s/.test(trimmed) && !trimmed.startsWith('$') && !trimmed.startsWith('@')) {
        this.pattern = `$${flag}(${trimmed})`;
      } else {
        this.pattern = `${this.pattern.trimEnd()} $${flag}()`;
      }
    }
    this.scheduleSearch(true);
  }

  cycleCaseMode() {
    this.toggleFlag('c');
  }

  cycleSearchMode() {
    this.toggleFlag('r');
  }

  toggleScopeToken(scope: string) {
    const token = `@${scope}`;
    const parts = this.pattern.trim().split(/\s+/).filter(Boolean);
    if (parts.includes(token)) {
      this.pattern = parts.filter((p) => p !== token).join(' ');
    } else {
      this.pattern = [...parts, token].join(' ');
    }
    this.scheduleSearch(true);
  }

  insertInlineOperator(op: '+' | '-' | '@' | '$', inputEl?: HTMLInputElement | null) {
    const cur = this.pattern;
    const prefix = cur.length > 0 && !/\s$/.test(cur) ? `${cur} ` : cur;
    this.pattern = `${prefix}${op}`;
    if (inputEl) {
      inputEl.focus();
      requestAnimationFrame(() => {
        const len = this.pattern.length;
        inputEl.setSelectionRange(len, len);
      });
    }
  }

  removeInlineModifier(rawToken: string) {
    const idx = this.pattern.indexOf(rawToken);
    if (idx >= 0) {
      const before = this.pattern.slice(0, idx);
      const after = this.pattern.slice(idx + rawToken.length);
      this.pattern = `${before} ${after}`.replace(/\s{2,}/g, ' ').trim();
    } else {
      const parts = this.pattern
        .split(/\s+/)
        .filter((t) => t !== rawToken);
      this.pattern = parts.join(' ');
    }
    this.scheduleSearch(true);
  }

  removeModifiersByKind(
    kinds: ('primary' | 'include' | 'exclude' | 'file' | 'exclude-file' | 'flag')[]
  ) {
    const toRemove = new Set(
      this.inlineModifiers.filter((m) => kinds.includes(m.kind)).map((m) => m.raw)
    );
    if (toRemove.size === 0) return;
    const base = this.primaryPattern;
    const kept = this.inlineModifiers
      .filter((m) => !kinds.includes(m.kind))
      .map((m) => m.raw);
    this.pattern = [base, ...kept].filter(Boolean).join(' ');
    this.scheduleSearch(true);
  }

  appendSearchTerm(term: string) {
    const clean = term.trim();
    if (!clean) return;
    const formatted = /\s/.test(clean) ? `"${clean.replace(/"/g, '\\"')}"` : clean;
    const cur = this.pattern.trim();
    this.pattern = cur.length > 0 ? `${cur} ${formatted}` : formatted;
    this.executeSearch(false);
  }

  applyPreset(preset: SearchPreset) {
    const parts = [preset.pattern];
    if (preset.contains) {
      for (const c of preset.contains) parts.push(c);
    }
    if (preset.excludes) {
      for (const x of preset.excludes) parts.push(`-${x}`);
    }
    if (preset.mode === 'regex') parts.push('$r');
    if (preset.caseMode === 'sensitive') parts.push('$c');
    if (preset.wholeWord) parts.push('$w');
    this.pattern = parts.join(' ');
    this._baseMode = preset.mode === 'multi' ? 'multi' : 'literal';
    this._baseCaseMode = 'insensitive';
    this._baseWholeWord = false;
    this.wholeLine = false;
    this.invert = false;
    this.replacement = '';
    this.executeSearch(false);
  }

  applyHistoryEntry(entry: SearchHistoryEntry) {
    let q = entry.pattern.trim();
    const hasDollarR = /\s\$r\b|^\$r\b/i.test(q);
    const hasDollarC = /\s\$c\b|^\$c\b/i.test(q);
    const hasDollarW = /\s\$w\b|^\$w\b/i.test(q);
    if (entry.mode === 'regex' && !hasDollarR) q += ' $r';
    if (entry.caseMode === 'sensitive' && !hasDollarC) q += ' $c';
    if (entry.wholeWord && !hasDollarW) q += ' $w';
    this.pattern = q;
    this._baseMode = entry.mode === 'multi' ? 'multi' : 'literal';
    this._baseCaseMode = 'insensitive';
    this._baseWholeWord = false;
    this.replacement = '';
    this.executeSearch(false);
  }

  resetAllFilters() {
    if (this.primaryPattern) {
      const flagMods = this.inlineModifiers
        .filter((m) => m.kind === 'flag' && parseDollarFlags(m.raw)?.regex)
        .map((m) => m.raw);
      this.pattern = [this.primaryPattern, ...flagMods].filter(Boolean).join(' ');
    }
    this.containsInput = '';
    this.excludesInput = '';
    this.replacement = '';
    this.contextLines = 0;
    this.selectedTypes = [];
    this.globsInput = '';
    this.selectedPaths = [];
    this._baseMode = 'literal';
    this._baseCaseMode = 'insensitive';
    this._baseWholeWord = false;
    this.wholeLine = false;
    this.invert = false;
    this.scheduleSearch(true);
  }

  // WebSocket management
  connectWebSocket() {
    if (typeof window === 'undefined') return;
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)) {
      return;
    }

    const protocol = window.location.protocol === 'https:' ? 'wss://' : 'ws://';
    const wsUrl = `${protocol}${window.location.host}/api/ws`;
    this.wsStatus = this.reconnectAttempt > 0 ? 'reconnecting' : 'connecting';

    try {
      const socket = new WebSocket(wsUrl);
      this.ws = socket;

      socket.onopen = () => {
        this.wsStatus = 'connected';
        this.reconnectAttempt = 0;
        this.fetchMeta();
        this.fetchSources();
        if (this.pattern.trim()) {
          this.executeSearch();
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
        this.wsStatus = 'reconnecting';
        this.scheduleReconnect();
      };
    } catch {
      this.wsStatus = 'offline';
      this.scheduleReconnect();
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

  scheduleSearch(immediate = false) {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    if (immediate) {
      this.debounceTimer = setTimeout(() => {
        this.executeSearch(false);
      }, 16);
      return;
    }
    if (!this.liveSearch) return;

    const trimmedLen = this.pattern.trim().length;
    if (trimmedLen > 0) {
      this.hasSearchedOnce = true;
    }
    const delay =
      trimmedLen <= 1
        ? Math.max(240, this.debounceMs)
        : trimmedLen === 2
          ? Math.max(150, this.debounceMs)
          : this.debounceMs;

    this.debounceTimer = setTimeout(() => {
      this.executeSearch(true);
    }, delay);
  }

  cancelSearch() {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    if (this.isSearching && this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(
        JSON.stringify({
          type: 'cancel',
          id: this.currentSearchId,
        })
      );
    }
    this.isSearching = false;
  }

  clearSearch() {
    this.cancelSearch();
    this.pattern = '';
    this._baseMode = 'literal';
    this._baseCaseMode = 'insensitive';
    this._baseWholeWord = false;
    this.errorMessage = null;
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

  private resetResultBuffer() {
    this.clearFlushSchedule();
    this.awaitingFirstChunk = false;
    this.pendingChunks = [];
    this.groupIndexByFile.clear();
    this.fileGroups = [];
    this.flatHits = [];
    this.activeHitIndex = -1;
    this.filesSearched = 0;
    this.filesMatched = 0;
    this.totalMatches = 0;
    this.matchedLines = 0;
    this.bytesSearched = 0;
    this.elapsedMs = 0;
    this.limitHit = false;
  }

  executeSearch(isLiveTyping = false) {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }

    const pat = this.primaryPattern;
    if (!pat || pat.length === 0) {
      this.cancelSearch();
      this.resetResultBuffer();
      this.errorMessage = null;
      return;
    }

    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      this.connectWebSocket();
      return;
    }

    this.currentSearchId += 1;
    const searchId = this.currentSearchId;

    // Stale-While-Revalidate: keep existing results on screen until the first batch or done arrives
    // so the UI never flashes to a blank spinner between keystrokes
    this.clearFlushSchedule();
    this.pendingChunks = [];
    this.awaitingFirstChunk = true;
    this.errorMessage = null;
    this.isSearching = true;
    this.hasSearchedOnce = true;

    if (!isLiveTyping && this.pattern.trim().length >= 1) {
      this.recordHistory();
    }

    const trimmedLen = pat.trim().length;
    const effectiveMaxResults =
      isLiveTyping && trimmedLen === 1
        ? Math.min(this.maxResults, 1000)
        : isLiveTyping && trimmedLen === 2
          ? Math.min(this.maxResults, 3000)
          : this.maxResults;

    const payload: WsSearchMessage = {
      type: 'search',
      id: searchId,
      tenant: this.tenant,
      pattern: pat,
      mode: this.mode,
      case: this.caseMode,
      wholeWord: this.wholeWord,
      wholeLine: this.wholeLine,
      invert: this.invert,
      contains: this.contains,
      excludes: this.excludes,
      replacement: this.replacement,
      context: this.contextLines,
      sources: this.selectedSources,
      paths: this.selectedPaths,
      globs: this.parsedGlobs,
      types: this.selectedTypes,
      hidden: this.hidden,
      respectIgnore: this.respectIgnore,
      maxResults: effectiveMaxResults,
    };

    const enabledSourcesSig = this.sources
      .filter((s) => s.enabled)
      .map((s) => s.id)
      .join(',');
    const cacheKey = JSON.stringify({
      p: pat,
      m: this.mode,
      c: this.caseMode,
      ww: this.wholeWord,
      wl: this.wholeLine,
      inv: this.invert,
      inc: this.contains,
      exc: this.excludes,
      rep: this.replacement,
      ctx: this.contextLines,
      src: this.selectedSources,
      en: enabledSourcesSig,
      paths: this.selectedPaths,
      globs: this.parsedGlobs,
      types: this.selectedTypes,
      hid: this.hidden,
      ign: this.respectIgnore,
      max: effectiveMaxResults,
    });
    this.activeQueryCacheKey = cacheKey;

    // Tier L0: Frontend Instant Ring Cache (< 0.05ms zero-copy $state.raw swap)
    const l0Hit = this.l0Cache.get(cacheKey);
    if (l0Hit) {
      this.fileGroups = l0Hit.fileGroups;
      this.flatHits = l0Hit.flatHits;
      this.filesSearched = l0Hit.filesSearched;
      this.filesMatched = l0Hit.filesMatched;
      this.totalMatches = l0Hit.totalMatches;
      this.matchedLines = l0Hit.matchedLines;
      this.bytesSearched = l0Hit.bytesSearched;
      this.limitHit = l0Hit.limitHit;
      this.cacheHit = 'l0-instant';
    }

    this.ws.send(JSON.stringify(payload));
  }

  private handleWsMessage(msg: WsIncomingMessage) {
    if (msg.id !== this.currentSearchId) return;

    switch (msg.type) {
      case 'hits': {
        if (Array.isArray(msg.items) && msg.items.length > 0) {
          this.pendingChunks.push(msg.items);
          // Coalesce the initial 60ms of streaming packets into a single full-viewport swap,
          // then stream subsequent batches at a calm 80ms rhythm (~12.5fps)
          this.scheduleFlushHits(this.awaitingFirstChunk ? 60 : 80);
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

        if (this.activeQueryCacheKey && this.flatHits.length <= 20000) {
          if (this.l0Cache.size >= 24 && !this.l0Cache.has(this.activeQueryCacheKey)) {
            const oldestKey = this.l0Cache.keys().next().value;
            if (oldestKey !== undefined) this.l0Cache.delete(oldestKey);
          }
          this.l0Cache.set(this.activeQueryCacheKey, {
            fileGroups: this.fileGroups,
            flatHits: this.flatHits,
            filesSearched: this.filesSearched,
            filesMatched: this.filesMatched,
            totalMatches: this.totalMatches,
            matchedLines: this.matchedLines,
            bytesSearched: this.bytesSearched,
            limitHit: this.limitHit,
          });
        }

        if (this.totalMatches > 0 && this.pattern.trim().length >= 2) {
          this.recordHistory();
        }

        if (this.activeHitIndex === -1 && this.flatHits.length > 0 && this.rightInspectorOpen && this.inspectedPath) {
          const firstMatchIdx = this.flatHits.findIndex((h) => !h.isContext);
          this.selectHitByIndex(firstMatchIdx >= 0 ? firstMatchIdx : 0, false);
        }
        break;
      }
      case 'error': {
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
      this.groupIndexByFile.clear();
      this.fileGroups = [];
      this.flatHits = [];
      this.activeHitIndex = -1;
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
      this.inspectFileAtLine(item.file, item.line, this.inspectorContext, true);
    }
  }

  selectHitByIndex(index: number, forceOpenInspector = false) {
    if (index < 0 || index >= this.flatHits.length) return;
    this.activeHitIndex = index;
    const hit = this.flatHits[index];
    if (hit) {
      // If the file group was collapsed, auto-expand it when navigating to it
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
      // Check if the streaming hit text might have been truncated by the 4096-byte UTF-8 streaming cap
      // (Note: CJK chars are 3 UTF-8 bytes each, or a JSON line starting with '{' that doesn't end with '}')
      const trimmed = hit.text.trim();
      const looksLikeIncompleteJson =
        (trimmed.startsWith('{') && !trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && !trimmed.endsWith(']'));
      const approxUtf8Bytes = new TextEncoder().encode(hit.text).length;

      if (approxUtf8Bytes < 4000 && !looksLikeIncompleteJson) {
        this.inspectedPath = hit.file;
        this.inspectedLine = hit.line;
        this.inspectedFile = null;
        this.inspectorLoading = false;
        this.inspectorError = null;
      } else {
        this.inspectFileAtLine(hit.file, hit.line, 0, forceOpenInspector);
      }
    }
  }

  navigateHits(delta: 1 | -1) {
    if (this.flatHits.length === 0) return;
    let next = this.activeHitIndex + delta;
    if (next < 0) next = 0;
    if (next >= this.flatHits.length) next = this.flatHits.length - 1;
    this.selectHitByIndex(next, false);
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

  async inspectFileAtLine(
    filePath: string,
    line = 1,
    contextRadius = this.inspectorContext,
    forceOpen = true
  ) {
    this.inspectedPath = filePath;
    this.inspectedLine = Math.max(1, line);
    this.inspectorContext = contextRadius;
    this.inspectorLoading = true;
    this.inspectorError = null;
    if (forceOpen) {
      this.detailOpen = true;
      if (!this.rightInspectorOpen) this.rightInspectorOpen = true;
    }

    try {
      const params = new URLSearchParams({
        tenant: this.tenant,
        path: filePath,
        line: String(Math.max(1, line)),
        context: String(contextRadius),
      });
      const res = await fetch(`/api/file?${params.toString()}`);
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }
      const data = (await res.json()) as FileResponse;
      this.inspectedFile = data;
    } catch (err) {
      this.inspectorError = err instanceof Error ? err.message : 'Failed to load file context';
    } finally {
      this.inspectorLoading = false;
    }
  }
}

export const workbench = new WorkbenchState();
