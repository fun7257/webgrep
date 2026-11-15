import { type ClassValue, clsx } from 'clsx';
import { twMerge } from 'tailwind-merge';
import type { HitItem, HitSpan } from './types';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/**
 * Universal clipboard helper that works both in Secure Contexts (`https://`, `localhost`)
 * AND over remote LAN/WAN HTTP (`http://<ip>:8787`) where `navigator.clipboard` is disabled by browsers.
 */
export function copyTextToClipboard(text: string): boolean {
  if (!text || typeof document === 'undefined') return false;

  const fallbackCopy = (): boolean => {
    try {
      const prevActive = document.activeElement as HTMLElement | null;
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.top = '-9999px';
      ta.style.left = '-9999px';
      ta.style.opacity = '0';
      ta.style.pointerEvents = 'none';
      document.body.appendChild(ta);
      ta.focus({ preventScroll: true });
      ta.select();
      ta.setSelectionRange(0, text.length);
      const ok = document.execCommand('copy');
      document.body.removeChild(ta);
      prevActive?.focus?.({ preventScroll: true });
      return ok;
    } catch {
      return false;
    }
  };

  if (
    typeof window !== 'undefined' &&
    window.isSecureContext &&
    typeof navigator !== 'undefined' &&
    navigator.clipboard?.writeText
  ) {
    navigator.clipboard.writeText(text).catch(() => {
      fallbackCopy();
    });
    return true;
  }

  return fallbackCopy();
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
  const slashIdx = normalized.lastIndexOf('/');
  const sepIdx = normalized.indexOf('::');
  const splitPos = Math.max(slashIdx >= 0 ? slashIdx + 1 : 0, sepIdx >= 0 ? sepIdx + 2 : 0);
  const dir = splitPos > 0 ? normalized.slice(0, splitPos) : '';
  const name = splitPos > 0 ? normalized.slice(splitPos) : normalized;
  const dotIdx = name.lastIndexOf('.');
  const ext = dotIdx > 0 ? name.slice(dotIdx + 1).toLowerCase() : '';
  const result = { dir, name, ext };

  if (filePathCache.size > 4096) {
    filePathCache.clear();
  }
  filePathCache.set(filePath, result);
  return result;
}

export interface HighlightSegment {
  text: string;
  kind: 'plain' | 'primary' | 'contains-0' | 'contains-1' | 'contains-2';
}

interface CompiledTermMatcher {
  regex: RegExp | null;
  isScoped: boolean;
  literalNeedle: string;
  literalCaseInsensitive: boolean;
  strippedNeedle: string;
}

const MAX_TERM_MATCHER_CACHE = 256;
const termMatcherCache = new Map<string, CompiledTermMatcher>();

function compileTermMatcher(
  rawTerm: string,
  defaultRegexMode: boolean,
  defaultCaseInsensitive: boolean
): CompiledTermMatcher | null {
  const term = rawTerm.trim();
  if (!term) return null;

  const cacheKey = `${defaultRegexMode ? '1' : '0'}:${defaultCaseInsensitive ? '1' : '0'}:${term}`;
  const cached = termMatcherCache.get(cacheKey);
  if (cached) {
    termMatcherCache.delete(cacheKey);
    termMatcherCache.set(cacheKey, cached);
    return cached;
  }

  const scopedMatch =
    /^\$([a-zA-Z.*]+)\(([\s\S]*)\)$/.exec(term) ??
    /^\$([a-zA-Z.*]+)\(([\s\S]*)$/.exec(term);
  const isScoped = Boolean(scopedMatch && scopedMatch[2].length > 0);

  let regex: RegExp | null = null;
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
    if (basePattern) {
      const regexPattern = isWholeWord ? `\\b(?:${basePattern})\\b` : basePattern;
      try {
        regex = new RegExp(regexPattern, useCaseInsensitive ? 'gi' : 'g');
      } catch {
        regex = null;
      }
    }
  }

  const literalNeedle = defaultCaseInsensitive ? term.toLowerCase() : term;
  let strippedNeedle = '';
  if (!isScoped && (term.includes('"') || term.includes("'"))) {
    const stripped = term.replace(/^["']+|["']+$/g, '').replace(/["']/g, '');
    if (stripped && stripped !== term) {
      strippedNeedle = defaultCaseInsensitive ? stripped.toLowerCase() : stripped;
    }
  }

  const compiled: CompiledTermMatcher = {
    regex,
    isScoped,
    literalNeedle,
    literalCaseInsensitive: defaultCaseInsensitive,
    strippedNeedle,
  };
  if (termMatcherCache.size >= MAX_TERM_MATCHER_CACHE) {
    const oldestKey = termMatcherCache.keys().next().value;
    if (oldestKey !== undefined) termMatcherCache.delete(oldestKey);
  }
  termMatcherCache.set(cacheKey, compiled);
  return compiled;
}

function collectTermSpans(
  text: string,
  getLower: () => string,
  rawTerm: string,
  defaultRegexMode: boolean,
  defaultCaseInsensitive: boolean
): { start: number; end: number }[] {
  const matcher = compileTermMatcher(rawTerm, defaultRegexMode, defaultCaseInsensitive);
  if (!matcher) return [];
  const len = text.length;
  const out: { start: number; end: number }[] = [];

  if (matcher.regex) {
    const re = matcher.regex;
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text)) !== null) {
      if (m[0].length === 0) {
        re.lastIndex++;
        continue;
      }
      out.push({ start: m.index, end: m.index + m[0].length });
    }
    re.lastIndex = 0;
    if (out.length > 0 || matcher.isScoped) {
      return out;
    }
  } else if (matcher.isScoped) {
    return out;
  }

  const hay = matcher.literalCaseInsensitive ? getLower() : text;
  const searchLiteral = (needle: string): boolean => {
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

  if (searchLiteral(matcher.literalNeedle)) {
    return out;
  }
  if (matcher.strippedNeedle) {
    searchLiteral(matcher.strippedNeedle);
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
  isRegexMode = false,
  stripLeadingIndent = true,
  maxPreviewChars = 540
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
      getLower,
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
        getLower,
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
    if (!windowAroundMatch) {
      return [{ text, kind: 'plain' }];
    }
    const budget = Math.max(220, maxPreviewChars);
    const indent = stripLeadingIndent ? (/^\s*/.exec(text)?.[0].length ?? 0) : 0;
    const sliced = indent > 0 && indent < len ? text.slice(indent) : text;
    if (sliced.length > budget) {
      return [{ text: `${sliced.slice(0, budget)} …`, kind: 'plain' }];
    }
    return [{ text: sliced, kind: 'plain' }];
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
  // Keeps rich continuous text up to `maxPreviewChars` (1–6 lines) while folding huge
  // unmatched regions with ' … ' so matches near the middle/end of ultra-long lines stay visible.
  const budget = Math.max(220, maxPreviewChars);
  const indent = stripLeadingIndent ? (/^\s*/.exec(text)?.[0].length ?? 0) : 0;
  let pos = resolved.length === 0 || resolved[0].start >= indent ? indent : 0;
  const shouldFold = len - pos > budget;

  const LEAD_THRESHOLD = Math.max(120, Math.round(budget * 0.42));
  const LEAD_HEAD = Math.max(36, Math.round(budget * 0.14));
  const LEAD_TAIL = Math.max(64, Math.round(budget * 0.24));
  const GAP_THRESHOLD = Math.max(96, Math.round(budget * 0.32));
  const GAP_SIDE = Math.max(36, Math.round(budget * 0.14));
  const TAIL_MAX = budget;

  for (let i = 0; i < resolved.length; i++) {
    const sp = resolved[i];
    if (sp.start > pos) {
      const gapLen = sp.start - pos;
      if (!shouldFold) {
        segments.push({
          text: text.slice(pos, sp.start),
          kind: 'plain',
        });
      } else if (i === 0) {
        if (gapLen > LEAD_THRESHOLD) {
          const head = text.slice(pos, pos + LEAD_HEAD).trimEnd();
          const tail = text.slice(sp.start - LEAD_TAIL, sp.start).trimStart();
          segments.push({
            text: `${head} … ${tail}`,
            kind: 'plain',
          });
        } else {
          segments.push({
            text: text.slice(pos, sp.start),
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
    if (shouldFold && remain > TAIL_MAX) {
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

export interface NanoTimestampInfo {
  nsStr: string;
  formattedTime: string;
  fullFormattedTime: string;
  restText: string;
  prefixLen: number;
}

/**
 * Zero-allocation check for a leading 19-digit Unix nanosecond timestamp (`<19-digit-ns> <payload>`).
 * Returns the byte/UTF-16 offset where `<payload>` begins, or `0` if absent.
 */
export function skipLeadingNanoTimestampOffset(text: string): number {
  if (!text || text.length < 20) return 0;
  for (let i = 0; i < 19; i++) {
    const code = text.charCodeAt(i);
    if (code < 48 || code > 57) return 0;
  }
  const sep = text.charCodeAt(19);
  if (sep !== 32 && sep !== 9) return 0;

  let ms = 0;
  for (let i = 0; i < 13; i++) {
    ms = ms * 10 + (text.charCodeAt(i) - 48);
  }
  // Valid range: 2000-01-01 to 2100-01-01
  if (!Number.isFinite(ms) || ms < 946684800000 || ms > 4102444800000) {
    return 0;
  }

  let restStart = 20;
  while (
    restStart < text.length &&
    (text.charCodeAt(restStart) === 32 || text.charCodeAt(restStart) === 9)
  ) {
    restStart++;
  }
  return restStart;
}

/**
 * Detects a leading 19-digit Unix nanosecond timestamp (`<19-digit-ns> <payload>`)
 * in external log records and formats it into human-readable local time.
 */
export function extractLeadingNanoTimestamp(text: string): NanoTimestampInfo | null {
  const restStart = skipLeadingNanoTimestampOffset(text);
  if (restStart === 0) return null;

  const nsStr = text.slice(0, 19);
  const msNum = Number(nsStr.slice(0, 13));
  const d = new Date(msNum);
  const pad2 = (n: number) => (n < 10 ? `0${n}` : `${n}`);
  const pad3 = (n: number) => (n < 10 ? `00${n}` : n < 100 ? `0${n}` : `${n}`);
  const formattedTime = `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}.${pad3(d.getMilliseconds())}`;
  const fullFormattedTime = `${d.getFullYear()}-${formattedTime}`;

  return {
    nsStr,
    formattedTime,
    fullFormattedTime,
    restText: text.slice(restStart),
    prefixLen: restStart,
  };
}

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
  isRegexMode = false,
  maxPreviewChars = 540
): HighlightSegment[] {
  const existing = hitSegmentCache.get(item);
  if (existing && existing.cacheKey === cacheKey) {
    return existing.segments;
  }

  let targetText = item.text;
  let targetSpans: HitSpan[] | undefined = item.spans;
  const tsInfo = extractLeadingNanoTimestamp(item.text);
  if (tsInfo && tsInfo.restText.length > 0) {
    const pLen = tsInfo.prefixLen;
    const isTimeOnlyDefaultSpan =
      primaryPattern.trim().length === 0 &&
      targetSpans?.length === 1 &&
      targetSpans[0].start === 0 &&
      targetSpans[0].end <= pLen;
    const nsHay = caseInsensitive ? tsInfo.nsStr.toLowerCase() : tsInfo.nsStr;
    const pNeedle = caseInsensitive ? primaryPattern.trim().toLowerCase() : primaryPattern.trim();
    const hasMatchInPrefix =
      !isTimeOnlyDefaultSpan &&
      ((targetSpans?.some((s) => s.start < pLen) ?? false) ||
        (pNeedle.length > 0 && nsHay.includes(pNeedle)) ||
        containsTerms.some((t) => {
          const tn = caseInsensitive ? t.toLowerCase() : t;
          return tn.length > 0 && nsHay.includes(tn);
        }));

    if (!hasMatchInPrefix) {
      targetText = tsInfo.restText;
      targetSpans = isTimeOnlyDefaultSpan
        ? undefined
        : targetSpans
            ?.filter((s) => s.end > pLen)
            .map((s) => ({
              start: Math.max(0, s.start - pLen),
              end: Math.max(0, s.end - pLen),
            }));
    }
  }

  const segments = buildHighlightSegments(
    targetText,
    targetSpans,
    containsTerms,
    caseInsensitive,
    true,
    primaryPattern,
    isRegexMode,
    true,
    maxPreviewChars
  );
  hitSegmentCache.set(item, { cacheKey, segments });
  return segments;
}

export interface StructuredAnalysis {
  kind: 'json' | 'embedded-json' | 'kv' | 'long-line';
  formattedText: string;
  bodyFormattedText?: string;
  jsonValue?: unknown;
  timeHint?: string;
  formatBadge?: string;
  prefix?: string;
  suffix?: string;
  kvPairs?: { key: string; value: string }[];
  charCount: number;
}

/**
 * Decodes \uXXXX unicode escapes, URL %XX UTF-8 sequences, ANSI escapes, and literal \n / \t
 * so human eyes can read escaped Chinese/UTF-8 text and multi-line stack traces effortlessly.
 */
export function decodeHumanEscapes(s: string): string {
  if (!s || (!s.includes('\\') && !s.includes('%') && !s.includes('\x1b'))) {
    return s;
  }
  let out = s
    .replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '')
    .replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\r\\n|\\n/g, '\n')
    .replace(/\\t/g, '  ');

  if (/%[0-9a-fA-F]{2}/.test(out)) {
    out = out.replace(/(?:%[0-9a-fA-F]{2})+/g, (match) => {
      try {
        return decodeURIComponent(match);
      } catch {
        return match;
      }
    });
  }
  return out;
}

/**
 * Recursively unwraps nested JSON strings (e.g. Docker `"log":"{\"level\":\"error\"}"` or gateway `"body":"{...}"`)
 * and decodes `\uXXXX` / `%XX` inside string values.
 */
function deepHumanizeJsonValue(val: unknown, depth = 0): unknown {
  if (depth > 4 || val === null || val === undefined) return val;
  if (typeof val === 'string') {
    const trimmed = val.trim();
    if (
      (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']'))
    ) {
      try {
        const inner = JSON.parse(trimmed);
        if (typeof inner === 'object' && inner !== null) {
          return deepHumanizeJsonValue(inner, depth + 1);
        }
      } catch {
        // keep as string
      }
    }
    return decodeHumanEscapes(val);
  }
  if (Array.isArray(val)) {
    return val.map((item) => deepHumanizeJsonValue(item, depth + 1));
  }
  if (typeof val === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(val as Record<string, unknown>)) {
      out[k] = deepHumanizeJsonValue(v, depth + 1);
    }
    return out;
  }
  return val;
}

/**
 * Detects any Unix epoch timestamp (10s, 13ms, 16us, 19ns) in a line and formats it into local time.
 */
export function detectInlineEpochHint(text: string): string | null {
  const lead = extractLeadingNanoTimestamp(text);
  if (lead) return lead.fullFormattedTime;

  const m = /(?:^|[^0-9])(1[5-9]\d{8}(?:\d{3}|\d{6}|\d{9})?)(?:$|[^0-9])/.exec(text);
  if (!m) return null;
  const rawDigits = m[1];
  const ms =
    rawDigits.length === 10
      ? Number(rawDigits) * 1000
      : rawDigits.length >= 13
        ? Number(rawDigits.slice(0, 13))
        : 0;
  if (!Number.isFinite(ms) || ms < 946684800000 || ms > 4102444800000) return null;

  const d = new Date(ms);
  const pad2 = (n: number) => (n < 10 ? `0${n}` : `${n}`);
  const pad3 = (n: number) => (n < 10 ? `00${n}` : n < 100 ? `0${n}` : `${n}`);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}.${pad3(d.getMilliseconds())}`;
}

/**
 * Universal structural indenter for non-JSON text:
 * - Formats compressed single-line HTML/XML (`<div><span>...</span></div>`) into indented lines
 * - Formats long single-line struct/map/bracket dumps (`User{id:1, roles:[a,b]}`) into indented lines
 */
export function universalPrettyStructure(s: string): { formatted: string; badge?: string } {
  const decoded = decodeHumanEscapes(s);
  if (decoded.includes('\n')) {
    return { formatted: decoded };
  }

  // 1. Check compressed HTML / XML tags on a single line
  if (decoded.length > 64 && /<\/?[a-zA-Z][a-zA-Z0-9:-]*[^>]*>/.test(decoded) && decoded.includes('><')) {
    const voidTags = new Set([
      'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
      'link', 'meta', 'param', 'source', 'track', 'wbr',
    ]);
    const tokens = decoded.replace(/>\s*</g, '>\n<').split('\n');
    if (tokens.length >= 3) {
      let depth = 0;
      const lines: string[] = [];
      for (const rawTok of tokens) {
        const tok = rawTok.trim();
        if (!tok) continue;
        const isClosing = /^<\//.test(tok);
        const openMatch = /^<([a-zA-Z0-9:-]+)/.exec(tok);
        const tagName = openMatch ? openMatch[1].toLowerCase() : '';
        const isSelfClosing =
          /\/>$/.test(tok) ||
          /^<![-]/.test(tok) ||
          /^<\?/.test(tok) ||
          voidTags.has(tagName) ||
          (openMatch !== null && tok.includes(`</${tagName}>`));

        if (isClosing) depth = Math.max(0, depth - 1);
        lines.push(`${'  '.repeat(depth)}${tok}`);
        if (!isClosing && openMatch && !isSelfClosing) {
          depth = Math.min(16, depth + 1);
        }
      }
      return { formatted: lines.join('\n'), badge: 'HTML' };
    }
  }

  // 2. Check long single-line brace/bracket structure (e.g. Go/Rust/Python struct or broken JSON)
  if (decoded.length > 80 && (decoded.includes('{') || decoded.includes('['))) {
    let depth = 0;
    let inQuote: '"' | "'" | null = null;
    let out = '';
    let brkCount = 0;
    for (let i = 0; i < decoded.length; i++) {
      const ch = decoded[i];
      const prev = i > 0 ? decoded[i - 1] : '';
      if (inQuote) {
        out += ch;
        if (ch === inQuote && prev !== '\\') inQuote = null;
        continue;
      }
      if (ch === '"' || ch === "'") {
        inQuote = ch;
        out += ch;
        continue;
      }
      if (ch === '{' || ch === '[') {
        const next = decoded[i + 1] ?? '';
        if (next === '}' || next === ']') {
          out += ch + next;
          i++;
          continue;
        }
        depth = Math.min(16, depth + 1);
        brkCount++;
        out += `${ch}\n${'  '.repeat(depth)}`;
      } else if (ch === '}' || ch === ']') {
        depth = Math.max(0, depth - 1);
        out += `\n${'  '.repeat(depth)}${ch}`;
      } else if (ch === ',' && depth > 0) {
        out += `,\n${'  '.repeat(depth)}`;
        while (i + 1 < decoded.length && decoded[i + 1] === ' ') i++;
      } else {
        out += ch;
      }
    }
    if (brkCount >= 1) {
      return { formatted: out, badge: 'STRUCT' };
    }
  }

  return { formatted: decoded };
}

const MAX_STRUCTURED_ANALYSIS_CACHE = 128;
const MAX_STRUCTURED_ANALYSIS_LEN = 262_144;
const structuredAnalysisCache = new Map<string, StructuredAnalysis>();

/**
 * Beautifies any line of text for comfortable reading in the Inspector without deleting user information.
 */
export function analyzeStructuredLine(text: string): StructuredAnalysis {
  if (text.length <= MAX_STRUCTURED_ANALYSIS_LEN) {
    const cached = structuredAnalysisCache.get(text);
    if (cached) {
      structuredAnalysisCache.delete(text);
      structuredAnalysisCache.set(text, cached);
      return cached;
    }
  }

  const result = computeStructuredAnalysis(text);

  if (text.length <= MAX_STRUCTURED_ANALYSIS_LEN) {
    if (structuredAnalysisCache.size >= MAX_STRUCTURED_ANALYSIS_CACHE) {
      const oldestKey = structuredAnalysisCache.keys().next().value;
      if (oldestKey !== undefined) structuredAnalysisCache.delete(oldestKey);
    }
    structuredAnalysisCache.set(text, result);
  }
  return result;
}

function computeStructuredAnalysis(text: string): StructuredAnalysis {
  const tsInfo = extractLeadingNanoTimestamp(text);
  const tsHeader = tsInfo ? `${tsInfo.fullFormattedTime} (${tsInfo.nsStr})` : '';
  const timeHint = tsInfo ? tsInfo.fullFormattedTime : (detectInlineEpochHint(text) ?? undefined);
  const bodyText = tsInfo && tsInfo.restText.length > 0 ? tsInfo.restText : text;
  const trimmed = bodyText.trim();
  const charCount = text.length;

  // 1. Direct JSON object or array (with recursive nested JSON string unpacking & unicode decoding)
  if (
    (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
    (trimmed.startsWith('[') && trimmed.endsWith(']'))
  ) {
    try {
      const parsed = JSON.parse(trimmed);
      const humanized = deepHumanizeJsonValue(parsed);
      const pretty = JSON.stringify(humanized, null, 2);
      return {
        kind: 'json',
        jsonValue: humanized,
        timeHint,
        formatBadge: 'JSON',
        prefix: tsHeader || undefined,
        bodyFormattedText: pretty,
        formattedText: tsHeader ? `${tsHeader}\n\n${pretty}` : pretty,
        charCount,
      };
    } catch {
      // fall through
    }
  }

  // 2. Embedded JSON inside a log or text line
  const firstBrace = bodyText.indexOf('{');
  const lastBrace = bodyText.lastIndexOf('}');
  if (firstBrace !== -1 && lastBrace > firstBrace + 1) {
    const candidate = bodyText.slice(firstBrace, lastBrace + 1);
    try {
      const parsed = JSON.parse(candidate);
      const humanized = deepHumanizeJsonValue(parsed);
      const rawPrefix = decodeHumanEscapes(bodyText.slice(0, firstBrace).trim());
      const prefix = [tsHeader, rawPrefix].filter((p) => p.length > 0).join('  ');
      const suffix = decodeHumanEscapes(bodyText.slice(lastBrace + 1).trim());
      const prettyJson = JSON.stringify(humanized, null, 2);
      const bodyParts = [rawPrefix, prettyJson, suffix].filter((p) => p.length > 0);
      const parts = [prefix, prettyJson, suffix].filter((p) => p.length > 0);
      return {
        kind: 'embedded-json',
        jsonValue: humanized,
        timeHint,
        formatBadge: 'JSON',
        prefix,
        bodyFormattedText: bodyParts.join('\n\n'),
        formattedText: parts.join('\n\n'),
        suffix,
        charCount,
      };
    } catch {
      // fall through
    }
  }

  // 3. Key=Value pairs detection (preserves any leading timestamp/level/module prefix and trailing suffix)
  if (!trimmed.startsWith('{') && !(trimmed.startsWith('[') && trimmed.endsWith(']'))) {
    const kvRegex = /(?:^|[\s,;])([a-zA-Z0-9_.-]+)=("[^"]*"|'[^']*'|[^\s,;<>"']+)/g;
    const pairs: { key: string; value: string }[] = [];
    let firstKeyStart = -1;
    let lastMatchEnd = 0;
    let match: RegExpExecArray | null;
    while ((match = kvRegex.exec(bodyText)) !== null) {
      if (firstKeyStart === -1) {
        const fullMatch = match[0];
        const keyValLen = match[1].length + 1 + match[2].length;
        firstKeyStart = match.index + (fullMatch.length - keyValLen);
      }
      lastMatchEnd = match.index + match[0].length;
      pairs.push({
        key: match[1],
        value: decodeHumanEscapes(match[2].replace(/^["']|["']$/g, '')),
      });
    }
    if (pairs.length >= 3) {
      const rawPrefix = firstKeyStart > 0 ? decodeHumanEscapes(bodyText.slice(0, firstKeyStart).trim()) : '';
      const prefix = [tsHeader, rawPrefix].filter((p) => p.length > 0).join('  ');
      const suffix = lastMatchEnd < bodyText.length ? decodeHumanEscapes(bodyText.slice(lastMatchEnd).trim()) : '';
      const kvFormatted = pairs.map((p) => `${p.key}: ${p.value}`).join('\n');
      const parts = [prefix, kvFormatted, suffix].filter((p) => p.length > 0);
      return {
        kind: 'kv',
        timeHint,
        formatBadge: 'KV',
        prefix: prefix || undefined,
        suffix: suffix || undefined,
        kvPairs: pairs,
        bodyFormattedText: [rawPrefix, kvFormatted, suffix].filter((p) => p.length > 0).join('\n\n'),
        formattedText: parts.join('\n\n'),
        charCount,
      };
    }
  }

  // 4. Universal structure / HTML / escape decoder for any code, HTML, or text line
  const universal = universalPrettyStructure(bodyText);
  return {
    kind: 'long-line',
    timeHint,
    formatBadge: universal.badge,
    prefix: tsHeader || undefined,
    bodyFormattedText: universal.formatted,
    formattedText: tsHeader ? `${tsHeader}\n${universal.formatted}` : universal.formatted,
    charCount,
  };
}

export type SyntaxTokenKind =
  | 'plain'
  | 'comment'
  | 'string'
  | 'keyword'
  | 'type'
  | 'builtin'
  | 'literal'
  | 'number'
  | 'function'
  | 'property'
  | 'punctuation';

export interface CodeHighlightSegment {
  text: string;
  matchKind: HighlightSegment['kind'];
  syntaxKind: SyntaxTokenKind;
}

const CODE_KEYWORDS = new Set([
  // Zig / Rust / C / C++ / Go
  'pub', 'fn', 'const', 'var', 'let', 'mut', 'return', 'if', 'else', 'for', 'while', 'loop',
  'switch', 'case', 'default', 'break', 'continue', 'defer', 'errdefer', 'try', 'catch',
  'orelse', 'comptime', 'inline', 'noinline', 'export', 'extern', 'packed', 'align',
  'linksection', 'callconv', 'suspend', 'resume', 'nosuspend', 'async', 'await',
  'struct', 'enum', 'union', 'error', 'opaque', 'test', 'usingnamespace', 'threadlocal',
  'volatile', 'allowzero', 'noalias', 'asm', 'unreachable', 'undefined',
  'impl', 'trait', 'use', 'mod', 'crate', 'where', 'ref', 'move', 'unsafe', 'dyn', 'type',
  'match', 'package', 'import', 'func', 'chan', 'go', 'select', 'fallthrough', 'range',
  'sizeof', 'typedef', 'static', 'register', 'auto', 'goto', 'namespace', 'template',
  'typename', 'virtual', 'override', 'final', 'public', 'private', 'protected', 'friend',
  // TS / JS / Python / Java / SQL
  'function', 'class', 'interface', 'extends', 'implements', 'new', 'typeof', 'instanceof',
  'in', 'of', 'from', 'as', 'yield', 'delete', 'void', 'throw', 'finally', 'debugger',
  'def', 'elif', 'except', 'lambda', 'pass', 'raise', 'with', 'global', 'nonlocal',
  'and', 'or', 'not', 'is', 'assert', 'del',
]);

const CODE_TYPES = new Set([
  'u8', 'u16', 'u32', 'u64', 'u128', 'usize', 'i8', 'i16', 'i32', 'i64', 'i128', 'isize',
  'c_short', 'c_ushort', 'c_int', 'c_uint', 'c_long', 'c_ulong', 'c_longlong', 'c_ulonglong',
  'c_char', 'c_void', 'f16', 'f32', 'f64', 'f80', 'f128', 'bool', 'void', 'noreturn',
  'anyerror', 'anytype', 'anyopaque', 'anyframe', 'comptime_int', 'comptime_float',
  'string', 'number', 'boolean', 'bigint', 'symbol', 'unknown', 'never', 'any', 'object',
  'int', 'float', 'double', 'char', 'short', 'long', 'unsigned', 'signed', 'size_t', 'ssize_t',
  'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t', 'int8_t', 'int16_t', 'int32_t', 'int64_t',
  'uintptr_t', 'intptr_t', 'byte', 'rune', 'error',
  'String', 'Vec', 'Option', 'Result', 'Box', 'Arc', 'Rc', 'Cell', 'RefCell', 'Self',
  'Array', 'Map', 'Set', 'WeakMap', 'WeakSet', 'Promise', 'Record', 'Partial', 'Readonly',
]);

const CODE_LITERALS = new Set([
  'true', 'false', 'null', 'undefined', 'nil', 'None', 'True', 'False', 'NaN', 'Infinity',
  'self', 'this', 'super', 'Some', 'Ok', 'Err',
]);

interface SyntaxSpan {
  start: number;
  end: number;
  kind: SyntaxTokenKind;
}

function tokenizeCodeSyntax(text: string): SyntaxSpan[] {
  const spans: SyntaxSpan[] = [];
  const n = text.length;
  let i = 0;

  const pushSpan = (start: number, end: number, kind: SyntaxTokenKind) => {
    if (end <= start) return;
    const prev = spans[spans.length - 1];
    if (prev && prev.kind === kind && prev.end === start) {
      prev.end = end;
    } else {
      spans.push({ start, end, kind });
    }
  };

  while (i < n) {
    const ch = text[i];
    const next = i + 1 < n ? text[i + 1] : '';

    // 1. Whitespace
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') {
      const start = i;
      while (
        i < n &&
        (text[i] === ' ' || text[i] === '\t' || text[i] === '\n' || text[i] === '\r')
      ) {
        i++;
      }
      pushSpan(start, i, 'plain');
      continue;
    }

    // 2. Comments: `//...`, `/*...*/`, `<!--...-->`, or `#...` (when at line start or after space)
    if (ch === '/' && next === '/') {
      const start = i;
      while (i < n && text[i] !== '\n') i++;
      pushSpan(start, i, 'comment');
      continue;
    }
    if (ch === '/' && next === '*') {
      const start = i;
      i += 2;
      while (i < n && !(text[i] === '*' && text[i + 1] === '/')) i++;
      if (i < n) i += 2;
      pushSpan(start, i, 'comment');
      continue;
    }
    if (ch === '<' && text.slice(i, i + 4) === '<!--') {
      const start = i;
      i += 4;
      while (i < n && text.slice(i, i + 3) !== '-->') i++;
      if (i < n) i += 3;
      pushSpan(start, i, 'comment');
      continue;
    }
    // 2b. Rust attributes (`#[derive(...)]`, `#![allow(...)]`) -> highlight as builtin
    if (ch === '#' && (next === '[' || (next === '!' && text[i + 2] === '['))) {
      const start = i;
      i += next === '!' ? 3 : 2;
      let depth = 1;
      while (i < n && depth > 0 && text[i] !== '\n') {
        if (text[i] === '[') depth++;
        else if (text[i] === ']') depth--;
        i++;
      }
      pushSpan(start, i, 'builtin');
      continue;
    }

    if (
      ch === '#' &&
      (i === 0 || text[i - 1] === ' ' || text[i - 1] === '\t' || text[i - 1] === '\n') &&
      !/^#(?:include|define|ifdef|ifndef|endif|pragma|elif|else|error|if)\b/.test(text.slice(i))
    ) {
      const start = i;
      while (i < n && text[i] !== '\n') i++;
      pushSpan(start, i, 'comment');
      continue;
    }

    // 2c. Rust lifetimes (`'a`, `'static`, `'_`) — must not be mistaken for unclosed `'...'` string!
    if (ch === "'" && /^'[a-zA-Z_][a-zA-Z0-9_]*(?!')/.test(text.slice(i))) {
      const start = i;
      i++;
      while (i < n && /[a-zA-Z0-9_]/.test(text[i])) i++;
      pushSpan(start, i, 'type');
      continue;
    }

    // 3. String or char literals: `"..."`, `'...'`, `` `...` ``
    if (ch === '"' || ch === "'" || ch === '`') {
      const quote = ch;
      const start = i;
      i++;
      while (i < n) {
        const c = text[i];
        if (c === '\\') {
          i += 2;
          continue;
        }
        if (c === quote) {
          i++;
          break;
        }
        if (c === '\n' && quote !== '`') break;
        i++;
      }
      // Check if this is a JSON / object property key (`"key":`)
      let lookahead = i;
      while (lookahead < n && (text[lookahead] === ' ' || text[lookahead] === '\t')) {
        lookahead++;
      }
      const isJsonKey =
        quote === '"' && lookahead < n && text[lookahead] === ':' && text[lookahead + 1] !== ':';
      pushSpan(start, i, isJsonKey ? 'property' : 'string');
      continue;
    }

    // 4. Zig `@builtin` / decorators / C preprocessor `#include`
    if (
      (ch === '@' || ch === '#') &&
      i + 1 < n &&
      /[a-zA-Z_]/.test(text[i + 1])
    ) {
      const start = i;
      i++;
      while (i < n && /[a-zA-Z0-9_]/.test(text[i])) i++;
      pushSpan(start, i, 'builtin');
      continue;
    }

    // 5. HTML / JSX tags (`<div`, `</span`, `/>`)
    if (ch === '<' && (next === '/' || /[a-zA-Z]/.test(next))) {
      const start = i;
      i += next === '/' ? 2 : 1;
      while (i < n && /[a-zA-Z0-9:_-]/.test(text[i])) i++;
      pushSpan(start, i, 'builtin');
      continue;
    }

    // 6. Numbers (hex, bin, oct, float, int)
    if (
      (ch >= '0' && ch <= '9') ||
      (ch === '.' && next >= '0' && next <= '9' && (i === 0 || !/[a-zA-Z0-9_]/.test(text[i - 1])))
    ) {
      const start = i;
      if (ch === '0' && (next === 'x' || next === 'X' || next === 'b' || next === 'B' || next === 'o' || next === 'O')) {
        i += 2;
        while (i < n && /[0-9a-fA-F_]/.test(text[i])) i++;
      } else {
        while (i < n && /[0-9_]/.test(text[i])) i++;
        if (i < n && text[i] === '.' && text[i + 1] !== '.') {
          i++;
          while (i < n && /[0-9_]/.test(text[i])) i++;
        }
        if (i < n && (text[i] === 'e' || text[i] === 'E')) {
          i++;
          if (i < n && (text[i] === '+' || text[i] === '-')) i++;
          while (i < n && /[0-9_]/.test(text[i])) i++;
        }
      }
      // Optional numeric type suffix (e.g. `u64`, `usize`, `f32`)
      while (i < n && /[a-zA-Z0-9_]/.test(text[i])) i++;
      pushSpan(start, i, 'number');
      continue;
    }

    // 7. Identifiers, Keywords, Types, Functions, Properties
    if (/[a-zA-Z_$]/.test(ch)) {
      const start = i;
      const prevChar = start > 0 ? text[start - 1] : '';
      i++;
      while (i < n && /[a-zA-Z0-9_$]/.test(text[i])) i++;
      const word = text.slice(start, i);

      let lookahead = i;
      while (lookahead < n && (text[lookahead] === ' ' || text[lookahead] === '\t')) {
        lookahead++;
      }
      const nextNonSpace = lookahead < n ? text[lookahead] : '';

      let kind: SyntaxTokenKind = 'plain';
      if (CODE_KEYWORDS.has(word)) {
        kind = 'keyword';
      } else if (CODE_LITERALS.has(word)) {
        kind = 'literal';
      } else if (CODE_TYPES.has(word)) {
        kind = 'type';
      } else if (nextNonSpace === '(' || (text[i] === '!' && text[i + 1] === '(')) {
        kind = 'function';
      } else if (/^[A-Z][a-zA-Z0-9_]*$/.test(word) && /[a-z]/.test(word)) {
        kind = 'type';
      } else if (
        prevChar === '.' ||
        (nextNonSpace === ':' && text[lookahead + 1] !== ':')
      ) {
        kind = 'property';
      }

      pushSpan(start, i, kind);
      continue;
    }

    // 8. Punctuation & operators
    const start = i;
    i++;
    pushSpan(start, i, 'punctuation');
  }

  return spans;
}

/**
 * Merges code syntax highlighting tokens with search match segments (`primary`, `contains-0/1/2`)
 * so search hits stand out with `<mark>` while all surrounding code has crisp syntax highlighting.
 */
export function highlightCodeWithMatches(
  text: string,
  matchSegments: HighlightSegment[]
): CodeHighlightSegment[] {
  if (!text) return [{ text: '', matchKind: 'plain', syntaxKind: 'plain' }];

  const syntaxSpans = tokenizeCodeSyntax(text);
  const out: CodeHighlightSegment[] = [];

  // Map matchSegments into [start, end, matchKind] ranges over `text`
  let cursor = 0;
  let synIdx = 0;

  for (const mSeg of matchSegments) {
    const segLen = mSeg.text.length;
    if (segLen === 0) continue;
    const segStart = cursor;
    const segEnd = cursor + segLen;
    cursor = segEnd;

    if (mSeg.kind !== 'plain') {
      out.push({
        text: mSeg.text,
        matchKind: mSeg.kind,
        syntaxKind: 'plain',
      });
      continue;
    }

    // Slice this plain segment across `syntaxSpans`
    let pos = segStart;
    while (pos < segEnd) {
      while (synIdx < syntaxSpans.length && syntaxSpans[synIdx].end <= pos) {
        synIdx++;
      }
      const syn = syntaxSpans[synIdx];
      if (!syn || syn.start > pos) {
        const nextBound = syn ? Math.min(segEnd, syn.start) : segEnd;
        out.push({
          text: text.slice(pos, nextBound),
          matchKind: 'plain',
          syntaxKind: 'plain',
        });
        pos = nextBound;
      } else {
        const sliceEnd = Math.min(segEnd, syn.end);
        out.push({
          text: text.slice(pos, sliceEnd),
          matchKind: 'plain',
          syntaxKind: syn.kind,
        });
        pos = sliceEnd;
      }
    }
  }

  return out;
}
