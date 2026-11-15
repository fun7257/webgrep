import type { DataSourceItem, ScopeFilter, SourceKind } from './types.ts';

export type SourceKindFilter = 'all' | 'dir' | 'file' | 'docker';

export function normalizeSourceKind(kind: SourceKind): Exclude<SourceKindFilter, 'all'> {
  if (kind === 'docker') return 'docker';
  if (kind === 'file') return 'file';
  return 'dir';
}

function matchesSourceRef(src: DataSourceItem, ref: string): boolean {
  if (src.id === ref) return true;
  return src.name.toLowerCase() === ref.toLowerCase();
}

export function isSourceRefInList(src: DataSourceItem, refs: readonly string[]): boolean {
  for (const r of refs) {
    if (matchesSourceRef(src, r)) return true;
  }
  return false;
}

export interface ScopeSourceSummary {
  mode: 'all' | 'single' | 'multi' | 'excluded' | 'mixed';
  singleSource: DataSourceItem | null;
  selectedCount: number;
  excludedCount: number;
}

/** Resolves the summary label/mode shown on the single source ScopeBar pill. */
export function resolveScopeSourceSummary(
  sources: readonly DataSourceItem[],
  selectedIds: readonly string[],
  excludedIds: readonly string[]
): ScopeSourceSummary {
  const selectedCount = selectedIds.length;
  const excludedCount = excludedIds.length;
  if (selectedCount === 0 && excludedCount === 0) {
    return { mode: 'all', singleSource: null, selectedCount: 0, excludedCount: 0 };
  }
  if (selectedCount === 1 && excludedCount === 0) {
    const singleSource = sources.find((s) => matchesSourceRef(s, selectedIds[0])) ?? null;
    return { mode: 'single', singleSource, selectedCount: 1, excludedCount: 0 };
  }
  if (selectedCount > 1 && excludedCount === 0) {
    return { mode: 'multi', singleSource: null, selectedCount, excludedCount: 0 };
  }
  if (selectedCount === 0 && excludedCount > 0) {
    return { mode: 'excluded', singleSource: null, selectedCount: 0, excludedCount };
  }
  return { mode: 'mixed', singleSource: null, selectedCount, excludedCount };
}

/** Pure single-click pill toggle: switches straight to `id`, or clears back to All if already sole selection. */
export function applySingleSourceSelection(
  scope: Pick<ScopeFilter, 'sources' | 'excludedSources'>,
  id: string
): { sources: string[]; excludedSources: string[] } {
  const curSources = scope.sources;
  const curExcluded = scope.excludedSources ?? [];
  if (curSources.length === 1 && curSources[0] === id && curExcluded.length === 0) {
    return { sources: [], excludedSources: [] };
  }
  return { sources: [id], excludedSources: [] };
}

/** Toggles `id` in multi-select inclusion list and ensures it is removed from `excludedSources`. */
export function toggleMultiSourceSelection(
  scope: Pick<ScopeFilter, 'sources' | 'excludedSources'>,
  id: string
): { sources: string[]; excludedSources: string[] } {
  const curSources = scope.sources;
  const nextSources = curSources.includes(id)
    ? curSources.filter((x) => x !== id)
    : [...curSources, id];
  const nextExcluded = (scope.excludedSources ?? []).filter((x) => x !== id);
  return { sources: nextSources, excludedSources: nextExcluded };
}

/** Toggles `id` in exclusion list and ensures it is removed from `sources`. */
export function toggleExcludeSourceSelection(
  scope: Pick<ScopeFilter, 'sources' | 'excludedSources'>,
  id: string
): { sources: string[]; excludedSources: string[] } {
  const curExcluded = scope.excludedSources ?? [];
  const nextExcluded = curExcluded.includes(id)
    ? curExcluded.filter((x) => x !== id)
    : [...curExcluded, id];
  const nextSources = scope.sources.filter((x) => x !== id);
  return { sources: nextSources, excludedSources: nextExcluded };
}

export function countSourcesByKind(
  sources: readonly DataSourceItem[]
): Record<SourceKindFilter, number> {
  const counts: Record<SourceKindFilter, number> = {
    all: sources.length,
    dir: 0,
    file: 0,
    docker: 0,
  };
  for (const s of sources) {
    counts[normalizeSourceKind(s.kind)] += 1;
  }
  return counts;
}

/** Filters sources by kind & search text; enabled sources stay first while preserving relative order. */
export function filterSourcesForPicker(
  sources: readonly DataSourceItem[],
  kind: SourceKindFilter,
  query: string
): DataSourceItem[] {
  const q = query.trim().toLowerCase();
  const enabledList: DataSourceItem[] = [];
  const disabledList: DataSourceItem[] = [];

  for (const s of sources) {
    if (kind !== 'all' && normalizeSourceKind(s.kind) !== kind) continue;
    if (q) {
      const hay = `${s.name}\0${s.path}\0${s.summary}\0${s.config?.endpoint ?? ''}`.toLowerCase();
      if (!hay.includes(q)) continue;
    }
    if (s.enabled) {
      enabledList.push(s);
    } else {
      disabledList.push(s);
    }
  }

  return [...enabledList, ...disabledList];
}
