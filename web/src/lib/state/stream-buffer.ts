import type { FileHitGroup, FileLine, FileResponse, HitItem, WsIncomingMessage } from '../types.ts';
import {
  computeMergedContextBounds,
  mergeContextLines,
  type ContextFetchWindow,
} from '../context-window.ts';

export const MAX_FILE_CONTEXT_CACHE = 16;

const utf8Encoder = new TextEncoder();

/**
 * Checks whether a streamed hit line may have hit the backend 4096-byte truncation cap.
 * Fast-paths short strings (< 1364 UTF-16 code units cannot exceed 4092 UTF-8 bytes).
 */
export function isPossiblyTruncatedHitText(text: string): boolean {
  if (text.length < 1364) return false;
  return utf8Encoder.encode(text).length >= 4092;
}

export interface MergeHitChunksResult {
  fileGroups: FileHitGroup[];
  flatHits: HitItem[];
  addedMatches: number;
}

/**
 * Merges incoming streamed hit batches into `fileGroups` and `flatHits` using Copy-on-Write:
 * - Untouched `FileHitGroup` references stay identical.
 * - Touched groups are shallow-copied at most once per flush (`touchedGroups`).
 * - `HitItem` object references are never cloned so `WeakMap<HitItem, ...>` highlight caches stay hot.
 * - `groupIndexByFile` is updated in-place as new files arrive.
 */
export function mergeHitChunks(
  currentGroups: readonly FileHitGroup[],
  currentFlat: readonly HitItem[],
  groupIndexByFile: Map<string, number>,
  chunks: readonly (readonly HitItem[])[]
): MergeHitChunksResult {
  const nextGroups = currentGroups.slice();
  const nextFlat = currentFlat.slice();
  const touchedGroups = new Set<number>();
  let addedMatches = 0;

  for (let c = 0; c < chunks.length; c++) {
    const batch = chunks[c];
    for (let i = 0; i < batch.length; i++) {
      const item = batch[i];
      nextFlat.push(item);
      const itemMatchCount = item.isContext ? 0 : 1;
      addedMatches += itemMatchCount;
      let gIdx = groupIndexByFile.get(item.file);
      if (gIdx === undefined) {
        gIdx = nextGroups.length;
        groupIndexByFile.set(item.file, gIdx);
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

  return {
    fileGroups: nextGroups,
    flatHits: nextFlat,
    addedMatches,
  };
}

/** Copy-on-Write toggle of a single group's `collapsed` flag at `index`. */
export function toggleGroupCollapseAt(
  fileGroups: readonly FileHitGroup[],
  index: number
): FileHitGroup[] {
  if (index < 0 || index >= fileGroups.length) return fileGroups as FileHitGroup[];
  const group = fileGroups[index];
  if (!group) return fileGroups as FileHitGroup[];
  const next = fileGroups.slice();
  next[index] = { ...group, collapsed: !group.collapsed };
  return next;
}

/** Sets `collapsed` across all groups while preserving references for unchanged groups. */
export function collapseAllGroups(
  fileGroups: readonly FileHitGroup[],
  collapsed: boolean
): FileHitGroup[] {
  return fileGroups.map((g) => (g.collapsed === collapsed ? g : { ...g, collapsed }));
}

export interface NormalizedDoneTelemetry {
  elapsedMs: number;
  filesSearched?: number;
  filesMatched?: number;
  totalMatches?: number;
  matchedLines: number;
  bytesSearched?: number;
  filesPruned: number;
  bytesSaved: number;
  limitHit: boolean;
  cacheHit: string;
  searchCount: number | null;
}

/** Normalizes optional/nullable fields on a WebSocket `done` summary frame. */
export function normalizeDoneTelemetry(
  msg: Extract<WsIncomingMessage, { type: 'done' }>,
  fallbackMatchedLines: number
): NormalizedDoneTelemetry {
  return {
    elapsedMs: msg.elapsedMs ?? 0,
    filesSearched: msg.filesSearched,
    filesMatched: msg.filesMatched,
    totalMatches: msg.totalMatches,
    matchedLines: msg.matchedLines ?? fallbackMatchedLines,
    bytesSearched: msg.bytesSearched,
    filesPruned:
      typeof msg.filesPruned === 'number' && Number.isFinite(msg.filesPruned) && msg.filesPruned > 0
        ? Math.round(msg.filesPruned)
        : 0,
    bytesSaved:
      typeof msg.bytesSaved === 'number' && Number.isFinite(msg.bytesSaved) && msg.bytesSaved > 0
        ? Math.round(msg.bytesSaved)
        : 0,
    limitHit: Boolean(msg.limitHit) && String(msg.limitHit) !== 'none',
    cacheHit: msg.cacheHit ?? 'none',
    searchCount: typeof msg.searchCount === 'number' && msg.searchCount > 0 ? msg.searchCount : null,
  };
}

/** Resolves an optional byte-offset anchor from an explicit hint or matching hit item. */
export function resolveAnchorByteHint(
  anchorByteHint: number | null | undefined,
  inspectedHit: HitItem | null,
  targetPath: string,
  targetLine: number
): number | undefined {
  if (typeof anchorByteHint === 'number' && Number.isFinite(anchorByteHint) && anchorByteHint >= 0) {
    return Math.floor(anchorByteHint);
  }
  if (
    inspectedHit &&
    inspectedHit.file === targetPath &&
    inspectedHit.line === targetLine &&
    typeof inspectedHit.byteOffset === 'number'
  ) {
    return inspectedHit.byteOffset;
  }
  return undefined;
}

/** Merges an incremental before/after context page and updates total-line/EOF bounds. */
export function mergeContextBatchResult(
  existingLines: readonly FileLine[],
  existingTotalLines: number,
  existingEof: boolean,
  data: FileResponse,
  win: ContextFetchWindow,
  direction: 'before' | 'after'
): { lines: FileLine[]; totalLines: number; eof: boolean; firstByte?: number; nextByte?: number } {
  const scopedIncoming = data.lines.filter(
    (item) => item.n >= win.targetStart && item.n <= win.targetEnd
  );
  const merged = mergeContextLines(existingLines, scopedIncoming);
  const lastFetched = data.lines[data.lines.length - 1]?.n ?? 0;
  const lastKept = scopedIncoming[scopedIncoming.length - 1]?.n ?? 0;
  const reachedEnd =
    direction === 'before'
      ? existingEof || (data.eof && lastKept >= lastFetched)
      : data.eof && lastKept >= lastFetched;
  const bounds = computeMergedContextBounds(
    merged,
    Math.max(existingTotalLines, data.totalLines),
    reachedEnd
  );
  return {
    lines: merged,
    totalLines: bounds.totalLines,
    eof: bounds.eof,
    firstByte: direction === 'before' && typeof data.firstByte === 'number' ? data.firstByte : undefined,
    nextByte: direction === 'after' && typeof data.nextByte === 'number' ? data.nextByte : undefined,
  };
}

/** Builds the deterministic 16-slot file-context LRU cache key. */
export function buildFileContextCacheKey(
  tenant: string,
  filePath: string,
  targetLine: number,
  dockerEpoch: number | null,
  dockerSinceSec: number | null
): string {
  const epochPart = dockerEpoch !== null ? `\u0000${dockerEpoch}` : '';
  const sincePart = dockerSinceSec !== null ? `\u0000s=${dockerSinceSec}` : '';
  return `${tenant}\u0000${filePath}\u0000${targetLine}${epochPart}${sincePart}`;
}

export interface FileContextCacheEntry {
  sourceRevision: number;
  data: FileResponse;
}

/**
 * 16-slot LRU cache for single-record / context file windows, invalidated per `sourceRevision`.
 */
export class FileContextLruCache {
  private entries = new Map<string, FileContextCacheEntry>();
  private readonly maxEntries: number;

  constructor(maxEntries = MAX_FILE_CONTEXT_CACHE) {
    this.maxEntries = maxEntries;
  }

  get size(): number {
    return this.entries.size;
  }

  clear(): void {
    this.entries.clear();
  }

  get(cacheKey: string, line: number, sourceRevision: number): FileResponse | null {
    const cached = this.entries.get(cacheKey);
    if (!cached) return null;
    if (cached.sourceRevision !== sourceRevision) {
      this.entries.delete(cacheKey);
      return null;
    }
    if (cached.data.lines.some((l) => l.n === line)) {
      this.entries.delete(cacheKey);
      this.entries.set(cacheKey, cached);
      return cached.data;
    }
    return null;
  }

  put(cacheKey: string, data: FileResponse, sourceRevision: number): void {
    if (this.entries.has(cacheKey)) {
      this.entries.delete(cacheKey);
    } else if (this.entries.size >= this.maxEntries) {
      const oldestKey = this.entries.keys().next().value;
      if (oldestKey !== undefined) this.entries.delete(oldestKey);
    }
    this.entries.set(cacheKey, { sourceRevision, data });
  }
}
