import { decodeHumanEscapes, detectInlineEpochHint, extractLeadingNanoTimestamp } from '../format.ts';
import { preserveLargeJsonIntegers } from '../adapters/log-parser.ts';

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
        const inner = JSON.parse(preserveLargeJsonIntegers(trimmed));
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
      // fall through
    }
  }

  // 2. Embedded JSON inside a log or text line
  const firstBrace = bodyText.indexOf('{');
  const lastBrace = bodyText.lastIndexOf('}');
  if (firstBrace !== -1 && lastBrace > firstBrace + 1) {
    const candidate = bodyText.slice(firstBrace, lastBrace + 1);
    try {
      const parsed = JSON.parse(preserveLargeJsonIntegers(candidate));
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

/**
 * Formats a single context record cleanly when it contains JSON, KV pairs, or structured markup,
 * returning the original text untouched for ordinary plain/code lines.
 */
export function formatContextRecordPretty(text: string): string {
  if (!text) return text;
  const info = analyzeStructuredLine(text);
  if (
    info.kind === 'json' ||
    info.kind === 'embedded-json' ||
    info.kind === 'kv' ||
    Boolean(info.formatBadge)
  ) {
    return info.bodyFormattedText ?? info.formattedText;
  }
  return text;
}
