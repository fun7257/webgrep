import type { BuiltinTimePreset } from '../types.ts';
import { parseCustomRangeDraft } from './slots.ts';

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
