import { decodeHumanEscapes, detectInlineEpochHint, extractLeadingNanoTimestamp } from '../format.ts';
import { extractLineTime, preserveLargeJsonIntegers } from '../adapters/log-parser.ts';

export { decodeHumanEscapes };

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
 * Attempts to repair and parse a JSON object/array that was truncated mid-stream
 * (e.g. by a logger's 4 KiB / 5 KiB line cap), closing dangling strings, incomplete
 * escapes/primitives, trailing commas/colons, and unclosed `{`/`[` containers.
 */
export function tryParseTruncatedJson(raw: string): unknown | undefined {
  const s = raw.trimStart();
  if (s.length < 4) return undefined;
  const first = s[0];
  if (first !== '{' && first !== '[') return undefined;

  // Quick structural sanity check on the first non-whitespace char after `{` / `[`
  let probe = 1;
  while (probe < s.length && (s[probe] === ' ' || s[probe] === '\t' || s[probe] === '\r' || s[probe] === '\n')) {
    probe++;
  }
  if (probe >= s.length) return undefined;
  const second = s[probe];
  if (first === '{' && second !== '"' && second !== '}') return undefined;
  if (
    first === '[' &&
    second !== '"' &&
    second !== '{' &&
    second !== '[' &&
    second !== '-' &&
    second !== 't' &&
    second !== 'f' &&
    second !== 'n' &&
    second !== ']' &&
    (second < '0' || second > '9')
  ) {
    return undefined;
  }

  const stack: ('{' | '[')[] = [];
  let inString = false;
  let escaped = false;
  // Tracks whether the current/just-closed string is an object property key
  let expectKeyInObj = false;
  let currentStringIsKey = false;
  let lastStructural: '' | '{' | '[' | '}' | ']' | ',' | ':' | 'val' = '';

  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
        lastStructural = 'val';
        if (currentStringIsKey) {
          currentStringIsKey = false;
          expectKeyInObj = false;
        }
      }
      continue;
    }

    if (ch === ' ' || ch === '\t' || ch === '\r' || ch === '\n') continue;

    if (ch === '"') {
      inString = true;
      escaped = false;
      currentStringIsKey = expectKeyInObj && stack.length > 0 && stack[stack.length - 1] === '{';
    } else if (ch === '{') {
      stack.push('{');
      expectKeyInObj = true;
      lastStructural = '{';
    } else if (ch === '[') {
      stack.push('[');
      expectKeyInObj = false;
      lastStructural = '[';
    } else if (ch === '}') {
      if (stack.length === 0 || stack[stack.length - 1] !== '{') return undefined;
      stack.pop();
      expectKeyInObj = false;
      lastStructural = '}';
    } else if (ch === ']') {
      if (stack.length === 0 || stack[stack.length - 1] !== '[') return undefined;
      stack.pop();
      expectKeyInObj = false;
      lastStructural = ']';
    } else if (ch === ':') {
      expectKeyInObj = false;
      lastStructural = ':';
    } else if (ch === ',') {
      expectKeyInObj = stack.length > 0 && stack[stack.length - 1] === '{';
      lastStructural = ',';
    } else {
      lastStructural = 'val';
    }
  }

  // If already balanced and outside string, regular JSON.parse would have handled it
  if (!inString && stack.length === 0) return undefined;

  let repaired = s;
  if (inString) {
    // Strip dangling trailing backslash or incomplete \uXXXX escape before closing quote
    if (escaped) {
      repaired = repaired.slice(0, -1);
    } else {
      const uMatch = repaired.match(/\\u[0-9a-fA-F]{0,3}$/);
      if (uMatch) {
        repaired = repaired.slice(0, repaired.length - uMatch[0].length);
      }
    }
    repaired += '"';
    if (currentStringIsKey) {
      repaired += ':null';
    }
  } else {
    repaired = repaired.trimEnd();
    if (lastStructural === ',') {
      repaired = repaired.slice(0, -1);
    } else if (lastStructural === ':') {
      repaired += 'null';
    } else if (lastStructural === 'val') {
      // Complete truncated boolean/null literal or trim incomplete numeric exponent/decimal
      const tailWord = repaired.match(/([a-zA-Z]+)$/);
      if (tailWord) {
        const w = tailWord[1];
        if (w !== 'true' && w !== 'false' && w !== 'null') {
          if ('true'.startsWith(w)) {
            repaired += 'true'.slice(w.length);
          } else if ('false'.startsWith(w)) {
            repaired += 'false'.slice(w.length);
          } else if ('null'.startsWith(w)) {
            repaired += 'null'.slice(w.length);
          }
        }
      } else if (/(?:[eE][+-]?|\.)$/.test(repaired)) {
        repaired = repaired.replace(/(?:[eE][+-]?|\.)$/, '');
      } else if (/[:,[\s]-$/.test(repaired)) {
        repaired = repaired.slice(0, -1) + 'null';
      }
      // If an object key string closed right at EOF without `:`, complete with `:null`
      if (
        stack.length > 0 &&
        stack[stack.length - 1] === '{' &&
        repaired.endsWith('"')
      ) {
        // Check if this string is a key (preceded by `{` or `,`)
        // Simple & exact: try parsing with closing brackets first, and if that fails try `:null`
      }
    }
  }

  let closing = '';
  for (let i = stack.length - 1; i >= 0; i--) {
    closing += stack[i] === '{' ? '}' : ']';
  }

  const candidates = [repaired + closing];
  if (!inString && stack.length > 0 && stack[stack.length - 1] === '{' && repaired.endsWith('"')) {
    candidates.push(repaired + ':null' + closing);
  }

  for (const cand of candidates) {
    try {
      const parsed = JSON.parse(preserveLargeJsonIntegers(cand));
      if (typeof parsed === 'object' && parsed !== null) {
        const count = Array.isArray(parsed) ? parsed.length : Object.keys(parsed).length;
        if (count > 0) return parsed;
      }
    } catch {
      // try next candidate
    }
  }
  return undefined;
}

/**
 * Recursively unwraps nested JSON strings (e.g. `"log":"{\"level\":\"error\"}"`)
 * and decodes `\uXXXX` / `%XX` inside JSON string values.
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
        const inner = JSON.parse(preserveLargeJsonIntegers(trimmed));
        if (typeof inner === 'object' && inner !== null) {
          return deepHumanizeJsonValue(inner, depth + 1);
        }
      } catch {
        // fall through to truncated repair check
      }
    }
    if (trimmed.startsWith('{"') || trimmed.startsWith('[{')) {
      const repairedInner = tryParseTruncatedJson(trimmed);
      if (repairedInner !== undefined) {
        return deepHumanizeJsonValue(repairedInner, depth + 1);
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

const MAX_STRUCTURED_ANALYSIS_CACHE = 128;
const MAX_STRUCTURED_ANALYSIS_LEN = 262_144;
const structuredAnalysisCache = new Map<string, StructuredAnalysis>();

/**
 * Beautifies JSON & KV lines (plus timestamp detection) for the Inspector without
 * applying special non-time heuristics to ordinary plain text lines.
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
  const lineTime = tsInfo ? null : extractLineTime(text);
  const timeHint = tsInfo
    ? tsInfo.fullFormattedTime
    : (lineTime?.timeFull || detectInlineEpochHint(text) || undefined);
  const bodyText = tsInfo && tsInfo.restText.length > 0 ? tsInfo.restText : text;
  const trimmed = bodyText.trim();
  const charCount = text.length;

  // 1. Direct JSON object or array (complete or truncated mid-stream)
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    const isClosed =
      (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']'));
    if (isClosed) {
      try {
        const parsed = JSON.parse(preserveLargeJsonIntegers(trimmed));
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
        // fall through to truncated repair check
      }
    }
    const repaired = tryParseTruncatedJson(trimmed);
    if (repaired !== undefined) {
      const humanized = deepHumanizeJsonValue(repaired);
      const pretty = JSON.stringify(humanized, null, 2);
      return {
        kind: 'json',
        jsonValue: humanized,
        timeHint,
        formatBadge: 'JSON (truncated)',
        prefix: tsHeader || undefined,
        bodyFormattedText: pretty,
        formattedText: tsHeader ? `${tsHeader}\n\n${pretty}` : pretty,
        charCount,
      };
    }
  }

  // 2. Embedded JSON inside a line (complete or truncated mid-stream)
  const firstBrace = bodyText.indexOf('{');
  const lastBrace = bodyText.lastIndexOf('}');
  if (firstBrace !== -1 && lastBrace > firstBrace + 1) {
    const candidate = bodyText.slice(firstBrace, lastBrace + 1);
    try {
      const parsed = JSON.parse(preserveLargeJsonIntegers(candidate));
      const humanized = deepHumanizeJsonValue(parsed);
      const rawPrefix = bodyText.slice(0, firstBrace).trim();
      const prefix = [tsHeader, rawPrefix].filter((p) => p.length > 0).join('  ');
      const suffix = bodyText.slice(lastBrace + 1).trim();
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
      // fall through to truncated embedded JSON check
    }
  }
  if (firstBrace > 0) {
    const repaired = tryParseTruncatedJson(bodyText.slice(firstBrace));
    if (repaired !== undefined) {
      const humanized = deepHumanizeJsonValue(repaired);
      const rawPrefix = bodyText.slice(0, firstBrace).trim();
      const prefix = [tsHeader, rawPrefix].filter((p) => p.length > 0).join('  ');
      const prettyJson = JSON.stringify(humanized, null, 2);
      const bodyParts = [rawPrefix, prettyJson].filter((p) => p.length > 0);
      const parts = [prefix, prettyJson].filter((p) => p.length > 0);
      return {
        kind: 'embedded-json',
        jsonValue: humanized,
        timeHint,
        formatBadge: 'JSON (truncated)',
        prefix,
        bodyFormattedText: bodyParts.join('\n\n'),
        formattedText: parts.join('\n\n'),
        charCount,
      };
    }
  }

  // 3. Key=Value pairs detection (preserves any leading prefix and trailing suffix)
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
      const rawPrefix = firstKeyStart > 0 ? bodyText.slice(0, firstKeyStart).trim() : '';
      const prefix = [tsHeader, rawPrefix].filter((p) => p.length > 0).join('  ');
      const suffix = lastMatchEnd < bodyText.length ? bodyText.slice(lastMatchEnd).trim() : '';
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

  // 4. Plain text: show verbatim without extra content adaptation
  return {
    kind: 'long-line',
    timeHint,
    prefix: tsHeader || undefined,
    bodyFormattedText: bodyText,
    formattedText: tsHeader ? `${tsHeader}\n${bodyText}` : bodyText,
    charCount,
  };
}

/**
 * Formats a single context record cleanly when it contains JSON or KV pairs,
 * returning the original text untouched for ordinary plain/code lines.
 */
export function formatContextRecordPretty(text: string): string {
  if (!text) return text;
  const info = analyzeStructuredLine(text);
  if (info.kind === 'json' || info.kind === 'embedded-json' || info.kind === 'kv') {
    return info.bodyFormattedText ?? info.formattedText;
  }
  return text;
}
