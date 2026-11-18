import { isBuiltinTimePreset } from './presets.ts';
import {
  extractPastedDateTime,
  formatYmd,
  isValidYmd,
  normalizeTimeInput,
  pad2,
  parsePastedDateTime,
  type ExtractedDateTime,
} from './paste-parser.ts';

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

export interface ResolvedFullBound {
  kind: 'empty' | 'relative' | 'explicit';
  spec: string;
  date: string;
  dateOnly: boolean;
}

export function resolveFullBound(
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
