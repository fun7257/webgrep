import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildQueryCacheKeys,
  compileSearchQuery,
  computeDockerPreviewSinceSec,
  createQueryStep,
  encodeStepToWire,
  formatHistoryLabel,
  parseTimeModifierSpec,
} from '../src/lib/query.ts';
import {
  TIME_FORMAT_PRESETS,
  buildCalendarMonthGrid,
  buildCustomRangeSpec,
  formatTimeScopeLabel,
  parseCustomRangeDraft,
  parsePastedDateTime,
} from '../src/lib/time-range.ts';
import type { ScopeFilter } from '../src/lib/types.ts';
import {
  analyzeStructuredLine,
  buildHighlightSegments,
  decodeHumanEscapes,
  extractLeadingNanoTimestamp,
  getCachedHighlightSegments,
  highlightCodeWithMatches,
  universalPrettyStructure,
} from '../src/lib/utils.ts';

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

  it('time-range utilities build, parse, paste-detect, format labels, and build 42-cell calendar grids', () => {
    const fixedNow = new Date(2026, 10, 14, 9, 30, 0).getTime();

    // buildCustomRangeSpec + reverse swap + today fallback
    const fullDay = buildCustomRangeSpec(
      { startDate: '2026-11-14', startTime: '', endDate: '2026-11-12', endTime: '' },
      fixedNow
    );
    assert.deepEqual(fullDay, {
      spec: '2026-11-12 00:00:00..2026-11-14 23:59:59',
      error: null,
    });

    const timeOnlyToday = buildCustomRangeSpec(
      { startDate: '', startTime: '09:15', endDate: '', endTime: '09:45' },
      fixedNow
    );
    assert.deepEqual(timeOnlyToday, {
      spec: '2026-11-14 09:15:00..2026-11-14 09:45:59',
      error: null,
    });

    const parsedDraft = parseCustomRangeDraft('2026-11-12 08:30:00..2026-11-14 18:00:00', fixedNow);
    assert.deepEqual(parsedDraft, {
      startDate: '2026-11-12',
      startTime: '08:30:00',
      endDate: '2026-11-14',
      endTime: '18:00:00',
    });

    // Paste parsers (Log4j comma ms, ISO UTC, compact 14-digit, dot/single-digit YMD, CJK, CLF, 12h AM/PM, epoch)
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

    // Label formatting
    const labels = { '': '全部时间', '15m': '最近 15 分钟' };
    assert.equal(formatTimeScopeLabel('2026-11-14 00:00:00..2026-11-14 23:59:59', labels, fixedNow), '2026-11-14');
    assert.equal(formatTimeScopeLabel('2026-11-12 00:00:00..2026-11-14 23:59:59', labels, fixedNow), '11-12 ~ 11-14');
    assert.equal(formatTimeScopeLabel('2026-11-14 10:00:00..2026-11-14 12:30:59', labels, fixedNow), '11-14 10:00 ~ 12:30');
    assert.equal(formatTimeScopeLabel('2026-11-14 10:00:00..', labels, fixedNow), '≥ 11-14 10:00');

    // Monday-first 42-cell grid for Nov 2026 (2026-11-01 is Sunday -> 6 leading days Oct 26..31)
    const grid = buildCalendarMonthGrid(2026, 10, '2026-11-14');
    assert.equal(grid.length, 42);
    assert.equal(grid[0].ymd, '2026-10-26');
    assert.equal(grid[0].inMonth, false);
    assert.equal(grid[6].ymd, '2026-11-01');
    assert.equal(grid[6].inMonth, true);
    assert.equal(grid.find((c) => c.ymd === '2026-11-14')?.isToday, true);
  });

  it('formatHistoryLabel formats step chain and draft cleanly', () => {
    const label = formatHistoryLabel(
      [createQueryStep('error'), createQueryStep('healthcheck', { exclude: true })],
      createQueryStep('timeout')
    );
    assert.equal(label, 'error → -healthcheck → timeout');
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

  it('indents compressed single-line HTML and arbitrary brace/bracket structures', () => {
    const htmlLine = '<div class="card"><span class="title">Payment Failed</span><p>Retry in 5s</p></div>';
    const htmlInfo = analyzeStructuredLine(htmlLine);
    assert.equal(htmlInfo.formatBadge, 'HTML');
    assert.ok(htmlInfo.bodyFormattedText?.includes('\n  <span class="title">'));

    const structLine =
      'OrderEvent{id: 9012, customer: "alice", items: [sku_1001, sku_1002], meta: {region: ap-east, retry: 3, gateway: edge-01}}';
    const pretty = universalPrettyStructure(structLine);
    assert.equal(pretty.badge, 'STRUCT');
    assert.ok(pretty.formatted.includes('\n  id: 9012,'));
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
