import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  CodeStreamStatsTracker,
  LogStreamStatsTracker,
  buildCodeVirtualLayout,
  buildLogVirtualLayout,
  classifyHitBestAdapter,
  codeAdapter,
  detectCodeLanguage,
  doesTextContainActiveQuery,
  getCachedLogProbe,
  getCachedPlainMeta,
  getCachedPlainProbe,
  logAdapter,
  parseLogLine,
  plainAdapter,
  preserveLargeJsonIntegers,
  probeLogLineFast,
  resolveBatchAdapterSummary,
  resolveDominantAdapter,
  resolveHitAdapterId,
  resolveSourceForHit,
} from '../src/lib/adapters/index.ts';
import type { DataSourceItem, HitItem } from '../src/lib/types.ts';

function makeHit(file: string, text: string, line = 1): HitItem {
  return {
    file,
    line,
    col: 1,
    text,
    spans: [],
  };
}

function makeSource(
  id: string,
  overrides: Partial<DataSourceItem> = {}
): DataSourceItem {
  return {
    id,
    kind: 'dir',
    name: id,
    enabled: true,
    ready: true,
    summary: `/var/log/${id}`,
    config: { path: `/var/log/${id}` },
    path: `/var/log/${id}`,
    exists: true,
    ...overrides,
  };
}

describe('Presentation Adapter layer & log parser', () => {
  it('preserves >= 16-digit unquoted JSON integers verbatim while leaving quoted/short/float numbers untouched', () => {
    const raw =
      '{"t":"2026-09-11T08:00:00.009+08:00","count":1,"ratio":0.95,"idStr":"12345678901234567890","data":{"configNum":7233907330973722123,"neg":-9223372036854775807}}';
    const safe = preserveLargeJsonIntegers(raw);
    const parsed = JSON.parse(safe) as Record<string, any>;
    assert.equal(parsed.count, 1);
    assert.equal(parsed.ratio, 0.95);
    assert.equal(parsed.idStr, '12345678901234567890');
    assert.equal(parsed.data.configNum, '7233907330973722123');
    assert.equal(parsed.data.neg, '-9223372036854775807');

    // Fast path returns exact string reference when no 16+ digit sequence exists
    const shortRaw = '{"count":42,"latency":0.15}';
    assert.equal(preserveLargeJsonIntegers(shortRaw), shortRaw);
  });

  it('parses real production NDJSON shapes (accessLog, joseKeyFail, influxdbHTTPDo, entQuery, errors, warn, debug)', () => {
    const accessLine =
      '{"t":"2026-09-11T08:00:00.009+08:00","l":"info","deviceID":"","traceID":"308b85351438c15a","account":"","category":"accessLog","ip":"127.0.0.6","method":"POST","route":"/inner/v1/biz-setting-flag","uri":"/inner/v1/biz-setting-flag?app=onlinehall","host":"test.gf.com.cn","origin":"","status":200,"connecting":1,"latency":0,"ioCount":0,"size":"33 B","bytes":33,"data":{"configNum":7233907330973722123}}';
    const access = parseLogLine(accessLine);
    assert.ok(access);
    assert.equal(access.format, 'ndjson');
    assert.equal(access.level, 'info');
    assert.equal(access.levelBadge, 'INF');
    assert.equal(access.levelFilterToken, '"l":"info"');
    assert.equal(access.category, 'accessLog');
    assert.equal(access.categoryFilterToken, '"category":"accessLog"');
    assert.equal(access.timeShort, '08:00:00.009');
    assert.equal(access.timeDate, '2026-09-11');
    assert.equal(access.http?.method, 'POST');
    assert.equal(access.http?.route, '/inner/v1/biz-setting-flag');
    assert.equal(access.http?.status, 200);
    assert.equal(access.http?.latencyText, '0ms');
    assert.equal(access.http?.sizeText, '33 B');
    assert.equal(access.summary, 'POST /inner/v1/biz-setting-flag');
    assert.equal(access.traceId, '308b85351438c15a');
    assert.equal(access.truncated, false);
    assert.equal((access.structuredData?.data as any)?.configNum, '7233907330973722123');
    // Empty strings like deviceID="" and account="" are filtered from keyFields
    assert.equal(access.keyFields.some((f) => f.key === 'deviceID' || f.key === 'account'), false);

    // Variable fractional timestamp (.01+08:00 -> 08:00:00.010)
    const joseLine =
      '{"t":"2026-09-11T08:00:00.01+08:00","l":"info","deviceID":"","traceID":"308b85351438c15a","account":"","category":"joseKeyFail","message":"get jose track id from request header fail"}';
    const jose = parseLogLine(joseLine);
    assert.ok(jose);
    assert.equal(jose.timeShort, '08:00:00.010');
    assert.equal(jose.category, 'joseKeyFail');
    assert.equal(jose.summary, 'get jose track id from request header fail');

    // No message field (influxdbHTTPDo)
    const influxHttp = parseLogLine(
      '{"t":"2026-09-11T08:00:08.609+08:00","l":"info","category":"influxdbHTTPDo","total":26.327117}'
    );
    assert.ok(influxHttp);
    assert.equal(influxHttp.summary, 'total=26.327117');

    // Empty message field (entQuery)
    const entQuery = parseLogLine(
      '{"t":"2026-09-11T08:00:58.023+08:00","l":"info","category":"entQuery","schema":"StatsConfig","result":0,"processing":1,"totalProcessing":2,"use":"19.380594ms","message":""}'
    );
    assert.ok(entQuery);
    assert.ok(entQuery.summary.includes('schema=StatsConfig'));
    assert.ok(entQuery.summary.includes('use=19.380594ms'));

    // Error / warn / debug records
    const errRec = parseLogLine(
      '{"t":"2026-09-11T11:17:35.908+08:00","l":"error","instance":"common","category":"redisProcessFail","error":"context canceled"}'
    );
    assert.ok(errRec);
    assert.equal(errRec.level, 'error');
    assert.equal(errRec.levelBadge, 'ERR');
    assert.equal(errRec.errorText, 'context canceled');
    assert.equal(errRec.summary, 'context canceled');

    const warnRec = parseLogLine(
      '{"t":"2026-09-11T09:40:53.725+08:00","l":"warn","category":"influxdb2client:performance","message":"Application name is not set"}'
    );
    assert.ok(warnRec);
    assert.equal(warnRec.level, 'warn');
    assert.equal(warnRec.levelBadge, 'WRN');

    const dbgRec = parseLogLine(
      '{"t":"2026-09-11T08:00:08.582+08:00","l":"debug","category":"influxdb2client:business","message":"Write proc: received write request"}'
    );
    assert.ok(dbgRec);
    assert.equal(dbgRec.level, 'debug');
    assert.equal(dbgRec.levelBadge, 'DBG');
  });

  it('recovers intact envelope fields and truncated tail from hard-truncated JSON lines', () => {
    const truncatedLine =
      '{"t":"2026-09-11T08:19:56.271+08:00","l":"info","deviceID":"01a06b8e-6883-7a5a-91df-cecab2c493c7","traceID":"7973979e4b12c3e3","account":"030680228968","category":"accessLog","ip":"10.49.80.135","method":"GET","route":"/my/profile","status":200,"data":{"autoFillAnswers":null,"questions":[{"content":"5年以上"},{"content":"unclosed';
    const rec = parseLogLine(truncatedLine);
    assert.ok(rec);
    assert.equal(rec.format, 'truncated-json');
    assert.equal(rec.truncated, true);
    assert.equal(rec.timeShort, '08:19:56.271');
    assert.equal(rec.level, 'info');
    assert.equal(rec.category, 'accessLog');
    assert.equal(rec.traceId, '7973979e4b12c3e3');
    assert.equal(rec.http?.method, 'GET');
    assert.equal(rec.http?.route, '/my/profile');
    assert.equal(rec.http?.status, 200);
    assert.equal(rec.structuredData?.account, '030680228968');
    assert.ok(rec.truncatedTail?.includes('"data"'));
  });

  it('parses Docker RFC3339Nano JSON, bare [STDERR] KV, leading 19-digit ns, and standard text logs', () => {
    const dockerJson =
      '2026-11-14T04:10:01.123456789Z {"level":"error","service":"api-gateway","msg":"upstream_timeout"}';
    const r1 = parseLogLine(dockerJson);
    assert.ok(r1);
    assert.equal(r1.format, 'docker-json');
    assert.equal(r1.level, 'error');
    assert.equal(r1.category, 'api-gateway');
    assert.equal(r1.summary, 'upstream_timeout');
    assert.equal(r1.timeShort, '04:10:01.123');

    const stderrKv = '[STDERR] trace_id=tr-1 span_id=sp-2 status=502';
    const p2 = probeLogLineFast(stderrKv);
    assert.equal(p2.isLog, true);
    assert.equal(p2.level, 'error');
    const r2 = parseLogLine(stderrKv);
    assert.ok(r2);
    assert.equal(r2.format, 'kv');
    assert.equal(r2.level, 'error');
    assert.equal(r2.traceId, 'tr-1');
    assert.equal(r2.http?.status, 502);

    const nanoJson =
      '1730340905123456789 {"level":"warn","msg":"slow query","duration":184}';
    const r3 = parseLogLine(nanoJson);
    assert.ok(r3);
    assert.equal(r3.level, 'warn');
    assert.equal(r3.summary, 'slow query');
    assert.ok(r3.timeShort.length === 12);

    const textLog = '2026-09-11 08:00:00.123 [ERROR] [auth] token expired trace_id=abc12345';
    const p4 = probeLogLineFast(textLog);
    assert.equal(p4.isLog, true);
    assert.equal(p4.level, 'error');
    const r4 = parseLogLine(textLog);
    assert.ok(r4);
    assert.equal(r4.format, 'text-log');
    assert.equal(r4.level, 'error');
    assert.equal(r4.category, 'auth');
    assert.equal(r4.traceId, 'abc12345');
    assert.ok(r4.summary.includes('token expired'));
  });

  it('respects source presets, code extensions, and user viewMode overrides across log/code/plain', () => {
    const jsonLogLine = '{"t":"2026-09-11T08:00:00.009+08:00","l":"info","message":"hello"}';
    const logHit = makeHit('logs/test.log', jsonLogLine);
    const jsonEventsHit = makeHit('mixed/events.json', jsonLogLine);
    const codeJsonHit = makeHit('mixed/package.json', jsonLogLine);
    const tsCodeHit = makeHit('mixed/src/app.ts', 'const level = "error";');
    const plainBlobHit = makeHit('mixed/notes.bin', 'arbitrary unformatted content');

    const logSrc = makeSource('logs', { pluginPreset: 'timeseries' });
    const codeSrc = makeSource('repo', { pluginPreset: 'code' });
    const autoSrc = makeSource('mixed', { pluginPreset: 'auto' });
    const rawSrc = makeSource('rawsrc', { pluginPreset: 'raw' });

    const sourceByName = new Map<string, DataSourceItem>([
      ['logs', logSrc],
      ['repo', codeSrc],
      ['mixed', autoSrc],
      ['rawsrc', rawSrc],
    ]);

    assert.equal(resolveSourceForHit('logs/test.log', sourceByName), logSrc);
    assert.equal(classifyHitBestAdapter(logHit, logSrc), 'log');
    assert.equal(classifyHitBestAdapter(jsonEventsHit, autoSrc), 'log');
    assert.equal(classifyHitBestAdapter(codeJsonHit, autoSrc), 'code');
    assert.equal(classifyHitBestAdapter(tsCodeHit, autoSrc), 'code');
    assert.equal(classifyHitBestAdapter(logHit, codeSrc), 'code');
    assert.equal(classifyHitBestAdapter(logHit, rawSrc), 'plain');
    assert.equal(classifyHitBestAdapter(plainBlobHit, autoSrc), 'plain');

    assert.equal(resolveHitAdapterId(logHit, logSrc, 'auto'), 'log');
    assert.equal(resolveHitAdapterId(tsCodeHit, autoSrc, 'auto'), 'code');

    // Explicit user preference overrides
    assert.equal(resolveHitAdapterId(logHit, logSrc, 'plain'), 'plain');
    assert.equal(resolveHitAdapterId(logHit, codeSrc, 'log'), 'log');
    assert.equal(resolveHitAdapterId(logHit, logSrc, 'code'), 'code');

    // Inspector context depth & toggle capabilities
    assert.equal(logAdapter.inspectContextLines, 0);
    assert.equal(codeAdapter.inspectContextLines, 12);
    assert.equal(plainAdapter.inspectContextLines, 0);
    assert.equal(logAdapter.supportsStructuredToggle, true);
    assert.equal(codeAdapter.supportsStructuredToggle, false);
    assert.equal(plainAdapter.supportsStructuredToggle, true);

    // Dominant & mixed batch summary sampling
    assert.equal(resolveDominantAdapter([logHit], sourceByName, 'auto'), 'log');
    assert.equal(resolveDominantAdapter([tsCodeHit], sourceByName, 'auto'), 'code');
    assert.equal(resolveDominantAdapter([plainBlobHit], sourceByName, 'auto'), 'plain');
    assert.equal(resolveDominantAdapter([tsCodeHit], sourceByName, 'log'), 'log');
    assert.equal(resolveDominantAdapter([logHit], sourceByName, 'code'), 'code');

    const mixedSummary = resolveBatchAdapterSummary(
      [logHit, logHit, tsCodeHit],
      sourceByName,
      'auto'
    );
    assert.equal(mixedSummary.isMixed, true);
    assert.equal(mixedSummary.detectedDominant, 'log');
    assert.equal(mixedSummary.sampleCounts.log, 2);
    assert.equal(mixedSummary.sampleCounts.code, 1);

    // Tail striding sees code hits even after >32 leading log hits
    const manyLogs = Array.from({ length: 40 }, (_, i) =>
      makeHit('logs/test.log', jsonLogLine, i + 1)
    );
    const tailMixed = resolveBatchAdapterSummary([...manyLogs, tsCodeHit], sourceByName, 'auto');
    assert.equal(tailMixed.isMixed, true);
    assert.equal(tailMixed.sampleCounts.code, 1);
  });

  it('tracks incremental O(delta) stats across streaming chunks and resets cleanly on new search', () => {
    const srcMap = new Map<string, DataSourceItem>([
      ['logs', makeSource('logs', { pluginPreset: 'timeseries' })],
    ]);
    const tracker = new LogStreamStatsTracker();

    const h1 = makeHit(
      'logs/test.log',
      '{"t":"2026-09-11T08:00:00.009+08:00","l":"info","category":"accessLog","message":"ok"}',
      1
    );
    const h2 = makeHit(
      'logs/test.log',
      '{"t":"2026-09-11T08:00:01.000+08:00","l":"error","category":"httpError","error":"502"}',
      2
    );
    const h3 = makeHit(
      'logs/test.log',
      '{"t":"2026-09-11T08:00:02.000+08:00","l":"error","category":"accessLog","error":"timeout"}',
      3
    );

    const s1 = tracker.update([h1, h2], srcMap, 'auto');
    assert.equal(s1.logCount, 2);
    assert.deepEqual(
      s1.levels.map((l) => [l.badge, l.count]),
      [
        ['ERR', 1],
        ['INF', 1],
      ]
    );

    // Append batch sharing exact first hit reference
    const s2 = tracker.update([h1, h2, h3], srcMap, 'auto');
    assert.equal(s2.logCount, 3);
    assert.deepEqual(
      s2.levels.map((l) => [l.badge, l.count]),
      [
        ['ERR', 2],
        ['INF', 1],
      ]
    );
    assert.equal(s2.topCategories[0].category, 'accessLog');
    assert.equal(s2.topCategories[0].count, 2);

    // New search replaces hits[0] -> resets cleanly
    const s3 = tracker.update([h2], srcMap, 'auto');
    assert.equal(s3.logCount, 1);
    assert.equal(s3.levels[0].badge, 'ERR');
    assert.equal(s3.levels[0].count, 1);
  });

  it('computes deterministic row heights and evaluates multi-term headline matching with AND semantics', () => {
    const hit = makeHit(
      'logs/test.log',
      '{"t":"2026-09-11T08:00:00.009+08:00","l":"info","category":"accessLog","method":"POST","route":"/inner/v1/biz-setting-flag","data":{"configNum":7233907330973722000}}'
    );
    const probe = probeLogLineFast(hit.text);
    const compact = logAdapter.measureRow(probe, hit, {
      fontPx: 13.5,
      lineHeight: 21,
      baseHitPad: 12,
      maxPreviewLines: 3,
      wordWrap: true,
      charsPerLine: 100,
      isCompact: false,
      density: 'compact',
    });
    const comfortable = logAdapter.measureRow(probe, hit, {
      fontPx: 13.5,
      lineHeight: 21,
      baseHitPad: 18,
      maxPreviewLines: 3,
      wordWrap: true,
      charsPerLine: 100,
      isCompact: false,
      density: 'comfortable',
    });
    assert.equal(compact.lines, 1);
    assert.equal(compact.height, 10 + 21);
    assert.equal(comfortable.lines, 1);
    assert.equal(comfortable.height, 14 + 21);

    const headline = 'POST /inner/v1/biz-setting-flag\naccessLog';
    assert.equal(doesTextContainActiveQuery(headline, 'POST', ['accessLog'], false), true);
    assert.equal(
      doesTextContainActiveQuery(headline, 'POST', ['7233907330973722000'], false),
      false
    );
    assert.equal(doesTextContainActiveQuery(headline, '', [], false), true);
  });

  it('extracts dateKey in probeLogLineFast and inserts standalone date dividers in buildLogVirtualLayout', () => {
    const day1 = makeHit(
      'logs/app.log',
      '{"t":"2026-09-11T23:59:59.10+08:00","l":"info","category":"auth","message":"before midnight"}',
      1
    );
    const day1Late = makeHit(
      'logs/app.log',
      '{"t":"2026-09-11T23:59:59.99+08:00","l":"warn","category":"auth","message":"still day1"}',
      2
    );
    const day2 = makeHit(
      'logs/app.log',
      '{"t":"2026-09-12T00:00:01.05+08:00","l":"error","category":"auth","error":"after midnight"}',
      3
    );
    const nonLogFallback = makeHit('repo/src/main.ts', 'export const ok = true;', 10);

    assert.equal(probeLogLineFast(day1.text).dateKey, '2026-09-11');
    assert.equal(probeLogLineFast(day2.text).dateKey, '2026-09-12');
    assert.equal(
      probeLogLineFast('2026-10-05 14:22:01 [ERROR] db connection lost').dateKey,
      '2026-10-05'
    );

    const srcMap = new Map<string, DataSourceItem>([
      ['logs', makeSource('logs', { pluginPreset: 'timeseries' })],
      ['repo', makeSource('repo', { pluginPreset: 'code' })],
    ]);

    const layout = buildLogVirtualLayout({
      hits: [day1, day1Late, day2, nonLogFallback],
      sourceByName: srcMap,
      forceLogSurface: false,
      ctx: {
        fontPx: 13.5,
        lineHeight: 21,
        baseHitPad: 12,
        maxPreviewLines: 1,
        wordWrap: true,
        charsPerLine: 100,
        isCompact: false,
        density: 'compact',
      },
      budget: 240,
      getLogProbe: getCachedLogProbe,
      getPlainProbe: getCachedPlainProbe,
    });

    assert.equal(layout.denseLogMode, true);
    // Expected items: [hit0(day1), hit1(day1), date:2026-09-12, hit2(day2), fallbackHit3]
    // Date divider is only inserted on date transitions (not above the first hit).
    assert.equal(layout.items.length, 5);
    assert.deepEqual(
      layout.items.map((it) => it.kind),
      ['hit', 'hit', 'date', 'hit', 'hit']
    );
    assert.equal(layout.items[2].kind === 'date' ? layout.items[2].dateKey : '', '2026-09-12');
    assert.equal(layout.items[4].kind === 'hit' ? layout.items[4].isNativeLog : true, false);
    assert.deepEqual([...layout.hitIdxToVirtualIdx], [0, 1, 3, 4]);
  });

  it('tracks incremental CodeStreamStatsTracker & builds file-grouped CodeVirtualLayout', () => {
    const hZig1 = makeHit('repo/src/main.zig', 'pub fn main() !void {}', 12);
    const hTs1 = makeHit('repo/web/src/App.svelte', '<script lang="ts">let x = 1;</script>', 5);
    const hZig2 = makeHit('repo/src/main.zig', 'try server.listen();', 48);
    const hDocker = makeHit('repo/Dockerfile', 'FROM alpine:3.20', 1);

    assert.equal(detectCodeLanguage('repo/src/main.zig')?.id, 'zig');
    assert.equal(detectCodeLanguage('repo/Dockerfile')?.label, 'Dockerfile');

    const tracker = new CodeStreamStatsTracker();
    const s1 = tracker.update([hZig1, hTs1]);
    assert.equal(s1.fileCount, 2);
    assert.equal(s1.totalScanned, 2);

    const s2 = tracker.update([hZig1, hTs1, hZig2, hDocker]);
    assert.equal(s2.fileCount, 3);
    assert.equal(s2.languages[0].id, 'zig');
    assert.equal(s2.languages[0].count, 2);

    // Build layout coalescing interleaved hits for `repo/src/main.zig` under one file header
    const expandedLayout = buildCodeVirtualLayout({
      hits: [hZig1, hTs1, hZig2],
      collapsedFiles: new Set(),
      activeLangFilter: null,
      activeDirFilter: null,
      ctx: {
        fontPx: 13.5,
        lineHeight: 21,
        baseHitPad: 12,
        maxPreviewLines: 3,
        wordWrap: true,
        charsPerLine: 100,
        isCompact: false,
        density: 'comfortable',
      },
      budget: 540,
      getPlainMeta: getCachedPlainMeta,
      getPlainProbe: getCachedPlainProbe,
    });

    // main.zig header -> hZig1 -> hZig2 -> App.svelte header -> hTs1
    assert.equal(expandedLayout.visibleFileCount, 2);
    assert.equal(expandedLayout.matchedHitCount, 3);
    assert.equal(expandedLayout.items.length, 5);
    assert.equal(expandedLayout.items[0].kind, 'file-header');
    assert.equal(expandedLayout.items[1].kind === 'hit' ? expandedLayout.items[1].hitIdx : -1, 0);
    assert.equal(expandedLayout.items[2].kind === 'hit' ? expandedLayout.items[2].hitIdx : -1, 2);
    assert.equal(expandedLayout.hitIdxToVirtualIdx[2], 2);

    // Collapsing main.zig hides its 2 hit rows and maps hits 0 and 2 to header index 0
    const collapsedLayout = buildCodeVirtualLayout({
      hits: [hZig1, hTs1, hZig2],
      collapsedFiles: new Set(['repo/src/main.zig']),
      activeLangFilter: null,
      activeDirFilter: null,
      ctx: {
        fontPx: 13.5,
        lineHeight: 21,
        baseHitPad: 12,
        maxPreviewLines: 3,
        wordWrap: true,
        charsPerLine: 100,
        isCompact: false,
        density: 'comfortable',
      },
      budget: 540,
      getPlainMeta: getCachedPlainMeta,
      getPlainProbe: getCachedPlainProbe,
    });
    assert.equal(collapsedLayout.items.length, 3); // header(zig), header(svelte), hit(ts)
    assert.equal(collapsedLayout.hitIdxToVirtualIdx[0], 0);
    assert.equal(collapsedLayout.hitIdxToVirtualIdx[2], 0);
    assert.equal(collapsedLayout.hitIdxToVirtualIdx[1], 2);

    // View-local language filter preserves totalFileCount while narrowing visible hits
    const zigOnly = buildCodeVirtualLayout({
      hits: [hZig1, hTs1, hZig2],
      collapsedFiles: new Set(),
      activeLangFilter: 'zig',
      activeDirFilter: null,
      ctx: {
        fontPx: 13.5,
        lineHeight: 21,
        baseHitPad: 12,
        maxPreviewLines: 3,
        wordWrap: true,
        charsPerLine: 100,
        isCompact: false,
        density: 'comfortable',
      },
      budget: 540,
      getPlainMeta: getCachedPlainMeta,
      getPlainProbe: getCachedPlainProbe,
    });
    assert.equal(zigOnly.totalFileCount, 2);
    assert.equal(zigOnly.visibleFileCount, 1);
    assert.equal(zigOnly.matchedHitCount, 2);
    assert.equal(zigOnly.hitIdxToVirtualIdx[1], -1);
  });
});
