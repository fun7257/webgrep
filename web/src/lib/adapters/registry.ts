import type { DataSourceItem, HitItem, ViewAdapterId, ViewModePreference } from '../types.ts';
import { codeAdapter } from './code-adapter.ts';
import { logAdapter, parseLineLogMeta } from './log-adapter.ts';
import { getCachedLogProbe } from './log-parser.ts';
import { estimatePlainColumns, parsePlainHitMeta, plainAdapter } from './plain-adapter.ts';
import type {
  AdapterBatchSummary,
  HeadlessAdapter,
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
  cached = parseLineLogMeta(item);
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
