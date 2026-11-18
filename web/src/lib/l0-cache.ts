import type { FileHitGroup, HitItem } from './types.ts';

export const MAX_L0_ENTRIES = 24;
export const MAX_L0_SINGLE_ROWS = 20_000;
export const MAX_L0_TOTAL_ROWS = 50_000;
export const L0_TTL_MS = 30_000;

export interface L0CacheEntry {
  exactKey: string;
  baseKey: string;
  sourceRevision: number;
  storedAt: number;
  timeStartMs: number;
  fileGroups: FileHitGroup[];
  flatHits: HitItem[];
  filesSearched: number;
  filesMatched: number;
  totalMatches: number;
  matchedLines: number;
  bytesSearched: number;
  filesPruned: number;
  bytesSaved: number;
  limitHit: boolean;
}

export interface InflightCacheMeta {
  exactKey: string;
  baseKey: string;
  sourceRevision: number;
  hadDraft: boolean;
  maxResults: number;
  timeStartMs: number;
}

export class L0StepCache {
  sourceRevision = 1;
  private entries = new Map<string, L0CacheEntry>();
  private totalRows = 0;

  get size(): number {
    return this.entries.size;
  }

  invalidate() {
    this.sourceRevision += 1;
    this.entries.clear();
    this.totalRows = 0;
  }

  private deleteEntry(key: string, entry: L0CacheEntry) {
    this.entries.delete(key);
    this.totalRows = Math.max(0, this.totalRows - entry.flatHits.length);
  }

  findValid(
    exactKey: string,
    baseKey: string,
    maxResults: number,
    nowMs = Date.now()
  ): L0CacheEntry | null {
    const exact = this.entries.get(exactKey);
    if (exact) {
      if (exact.sourceRevision === this.sourceRevision && nowMs - exact.storedAt <= L0_TTL_MS) {
        this.entries.delete(exactKey);
        this.entries.set(exactKey, exact);
        return exact;
      }
      this.deleteEntry(exactKey, exact);
    }

    for (const [k, entry] of this.entries) {
      if (
        entry.baseKey === baseKey &&
        !entry.limitHit &&
        maxResults >= entry.flatHits.length &&
        entry.sourceRevision === this.sourceRevision &&
        nowMs - entry.storedAt <= L0_TTL_MS
      ) {
        this.entries.delete(k);
        this.entries.set(k, entry);
        return entry;
      }
    }
    return null;
  }

  put(
    meta: InflightCacheMeta,
    snapshot: Omit<L0CacheEntry, 'exactKey' | 'baseKey' | 'sourceRevision' | 'storedAt' | 'timeStartMs'>,
    nowMs = Date.now()
  ) {
    if (meta.sourceRevision !== this.sourceRevision) return;
    const rowCount = snapshot.flatHits.length;
    if (rowCount > MAX_L0_SINGLE_ROWS) return;

    const existing = this.entries.get(meta.exactKey);
    if (existing) {
      this.deleteEntry(meta.exactKey, existing);
    }

    while (
      this.entries.size > 0 &&
      (this.entries.size >= MAX_L0_ENTRIES || this.totalRows + rowCount > MAX_L0_TOTAL_ROWS)
    ) {
      const oldest = this.entries.entries().next().value;
      if (!oldest) break;
      this.deleteEntry(oldest[0], oldest[1]);
    }

    if (this.totalRows + rowCount > MAX_L0_TOTAL_ROWS) return;

    const entry: L0CacheEntry = {
      exactKey: meta.exactKey,
      baseKey: meta.baseKey,
      sourceRevision: meta.sourceRevision,
      storedAt: nowMs,
      timeStartMs: meta.timeStartMs,
      ...snapshot,
    };
    this.entries.set(meta.exactKey, entry);
    this.totalRows += rowCount;
  }
}
