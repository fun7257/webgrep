import {
  extractLeadingNanoTimestamp,
  skipLeadingNanoTimestampOffset,
} from '../format.ts';
import type { HitItem } from '../types.ts';
import type { FastLogProbe } from './types.ts';

const NON_LOG_PROBE: FastLogProbe = {
  isLog: false,
  hasTime: false,
  isJson: false,
  isKv: false,
  dateKey: '',
  timeShort: '',
  timeLabel: '',
  timeFull: '',
  timeRaw: '',
  bodyStart: 0,
};

function isAsciiDigit(c: number): boolean {
  return c >= 48 && c <= 57;
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

function pad3(n: number): string {
  if (n < 10) return `00${n}`;
  if (n < 100) return `0${n}`;
  return String(n);
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

function consumeStreamTagOffset(text: string, pos: number): number {
  let rest = pos;
  while (rest < text.length && (text.charCodeAt(rest) === 32 || text.charCodeAt(rest) === 9)) {
    rest++;
  }
  if (text.startsWith('[STDERR]', rest) || text.startsWith('[STDOUT]', rest)) {
    rest += 8;
    while (rest < text.length && (text.charCodeAt(rest) === 32 || text.charCodeAt(rest) === 9)) {
      rest++;
    }
  }
  return rest;
}

function detectLeadingTimestampPrefix(text: string): {
  bodyStart: number;
  prefixTime: FormattedLogTimestamp | null;
} {
  if (!text) return { bodyStart: 0, prefixTime: null };

  const nanoOff = skipLeadingNanoTimestampOffset(text);
  if (nanoOff > 0) {
    const nano = extractLeadingNanoTimestamp(text);
    return {
      bodyStart: consumeStreamTagOffset(text, nanoOff),
      prefixTime: nano
        ? {
            timeShort: nano.fullFormattedTime.slice(11),
            timeDate: nano.fullFormattedTime.slice(0, 10),
            timeFull: nano.fullFormattedTime,
            timeRaw: nano.nsStr,
          }
        : null,
    };
  }

  // Fast ASCII check for leading YYYY-MM-DDTHH:MM:SS... or YYYY-MM-DD HH:MM:SS...
  if (
    text.length >= 19 &&
    (text.charCodeAt(4) === 45 || text.charCodeAt(4) === 47) &&
    text.charCodeAt(7) === text.charCodeAt(4) &&
    (text.charCodeAt(10) === 84 || text.charCodeAt(10) === 32) &&
    text.charCodeAt(13) === 58 &&
    text.charCodeAt(16) === 58 &&
    isAsciiDigit(text.charCodeAt(0)) &&
    isAsciiDigit(text.charCodeAt(18))
  ) {
    let sp = 19;
    while (sp < text.length && sp <= 44) {
      const c = text.charCodeAt(sp);
      if (c === 32 || c === 9) break;
      sp++;
    }
    const tsSlice = text.slice(0, sp);
    const parsedTs = formatLogTimestamp(tsSlice);
    if (parsedTs) {
      return {
        bodyStart: consumeStreamTagOffset(text, sp),
        prefixTime: parsedTs,
      };
    }
  }

  // Bare leading HH:MM:SS(.sss)?
  if (
    text.length >= 9 &&
    text.charCodeAt(2) === 58 &&
    text.charCodeAt(5) === 58 &&
    isAsciiDigit(text.charCodeAt(0)) &&
    isAsciiDigit(text.charCodeAt(7))
  ) {
    let sp = 8;
    while (sp < text.length && sp <= 20) {
      const c = text.charCodeAt(sp);
      if (c === 32 || c === 9) break;
      sp++;
    }
    const parsedTs = formatLogTimestamp(text.slice(0, sp));
    if (parsedTs) {
      return {
        bodyStart: consumeStreamTagOffset(text, sp),
        prefixTime: parsedTs,
      };
    }
  }

  return { bodyStart: consumeStreamTagOffset(text, 0), prefixTime: null };
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

function probeJsonTimeFast(
  text: string,
  bodyStart: number
): { hasKeys: boolean; ts: FormattedLogTimestamp | null } {
  const scanTo = Math.min(text.length, bodyStart + 640);
  let pos = bodyStart + 1;
  let hasKeys = false;

  while (pos < scanTo) {
    while (pos < scanTo) {
      const c = text.charCodeAt(pos);
      if (c === 32 || c === 44 || c === 9 || c === 10 || c === 13) pos++;
      else break;
    }
    if (pos >= scanTo || text.charCodeAt(pos) === 125) break;
    if (text.charCodeAt(pos) !== 34) break;

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
    pos++;

    while (pos < scanTo) {
      const wc = text.charCodeAt(pos);
      if (wc === 32 || wc === 9 || wc === 10 || wc === 13) pos++;
      else break;
    }
    if (pos >= scanTo || text.charCodeAt(pos) !== 58) break;
    pos++;
    hasKeys = true;

    while (pos < scanTo) {
      const wc = text.charCodeAt(pos);
      if (wc === 32 || wc === 9 || wc === 10 || wc === 13) pos++;
      else break;
    }
    if (pos >= scanTo) break;

    const vStart = pos;
    const vCh = text.charCodeAt(vStart);
    const checkTime = isJsonTimeKey(text, kStart, kLen);

    if (vCh === 34) {
      pos++;
      while (pos < scanTo) {
        const sc = text.charCodeAt(pos);
        if (sc === 92) {
          pos += 2;
          continue;
        }
        if (sc === 34) break;
        pos++;
      }
      if (pos < scanTo && text.charCodeAt(pos) === 34) {
        if (checkTime) {
          const ts = formatLogTimestamp(text.slice(vStart + 1, pos));
          if (ts) return { hasKeys: true, ts };
        }
        pos++;
      }
    } else if (vCh === 123 || vCh === 91) {
      let depth = 1;
      let inStr = false;
      pos++;
      while (pos < scanTo && depth > 0) {
        const nc = text.charCodeAt(pos);
        if (inStr) {
          if (nc === 92) {
            pos += 2;
            continue;
          }
          if (nc === 34) inStr = false;
        } else if (nc === 34) {
          inStr = true;
        } else if (nc === 123 || nc === 91) {
          depth++;
        } else if (nc === 125 || nc === 93) {
          depth--;
        }
        pos++;
      }
    } else {
      while (pos < scanTo) {
        const pc = text.charCodeAt(pos);
        if (pc === 44 || pc === 125 || pc === 32 || pc === 9 || pc === 10 || pc === 13) break;
        pos++;
      }
      if (checkTime) {
        const ts = formatLogTimestamp(text.slice(vStart, pos));
        if (ts) return { hasKeys: true, ts };
      }
    }
  }

  return { hasKeys, ts: null };
}

function buildCompactTimeLabel(ts: FormattedLogTimestamp | null): string {
  if (!ts) return '';
  if (ts.timeDate && ts.timeShort) {
    return `${ts.timeDate.slice(5)} ${ts.timeShort}`;
  }
  return ts.timeShort || ts.timeFull;
}

const KV_PROBE_RE = /(?:^|[\s,;])([a-zA-Z0-9_.-]+)=("[^"]*"|'[^']*'|[^\s,;<>"']+)/g;
const KV_TIME_KEY_SET = new Set(['t', 'ts', 'time', 'timestamp', '@timestamp', 'datetime', 'date']);

/**
 * O(1) bounded line-log probe extracting only timestamp & JSON/KV structural signals.
 * Never invents levels, categories, trace IDs, or synthetic summaries.
 */
export function probeLogLineFast(text: string): FastLogProbe {
  if (!text) return NON_LOG_PROBE;

  const { bodyStart, prefixTime } = detectLeadingTimestampPrefix(text);
  let pos = bodyStart;
  while (pos < text.length && (text.charCodeAt(pos) === 32 || text.charCodeAt(pos) === 9)) {
    pos++;
  }
  if (pos >= text.length && !prefixTime) return NON_LOG_PROBE;

  const firstChar = pos < text.length ? text.charCodeAt(pos) : 0;
  let ts: FormattedLogTimestamp | null = prefixTime;
  let isJson = false;
  let isKv = false;

  if (firstChar === 123) {
    const jsonScan = probeJsonTimeFast(text, pos);
    isJson = jsonScan.hasKeys;
    if (!ts && jsonScan.ts) ts = jsonScan.ts;
  } else {
    const scanHead = text.slice(pos, Math.min(text.length, pos + 384));
    KV_PROBE_RE.lastIndex = 0;
    let kvCount = 0;
    let m: RegExpExecArray | null;
    while ((m = KV_PROBE_RE.exec(scanHead)) !== null) {
      kvCount++;
      if (!ts && KV_TIME_KEY_SET.has(m[1].toLowerCase())) {
        const cleanVal = m[2].replace(/^["']|["']$/g, '');
        const parsed = formatLogTimestamp(cleanVal);
        if (parsed) ts = parsed;
      }
      if (kvCount >= 3 && ts) break;
    }
    if (kvCount >= 3 || (prefixTime !== null && kvCount >= 2)) {
      isKv = true;
    }
  }

  const hasTime = ts !== null;
  const isLog = hasTime || isJson || isKv;
  if (!isLog) return NON_LOG_PROBE;

  return {
    isLog,
    hasTime,
    isJson,
    isKv,
    dateKey: ts?.timeDate ?? '',
    timeShort: ts?.timeShort ?? '',
    timeLabel: buildCompactTimeLabel(ts),
    timeFull: ts?.timeFull ?? '',
    timeRaw: ts?.timeRaw ?? '',
    bodyStart: pos,
  };
}

export function extractLineTime(text: string): FormattedLogTimestamp | null {
  const probe = probeLogLineFast(text);
  if (!probe.hasTime) return null;
  return {
    timeShort: probe.timeShort,
    timeDate: probe.dateKey,
    timeFull: probe.timeFull,
    timeRaw: probe.timeRaw,
  };
}

const logProbeCache = new WeakMap<HitItem, FastLogProbe>();

export function getCachedLogProbe(item: HitItem): FastLogProbe {
  let cached = logProbeCache.get(item);
  if (cached) return cached;
  cached = probeLogLineFast(item.text);
  logProbeCache.set(item, cached);
  return cached;
}
