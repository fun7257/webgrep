import type { BuiltinTimePreset } from './types.ts';
import { fuzzyMatchText, type HighlightRange } from './source-picker.ts';

export const BUILTIN_TIME_PRESETS: readonly BuiltinTimePreset[] = [
  '',
  '5m',
  '15m',
  '30m',
  '1h',
  '3h',
  '6h',
  '12h',
  '24h',
  'today',
  'yesterday',
  '7d',
  '30d',
];

export const FLAT_QUICK_TIME_PRESETS: readonly BuiltinTimePreset[] = [
  '5m',
  '15m',
  '30m',
  '1h',
  '3h',
  '6h',
  '12h',
  '24h',
  'today',
  'yesterday',
  '7d',
  '30d',
];

export interface TimePresetGroup {
  id: 'live' | 'hours' | 'days';
  presets: readonly BuiltinTimePreset[];
}

export const QUICK_TIME_PRESET_GROUPS: readonly TimePresetGroup[] = [
  { id: 'live', presets: ['5m', '15m', '30m', '1h'] },
  { id: 'hours', presets: ['3h', '6h', '12h', '24h'] },
  { id: 'days', presets: ['today', 'yesterday', '7d', '30d'] },
];

const BUILTIN_PRESET_SET = new Set<string>(BUILTIN_TIME_PRESETS);

export function isBuiltinTimePreset(spec: string): spec is BuiltinTimePreset {
  return BUILTIN_PRESET_SET.has(spec);
}

export interface TimeRangeDraft {
  startDate: string;
  startTime: string;
  endDate: string;
  endTime: string;
}

export interface FullTimeRangeDraft {
  start: string;
  end: string;
}

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

export function formatYmd(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

export function formatHms(d: Date): string {
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

export function isValidYmd(raw: string): boolean {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw.trim());
  if (!m) return false;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  if (y < 1970 || y > 2261 || mo < 1 || mo > 12 || d < 1 || d > 31) return false;
  const dt = new Date(y, mo - 1, d);
  return dt.getFullYear() === y && dt.getMonth() === mo - 1 && dt.getDate() === d;
}

export function normalizeTimeInput(raw: string, isEnd: boolean): string | null {
  const s = raw.trim();
  if (!s) return '';

  let hh = 0;
  let mm = 0;
  let ss = isEnd ? 59 : 0;

  const colonMatch = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(s);
  if (colonMatch) {
    hh = Number(colonMatch[1]);
    mm = Number(colonMatch[2]);
    if (colonMatch[3] !== undefined) ss = Number(colonMatch[3]);
  } else if (/^\d{4}$/.test(s)) {
    hh = Number(s.slice(0, 2));
    mm = Number(s.slice(2, 4));
  } else if (/^\d{6}$/.test(s)) {
    hh = Number(s.slice(0, 2));
    mm = Number(s.slice(2, 4));
    ss = Number(s.slice(4, 6));
  } else {
    return null;
  }

  if (hh < 0 || hh > 23 || mm < 0 || mm > 59 || ss < 0 || ss > 59) {
    return null;
  }
  return `${pad2(hh)}:${pad2(mm)}:${pad2(ss)}`;
}

const MONTH_ABBR: Record<string, string> = {
  jan: '01',
  feb: '02',
  mar: '03',
  apr: '04',
  may: '05',
  jun: '06',
  jul: '07',
  aug: '08',
  sep: '09',
  oct: '10',
  nov: '11',
  dec: '12',
};

function parseMonthToken(rawMon: string): string | null {
  if (rawMon.length < 3) return null;
  return MONTH_ABBR[rawMon.slice(0, 3).toLowerCase()] ?? null;
}

function applyAmPmHour(hh: number, ampm?: string): number {
  if (!ampm) return hh;
  if (hh < 1 || hh > 12) return -1;
  const up = ampm.toUpperCase();
  if (up === 'AM') return hh === 12 ? 0 : hh;
  return hh === 12 ? 12 : hh + 12;
}

function resolveParsedDateTime(
  datePart: string,
  hh: number,
  mm: number,
  ss: number,
  fracStr?: string,
  tz?: string
): { date: string; time: string } | null {
  if (!isValidYmd(datePart)) return null;
  if (hh < 0 || hh > 23 || mm > 59 || ss > 59) return null;

  if (tz) {
    const upperTz = tz.toUpperCase();
    const normTz =
      upperTz === 'Z' || upperTz === 'UTC' || upperTz === 'GMT'
        ? 'Z'
        : tz.includes(':')
          ? tz
          : `${tz.slice(0, 3)}:${tz.slice(3, 5)}`;
    const fracMs = fracStr ? `.${fracStr.slice(0, 3).padEnd(3, '0')}` : '';
    const iso = `${datePart}T${pad2(hh)}:${pad2(mm)}:${pad2(ss)}${fracMs}${normTz}`;
    const parsedMs = Date.parse(iso);
    if (!Number.isFinite(parsedMs)) return null;
    const d = new Date(parsedMs);
    return { date: formatYmd(d), time: formatHms(d) };
  }

  return { date: datePart, time: `${pad2(hh)}:${pad2(mm)}:${pad2(ss)}` };
}

export function parsePastedDateTime(raw: string): { date: string; time: string } | null {
  const s = raw.trim().replace(/^[[("']+|[)\]"',;]+$/g, '').trim();
  if (!s) return null;

  // Compact calendar YYYYMMDDHHmmss[.SSS][tz] or YYYYMMDDTHHmmssZ (checked before generic epoch)
  const compactMatch =
    /^(19\d{2}|20\d{2})(\d{2})(\d{2})(?:T)?(\d{2})(\d{2})(\d{2})?(?:[.,]?(\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (compactMatch) {
    const datePart = `${compactMatch[1]}-${compactMatch[2]}-${compactMatch[3]}`;
    const parsed = resolveParsedDateTime(
      datePart,
      Number(compactMatch[4]),
      Number(compactMatch[5]),
      compactMatch[6] !== undefined ? Number(compactMatch[6]) : 0,
      compactMatch[7],
      compactMatch[8]
    );
    if (parsed) return parsed;
  }

  // Compact date + separated time (YYYYMMDD HH:MM[:SS])
  const compactSpaceMatch =
    /^(19\d{2}|20\d{2})(\d{2})(\d{2})[T _]+(\d{1,2}):(\d{1,2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (compactSpaceMatch) {
    const datePart = `${compactSpaceMatch[1]}-${compactSpaceMatch[2]}-${compactSpaceMatch[3]}`;
    const parsed = resolveParsedDateTime(
      datePart,
      Number(compactSpaceMatch[4]),
      Number(compactSpaceMatch[5]),
      compactSpaceMatch[6] !== undefined ? Number(compactSpaceMatch[6]) : 0,
      compactSpaceMatch[7],
      compactSpaceMatch[8]
    );
    if (parsed) return parsed;
  }

  // Unix epoch integer or float (10s / 13ms / 16us / 19ns)
  const epochMatch = /^(\d{10,19})(?:\.\d+)?$/.exec(s);
  if (epochMatch) {
    const digits = epochMatch[1];
    let ms = 0;
    if (digits.length >= 16) {
      ms = Math.floor(Number(digits.slice(0, 13)));
    } else if (digits.length >= 13) {
      ms = Number(digits.slice(0, 13));
    } else {
      ms = Number(s) * 1000;
    }
    if (!Number.isFinite(ms) || ms <= 0) return null;
    const d = new Date(ms);
    if (Number.isNaN(d.getTime())) return null;
    return { date: formatYmd(d), time: formatHms(d) };
  }

  // ISO-8601 / Log4j / Slash / Dot / Underscore YMD (date-only or datetime)
  const ymdMatch =
    /^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[T _]+(\d{1,2}):(\d{1,2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(AM|PM)?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?)?$/i.exec(
      s
    );
  if (ymdMatch) {
    const datePart = `${ymdMatch[1]}-${pad2(Number(ymdMatch[2]))}-${pad2(Number(ymdMatch[3]))}`;
    if (ymdMatch[4] === undefined) {
      return isValidYmd(datePart) ? { date: datePart, time: '' } : null;
    }
    const hh = applyAmPmHour(Number(ymdMatch[4]), ymdMatch[8]);
    return resolveParsedDateTime(
      datePart,
      hh,
      Number(ymdMatch[5]),
      ymdMatch[6] !== undefined ? Number(ymdMatch[6]) : 0,
      ymdMatch[7],
      ymdMatch[9]
    );
  }

  // CJK YYYY年M月D日 [HH:MM[:SS] | H时m分s秒]
  const cjkMatch =
    /^(\d{4})年(\d{1,2})月(\d{1,2})日(?:\s*[T ]?\s*(\d{1,2})[:时](\d{1,2})(?:[:分](\d{1,2})秒?)?(?:[.,](\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?)?$/i.exec(
      s
    );
  if (cjkMatch) {
    const datePart = `${cjkMatch[1]}-${pad2(Number(cjkMatch[2]))}-${pad2(Number(cjkMatch[3]))}`;
    if (cjkMatch[4] === undefined) {
      return isValidYmd(datePart) ? { date: datePart, time: '' } : null;
    }
    return resolveParsedDateTime(
      datePart,
      Number(cjkMatch[4]),
      Number(cjkMatch[5]),
      cjkMatch[6] !== undefined ? Number(cjkMatch[6]) : 0,
      cjkMatch[7],
      cjkMatch[8]
    );
  }

  // Nginx / Apache CLF (14/Nov/2026:10:15:02 +0800) & DD-Mon-YYYY HH:mm:ss
  const clfMatch =
    /^(\d{1,2})[/-]([A-Za-z]{3,9})[/-](\d{4})[: T](\d{1,2}):(\d{2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (clfMatch) {
    const mmStr = parseMonthToken(clfMatch[2]);
    if (mmStr) {
      const datePart = `${clfMatch[3]}-${mmStr}-${pad2(Number(clfMatch[1]))}`;
      return resolveParsedDateTime(
        datePart,
        Number(clfMatch[4]),
        Number(clfMatch[5]),
        clfMatch[6] !== undefined ? Number(clfMatch[6]) : 0,
        clfMatch[7],
        clfMatch[8]
      );
    }
  }

  // RFC 2822 day-first ([Sat, ]14 Nov 2026 10:15:02 GMT)
  const rfcMatch =
    /^(?:[A-Za-z]{3,9},?\s+)?(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})[T ](\d{1,2}):(\d{2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (rfcMatch) {
    const mmStr = parseMonthToken(rfcMatch[2]);
    if (mmStr) {
      const datePart = `${rfcMatch[3]}-${mmStr}-${pad2(Number(rfcMatch[1]))}`;
      return resolveParsedDateTime(
        datePart,
        Number(rfcMatch[4]),
        Number(rfcMatch[5]),
        rfcMatch[6] !== undefined ? Number(rfcMatch[6]) : 0,
        rfcMatch[7],
        rfcMatch[8]
      );
    }
  }

  // Month-first (Nov 14, 2026 10:15:02 AM)
  const monthFirstMatch =
    /^(?:[A-Za-z]{3,9},?\s+)?([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(\d{4})[T ](\d{1,2}):(\d{2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(AM|PM)?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (monthFirstMatch) {
    const mmStr = parseMonthToken(monthFirstMatch[1]);
    if (mmStr) {
      const datePart = `${monthFirstMatch[3]}-${mmStr}-${pad2(Number(monthFirstMatch[2]))}`;
      const hh = applyAmPmHour(Number(monthFirstMatch[4]), monthFirstMatch[8]);
      return resolveParsedDateTime(
        datePart,
        hh,
        Number(monthFirstMatch[5]),
        monthFirstMatch[6] !== undefined ? Number(monthFirstMatch[6]) : 0,
        monthFirstMatch[7],
        monthFirstMatch[9]
      );
    }
  }

  // Apache ctime (Sat Nov 14 10:15:02.123456 2026)
  const ctimeMatch =
    /^(?:[A-Za-z]{3,9}\s+)([A-Za-z]{3,9})\s+(\d{1,2})\s+(\d{1,2}):(\d{2}):(\d{2})(?:[.,](\d{1,9}))?\s+(\d{4})\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (ctimeMatch) {
    const mmStr = parseMonthToken(ctimeMatch[1]);
    if (mmStr) {
      const datePart = `${ctimeMatch[7]}-${mmStr}-${pad2(Number(ctimeMatch[2]))}`;
      return resolveParsedDateTime(
        datePart,
        Number(ctimeMatch[3]),
        Number(ctimeMatch[4]),
        Number(ctimeMatch[5]),
        ctimeMatch[6],
        ctimeMatch[8]
      );
    }
  }

  // US MDY (11/14/2026 2:15:02 PM) & EU DMY (14.11.2026 10:15:02)
  const usEuMatch =
    /^(\d{1,2})([/.])(\d{1,2})\2(\d{4})[T ](\d{1,2}):(\d{2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(AM|PM)?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (usEuMatch) {
    const p1 = Number(usEuMatch[1]);
    const p2 = Number(usEuMatch[3]);
    let mon = p1;
    let day = p2;
    if (usEuMatch[2] === '.') {
      day = p1;
      mon = p2;
    } else if (p1 > 12) {
      day = p1;
      mon = p2;
    }
    const datePart = `${usEuMatch[4]}-${pad2(mon)}-${pad2(day)}`;
    const hh = applyAmPmHour(Number(usEuMatch[5]), usEuMatch[9]);
    return resolveParsedDateTime(
      datePart,
      hh,
      Number(usEuMatch[6]),
      usEuMatch[7] !== undefined ? Number(usEuMatch[7]) : 0,
      usEuMatch[8],
      usEuMatch[10]
    );
  }

  return null;
}

const EMBEDDED_TS_PATTERNS: readonly RegExp[] = [
  /(?:19|20)\d{2}[-/.]\d{1,2}[-/.]\d{1,2}(?:[T _]+\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d{1,9})?(?:\s*(?:AM|PM))?(?:\s*(?:Z|[+-]\d{2}:?\d{2}|UTC|GMT))?)?/i,
  /\d{1,2}[/-][A-Za-z]{3,9}[/-](?:19|20)\d{2}[: T]\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d{1,9})?(?:\s*(?:Z|[+-]\d{2}:?\d{2}|UTC|GMT))?/i,
  /(?:19|20)\d{2}年\d{1,2}月\d{1,2}日(?:\s*[T ]?\s*\d{1,2}[:时]\d{1,2}(?:[:分]\d{1,2}秒?)?(?:[.,]\d{1,9})?(?:\s*(?:Z|[+-]\d{2}:?\d{2}|UTC|GMT))?)?/i,
  /\d{1,2}([/.])\d{1,2}\1(?:19|20)\d{2}[T ]\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d{1,9})?(?:\s*(?:AM|PM))?(?:\s*(?:Z|[+-]\d{2}:?\d{2}|UTC|GMT))?/i,
  /\b(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?:T)?\d{6}(?:[.,]?\d{1,9})?(?:\s*(?:Z|[+-]\d{2}:?\d{2}|UTC|GMT))?\b/i,
  /^\s*[\[(]?(\d{10,19}(?:\.\d+)?)(?=[\])\s,;:]|$)/,
];

function candidateHasSeconds(candidate: string): boolean {
  if (/^\s*\d{10,19}(?:\.\d+)?\s*$/.test(candidate)) return true;
  if (/(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])T?\d{6}/.test(candidate)) return true;
  if (/\d{1,2}[:时]\d{2}[:分]\d{2}/.test(candidate)) return true;
  return false;
}

export interface ExtractedDateTime {
  date: string;
  time: string;
  hasSeconds: boolean;
  formatted: string;
}

export function extractPastedDateTime(
  raw: string,
  nowMs = Date.now(),
  isEnd = false
): ExtractedDateTime | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;

  const direct = parsePastedDateTime(trimmed);
  if (direct) {
    const hasSeconds = candidateHasSeconds(trimmed);
    const time =
      direct.time && !hasSeconds && isEnd ? `${direct.time.slice(0, 6)}59` : direct.time;
    return {
      date: direct.date,
      time,
      hasSeconds,
      formatted: time ? `${direct.date} ${time}` : direct.date,
    };
  }

  for (const re of EMBEDDED_TS_PATTERNS) {
    const m = re.exec(trimmed);
    if (!m) continue;
    const candidate = (m[1] && m[0].startsWith(trimmed[0] ?? '') ? m[1] : m[0]).trim();
    const parsed = parsePastedDateTime(candidate);
    if (!parsed) continue;
    const hasSeconds = candidateHasSeconds(candidate);
    const time =
      parsed.time && !hasSeconds && isEnd ? `${parsed.time.slice(0, 6)}59` : parsed.time;
    return {
      date: parsed.date,
      time,
      hasSeconds,
      formatted: time ? `${parsed.date} ${time}` : parsed.date,
    };
  }

  // Yearless syslog at start of line (e.g. "Nov 14 09:15:00 web01 ...")
  const syslogMatch =
    /^(?:[A-Za-z]{3,9}\s+)?([A-Za-z]{3})\s+(\d{1,2})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\b/.exec(
      trimmed
    );
  if (syslogMatch) {
    const mmStr = parseMonthToken(syslogMatch[1]);
    if (mmStr) {
      const yr = new Date(nowMs).getFullYear();
      const hasSeconds = syslogMatch[5] !== undefined;
      const ss = hasSeconds ? Number(syslogMatch[5]) : isEnd ? 59 : 0;
      const resolved = resolveParsedDateTime(
        `${yr}-${mmStr}-${pad2(Number(syslogMatch[2]))}`,
        Number(syslogMatch[3]),
        Number(syslogMatch[4]),
        ss
      );
      if (resolved) {
        return {
          date: resolved.date,
          time: resolved.time,
          hasSeconds,
          formatted: `${resolved.date} ${resolved.time}`,
        };
      }
    }
  }

  return null;
}

const REL_TIME_RE = /^(?:now\s*-\s*|-\s*)?(\d+(?:\.\d+)?)\s*(s|sec|m|min|h|hr|d|day|w)$/i;

function normalizeRelToken(raw: string): string | null {
  const m = REL_TIME_RE.exec(raw.trim());
  if (!m) return null;
  return `${m[1]}${m[2].toLowerCase()}`;
}

function splitBoundToken(token: string, isEnd: boolean): { date: string; time: string } {
  const clean = token.trim().replace(/^(\d{4})\/(\d{2})\/(\d{2})/, '$1-$2-$3');
  if (!clean) return { date: '', time: '' };

  const fullMatch = /^(\d{4}-\d{2}-\d{2})[T ](\d{1,2}:\d{2}(?::\d{2})?)$/.exec(clean);
  if (fullMatch && isValidYmd(fullMatch[1])) {
    return {
      date: fullMatch[1],
      time: normalizeTimeInput(fullMatch[2], isEnd) ?? '',
    };
  }

  if (isValidYmd(clean)) {
    return { date: clean, time: isEnd ? '23:59:59' : '00:00:00' };
  }

  const timeOnly = normalizeTimeInput(clean, isEnd);
  if (timeOnly !== null && timeOnly !== '') {
    return { date: '', time: timeOnly };
  }

  return { date: '', time: '' };
}

export function parseCustomRangeDraft(spec: string, nowMs = Date.now()): TimeRangeDraft {
  const clean = spec.trim();
  if (!clean) {
    return { startDate: '', startTime: '', endDate: '', endTime: '' };
  }

  const lower = clean.toLowerCase();
  if (lower === 'today') {
    const todayYmd = formatYmd(new Date(nowMs));
    return { startDate: todayYmd, startTime: '00:00:00', endDate: '', endTime: '' };
  }
  if (lower === 'yesterday') {
    const d = new Date(nowMs);
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() - 1);
    const ydayYmd = formatYmd(d);
    return { startDate: ydayYmd, startTime: '00:00:00', endDate: ydayYmd, endTime: '23:59:59' };
  }

  if (isBuiltinTimePreset(lower)) {
    return { startDate: '', startTime: '', endDate: '', endTime: '' };
  }

  if (/^\d{4}[-/]\d{2}[-/]\d{2}$/.test(clean)) {
    const normalized = clean.replace(/\//g, '-');
    if (isValidYmd(normalized)) {
      return {
        startDate: normalized,
        startTime: '00:00:00',
        endDate: normalized,
        endTime: '23:59:59',
      };
    }
  }

  const sep = clean.includes('..') ? '..' : clean.includes('~') ? '~' : null;
  if (sep) {
    const [leftRaw, rightRaw] = clean.split(sep, 2);
    const left = splitBoundToken(leftRaw, false);
    const right = splitBoundToken(rightRaw, true);
    return {
      startDate: left.date,
      startTime: left.time,
      endDate: right.date,
      endTime: right.time,
    };
  }

  const single = splitBoundToken(clean, false);
  return {
    startDate: single.date,
    startTime: single.time,
    endDate: '',
    endTime: '',
  };
}

function formatFullBoundDraft(raw: string, isEnd: boolean): string {
  const clean = raw.trim();
  if (!clean) return '';
  const rel = normalizeRelToken(clean);
  if (rel) return rel;
  const bound = splitBoundToken(clean, isEnd);
  if (bound.date) {
    return `${bound.date} ${bound.time || (isEnd ? '23:59:59' : '00:00:00')}`;
  }
  return clean;
}

export function parseFullTimeRangeDraft(spec: string): FullTimeRangeDraft {
  const clean = spec.trim();
  if (!clean) return { start: '', end: '' };

  const lower = clean.toLowerCase();
  if (isBuiltinTimePreset(lower)) {
    return { start: '', end: '' };
  }

  const rel = normalizeRelToken(clean);
  if (rel) {
    return { start: rel, end: '' };
  }

  if (/^\d{4}[-/]\d{2}[-/]\d{2}$/.test(clean)) {
    const normalized = clean.replace(/\//g, '-');
    if (isValidYmd(normalized)) {
      return {
        start: `${normalized} 00:00:00`,
        end: `${normalized} 23:59:59`,
      };
    }
  }

  const sep = clean.includes('..') ? '..' : clean.includes('~') ? '~' : null;
  if (sep) {
    const [leftRaw, rightRaw] = clean.split(sep, 2);
    return {
      start: formatFullBoundDraft(leftRaw, false),
      end: formatFullBoundDraft(rightRaw, true),
    };
  }

  return {
    start: formatFullBoundDraft(clean, false),
    end: '',
  };
}

interface ResolvedFullBound {
  kind: 'empty' | 'relative' | 'explicit';
  spec: string;
  date: string;
  dateOnly: boolean;
}

function resolveFullBound(
  raw: string,
  isEnd: boolean,
  fallbackYmd: string,
  nowMs: number
): ResolvedFullBound | null {
  const clean = raw.trim();
  if (!clean) {
    return { kind: 'empty', spec: '', date: '', dateOnly: false };
  }

  if (isEnd && (clean.toLowerCase() === 'now' || clean === '现在')) {
    return { kind: 'empty', spec: '', date: '', dateOnly: false };
  }

  const rel = normalizeRelToken(clean);
  if (rel) {
    return { kind: 'relative', spec: rel, date: '', dateOnly: false };
  }

  // Date-only: YYYY-MM-DD or YYYY/M/D
  const dateOnlyMatch = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/.exec(clean);
  if (dateOnlyMatch) {
    const ymd = `${dateOnlyMatch[1]}-${pad2(Number(dateOnlyMatch[2]))}-${pad2(Number(dateOnlyMatch[3]))}`;
    if (!isValidYmd(ymd)) return null;
    const hms = isEnd ? '23:59:59' : '00:00:00';
    return { kind: 'explicit', spec: `${ymd} ${hms}`, date: ymd, dateOnly: true };
  }

  // Date + Time: YYYY-MM-DD HH:mm[:ss] (or slash / T)
  const fullMatch = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})[T _]+(\d{1,2}:\d{2}(?::\d{2})?)$/.exec(clean);
  if (fullMatch) {
    const ymd = `${fullMatch[1]}-${pad2(Number(fullMatch[2]))}-${pad2(Number(fullMatch[3]))}`;
    if (!isValidYmd(ymd)) return null;
    const hms = normalizeTimeInput(fullMatch[4], isEnd);
    if (!hms) return null;
    return { kind: 'explicit', spec: `${ymd} ${hms}`, date: ymd, dateOnly: false };
  }

  // Time-only: HH:mm[:ss] or HHmm / HHmmss -> inherits fallback date
  if (/^(?:\d{1,2}:\d{2}(?::\d{2})?|\d{4}|\d{6})$/.test(clean)) {
    const hms = normalizeTimeInput(clean, isEnd);
    if (!hms) return null;
    return { kind: 'explicit', spec: `${fallbackYmd} ${hms}`, date: fallbackYmd, dateOnly: false };
  }

  // Fallback to 20+ log / ISO / epoch / pasted timestamp formats
  const extracted = extractPastedDateTime(clean, nowMs, isEnd);
  if (extracted) {
    const dateOnly = extracted.time === '';
    const hms = dateOnly ? (isEnd ? '23:59:59' : '00:00:00') : extracted.time;
    return { kind: 'explicit', spec: `${extracted.date} ${hms}`, date: extracted.date, dateOnly };
  }

  return null;
}

export function buildFullTimeRangeSpec(
  draft: FullTimeRangeDraft,
  nowMs = Date.now()
): { spec: string; error: 'empty' | 'invalid_start' | 'invalid_end' | null } {
  let rawStart = draft.start.trim();
  let rawEnd = draft.end.trim();

  if (!rawEnd) {
    const sep = rawStart.includes('..') ? '..' : rawStart.includes('~') ? '~' : null;
    if (sep) {
      const [leftRaw, rightRaw] = rawStart.split(sep, 2);
      rawStart = leftRaw.trim();
      rawEnd = rightRaw.trim();
    }
  }

  if (rawEnd.toLowerCase() === 'now' || rawEnd === '现在') {
    rawEnd = '';
  }

  if (!rawStart && !rawEnd) {
    return { spec: '', error: 'empty' };
  }

  const todayYmd = formatYmd(new Date(nowMs));
  const startRes = resolveFullBound(rawStart, false, todayYmd, nowMs);
  if (!startRes) {
    return { spec: '', error: 'invalid_start' };
  }

  const endFallbackYmd = startRes.kind === 'explicit' && startRes.date ? startRes.date : todayYmd;
  const endRes = resolveFullBound(rawEnd, true, endFallbackYmd, nowMs);
  if (!endRes) {
    return { spec: '', error: 'invalid_end' };
  }

  if (startRes.kind === 'relative' && endRes.kind === 'empty') {
    return { spec: startRes.spec, error: null };
  }

  let left = startRes.spec;
  let right = endRes.spec;

  if (
    startRes.kind === 'explicit' &&
    endRes.kind === 'explicit' &&
    left &&
    right &&
    left > right
  ) {
    if (startRes.dateOnly && endRes.dateOnly && startRes.date > endRes.date) {
      left = `${endRes.date} 00:00:00`;
      right = `${startRes.date} 23:59:59`;
    } else {
      const tmp = left;
      left = right;
      right = tmp;
    }
  }

  return { spec: `${left}..${right}`, error: null };
}

export function buildCustomRangeSpec(
  draft: TimeRangeDraft,
  nowMs = Date.now()
): { spec: string; error: 'empty' | 'invalid_start' | 'invalid_end' | null } {
  let rawStartDate = draft.startDate.trim().replace(/\//g, '-');
  let rawStartTime = draft.startTime.trim();
  let rawEndDate = draft.endDate.trim().replace(/\//g, '-');
  let rawEndTime = draft.endTime.trim();

  // Support pasted datetime directly inside date input without clipboard event
  if (rawStartDate && !isValidYmd(rawStartDate)) {
    const parsed = parsePastedDateTime(rawStartDate);
    if (parsed) {
      rawStartDate = parsed.date;
      if (!rawStartTime && parsed.time) rawStartTime = parsed.time;
    }
  }
  if (rawEndDate && !isValidYmd(rawEndDate)) {
    const parsed = parsePastedDateTime(rawEndDate);
    if (parsed) {
      rawEndDate = parsed.date;
      if (!rawEndTime && parsed.time) rawEndTime = parsed.time;
    }
  }

  if (!rawStartDate && !rawStartTime && !rawEndDate && !rawEndTime) {
    return { spec: '', error: 'empty' };
  }

  const todayYmd = formatYmd(new Date(nowMs));
  const effStartDate = rawStartDate || (rawStartTime ? todayYmd : '');
  const effEndDate = rawEndDate || (rawEndTime ? todayYmd : '');

  if (effStartDate && !isValidYmd(effStartDate)) {
    return { spec: '', error: 'invalid_start' };
  }
  const normStartTime = normalizeTimeInput(rawStartTime, false);
  if (normStartTime === null) {
    return { spec: '', error: 'invalid_start' };
  }

  if (effEndDate && !isValidYmd(effEndDate)) {
    return { spec: '', error: 'invalid_end' };
  }
  const normEndTime = normalizeTimeInput(rawEndTime, true);
  if (normEndTime === null) {
    return { spec: '', error: 'invalid_end' };
  }

  let left = effStartDate ? `${effStartDate} ${normStartTime || '00:00:00'}` : '';
  let right = effEndDate ? `${effEndDate} ${normEndTime || '23:59:59'}` : '';

  if (left && right && left > right) {
    if (effStartDate > effEndDate && !rawStartTime && !rawEndTime) {
      left = `${effEndDate} 00:00:00`;
      right = `${effStartDate} 23:59:59`;
    } else {
      const tmp = left;
      left = right;
      right = tmp;
    }
  }

  return { spec: `${left}..${right}`, error: null };
}

export interface DateTimeParts {
  year: string;
  month: string;
  day: string;
  hour: string;
  minute: string;
  second: string;
}

export type DateTimeSlot = keyof DateTimeParts;

export const DATETIME_SLOTS: readonly DateTimeSlot[] = [
  'year',
  'month',
  'day',
  'hour',
  'minute',
  'second',
];

export interface SyncedTimeRangeState {
  start: DateTimeParts;
  end: DateTimeParts;
  endIsNow: boolean;
}

export function dateToParts(d: Date): DateTimeParts {
  return {
    year: String(d.getFullYear()).padStart(4, '0'),
    month: pad2(d.getMonth() + 1),
    day: pad2(d.getDate()),
    hour: pad2(d.getHours()),
    minute: pad2(d.getMinutes()),
    second: pad2(d.getSeconds()),
  };
}

export function daysInMonth(year: number, month1to12: number): number {
  const safeYear = Math.min(2099, Math.max(1970, Math.trunc(year) || 2026));
  const safeMonth = Math.min(12, Math.max(1, Math.trunc(month1to12) || 1));
  return new Date(safeYear, safeMonth, 0).getDate();
}

export function clampDateTimeParts(
  parts: DateTimeParts,
  fallbackNowMs = Date.now()
): DateTimeParts {
  const fb = new Date(fallbackNowMs);
  const rawY = Number.parseInt(parts.year.trim(), 10);
  const rawM = Number.parseInt(parts.month.trim(), 10);
  const rawD = Number.parseInt(parts.day.trim(), 10);
  const rawH = Number.parseInt(parts.hour.trim(), 10);
  const rawMin = Number.parseInt(parts.minute.trim(), 10);
  const rawS = Number.parseInt(parts.second.trim(), 10);

  const y = Number.isFinite(rawY) ? Math.min(2099, Math.max(1970, rawY)) : fb.getFullYear();
  const m = Number.isFinite(rawM) ? Math.min(12, Math.max(1, rawM)) : fb.getMonth() + 1;
  const maxDay = daysInMonth(y, m);
  const d = Number.isFinite(rawD)
    ? Math.min(maxDay, Math.max(1, rawD))
    : Math.min(maxDay, fb.getDate());
  const h = Number.isFinite(rawH) ? Math.min(23, Math.max(0, rawH)) : 0;
  const min = Number.isFinite(rawMin) ? Math.min(59, Math.max(0, rawMin)) : 0;
  const s = Number.isFinite(rawS) ? Math.min(59, Math.max(0, rawS)) : 0;

  return {
    year: String(y).padStart(4, '0'),
    month: pad2(m),
    day: pad2(d),
    hour: pad2(h),
    minute: pad2(min),
    second: pad2(s),
  };
}

function wrapSlotValue(val: number, min: number, max: number, delta: number): number {
  const span = max - min + 1;
  return min + ((((val - min + delta) % span) + span) % span);
}

export function stepDateTimeSlot(
  parts: DateTimeParts,
  slot: DateTimeSlot,
  delta: number
): DateTimeParts {
  const norm = clampDateTimeParts(parts);
  let y = Number(norm.year);
  let m = Number(norm.month);
  let d = Number(norm.day);
  let h = Number(norm.hour);
  let min = Number(norm.minute);
  let s = Number(norm.second);

  switch (slot) {
    case 'year':
      y = wrapSlotValue(y, 1970, 2099, delta);
      break;
    case 'month':
      m = wrapSlotValue(m, 1, 12, delta);
      break;
    case 'day':
      d = wrapSlotValue(d, 1, daysInMonth(y, m), delta);
      break;
    case 'hour':
      h = wrapSlotValue(h, 0, 23, delta);
      break;
    case 'minute':
      min = wrapSlotValue(min, 0, 59, delta);
      break;
    case 'second':
      s = wrapSlotValue(s, 0, 59, delta);
      break;
  }

  const maxDay = daysInMonth(y, m);
  if (d > maxDay) d = maxDay;

  return {
    year: String(y).padStart(4, '0'),
    month: pad2(m),
    day: pad2(d),
    hour: pad2(h),
    minute: pad2(min),
    second: pad2(s),
  };
}

export function extractedToDateTimeParts(
  ext: ExtractedDateTime,
  isEnd: boolean
): DateTimeParts {
  const [year = '2026', month = '01', day = '01'] = ext.date.split('-');
  const [hour, minute, second] = ext.time
    ? ext.time.split(':')
    : isEnd
      ? ['23', '59', '59']
      : ['00', '00', '00'];
  return clampDateTimeParts({
    year,
    month,
    day,
    hour: hour ?? '00',
    minute: minute ?? '00',
    second: second ?? (isEnd ? '59' : '00'),
  });
}

function relTokenOffsetMs(raw: string): number | null {
  const m = REL_TIME_RE.exec(raw.trim());
  if (!m) return null;
  const num = Number(m[1]);
  const unit = m[2].toLowerCase();
  const mult = unit.startsWith('s')
    ? 1000
    : unit.startsWith('m')
      ? 60_000
      : unit.startsWith('h')
        ? 3_600_000
        : unit.startsWith('d')
          ? 86_400_000
          : 7 * 86_400_000;
  return num * mult;
}

function resolveAnyBoundParts(
  rawBound: string,
  isEnd: boolean,
  fallbackParts: DateTimeParts,
  nowMs: number
): DateTimeParts | null {
  const clean = rawBound.trim();
  if (!clean) return null;

  const relMs = relTokenOffsetMs(clean);
  if (relMs !== null) {
    return dateToParts(new Date(Math.max(1, Math.round(nowMs - relMs))));
  }

  const bound = splitBoundToken(clean, isEnd);
  if (bound.date) {
    const [year, month, day] = bound.date.split('-');
    const [hour, minute, second] = (bound.time || (isEnd ? '23:59:59' : '00:00:00')).split(':');
    return clampDateTimeParts({ year, month, day, hour, minute, second }, nowMs);
  }
  if (bound.time) {
    const [hour, minute, second] = bound.time.split(':');
    return clampDateTimeParts(
      {
        year: fallbackParts.year,
        month: fallbackParts.month,
        day: fallbackParts.day,
        hour,
        minute,
        second,
      },
      nowMs
    );
  }

  const ext = extractPastedDateTime(clean, nowMs, isEnd);
  if (ext) {
    return extractedToDateTimeParts(ext, isEnd);
  }

  return null;
}

export function resolveSyncedDateTimeParts(
  spec: string,
  nowMs = Date.now()
): SyncedTimeRangeState {
  const nowParts = dateToParts(new Date(nowMs));
  const todayMidnight = new Date(nowMs);
  todayMidnight.setHours(0, 0, 0, 0);
  const todayStartParts = dateToParts(todayMidnight);

  const clean = spec.trim();
  const lower = clean.toLowerCase();

  if (!clean || lower === 'today') {
    return {
      start: todayStartParts,
      end: nowParts,
      endIsNow: true,
    };
  }

  if (lower === 'yesterday') {
    const yday = new Date(todayMidnight.getTime());
    yday.setDate(yday.getDate() - 1);
    const ydayStart = dateToParts(yday);
    return {
      start: ydayStart,
      end: { ...ydayStart, hour: '23', minute: '59', second: '59' },
      endIsNow: false,
    };
  }

  const relMs = relTokenOffsetMs(clean);
  if (relMs !== null) {
    return {
      start: dateToParts(new Date(Math.max(1, Math.round(nowMs - relMs)))),
      end: nowParts,
      endIsNow: true,
    };
  }

  if (/^\d{4}[-/]\d{1,2}[-/]\d{1,2}$/.test(clean)) {
    const [y, mo, da] = clean.replace(/\//g, '-').split('-');
    const normalized = `${y}-${pad2(Number(mo))}-${pad2(Number(da))}`;
    if (isValidYmd(normalized)) {
      const [year, month, day] = normalized.split('-');
      return {
        start: { year, month, day, hour: '00', minute: '00', second: '00' },
        end: { year, month, day, hour: '23', minute: '59', second: '59' },
        endIsNow: false,
      };
    }
  }

  const sep = clean.includes('..') ? '..' : clean.includes('~') ? '~' : null;
  if (sep) {
    const [leftRaw, rightRaw] = clean.split(sep, 2);
    const startParts =
      resolveAnyBoundParts(leftRaw, false, todayStartParts, nowMs) ?? todayStartParts;
    if (!rightRaw.trim()) {
      return {
        start: startParts,
        end: nowParts,
        endIsNow: true,
      };
    }
    const endParts = resolveAnyBoundParts(rightRaw, true, startParts, nowMs) ?? nowParts;
    return {
      start: startParts,
      end: endParts,
      endIsNow: false,
    };
  }

  const singleStart =
    resolveAnyBoundParts(clean, false, todayStartParts, nowMs) ?? todayStartParts;
  return {
    start: singleStart,
    end: nowParts,
    endIsNow: true,
  };
}

export function formatDateTimePartsToSpec(parts: DateTimeParts): string {
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}:${parts.second}`;
}

export function buildSpecFromDateTimeParts(
  start: DateTimeParts,
  end: DateTimeParts,
  endIsNow: boolean
): string {
  const normStart = clampDateTimeParts(start);
  let left = formatDateTimePartsToSpec(normStart);
  if (endIsNow) {
    return `${left}..`;
  }
  const normEnd = clampDateTimeParts(end);
  let right = formatDateTimePartsToSpec(normEnd);
  if (left > right) {
    const tmp = left;
    left = right;
    right = tmp;
  }
  return `${left}..${right}`;
}

export function normalizeCanonicalRelToken(raw: string): string | null {
  const m =
    /^(?:now\s*-\s*|last\s+|past\s+|最近\s*|近\s*|-\s*)?(\d+(?:\.\d+)?)\s*(s|sec|secs|second|seconds|秒|秒钟|m|min|mins|minute|minutes|分|分钟|h|hr|hrs|hour|hours|小时|时|d|day|days|天|日|w|wk|wks|week|weeks|周|星期)$/i.exec(
      raw.trim()
    );
  if (!m) return null;
  const num = Number(m[1]);
  if (!Number.isFinite(num) || num <= 0) return null;
  const u = m[2].toLowerCase();
  let unit: 's' | 'm' | 'h' | 'd' | 'w';
  if (u === 's' || u.startsWith('sec') || u.startsWith('秒')) {
    unit = 's';
  } else if (u === 'm' || u.startsWith('min') || u === '分' || u === '分钟') {
    unit = 'm';
  } else if (u === 'h' || u.startsWith('hr') || u.startsWith('hour') || u === '小时' || u === '时') {
    unit = 'h';
  } else if (u === 'd' || u.startsWith('day') || u === '天' || u === '日') {
    unit = 'd';
  } else {
    unit = 'w';
  }
  const numStr = String(Number(m[1]));
  return `${numStr}${unit}`;
}

export function formatRelativeSpecHuman(spec: string, locale: 'zh' | 'en'): string | null {
  const canonical = normalizeCanonicalRelToken(spec);
  if (!canonical) return null;
  const unit = canonical.slice(-1) as 's' | 'm' | 'h' | 'd' | 'w';
  const numStr = canonical.slice(0, -1);
  const num = Number(numStr);
  if (locale === 'zh') {
    const unitZh: Record<typeof unit, string> = {
      s: '秒',
      m: '分钟',
      h: '小时',
      d: '天',
      w: '周',
    };
    return `最近 ${numStr} ${unitZh[unit]}`;
  }
  const singular = num === 1;
  const unitEn: Record<typeof unit, string> = {
    s: 'sec',
    m: 'min',
    h: singular ? 'hour' : 'hours',
    d: singular ? 'day' : 'days',
    w: singular ? 'week' : 'weeks',
  };
  return `Last ${numStr} ${unitEn[unit]}`;
}

export function formatTimeScopeLabel(
  spec: string,
  timeLabels: Record<string, string>,
  nowMs = Date.now()
): string {
  const clean = spec.trim();
  if (!clean) return timeLabels[''] ?? '';
  if (clean in timeLabels) return timeLabels[clean];

  const isZh = Object.values(timeLabels).some((v) => /[\u4e00-\u9fff]/.test(v));
  const relCanonical = normalizeCanonicalRelToken(clean);
  if (relCanonical) {
    if (relCanonical in timeLabels) return timeLabels[relCanonical];
    const human = formatRelativeSpecHuman(relCanonical, isZh ? 'zh' : 'en');
    if (human) return human;
  }

  const currentYear = String(new Date(nowMs).getFullYear());
  const shortDate = (ymd: string): string =>
    ymd.startsWith(`${currentYear}-`) ? ymd.slice(5) : ymd;
  const shortTime = (hms: string): string =>
    hms.endsWith(':00') || hms.endsWith(':59') ? hms.slice(0, 5) : hms;

  const draft = parseCustomRangeDraft(clean, nowMs);
  const { startDate, startTime, endDate, endTime } = draft;

  if (startDate && endDate) {
    const sTime = startTime || '00:00:00';
    const eTime = endTime || '23:59:59';

    if (startDate === endDate && sTime === '00:00:00' && eTime === '23:59:59') {
      return startDate;
    }
    if (sTime === '00:00:00' && eTime === '23:59:59') {
      return `${shortDate(startDate)} ~ ${shortDate(endDate)}`;
    }
    if (startDate === endDate) {
      return `${shortDate(startDate)} ${shortTime(sTime)} ~ ${shortTime(eTime)}`;
    }
    return `${shortDate(startDate)} ${shortTime(sTime)} ~ ${shortDate(endDate)} ${shortTime(eTime)}`;
  }

  if (startDate && !endDate) {
    const sTime = startTime || '00:00:00';
    return sTime === '00:00:00'
      ? `≥ ${shortDate(startDate)}`
      : `≥ ${shortDate(startDate)} ${shortTime(sTime)}`;
  }

  if (!startDate && endDate) {
    const eTime = endTime || '23:59:59';
    return eTime === '23:59:59'
      ? `≤ ${shortDate(endDate)}`
      : `≤ ${shortDate(endDate)} ${shortTime(eTime)}`;
  }

  return clean;
}

export function formatTimeTriggerLabel(
  spec: string,
  timeShortLabels: Record<string, string>,
  idleLabel: string,
  nowMs = Date.now()
): string {
  const clean = spec.trim();
  if (!clean) return idleLabel;
  if (clean in timeShortLabels) return timeShortLabels[clean];
  const relCanonical = normalizeCanonicalRelToken(clean);
  if (relCanonical) return relCanonical;
  return formatTimeScopeLabel(clean, timeShortLabels, nowMs);
}

export interface ParsedQuickTimeExpression {
  spec: string;
  kind: 'preset' | 'relative' | 'range';
}

export function parseQuickTimeExpression(
  rawInput: string,
  nowMs = Date.now()
): ParsedQuickTimeExpression | null {
  const clean = rawInput.trim();
  if (!clean) return null;

  const lower = clean.toLowerCase();
  if (
    lower === 'any' ||
    lower === 'any time' ||
    lower === 'all' ||
    lower === 'all time' ||
    clean === '不限' ||
    clean === '不限时间' ||
    clean === '全部' ||
    clean === '全部时间'
  ) {
    return { spec: '', kind: 'preset' };
  }
  if (lower === 'today' || clean === '今天' || clean === '今日') {
    return { spec: 'today', kind: 'preset' };
  }
  if (lower === 'yesterday' || lower === 'yday' || clean === '昨天' || clean === '昨日') {
    return { spec: 'yesterday', kind: 'preset' };
  }
  if (clean === '半小时' || lower === 'half hour') {
    return { spec: '30m', kind: 'preset' };
  }

  const rel = normalizeCanonicalRelToken(clean);
  if (rel) {
    return {
      spec: rel,
      kind: isBuiltinTimePreset(rel) ? 'preset' : 'relative',
    };
  }

  const rangeSep = clean.includes('..') ? '..' : clean.includes('~') ? '~' : null;
  if (rangeSep) {
    const [leftRaw, rightRaw] = clean.split(rangeSep, 2);
    if (!leftRaw.trim() && !rightRaw.trim()) return null;
    const todayYmd = formatYmd(new Date(nowMs));
    const startRes = resolveFullBound(leftRaw, false, todayYmd, nowMs);
    if (!startRes) return null;
    const endFallback = startRes.kind === 'explicit' && startRes.date ? startRes.date : todayYmd;
    const endRes = resolveFullBound(rightRaw, true, endFallback, nowMs);
    if (!endRes) return null;
    if (startRes.kind === 'empty' && endRes.kind === 'empty') return null;

    if (startRes.kind === 'relative' && endRes.kind === 'empty') {
      const canonical = normalizeCanonicalRelToken(startRes.spec) ?? startRes.spec;
      return {
        spec: canonical,
        kind: isBuiltinTimePreset(canonical) ? 'preset' : 'relative',
      };
    }

    const built = buildFullTimeRangeSpec({ start: leftRaw.trim(), end: rightRaw.trim() }, nowMs);
    if (built.error || !built.spec) return null;
    return { spec: built.spec, kind: 'range' };
  }

  const dateOnlyMatch = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/.exec(clean);
  if (dateOnlyMatch) {
    const ymd = `${dateOnlyMatch[1]}-${pad2(Number(dateOnlyMatch[2]))}-${pad2(Number(dateOnlyMatch[3]))}`;
    if (!isValidYmd(ymd)) return null;
    return { spec: ymd, kind: 'range' };
  }

  const colonTimeMatch = /^\d{1,2}:\d{2}(?::\d{2})?$/.test(clean);
  if (colonTimeMatch) {
    const hms = normalizeTimeInput(clean, false);
    if (!hms) return null;
    const todayYmd = formatYmd(new Date(nowMs));
    return { spec: `${todayYmd} ${hms}..`, kind: 'range' };
  }

  const ext = extractPastedDateTime(clean, nowMs, false);
  if (ext) {
    const hms = ext.time || '00:00:00';
    return { spec: `${ext.date} ${hms}..`, kind: 'range' };
  }

  return null;
}

export interface QuickTimeCandidate {
  key: string;
  spec: string;
  shortLabel: string;
  fullLabel: string;
  shortRanges: HighlightRange[];
  fullRanges: HighlightRange[];
  isCustom: boolean;
}

const PRESET_ALIASES: Record<string, readonly string[]> = {
  '': ['any', 'any time', 'all', 'all time', '不限', '全部', '全部时间'],
  today: ['today', 'tod', '今天', '今日'],
  yesterday: ['yesterday', 'yday', '昨天', '昨日'],
  '30m': ['半小时', 'half hour'],
};

export function matchQuickTimeCandidates(
  query: string,
  timeLabels: Record<string, string>,
  timeShortLabels: Record<string, string>,
  nowMs = Date.now()
): QuickTimeCandidate[] {
  const trimmed = query.trim();
  const parsed = trimmed ? parseQuickTimeExpression(trimmed, nowMs) : null;
  const presetsToScan: readonly BuiltinTimePreset[] = ['', ...FLAT_QUICK_TIME_PRESETS];

  const scored: Array<QuickTimeCandidate & { score: number }> = [];
  const seenSpecs = new Set<string>();

  if (!trimmed) {
    for (const preset of presetsToScan) {
      scored.push({
        key: `preset:${preset || 'any'}`,
        spec: preset,
        shortLabel: timeShortLabels[preset] ?? timeLabels[preset] ?? preset,
        fullLabel: timeLabels[preset] ?? preset,
        shortRanges: [],
        fullRanges: [],
        isCustom: false,
        score: 0,
      });
    }
    return scored;
  }

  const tokens = trimmed.split(/\s+/).filter(Boolean);
  for (const preset of presetsToScan) {
    const shortLabel = timeShortLabels[preset] ?? timeLabels[preset] ?? preset;
    const fullLabel = timeLabels[preset] ?? shortLabel;
    const aliases = PRESET_ALIASES[preset] ?? [];

    let totalScore = 0;
    let matchedAll = true;
    const shortRanges: HighlightRange[] = [];
    const fullRanges: HighlightRange[] = [];

    for (const tok of tokens) {
      const mFull = fuzzyMatchText(fullLabel, tok);
      const mShort = fuzzyMatchText(shortLabel, tok);
      const mCode = preset ? fuzzyMatchText(preset, tok) : null;
      let bestAliasScore = -Infinity;
      for (const alias of aliases) {
        const ma = fuzzyMatchText(alias, tok);
        if (ma && ma.score > bestAliasScore) bestAliasScore = ma.score;
      }

      if (!mFull && !mShort && !mCode && bestAliasScore === -Infinity) {
        matchedAll = false;
        break;
      }
      if (mFull) fullRanges.push(...mFull.ranges);
      if (mShort) shortRanges.push(...mShort.ranges);

      const best = Math.max(
        mFull?.score ?? -Infinity,
        mShort ? mShort.score + 10 : -Infinity,
        mCode ? mCode.score + 8 : -Infinity,
        bestAliasScore
      );
      totalScore += best;
    }

    if (matchedAll) {
      seenSpecs.add(preset);
      scored.push({
        key: `preset:${preset || 'any'}`,
        spec: preset,
        shortLabel,
        fullLabel,
        shortRanges,
        fullRanges,
        isCustom: false,
        score: totalScore + (parsed?.spec === preset ? 500 : 0),
      });
    }
  }

  scored.sort((a, b) => b.score - a.score);

  if (parsed && !seenSpecs.has(parsed.spec)) {
    const customFull = formatTimeScopeLabel(parsed.spec, timeLabels, nowMs);
    const customShort = formatTimeTriggerLabel(
      parsed.spec,
      timeShortLabels,
      timeShortLabels[''] ?? '',
      nowMs
    );
    scored.unshift({
      key: `custom:${parsed.spec}`,
      spec: parsed.spec,
      shortLabel: customShort,
      fullLabel: customFull,
      shortRanges: [],
      fullRanges: [],
      isCustom: true,
      score: 1000,
    });
  }

  return scored.map(({ score: _score, ...rest }) => rest);
}

export interface TimeFormatPreset {
  id: string;
  value: string;
  labelZh: string;
  labelEn: string;
  example: string;
}

export const TIME_FORMAT_PRESETS: TimeFormatPreset[] = [
  {
    id: 'auto',
    value: 'auto',
    labelZh: '自动识别',
    labelEn: 'Auto',
    example: '2026-11-14T09:15:00Z INFO ok',
  },
  {
    id: 'standard',
    value: 'yyyy-MM-dd HH:mm:ss',
    labelZh: '标准时间',
    labelEn: 'yyyy-MM-dd HH:mm:ss',
    example: '2026-11-14 09:15:00 ERROR timeout',
  },
  {
    id: 'iso8601',
    value: "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
    labelZh: 'ISO-8601',
    labelEn: 'ISO-8601',
    example: '2026-11-14T09:15:00.123+08:00 INFO ok',
  },
  {
    id: 'compact',
    value: 'yyyyMMddHHmmss',
    labelZh: '紧凑数字',
    labelEn: 'yyyyMMddHHmmss',
    example: '20261114091500 INFO batch ok',
  },
  {
    id: 'yyyy_hm',
    value: 'yyyy-hm',
    labelZh: 'yyyy-hm',
    labelEn: 'yyyy-hm',
    example: '2026-1030 WARN custom clock',
  },
  {
    id: 'slash',
    value: 'yyyy/MM/dd HH:mm:ss',
    labelZh: '斜杠日期',
    labelEn: 'yyyy/MM/dd HH:mm:ss',
    example: '2026/11/14 09:15:00 server crashed',
  },
  {
    id: 'clf',
    value: 'dd/MMM/yyyy:HH:mm:ss Z',
    labelZh: 'Nginx CLF',
    labelEn: 'Nginx CLF',
    example: '14/Nov/2026:09:15:00 +0800 "GET /api"',
  },
  {
    id: 'syslog',
    value: 'MMM d HH:mm:ss',
    labelZh: 'Syslog',
    labelEn: 'Syslog',
    example: 'Nov 14 09:15:00 web01 sshd[123]: ok',
  },
  {
    id: 'epoch',
    value: 'epoch',
    labelZh: 'Epoch 秒',
    labelEn: 'Epoch s',
    example: '1794647700 INFO worker ready',
  },
  {
    id: 'json_ts',
    value: 'json:timestamp',
    labelZh: 'JSON timestamp',
    labelEn: 'JSON timestamp',
    example: '{"timestamp":"2026-11-14T09:15:00Z","lvl":"ERROR"}',
  },
  {
    id: 'json_short',
    value: 'json:ts',
    labelZh: 'JSON ts',
    labelEn: 'JSON ts',
    example: '{"ts":1794647700123,"msg":"boom"}',
  },
  {
    id: 'regex_bracket',
    value: 'regex:\\[(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2})\\]',
    labelZh: '方括号正则',
    labelEn: 'Bracket Regex',
    example: '[ERROR] [2026-11-14 09:15:00] retry failed',
  },
];
