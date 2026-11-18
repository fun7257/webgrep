import type {
  DataSourceItem,
  HitItem,
  QueryStep,
  ScopeFilter,
  SearchMode,
  TimePreset,
  WsSearchMessage,
} from '../types.ts';
import {
  buildQueryCacheKeys,
  compileSearchQuery,
  createQueryStep,
  normalizeStep,
  parseTimeModifierSpec,
  stepsEqual,
  type CompiledSearchQuery,
  type QueryCacheKeys,
} from '../query.ts';
import { computeSourcePluginsSig, resolveSourcePluginPreset } from '../prefilter.ts';
import { buildShareReplayUrl, resolvePinnedShareTime } from '../share.ts';

export interface ExecutedQuerySnapshot {
  steps: QueryStep[];
  draft: QueryStep | null;
  sources: string[];
  excludedSources: string[];
  timePreset: TimePreset;
  timeStartMs: number;
  timeEndMs: number;
  executedAtMs: number;
  hidden: boolean;
  respectIgnore: boolean;
  maxResults: number;
}

/** Resolves a source name (case-insensitive) or ID to its canonical source ID when present. */
export function resolveSourceIdOrName(
  sources: ReadonlyArray<Pick<DataSourceItem, 'id' | 'name'>>,
  nameOrId: string
): string {
  const match = sources.find(
    (s) => s.id === nameOrId || s.name.toLowerCase() === nameOrId.toLowerCase()
  );
  return match ? match.id : nameOrId;
}

/** Converts source IDs to portable unique source names (falling back to IDs on collision). */
export function toPortableSourceRefs(
  sources: ReadonlyArray<Pick<DataSourceItem, 'id' | 'name'>>,
  sourceById: ReadonlyMap<string, Pick<DataSourceItem, 'id' | 'name'>>,
  ids: readonly string[]
): string[] {
  return ids.map((id) => {
    const src = sourceById.get(id);
    if (!src) return id;
    const lowerName = src.name.toLowerCase();
    const sameNameCount = sources.reduce(
      (acc, item) => acc + (item.name.toLowerCase() === lowerName ? 1 : 0),
      0
    );
    return sameNameCount === 1 ? src.name : id;
  });
}

/** Returns true when two string lists contain the same elements regardless of order. */
export function sameSourceList(a: readonly string[], b: readonly string[]): boolean {
  if (a.length !== b.length) return false;
  const sa = [...a].sort();
  const sb = [...b].sort();
  for (let i = 0; i < sa.length; i++) {
    if (sa[i] !== sb[i]) return false;
  }
  return true;
}

/** Deduplicates include/exclude source lists with excluded IDs taking precedence. */
export function normalizeScopeSourceLists(
  sources: readonly string[],
  excludedSources: readonly string[] = []
): { sources: string[]; excludedSources: string[] } {
  const nextExcludedSet = new Set(excludedSources);
  const nextSources = Array.from(new Set(sources)).filter((id) => !nextExcludedSet.has(id));
  const nextExcluded = Array.from(nextExcludedSet);
  return { sources: nextSources, excludedSources: nextExcluded };
}

/** Resolves explicit scope source selections, or falls back to all enabled source IDs. */
export function computeEffectiveSourceIds(
  sources: ReadonlyArray<Pick<DataSourceItem, 'id' | 'enabled'>>,
  selectedSources: readonly string[]
): string[] {
  if (selectedSources.length > 0) {
    return [...selectedSources];
  }
  return sources.filter((s) => s.enabled).map((s) => s.id);
}

/** Computes active DataSourceItem objects matching the current include/exclude ScopeFilter. */
export function computeActiveSources(
  sources: readonly DataSourceItem[],
  scope: Pick<ScopeFilter, 'sources' | 'excludedSources'>
): DataSourceItem[] {
  const excluded = new Set(scope.excludedSources ?? []);
  if (scope.sources.length > 0) {
    const selected = new Set(scope.sources);
    return sources.filter(
      (s) =>
        (selected.has(s.id) || selected.has(s.name)) &&
        !excluded.has(s.id) &&
        !excluded.has(s.name)
    );
  }
  return sources.filter(
    (s) => s.enabled && !excluded.has(s.id) && !excluded.has(s.name)
  );
}

/** Determines whether a source resolves time filtering via line content timestamps. */
export function isContentTimeSource(source: DataSourceItem): boolean {
  const preset = resolveSourcePluginPreset(source);
  if (preset === 'code') return false;
  if (preset === 'timeseries') return true;
  if (source.config?.timeFormat !== undefined && source.config?.timeFormat !== null) {
    const tf = source.config.timeFormat.trim();
    if (tf.length > 0) return true;
  }
  return source.kind === 'docker' || preset === 'auto';
}

export function computeTimeBasisSummary(
  activeSources: readonly DataSourceItem[]
): { contentCount: number; mtimeCount: number } {
  let contentCount = 0;
  let mtimeCount = 0;
  for (const s of activeSources) {
    if (isContentTimeSource(s)) {
      contentCount += 1;
    } else {
      mtimeCount += 1;
    }
  }
  return { contentCount, mtimeCount };
}

export function computeSourceTimeFormatsSig(
  activeSources: readonly DataSourceItem[]
): string {
  return activeSources
    .filter((s) => isContentTimeSource(s))
    .map((s) => `${s.id}=${s.config?.timeFormat?.trim() || 'auto'}`)
    .sort()
    .join('|');
}

export function isDockerVirtualPath(
  sources: ReadonlyArray<Pick<DataSourceItem, 'kind' | 'name'>>,
  filePath: string
): boolean {
  const slash = filePath.indexOf('/');
  if (slash <= 0) return false;
  const prefix = filePath.slice(0, slash).toLowerCase();
  return sources.some((s) => s.kind === 'docker' && s.name.toLowerCase() === prefix);
}

/** Checks whether step `idx` can flip between `+` (include) and `-` (exclude). */
export function canToggleStepExcludeAt(
  steps: readonly QueryStep[],
  idx: number,
  draftStep: QueryStep | null,
  timePreset: TimePreset
): boolean {
  const target = steps[idx];
  if (!target) return false;
  if (target.exclude) return true;
  const otherPositiveStep = steps.some((s, i) => i !== idx && !s.exclude);
  const positiveDraft = Boolean(draftStep && !draftStep.exclude);
  return otherPositiveStep || positiveDraft || timePreset !== '';
}

export interface EditedStepState {
  steps: QueryStep[];
  pattern: string;
  caseSensitive: boolean;
  wholeWord: boolean;
  isRegex: boolean;
  draftExclude: boolean;
}

/** Pulls committed step `idx` back into draft state while preserving any existing draft. */
export function buildEditedStepState(
  steps: readonly QueryStep[],
  idx: number,
  draftStep: QueryStep | null,
  timePreset: TimePreset
): EditedStepState | null {
  if (idx < 0 || idx >= steps.length) return null;
  const target = steps[idx];
  const remaining = steps.filter((_, i) => i !== idx);
  if (draftStep && !remaining.some((s) => stepsEqual(s, draftStep))) {
    remaining.push(draftStep);
  }
  const draftExclude =
    target.exclude && (remaining.some((s) => !s.exclude) || timePreset !== '');
  return {
    steps: remaining,
    pattern: target.text,
    caseSensitive: target.caseSensitive,
    wholeWord: target.wholeWord,
    isRegex: target.isRegex,
    draftExclude,
  };
}

/** Commits any pending draft step and appends a new literal include/exclude step. */
export function buildAppendedStepList(
  steps: readonly QueryStep[],
  draftStep: QueryStep | null,
  term: string,
  opts: { exclude: boolean; timePreset: TimePreset }
): QueryStep[] | null {
  const clean = term.trim();
  if (!clean) return null;
  const next = steps.slice();
  if (draftStep && !next.some((s) => stepsEqual(s, draftStep))) {
    next.push(draftStep);
  }
  const resolvedExclude = opts.exclude
    ? next.some((s) => !s.exclude) || opts.timePreset !== ''
    : false;
  const added = createQueryStep(clean, { exclude: resolvedExclude });
  if (!next.some((s) => stepsEqual(s, added))) {
    next.push(added);
  }
  return next;
}

export interface SearchRequestPlan {
  compiled: CompiledSearchQuery;
  snapshot: ExecutedQuerySnapshot;
  keys: QueryCacheKeys;
  timeStartMs: number;
  timeEndMs: number;
  buildWsPayload: (searchId: number) => WsSearchMessage;
}

/** Compiles query state into a snapshot, cache keys, and WebSocket payload factory. */
export function buildSearchRequestPlan(params: {
  steps: readonly QueryStep[];
  draftStep: QueryStep | null;
  scope: ScopeFilter;
  sources: readonly DataSourceItem[];
  tenant: string;
  mode: SearchMode;
  hidden: boolean;
  respectIgnore: boolean;
  maxResults: number;
  replayTimeRange?: { startMs: number; endMs: number };
  nowMs?: number;
  tzOffsetMin?: number;
}): SearchRequestPlan | null {
  const nowMs = params.nowMs ?? Date.now();
  const tzOffsetMin = params.tzOffsetMin ?? -new Date().getTimezoneOffset();
  const compiled = compileSearchQuery(params.steps, params.draftStep, params.scope, nowMs);
  if (!compiled.hasExecutableQuery) return null;

  const reqTimeRange =
    params.replayTimeRange ??
    (params.scope.timePreset ? parseTimeModifierSpec(params.scope.timePreset, nowMs) : null);
  const timeStartMs = reqTimeRange && reqTimeRange.startMs > 0 ? reqTimeRange.startMs : 0;
  const timeEndMs = reqTimeRange && reqTimeRange.endMs > 0 ? reqTimeRange.endMs : 0;

  const snapshot: ExecutedQuerySnapshot = {
    steps: params.steps.map(normalizeStep).filter((s) => s.text.length > 0),
    draft: params.draftStep ? createQueryStep(params.draftStep.text, params.draftStep) : null,
    sources: [...params.scope.sources],
    excludedSources: [...(params.scope.excludedSources ?? [])],
    timePreset: params.scope.timePreset,
    timeStartMs,
    timeEndMs,
    executedAtMs: nowMs,
    hidden: params.hidden,
    respectIgnore: params.respectIgnore,
    maxResults: params.maxResults,
  };

  const active = computeActiveSources(params.sources, params.scope);
  const keys = buildQueryCacheKeys({
    tenant: params.tenant,
    effectiveSources: computeEffectiveSourceIds(params.sources, params.scope.sources),
    excludedSources: params.scope.excludedSources ?? [],
    types: params.scope.types,
    timePreset: params.scope.timePreset,
    timeMode: 'source',
    tzOffsetMin,
    sourceTimeFormatsSig: computeSourceTimeFormatsSig(active),
    sourcePluginsSig: computeSourcePluginsSig(active),
    steps: compiled.activeSteps,
    contextLines: 0,
    hidden: params.hidden,
    respectIgnore: params.respectIgnore,
    maxResults: params.maxResults,
    nowMs,
  });

  return {
    compiled,
    snapshot,
    keys,
    timeStartMs,
    timeEndMs,
    buildWsPayload: (searchId: number): WsSearchMessage => ({
      type: 'search',
      id: searchId,
      tenant: params.tenant,
      pattern: compiled.primaryPattern,
      mode: params.mode,
      case: 'insensitive',
      contains: compiled.contains,
      excludes: compiled.excludes,
      context: 0,
      sources: compiled.sources,
      types: compiled.types,
      globs: compiled.globs,
      fileGlobs: [],
      hidden: params.hidden,
      respectIgnore: params.respectIgnore,
      maxResults: params.maxResults,
      nearbyLines: 0,
      timeStartMs: timeStartMs > 0 ? timeStartMs : undefined,
      timeEndMs: timeEndMs > 0 ? timeEndMs : undefined,
      timeMode: 'source',
      tzOffsetMin,
    }),
  };
}

/** Builds a portable `?share=` replay URL from the active snapshot and inspected record. */
export function buildWorkbenchShareUrl(params: {
  baseHref: string;
  hasSearchedOnce: boolean;
  lastExecutedSnapshot: ExecutedQuerySnapshot | null;
  steps: readonly QueryStep[];
  draftStep: QueryStep | null;
  scope: ScopeFilter;
  displayedTimeStartMs: number;
  hidden: boolean;
  respectIgnore: boolean;
  maxResults: number;
  inspectedHit: HitItem | null;
  activeHit: HitItem | null;
  inspectedPath: string | null;
  inspectedLine: number;
  flatHits: readonly HitItem[];
  sources: readonly DataSourceItem[];
  sourceById: ReadonlyMap<string, DataSourceItem>;
  contextPrettyMode: boolean;
  inspectorRaw: boolean;
  openContext: boolean;
  mtimeCount: number;
}): string {
  const snap: ExecutedQuerySnapshot =
    params.hasSearchedOnce && params.lastExecutedSnapshot
      ? params.lastExecutedSnapshot
      : {
          steps: params.steps.map(normalizeStep).filter((s) => s.text.length > 0),
          draft: params.draftStep,
          sources: [...params.scope.sources],
          excludedSources: [...(params.scope.excludedSources ?? [])],
          timePreset: params.scope.timePreset,
          timeStartMs: params.displayedTimeStartMs,
          timeEndMs: 0,
          executedAtMs: Date.now(),
          hidden: params.hidden,
          respectIgnore: params.respectIgnore,
          maxResults: params.maxResults,
        };

  const pinned = resolvePinnedShareTime(
    snap.timePreset,
    snap.timeStartMs,
    snap.timeEndMs,
    snap.executedAtMs,
    params.mtimeCount > 0
  );

  const previewHit = params.inspectedHit ?? params.activeHit;
  const anchorPath = params.inspectedPath;
  const anchorLine =
    anchorPath && previewHit && previewHit.file === anchorPath
      ? previewHit.line
      : params.inspectedLine;
  const matchingHit =
    anchorPath && previewHit && previewHit.file === anchorPath && previewHit.line === anchorLine
      ? previewHit
      : anchorPath
        ? params.flatHits.find((h) => h.file === anchorPath && h.line === anchorLine) ?? null
        : null;
  const anchorByte =
    matchingHit && typeof matchingHit.byteOffset === 'number' ? matchingHit.byteOffset : null;

  return buildShareReplayUrl(params.baseHref, {
    steps: snap.steps.map((s) => createQueryStep(s.text, s)),
    draft: snap.draft ? createQueryStep(snap.draft.text, snap.draft) : null,
    sources: toPortableSourceRefs(params.sources, params.sourceById, snap.sources),
    excludedSources: toPortableSourceRefs(params.sources, params.sourceById, snap.excludedSources),
    timePreset: pinned.timePreset,
    timeStartMs: pinned.timeStartMs,
    timeEndMs: pinned.timeEndMs,
    hidden: snap.hidden,
    respectIgnore: snap.respectIgnore,
    maxResults: snap.maxResults,
    contextPath: anchorPath,
    contextAnchorLine: anchorLine,
    contextAnchorByte: anchorByte,
    contextPretty: params.contextPrettyMode,
    inspectorRaw: params.inspectorRaw,
    openContext: params.openContext,
  });
}
