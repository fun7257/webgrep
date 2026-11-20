import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  HISTORY_STORAGE_KEY,
  LEGACY_SETTINGS_KEYS,
  MAX_SEARCH_HISTORY,
  SETTINGS_STORAGE_KEY,
  SOURCES_CACHE_STORAGE_KEY,
  THEME_STORAGE_KEY,
  clearHistoryFromStorage,
  loadCachedSourcesFromStorage,
  loadHistoryFromStorage,
  loadSettingsFromStorage,
  loadThemeFromStorage,
  normalizeCachedSources,
  normalizeHistoryEntries,
  normalizeSettings,
  readStorageWithFallback,
  sanitizeTenantId,
  saveCachedSourcesToStorage,
  saveHistoryToStorage,
  saveSettingsToStorage,
  saveThemeToStorage,
  upsertHistoryEntry,
  type StorageLike,
} from '../src/lib/state/persistence.ts';
import {
  MAX_FILE_CONTEXT_CACHE,
  FileContextLruCache,
  buildFileContextCacheKey,
  collapseAllGroups,
  isPossiblyTruncatedHitText,
  mergeContextBatchResult,
  mergeHitChunks,
  normalizeDoneTelemetry,
  resolveAnchorByteHint,
  toggleGroupCollapseAt,
} from '../src/lib/state/stream-buffer.ts';
import {
  buildAppendedStepList,
  buildEditedStepState,
  buildSearchRequestPlan,
  buildWorkbenchShareUrl,
  canToggleStepExcludeAt,
  computeActiveSources,
  computeEffectiveSourceIds,
  computeSourceTimeFormatsSig,
  computeTimeBasisSummary,
  isContentTimeSource,
  isDockerVirtualPath,
  normalizeScopeSourceLists,
  resolveSourceIdOrName,
  sameSourceList,
  toPortableSourceRefs,
} from '../src/lib/state/query-actions.ts';
import {
  computeDockerPreviewSinceSec,
  fetchAuthStatus,
  postAuthLogin,
  postTimePreview,
  postUpsertSource,
  requestFileWindow,
} from '../src/lib/state/api-client.ts';
import {
  SearchWsTransport,
  WS_DEGRADED_GRACE_MS,
} from '../src/lib/state/ws-transport.ts';
import { createQueryStep } from '../src/lib/query.ts';
import type {
  DataSourceItem,
  FileHitGroup,
  FileResponse,
  HitItem,
  McpStateResponse,
  ScopeFilter,
  SearchHistoryEntry,
  WsIncomingMessage,
} from '../src/lib/types.ts';

function makeMemoryStorage(initial: Record<string, string> = {}): StorageLike & {
  data: Map<string, string>;
} {
  const data = new Map<string, string>(Object.entries(initial));
  return {
    data,
    getItem: (key) => data.get(key) ?? null,
    setItem: (key, val) => {
      data.set(key, val);
    },
    removeItem: (key) => {
      data.delete(key);
    },
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

function makeHit(file: string, line: number, text = `line ${line}`, isContext = false): HitItem {
  return {
    file,
    line,
    col: 1,
    text,
    isContext,
    spans: isContext ? [] : [{ start: 0, end: Math.min(4, text.length) }],
  };
}

function makeFileResponse(path: string, lineNums: number[]): FileResponse {
  return {
    path,
    startLine: lineNums[0] ?? 1,
    totalLines: 100,
    binary: false,
    eof: false,
    lines: lineNums.map((n) => ({ n, text: `line ${n}` })),
  };
}

describe('state/persistence', () => {
  it('exposes canonical storage keys and reads primary before fallback safely', () => {
    assert.equal(HISTORY_STORAGE_KEY, 'webgrep.searchHistory.v2');
    assert.equal(THEME_STORAGE_KEY, 'webgrep.theme.v1');
    assert.equal(SETTINGS_STORAGE_KEY, 'webgrep.settings.v3');
    assert.deepEqual([...LEGACY_SETTINGS_KEYS], ['webgrep.settings.v2']);
    assert.equal(SOURCES_CACHE_STORAGE_KEY, 'webgrep.sourcesCache.v1');

    const throwingPrimary: StorageLike = {
      getItem: () => {
        throw new Error('blocked');
      },
    };
    const fallback = makeMemoryStorage({
      'webgrep.settings.v2': '{"hidden":true}',
    });
    assert.equal(
      readStorageWithFallback(throwingPrimary, fallback, [
        SETTINGS_STORAGE_KEY,
        ...LEGACY_SETTINGS_KEYS,
      ]),
      '{"hidden":true}'
    );

    const primary = makeMemoryStorage({
      [SETTINGS_STORAGE_KEY]: '{"hidden":false}',
    });
    assert.equal(
      readStorageWithFallback(primary, fallback, [
        SETTINGS_STORAGE_KEY,
        ...LEGACY_SETTINGS_KEYS,
      ]),
      '{"hidden":false}'
    );
  });

  it('sanitizes tenant IDs and normalizes/clamps settings and theme', () => {
    assert.equal(sanitizeTenantId('  prod/us-east 1  '), 'prod-us-east-1');
    assert.equal(sanitizeTenantId('   '), 'default');
    assert.equal(sanitizeTenantId('x'.repeat(90)).length, 64);

    const norm = normalizeSettings({
      respectIgnore: true,
      hidden: true,
      previewLines: 99,
      contextInitialLines: 0,
      contextStepLines: 999,
      contextAutoLoadPace: 'fast',
      maxResults: 999_999_999,
      codeFontSize: 4,
      wordWrap: false,
      resultDensity: 'compact',
      viewMode: 'log',
      locale: 'en',
      mcpMaxLogs: 500,
      tenant: '  team-a  ',
    });
    assert.equal(norm.respectIgnore, true);
    assert.equal(norm.hidden, true);
    assert.equal(norm.previewLines, 6);
    assert.equal(norm.contextInitialLines, 1);
    assert.equal(norm.contextStepLines, 100);
    assert.equal(norm.contextAutoLoadPace, 'fast');
    assert.equal(norm.maxResults, 500000);
    assert.equal(norm.codeFontSize, 10);
    assert.equal(norm.wordWrap, false);
    assert.equal(norm.resultDensity, 'compact');
    assert.equal(norm.viewMode, 'log');
    assert.equal(norm.locale, 'en');
    assert.equal(norm.mcpMaxLogs, 200);
    assert.equal(norm.tenant, 'team-a');

    assert.equal(normalizeSettings({}).viewMode, 'auto');
    assert.equal(normalizeSettings({ viewMode: 'code' }).viewMode, 'code');
    assert.equal(normalizeSettings({ viewMode: 'plain' }).viewMode, 'plain');
    assert.equal(normalizeSettings({ viewMode: 'invalid-mode' }).viewMode, 'auto');

    const storage = makeMemoryStorage();
    saveSettingsToStorage(storage, norm);
    const reloaded = loadSettingsFromStorage(storage, null);
    assert.deepEqual(reloaded, norm);

    assert.equal(loadThemeFromStorage(null, null), true);
    saveThemeToStorage(storage, false);
    assert.equal(loadThemeFromStorage(storage, null), false);
    saveThemeToStorage(storage, true);
    assert.equal(loadThemeFromStorage(storage, null), true);
  });

  it('caps searchHistory at 20 entries, deduplicates by id, and validates cached sources', () => {
    const entries: SearchHistoryEntry[] = Array.from({ length: 25 }, (_, i) => ({
      id: `id-${i}`,
      steps: [createQueryStep(`term-${i}`)],
      draft: null,
      scope: { sources: [], excludedSources: [], types: [], timePreset: '' },
      label: `term-${i}`,
      timestamp: 1000 + i,
    }));

    assert.equal(MAX_SEARCH_HISTORY, 20);
    assert.equal(normalizeHistoryEntries(entries).length, 20);

    const storage = makeMemoryStorage();
    saveHistoryToStorage(storage, entries);
    const loaded = loadHistoryFromStorage(storage);
    assert.equal(loaded.length, 20);
    assert.equal(loaded[0].id, 'id-0');

    const promoted = upsertHistoryEntry(loaded, {
      ...loaded[5],
      label: 'updated-5',
    });
    assert.equal(promoted.length, 20);
    assert.equal(promoted[0].id, 'id-5');
    assert.equal(promoted[0].label, 'updated-5');
    assert.equal(promoted.filter((e) => e.id === 'id-5').length, 1);

    clearHistoryFromStorage(storage);
    assert.deepEqual(loadHistoryFromStorage(storage), []);

    const validSrc = makeSource('s1');
    const mixed = normalizeCachedSources([
      validSrc,
      { id: 'bad-missing-exists', name: 'x', enabled: true },
      null,
    ]);
    assert.equal(mixed.length, 1);
    saveCachedSourcesToStorage(storage, mixed);
    assert.equal(loadCachedSourcesFromStorage(storage).length, 1);
  });
});

describe('state/stream-buffer', () => {
  it('detects possibly truncated lines accurately with short ASCII fast path', () => {
    assert.equal(isPossiblyTruncatedHitText('short line'), false);
    assert.equal(isPossiblyTruncatedHitText('a'.repeat(1400)), false);
    assert.equal(isPossiblyTruncatedHitText('a'.repeat(4092)), true);
    assert.equal(isPossiblyTruncatedHitText('中'.repeat(1364)), true);
  });

  it('mergeHitChunks preserves Copy-on-Write group & HitItem references and updates groupIndexByFile', () => {
    const h1 = makeHit('a.log', 1, 'first');
    const h2 = makeHit('b.log', 2, 'second');
    const h3 = makeHit('a.log', 3, 'third');
    const h4 = makeHit('a.log', 4, 'context-line', true);
    const h5 = makeHit('c.log', 1, 'fourth');

    const groupIndexByFile = new Map<string, number>();
    const firstMerge = mergeHitChunks([], [], groupIndexByFile, [[h1, h2]]);
    assert.equal(firstMerge.addedMatches, 2);
    assert.equal(firstMerge.fileGroups.length, 2);
    assert.equal(firstMerge.flatHits.length, 2);
    assert.equal(groupIndexByFile.get('a.log'), 0);
    assert.equal(groupIndexByFile.get('b.log'), 1);

    const prevGroupA: FileHitGroup = firstMerge.fileGroups[0];
    const prevGroupAItems = prevGroupA.items;
    const prevGroupB: FileHitGroup = firstMerge.fileGroups[1];

    // Second merge touches a.log (twice) and c.log (new), leaving b.log untouched
    const secondMerge = mergeHitChunks(
      firstMerge.fileGroups,
      firstMerge.flatHits,
      groupIndexByFile,
      [[h3], [h4, h5]]
    );

    assert.equal(secondMerge.addedMatches, 2); // h4 isContext does not increment match count
    assert.equal(secondMerge.fileGroups.length, 3);
    assert.equal(secondMerge.flatHits.length, 5);
    assert.equal(groupIndexByFile.get('c.log'), 2);

    // Untouched group b.log MUST preserve exact object reference
    assert.strictEqual(secondMerge.fileGroups[1], prevGroupB);
    // Touched group a.log MUST be shallow-copied without mutating previous array
    assert.notStrictEqual(secondMerge.fileGroups[0], prevGroupA);
    assert.equal(prevGroupAItems.length, 1);
    assert.equal(secondMerge.fileGroups[0].items.length, 3);
    assert.equal(secondMerge.fileGroups[0].matchCount, 2);

    // HitItem references MUST remain identical for WeakMap<HitItem, ...> cache hits
    assert.strictEqual(secondMerge.flatHits[0], h1);
    assert.strictEqual(secondMerge.flatHits[1], h2);
    assert.strictEqual(secondMerge.flatHits[2], h3);
    assert.strictEqual(secondMerge.flatHits[3], h4);
    assert.strictEqual(secondMerge.flatHits[4], h5);
    assert.strictEqual(secondMerge.fileGroups[0].items[0], h1);
    assert.strictEqual(secondMerge.fileGroups[0].items[1], h3);

    // CoW group collapse helpers preserve unaffected references
    const toggled = toggleGroupCollapseAt(secondMerge.fileGroups, 0);
    assert.equal(toggled[0].collapsed, true);
    assert.strictEqual(toggled[1], secondMerge.fileGroups[1]);
    assert.strictEqual(toggleGroupCollapseAt(toggled, 99), toggled);

    const collapsedAll = collapseAllGroups(toggled, true);
    assert.strictEqual(collapsedAll[0], toggled[0]); // already collapsed -> preserved
    assert.equal(collapsedAll[1].collapsed, true);
    assert.equal(collapsedAll[2].collapsed, true);
  });

  it('FileContextLruCache enforces 16-slot LRU eviction and sourceRevision validation', () => {
    assert.equal(MAX_FILE_CONTEXT_CACHE, 16);
    const cache = new FileContextLruCache();

    for (let i = 0; i < 16; i++) {
      cache.put(`k-${i}`, makeFileResponse(`f-${i}`, [10, 11]), 1);
    }
    assert.equal(cache.size, 16);

    // Promote k-0 to MRU via valid get; k-1 becomes LRU
    const hit0 = cache.get('k-0', 10, 1);
    assert.ok(hit0 !== null);

    // Line mismatch returns null without invalidating
    assert.equal(cache.get('k-2', 999, 1), null);

    // Adding 17th entry evicts k-1 (LRU), keeping k-0
    cache.put('k-16', makeFileResponse('f-16', [10]), 1);
    assert.equal(cache.size, 16);
    assert.equal(cache.get('k-1', 10, 1), null);
    assert.ok(cache.get('k-0', 10, 1) !== null);

    // Source revision mismatch invalidates and evicts the stale entry
    assert.equal(cache.get('k-0', 10, 2), null);
    assert.equal(cache.size, 15);
  });

  it('normalizes done telemetry, resolves byte hints, and merges incremental context batches', () => {
    const done = normalizeDoneTelemetry(
      {
        type: 'done',
        id: 1,
        elapsedMs: 12.5,
        filesSearched: 10,
        filesMatched: 2,
        totalMatches: 5,
        matchedLines: 5,
        bytesSearched: 4096,
        limitHit: 'none',
        filesPruned: 3.6,
        bytesSaved: 1024,
      },
      0
    );
    assert.equal(done.limitHit, false);
    assert.equal(done.filesPruned, 4);
    assert.equal(done.bytesSaved, 1024);
    assert.equal(done.cacheHit, 'none');

    const hit: HitItem = { ...makeHit('a.log', 50), byteOffset: 4200 };
    assert.equal(resolveAnchorByteHint(999.8, hit, 'a.log', 50), 999);
    assert.equal(resolveAnchorByteHint(undefined, hit, 'a.log', 50), 4200);
    assert.equal(resolveAnchorByteHint(undefined, hit, 'other.log', 50), undefined);

    assert.equal(
      buildFileContextCacheKey('default', 'docker/app', 12, 3, 1700),
      'default\u0000docker/app\u000012\u00003\u0000s=1700'
    );
    assert.equal(
      buildFileContextCacheKey('default', 'repo/src/main.zig', 42, null, null, 12),
      'default\u0000repo/src/main.zig\u000042\u0000c=12'
    );

    const existing = makeFileResponse('a.log', [10, 11, 12]).lines;
    const incoming: FileResponse = {
      path: 'a.log',
      startLine: 5,
      totalLines: 100,
      binary: false,
      eof: false,
      firstByte: 128,
      nextByte: 512,
      lines: [7, 8, 9, 10].map((n) => ({ n, text: `line ${n}` })),
    };
    const merged = mergeContextBatchResult(
      existing,
      100,
      false,
      incoming,
      { line: 8, context: 2, targetStart: 7, targetEnd: 9 },
      'before'
    );
    assert.deepEqual(
      merged.lines.map((l) => l.n),
      [7, 8, 9, 10, 11, 12]
    );
    assert.equal(merged.firstByte, 128);
    assert.equal(merged.nextByte, undefined);
  });
});

describe('state/query-actions', () => {
  const srcLogs = makeSource('s-logs', {
    name: 'AppLogs',
    pluginPreset: 'timeseries',
    config: { path: '/logs', timeFormat: '%Y-%m-%d %H:%M:%S' },
  });
  const srcCode = makeSource('s-code', {
    name: 'BackendCode',
    pluginPreset: 'code',
  });
  const srcDocker = makeSource('s-docker', {
    id: 's-docker',
    kind: 'docker',
    name: 'api-ctr',
    enabled: false,
  });
  const srcDup1 = makeSource('s-dup1', { name: 'DupName', enabled: false });
  const srcDup2 = makeSource('s-dup2', { name: 'DupName', enabled: false });
  const sources = [srcLogs, srcCode, srcDocker, srcDup1, srcDup2];

  it('resolves source IDs/names, portable refs, and scope normalization', () => {
    assert.equal(resolveSourceIdOrName(sources, 'applogs'), 's-logs');
    assert.equal(resolveSourceIdOrName(sources, 's-code'), 's-code');
    assert.equal(resolveSourceIdOrName(sources, 'unknown'), 'unknown');

    const byId = new Map(sources.map((s) => [s.id, s]));
    assert.deepEqual(toPortableSourceRefs(sources, byId, ['s-logs', 's-dup1']), [
      'AppLogs',
      's-dup1',
    ]);

    assert.equal(sameSourceList(['a', 'b'], ['b', 'a']), true);
    assert.equal(sameSourceList(['a', 'b'], ['a']), false);

    assert.deepEqual(normalizeScopeSourceLists(['a', 'a', 'b'], ['b', 'c', 'b']), {
      sources: ['a'],
      excludedSources: ['b', 'c'],
    });

    assert.deepEqual(computeEffectiveSourceIds(sources, []), ['s-logs', 's-code']);
    assert.deepEqual(computeEffectiveSourceIds(sources, ['s-docker']), ['s-docker']);

    const activeAll = computeActiveSources(sources, {
      sources: [],
      excludedSources: ['BackendCode'],
    });
    assert.deepEqual(
      activeAll.map((s) => s.id),
      ['s-logs']
    );

    assert.equal(isDockerVirtualPath(sources, 'API-CTR/stdout'), true);
    assert.equal(isDockerVirtualPath(sources, 'AppLogs/app.log'), false);
  });

  it('computes content-time vs mtime basis and source time format signatures', () => {
    assert.equal(isContentTimeSource(srcLogs), true);
    assert.equal(isContentTimeSource(srcCode), false);
    assert.equal(isContentTimeSource(srcDocker), true);

    assert.deepEqual(computeTimeBasisSummary([srcLogs, srcCode, srcDocker]), {
      contentCount: 2,
      mtimeCount: 1,
    });

    assert.equal(
      computeSourceTimeFormatsSig([srcLogs, srcCode, srcDocker]),
      's-docker=auto|s-logs=%Y-%m-%d %H:%M:%S'
    );
  });

  it('handles step exclusion rules, editing back to draft, and appending steps', () => {
    const pos = createQueryStep('error');
    const neg = createQueryStep('health', { exclude: true });

    // Only one positive step without timePreset cannot flip to exclude
    assert.equal(canToggleStepExcludeAt([pos], 0, null, ''), false);
    // Flipping exclude -> include is always allowed
    assert.equal(canToggleStepExcludeAt([pos, neg], 1, null, ''), true);
    // With timePreset active, sole positive step can flip to exclude
    assert.equal(canToggleStepExcludeAt([pos], 0, null, '15m'), true);

    // Editing a step preserves current draft in steps
    const edited = buildEditedStepState([pos, neg], 1, createQueryStep('timeout'), '');
    assert.ok(edited !== null);
    assert.equal(edited.pattern, 'health');
    assert.equal(edited.draftExclude, true);
    assert.deepEqual(
      edited.steps.map((s) => s.text),
      ['error', 'timeout']
    );

    // Appending excluded term without positive step/time falls back to positive
    const appendedNoAnchor = buildAppendedStepList([], null, 'noise', {
      exclude: true,
      timePreset: '',
    });
    assert.deepEqual(appendedNoAnchor?.map((s) => [s.text, s.exclude]), [['noise', false]]);

    const appendedWithAnchor = buildAppendedStepList([pos], createQueryStep('db'), 'noise', {
      exclude: true,
      timePreset: '',
    });
    assert.deepEqual(
      appendedWithAnchor?.map((s) => [s.text, s.exclude]),
      [
        ['error', false],
        ['db', false],
        ['noise', true],
      ]
    );
  });

  it('builds executable search plans and deterministic share URLs', () => {
    const scope: ScopeFilter = {
      sources: ['s-logs'],
      excludedSources: [],
      types: [],
      timePreset: '15m',
    };
    const emptyPlan = buildSearchRequestPlan({
      steps: [],
      draftStep: null,
      scope: { sources: [], excludedSources: [], types: [], timePreset: '' },
      sources,
      tenant: 'default',
      mode: 'literal',
      hidden: false,
      respectIgnore: false,
      maxResults: 1000,
    });
    assert.equal(emptyPlan, null);

    const plan = buildSearchRequestPlan({
      steps: [createQueryStep('timeout', { caseSensitive: true })],
      draftStep: createQueryStep('retry'),
      scope,
      sources,
      tenant: 'ops',
      mode: 'literal',
      hidden: false,
      respectIgnore: true,
      maxResults: 5000,
      nowMs: 1_730_340_900_000,
      tzOffsetMin: 480,
    });
    assert.ok(plan !== null);
    const payload = plan.buildWsPayload(42);
    assert.equal(payload.id, 42);
    assert.equal(payload.tenant, 'ops');
    assert.equal(payload.pattern, '$c(timeout)');
    assert.deepEqual(payload.contains, ['retry']);
    assert.deepEqual(payload.sources, ['s-logs']);

    const byId = new Map(sources.map((s) => [s.id, s]));
    const shareUrl = buildWorkbenchShareUrl({
      baseHref: 'http://127.0.0.1:8787/',
      hasSearchedOnce: true,
      lastExecutedSnapshot: plan.snapshot,
      steps: [],
      draftStep: null,
      scope,
      displayedTimeStartMs: plan.timeStartMs,
      hidden: false,
      respectIgnore: true,
      maxResults: 5000,
      inspectedHit: { ...makeHit('/logs/app.log', 88), byteOffset: 2048 },
      activeHit: null,
      inspectedPath: '/logs/app.log',
      inspectedLine: 88,
      flatHits: [],
      sources,
      sourceById: byId,
      contextPrettyMode: false,
      inspectorRaw: false,
      openContext: true,
      mtimeCount: 0,
    });
    assert.ok(shareUrl.includes('?share='));
  });
});

describe('state/api-client & state/ws-transport', () => {
  it('routes auth, upsert errors, time preview, and Docker file window requests cleanly', async () => {
    const authRes = await fetchAuthStatus(
      async () =>
        new Response(JSON.stringify({ authRequired: true, authenticated: false }), { status: 200 })
    );
    assert.equal(authRes?.authRequired, true);

    const badLogin = await postAuthLogin(async () => new Response('{}', { status: 401 }), 'wrong');
    assert.deepEqual(badLogin, { ok: false, invalidPassword: true });

    await assert.rejects(
      () =>
        postUpsertSource(
          async () => new Response(JSON.stringify({ error: 'Invalid path' }), { status: 400 }),
          { name: 'bad', path: '/nope' }
        ),
      /Invalid path/
    );

    const previewErr = await postTimePreview(
      async () => new Response(JSON.stringify({ errorMessage: 'Bad mask' }), { status: 400 }),
      '%Q',
      '2026-01-01',
      0
    );
    assert.equal(previewErr.validFormat, false);
    assert.equal(previewErr.errorMessage, 'Bad mask');

    let requestedUrl = '';
    const dockerSrc = makeSource('dk', { kind: 'docker', name: 'web-api' });
    assert.equal(computeDockerPreviewSinceSec([dockerSrc], 'web-api/stdout', 1_700_000_000_000), 1_699_999_998);

    const fileRes = await requestFileWindow(
      async (input) => {
        requestedUrl = String(input);
        return new Response(JSON.stringify(makeFileResponse('web-api/stdout', [10])), { status: 200 });
      },
      {
        tenant: 'default',
        sources: [dockerSrc],
        displayedTimeStartMs: 1_700_000_000_000,
        filePath: 'web-api/stdout',
        line: 10,
        context: 0,
        anchorByte: 512.9,
      }
    );
    assert.equal(fileRes.path, 'web-api/stdout');
    assert.ok(requestedUrl.includes('anchorByte=512'));
    assert.ok(requestedUrl.includes('since=1699999998'));
  });

  it('SearchWsTransport fast-filters stale search IDs and handles mcp_state pushes', () => {
    assert.equal(WS_DEGRADED_GRACE_MS, 650);
    const mcpStates: McpStateResponse[] = [];
    const searchMsgs: WsIncomingMessage[] = [];
    let currentSearchId = 7;

    const transport = new SearchWsTransport({
      canConnect: () => true,
      shouldReconnect: () => false,
      shouldVerifySessionOnDisconnect: () => false,
      getCurrentSearchId: () => currentSearchId,
      onStatusChange: () => {},
      onDegradedChange: () => {},
      onOpen: () => {},
      onMcpStatePush: (s) => mcpStates.push(s),
      onSearchMessage: (m) => searchMsgs.push(m),
      onVerifySessionOnDisconnect: () => {},
      onDisconnectSearchReset: () => {},
    });

    transport.handleRawMessage(
      JSON.stringify({
        type: 'mcp_state',
        state: {
          enabled: true,
          maxLogs: 20,
          endpointPath: '/mcp',
          protocolVersion: '2025-03-26',
          stats: { totalCalls: 1, errorCalls: 0, lastCallMs: 5 },
          capabilities: [],
          logs: [],
        },
      })
    );
    assert.equal(mcpStates.length, 1);

    // Stale search ID within first 48 bytes is dropped before JSON.parse
    transport.handleRawMessage('{"type":"hits","id":6,"items":[]}');
    assert.equal(searchMsgs.length, 0);

    // Matching search ID passes through
    transport.handleRawMessage('{"type":"done","id":7,"elapsedMs":1,"filesSearched":1,"filesMatched":0,"totalMatches":0,"matchedLines":0,"bytesSearched":10,"limitHit":"none"}');
    assert.equal(searchMsgs.length, 1);
    assert.equal(searchMsgs[0].type, 'done');

    currentSearchId = 8;
    transport.handleRawMessage('{"type":"hits","id":7,"items":[]}');
    assert.equal(searchMsgs.length, 1);
  });
});
