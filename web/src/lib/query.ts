/**
 * Structured query model & compiler for WebGrep:
 *
 * - Every search step (`QueryStep`) holds clean verbatim text + explicit `Aa` / `ab` / `.*` / `-` flags.
 * - Spaces, quotes, `-O3`, `in:foo`, `time:bar`, `@Vector` are 100% literal inside a step (zero implicit parsing).
 * - Scope filters (`ScopeFilter`: data sources, file types, time window) live cleanly outside text steps.
 * - Compiles to `libwebgrep` WebSocket wire terms (`$c(...)`, `$w(...)`, `$r(...)`, `$rcw(...)`) + scope fields,
 *   and produces canonical cache keys & history identifiers.
 */
import type { DataSourceItem, QueryStep, ScopeFilter, TimeFilterMode, TimePreset } from './types.ts';
import { formatTimeScopeLabel } from './time-range.ts';

export { formatTimeScopeLabel };

export interface CompiledSearchQuery {
  activeSteps: QueryStep[];
  primaryPattern: string;
  contains: string[];
  excludes: string[];
  sources: string[];
  globs: string[];
  types: string[];
  timeStartMs: number;
  timeEndMs: number;
  timeMode: TimeFilterMode;
  timeFormat: string;
  hasExecutableQuery: boolean;
}

export interface QueryCacheKeys {
  baseKey: string;
  exactKey: string;
  historyId: string;
}

export function createQueryStep(
  text = '',
  opts: Partial<Omit<QueryStep, 'text'>> = {}
): QueryStep {
  return {
    text,
    exclude: Boolean(opts.exclude),
    caseSensitive: Boolean(opts.caseSensitive),
    wholeWord: Boolean(opts.wholeWord),
    isRegex: Boolean(opts.isRegex),
  };
}

export function isStepEmpty(step: QueryStep | null | undefined): boolean {
  return !step || step.text.trim().length === 0;
}

export function normalizeStep(step: QueryStep): QueryStep {
  return {
    text: step.text.trim(),
    exclude: Boolean(step.exclude),
    caseSensitive: Boolean(step.caseSensitive),
    wholeWord: Boolean(step.wholeWord),
    isRegex: Boolean(step.isRegex),
  };
}

export function stepsEqual(a: QueryStep, b: QueryStep): boolean {
  return (
    a.text === b.text &&
    a.exclude === b.exclude &&
    a.caseSensitive === b.caseSensitive &&
    a.wholeWord === b.wholeWord &&
    a.isRegex === b.isRegex
  );
}

function escapeRegex(s: string): string {
  return s.replace(/[\\.*+?^${}()|[\]]/g, '\\$&');
}

/**
 * Encodes a single `QueryStep` into the wire representation expected by `src/search_job.zig`.
 * Literal strings matching `$flags(...)` are regex-escaped so the backend never reinterprets them as modifiers.
 */
export function encodeStepToWire(step: QueryStep): string {
  const text = step.text.trim();
  if (!text) return '';

  const c = step.caseSensitive ? 'c' : '';
  const w = step.wholeWord ? 'w' : '';

  if (step.isRegex) {
    return `$r${c}${w}(${text})`;
  }

  if (/^\$[a-zA-Z.*]*\(/.test(text)) {
    return `$r${c}${w}(${escapeRegex(text)})`;
  }

  const flags = `${c}${w}`;
  return flags ? `$${flags}(${text})` : text;
}

function parseSingleTimePoint(expr: string, nowMs: number, isEnd: boolean): number | null {
  const s = expr.trim();
  if (!s) return null;

  const rel = /^(\d+(?:\.\d+)?)\s*(s|sec|m|min|h|hr|d|day|w)$/i.exec(s);
  if (rel) {
    const num = Number(rel[1]);
    const unit = rel[2].toLowerCase();
    const mult = unit.startsWith('s')
      ? 1000
      : unit.startsWith('m')
        ? 60_000
        : unit.startsWith('h')
          ? 3_600_000
          : unit.startsWith('d')
            ? 86_400_000
            : 7 * 86_400_000;
    return Math.max(1, Math.round(nowMs - num * mult));
  }

  const tod = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(s);
  if (tod) {
    const d = new Date(nowMs);
    const hh = Number(tod[1]);
    const mm = Number(tod[2]);
    const ss = tod[3] !== undefined ? Number(tod[3]) : isEnd ? 59 : 0;
    const ms = isEnd ? 999 : 0;
    d.setHours(hh, mm, ss, ms);
    return d.getTime();
  }

  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) {
    const iso = isEnd ? `${s}T23:59:59.999` : `${s}T00:00:00.000`;
    const parsed = Date.parse(iso);
    return Number.isFinite(parsed) ? parsed : null;
  }

  if (/^\d{10,19}$/.test(s)) {
    if (s.length >= 16) return Math.floor(Number(s.slice(0, 13)));
    if (s.length >= 13) return Number(s.slice(0, 13));
    return Number(s) * 1000;
  }

  const slashNormalized = s.replace(/^(\d{4})\/(\d{2})\/(\d{2})(?=$|[T ])/, '$1-$2-$3');
  const localDt =
    /^(\d{4})-(\d{2})-(\d{2})[T ](\d{1,2}):(\d{2})(?::(\d{2}))?(?:[.,](\d{1,3}))?$/.exec(
      slashNormalized
    );
  if (localDt) {
    const year = Number(localDt[1]);
    const month = Number(localDt[2]);
    const day = Number(localDt[3]);
    const hh = Number(localDt[4]);
    const mm = Number(localDt[5]);
    const ss = localDt[6] !== undefined ? Number(localDt[6]) : isEnd ? 59 : 0;
    const ms =
      localDt[7] !== undefined ? Number(localDt[7].padEnd(3, '0')) : isEnd ? 999 : 0;
    const d = new Date(year, month - 1, day, hh, mm, ss, ms);
    const ts = d.getTime();
    return Number.isFinite(ts) ? ts : null;
  }

  const normalizedIso =
    slashNormalized.includes(' ') && !slashNormalized.includes('T')
      ? slashNormalized.replace(' ', 'T')
      : slashNormalized;
  const parsed = Date.parse(normalizedIso);
  if (!Number.isFinite(parsed)) return null;
  if (isEnd && !/[.,]\d+/.test(normalizedIso)) {
    return parsed + 999;
  }
  return parsed;
}

export function parseTimeModifierSpec(
  rawSpec: string,
  nowMs = Date.now()
): { startMs: number; endMs: number } | null {
  const clean = rawSpec.trim();
  if (!clean) return null;

  const named = clean.toLowerCase();
  if (named === 'today' || named === 'yesterday') {
    const d = new Date(nowMs);
    d.setHours(0, 0, 0, 0);
    if (named === 'today') return { startMs: d.getTime(), endMs: 0 };
    const end = d.getTime() - 1;
    d.setDate(d.getDate() - 1);
    return { startMs: d.getTime(), endMs: end };
  }

  const rangeSep = clean.includes('..') ? '..' : clean.includes('~') ? '~' : null;
  if (rangeSep) {
    const [leftRaw, rightRaw] = clean.split(rangeSep, 2);
    const startMs = leftRaw.trim() ? parseSingleTimePoint(leftRaw, nowMs, false) : 0;
    const endMs = rightRaw.trim() ? parseSingleTimePoint(rightRaw, nowMs, true) : 0;
    if (startMs === null || endMs === null) return null;
    if (startMs === 0 && endMs === 0) return null;
    if (startMs > 0 && endMs > 0 && startMs > endMs) {
      return { startMs: endMs, endMs: startMs };
    }
    return { startMs, endMs };
  }

  if (/^\d{4}-\d{2}-\d{2}$/.test(clean)) {
    const startMs = parseSingleTimePoint(clean, nowMs, false);
    const endMs = parseSingleTimePoint(clean, nowMs, true);
    if (startMs !== null && endMs !== null) {
      return { startMs, endMs };
    }
  }

  const startMs = parseSingleTimePoint(clean, nowMs, false);
  if (startMs === null) return null;
  return { startMs, endMs: 0 };
}

export function compileSearchQuery(
  steps: readonly QueryStep[],
  draft: QueryStep | null,
  scope: ScopeFilter,
  nowMs = Date.now()
): CompiledSearchQuery {
  const activeSteps: QueryStep[] = [];
  for (const s of steps) {
    const norm = normalizeStep(s);
    if (norm.text.length > 0) activeSteps.push(norm);
  }
  if (draft) {
    const normDraft = normalizeStep(draft);
    if (normDraft.text.length > 0) activeSteps.push(normDraft);
  }

  const positives: string[] = [];
  const excludes: string[] = [];
  for (const step of activeSteps) {
    const wire = encodeStepToWire(step);
    if (!wire) continue;
    if (step.exclude) {
      excludes.push(wire);
    } else {
      positives.push(wire);
    }
  }

  const timeRange = scope.timePreset ? parseTimeModifierSpec(scope.timePreset, nowMs) : null;
  const timeStartMs = timeRange?.startMs ?? 0;
  const timeEndMs = timeRange?.endMs ?? 0;
  const timeMode: TimeFilterMode = scope.timeMode ?? 'source';
  const timeFormat = (scope.timeFormat ?? '').trim();

  const sources = [...scope.sources];
  const excludedSources = scope.excludedSources ?? [];
  const globs = excludedSources.map((id) => `!${id}`);
  const types = [...scope.types];

  const primaryPattern = positives[0] ?? '';
  const contains = positives.slice(1);
  const hasExecutableQuery = primaryPattern.length > 0 || timeStartMs > 0 || timeEndMs > 0;

  return {
    activeSteps,
    primaryPattern,
    contains,
    excludes,
    sources,
    globs,
    types,
    timeStartMs,
    timeEndMs,
    timeMode,
    timeFormat,
    hasExecutableQuery,
  };
}

export interface HistoryScopeFlags {
  hasSources: boolean;
  hasTime: boolean;
}

/**
 * Returns value-free scope flags indicating whether a history entry restricts
 * data sources and/or time range, without exposing specific names or values.
 */
export function getHistoryScopeFlags(
  scope: Pick<ScopeFilter, 'sources' | 'excludedSources' | 'timePreset'> | null | undefined
): HistoryScopeFlags {
  if (!scope) return { hasSources: false, hasTime: false };
  const hasSources =
    scope.sources.length > 0 || (scope.excludedSources?.length ?? 0) > 0;
  const hasTime = scope.timePreset.trim().length > 0;
  return { hasSources, hasTime };
}

export function formatHistoryLabel(
  steps: readonly QueryStep[],
  draft: QueryStep | null
): string {
  const parts: string[] = [];
  for (const s of steps) {
    const norm = normalizeStep(s);
    if (norm.text.length > 0) {
      parts.push(norm.exclude ? `-${norm.text}` : norm.text);
    }
  }
  if (draft) {
    const normDraft = normalizeStep(draft);
    if (normDraft.text.length > 0) {
      parts.push(normDraft.exclude ? `-${normDraft.text}` : normDraft.text);
    }
  }
  return parts.join(' → ');
}

function getTimeBucketKey(preset: TimePreset, nowMs: number): string {
  const clean = preset.trim();
  if (!clean) return '';
  if (clean === 'today' || clean === 'yesterday') {
    const d = new Date(nowMs);
    const yyyy = d.getFullYear();
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    return `${clean}:${yyyy}-${mm}-${dd}`;
  }
  if (/^\d{4}[-/]\d{2}[-/]\d{2}$/.test(clean)) {
    return `range:${clean}`;
  }
  const sep = clean.includes('..') ? '..' : clean.includes('~') ? '~' : null;
  if (sep) {
    const [leftRaw, rightRaw] = clean.split(sep, 2);
    const relRe = /^\d+(?:\.\d+)?\s*(?:s|sec|m|min|h|hr|d|day|w)$/i;
    const isDynamic =
      relRe.test(leftRaw.trim()) ||
      relRe.test(rightRaw.trim()) ||
      rightRaw.trim() === '';
    if (!isDynamic) {
      return `range:${clean}`;
    }
  }
  return `${clean}:${Math.floor(nowMs / 5000)}`;
}

export function buildQueryCacheKeys(params: {
  tenant: string;
  effectiveSources: readonly string[];
  excludedSources: readonly string[];
  types: readonly string[];
  timePreset: TimePreset;
  timeMode?: TimeFilterMode;
  timeFormat?: string;
  tzOffsetMin?: number;
  sourceTimeFormatsSig?: string;
  sourcePluginsSig?: string;
  steps: readonly QueryStep[];
  contextLines?: number;
  hidden: boolean;
  respectIgnore: boolean;
  maxResults: number;
  nowMs?: number;
}): QueryCacheKeys {
  const nowMs = params.nowMs ?? Date.now();
  const sortedSources = [...params.effectiveSources].sort();
  const sortedExcluded = [...params.excludedSources].sort();
  const sortedTypes = [...params.types].sort();
  const normSteps = params.steps.map(normalizeStep).filter((s) => s.text.length > 0);
  const timeMode: TimeFilterMode = params.timeMode ?? 'source';
  const timeFormat = (params.timeFormat ?? '').trim();
  const tzOffsetMin = params.tzOffsetMin ?? 0;
  const sourceTimeFormatsSig = params.sourceTimeFormatsSig ?? '';
  const sourcePluginsSig = params.sourcePluginsSig ?? '';

  const historyId = JSON.stringify({
    t: params.tenant,
    s: sortedSources,
    ex: sortedExcluded,
    ty: sortedTypes,
    tp: params.timePreset,
    ...(params.timePreset && timeMode !== 'source' ? { tm: timeMode } : {}),
    ...(params.timePreset && timeMode !== 'mtime' && timeFormat ? { tf: timeFormat } : {}),
    q: normSteps,
  });

  const baseKey = JSON.stringify({
    t: params.tenant,
    s: sortedSources,
    ex: sortedExcluded,
    ty: sortedTypes,
    tb: getTimeBucketKey(params.timePreset, nowMs),
    tm: timeMode,
    tf: timeFormat,
    tz: tzOffsetMin,
    sf: sourceTimeFormatsSig,
    sp: sourcePluginsSig,
    q: normSteps,
    ctx: params.contextLines ?? 0,
    hid: params.hidden,
    ign: params.respectIgnore,
  });

  const exactKey = `${baseKey}|max:${params.maxResults}`;
  return { baseKey, exactKey, historyId };
}

/**
 * Computes the aligned Docker HTTP `/logs?since=<sec>` preview offset so 1-based line numbers
 * from `/api/file` & `/api/context` match content-time auto-filtered Docker search hits 1:1.
 */
export function computeDockerPreviewSinceSec(
  sources: ReadonlyArray<Pick<DataSourceItem, 'kind' | 'name' | 'config'>>,
  filePath: string,
  timeStartMs: number
): number | null {
  if (!Number.isFinite(timeStartMs) || timeStartMs <= 0) return null;
  const slash = filePath.indexOf('/');
  if (slash <= 0) return null;
  const prefix = filePath.slice(0, slash).toLowerCase();
  const matched = sources.find((s) => s.kind === 'docker' && s.name.toLowerCase() === prefix);
  if (!matched) return null;
  const rawTf = matched.config?.timeFormat;
  const effectiveTf = rawTf === undefined || rawTf === null ? 'auto' : rawTf.trim().toLowerCase();
  if (effectiveTf !== 'auto') return null;
  const sinceSec = Math.floor(timeStartMs / 1000) - 2;
  return sinceSec > 0 ? sinceSec : null;
}
