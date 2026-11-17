import type { FileLine } from './types.ts';

export const DEFAULT_INITIAL_CONTEXT_LINES = 10;
export const DEFAULT_CONTEXT_STEP_LINES = 10;
export const INITIAL_CONTEXT_RADIUS = DEFAULT_INITIAL_CONTEXT_LINES;
export const CONTEXT_STEP_LINES = DEFAULT_CONTEXT_STEP_LINES;
export const MIN_CONTEXT_LINE_SETTING = 1;
export const MAX_CONTEXT_LINE_SETTING = 100;

export type ContextAutoLoadPace = 'slow' | 'normal' | 'fast';
export const DEFAULT_CONTEXT_AUTO_LOAD_PACE: ContextAutoLoadPace = 'normal';

export function normalizeContextAutoLoadPace(
  value: unknown,
  fallback: ContextAutoLoadPace = DEFAULT_CONTEXT_AUTO_LOAD_PACE
): ContextAutoLoadPace {
  return value === 'slow' || value === 'normal' || value === 'fast' ? value : fallback;
}

export function resolveContextLoadCooldownMs(pace: ContextAutoLoadPace): number {
  switch (pace) {
    case 'slow':
      return 480;
    case 'fast':
      return 90;
    case 'normal':
    default:
      return 240;
  }
}

export function clampContextLineSetting(
  value: unknown,
  fallback = DEFAULT_INITIAL_CONTEXT_LINES
): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback;
  return Math.max(
    MIN_CONTEXT_LINE_SETTING,
    Math.min(MAX_CONTEXT_LINE_SETTING, Math.round(value))
  );
}

export interface ContextFetchWindow {
  line: number;
  context: number;
  targetStart: number;
  targetEnd: number;
}

export interface MergedContextBounds {
  firstLine: number;
  lastLine: number;
  totalLines: number;
  eof: boolean;
  canLoadBefore: boolean;
  canLoadAfter: boolean;
}

/**
 * Computes an initial `/api/file` window centered on `anchorLine`.
 * Guarantees `context >= 1` so small/compressed files report exact `totalLines`.
 */
export function computeInitialFetchWindow(
  anchorLine: number,
  radius = INITIAL_CONTEXT_RADIUS
): ContextFetchWindow {
  const anchor = Math.max(1, Math.floor(anchorLine));
  const ctx = Math.min(300, Math.max(1, Math.floor(radius)));
  return {
    line: anchor,
    context: ctx,
    targetStart: Math.max(1, anchor - ctx),
    targetEnd: anchor + ctx,
  };
}

/**
 * Computes an upward `/api/file` window covering `[Math.max(1, firstLine - stepLines), firstLine - 1]`.
 * Returns `null` once line `#1` is already loaded.
 */
export function computeUpwardFetchWindow(
  firstLine: number,
  stepLines = CONTEXT_STEP_LINES
): ContextFetchWindow | null {
  const first = Math.floor(firstLine);
  if (first <= 1) return null;
  const step = Math.min(600, Math.max(1, Math.floor(stepLines)));
  const targetEnd = first - 1;
  const targetStart = Math.max(1, first - step);
  const span = targetEnd - targetStart;
  const context = Math.min(300, Math.max(1, Math.ceil(span / 2)));
  return {
    line: targetStart + context,
    context,
    targetStart,
    targetEnd,
  };
}

/**
 * Computes a downward `/api/file` window starting at `lastLine + 1`.
 * Returns `null` when EOF has already been reached or `lastLine < 1`.
 */
export function computeDownwardFetchWindow(
  lastLine: number,
  totalLines: number,
  eof: boolean,
  stepLines = CONTEXT_STEP_LINES
): ContextFetchWindow | null {
  const last = Math.floor(lastLine);
  if (eof || last < 1) return null;
  if (totalLines > 0 && last >= totalLines) return null;

  const step = Math.min(600, Math.max(1, Math.floor(stepLines)));
  const targetStart = last + 1;
  const rawEnd = last + step;
  const targetEnd = totalLines > 0 ? Math.min(totalLines, rawEnd) : rawEnd;
  if (targetEnd < targetStart) return null;

  const span = targetEnd - targetStart;
  const context = Math.min(300, Math.max(1, Math.ceil(span / 2)));
  return {
    line: targetStart + context,
    context,
    targetStart,
    targetEnd,
  };
}

function isStrictlyAscending(lines: readonly FileLine[]): boolean {
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].n <= lines[i - 1].n) return false;
  }
  return true;
}

/**
 * Merges and deduplicates context lines by 1-based line number, returning a new sorted array
 * compatible with `$state.raw` Copy-on-Write updates.
 */
export function mergeContextLines(
  existing: readonly FileLine[],
  incoming: readonly FileLine[]
): FileLine[] {
  if (existing.length === 0) {
    return isStrictlyAscending(incoming)
      ? incoming.slice()
      : [...incoming].sort((a, b) => a.n - b.n);
  }
  if (incoming.length === 0) return existing.slice();

  // O(n) fast paths for strictly disjoint upward/downward pages.
  if (incoming[incoming.length - 1].n < existing[0].n && isStrictlyAscending(incoming)) {
    return [...incoming, ...existing];
  }
  if (incoming[0].n > existing[existing.length - 1].n && isStrictlyAscending(incoming)) {
    return [...existing, ...incoming];
  }

  const byLine = new Map<number, FileLine>();
  for (let i = 0; i < existing.length; i++) {
    byLine.set(existing[i].n, existing[i]);
  }
  for (let i = 0; i < incoming.length; i++) {
    byLine.set(incoming[i].n, incoming[i]);
  }
  return Array.from(byLine.values()).sort((a, b) => a.n - b.n);
}

/**
 * Derives merged bounds and pagination availability.
 * Preserves unknown `totalLines = 0` (`!eof`) on large files/streams until true EOF is observed.
 */
export function computeMergedContextBounds(
  lines: readonly FileLine[],
  totalLines: number,
  chunkEof: boolean
): MergedContextBounds {
  if (lines.length === 0) {
    return {
      firstLine: 0,
      lastLine: 0,
      totalLines: Math.max(0, totalLines),
      eof: chunkEof,
      canLoadBefore: false,
      canLoadAfter: false,
    };
  }

  const firstLine = lines[0].n;
  const lastLine = lines[lines.length - 1].n;
  const resolvedTotal = chunkEof
    ? Math.max(totalLines, lastLine)
    : totalLines > 0
      ? Math.max(totalLines, lastLine)
      : 0;
  const eof = chunkEof || (resolvedTotal > 0 && lastLine >= resolvedTotal);

  return {
    firstLine,
    lastLine,
    totalLines: resolvedTotal,
    eof,
    canLoadBefore: firstLine > 1,
    canLoadAfter: !eof,
  };
}

export function formatContextRangeBadge(
  firstLine: number,
  lastLine: number,
  totalLines: number
): string {
  if (firstLine <= 0 || lastLine < firstLine) return '';
  const span = `${firstLine}–${lastLine}`;
  return totalLines > 0 ? `${span} / ${totalLines}` : span;
}
