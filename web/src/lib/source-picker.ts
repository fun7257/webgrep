import type { DataSourceItem, ScopeFilter, SourceKind } from './types.ts';

export type SourceKindFilter = 'all' | 'dir' | 'file';

export function normalizeSourceKind(kind: SourceKind): Exclude<SourceKindFilter, 'all'> {
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
  };
  for (const s of sources) {
    counts[normalizeSourceKind(s.kind)] += 1;
  }
  return counts;
}

export interface HighlightRange {
  start: number;
  end: number;
}

export interface HighlightSegmentPiece {
  text: string;
  match: boolean;
}

export interface FuzzyFilteredSource {
  source: DataSourceItem;
  score: number;
  nameRanges: HighlightRange[];
  subtitleRanges: HighlightRange[];
}

export function getSourceSubtitle(src: DataSourceItem): string {
  return src.summary || src.path;
}

function isWordBoundary(text: string, idx: number): boolean {
  if (idx <= 0) return true;
  const prev = text.charCodeAt(idx - 1);
  // '/' '\' '-' '_' '.' ':' ' ' '\t'
  if (
    prev === 47 ||
    prev === 92 ||
    prev === 45 ||
    prev === 95 ||
    prev === 46 ||
    prev === 58 ||
    prev === 32 ||
    prev === 9
  ) {
    return true;
  }
  const curr = text.charCodeAt(idx);
  // camelCase boundary: [a-z][A-Z]
  return prev >= 97 && prev <= 122 && curr >= 65 && curr <= 90;
}

export function mergeHighlightRanges(ranges: readonly HighlightRange[]): HighlightRange[] {
  if (ranges.length === 0) return [];
  const sorted = [...ranges]
    .filter((r) => r.end > r.start)
    .sort((a, b) => a.start - b.start || a.end - b.end);
  if (sorted.length === 0) return [];
  const merged: HighlightRange[] = [{ start: sorted[0].start, end: sorted[0].end }];
  for (let i = 1; i < sorted.length; i++) {
    const cur = sorted[i];
    const last = merged[merged.length - 1];
    if (cur.start <= last.end) {
      if (cur.end > last.end) last.end = cur.end;
    } else {
      merged.push({ start: cur.start, end: cur.end });
    }
  }
  return merged;
}

export function splitHighlightRanges(
  text: string,
  ranges: readonly HighlightRange[]
): HighlightSegmentPiece[] {
  if (!text) return [];
  if (ranges.length === 0) return [{ text, match: false }];
  const merged = mergeHighlightRanges(ranges);
  if (merged.length === 0) return [{ text, match: false }];

  const out: HighlightSegmentPiece[] = [];
  let cursor = 0;
  for (const r of merged) {
    const start = Math.max(cursor, Math.min(r.start, text.length));
    const end = Math.max(start, Math.min(r.end, text.length));
    if (start > cursor) {
      out.push({ text: text.slice(cursor, start), match: false });
    }
    if (end > start) {
      out.push({ text: text.slice(start, end), match: true });
    }
    cursor = end;
  }
  if (cursor < text.length) {
    out.push({ text: text.slice(cursor), match: false });
  }
  return out;
}

function indicesToRanges(indices: readonly number[]): HighlightRange[] {
  if (indices.length === 0) return [];
  const out: HighlightRange[] = [];
  let start = indices[0];
  let end = start + 1;
  for (let i = 1; i < indices.length; i++) {
    if (indices[i] === end) {
      end += 1;
    } else {
      out.push({ start, end });
      start = indices[i];
      end = start + 1;
    }
  }
  out.push({ start, end });
  return out;
}

/** Matches a single non-empty token against `text`, ranking contiguous substrings above fuzzy subsequences. */
export function fuzzyMatchText(
  text: string,
  token: string
): { score: number; ranges: HighlightRange[] } | null {
  if (!token) return { score: 0, ranges: [] };
  if (!text) return null;

  const hay = text.toLowerCase();
  const needle = token.toLowerCase();
  const m = needle.length;
  const n = hay.length;
  if (m > n || n !== text.length) return null;

  // 1. Contiguous substring check: prefix > word-boundary substring > inline substring
  let bestSubScore = -Infinity;
  let bestSubIdx = -1;
  let searchFrom = 0;
  while (searchFrom <= n - m) {
    const idx = hay.indexOf(needle, searchFrom);
    if (idx < 0) break;
    let s: number;
    if (idx === 0) {
      s = 200;
    } else if (isWordBoundary(text, idx)) {
      s = 165 - idx * 0.2;
    } else {
      s = 135 - idx * 0.2;
    }
    if (s > bestSubScore) {
      bestSubScore = s;
      bestSubIdx = idx;
    }
    if (idx === 0) break;
    searchFrom = idx + 1;
  }
  if (bestSubIdx >= 0) {
    return { score: bestSubScore, ranges: [{ start: bestSubIdx, end: bestSubIdx + m }] };
  }

  // 2. Fast linear subsequence pre-check
  let kCheck = 0;
  for (let i = 0; i < n && kCheck < m; i++) {
    if (hay.charCodeAt(i) === needle.charCodeAt(kCheck)) {
      kCheck += 1;
    }
  }
  if (kCheck < m) return null;

  // 3a. Exact O(m * n) DP alignment maximizing word-boundary & consecutive character bonuses
  if (m <= 32 && n <= 256) {
    const NEG_INF = -1e9;
    const boundaries = new Uint8Array(n);
    for (let j = 0; j < n; j++) {
      boundaries[j] = isWordBoundary(text, j) ? 1 : 0;
    }

    let prevRow = new Float64Array(n).fill(NEG_INF);
    const back = new Int16Array(m * n).fill(-1);

    for (let j = 0; j < n; j++) {
      if (hay.charCodeAt(j) === needle.charCodeAt(0)) {
        // Tiny tie-breaker (-j * 0.001) prefers earlier match start on equal scores
        prevRow[j] = 10 + (boundaries[j] ? 14 : 0) - j * 0.001;
      }
    }

    for (let k = 1; k < m; k++) {
      const currRow = new Float64Array(n).fill(NEG_INF);
      const targetCode = needle.charCodeAt(k);
      let runningBestVal = NEG_INF;
      let runningBestIdx = -1;

      for (let j = k; j < n; j++) {
        const pCand = prevRow[j - 1];
        if (pCand > NEG_INF / 2) {
          const adjusted = pCand + 1.5 * (j - 1);
          if (adjusted > runningBestVal) {
            runningBestVal = adjusted;
            runningBestIdx = j - 1;
          }
        }

        if (hay.charCodeAt(j) !== targetCode) continue;

        const charGain = 10 + (boundaries[j] ? 14 : 0);
        const candAdj = pCand > NEG_INF / 2 ? pCand + 16 + charGain : NEG_INF;
        const candJump =
          runningBestIdx >= 0 ? runningBestVal - 1.5 * (j - 1) + charGain : NEG_INF;

        if (candAdj >= candJump && candAdj > NEG_INF / 2) {
          currRow[j] = candAdj;
          back[k * n + j] = j - 1;
        } else if (candJump > NEG_INF / 2) {
          currRow[j] = candJump;
          back[k * n + j] = runningBestIdx;
        }
      }
      prevRow = currRow;
    }

    let bestEnd = -1;
    let bestDpScore = NEG_INF;
    for (let j = m - 1; j < n; j++) {
      if (prevRow[j] > bestDpScore) {
        bestDpScore = prevRow[j];
        bestEnd = j;
      }
    }
    if (bestEnd < 0) return null;

    const matchedIndices = new Array<number>(m);
    let cur = bestEnd;
    for (let k = m - 1; k >= 0; k--) {
      matchedIndices[k] = cur;
      cur = back[k * n + cur];
    }

    // Recompute exact score without the tiny tie-breaker offset
    const spanSkips = matchedIndices[m - 1] - matchedIndices[0] + 1 - m;
    let exactScore = 10 * m - 1.5 * spanSkips;
    for (let k = 0; k < m; k++) {
      const idx = matchedIndices[k];
      if (boundaries[idx]) exactScore += 14;
      if (k > 0 && idx === matchedIndices[k - 1] + 1) exactScore += 16;
    }
    if (exactScore <= 0) return null;

    return {
      score: exactScore,
      ranges: indicesToRanges(matchedIndices),
    };
  }

  // 3b. Greedy word-boundary fallback for oversized paths
  const greedy: number[] = [];
  let pos = 0;
  for (let k = 0; k < m; k++) {
    const ch = needle.charCodeAt(k);
    let chosen = -1;
    for (let j = pos; j < n; j++) {
      if (hay.charCodeAt(j) === ch) {
        if (chosen < 0) chosen = j;
        if (isWordBoundary(text, j) || (k > 0 && j === greedy[k - 1] + 1)) {
          chosen = j;
          break;
        }
      }
    }
    if (chosen < 0) return null;
    greedy.push(chosen);
    pos = chosen + 1;
  }

  const skips = greedy[m - 1] - greedy[0] + 1 - m;
  let greedyScore = 10 * m - 1.5 * skips;
  for (let k = 0; k < m; k++) {
    if (isWordBoundary(text, greedy[k])) greedyScore += 14;
    if (k > 0 && greedy[k] === greedy[k - 1] + 1) greedyScore += 16;
  }
  if (greedyScore <= 0) return null;

  return {
    score: greedyScore,
    ranges: indicesToRanges(greedy),
  };
}

/** Fuzzy-filters sources by kind & whitespace-separated query tokens, keeping enabled before disabled. */
export function fuzzyFilterSourcesForPicker(
  sources: readonly DataSourceItem[],
  kind: SourceKindFilter,
  query: string
): FuzzyFilteredSource[] {
  const tokens = query.trim().split(/\s+/).filter(Boolean);
  const enabledList: FuzzyFilteredSource[] = [];
  const disabledList: FuzzyFilteredSource[] = [];

  for (const s of sources) {
    if (kind !== 'all' && normalizeSourceKind(s.kind) !== kind) continue;

    if (tokens.length === 0) {
      const item: FuzzyFilteredSource = {
        source: s,
        score: 0,
        nameRanges: [],
        subtitleRanges: [],
      };
      if (s.enabled) enabledList.push(item);
      else disabledList.push(item);
      continue;
    }

    const subtitle = getSourceSubtitle(s);
    let totalScore = 0;
    const nameRanges: HighlightRange[] = [];
    const subtitleRanges: HighlightRange[] = [];
    let matchedAll = true;

    for (const tok of tokens) {
      const nameHit = fuzzyMatchText(s.name, tok);
      const subHit = fuzzyMatchText(subtitle, tok);
      const pathHit = subtitle === s.path ? subHit : fuzzyMatchText(s.path, tok);

      if (!nameHit && !subHit && !pathHit) {
        matchedAll = false;
        break;
      }

      if (nameHit) nameRanges.push(...nameHit.ranges);
      if (subHit) subtitleRanges.push(...subHit.ranges);

      const tokBest = Math.max(
        nameHit ? nameHit.score * 1.5 : -Infinity,
        subHit ? subHit.score : -Infinity,
        pathHit ? pathHit.score * 0.9 : -Infinity
      );
      totalScore += tokBest;
    }

    if (!matchedAll) continue;

    const item: FuzzyFilteredSource = {
      source: s,
      score: totalScore,
      nameRanges: mergeHighlightRanges(nameRanges),
      subtitleRanges: mergeHighlightRanges(subtitleRanges),
    };
    if (s.enabled) enabledList.push(item);
    else disabledList.push(item);
  }

  if (tokens.length > 0) {
    enabledList.sort((a, b) => b.score - a.score);
    disabledList.sort((a, b) => b.score - a.score);
  }

  return [...enabledList, ...disabledList];
}

/** Filters sources by kind & search text; enabled sources stay first while preserving relative order. */
export function filterSourcesForPicker(
  sources: readonly DataSourceItem[],
  kind: SourceKindFilter,
  query: string
): DataSourceItem[] {
  return fuzzyFilterSourcesForPicker(sources, kind, query).map((x) => x.source);
}
