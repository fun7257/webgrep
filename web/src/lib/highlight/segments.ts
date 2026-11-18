import type { HitItem, HitSpan } from '../types.ts';
import { extractLeadingNanoTimestamp } from '../format.ts';

export interface HighlightSegment {
  text: string;
  kind: 'plain' | 'primary' | 'contains-0' | 'contains-1' | 'contains-2';
}

export interface CompiledTermMatcher {
  regex: RegExp | null;
  isScoped: boolean;
  literalNeedle: string;
  literalCaseInsensitive: boolean;
  strippedNeedle: string;
}

const MAX_TERM_MATCHER_CACHE = 256;
const termMatcherCache = new Map<string, CompiledTermMatcher>();

/**
 * Compiles a raw query term (supporting `$c`/`$w`/`$r` wire modifiers) into a
 * reusable matcher backed by a 256-entry LRU cache.
 */
export function compileTermMatcher(
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

/**
 * Finds all UTF-16 match spans for `rawTerm` within `text`, using `getLower` lazily
 * for case-insensitive literal scans.
 */
export function collectTermSpans(
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
