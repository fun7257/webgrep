import {
  decodeHumanEscapes,
  extractLeadingNanoTimestamp,
  skipLeadingNanoTimestampOffset,
} from '../format.ts';
import type {
  FastLogProbe,
  LogFormat,
  LogHttpMeta,
  LogKeyField,
  LogLevel,
  ParsedLogRecord,
} from './types.ts';
import type { HitItem } from '../types.ts';

const NON_LOG_PROBE: FastLogProbe = {
  isLog: false,
  dateKey: '',
  level: 'unknown',
  levelFilterToken: '',
  category: '',
  categoryFilterToken: '',
  estimatedSummaryCols: 0,
  hasLongPayload: false,
};

function isAsciiDigit(c: number): boolean {
  return c >= 48 && c <= 57;
}

/**
 * Zero-regex ASCII date extractor for `YYYY-MM-DD` / `YYYY/MM/DD` prefixes.
 */
function extractAsciiDateKey(str: string, start: number, len: number): string {
  if (len < 10 || start < 0 || start + 10 > str.length) return '';
  const sep = str.charCodeAt(start + 4);
  if ((sep !== 45 && sep !== 47) || str.charCodeAt(start + 7) !== sep) return '';
  if (
    !isAsciiDigit(str.charCodeAt(start)) ||
    !isAsciiDigit(str.charCodeAt(start + 1)) ||
    !isAsciiDigit(str.charCodeAt(start + 2)) ||
    !isAsciiDigit(str.charCodeAt(start + 3)) ||
    !isAsciiDigit(str.charCodeAt(start + 5)) ||
    !isAsciiDigit(str.charCodeAt(start + 6)) ||
    !isAsciiDigit(str.charCodeAt(start + 8)) ||
    !isAsciiDigit(str.charCodeAt(start + 9))
  ) {
    return '';
  }
  const month = (str.charCodeAt(start + 5) - 48) * 10 + (str.charCodeAt(start + 6) - 48);
  const day = (str.charCodeAt(start + 8) - 48) * 10 + (str.charCodeAt(start + 9) - 48);
  if (month < 1 || month > 12 || day < 1 || day > 31) return '';
  if (sep === 45) return str.slice(start, start + 10);
  return `${str.slice(start, start + 4)}-${str.slice(start + 5, start + 7)}-${str.slice(start + 8, start + 10)}`;
}

const LEVEL_MAP: Record<string, { level: LogLevel; badge: string }> = {
  fatal: { level: 'fatal', badge: 'FTL' },
  ftl: { level: 'fatal', badge: 'FTL' },
  crit: { level: 'fatal', badge: 'FTL' },
  critical: { level: 'fatal', badge: 'FTL' },
  panic: { level: 'fatal', badge: 'FTL' },
  emerg: { level: 'fatal', badge: 'FTL' },
  emergency: { level: 'fatal', badge: 'FTL' },
  alert: { level: 'fatal', badge: 'FTL' },
  error: { level: 'error', badge: 'ERR' },
  err: { level: 'error', badge: 'ERR' },
  severe: { level: 'error', badge: 'ERR' },
  stderr: { level: 'error', badge: 'ERR' },
  warn: { level: 'warn', badge: 'WRN' },
  warning: { level: 'warn', badge: 'WRN' },
  wrn: { level: 'warn', badge: 'WRN' },
  info: { level: 'info', badge: 'INF' },
  inf: { level: 'info', badge: 'INF' },
  information: { level: 'info', badge: 'INF' },
  notice: { level: 'info', badge: 'INF' },
  debug: { level: 'debug', badge: 'DBG' },
  dbg: { level: 'debug', badge: 'DBG' },
  trace: { level: 'trace', badge: 'TRC' },
  trc: { level: 'trace', badge: 'TRC' },
  verbose: { level: 'trace', badge: 'TRC' },
};

const PINO_LEVEL_MAP: Record<number, { level: LogLevel; badge: string }> = {
  60: { level: 'fatal', badge: 'FTL' },
  50: { level: 'error', badge: 'ERR' },
  40: { level: 'warn', badge: 'WRN' },
  30: { level: 'info', badge: 'INF' },
  20: { level: 'debug', badge: 'DBG' },
  10: { level: 'trace', badge: 'TRC' },
};

const TIME_KEYS = ['t', 'ts', 'time', 'timestamp', '@timestamp', 'datetime', 'date', 'asctime'] as const;
const LEVEL_KEYS = ['l', 'lvl', 'level', 'severity', 'levelname'] as const;
const CATEGORY_KEYS = ['category', 'logger', 'component', 'module', 'service', 'app', 'instance'] as const;
const TRACE_KEYS = [
  'traceID',
  'traceId',
  'trace_id',
  'requestID',
  'requestId',
  'request_id',
  'reqId',
  'req_id',
  'spanID',
  'span_id',
] as const;

const ENVELOPE_HIDE_KEYS = new Set<string>([
  't',
  'ts',
  'time',
  'timestamp',
  '@timestamp',
  'datetime',
  'l',
  'lvl',
  'level',
  'severity',
  'levelname',
  'category',
  'logger',
  'message',
  'msg',
]);

export function normalizeLogLevel(raw: unknown): { level: LogLevel; badge: string } {
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    return PINO_LEVEL_MAP[raw] ?? { level: 'unknown', badge: '' };
  }
  if (typeof raw !== 'string') {
    return { level: 'unknown', badge: '' };
  }
  const clean = raw.trim().toLowerCase();
  if (!clean) return { level: 'unknown', badge: '' };
  const mapped = LEVEL_MAP[clean];
  if (mapped) return mapped;
  if (/^\d{2}$/.test(clean)) {
    return PINO_LEVEL_MAP[Number(clean)] ?? { level: 'unknown', badge: '' };
  }
  return { level: 'unknown', badge: '' };
}

/**
 * Quote-aware pass that converts unquoted integer literals with >= 16 digits
 * into JSON strings before `JSON.parse`, preserving exact 64-bit IDs (Snowflake, configNum).
 */
export function preserveLargeJsonIntegers(raw: string): string {
  if (!raw || !/\d{16}/.test(raw)) return raw;

  let out = '';
  let lastCopy = 0;
  let inString = false;
  let escaped = false;
  const len = raw.length;

  for (let i = 0; i < len; i++) {
    const ch = raw.charCodeAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === 92) {
        escaped = true;
      } else if (ch === 34) {
        inString = false;
      }
      continue;
    }

    if (ch === 34) {
      inString = true;
      continue;
    }

    // Check start of unquoted numeric token: optional '-' followed by digit
    if (ch === 45 || (ch >= 48 && ch <= 57)) {
      const prev = i > 0 ? raw.charCodeAt(i - 1) : 0;
      const validBefore =
        i === 0 ||
        prev === 58 || // :
        prev === 91 || // [
        prev === 44 || // ,
        prev === 32 ||
        prev === 9 ||
        prev === 10 ||
        prev === 13;
      if (!validBefore) continue;

      let j = ch === 45 ? i + 1 : i;
      const digitStart = j;
      while (j < len) {
        const dc = raw.charCodeAt(j);
        if (dc >= 48 && dc <= 57) j++;
        else break;
      }
      const digitCount = j - digitStart;
      if (digitCount >= 16) {
        const next = j < len ? raw.charCodeAt(j) : 0;
        const validAfter =
          j === len ||
          next === 44 || // ,
          next === 125 || // }
          next === 93 || // ]
          next === 32 ||
          next === 9 ||
          next === 10 ||
          next === 13;
        const hasLeadingZero = digitCount > 1 && raw.charCodeAt(digitStart) === 48;
        if (validAfter && !hasLeadingZero) {
          out += raw.slice(lastCopy, i);
          out += `"${raw.slice(i, j)}"`;
          lastCopy = j;
        }
      }
      i = j - 1;
    }
  }

  if (lastCopy === 0) return raw;
  out += raw.slice(lastCopy);
  return out;
}

function skipWs(s: string, pos: number): number {
  while (pos < s.length) {
    const c = s.charCodeAt(pos);
    if (c === 32 || c === 9 || c === 10 || c === 13) pos++;
    else break;
  }
  return pos;
}

function parseJsonStringAt(s: string, start: number): { value: string; nextPos: number } | null {
  if (start >= s.length || s.charCodeAt(start) !== 34) return null;
  let pos = start + 1;
  let hasEscape = false;
  while (pos < s.length) {
    const c = s.charCodeAt(pos);
    if (c === 92) {
      hasEscape = true;
      pos += 2;
      continue;
    }
    if (c === 34) {
      const slice = s.slice(start, pos + 1);
      if (!hasEscape) {
        return { value: s.slice(start + 1, pos), nextPos: pos + 1 };
      }
      try {
        const parsed = JSON.parse(slice);
        return typeof parsed === 'string' ? { value: parsed, nextPos: pos + 1 } : null;
      } catch {
        return null;
      }
    }
    if (c < 32) return null;
    pos++;
  }
  return null;
}

function findBalancedEnd(s: string, start: number): number {
  const open = s.charCodeAt(start);
  if (open !== 123 && open !== 91) return -1;
  let depth = 0;
  let inStr = false;
  let esc = false;
  for (let i = start; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (inStr) {
      if (esc) esc = false;
      else if (c === 92) esc = true;
      else if (c === 34) inStr = false;
      continue;
    }
    if (c === 34) {
      inStr = true;
    } else if (c === 123 || c === 91) {
      depth++;
    } else if (c === 125 || c === 93) {
      depth--;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

/**
 * Recovers intact top-level key-value pairs from a hard-truncated JSON log line
 * (e.g. 4,984-byte fixed-buffer truncated lines in production logs).
 */
export function parseTruncatedJsonEnvelope(
  raw: string
): { fields: Record<string, unknown>; tail: string } | null {
  const start = skipWs(raw, 0);
  if (start >= raw.length || raw.charCodeAt(start) !== 123) return null;

  const fields: Record<string, unknown> = {};
  let keyCount = 0;
  let pos = skipWs(raw, start + 1);
  let tailStart = pos;

  while (pos < raw.length) {
    pos = skipWs(raw, pos);
    if (pos >= raw.length) break;
    if (raw.charCodeAt(pos) === 125) {
      tailStart = pos + 1;
      break;
    }
    tailStart = pos;

    const keyParsed = parseJsonStringAt(raw, pos);
    if (!keyParsed) break;
    pos = skipWs(raw, keyParsed.nextPos);
    if (pos >= raw.length || raw.charCodeAt(pos) !== 58) break; // ':'
    pos = skipWs(raw, pos + 1);
    if (pos >= raw.length) break;

    const valCh = raw.charCodeAt(pos);
    let parsedVal: unknown;
    let nextPos = -1;

    if (valCh === 34) {
      const strVal = parseJsonStringAt(raw, pos);
      if (!strVal) break;
      parsedVal = strVal.value;
      nextPos = strVal.nextPos;
    } else if (valCh === 123 || valCh === 91) {
      const end = findBalancedEnd(raw, pos);
      if (end === -1) break;
      try {
        parsedVal = JSON.parse(preserveLargeJsonIntegers(raw.slice(pos, end)));
        nextPos = end;
      } catch {
        break;
      }
    } else if (raw.startsWith('true', pos)) {
      parsedVal = true;
      nextPos = pos + 4;
    } else if (raw.startsWith('false', pos)) {
      parsedVal = false;
      nextPos = pos + 5;
    } else if (raw.startsWith('null', pos)) {
      parsedVal = null;
      nextPos = pos + 4;
    } else if (valCh === 45 || (valCh >= 48 && valCh <= 57)) {
      let end = pos + (valCh === 45 ? 1 : 0);
      let isFloat = false;
      while (end < raw.length) {
        const nc = raw.charCodeAt(end);
        if (nc >= 48 && nc <= 57) {
          end++;
        } else if (nc === 46 || nc === 101 || nc === 69 || nc === 43 || nc === 45) {
          isFloat = true;
          end++;
        } else {
          break;
        }
      }
      const numRaw = raw.slice(pos, end);
      if (!numRaw || numRaw === '-') break;
      const afterNum = skipWs(raw, end);
      if (
        afterNum < raw.length &&
        raw.charCodeAt(afterNum) !== 44 &&
        raw.charCodeAt(afterNum) !== 125
      ) {
        break;
      }
      if (afterNum >= raw.length) {
        // Number right at EOF may itself be cut off mid-digit
        break;
      }
      const digitsOnly = valCh === 45 ? end - pos - 1 : end - pos;
      if (!isFloat && digitsOnly >= 16) {
        parsedVal = numRaw;
      } else {
        const n = Number(numRaw);
        if (!Number.isFinite(n)) break;
        parsedVal = n;
      }
      nextPos = end;
    } else {
      break;
    }

    fields[keyParsed.value] = parsedVal;
    keyCount++;
    pos = skipWs(raw, nextPos);
    tailStart = pos;
    if (pos < raw.length && raw.charCodeAt(pos) === 44) {
      pos++;
      tailStart = pos;
      continue;
    }
    if (pos < raw.length && raw.charCodeAt(pos) === 125) {
      tailStart = pos + 1;
      break;
    }
    break;
  }

  if (keyCount === 0) return null;
  const hasEnvelopeSignal =
    keyCount >= 2 ||
    TIME_KEYS.some((k) => Object.prototype.hasOwnProperty.call(fields, k)) ||
    LEVEL_KEYS.some((k) => Object.prototype.hasOwnProperty.call(fields, k));
  if (!hasEnvelopeSignal) return null;

  const tail = raw.slice(tailStart).trim();
  return { fields, tail };
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function pad3(n: number): string {
  return n < 10 ? `00${n}` : n < 100 ? `0${n}` : `${n}`;
}

function formatDateLocal(ms: number): {
  timeShort: string;
  timeDate: string;
  timeFull: string;
} {
  const d = new Date(ms);
  const yyyy = d.getFullYear();
  const mm = pad2(d.getMonth() + 1);
  const dd = pad2(d.getDate());
  const hh = pad2(d.getHours());
  const mi = pad2(d.getMinutes());
  const ss = pad2(d.getSeconds());
  const mmm = pad3(d.getMilliseconds());
  const timeShort = `${hh}:${mi}:${ss}.${mmm}`;
  const timeDate = `${yyyy}-${mm}-${dd}`;
  return {
    timeShort,
    timeDate,
    timeFull: `${timeDate} ${timeShort}`,
  };
}

export interface FormattedLogTimestamp {
  timeShort: string;
  timeDate: string;
  timeFull: string;
  timeRaw: string;
}

const ISO_OR_DATETIME_RE =
  /^(\d{4})[-/](\d{2})[-/](\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:[.,](\d{1,9}))?(Z|[+-]\d{2}:?\d{2})?$/i;

export function formatLogTimestamp(raw: unknown): FormattedLogTimestamp | null {
  if (raw === null || raw === undefined) return null;
  const timeRaw = String(raw).trim();
  if (!timeRaw) return null;

  if (/^\d{10,19}$/.test(timeRaw)) {
    const ms =
      timeRaw.length === 10
        ? Number(timeRaw) * 1000
        : Number(timeRaw.slice(0, 13));
    if (Number.isFinite(ms) && ms >= 946_684_800_000 && ms <= 4_102_444_800_000) {
      const f = formatDateLocal(ms);
      return { ...f, timeRaw };
    }
  }

  const m = ISO_OR_DATETIME_RE.exec(timeRaw);
  if (m) {
    const date = `${m[1]}-${m[2]}-${m[3]}`;
    const hms = `${m[4]}:${m[5]}:${m[6]}`;
    const fracRaw = m[7] ?? '';
    const fracMs = fracRaw ? fracRaw.slice(0, 3).padEnd(3, '0') : '000';
    const tz = m[8] ? ` ${m[8].toUpperCase()}` : '';
    const timeShort = `${hms}.${fracMs}`;
    return {
      timeShort,
      timeDate: date,
      timeFull: `${date} ${timeShort}${tz}`,
      timeRaw,
    };
  }

  const hmsOnly = /^(\d{2}):(\d{2}):(\d{2})(?:[.,](\d{1,9}))?$/.exec(timeRaw);
  if (hmsOnly) {
    const fracMs = hmsOnly[4] ? hmsOnly[4].slice(0, 3).padEnd(3, '0') : '000';
    const timeShort = `${hmsOnly[1]}:${hmsOnly[2]}:${hmsOnly[3]}.${fracMs}`;
    return {
      timeShort,
      timeDate: '',
      timeFull: timeRaw,
      timeRaw,
    };
  }

  return null;
}

function consumeDockerStreamTag(
  text: string,
  pos: number
): { nextPos: number; streamTag: 'stderr' | 'stdout' | null } {
  let rest = pos;
  while (rest < text.length && (text.charCodeAt(rest) === 32 || text.charCodeAt(rest) === 9)) {
    rest++;
  }
  if (text.startsWith('[STDERR]', rest)) {
    rest += 8;
    while (rest < text.length && (text.charCodeAt(rest) === 32 || text.charCodeAt(rest) === 9)) {
      rest++;
    }
    return { nextPos: rest, streamTag: 'stderr' };
  }
  if (text.startsWith('[STDOUT]', rest)) {
    rest += 8;
    while (rest < text.length && (text.charCodeAt(rest) === 32 || text.charCodeAt(rest) === 9)) {
      rest++;
    }
    return { nextPos: rest, streamTag: 'stdout' };
  }
  return { nextPos: rest, streamTag: null };
}

/**
 * Skips optional Docker RFC3339Nano prefix and `[STDERR]`/`[STDOUT]` tag or leading 19-digit ns prefix.
 */
function detectLogLinePrefix(text: string): {
  bodyStart: number;
  prefixTime: FormattedLogTimestamp | null;
  streamTag: 'stderr' | 'stdout' | null;
  isDockerPrefix: boolean;
} {
  if (!text) {
    return { bodyStart: 0, prefixTime: null, streamTag: null, isDockerPrefix: false };
  }

  const nanoOff = skipLeadingNanoTimestampOffset(text);
  if (nanoOff > 0) {
    const nano = extractLeadingNanoTimestamp(text);
    const tagged = consumeDockerStreamTag(text, nanoOff);
    return {
      bodyStart: tagged.nextPos,
      prefixTime: nano
        ? {
            timeShort: nano.fullFormattedTime.slice(11),
            timeDate: nano.fullFormattedTime.slice(0, 10),
            timeFull: nano.fullFormattedTime,
            timeRaw: nano.nsStr,
          }
        : null,
      streamTag: tagged.streamTag,
      isDockerPrefix: tagged.streamTag !== null,
    };
  }

  // Fast character check for RFC3339 prefix: YYYY-MM-DDTHH:MM:SS...
  if (
    text.length >= 22 &&
    text.charCodeAt(4) === 45 &&
    text.charCodeAt(7) === 45 &&
    text.charCodeAt(10) === 84 && // 'T'
    text.charCodeAt(13) === 58 &&
    text.charCodeAt(16) === 58
  ) {
    const sp = text.indexOf(' ', 19);
    if (sp > 19 && sp <= 44) {
      const tsSlice = text.slice(0, sp);
      const parsedTs = formatLogTimestamp(tsSlice);
      if (parsedTs) {
        const tagged = consumeDockerStreamTag(text, sp + 1);
        return {
          bodyStart: tagged.nextPos,
          prefixTime: parsedTs,
          streamTag: tagged.streamTag,
          isDockerPrefix: true,
        };
      }
    }
  }

  // Bare leading [STDERR] / [STDOUT]
  const bare = consumeDockerStreamTag(text, 0);
  if (bare.streamTag !== null) {
    return {
      bodyStart: bare.nextPos,
      prefixTime: null,
      streamTag: bare.streamTag,
      isDockerPrefix: true,
    };
  }

  return { bodyStart: 0, prefixTime: null, streamTag: null, isDockerPrefix: false };
}

function estimateColumnsSlice(text: string, from: number, maxCols: number): number {
  const end = Math.min(text.length, from + maxCols);
  let cols = 0;
  for (let i = from; i < end; i++) {
    cols += text.charCodeAt(i) >= 0x2e80 ? 1.67 : 1;
  }
  return Math.max(24, Math.round(cols));
}

function isJsonTimeKey(text: string, kStart: number, kLen: number): boolean {
  const c0 = text.charCodeAt(kStart);
  switch (kLen) {
    case 1:
      return c0 === 116; // t
    case 2:
      return c0 === 116 && text.charCodeAt(kStart + 1) === 115; // ts
    case 4:
      return (
        (c0 === 116 && text.startsWith('time', kStart)) ||
        (c0 === 100 && text.startsWith('date', kStart))
      );
    case 7:
      return c0 === 97 && text.startsWith('asctime', kStart);
    case 8:
      return c0 === 100 && text.startsWith('datetime', kStart);
    case 9:
      return c0 === 116 && text.startsWith('timestamp', kStart);
    case 10:
      return c0 === 64 && text.startsWith('@timestamp', kStart);
    default:
      return false;
  }
}

function isJsonLevelKey(text: string, kStart: number, kLen: number): boolean {
  const c0 = text.charCodeAt(kStart);
  switch (kLen) {
    case 1:
      return c0 === 108; // l
    case 3:
      return c0 === 108 && text.startsWith('lvl', kStart);
    case 5:
      return c0 === 108 && text.startsWith('level', kStart);
    case 8:
      return c0 === 115 && text.startsWith('severity', kStart);
    case 9:
      return c0 === 108 && text.startsWith('levelname', kStart);
    default:
      return false;
  }
}

function getJsonCategoryPriority(text: string, kStart: number, kLen: number): number {
  const c0 = text.charCodeAt(kStart);
  switch (kLen) {
    case 3:
      return c0 === 97 && text.startsWith('app', kStart) ? 5 : 99;
    case 6:
      if (c0 === 108 && text.startsWith('logger', kStart)) return 1;
      if (c0 === 109 && text.startsWith('module', kStart)) return 3;
      return 99;
    case 7:
      return c0 === 115 && text.startsWith('service', kStart) ? 4 : 99;
    case 8:
      if (c0 === 99 && text.startsWith('category', kStart)) return 0;
      if (c0 === 105 && text.startsWith('instance', kStart)) return 6;
      return 99;
    case 9:
      return c0 === 99 && text.startsWith('component', kStart) ? 2 : 99;
    default:
      return 99;
  }
}

function isJsonSummaryKey(text: string, kStart: number, kLen: number): boolean {
  const c0 = text.charCodeAt(kStart);
  switch (kLen) {
    case 3:
      return (
        (c0 === 109 && text.startsWith('msg', kStart)) ||
        (c0 === 101 && text.startsWith('err', kStart))
      );
    case 5:
      return (
        (c0 === 101 && text.startsWith('error', kStart)) ||
        (c0 === 114 && text.startsWith('route', kStart))
      );
    case 7:
      return c0 === 109 && text.startsWith('message', kStart);
    default:
      return false;
  }
}

/**
 * Single-pass bounded JSON envelope probe over `bodyStart .. bodyStart + 640`.
 */
function probeJsonEnvelopeFast(
  text: string,
  bodyStart: number,
  streamTag: 'stderr' | 'stdout' | null,
  prefixDateKey: string
): FastLogProbe {
  const scanTo = Math.min(text.length, bodyStart + 640);
  let pos = bodyStart + 1;
  let hasTime = false;
  let dateKey = prefixDateKey;
  let level: LogLevel = 'unknown';
  let levelFilterToken = '';
  let category = '';
  let categoryFilterToken = '';
  let catPriority = 99;
  let summaryValStart = -1;
  let summaryValLen = -1;

  while (pos < scanTo) {
    // Skip whitespace and commas
    while (pos < scanTo) {
      const c = text.charCodeAt(pos);
      if (c === 32 || c === 44 || c === 9 || c === 10 || c === 13) pos++;
      else break;
    }
    if (pos >= scanTo || text.charCodeAt(pos) === 125) break;
    if (text.charCodeAt(pos) !== 34) break;

    const keyQuoteStart = pos;
    const kStart = pos + 1;
    pos = kStart;
    while (pos < scanTo) {
      const kc = text.charCodeAt(pos);
      if (kc === 92) {
        pos += 2;
        continue;
      }
      if (kc === 34) break;
      pos++;
    }
    if (pos >= scanTo) break;
    const kLen = pos - kStart;
    pos++; // past closing '"'

    while (pos < scanTo) {
      const wc = text.charCodeAt(pos);
      if (wc === 32 || wc === 9 || wc === 10 || wc === 13) pos++;
      else break;
    }
    if (pos >= scanTo || text.charCodeAt(pos) !== 58) break; // ':'
    pos++;

    while (pos < scanTo) {
      const wc = text.charCodeAt(pos);
      if (wc === 32 || wc === 9 || wc === 10 || wc === 13) pos++;
      else break;
    }
    if (pos >= scanTo) break;

    const vStart = pos;
    const vCh = text.charCodeAt(vStart);

    const checkTime = !hasTime && isJsonTimeKey(text, kStart, kLen);
    const checkLevel = level === 'unknown' && isJsonLevelKey(text, kStart, kLen);
    const candCatPrio = catPriority > 0 ? getJsonCategoryPriority(text, kStart, kLen) : 99;
    const checkCat = candCatPrio < catPriority;
    const checkSummary = summaryValLen <= 0 && isJsonSummaryKey(text, kStart, kLen);

    if (checkTime) hasTime = true;

    if (vCh === 34) {
      const strStart = vStart + 1;
      let q = strStart;
      let hasEscape = false;
      const strLimit = checkSummary ? text.length : scanTo;
      while (q < strLimit) {
        const vc = text.charCodeAt(q);
        if (vc === 92) {
          hasEscape = true;
          q += 2;
          continue;
        }
        if (vc === 34) break;
        q++;
      }
      if (q < strLimit) {
        const valLen = q - strStart;
        if (checkTime && !dateKey && !hasEscape && valLen >= 10) {
          dateKey = extractAsciiDateKey(text, strStart, valLen);
        } else if (checkLevel && !hasEscape && valLen > 0 && valLen <= 32) {
          const rawVal = text.slice(strStart, q);
          const norm = LEVEL_MAP[rawVal] ?? normalizeLogLevel(rawVal);
          if (norm.level !== 'unknown') {
            level = norm.level;
            levelFilterToken = text.slice(keyQuoteStart, q + 1);
          }
        } else if (checkCat && !hasEscape && valLen > 0 && valLen <= 96) {
          category = text.slice(strStart, q);
          categoryFilterToken = text.slice(keyQuoteStart, q + 1);
          catPriority = candCatPrio;
        } else if (checkSummary && valLen > 0) {
          summaryValStart = strStart;
          summaryValLen = valLen;
        }
        pos = q + 1;
      } else {
        if (checkSummary && text.length > strStart) {
          summaryValStart = strStart;
          summaryValLen = text.length - strStart;
        }
        break;
      }
    } else if (vCh === 123 || vCh === 91) {
      let depth = 1;
      let inStr = false;
      let p = vStart + 1;
      while (p < scanTo && depth > 0) {
        const sc = text.charCodeAt(p);
        if (inStr) {
          if (sc === 92) {
            p += 2;
            continue;
          }
          if (sc === 34) inStr = false;
        } else {
          if (sc === 34) inStr = true;
          else if (sc === 123 || sc === 91) depth++;
          else if (sc === 125 || sc === 93) depth--;
        }
        p++;
      }
      if (depth > 0) break;
      pos = p;
    } else {
      let end = vStart;
      while (end < scanTo) {
        const nc = text.charCodeAt(end);
        if (nc === 44 || nc === 125 || nc === 32 || nc === 9 || nc === 10 || nc === 13) break;
        end++;
      }
      if (checkLevel && vCh >= 48 && vCh <= 57 && end - vStart <= 4) {
        const numVal = Number(text.slice(vStart, end));
        const norm = PINO_LEVEL_MAP[numVal];
        if (norm) {
          level = norm.level;
          levelFilterToken = text.slice(keyQuoteStart, end);
        }
      }
      pos = end;
    }

    if (hasTime && level !== 'unknown' && catPriority === 0 && summaryValLen > 0) {
      break;
    }
  }

  if (!hasTime && level === 'unknown') {
    return NON_LOG_PROBE;
  }

  if (level === 'unknown' && streamTag === 'stderr') {
    level = 'error';
    levelFilterToken = '[STDERR]';
  }

  const estimatedSummaryCols =
    summaryValStart >= 0 && summaryValLen > 0
      ? Math.min(260, estimateColumnsSlice(text, summaryValStart, Math.min(240, summaryValLen)))
      : Math.min(260, estimateColumnsSlice(text, Math.min(text.length, bodyStart + 48), 240));

  return {
    isLog: true,
    dateKey,
    level,
    levelFilterToken,
    category,
    categoryFilterToken,
    estimatedSummaryCols,
    hasLongPayload: text.length - bodyStart > 160,
  };
}

/**
 * O(1) non-JSON-parsing log probe used for 20,000-row virtual layout & O(delta) stats.
 */
export function probeLogLineFast(text: string): FastLogProbe {
  if (!text) return NON_LOG_PROBE;

  const prefix = detectLogLinePrefix(text);
  const prefixDateKey = prefix.prefixTime?.timeDate ?? '';
  let bodyStart = prefix.bodyStart;
  while (bodyStart < text.length && (text.charCodeAt(bodyStart) === 32 || text.charCodeAt(bodyStart) === 9)) {
    bodyStart++;
  }
  if (bodyStart >= text.length) return NON_LOG_PROBE;

  const firstChar = text.charCodeAt(bodyStart);

  // 1. JSON log envelope fast path (single-pass bounded scan)
  if (firstChar === 123) {
    return probeJsonEnvelopeFast(text, bodyStart, prefix.streamTag, prefixDateKey);
  }

  const bodyDateKey =
    prefixDateKey || extractAsciiDateKey(text, bodyStart, text.length - bodyStart);

  // 2. Logfmt / KV fast path: look for level= or lvl= or prefixTime + key=val
  const scanHead = text.slice(bodyStart, Math.min(text.length, bodyStart + 384));
  const kvLevel = /(?:^|[\s,])(level|lvl|severity)=["']?([a-zA-Z]+)["']?/i.exec(scanHead);
  if (kvLevel) {
    const norm = normalizeLogLevel(kvLevel[2]);
    if (norm.level !== 'unknown') {
      const catKv = /(?:^|[\s,])(category|logger|component|service|module)=["']?([^\s,"']+)["']?/i.exec(scanHead);
      const tokenRaw = kvLevel[0].trim().replace(/^,/, '').trim();
      return {
        isLog: true,
        dateKey: bodyDateKey,
        level: norm.level,
        levelFilterToken: tokenRaw,
        category: catKv ? catKv[2] : '',
        categoryFilterToken: catKv ? catKv[0].trim().replace(/^,/, '').trim() : '',
        estimatedSummaryCols: Math.min(240, estimateColumnsSlice(text, bodyStart, 240)),
        hasLongPayload: text.length - bodyStart > 160,
      };
    }
  }

  // 3. Text log fast path: leading timestamp (either prefix or YYYY-MM-DD HH:MM:SS...) + level token
  const headStartsDate = bodyDateKey.length === 10 &&
    text.length - bodyStart >= 19 &&
    (text.charCodeAt(bodyStart + 10) === 84 || text.charCodeAt(bodyStart + 10) === 32) &&
    text.charCodeAt(bodyStart + 13) === 58;

  if (prefix.prefixTime || headStartsDate || prefix.streamTag !== null) {
    const lvlMatch =
      /(?:^|[\s[\](])(FATAL|CRIT|CRITICAL|PANIC|ERROR|ERR|WARN|WARNING|INFO|DEBUG|DBG|TRACE)(?=[\s\]):,]|$)/i.exec(
        scanHead
      );
    if (lvlMatch) {
      const norm = normalizeLogLevel(lvlMatch[1]);
      if (norm.level !== 'unknown') {
        return {
          isLog: true,
          dateKey: bodyDateKey,
          level: norm.level,
          levelFilterToken: lvlMatch[1],
          category: '',
          categoryFilterToken: '',
          estimatedSummaryCols: Math.min(240, estimateColumnsSlice(text, bodyStart, 240)),
          hasLongPayload: text.length - bodyStart > 160,
        };
      }
    }
    if (prefix.prefixTime || prefix.streamTag !== null) {
      const kvMatches = scanHead.match(/(?:^|\s)[a-zA-Z_][a-zA-Z0-9_.-]*=/g);
      if (kvMatches && kvMatches.length >= 2) {
        return {
          isLog: true,
          dateKey: bodyDateKey,
          level: prefix.streamTag === 'stderr' ? 'error' : 'unknown',
          levelFilterToken: prefix.streamTag === 'stderr' ? '[STDERR]' : '',
          category: '',
          categoryFilterToken: '',
          estimatedSummaryCols: Math.min(240, estimateColumnsSlice(text, bodyStart, 240)),
          hasLongPayload: text.length - bodyStart > 160,
        };
      }
    }
  }

  return NON_LOG_PROBE;
}

const logProbeCache = new WeakMap<HitItem, FastLogProbe>();

/**
 * WeakMap-cached O(1) fast log probe so `classifyHit`, layout measurement,
 * and `LogStreamStatsTracker` scan each `HitItem` at most once.
 */
export function getCachedLogProbe(item: HitItem): FastLogProbe {
  let cached = logProbeCache.get(item);
  if (cached) return cached;
  cached = probeLogLineFast(item.text);
  logProbeCache.set(item, cached);
  return cached;
}

function deepHumanizeLogValue(val: unknown, depth = 0): unknown {
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
          return deepHumanizeLogValue(inner, depth + 1);
        }
      } catch {
        // keep string
      }
    }
    return decodeHumanEscapes(val);
  }
  if (Array.isArray(val)) {
    return val.map((item) => deepHumanizeLogValue(item, depth + 1));
  }
  if (typeof val === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(val as Record<string, unknown>)) {
      out[k] = deepHumanizeLogValue(v, depth + 1);
    }
    return out;
  }
  return val;
}

function pickStringField(
  obj: Record<string, unknown>,
  keys: readonly string[]
): { key: string; value: string } | null {
  for (const k of keys) {
    const v = obj[k];
    if (typeof v === 'string' && v.trim().length > 0) {
      return { key: k, value: v.trim() };
    }
  }
  return null;
}

function formatLatencyText(raw: unknown): string | undefined {
  if (typeof raw === 'string' && raw.trim().length > 0) {
    return raw.trim();
  }
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    if (raw === 0) return '0ms';
    return Number.isInteger(raw) ? `${raw}ms` : `${raw.toFixed(2)}ms`;
  }
  return undefined;
}

function formatJsonFilterToken(
  rawBody: string,
  key: string,
  val: string | number
): string {
  const compact = typeof val === 'number' ? `"${key}":${val}` : `"${key}":"${val}"`;
  if (rawBody.includes(compact)) return compact;
  const spaced = typeof val === 'number' ? `"${key}": ${val}` : `"${key}": "${val}"`;
  if (rawBody.includes(spaced)) return spaced;
  return typeof val === 'string' ? val : String(val);
}

function formatKvToken(rawBody: string, key: string, val: string): string {
  const unquoted = `${key}=${val}`;
  if (rawBody.includes(unquoted)) return unquoted;
  const quoted = `${key}="${val}"`;
  if (rawBody.includes(quoted)) return quoted;
  return val;
}

function buildRecordFromObject(params: {
  obj: Record<string, unknown>;
  rawBody: string;
  format: LogFormat;
  truncated: boolean;
  truncatedTail?: string;
  prefixTime: FormattedLogTimestamp | null;
  streamTag: 'stderr' | 'stdout' | null;
}): ParsedLogRecord {
  const { obj, rawBody, format, truncated, truncatedTail, prefixTime, streamTag } = params;

  // 1. Timestamp
  let timeInfo: FormattedLogTimestamp | null = null;
  for (const k of TIME_KEYS) {
    if (obj[k] !== undefined && obj[k] !== null) {
      timeInfo = formatLogTimestamp(obj[k]);
      if (timeInfo) break;
    }
  }
  if (!timeInfo) timeInfo = prefixTime;

  // 2. Level
  let level: LogLevel = 'unknown';
  let levelBadge = '';
  let levelFilterToken = '';
  for (const k of LEVEL_KEYS) {
    const rawVal = obj[k];
    if (rawVal === undefined || rawVal === null) continue;
    const norm = normalizeLogLevel(rawVal);
    if (norm.level !== 'unknown') {
      level = norm.level;
      levelBadge = norm.badge;
      levelFilterToken =
        typeof rawVal === 'number' || typeof rawVal === 'string'
          ? formatJsonFilterToken(rawBody, k, typeof rawVal === 'number' ? rawVal : rawVal.trim())
          : '';
      break;
    }
  }
  if (level === 'unknown' && streamTag === 'stderr') {
    level = 'error';
    levelBadge = 'ERR';
    levelFilterToken = '[STDERR]';
  }

  // 3. Category
  const catHit = pickStringField(obj, CATEGORY_KEYS);
  const category = catHit ? catHit.value : '';
  const categoryFilterToken = catHit
    ? formatJsonFilterToken(rawBody, catHit.key, catHit.value)
    : '';

  // 4. Trace ID
  const traceHit = pickStringField(obj, TRACE_KEYS);
  const traceId = traceHit ? traceHit.value : '';
  const traceKey = traceHit ? traceHit.key : '';
  const traceFilterToken = traceHit ? traceHit.value : '';

  // 5. HTTP metadata
  const methodHit = pickStringField(obj, ['method']);
  const routeHit = pickStringField(obj, ['route', 'path', 'url']);
  const uriHit = pickStringField(obj, ['uri']);
  const statusRaw = obj.status ?? obj.statusCode ?? obj.status_code;
  const statusNum =
    typeof statusRaw === 'number' && Number.isFinite(statusRaw)
      ? statusRaw
      : typeof statusRaw === 'string' && /^\d{3}$/.test(statusRaw.trim())
        ? Number(statusRaw.trim())
        : undefined;
  const latencyText = formatLatencyText(obj.latency ?? obj.use ?? obj.duration ?? obj.elapsed);
  const sizeField = pickStringField(obj, ['size', 'requestBodySize']);
  const sizeText =
    sizeField?.value ??
    (typeof obj.bytes === 'number' && Number.isFinite(obj.bytes) && obj.bytes > 0
      ? `${obj.bytes} B`
      : undefined);
  const ipHit = pickStringField(obj, ['ip', 'clientIP', 'remoteAddr']);
  const hostHit = pickStringField(obj, ['host']);

  const hasHttp = Boolean(methodHit || routeHit || uriHit || statusNum !== undefined);
  const http: LogHttpMeta | undefined = hasHttp
    ? {
        method: methodHit?.value,
        route: routeHit?.value,
        uri: uriHit?.value,
        status: statusNum,
        latencyText,
        sizeText,
        ip: ipHit?.value,
        host: hostHit?.value,
      }
    : undefined;

  // 6. Primary message, errorText, and smart summary
  const msgHit = pickStringField(obj, ['message', 'msg']);
  const errHit = pickStringField(obj, ['error', 'err']);
  const messageText = msgHit?.value ?? '';
  const errorText = errHit?.value ?? '';

  let summary = '';
  if (http?.method && (http.route || http.uri)) {
    summary = `${http.method} ${http.route || http.uri}`;
    if (errorText) summary = `${summary} — ${errorText}`;
    else if (messageText) summary = `${summary} — ${messageText}`;
  } else if (messageText && errorText && messageText !== errorText) {
    summary = `${messageText} — ${errorText}`;
  } else if (errorText) {
    summary = errorText;
  } else if (messageText) {
    summary = messageText;
  } else {
    // Metric / event records without message (e.g. entQuery, influxdbHTTPDo)
    const inlineParts: string[] = [];
    for (const [k, v] of Object.entries(obj)) {
      if (ENVELOPE_HIDE_KEYS.has(k)) continue;
      if (v === '' || v === null || v === undefined) continue;
      if (typeof v === 'object') continue;
      inlineParts.push(`${k}=${String(v)}`);
      if (inlineParts.length >= 6) break;
    }
    summary = inlineParts.join('  ');
  }

  // 7. High-signal compact keyFields
  const keyFields: LogKeyField[] = [];
  const usedFieldKeys = new Set<string>();
  const pushField = (
    key: string,
    label: string,
    value: string,
    role: LogKeyField['role'],
    filterToken?: string
  ) => {
    if (!value || usedFieldKeys.has(key)) return;
    usedFieldKeys.add(key);
    keyFields.push({
      key,
      label,
      value,
      role,
      filterToken: filterToken ?? formatJsonFilterToken(rawBody, key, value),
    });
  };

  if (traceId && traceKey) {
    pushField(traceKey, traceKey, traceId, 'trace', traceId);
  }
  for (const idKey of ['service', 'account', 'userID', 'uid', 'deviceID', 'ip', 'instance', 'schema']) {
    if (catHit?.key === idKey) continue;
    const v = obj[idKey];
    if (typeof v === 'string' && v.trim().length > 0) {
      pushField(idKey, idKey, v.trim(), 'identity');
    }
  }
  for (const mKey of ['latency', 'use', 'duration', 'total', 'size', 'requestBodySize', 'count']) {
    const v = obj[mKey];
    if (typeof v === 'string' && v.trim().length > 0) {
      pushField(mKey, mKey, v.trim(), 'metric');
    } else if (typeof v === 'number' && Number.isFinite(v)) {
      const formatted = mKey === 'latency' || mKey === 'use' || mKey === 'duration'
        ? formatLatencyText(v) ?? String(v)
        : String(v);
      pushField(mKey, mKey, formatted, 'metric', formatJsonFilterToken(rawBody, mKey, v));
    }
  }

  // 8. Remaining fields for Inspector details
  const remainingFields: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (ENVELOPE_HIDE_KEYS.has(k)) continue;
    if (k === 'error' || k === 'err') continue;
    if (catHit && k === catHit.key) continue;
    if (v === '' || v === null || v === undefined) continue;
    if (typeof v === 'object' && !Array.isArray(v) && Object.keys(v as object).length === 0) continue;
    if (Array.isArray(v) && v.length === 0) continue;
    remainingFields[k] = v;
  }

  return {
    kind: 'log',
    format,
    timeShort: timeInfo?.timeShort ?? '',
    timeDate: timeInfo?.timeDate ?? '',
    timeFull: timeInfo?.timeFull ?? '',
    timeRaw: timeInfo?.timeRaw ?? '',
    level,
    levelBadge,
    levelFilterToken,
    category,
    categoryFilterToken,
    summary: summary || rawBody.slice(0, 180),
    errorText,
    http,
    traceId,
    traceKey,
    traceFilterToken,
    keyFields,
    truncated,
    truncatedTail,
    structuredData: obj,
    remainingFields: Object.keys(remainingFields).length > 0 ? remainingFields : undefined,
    rawRestText: rawBody,
  };
}

function parseKvRecord(
  body: string,
  prefixTime: FormattedLogTimestamp | null,
  streamTag: 'stderr' | 'stdout' | null
): ParsedLogRecord | null {
  const kvRegex = /(?:^|[\s,;])([a-zA-Z0-9_.-]+)=("[^"]*"|'[^']*'|[^\s,;<>"']+)/g;
  const pairs: { key: string; value: string }[] = [];
  let firstKeyStart = -1;
  let lastMatchEnd = 0;
  let match: RegExpExecArray | null;
  while ((match = kvRegex.exec(body)) !== null) {
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
  if (pairs.length < 2) return null;

  const obj: Record<string, unknown> = {};
  for (const p of pairs) {
    obj[p.key] = p.value;
  }
  const hasLogSignal =
    LEVEL_KEYS.some((k) => k in obj) ||
    TIME_KEYS.some((k) => k in obj) ||
    Boolean(prefixTime) ||
    streamTag !== null;
  if (!hasLogSignal) return null;

  const leadingText = firstKeyStart > 0 ? body.slice(0, firstKeyStart).trim() : '';
  const trailingText = lastMatchEnd < body.length ? body.slice(lastMatchEnd).trim() : '';

  const rec = buildRecordFromObject({
    obj,
    rawBody: body,
    format: 'kv',
    truncated: false,
    prefixTime,
    streamTag,
  });

  if (rec.levelFilterToken) {
    for (const k of LEVEL_KEYS) {
      if (typeof obj[k] === 'string') {
        rec.levelFilterToken = formatKvToken(body, k, obj[k] as string);
        break;
      }
    }
  }
  if (rec.category && !rec.summary && leadingText) {
    rec.summary = leadingText;
  } else if (leadingText && !obj.message && !obj.msg && !obj.error && !obj.err) {
    rec.summary = [leadingText, rec.summary, trailingText].filter(Boolean).join('  ');
  }
  return rec;
}

function parseTextLogRecord(
  body: string,
  prefixTime: FormattedLogTimestamp | null,
  streamTag: 'stderr' | 'stdout' | null
): ParsedLogRecord | null {
  let rest = body.trim();
  let timeInfo = prefixTime;

  const leadDt =
    /^(\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d{1,9})?(?:Z|[+-]\d{2}:?\d{2})?)\s+(.*)$/i.exec(
      rest
    );
  if (leadDt) {
    const parsed = formatLogTimestamp(leadDt[1]);
    if (parsed) {
      timeInfo = parsed;
      rest = leadDt[2].trim();
    }
  }

  const lvlRe =
    /^[\[(]?(FATAL|CRIT|CRITICAL|PANIC|ERROR|ERR|WARN|WARNING|INFO|DEBUG|DBG|TRACE)[\])]?[:\s-]*(.*)$/i.exec(
      rest
    );
  let level: LogLevel = streamTag === 'stderr' ? 'error' : 'unknown';
  let levelBadge = streamTag === 'stderr' ? 'ERR' : '';
  let levelFilterToken = streamTag === 'stderr' ? '[STDERR]' : '';

  if (lvlRe) {
    const norm = normalizeLogLevel(lvlRe[1]);
    if (norm.level !== 'unknown') {
      level = norm.level;
      levelBadge = norm.badge;
      levelFilterToken = lvlRe[1];
      rest = lvlRe[2].trim();
    }
  }

  if (!timeInfo && level === 'unknown') return null;

  let category = '';
  let categoryFilterToken = '';
  const bracketCat = /^\[([a-zA-Z0-9_.:/-]{2,40})\]\s+(.*)$/.exec(rest);
  if (bracketCat) {
    category = bracketCat[1];
    categoryFilterToken = bracketCat[1];
    rest = bracketCat[2].trim();
  }

  const traceMatch = /\b(?:trace[_-]?id|request[_-]?id|req[_-]?id)[=:\s]+([a-zA-Z0-9-]{8,64})\b/i.exec(
    rest
  );

  return {
    kind: 'log',
    format: 'text-log',
    timeShort: timeInfo?.timeShort ?? '',
    timeDate: timeInfo?.timeDate ?? '',
    timeFull: timeInfo?.timeFull ?? '',
    timeRaw: timeInfo?.timeRaw ?? '',
    level,
    levelBadge,
    levelFilterToken,
    category,
    categoryFilterToken,
    summary: decodeHumanEscapes(rest || body),
    errorText: level === 'error' || level === 'fatal' ? decodeHumanEscapes(rest) : '',
    traceId: traceMatch ? traceMatch[1] : '',
    traceKey: traceMatch ? 'traceID' : '',
    traceFilterToken: traceMatch ? traceMatch[1] : '',
    keyFields: [],
    truncated: false,
    rawRestText: body,
  };
}

/**
 * Full structured log parser supporting NDJSON, hard-truncated JSON envelopes,
 * Docker RFC3339+JSON/KV streams, leading 19-digit ns logs, logfmt KV, and text logs.
 */
export function parseLogLine(text: string): ParsedLogRecord | null {
  if (!text) return null;

  const prefix = detectLogLinePrefix(text);
  const body = text.slice(prefix.bodyStart).trim();
  if (!body) return null;

  if (body.startsWith('{')) {
    try {
      const safeJson = preserveLargeJsonIntegers(body);
      const parsed = JSON.parse(safeJson);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        const humanized = deepHumanizeLogValue(parsed) as Record<string, unknown>;
        return buildRecordFromObject({
          obj: humanized,
          rawBody: body,
          format: prefix.isDockerPrefix ? 'docker-json' : 'ndjson',
          truncated: false,
          prefixTime: prefix.prefixTime,
          streamTag: prefix.streamTag,
        });
      }
    } catch {
      const recovered = parseTruncatedJsonEnvelope(body);
      if (recovered) {
        const humanized = deepHumanizeLogValue(recovered.fields) as Record<string, unknown>;
        return buildRecordFromObject({
          obj: humanized,
          rawBody: body,
          format: 'truncated-json',
          truncated: true,
          truncatedTail: recovered.tail || undefined,
          prefixTime: prefix.prefixTime,
          streamTag: prefix.streamTag,
        });
      }
    }
  }

  // Embedded JSON inside text log (e.g. `2026-...Z [STDERR] prefix {"t":...}`)
  const firstBrace = body.indexOf('{');
  const lastBrace = body.lastIndexOf('}');
  if (firstBrace > 0 && lastBrace > firstBrace + 1) {
    const candidate = body.slice(firstBrace, lastBrace + 1);
    try {
      const parsed = JSON.parse(preserveLargeJsonIntegers(candidate));
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        const humanized = deepHumanizeLogValue(parsed) as Record<string, unknown>;
        const rec = buildRecordFromObject({
          obj: humanized,
          rawBody: body,
          format: prefix.isDockerPrefix ? 'docker-json' : 'ndjson',
          truncated: false,
          prefixTime: prefix.prefixTime,
          streamTag: prefix.streamTag,
        });
        const lead = body.slice(0, firstBrace).trim();
        if (lead && !rec.category) {
          rec.category = lead.slice(0, 32);
          rec.categoryFilterToken = rec.category;
        }
        return rec;
      }
    } catch {
      // fall through
    }
  }

  const kv = parseKvRecord(body, prefix.prefixTime, prefix.streamTag);
  if (kv) return kv;

  return parseTextLogRecord(body, prefix.prefixTime, prefix.streamTag);
}
