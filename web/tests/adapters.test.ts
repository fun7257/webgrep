import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  CodeStreamStatsTracker,
  buildCodeVirtualLayout,
  buildLogVirtualLayout,
  codeAdapter,
  detectCodeLanguage,
  extractLineTime,
  getCachedPlainMeta,
  getCachedPlainProbe,
  logAdapter,
  parseLineLogMeta,
  preserveLargeJsonIntegers,
  probeLogLineFast,
  resolveBatchViewAdapter,
  resolveHitAdapterId,
  resolvePathAdapterId,
  resolveSourceAdapterId,
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

describe('Presentation Adapter layer & simple line-log time probe', () => {
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

    const shortRaw = '{"count":42,"latency":0.15}';
    assert.equal(preserveLargeJsonIntegers(shortRaw), shortRaw);
  });

  it('extracts timestamps and JSON/KV shape cleanly without level/category/summary heuristics', () => {
    const ndjson =
      '{"t":"2026-09-11T08:00:00.01+08:00","l":"info","category":"accessLog","message":"ok"}';
    const pJson = probeLogLineFast(ndjson);
    assert.equal(pJson.isLog, true);
    assert.equal(pJson.isJson, true);
    assert.equal(pJson.hasTime, true);
    assert.equal(pJson.dateKey, '2026-09-11');
    assert.equal(pJson.timeShort, '08:00:00.010');
    assert.equal(pJson.timeLabel, '09-11 08:00:00.010');

    const dockerJson =
      '2026-11-14T04:10:01.123456789Z {"level":"error","service":"api-gateway","msg":"upstream_timeout"}';
    const pDocker = probeLogLineFast(dockerJson);
    assert.equal(pDocker.isLog, true);
    assert.equal(pDocker.isJson, true);
    assert.equal(pDocker.dateKey, '2026-11-14');
    assert.equal(pDocker.timeShort, '04:10:01.123');

    const stderrKv = '[STDERR] trace_id=tr-1 span_id=sp-2 status=502';
    const pKv = probeLogLineFast(stderrKv);
    assert.equal(pKv.isLog, true);
    assert.equal(pKv.isKv, true);
    assert.equal(pKv.hasTime, false);

    const nanoJson =
      '1730340905123456789 {"level":"warn","msg":"slow query","duration":184}';
    const tNano = extractLineTime(nanoJson);
    assert.ok(tNano);
    assert.equal(tNano.timeShort.length, 12);

    // Timestamped text line even WITHOUT any severity word
    const textWithTime = '2026-09-11 08:00:00.123 upstream ready';
    const pText = probeLogLineFast(textWithTime);
    assert.equal(pText.isLog, true);
    assert.equal(pText.hasTime, true);
    assert.equal(pText.dateKey, '2026-09-11');
    assert.equal(pText.timeShort, '08:00:00.123');

    // Verbatim line body preserved by parseLineLogMeta
    const meta = parseLineLogMeta(makeHit('logs/app.log', textWithTime, 5));
    assert.equal(meta.bodyText, textWithTime);
    assert.equal(meta.timeLabel, '09-11 08:00:00.123');

    // Arbitrary text without timestamp/JSON/KV
    const plain = probeLogLineFast('arbitrary unformatted content');
    assert.equal(plain.isLog, false);
    assert.equal(plain.hasTime, false);
  });

  it('routes log vs code strictly by configured DataSource preset without content heuristics', () => {
    const jsonLogLine = '{"t":"2026-09-11T08:00:00.009+08:00","l":"info","message":"hello"}';
    const logHit = makeHit('logs/test.log', jsonLogLine);
    const tsInLogSource = makeHit('logs/src/app.ts', 'const level = "error";');
    const logInCodeSource = makeHit('repo/test.log', jsonLogLine);
    const tsCodeHit = makeHit('repo/src/app.ts', 'const level = "error";');
    const plainBlobHit = makeHit('logs/notes.bin', 'arbitrary unformatted content');

    const logSrc = makeSource('logs', { pluginPreset: 'timeseries' });
    const codeSrc = makeSource('repo', { pluginPreset: 'code' });
    const defaultSrc = makeSource('defaultsrc');

    const sourceByName = new Map<string, DataSourceItem>([
      ['logs', logSrc],
      ['repo', codeSrc],
      ['defaultsrc', defaultSrc],
    ]);

    assert.equal(resolveSourceForHit('logs/test.log', sourceByName), logSrc);
    assert.equal(resolveSourceAdapterId(logSrc), 'log');
    assert.equal(resolveSourceAdapterId(codeSrc), 'code');
    assert.equal(resolveSourceAdapterId(defaultSrc), 'log');
    assert.equal(resolveSourceAdapterId(undefined), 'log');

    // View is strictly determined by DataSource configuration, regardless of file extension or text
    assert.equal(resolveHitAdapterId(logHit, logSrc), 'log');
    assert.equal(resolveHitAdapterId(tsInLogSource, logSrc), 'log');
    assert.equal(resolveHitAdapterId(plainBlobHit, logSrc), 'log');
    assert.equal(resolveHitAdapterId(tsCodeHit, codeSrc), 'code');
    assert.equal(resolveHitAdapterId(logInCodeSource, codeSrc), 'code');

    // Path-based resolution for InspectorPane preserves per-source view even in mixed-source batches
    assert.equal(resolvePathAdapterId('logs/src/app.ts', sourceByName), 'log');
    assert.equal(resolvePathAdapterId('repo/test.log', sourceByName), 'code');
    assert.equal(resolvePathAdapterId('unknown/file.ts', sourceByName), 'log');

    assert.equal(logAdapter.inspectContextLines, 0);
    assert.equal(codeAdapter.inspectContextLines, 12);
    assert.equal(logAdapter.supportsStructuredToggle, true);
    assert.equal(codeAdapter.supportsStructuredToggle, false);

    // Batch view uses code when active sources / hits belong solely to code sources, otherwise log
    assert.equal(resolveBatchViewAdapter([logHit], sourceByName, [logSrc]), 'log');
    assert.equal(resolveBatchViewAdapter([tsCodeHit], sourceByName, [codeSrc]), 'code');
    assert.equal(resolveBatchViewAdapter([logInCodeSource], sourceByName, [codeSrc]), 'code');
    assert.equal(resolveBatchViewAdapter([], sourceByName, [codeSrc]), 'code');
    assert.equal(resolveBatchViewAdapter([], sourceByName, [logSrc, codeSrc]), 'log');
    assert.equal(resolveBatchViewAdapter([logHit, tsCodeHit], sourceByName, [logSrc, codeSrc]), 'log');
  });

  it('builds simple 1:1 line-log virtual layout matching plain line height math', () => {
    const h1 = makeHit('logs/app.log', '{"t":"2026-09-11T08:00:00.009+08:00","msg":"a"}', 1);
    const h2 = makeHit('logs/app.log', '2026-09-12 00:00:01.050 ' + 'x'.repeat(250), 2);

    const layout = buildLogVirtualLayout({
      hits: [h1, h2],
      ctx: {
        fontPx: 13.5,
        lineHeight: 21,
        baseHitPad: 12,
        maxPreviewLines: 3,
        wordWrap: true,
        charsPerLine: 100,
        isCompact: false,
        density: 'compact',
      },
      budget: 540,
      getLineProbe: getCachedPlainProbe,
    });

    assert.equal(layout.lines.length, 2);
    assert.equal(layout.lines[0], 1);
    assert.equal(layout.lines[1], 3);
    assert.equal(layout.offsets.length, 3);
    assert.equal(layout.offsets[1], 12 + 22 + 21);
    assert.equal(layout.totalHeight, 12 + 22 + 21 + (12 + 22 + 3 * 21));
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

    assert.equal(expandedLayout.visibleFileCount, 2);
    assert.equal(expandedLayout.matchedHitCount, 3);
    assert.equal(expandedLayout.items.length, 5);
    assert.equal(expandedLayout.items[0].kind, 'file-header');
    assert.equal(expandedLayout.items[1].kind === 'hit' ? expandedLayout.items[1].hitIdx : -1, 0);
    assert.equal(expandedLayout.items[2].kind === 'hit' ? expandedLayout.items[2].hitIdx : -1, 2);
    assert.equal(expandedLayout.hitIdxToVirtualIdx[2], 2);

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
    assert.equal(collapsedLayout.items.length, 3);
    assert.equal(collapsedLayout.hitIdxToVirtualIdx[0], 0);
    assert.equal(collapsedLayout.hitIdxToVirtualIdx[2], 0);
    assert.equal(collapsedLayout.hitIdxToVirtualIdx[1], 2);

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
