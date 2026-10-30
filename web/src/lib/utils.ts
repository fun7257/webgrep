import { type ClassValue, clsx } from 'clsx';
import { twMerge } from 'tailwind-merge';
import type { HitItem, HitSpan } from './types';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${kb.toFixed(1)} KB`;
  const mb = kb / 1024;
  if (mb < 1024) return `${mb.toFixed(2)} MB`;
  const gb = mb / 1024;
  return `${gb.toFixed(2)} GB`;
}

export function formatMs(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return '0.00 ms';
  if (ms < 1000) return `${ms.toFixed(2)} ms`;
  return `${(ms / 1000).toFixed(2)} s`;
}

export function formatThroughput(bytes: number, elapsedMs: number): string {
  if (!bytes || !elapsedMs || elapsedMs <= 0) return '';
  const bytesPerSec = (bytes / elapsedMs) * 1000;
  const mbPerSec = bytesPerSec / (1024 * 1024);
  if (mbPerSec >= 1024) {
    return `${(mbPerSec / 1024).toFixed(2)} GB/s`;
  }
  return `${mbPerSec.toFixed(0)} MB/s`;
}

const filePathCache = new Map<string, { dir: string; name: string; ext: string }>();

export function splitFilePath(filePath: string): {
  dir: string;
  name: string;
  ext: string;
} {
  const cached = filePathCache.get(filePath);
  if (cached) return cached;

  const normalized = filePath.includes('\\') ? filePath.replace(/\\/g, '/') : filePath;
  const idx = normalized.lastIndexOf('/');
  const dir = idx >= 0 ? normalized.slice(0, idx + 1) : '';
  const name = idx >= 0 ? normalized.slice(idx + 1) : normalized;
  const dotIdx = name.lastIndexOf('.');
  const ext = dotIdx > 0 ? name.slice(dotIdx + 1).toLowerCase() : '';
  const result = { dir, name, ext };

  if (filePathCache.size > 4096) {
    filePathCache.clear();
  }
  filePathCache.set(filePath, result);
  return result;
}

export const KNOWN_FILE_TYPES: {
  id: string;
  label: string;
  color: string;
}[] = [
  { id: 'zig', label: 'zig', color: 'text-muted-foreground border-border bg-secondary' },
  { id: 'ts', label: 'ts', color: 'text-muted-foreground border-border bg-secondary' },
  { id: 'js', label: 'js', color: 'text-muted-foreground border-border bg-secondary' },
  { id: 'json', label: 'json', color: 'text-muted-foreground border-border bg-secondary' },
  { id: 'md', label: 'md', color: 'text-muted-foreground border-border bg-secondary' },
  { id: 'py', label: 'py', color: 'text-muted-foreground border-border bg-secondary' },
  { id: 'rust', label: 'rust', color: 'text-muted-foreground border-border bg-secondary' },
  { id: 'go', label: 'go', color: 'text-muted-foreground border-border bg-secondary' },
  { id: 'html', label: 'html', color: 'text-muted-foreground border-border bg-secondary' },
  { id: 'css', label: 'css', color: 'text-muted-foreground border-border bg-secondary' },
  { id: 'toml', label: 'toml', color: 'text-muted-foreground border-border bg-secondary' },
  { id: 'yaml', label: 'yaml', color: 'text-muted-foreground border-border bg-secondary' },
];

export interface HighlightSegment {
  text: string;
  kind: 'plain' | 'primary' | 'contains-0' | 'contains-1' | 'contains-2';
}

function collectTermSpans(
  text: string,
  lowerText: string | null,
  rawTerm: string,
  defaultRegexMode: boolean,
  defaultCaseInsensitive: boolean
): { start: number; end: number }[] {
  const term = rawTerm.trim();
  if (!term) return [];
  const len = text.length;
  const out: { start: number; end: number }[] = [];

  const scopedMatch =
    /^\$([a-zA-Z.*]+)\(([\s\S]*)\)$/.exec(term) ??
    /^\$([a-zA-Z.*]+)\(([\s\S]*)$/.exec(term);
  const isScoped = Boolean(scopedMatch && scopedMatch[2].length > 0);

  if (isScoped || defaultRegexMode) {
    const mods = isScoped ? scopedMatch![1].toLowerCase() : '';
    const rawInner = isScoped ? scopedMatch![2] : term;
    const isScopedRegex =
      !isScoped || mods.includes('r') || mods === '.*' || mods === 're' || mods === 'regex';
    const isCaseSensitive =
      (mods.includes('c') || mods === 'case' || mods === 'aa' || mods === 's') &&
      !mods.includes('i');
    const useCaseInsensitive = mods.includes('i')
      ? true
      : isCaseSensitive
        ? false
        : defaultCaseInsensitive;
    const isWholeWord =
      mods.includes('w') || mods === 'word' || mods === 'b' || mods === '\\b';

    const basePattern = isScopedRegex
      ? rawInner
      : rawInner.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

    const tryRegex = (patternStr: string): boolean => {
      if (!patternStr) return false;
      const regexPattern = isWholeWord ? `\\b(?:${patternStr})\\b` : patternStr;
      try {
        const re = new RegExp(regexPattern, useCaseInsensitive ? 'gi' : 'g');
        let m: RegExpExecArray | null;
        while ((m = re.exec(text)) !== null) {
          if (m[0].length === 0) {
            re.lastIndex++;
            continue;
          }
          out.push({ start: m.index, end: m.index + m[0].length });
        }
        return out.length > 0;
      } catch {
        return false;
      }
    };

    if (tryRegex(basePattern)) {
      return out;
    }
    if (isScoped) {
      return out;
    }
  }

  const hay = defaultCaseInsensitive ? (lowerText ?? text.toLowerCase()) : text;
  const searchLiteral = (candidateTerm: string): boolean => {
    const needle = defaultCaseInsensitive ? candidateTerm.toLowerCase() : candidateTerm;
    if (!needle) return false;
    let pos = 0;
    while (pos < len) {
      const found = hay.indexOf(needle, pos);
      if (found === -1) break;
      out.push({ start: found, end: found + needle.length });
      pos = found + Math.max(1, needle.length);
    }
    return out.length > 0;
  };

  if (searchLiteral(term)) {
    return out;
  }
  if (term.includes('"') || term.includes("'")) {
    const strippedQuotes = term.replace(/^["']+|["']+$/g, '').replace(/["']/g, '');
    if (strippedQuotes && strippedQuotes !== term) {
      searchLiteral(strippedQuotes);
    }
  }
  return out;
}

/**
 * Splits a line of text into highlighted segments using UTF-16 `spans` from libwebgrep
 * (or `primaryPattern` when formatting structured JSON/KV) and secondary `contains` terms.
 */
export function buildHighlightSegments(
  text: string,
  primarySpans: HitSpan[] | undefined,
  containsTerms: string[] = [],
  caseInsensitive = true,
  windowAroundMatch = false,
  primaryPattern = '',
  isRegexMode = false
): HighlightSegment[] {
  if (!text) return [{ text: '', kind: 'plain' }];
  const len = text.length;

  interface TaggedSpan {
    start: number;
    end: number;
    kind: HighlightSegment['kind'];
    priority: number;
  }

  const allSpans: TaggedSpan[] = [];
  let lowerText: string | null = null;
  const getLower = () => {
    if (lowerText === null) lowerText = text.toLowerCase();
    return lowerText;
  };

  if (primarySpans && primarySpans.length > 0) {
    for (const s of primarySpans) {
      const start = Math.max(0, Math.min(len, s.start));
      const end = Math.max(start, Math.min(len, s.end));
      if (end > start) {
        allSpans.push({ start, end, kind: 'primary', priority: 0 });
      }
    }
  } else if (primaryPattern.trim().length > 0) {
    const pSpans = collectTermSpans(
      text,
      caseInsensitive ? getLower() : null,
      primaryPattern,
      isRegexMode,
      caseInsensitive
    );
    for (const s of pSpans) {
      allSpans.push({ start: s.start, end: s.end, kind: 'primary', priority: 0 });
    }
  }

  if (containsTerms && containsTerms.length > 0) {
    containsTerms.forEach((rawTerm, idx) => {
      const kind = `contains-${idx % 3}` as HighlightSegment['kind'];
      const cSpans = collectTermSpans(
        text,
        caseInsensitive ? getLower() : null,
        rawTerm,
        isRegexMode,
        caseInsensitive
      );
      for (const s of cSpans) {
        allSpans.push({
          start: s.start,
          end: s.end,
          kind,
          priority: idx + 1,
        });
      }
    });
  }

  if (allSpans.length === 0) {
    return [{ text, kind: 'plain' }];
  }

  // Track which highlight kinds have at least one standalone match not strictly inside a wider match
  const hasStandaloneByKind = new Set<HighlightSegment['kind']>();
  for (let i = 0; i < allSpans.length; i++) {
    const a = allSpans[i];
    const lenA = a.end - a.start;
    let strictlyInsideWider = false;
    for (let j = 0; j < allSpans.length; j++) {
      if (i === j) continue;
      const b = allSpans[j];
      if (b.kind === a.kind) continue;
      const lenB = b.end - b.start;
      if (lenB > lenA && b.start <= a.start && b.end >= a.end) {
        strictlyInsideWider = true;
        break;
      }
    }
    if (!strictlyInsideWider) {
      hasStandaloneByKind.add(a.kind);
    }
  }

  // Collect sorted unique boundary coordinates for interval resolution
  const coordSet = new Set<number>();
  for (const sp of allSpans) {
    coordSet.add(sp.start);
    coordSet.add(sp.end);
  }
  const coords = Array.from(coordSet).sort((a, b) => a - b);

  const spanBeats = (cand: TaggedSpan, best: TaggedSpan): boolean => {
    const candLen = cand.end - cand.start;
    const bestLen = best.end - best.start;
    if (candLen !== bestLen) {
      const narrower = candLen < bestLen ? cand : best;
      const narrowerWins =
        narrower.end - narrower.start >= 2 || !hasStandaloneByKind.has(narrower.kind);
      return candLen < bestLen ? narrowerWins : !narrowerWins;
    }
    return cand.priority < best.priority;
  };

  const resolved: TaggedSpan[] = [];
  for (let i = 0; i < coords.length - 1; i++) {
    const segStart = coords[i];
    const segEnd = coords[i + 1];
    if (segEnd <= segStart) continue;

    let winner: TaggedSpan | null = null;
    for (let j = 0; j < allSpans.length; j++) {
      const sp = allSpans[j];
      if (sp.start <= segStart && sp.end >= segEnd) {
        if (winner === null || spanBeats(sp, winner)) {
          winner = sp;
        }
      }
    }

    if (winner !== null) {
      const prev = resolved.length > 0 ? resolved[resolved.length - 1] : null;
      if (prev && prev.end === segStart && prev.kind === winner.kind) {
        prev.end = segEnd;
      } else {
        resolved.push({
          start: segStart,
          end: segEnd,
          kind: winner.kind,
          priority: winner.priority,
        });
      }
    }
  }

  const segments: HighlightSegment[] = [];
  if (!windowAroundMatch) {
    let pos = 0;
    for (let i = 0; i < resolved.length; i++) {
      const sp = resolved[i];
      if (sp.start > pos) {
        segments.push({
          text: text.slice(pos, sp.start),
          kind: 'plain',
        });
      }
      segments.push({ text: text.slice(sp.start, sp.end), kind: sp.kind });
      pos = sp.end;
    }
    if (pos < len) {
      segments.push({ text: text.slice(pos), kind: 'plain' });
    }
    return segments;
  }

  // Match-centered snippet windowing for virtualized ResultList rows:
  // Folds long leading/inter-match unmatched regions with ' … ' so primary and secondary
  // highlights in the middle/end of long lines are always visible inside the row viewport.
  const LEAD_THRESHOLD = 38;
  const LEAD_HEAD = 14;
  const LEAD_TAIL = 18;
  const GAP_THRESHOLD = 32;
  const GAP_SIDE = 12;
  const TAIL_MAX = 180;

  let pos = 0;
  for (let i = 0; i < resolved.length; i++) {
    const sp = resolved[i];
    if (sp.start > pos) {
      const gapLen = sp.start - pos;
      if (i === 0) {
        if (gapLen > LEAD_THRESHOLD) {
          const head = text.slice(0, LEAD_HEAD).trimEnd();
          const tail = text.slice(sp.start - LEAD_TAIL, sp.start).trimStart();
          segments.push({
            text: `${head} … ${tail}`,
            kind: 'plain',
          });
        } else {
          segments.push({
            text: text.slice(0, sp.start),
            kind: 'plain',
          });
        }
      } else if (gapLen > GAP_THRESHOLD) {
        const left = text.slice(pos, pos + GAP_SIDE);
        const right = text.slice(sp.start - GAP_SIDE, sp.start);
        segments.push({
          text: `${left} … ${right}`,
          kind: 'plain',
        });
      } else {
        segments.push({
          text: text.slice(pos, sp.start),
          kind: 'plain',
        });
      }
    }
    segments.push({ text: text.slice(sp.start, sp.end), kind: sp.kind });
    pos = sp.end;
  }

  if (pos < len) {
    const remain = len - pos;
    if (remain > TAIL_MAX) {
      segments.push({
        text: `${text.slice(pos, pos + TAIL_MAX)} …`,
        kind: 'plain',
      });
    } else {
      segments.push({
        text: text.slice(pos),
        kind: 'plain',
      });
    }
  }
  return segments;
}

const hitSegmentCache = new WeakMap<
  HitItem,
  { cacheKey: string; segments: HighlightSegment[] }
>();

/**
 * O(1) WeakMap-memoized highlight segments for virtualized HitItem rows.
 * Centers the snippet window around matched spans so highlights in the middle/end of long lines are always visible.
 */
export function getCachedHighlightSegments(
  item: HitItem,
  containsTerms: string[],
  caseInsensitive: boolean,
  cacheKey: string,
  primaryPattern = '',
  isRegexMode = false
): HighlightSegment[] {
  const existing = hitSegmentCache.get(item);
  if (existing && existing.cacheKey === cacheKey) {
    return existing.segments;
  }
  const segments = buildHighlightSegments(
    item.text,
    item.spans,
    containsTerms,
    caseInsensitive,
    true,
    primaryPattern,
    isRegexMode
  );
  hitSegmentCache.set(item, { cacheKey, segments });
  return segments;
}

export interface StructuredAnalysis {
  kind: 'json' | 'embedded-json' | 'kv' | 'long-line';
  formattedText: string;
  prefix?: string;
  suffix?: string;
  kvPairs?: { key: string; value: string }[];
  charCount: number;
}

function unescapeFormattedText(s: string): string {
  return s
    .replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '')
    .replace(/\\r\\n|\\n/g, '\n')
    .replace(/\\t/g, '  ');
}

/**
 * Beautifies a line for comfortable reading in the Inspector without deleting any user information.
 */
export function analyzeStructuredLine(text: string): StructuredAnalysis {
  const trimmed = text.trim();
  const charCount = text.length;

  // 1. Direct JSON object or array
  if (
    (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
    (trimmed.startsWith('[') && trimmed.endsWith(']'))
  ) {
    try {
      const parsed = JSON.parse(trimmed);
      const pretty = JSON.stringify(parsed, null, 2);
      return {
        kind: 'json',
        formattedText: pretty,
        charCount,
      };
    } catch {
      // fall through
    }
  }

  // 2. Embedded JSON inside a log or text line
  const firstBrace = text.indexOf('{');
  const lastBrace = text.lastIndexOf('}');
  if (firstBrace !== -1 && lastBrace > firstBrace + 1) {
    const candidate = text.slice(firstBrace, lastBrace + 1);
    try {
      const parsed = JSON.parse(candidate);
      const prefix = text.slice(0, firstBrace).trim();
      const suffix = text.slice(lastBrace + 1).trim();
      const prettyJson = JSON.stringify(parsed, null, 2);
      const parts = [prefix, prettyJson, suffix].filter((p) => p.length > 0);
      return {
        kind: 'embedded-json',
        prefix,
        formattedText: parts.join('\n\n'),
        suffix,
        charCount,
      };
    } catch {
      // fall through
    }
  }

  // 3. Key=Value pairs detection (only when the line is a pure KV log line)
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
    const kvRegex = /(?:^|[\s,;])([a-zA-Z0-9_.-]+)=("[^"]*"|'[^']*'|[^\s,;<>"']+)/g;
    const pairs: { key: string; value: string }[] = [];
    let match: RegExpExecArray | null;
    while ((match = kvRegex.exec(text)) !== null) {
      pairs.push({
        key: match[1],
        value: match[2].replace(/^["']|["']$/g, ''),
      });
    }
    if (pairs.length >= 3) {
      return {
        kind: 'kv',
        kvPairs: pairs,
        formattedText: pairs.map((p) => `${p.key}: ${p.value}`).join('\n'),
        charCount,
      };
    }
  }

  // 4. Plain text / code / log line (beautify escaped newlines/tabs only, zero deletion)
  return {
    kind: 'long-line',
    formattedText: unescapeFormattedText(text),
    charCount,
  };
}
