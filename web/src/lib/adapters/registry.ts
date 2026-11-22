import { resolveSourcePluginPreset } from '../prefilter.ts';
import type { DataSourceItem, HitItem, ViewAdapterId } from '../types.ts';
import { codeAdapter } from './code-adapter.ts';
import {
  estimateLineColumns,
  logAdapter,
  parseHitFileMeta,
  parseLineLogMeta,
} from './log-adapter.ts';
import { getCachedLogProbe } from './log-parser.ts';
import type {
  HeadlessAdapter,
  LineRowProbe,
  ParsedLineMeta,
  ParsedLogRecord,
} from './types.ts';

export const HEADLESS_ADAPTERS: readonly HeadlessAdapter[] = [
  logAdapter,
  codeAdapter,
];

const ADAPTER_BY_ID = new Map<ViewAdapterId, HeadlessAdapter>(
  HEADLESS_ADAPTERS.map((a) => [a.id, a])
);

export function getHeadlessAdapter(id: ViewAdapterId): HeadlessAdapter {
  return ADAPTER_BY_ID.get(id) ?? logAdapter;
}

const parsedLogCache = new WeakMap<HitItem, ParsedLogRecord>();
const lineMetaCache = new WeakMap<HitItem, ParsedLineMeta>();
const lineProbeCache = new WeakMap<HitItem, LineRowProbe>();

export { getCachedLogProbe };

export function getCachedParsedLog(item: HitItem): ParsedLogRecord {
  let cached = parsedLogCache.get(item);
  if (cached) return cached;
  cached = parseLineLogMeta(item);
  parsedLogCache.set(item, cached);
  return cached;
}

export function getCachedPlainMeta(item: HitItem): ParsedLineMeta {
  let cached = lineMetaCache.get(item);
  if (cached) return cached;
  cached = parseHitFileMeta(item);
  lineMetaCache.set(item, cached);
  return cached;
}

export function getCachedPlainProbe(item: HitItem, budget: number): LineRowProbe {
  let cached = lineProbeCache.get(item);
  if (cached && cached.budget === budget) return cached;
  cached = {
    budget,
    cols: estimateLineColumns(item.text, budget),
  };
  lineProbeCache.set(item, cached);
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
 * Deterministic view mode bound directly to the DataSource configuration:
 * `'code'` sources render in Codebase View; `'timeseries'` (log) sources render in Log View.
 */
export function resolveSourceAdapterId(
  source?: Pick<DataSourceItem, 'pluginPreset' | 'config'>
): ViewAdapterId {
  return source && resolveSourcePluginPreset(source) === 'code' ? 'code' : 'log';
}

export function resolveHitAdapterId(
  _item: HitItem,
  source?: Pick<DataSourceItem, 'pluginPreset' | 'config'>
): ViewAdapterId {
  return resolveSourceAdapterId(source);
}

export function resolvePathAdapterId(
  file: string,
  sourceByName: ReadonlyMap<string, DataSourceItem>
): ViewAdapterId {
  return resolveSourceAdapterId(resolveSourceForHit(file, sourceByName));
}

/**
 * Resolves the active result-list presentation adapter strictly from configured DataSource modes
 * (zero content/extension auto-detection heuristics).
 */
export function resolveBatchViewAdapter(
  hits: readonly HitItem[],
  sourceByName: ReadonlyMap<string, DataSourceItem>,
  activeSources: readonly DataSourceItem[] = []
): ViewAdapterId {
  if (hits.length > 0) {
    let logCount = 0;
    let codeCount = 0;
    let lastFile = '';
    let lastAdapter: ViewAdapterId = 'log';
    const limit = Math.min(hits.length, 64);
    for (let i = 0; i < limit; i++) {
      const file = hits[i].file;
      if (file !== lastFile) {
        lastFile = file;
        lastAdapter = resolvePathAdapterId(file, sourceByName);
      }
      if (lastAdapter === 'code') codeCount++;
      else logCount++;
    }
    return codeCount > logCount ? 'code' : 'log';
  }

  if (activeSources.length > 0) {
    let codeCount = 0;
    for (const src of activeSources) {
      if (resolveSourceAdapterId(src) === 'code') codeCount++;
    }
    if (codeCount === activeSources.length) return 'code';
  }
  return 'log';
}
