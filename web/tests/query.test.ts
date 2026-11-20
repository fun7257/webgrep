import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildQueryCacheKeys,
  compileSearchQuery,
  computeDockerPreviewSinceSec,
  createQueryStep,
  encodeStepToWire,
  formatHistoryLabel,
  getHistoryScopeFlags,
  parseTimeModifierSpec,
} from '../src/lib/query.ts';
import {
  BUILTIN_TIME_PRESETS,
  QUICK_TIME_PRESET_GROUPS,
  TIME_FORMAT_PRESETS,
  buildCustomRangeSpec,
  buildFullTimeRangeSpec,
  buildSpecFromDateTimeParts,
  clampDateTimeParts,
  daysInMonth,
  extractPastedDateTime,
  formatTimeScopeLabel,
  formatTimeTriggerLabel,
  matchQuickTimeCandidates,
  parseCustomRangeDraft,
  parseFullTimeRangeDraft,
  parsePastedDateTime,
  parseQuickTimeExpression,
  resolveSyncedDateTimeParts,
  stepDateTimeSlot,
} from '../src/lib/time-range.ts';
import type { ScopeFilter } from '../src/lib/types.ts';
import {
  analyzeStructuredLine,
  buildHighlightSegments,
  decodeHumanEscapes,
  extractLeadingNanoTimestamp,
  formatContextRecordPretty,
  getCachedHighlightSegments,
  highlightCodeWithMatches,
  skipLeadingNanoTimestampOffset,
  syntaxKindToClass,
} from '../src/lib/utils.ts';
import {
  buildFrameProfileForHz,
  computeFrameProfile,
  snapRefreshRateHz,
} from '../src/lib/frame.ts';

const EMPTY_SCOPE: ScopeFilter = { sources: [], excludedSources: [], types: [], timePreset: '' };

describe('Structured Query Model & Compiler', () => {
  it('encodeStepToWire keeps plain text literal (spaces, -O3, in:foo, /api/v1) and encodes flags cleanly', () => {
    assert.equal(encodeStepToWire(createQueryStep('hello world')), 'hello world');
    assert.equal(encodeStepToWire(createQueryStep('-O3')), '-O3');
    assert.equal(encodeStepToWire(createQueryStep('in:src/')), 'in:src/');
    assert.equal(encodeStepToWire(createQueryStep('/api/v1')), '/api/v1');

    assert.equal(
      encodeStepToWire(createQueryStep('Error', { caseSensitive: true })),
      '$c(Error)'
    );
    assert.equal(
      encodeStepToWire(createQueryStep('Error', { wholeWord: true })),
      '$w(Error)'
    );
    assert.equal(
      encodeStepToWire(createQueryStep('Error', { caseSensitive: true, wholeWord: true })),
      '$cw(Error)'
    );
    assert.equal(
      encodeStepToWire(createQueryStep('pub\\s+fn', { isRegex: true })),
      '$r(pub\\s+fn)'
    );
    assert.equal(
      encodeStepToWire(createQueryStep('pub\\s+fn', { isRegex: true, caseSensitive: true, wholeWord: true })),
      '$rcw(pub\\s+fn)'
    );

    // Literal strings matching `$flags(...)` are escaped as `$r(...)` so backend doesn't reinterpret them
    assert.equal(encodeStepToWire(createQueryStep('$r(x)')), '$r(\\$r\\(x\\))');
  });

  it('compileSearchQuery compiles multi-level same-line convergence (+ / -) and independent ScopeFilter', () => {
    const fixedNow = 1730340900000;
    const steps = [
      createQueryStep('error', { caseSensitive: true }),
      createQueryStep('timeout', { wholeWord: true }),
      createQueryStep('healthcheck', { exclude: true }),
    ];
    const draft = createQueryStep('pg_pool_\\d+', { isRegex: true });
    const scope: ScopeFilter = {
      sources: ['src-1'],
      excludedSources: ['src-legacy'],
      types: ['log', 'json'],
      timePreset: '15m',
    };

    const compiled = compileSearchQuery(steps, draft, scope, fixedNow);
    assert.equal(compiled.hasExecutableQuery, true);
    assert.equal(compiled.primaryPattern, '$c(error)');
    assert.deepEqual(compiled.contains, ['$w(timeout)', '$r(pg_pool_\\d+)']);
    assert.deepEqual(compiled.excludes, ['healthcheck']);
    assert.deepEqual(compiled.sources, ['src-1']);
    assert.deepEqual(compiled.globs, ['!src-legacy']);
    assert.deepEqual(compiled.types, ['log', 'json']);
    assert.equal(compiled.timeStartMs, fixedNow - 15 * 60 * 1000);
    assert.equal(compiled.timeEndMs, 0);
  });

  it('compileSearchQuery supports time-only browsing when steps and draft are empty', () => {
    const fixedNow = 1730340900000;
    const compiled = compileSearchQuery([], null, { ...EMPTY_SCOPE, timePreset: 'today' }, fixedNow);
    assert.equal(compiled.hasExecutableQuery, true);
    assert.equal(compiled.primaryPattern, '');
    assert.ok(compiled.timeStartMs > 0);
  });

  it('parseTimeModifierSpec parses relative, today, yesterday, and explicit ranges', () => {
    const fixedNow = 1730340900000;
    const rel = parseTimeModifierSpec('15m', fixedNow);
    assert.deepEqual(rel, { startMs: fixedNow - 15 * 60 * 1000, endMs: 0 });

    const today = parseTimeModifierSpec('today', fixedNow);
    const midnight = new Date(fixedNow);
    midnight.setHours(0, 0, 0, 0);
    assert.deepEqual(today, { startMs: midnight.getTime(), endMs: 0 });

    const yesterday = parseTimeModifierSpec('yesterday', fixedNow);
    assert.ok(yesterday !== null);
    assert.equal(yesterday.endMs, midnight.getTime() - 1);

    const day = parseTimeModifierSpec('2026-10-31', fixedNow);
    assert.ok(day !== null && day.startMs > 0 && day.endMs > day.startMs);

    const thirtyDays = parseTimeModifierSpec('30d', fixedNow);
    assert.deepEqual(thirtyDays, { startMs: fixedNow - 30 * 86_400_000, endMs: 0 });

    const intraday = parseTimeModifierSpec('2026-11-14 10:15..2026-11-14 10:30', fixedNow);
    assert.ok(intraday !== null);
    assert.equal(intraday.startMs, new Date(2026, 10, 14, 10, 15, 0, 0).getTime());
    assert.equal(intraday.endMs, new Date(2026, 10, 14, 10, 30, 59, 999).getTime());

    const openEnd = parseTimeModifierSpec('2026/11/14 10:00:00..', fixedNow);
    assert.deepEqual(openEnd, {
      startMs: new Date(2026, 10, 14, 10, 0, 0, 0).getTime(),
      endMs: 0,
    });

    const openStart = parseTimeModifierSpec('..2026-11-14 12:00:00', fixedNow);
    assert.deepEqual(openStart, {
      startMs: 0,
      endMs: new Date(2026, 10, 14, 12, 0, 0, 999).getTime(),
    });
  });

  it('time-range utilities build, parse, paste-detect, format labels, and compile 3x4 quick presets', () => {
    const fixedNow = new Date(2026, 10, 14, 9, 30, 0).getTime();

    // All 12 quick presets in 3x4 cognitive groups are built-in and compile cleanly
    assert.deepEqual(
      QUICK_TIME_PRESET_GROUPS.map((g) => [...g.presets]),
      [
        ['5m', '15m', '30m', '1h'],
        ['3h', '6h', '12h', '24h'],
        ['today', 'yesterday', '7d', '30d'],
      ]
    );
    assert.equal(BUILTIN_TIME_PRESETS.length, 13); // '' + 12 presets
    for (const group of QUICK_TIME_PRESET_GROUPS) {
      for (const preset of group.presets) {
        const parsed = parseTimeModifierSpec(preset, fixedNow);
        assert.ok(parsed !== null, `preset ${preset} should compile`);
        assert.ok(parsed.startMs > 0, `preset ${preset} should have positive startMs`);
        if (preset === 'yesterday') {
          assert.ok(parsed.endMs > parsed.startMs);
        } else {
          assert.equal(parsed.endMs, 0);
        }
      }
    }

    // Full-timestamp range builder + omitted seconds + intra-day inheritance + open bounds + swap
    assert.deepEqual(
      buildFullTimeRangeSpec({ start: '2026-11-12 10:00', end: '10:30' }, fixedNow),
      { spec: '2026-11-12 10:00:00..2026-11-12 10:30:59', error: null }
    );
    assert.deepEqual(
      buildFullTimeRangeSpec({ start: '2026-11-14', end: '2026-11-12' }, fixedNow),
      { spec: '2026-11-12 00:00:00..2026-11-14 23:59:59', error: null }
    );
    assert.deepEqual(
      buildFullTimeRangeSpec({ start: '2026-11-14 08:00:00', end: 'now' }, fixedNow),
      { spec: '2026-11-14 08:00:00..', error: null }
    );
    assert.deepEqual(
      buildFullTimeRangeSpec({ start: '', end: '2026-11-14 12:00' }, fixedNow),
      { spec: '..2026-11-14 12:00:59', error: null }
    );
    assert.deepEqual(
      buildFullTimeRangeSpec({ start: '2026-11-14 08:00..2026-11-14 09:00', end: '' }, fixedNow),
      { spec: '2026-11-14 08:00:00..2026-11-14 09:00:59', error: null }
    );
    assert.deepEqual(
      buildFullTimeRangeSpec({ start: 'now-45m', end: '' }, fixedNow),
      { spec: '45m', error: null }
    );
    assert.deepEqual(
      buildFullTimeRangeSpec({ start: '[2026-11-14 08:12:34,567] ERROR timeout', end: '' }, fixedNow),
      { spec: '2026-11-14 08:12:34..', error: null }
    );
    assert.deepEqual(
      buildFullTimeRangeSpec({ start: 'not-a-time', end: '' }, fixedNow),
      { spec: '', error: 'invalid_start' }
    );
    assert.deepEqual(
      buildFullTimeRangeSpec({ start: '2026-11-14 08:00:00', end: '2026-02-30' }, fixedNow),
      { spec: '', error: 'invalid_end' }
    );

    // parseFullTimeRangeDraft keeps builtin presets empty and parses custom specs cleanly
    assert.deepEqual(parseFullTimeRangeDraft(''), { start: '', end: '' });
    assert.deepEqual(parseFullTimeRangeDraft('5m'), { start: '', end: '' });
    assert.deepEqual(parseFullTimeRangeDraft('today'), { start: '', end: '' });
    assert.deepEqual(parseFullTimeRangeDraft('2026-11-12 08:30:00..2026-11-14 18:00:00'), {
      start: '2026-11-12 08:30:00',
      end: '2026-11-14 18:00:00',
    });
    assert.deepEqual(parseFullTimeRangeDraft('2026-11-14'), {
      start: '2026-11-14 00:00:00',
      end: '2026-11-14 23:59:59',
    });
    assert.deepEqual(parseFullTimeRangeDraft('45m'), { start: '45m', end: '' });

    // Legacy buildCustomRangeSpec + parseCustomRangeDraft still compatible for label formatter
    const fullDay = buildCustomRangeSpec(
      { startDate: '2026-11-14', startTime: '', endDate: '2026-11-12', endTime: '' },
      fixedNow
    );
    assert.deepEqual(fullDay, {
      spec: '2026-11-12 00:00:00..2026-11-14 23:59:59',
      error: null,
    });

    const parsedDraft = parseCustomRangeDraft('2026-11-12 08:30:00..2026-11-14 18:00:00', fixedNow);
    assert.deepEqual(parsedDraft, {
      startDate: '2026-11-12',
      startTime: '08:30:00',
      endDate: '2026-11-14',
      endTime: '18:00:00',
    });

    // Paste parsers (Log4j comma ms, ISO UTC, compact 14-digit, dot/single-digit YMD, CJK, CLF, 12h AM/PM, epoch, full log lines)
    assert.deepEqual(parsePastedDateTime('2026-11-14 08:12:34,567'), {
      date: '2026-11-14',
      time: '08:12:34',
    });
    assert.deepEqual(parsePastedDateTime('20261114101502'), {
      date: '2026-11-14',
      time: '10:15:02',
    });
    assert.deepEqual(parsePastedDateTime('2026.11.14 09:15:02'), {
      date: '2026-11-14',
      time: '09:15:02',
    });
    assert.deepEqual(parsePastedDateTime('2026-1-5 8:05'), {
      date: '2026-01-05',
      time: '08:05:00',
    });
    assert.deepEqual(parsePastedDateTime('2026年11月14日 10时15分02秒'), {
      date: '2026-11-14',
      time: '10:15:02',
    });
    assert.deepEqual(parsePastedDateTime('11/14/2026 2:15:02 PM'), {
      date: '2026-11-14',
      time: '14:15:02',
    });
    assert.equal(TIME_FORMAT_PRESETS[0]?.id, 'auto');
    assert.ok(TIME_FORMAT_PRESETS.some((p) => p.value === 'yyyy-hm'));
    const utcMs = Date.UTC(2026, 10, 14, 1, 2, 3);
    const localExpected = new Date(utcMs);
    const pad2 = (n: number) => String(n).padStart(2, '0');
    const expDate = `${localExpected.getFullYear()}-${pad2(localExpected.getMonth() + 1)}-${pad2(localExpected.getDate())}`;
    const expTime = `${pad2(localExpected.getHours())}:${pad2(localExpected.getMinutes())}:${pad2(localExpected.getSeconds())}`;
    assert.deepEqual(parsePastedDateTime('2026-11-14T01:02:03.456Z'), {
      date: expDate,
      time: expTime,
    });
    assert.deepEqual(parsePastedDateTime('14/Nov/2026:01:02:03 +0000'), {
      date: expDate,
      time: expTime,
    });
    assert.deepEqual(parsePastedDateTime(String(utcMs)), {
      date: expDate,
      time: expTime,
    });
    assert.deepEqual(parsePastedDateTime(`${utcMs}000000`), {
      date: expDate,
      time: expTime,
    });

    // Full log line extraction
    assert.equal(
      extractPastedDateTime('2026-11-14T01:02:03.456789Z {"level":"error"}', fixedNow)?.formatted,
      `${expDate} ${expTime}`
    );
    assert.equal(
      extractPastedDateTime(`${utcMs}000000 {"msg":"boom"}`, fixedNow)?.formatted,
      `${expDate} ${expTime}`
    );
    assert.equal(
      extractPastedDateTime('Nov 14 09:15:00 web01 sshd[123]: ok', fixedNow)?.formatted,
      '2026-11-14 09:15:00'
    );
    assert.equal(
      extractPastedDateTime('2026-11-14 10:30', fixedNow, true)?.formatted,
      '2026-11-14 10:30:59'
    );

    // Label formatting
    const labels = { '': '全部时间', '5m': '最近 5 分钟', '15m': '最近 15 分钟' };
    assert.equal(formatTimeScopeLabel('5m', labels, fixedNow), '最近 5 分钟');
    assert.equal(formatTimeScopeLabel('2026-11-14 00:00:00..2026-11-14 23:59:59', labels, fixedNow), '2026-11-14');
    assert.equal(formatTimeScopeLabel('2026-11-12 00:00:00..2026-11-14 23:59:59', labels, fixedNow), '11-12 ~ 11-14');
    assert.equal(formatTimeScopeLabel('2026-11-14 10:00:00..2026-11-14 12:30:59', labels, fixedNow), '11-14 10:00 ~ 12:30');
    assert.equal(formatTimeScopeLabel('2026-11-14 10:00:00..', labels, fixedNow), '≥ 11-14 10:00');
  });

  it('resolveSyncedDateTimeParts, clampDateTimeParts, stepDateTimeSlot, and buildSpecFromDateTimeParts prefill and sync presets cleanly', () => {
    const fixedNow = new Date(2026, 10, 15, 13, 18, 25).getTime();

    // '' and 'today' prefill today 00:00:00 .. now (endIsNow=true)
    const anySynced = resolveSyncedDateTimeParts('', fixedNow);
    assert.deepEqual(anySynced, {
      start: { year: '2026', month: '11', day: '15', hour: '00', minute: '00', second: '00' },
      end: { year: '2026', month: '11', day: '15', hour: '13', minute: '18', second: '25' },
      endIsNow: true,
    });
    assert.deepEqual(resolveSyncedDateTimeParts('today', fixedNow), anySynced);

    // Rolling presets sync exact start offset while keeping endIsNow=true
    assert.deepEqual(resolveSyncedDateTimeParts('5m', fixedNow).start, {
      year: '2026', month: '11', day: '15', hour: '13', minute: '13', second: '25',
    });
    assert.deepEqual(resolveSyncedDateTimeParts('15m', fixedNow).start, {
      year: '2026', month: '11', day: '15', hour: '13', minute: '03', second: '25',
    });
    assert.deepEqual(resolveSyncedDateTimeParts('1h', fixedNow).start, {
      year: '2026', month: '11', day: '15', hour: '12', minute: '18', second: '25',
    });
    assert.deepEqual(resolveSyncedDateTimeParts('7d', fixedNow).start, {
      year: '2026', month: '11', day: '08', hour: '13', minute: '18', second: '25',
    });
    assert.deepEqual(resolveSyncedDateTimeParts('30d', fixedNow).start, {
      year: '2026', month: '10', day: '16', hour: '13', minute: '18', second: '25',
    });

    // 'yesterday' resolves to full calendar day with endIsNow=false
    assert.deepEqual(resolveSyncedDateTimeParts('yesterday', fixedNow), {
      start: { year: '2026', month: '11', day: '14', hour: '00', minute: '00', second: '00' },
      end: { year: '2026', month: '11', day: '14', hour: '23', minute: '59', second: '59' },
      endIsNow: false,
    });

    // Explicit ranges (both closed and open-ended) sync cleanly
    assert.deepEqual(resolveSyncedDateTimeParts('2026-11-12 08:30:00..2026-11-14 18:00:00', fixedNow), {
      start: { year: '2026', month: '11', day: '12', hour: '08', minute: '30', second: '00' },
      end: { year: '2026', month: '11', day: '14', hour: '18', minute: '00', second: '00' },
      endIsNow: false,
    });
    assert.deepEqual(resolveSyncedDateTimeParts('2026-11-14 10:00:00..', fixedNow), {
      start: { year: '2026', month: '11', day: '14', hour: '10', minute: '00', second: '00' },
      end: { year: '2026', month: '11', day: '15', hour: '13', minute: '18', second: '25' },
      endIsNow: true,
    });

    // Calendar month-day clamping (non-leap vs leap year)
    assert.equal(daysInMonth(2026, 2), 28);
    assert.equal(daysInMonth(2024, 2), 29);
    assert.deepEqual(
      clampDateTimeParts({ year: '2026', month: '2', day: '31', hour: '29', minute: '75', second: '9' }),
      { year: '2026', month: '02', day: '28', hour: '23', minute: '59', second: '09' }
    );

    // Slot stepping wraps properly and clamps day when stepping across shorter month
    assert.deepEqual(
      stepDateTimeSlot(
        { year: '2026', month: '01', day: '31', hour: '00', minute: '00', second: '00' },
        'month',
        1
      ),
      { year: '2026', month: '02', day: '28', hour: '00', minute: '00', second: '00' }
    );
    assert.deepEqual(
      stepDateTimeSlot(
        { year: '2026', month: '11', day: '15', hour: '23', minute: '00', second: '00' },
        'hour',
        1
      ),
      { year: '2026', month: '11', day: '15', hour: '00', minute: '00', second: '00' }
    );

    // Build spec handles endIsNow and auto-swaps reversed bounds
    assert.equal(
      buildSpecFromDateTimeParts(
        { year: '2026', month: '11', day: '15', hour: '09', minute: '00', second: '00' },
        { year: '2026', month: '11', day: '15', hour: '13', minute: '18', second: '25' },
        true
      ),
      '2026-11-15 09:00:00..'
    );
    assert.equal(
      buildSpecFromDateTimeParts(
        { year: '2026', month: '11', day: '15', hour: '12', minute: '00', second: '00' },
        { year: '2026', month: '11', day: '14', hour: '08', minute: '30', second: '00' },
        false
      ),
      '2026-11-14 08:30:00..2026-11-15 12:00:00'
    );
  });

  it('formatHistoryLabel formats step chain and draft cleanly', () => {
    const label = formatHistoryLabel(
      [createQueryStep('error'), createQueryStep('healthcheck', { exclude: true })],
      createQueryStep('timeout')
    );
    assert.equal(label, 'error → -healthcheck → timeout');
  });

  it('getHistoryScopeFlags detects scoped sources and time ranges without exposing values', () => {
    assert.deepEqual(getHistoryScopeFlags(null), { hasSources: false, hasTime: false });
    assert.deepEqual(getHistoryScopeFlags(undefined), { hasSources: false, hasTime: false });
    assert.deepEqual(getHistoryScopeFlags(EMPTY_SCOPE), { hasSources: false, hasTime: false });
    assert.deepEqual(
      getHistoryScopeFlags({ sources: ['src-1'], excludedSources: [], timePreset: '   ' }),
      { hasSources: true, hasTime: false }
    );
    assert.deepEqual(
      getHistoryScopeFlags({ sources: [], excludedSources: ['src-2'], timePreset: '' }),
      { hasSources: true, hasTime: false }
    );
    assert.deepEqual(
      getHistoryScopeFlags({ sources: [], excludedSources: [], timePreset: '45m' }),
      { hasSources: false, hasTime: true }
    );
    assert.deepEqual(
      getHistoryScopeFlags({ sources: [], timePreset: '2026-11-15 09:30:00..' }),
      { hasSources: false, hasTime: true }
    );
    assert.deepEqual(
      getHistoryScopeFlags({
        sources: ['src-1'],
        excludedSources: ['src-2'],
        timePreset: '1h',
      }),
      { hasSources: true, hasTime: true }
    );
  });

  it('buildQueryCacheKeys separates baseKey (for maxResults growth) and exactKey, including tenant & sources', () => {
    const common = {
      tenant: 'ws-a',
      effectiveSources: ['s2', 's1'],
      excludedSources: ['s3'],
      types: ['zig', 'log'],
      timePreset: '1h' as const,
      steps: [createQueryStep('panic')],
      hidden: false,
      respectIgnore: true,
      nowMs: 1730340900000,
    };
    const k1 = buildQueryCacheKeys({ ...common, maxResults: 500 });
    const k2 = buildQueryCacheKeys({ ...common, maxResults: 2000 });
    assert.equal(k1.baseKey, k2.baseKey);
    assert.notEqual(k1.exactKey, k2.exactKey);
    assert.equal(k1.historyId, k2.historyId);

    // Different tenant invalidates keys
    const kOther = buildQueryCacheKeys({ ...common, tenant: 'ws-b', maxResults: 500 });
    assert.notEqual(k1.exactKey, kOther.exactKey);
    assert.notEqual(k1.historyId, kOther.historyId);
  });

  it('compiles non-stacked per-source timeMode default and isolates sourceTimeFormatsSig, tzOffsetMin, and timePreset', () => {
    const fixedNow = new Date(2026, 10, 14, 15, 0, 0).getTime();

    const defaultCompiled = compileSearchQuery([], null, {
      sources: [],
      types: [],
      timePreset: '1h',
    }, fixedNow);
    assert.equal(defaultCompiled.timeMode, 'source');
    assert.equal(defaultCompiled.timeFormat, '');
    assert.equal(defaultCompiled.hasExecutableQuery, true);

    const overrideCompiled = compileSearchQuery([], null, {
      sources: [],
      types: [],
      timePreset: '24h',
      timeMode: 'mtime',
      timeFormat: '  json:ts  ',
    }, fixedNow);
    assert.equal(overrideCompiled.timeMode, 'mtime');
    assert.equal(overrideCompiled.timeFormat, 'json:ts');
    assert.equal(overrideCompiled.hasExecutableQuery, true);

    const common = {
      tenant: 'ws-a',
      effectiveSources: ['s1'],
      excludedSources: [],
      types: [],
      timePreset: '1h' as const,
      timeMode: 'source' as const,
      timeFormat: '',
      tzOffsetMin: 480,
      sourceTimeFormatsSig: '',
      steps: [createQueryStep('error')],
      hidden: false,
      respectIgnore: false,
      maxResults: 500,
      nowMs: fixedNow,
    };
    const kMtimeSource = buildQueryCacheKeys(common);
    const kAutoContentSource = buildQueryCacheKeys({ ...common, sourceTimeFormatsSig: 's1=auto' });
    const kCustomContentSource = buildQueryCacheKeys({ ...common, sourceTimeFormatsSig: 's1=json:ts' });
    const kOtherTz = buildQueryCacheKeys({ ...common, tzOffsetMin: 0 });
    const kOtherPreset = buildQueryCacheKeys({ ...common, timePreset: '24h' });

    assert.notEqual(kMtimeSource.baseKey, kAutoContentSource.baseKey);
    assert.notEqual(kMtimeSource.exactKey, kAutoContentSource.exactKey);
    assert.equal(kMtimeSource.historyId, kAutoContentSource.historyId);

    assert.notEqual(kAutoContentSource.baseKey, kCustomContentSource.baseKey);
    assert.notEqual(kAutoContentSource.exactKey, kCustomContentSource.exactKey);
    assert.equal(kAutoContentSource.historyId, kCustomContentSource.historyId);

    assert.notEqual(kMtimeSource.baseKey, kOtherTz.baseKey);
    assert.notEqual(kMtimeSource.baseKey, kOtherPreset.baseKey);
    assert.notEqual(kMtimeSource.historyId, kOtherPreset.historyId);

    const zhLabels = { '': '不限时间', '1h': '最近 1 小时', '24h': '最近 24 小时' };
    const enLabels = { '': 'Any time', '15m': 'Last 15 min' };
    assert.equal(formatTimeScopeLabel('', zhLabels, fixedNow), '不限时间');
    assert.equal(formatTimeScopeLabel('1h', zhLabels, fixedNow), '最近 1 小时');
    assert.equal(formatTimeScopeLabel('24h', zhLabels, fixedNow), '最近 24 小时');
    assert.equal(formatTimeScopeLabel('15m', enLabels, fixedNow), 'Last 15 min');
    assert.equal(
      formatTimeScopeLabel('2026-11-13 00:00:00..2026-11-14 23:59:59', enLabels, fixedNow),
      '11-13 ~ 11-14'
    );
  });
});

describe('analyzeStructuredLine & buildHighlightSegments (Inspector formatting & highlights)', () => {
  it('result-row windowing skips leading indentation so the match stays visible', () => {
    const text = '            let size: usize = cmd("SCARD").arg(key).query_async(conn).await?;';
    const segs = buildHighlightSegments(text, undefined, [], true, true, 'scard');
    assert.equal(segs.map((s) => s.text).join('').startsWith('let size'), true);
    assert.ok(segs.some((s) => s.kind === 'primary' && s.text === 'SCARD'));
  });

  it('preserves leading log prefix (timestamp/level/module) on KV log lines', () => {
    const line =
      '2026-10-29T09:17:30.000Z [ERROR] [ledger-core] trace_id=tr-99812 span_id=sp-4410 code=ERR_LEDGER_OVERFLOW';
    const info = analyzeStructuredLine(line);
    assert.equal(info.kind, 'kv');
    assert.equal(info.prefix, '2026-10-29T09:17:30.000Z [ERROR] [ledger-core]');
    assert.equal(info.kvPairs?.length, 3);
    assert.ok(info.formattedText.includes('2026-10-29T09:17:30.000Z [ERROR] [ledger-core]'));
    assert.ok(info.formattedText.includes('code: ERR_LEDGER_OVERFLOW'));
  });

  it('highlights scoped $cw(ErrorCode) and $rw(\\d{4}) only on whole-word boundaries', () => {
    const line = '    const x = ErrorCode2 + ErrorCode + 1001 + 12345;';
    const segs = buildHighlightSegments(
      line,
      undefined,
      ['$rw(\\d{4})'],
      true,
      false,
      '$cw(ErrorCode)',
      false
    );
    const primaryMatches = segs.filter((s) => s.kind === 'primary').map((s) => s.text);
    const containsMatches = segs.filter((s) => s.kind === 'contains-0').map((s) => s.text);
    assert.deepEqual(primaryMatches, ['ErrorCode']);
    assert.deepEqual(containsMatches, ['1001']);
  });

  it('extracts 19-digit nanosecond timestamp and formats JSON payload cleanly', () => {
    const line =
      '1730340905123456789 {"level":"error","service":"payment-api","msg":"upstream timeout"}';
    const ts = extractLeadingNanoTimestamp(line);
    assert.ok(ts !== null);
    assert.equal(ts.nsStr, '1730340905123456789');
    assert.equal(
      ts.restText,
      '{"level":"error","service":"payment-api","msg":"upstream timeout"}'
    );

    const info = analyzeStructuredLine(line);
    assert.equal(info.kind, 'json');
    assert.ok(info.prefix?.includes('1730340905123456789'));
    assert.ok(info.formattedText.includes('"service": "payment-api"'));
    assert.ok(info.timeHint && info.timeHint.length > 0);
    assert.equal(info.formatBadge, 'JSON');
  });

  it('decodes Unicode \\uXXXX, URL %XX escapes, and recursively unpacks nested JSON strings', () => {
    const dockerLine =
      '{"stream":"stderr","log":"{\\"level\\":\\"error\\",\\"msg\\":\\"\\u8ba2\\u5355%E8%B6%85%E6%97%B6\\"}"}';
    const info = analyzeStructuredLine(dockerLine);
    assert.equal(info.kind, 'json');
    assert.equal(info.formatBadge, 'JSON');
    assert.ok(info.bodyFormattedText?.includes('"订单超时"'));
    assert.equal(decodeHumanEscapes('hello\\u4e16\\u754c%21'), 'hello世界!');
  });

  it('formats Docker RFC3339Nano embedded-JSON and [STDERR] KV log lines cleanly', () => {
    const rfcJsonLine =
      '2026-11-14T04:10:01.123456789Z {"level":"error","service":"api-gateway","msg":"upstream_timeout"}';
    const jsonInfo = analyzeStructuredLine(rfcJsonLine);
    assert.equal(jsonInfo.kind, 'embedded-json');
    assert.equal(jsonInfo.formatBadge, 'JSON');
    assert.equal(jsonInfo.prefix, '2026-11-14T04:10:01.123456789Z');
    assert.ok(jsonInfo.formattedText.includes('"service": "api-gateway"'));

    const stderrKvLine = '[STDERR] trace_id=tr-1 span_id=sp-2 status=502';
    const kvInfo = analyzeStructuredLine(stderrKvLine);
    assert.equal(kvInfo.kind, 'kv');
    assert.equal(kvInfo.formatBadge, 'KV');
    assert.equal(kvInfo.prefix, '[STDERR]');
    assert.equal(kvInfo.kvPairs?.length, 3);
  });

  it('renders plain/HTML/struct text directly without special HTML/STRUCT adaptation', () => {
    const htmlLine = '<div class="card"><span class="title">Payment Failed</span><p>Retry in 5s</p></div>';
    const htmlInfo = analyzeStructuredLine(htmlLine);
    assert.equal(htmlInfo.kind, 'long-line');
    assert.equal(htmlInfo.formatBadge, undefined);
    assert.equal(htmlInfo.bodyFormattedText, htmlLine);
    assert.equal(formatContextRecordPretty(htmlLine), htmlLine);

    const structLine =
      'OrderEvent{id: 9012, customer: "alice", items: [sku_1001, sku_1002], meta: {region: ap-east, retry: 3, gateway: edge-01}}';
    const structInfo = analyzeStructuredLine(structLine);
    assert.equal(structInfo.kind, 'long-line');
    assert.equal(structInfo.formatBadge, undefined);
    assert.equal(structInfo.bodyFormattedText, structLine);

    const plainTsLine = '2026-09-11 08:00:00.123 upstream ready';
    const tsInfo = analyzeStructuredLine(plainTsLine);
    assert.equal(tsInfo.kind, 'long-line');
    assert.equal(tsInfo.bodyFormattedText, plainTsLine);
    assert.equal(tsInfo.timeHint, '2026-09-11 08:00:00.123');
  });

  it('tokenizes code syntax (keywords, builtins, types, strings, comments) while preserving search match highlights', () => {
    const zigLine = 'pub fn scanChunk(buf: []const u8) @Vector(64, u8) { // fast path';
    const matchSegs = buildHighlightSegments(
      zigLine,
      undefined,
      [],
      true,
      false,
      'scanChunk',
      false
    );
    const codeSegs = highlightCodeWithMatches(zigLine, matchSegs);
    assert.equal(codeSegs.map((s) => s.text).join(''), zigLine);
    assert.ok(codeSegs.some((s) => s.text === 'pub' && s.syntaxKind === 'keyword'));
    assert.ok(codeSegs.some((s) => s.text === 'fn' && s.syntaxKind === 'keyword'));
    assert.ok(codeSegs.some((s) => s.text === 'scanChunk' && s.matchKind === 'primary'));
    assert.ok(codeSegs.some((s) => s.text === 'u8' && s.syntaxKind === 'type'));
    assert.ok(codeSegs.some((s) => s.text === '@Vector' && s.syntaxKind === 'builtin'));
    assert.ok(codeSegs.some((s) => s.text === '64' && s.syntaxKind === 'number'));
    assert.ok(codeSegs.some((s) => s.text.includes('// fast path') && s.syntaxKind === 'comment'));
  });

  it('highlights common formats (JSONL, logfmt/plain logs with URLs and contractions, YAML/TOML/SQL) while preserving matches', () => {
    const jsonLog =
      '{"t":"2026-10-08T12:00:00.000+08:00","l":"error","status":500,"url":"https://api.example.com/v1"}';
    const jsonMatchSegs = buildHighlightSegments(jsonLog, undefined, [], true, false, 'api.example.com', false);
    const jsonSegs = highlightCodeWithMatches(jsonLog, jsonMatchSegs);
    assert.equal(jsonSegs.map((s) => s.text).join(''), jsonLog);
    assert.ok(jsonSegs.some((s) => s.text === '"t"' && s.syntaxKind === 'property'));
    assert.ok(jsonSegs.some((s) => s.text.includes('2026-10-08T12:00:00') && s.syntaxKind === 'timestamp'));
    assert.ok(jsonSegs.some((s) => s.text === '"error"' && s.syntaxKind === 'log-error'));
    assert.ok(jsonSegs.some((s) => s.text === '500' && s.syntaxKind === 'number'));
    assert.ok(jsonSegs.some((s) => s.text === 'api.example.com' && s.matchKind === 'primary'));

    const plainLog =
      "2026-11-16 10:00:00.123 [WARN] upstream retry ip=10.0.0.8:8080 endpoint=https://example.com/health Couldn't connect";
    const plainSegs = highlightCodeWithMatches(plainLog, [{ text: plainLog, kind: 'plain' }]);
    assert.equal(plainSegs.map((s) => s.text).join(''), plainLog);
    assert.ok(plainSegs.some((s) => s.text === '2026-11-16 10:00:00.123' && s.syntaxKind === 'timestamp'));
    assert.ok(plainSegs.some((s) => s.text === 'WARN' && s.syntaxKind === 'log-warn'));
    assert.ok(plainSegs.some((s) => s.text === 'ip' && s.syntaxKind === 'property'));
    assert.ok(plainSegs.some((s) => s.text === '10.0.0.8:8080' && s.syntaxKind === 'number'));
    assert.ok(plainSegs.some((s) => s.text === 'https://example.com/health' && s.syntaxKind === 'url'));
    assert.ok(!plainSegs.some((s) => s.syntaxKind === 'comment'), 'https:// must not start a // comment');
    assert.ok(!plainSegs.some((s) => s.syntaxKind === 'string'), "Couldn't apostrophe must not open a string");

    const yamlTomlSql = [
      'content-type: application/json',
      '[dependencies]',
      'SELECT id FROM users WHERE active = true -- query',
    ].join('\n');
    const multiSegs = highlightCodeWithMatches(yamlTomlSql, [{ text: yamlTomlSql, kind: 'plain' }]);
    assert.equal(multiSegs.map((s) => s.text).join(''), yamlTomlSql);
    assert.ok(multiSegs.some((s) => s.text === 'content-type' && s.syntaxKind === 'property'));
    assert.ok(multiSegs.some((s) => s.text === '[dependencies]' && s.syntaxKind === 'builtin'));
    assert.ok(multiSegs.some((s) => s.text === 'SELECT' && s.syntaxKind === 'keyword'));
    assert.ok(multiSegs.some((s) => s.text === '-- query' && s.syntaxKind === 'comment'));

    assert.equal(syntaxKindToClass('log-error'), 'syn-log-error');
    assert.equal(syntaxKindToClass('url'), 'syn-url');
    assert.equal(syntaxKindToClass('plain'), '');
    assert.ok(formatContextRecordPretty('{"a":1}').includes('\n'));
  });

  it('preserves rich single-record content across 1–6 preview lines without premature ellipses and centers ultra-long records', () => {
    // 320-char single record within 540-char preview budget: must stay unbroken
    const mediumBody =
      '    {"level":"error","service":"checkout-api","trace_id":"tr-90210",' +
      '"customer_note":"' +
      'alpha-beta-gamma-'.repeat(12) +
      '","msg":"upstream gateway timeout after 3000ms"}';
    const mediumHit = {
      file: 'logs/checkout.jsonl',
      line: 184,
      col: 15,
      text: mediumBody,
      spans: [{ start: 14, end: 19 }],
    };
    const mediumSegs = getCachedHighlightSegments(
      mediumHit,
      ['timeout'],
      true,
      'literal:error\u0001timeout\u0001540',
      'error',
      false,
      540
    );
    const mediumRendered = mediumSegs.map((s) => s.text).join('');
    assert.equal(mediumRendered.startsWith('{"level":"error"'), true);
    assert.equal(mediumRendered.includes('…'), false);
    assert.ok(mediumSegs.some((s) => s.text === 'error' && s.kind === 'primary'));
    assert.ok(mediumSegs.some((s) => s.text === 'timeout' && s.kind === 'contains-0'));

    // 2000-char ultra-long record: centers match window cleanly and trims leading/trailing filler
    const prefix = 'x'.repeat(1150);
    const suffix = 'y'.repeat(800);
    const longLine = `${prefix} target_token_here ${suffix}`;
    const longSegs = buildHighlightSegments(
      longLine,
      undefined,
      [],
      true,
      true,
      'target_token_here',
      false,
      true,
      540
    );
    const longRendered = longSegs.map((s) => s.text).join('');
    assert.ok(longRendered.includes('target_token_here'));
    assert.ok(longRendered.includes(' … '));
    assert.ok(longRendered.length < 900);
  });

  it('computeDockerPreviewSinceSec aligns Docker preview since= strictly with auto content-time search pushdown', () => {
    const sources = [
      { kind: 'docker', name: 'docker-auto', config: { path: 'auto', timeFormat: 'auto' } },
      { kind: 'docker', name: 'docker-default', config: { path: 'auto' } },
      { kind: 'docker', name: 'docker-mtime', config: { path: 'auto', timeFormat: '' } },
      { kind: 'docker', name: 'docker-custom', config: { path: 'auto', timeFormat: 'json:ts' } },
      { kind: 'dir', name: 'app-logs', config: { path: '/tmp/logs', timeFormat: 'auto' } },
    ];
    const startMs = 1794650640123; // 1794650640s -> since = 1794650638
    assert.equal(computeDockerPreviewSinceSec(sources, 'docker-auto/gateway', startMs), 1794650638);
    assert.equal(computeDockerPreviewSinceSec(sources, 'Docker-Default/api', startMs), 1794650638);
    assert.equal(computeDockerPreviewSinceSec(sources, 'docker-mtime/gateway', startMs), null);
    assert.equal(computeDockerPreviewSinceSec(sources, 'docker-custom/gateway', startMs), null);
    assert.equal(computeDockerPreviewSinceSec(sources, 'app-logs/gateway.log', startMs), null);
    assert.equal(computeDockerPreviewSinceSec(sources, 'gateway', startMs), null);
    assert.equal(computeDockerPreviewSinceSec(sources, 'docker-auto/gateway', 0), null);
  });
});

describe('selection latency optimization helpers', () => {
  it('skipLeadingNanoTimestampOffset matches extractLeadingNanoTimestamp prefix without allocation', () => {
    const withNano = '1730340905123456789   INFO request finished';
    const extracted = extractLeadingNanoTimestamp(withNano);
    assert.ok(extracted);
    assert.equal(skipLeadingNanoTimestampOffset(withNano), extracted.prefixLen);
    assert.equal(withNano.slice(skipLeadingNanoTimestampOffset(withNano)), extracted.restText);

    assert.equal(skipLeadingNanoTimestampOffset('{"level":"info","msg":"ok"}'), 0);
    assert.equal(skipLeadingNanoTimestampOffset('9999999999999999999 too late'), 0);
    assert.equal(skipLeadingNanoTimestampOffset('1730340905123456789'), 0);
  });

  it('decodeHumanEscapes fast path preserves plain text and decodes backslash/ANSI/percent sequences', () => {
    const plain = 'hello world status=200 latency=4ms';
    assert.equal(decodeHumanEscapes(plain), plain);

    const escaped = 'GET /search\\u003fq%3D1\\n\\t\x1b[31merr\x1b[0m';
    assert.equal(decodeHumanEscapes(escaped), 'GET /search?q=1\n  err');
  });

  it('cached term matchers remain stateless across repeated regex highlight calls', () => {
    const pattern = 'err[_-]?\\d+';
    for (let i = 0; i < 4; i++) {
      const segs = buildHighlightSegments(
        'first err_12 and second err-34done',
        undefined,
        ['second'],
        false,
        false,
        pattern,
        true,
      );
      const hits = segs.filter((s) => s.kind === 'primary').map((s) => s.text);
      assert.deepEqual(hits, ['err_12', 'err-34']);
      const secondaryHits = segs.filter((s) => s.kind === 'contains-0').map((s) => s.text);
      assert.deepEqual(secondaryHits, ['second']);
    }
  });

  it('analyzeStructuredLine LRU cache returns identical structured result cleanly', () => {
    const line = '{"level":"error","service":"gateway","latency_ms":42,"msg":"timeout"}';
    const first = analyzeStructuredLine(line);
    const second = analyzeStructuredLine(line);
    assert.equal(first.kind, 'json');
    assert.equal(first, second);
    assert.equal(second.formatBadge, 'JSON');
    assert.ok(second.formattedText.includes('"service": "gateway"'));

    const plainLine = 'just a plain non-structured text line';
    const plain1 = analyzeStructuredLine(plainLine);
    const plain2 = analyzeStructuredLine(plainLine);
    assert.equal(plain1.kind, 'long-line');
    assert.equal(plain1, plain2);
  });
});

describe('adaptive display refresh-rate profiler (60Hz–240Hz)', () => {
  it('detects 60Hz standard tier with integer VSync frame pacing and -0.5f lead compensation', () => {
    const profile = computeFrameProfile([16.4, 16.8, 16.7, 16.5, 17.0, 16.6, 16.9, 16.6]);
    assert.equal(profile.hz, 60);
    assert.equal(profile.tier, 'standard');
    assert.equal(profile.firstFlushFrames, 3);
    assert.equal(profile.steadyFlushFrames, 4);
    assert.equal(profile.firstFlushLeadMs, 41);
    assert.equal(profile.steadyFlushLeadMs, 58);
    assert.equal(profile.deferInspectorThresholdChars, 12_288);
    assert.equal(profile.overscanPx, 560);
    assert.equal(profile.switchMotionMs, 67);
    assert.equal(profile.sheetMotionMs, 150);
    assert.equal(profile.drawerEnterMs, 183);
  });

  it('detects 120Hz high-refresh tier with exact 1/8 VSync submultiple pacing', () => {
    const profile = computeFrameProfile([8.2, 8.4, 8.33, 8.5, 8.3, 8.1, 8.4, 8.3]);
    assert.equal(profile.hz, 120);
    assert.equal(profile.tier, 'high');
    assert.equal(profile.firstFlushFrames, 6);
    assert.equal(profile.steadyFlushFrames, 8);
    assert.equal(profile.firstFlushLeadMs, 45);
    assert.equal(profile.steadyFlushLeadMs, 62);
    assert.equal(profile.deferInspectorThresholdChars, 4_096);
    assert.equal(profile.overscanPx, 420);
    assert.equal(profile.switchMotionMs, 67);
    assert.equal(profile.sheetMotionMs, 150);
    assert.equal(profile.drawerEnterMs, 183);
  });

  it('supports 90Hz and 144Hz panels, rejects outliers, and falls back safely to 60Hz', () => {
    const p90 = computeFrameProfile([11.0, 11.2, 11.1, 10.9, 11.3, 11.1]);
    assert.equal(p90.hz, 90);
    assert.equal(p90.tier, 'high');
    assert.equal(p90.steadyFlushFrames, 6);

    const p144 = buildFrameProfileForHz(144);
    assert.equal(p144.hz, 144);
    assert.equal(p144.tier, 'high');
    assert.equal(p144.steadyFlushFrames, 10);

    const noisy60 = computeFrameProfile([0.4, 16.7, 16.6, 130.0, 16.8, NaN, 16.5]);
    assert.equal(noisy60.hz, 60);

    assert.equal(computeFrameProfile([]).hz, 60);
    assert.equal(computeFrameProfile([16.6, 16.7]).hz, 60);
    assert.equal(snapRefreshRateHz(NaN), 60);
  });
});

describe('quick time expression parser & fuzzy matcher', () => {
  const fixedNow = new Date(2026, 10, 14, 15, 30, 0, 0).getTime();
  const zhLabels: Record<string, string> = {
    '': '全部时间',
    '5m': '最近 5 分钟',
    '15m': '最近 15 分钟',
    '30m': '最近 30 分钟',
    '1h': '最近 1 小时',
    '3h': '最近 3 小时',
    '6h': '最近 6 小时',
    '12h': '最近 12 小时',
    '24h': '最近 24 小时',
    today: '今天',
    yesterday: '昨天',
    '7d': '最近 7 天',
    '30d': '最近 30 天',
  };
  const zhShort: Record<string, string> = {
    '': '不限',
    '5m': '5m',
    '15m': '15m',
    '30m': '30m',
    '1h': '1h',
    '3h': '3h',
    '6h': '6h',
    '12h': '12h',
    '24h': '24h',
    today: '今天',
    yesterday: '昨天',
    '7d': '7d',
    '30d': '30d',
  };

  it('parses ad-hoc English/Chinese relative durations, pasted timestamps, and explicit ranges while rejecting noise', () => {
    assert.deepEqual(parseQuickTimeExpression('45m', fixedNow), { spec: '45m', kind: 'relative' });
    assert.deepEqual(parseQuickTimeExpression('2h', fixedNow), { spec: '2h', kind: 'relative' });
    assert.deepEqual(parseQuickTimeExpression('最近10分钟', fixedNow), { spec: '10m', kind: 'relative' });
    assert.deepEqual(parseQuickTimeExpression('2小时', fixedNow), { spec: '2h', kind: 'relative' });
    assert.deepEqual(parseQuickTimeExpression('半小时', fixedNow), { spec: '30m', kind: 'preset' });
    assert.deepEqual(parseQuickTimeExpression('15m', fixedNow), { spec: '15m', kind: 'preset' });
    assert.deepEqual(parseQuickTimeExpression('不限', fixedNow), { spec: '', kind: 'preset' });
    assert.deepEqual(parseQuickTimeExpression('2026-11-14', fixedNow), {
      spec: '2026-11-14',
      kind: 'range',
    });
    assert.deepEqual(parseQuickTimeExpression('09:30', fixedNow), {
      spec: '2026-11-14 09:30:00..',
      kind: 'range',
    });
    assert.deepEqual(parseQuickTimeExpression('2026-11-14 10:00..2026-11-14 11:30', fixedNow), {
      spec: '2026-11-14 10:00:00..2026-11-14 11:30:59',
      kind: 'range',
    });

    const pasted = parseQuickTimeExpression('2026-11-14 09:15:20 [ERROR] timeout', fixedNow);
    assert.deepEqual(pasted, { spec: '2026-11-14 09:15:20..', kind: 'range' });

    assert.equal(parseQuickTimeExpression('foo..bar', fixedNow), null);
    assert.equal(parseQuickTimeExpression('abc', fixedNow), null);
    assert.equal(parseQuickTimeExpression('2026', fixedNow), null);
    assert.equal(parseQuickTimeExpression('0m', fixedNow), null);
  });

  it('fuzzy-matches built-in presets and prepends deduplicated custom candidates', () => {
    const emptyList = matchQuickTimeCandidates('', zhLabels, zhShort, fixedNow);
    assert.equal(emptyList.length, 13);
    assert.equal(emptyList[0].spec, '');

    const match15 = matchQuickTimeCandidates('15', zhLabels, zhShort, fixedNow);
    assert.equal(match15[0].spec, '15m');
    assert.equal(match15[0].isCustom, false);
    assert.ok(match15[0].shortRanges.length > 0);

    const match15m = matchQuickTimeCandidates('15m', zhLabels, zhShort, fixedNow);
    assert.equal(match15m.filter((c) => c.spec === '15m').length, 1);
    assert.equal(match15m[0].spec, '15m');
    assert.equal(match15m[0].isCustom, false);

    const matchTod = matchQuickTimeCandidates('tod', zhLabels, zhShort, fixedNow);
    assert.ok(matchTod.some((c) => c.spec === 'today'));

    const matchYdayZh = matchQuickTimeCandidates('昨', zhLabels, zhShort, fixedNow);
    assert.equal(matchYdayZh[0].spec, 'yesterday');

    const match45m = matchQuickTimeCandidates('45m', zhLabels, zhShort, fixedNow);
    assert.equal(match45m[0].spec, '45m');
    assert.equal(match45m[0].isCustom, true);
    assert.equal(match45m[0].shortLabel, '45m');
    assert.equal(match45m[0].fullLabel, '最近 45 分钟');

    assert.equal(formatTimeScopeLabel('45m', zhLabels, fixedNow), '最近 45 分钟');
    assert.equal(formatTimeTriggerLabel('', zhShort, '不限', fixedNow), '不限');
    assert.equal(formatTimeTriggerLabel('45m', zhShort, '不限', fixedNow), '45m');
    assert.equal(formatTimeTriggerLabel('today', zhShort, '不限', fixedNow), '今天');
  });
});


