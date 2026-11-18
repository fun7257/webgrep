import type { BuiltinTimePreset } from '../types.ts';
import { fuzzyMatchText, type HighlightRange } from '../source-picker.ts';
import {
  extractPastedDateTime,
  formatYmd,
  isValidYmd,
  normalizeTimeInput,
  pad2,
} from './paste-parser.ts';
import {
  FLAT_QUICK_TIME_PRESETS,
  formatTimeScopeLabel,
  formatTimeTriggerLabel,
  isBuiltinTimePreset,
  normalizeCanonicalRelToken,
} from './presets.ts';
import { buildFullTimeRangeSpec, resolveFullBound } from './slots.ts';

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
