import { collectTermSpans } from '../highlight/segments.ts';
import type { DataSourceItem, HitItem, ViewAdapterId, ViewModePreference } from '../types.ts';
import { codeAdapter } from './code-adapter.ts';
import { buildFallbackParsedLog, logAdapter } from './log-adapter.ts';
import { getCachedLogProbe, parseLogLine } from './log-parser.ts';
import { estimatePlainColumns, parsePlainHitMeta, plainAdapter } from './plain-adapter.ts';
import type {
  AdapterBatchSummary,
  FastLogProbe,
  HeadlessAdapter,
  LogCategoryStat,
  LogLevel,
  LogLevelStat,
  LogStreamStats,
  ParsedLogRecord,
  ParsedPlainRecord,
  PlainRowProbe,
} from './types.ts';

export const HEADLESS_ADAPTERS: readonly HeadlessAdapter[] = [
  logAdapter,
  codeAdapter,
  plainAdapter,
];

export const VIEW_MODE_CYCLE_ORDER: readonly ViewModePreference[] = [
  'auto',
  ...HEADLESS_ADAPTERS.map((a) => a.id),
];

const ADAPTER_BY_ID = new Map<ViewAdapterId, HeadlessAdapter>(
  HEADLESS_ADAPTERS.map((a) => [a.id, a])
);

export function getHeadlessAdapter(id: ViewAdapterId): HeadlessAdapter {
  return ADAPTER_BY_ID.get(id) ?? plainAdapter;
}

const parsedLogCache = new WeakMap<HitItem, ParsedLogRecord>();
const plainMetaCache = new WeakMap<HitItem, ParsedPlainRecord>();
const plainProbeCache = new WeakMap<HitItem, PlainRowProbe>();

export { getCachedLogProbe };

export function getCachedParsedLog(item: HitItem): ParsedLogRecord {
  let cached = parsedLogCache.get(item);
  if (cached) return cached;
  cached = parseLogLine(item.text) ?? buildFallbackParsedLog(item);
  parsedLogCache.set(item, cached);
  return cached;
}

export function getCachedPlainMeta(item: HitItem): ParsedPlainRecord {
  let cached = plainMetaCache.get(item);
  if (cached) return cached;
  cached = parsePlainHitMeta(item);
  plainMetaCache.set(item, cached);
  return cached;
}

export function getCachedPlainProbe(item: HitItem, budget: number): PlainRowProbe {
  let cached = plainProbeCache.get(item);
  if (cached && cached.budget === budget) return cached;
  cached = {
    budget,
    cols: estimatePlainColumns(item.text, budget),
  };
  plainProbeCache.set(item, cached);
  return cached;
}

export function resolveSourceForHit(
  file: string,
  sourceByName: ReadonlyMap<string, DataSourceItem>
): DataSourceItem | undefined {
  const slash = file.indexOf('/');
  if (slash <= 0) return undefined;
  return sourceByName.get(file.slice(0, slash).toLowerCase());
}

/**
 * Classifies a single `HitItem` against all registered `HEADLESS_ADAPTERS`,
 * returning the highest-scoring adapter ID (ties broken by lowest `order`, fallback `'plain'`).
 */
export function classifyHitBestAdapter(item: HitItem, source?: DataSourceItem): ViewAdapterId {
  let bestId: ViewAdapterId = 'plain';
  let bestScore = -1;
  let bestOrder = Number.MAX_SAFE_INTEGER;

  for (let i = 0; i < HEADLESS_ADAPTERS.length; i++) {
    const adapter = HEADLESS_ADAPTERS[i];
    const score = adapter.classifyHit(item, source);
    if (score > bestScore || (score === bestScore && adapter.order < bestOrder)) {
      bestScore = score;
      bestOrder = adapter.order;
      bestId = adapter.id;
    }
  }
  return bestId;
}

export function resolveHitAdapterId(
  item: HitItem,
  source: DataSourceItem | undefined,
  preference: ViewModePreference
): ViewAdapterId {
  if (preference !== 'auto') {
    return preference;
  }
  return classifyHitBestAdapter(item, source);
}

/**
 * Samples up to 64 hits (first 32 + 32 strided across the tail) in bounded O(1) time
 * to determine the dominant surface adapter and whether mixed data shapes are present.
 */
export function resolveBatchAdapterSummary(
  hits: readonly HitItem[],
  sourceByName: ReadonlyMap<string, DataSourceItem>,
  preference: ViewModePreference
): AdapterBatchSummary {
  const hLen = hits.length;
  const sampleCounts: Record<ViewAdapterId, number> = {
    log: 0,
    code: 0,
    plain: 0,
  };

  if (hLen === 0) {
    return {
      activeAdapter: preference === 'auto' ? 'plain' : preference,
      detectedDominant: 'plain',
      isMixed: false,
      sampleCount: 0,
      sampleCounts,
    };
  }

  let lastFile = '';
  let lastSrc: DataSourceItem | undefined = undefined;
  let sampleCount = 0;

  const tally = (it: HitItem) => {
    if (it.file !== lastFile) {
      lastFile = it.file;
      lastSrc = resolveSourceForHit(lastFile, sourceByName);
    }
    const id = classifyHitBestAdapter(it, lastSrc);
    sampleCounts[id] += 1;
    sampleCount += 1;
  };

  const headEnd = Math.min(32, hLen);
  for (let i = 0; i < headEnd; i++) {
    tally(hits[i]);
  }
  if (hLen > 32) {
    const tailLen = hLen - 32;
    const tailSamples = Math.min(32, tailLen);
    for (let s = 0; s < tailSamples; s++) {
      const idx = 32 + Math.floor((s * tailLen) / tailSamples);
      tally(hits[idx]);
    }
  }

  let detectedDominant: ViewAdapterId = 'plain';
  const structuredCount = sampleCounts.log + sampleCounts.code;
  const topStructuredCount = Math.max(sampleCounts.log, sampleCounts.code);
  if (
    structuredCount > 0 &&
    (topStructuredCount * 100 >= sampleCount * 35 || structuredCount * 2 >= sampleCount)
  ) {
    detectedDominant = sampleCounts.log >= sampleCounts.code ? 'log' : 'code';
  }

  return {
    activeAdapter: preference === 'auto' ? detectedDominant : preference,
    detectedDominant,
    isMixed: sampleCounts.log > 0 && sampleCounts.code > 0,
    sampleCount,
    sampleCounts,
  };
}

export function resolveDominantAdapter(
  hits: readonly HitItem[],
  sourceByName: ReadonlyMap<string, DataSourceItem>,
  preference: ViewModePreference
): ViewAdapterId {
  return resolveBatchAdapterSummary(hits, sourceByName, preference).activeAdapter;
}

const ORDERED_LEVELS: readonly { level: LogLevel; badge: string }[] = [
  { level: 'fatal', badge: 'FTL' },
  { level: 'error', badge: 'ERR' },
  { level: 'warn', badge: 'WRN' },
  { level: 'info', badge: 'INF' },
  { level: 'debug', badge: 'DBG' },
  { level: 'trace', badge: 'TRC' },
];

const EMPTY_STATS: LogStreamStats = {
  totalScanned: 0,
  logCount: 0,
  levels: [],
  topCategories: [],
};

/**
 * Incremental O(delta) log stream statistics tracker for `LogSummaryStrip`.
 * Processes only newly appended chunks using O(1) `probeLogLineFast` (zero JSON.parse).
 */
export class LogStreamStatsTracker {
  private firstHitRef: HitItem | null = null;
  private scannedLen = 0;
  private logCount = 0;
  private lastPreference: ViewModePreference = 'auto';
  private lastSourceByName: ReadonlyMap<string, DataSourceItem> | null = null;
  private levelCounts = new Map<LogLevel, number>();
  private levelTokens = new Map<LogLevel, string>();
  private categoryCounts = new Map<string, number>();
  private categoryTokens = new Map<string, string>();
  private cachedStats: LogStreamStats = EMPTY_STATS;

  reset(): void {
    this.firstHitRef = null;
    this.scannedLen = 0;
    this.logCount = 0;
    this.levelCounts.clear();
    this.levelTokens.clear();
    this.categoryCounts.clear();
    this.categoryTokens.clear();
    this.cachedStats = EMPTY_STATS;
  }

  update(
    hits: readonly HitItem[],
    sourceByName: ReadonlyMap<string, DataSourceItem>,
    preference: ViewModePreference
  ): LogStreamStats {
    const hLen = hits.length;
    if (hLen === 0) {
      if (this.scannedLen !== 0) {
        this.reset();
      }
      this.lastPreference = preference;
      this.lastSourceByName = sourceByName;
      return this.cachedStats;
    }

    const needReset =
      hits[0] !== this.firstHitRef ||
      hLen < this.scannedLen ||
      preference !== this.lastPreference ||
      sourceByName !== this.lastSourceByName;

    if (needReset) {
      this.reset();
      this.firstHitRef = hits[0];
      this.lastPreference = preference;
      this.lastSourceByName = sourceByName;
    }

    if (this.scannedLen === hLen) {
      return this.cachedStats;
    }

    let lastFile = '';
    let lastSrc: DataSourceItem | undefined = undefined;
    for (let i = this.scannedLen; i < hLen; i++) {
      const it = hits[i];
      if (it.file !== lastFile) {
        lastFile = it.file;
        lastSrc = resolveSourceForHit(lastFile, sourceByName);
      }
      const probe: FastLogProbe = getCachedLogProbe(it);
      const isIncluded =
        preference === 'log' ? probe.isLog : classifyHitBestAdapter(it, lastSrc) === 'log';
      if (!isIncluded) continue;

      this.logCount++;

      if (probe.level !== 'unknown') {
        this.levelCounts.set(probe.level, (this.levelCounts.get(probe.level) ?? 0) + 1);
        if (probe.levelFilterToken && !this.levelTokens.has(probe.level)) {
          this.levelTokens.set(probe.level, probe.levelFilterToken);
        }
      }

      if (probe.category) {
        this.categoryCounts.set(
          probe.category,
          (this.categoryCounts.get(probe.category) ?? 0) + 1
        );
        if (probe.categoryFilterToken && !this.categoryTokens.has(probe.category)) {
          this.categoryTokens.set(probe.category, probe.categoryFilterToken);
        }
      }
    }

    this.scannedLen = hLen;

    const levels: LogLevelStat[] = [];
    for (const entry of ORDERED_LEVELS) {
      const count = this.levelCounts.get(entry.level) ?? 0;
      if (count > 0) {
        levels.push({
          level: entry.level,
          badge: entry.badge,
          count,
          filterToken: this.levelTokens.get(entry.level) ?? entry.level,
        });
      }
    }

    const topCategories: LogCategoryStat[] = Array.from(this.categoryCounts.entries())
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, 4)
      .map(([category, count]) => ({
        category,
        count,
        filterToken: this.categoryTokens.get(category) ?? category,
      }));

    this.cachedStats = {
      totalScanned: hLen,
      logCount: this.logCount,
      levels,
      topCategories,
    };
    return this.cachedStats;
  }
}

/**
 * Checks whether all active text query terms appear inside `text` (so log rows know
 * whether the search match is already visible in the headline/category or needs an excerpt).
 */
export function doesTextContainActiveQuery(
  text: string,
  primaryPattern: string,
  contains: readonly string[],
  isRegexMode: boolean
): boolean {
  const primary = primaryPattern.trim();
  if (!primary && contains.length === 0) {
    return true;
  }
  if (!text) return false;

  let lowerText: string | null = null;
  const getLower = () => {
    if (lowerText === null) lowerText = text.toLowerCase();
    return lowerText;
  };

  if (primary) {
    const pSpans = collectTermSpans(text, getLower, primary, isRegexMode, true);
    if (pSpans.length === 0) return false;
  }
  for (let i = 0; i < contains.length; i++) {
    const term = contains[i].trim();
    if (!term) continue;
    const cSpans = collectTermSpans(text, getLower, term, isRegexMode, true);
    if (cSpans.length === 0) return false;
  }
  return true;
}
