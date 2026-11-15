import type { BuiltinTimePreset } from './types.ts';

export const BUILTIN_TIME_PRESETS: readonly BuiltinTimePreset[] = [
  '',
  '15m',
  '1h',
  '6h',
  '24h',
  'today',
  'yesterday',
  '7d',
  '30d',
];

const BUILTIN_PRESET_SET = new Set<string>(BUILTIN_TIME_PRESETS);

export function isBuiltinTimePreset(spec: string): spec is BuiltinTimePreset {
  return BUILTIN_PRESET_SET.has(spec);
}

export interface CalendarDayCell {
  ymd: string;
  day: number;
  inMonth: boolean;
  isToday: boolean;
}

export interface TimeRangeDraft {
  startDate: string;
  startTime: string;
  endDate: string;
  endTime: string;
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

export function buildCalendarMonthGrid(
  year: number,
  monthIndex0: number,
  todayYmd: string
): CalendarDayCell[] {
  const firstOfMonth = new Date(year, monthIndex0, 1);
  // Monday = 0 ... Sunday = 6
  const leadDays = (firstOfMonth.getDay() + 6) % 7;
  const gridStart = new Date(year, monthIndex0, 1 - leadDays);

  const cells: CalendarDayCell[] = [];
  for (let i = 0; i < 42; i += 1) {
    const d = new Date(gridStart.getFullYear(), gridStart.getMonth(), gridStart.getDate() + i);
    const ymd = formatYmd(d);
    cells.push({
      ymd,
      day: d.getDate(),
      inMonth: d.getMonth() === firstOfMonth.getMonth() && d.getFullYear() === firstOfMonth.getFullYear(),
      isToday: ymd === todayYmd,
    });
  }
  return cells;
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

  if (
    lower === '15m' ||
    lower === '1h' ||
    lower === '6h' ||
    lower === '24h' ||
    lower === '7d' ||
    lower === '30d'
  ) {
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

export function formatTimeScopeLabel(
  spec: string,
  timeLabels: Record<string, string>,
  nowMs = Date.now()
): string {
  const clean = spec.trim();
  if (!clean) return timeLabels[''] ?? '';
  if (clean in timeLabels) return timeLabels[clean];

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
