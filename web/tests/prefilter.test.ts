import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_PLUGIN_CATALOG,
  DEFAULT_PLUGIN_PRESET,
  DEFAULT_PRESET_CATALOG,
  PLUGIN_DOMAINS,
  PLUGIN_PRESETS,
  computeEnabledSourcesSyncSig,
  computeSourcePluginsSig,
  formatPrunedTelemetry,
  groupPluginsForPreset,
  hasPluginOverrides,
  isPluginApplicableToPreset,
  isPluginEffectiveEnabled,
  normalizeMetaPrefilterCatalog,
  normalizePluginDomain,
  normalizePluginOverrides,
  normalizePluginPreset,
  resolveSourcePluginOverrides,
  resolveSourcePluginPreset,
  sanitizePluginOverridesForPreset,
  togglePluginOverride,
} from '../src/lib/prefilter.ts';
import { L0StepCache } from '../src/lib/l0-cache.ts';
import { buildQueryCacheKeys, createQueryStep } from '../src/lib/query.ts';
import { messages } from '../src/lib/i18n.ts';
import type { DataSourceItem } from '../src/lib/types.ts';

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

describe('Prefilter plugin catalog, presets, overrides, cache keys & telemetry', () => {
  it('normalizes plugin presets strictly to timeseries (log) or code with safe timeseries fallback', () => {
    assert.deepEqual([...PLUGIN_PRESETS], ['timeseries', 'code']);
    assert.equal(DEFAULT_PLUGIN_PRESET, 'timeseries');

    assert.equal(normalizePluginPreset(undefined), 'timeseries');
    assert.equal(normalizePluginPreset(null), 'timeseries');
    assert.equal(normalizePluginPreset(''), 'timeseries');
    assert.equal(normalizePluginPreset('  TIMESERIES  '), 'timeseries');
    assert.equal(normalizePluginPreset('log'), 'timeseries');
    assert.equal(normalizePluginPreset('Code'), 'code');
    // Legacy auto/raw presets migrate cleanly to timeseries
    assert.equal(normalizePluginPreset('auto'), 'timeseries');
    assert.equal(normalizePluginPreset('raw'), 'timeseries');
    assert.equal(normalizePluginPreset('unknown_mode'), 'timeseries');
    assert.equal(normalizePluginPreset('unknown_mode', 'code'), 'code');
  });

  it('parses /api/meta plugins & presets backward-compatibly with safe defaults', () => {
    const legacy = normalizeMetaPrefilterCatalog(undefined);
    assert.deepEqual(
      legacy.presets.map((p) => p.id),
      DEFAULT_PRESET_CATALOG.map((p) => p.id)
    );
    assert.deepEqual(
      legacy.plugins.map((p) => p.id),
      DEFAULT_PLUGIN_CATALOG.map((p) => p.id)
    );

    const partial = normalizeMetaPrefilterCatalog({ presets: [], plugins: [] });
    assert.equal(partial.presets.length, 2);
    assert.equal(partial.plugins.length, DEFAULT_PLUGIN_CATALOG.length);

    const serverMeta = normalizeMetaPrefilterCatalog({
      presets: [
        { id: 'timeseries', name_key: 'preset.ts', description: 'Time-series preset' },
        'code',
        'auto',
        'raw',
        'invalid_ignored',
      ],
      plugins: [
        {
          id: 'filename_date',
          domain: 'log',
          name_key: 'plugin.filename_date',
          stages: ['file_prune'],
          default_presets: ['timeseries'],
          cost_hint: 'o1',
        },
        {
          id: 'custom_bloom',
          domain: 'common',
          description: 'Custom server-supplied prefilter',
          stages: ['file_prune', 'window_narrow'],
          defaultPresets: ['timeseries'],
          costHint: 'o1',
        },
      ],
    });
    assert.deepEqual(
      serverMeta.presets.map((p) => p.id),
      ['timeseries', 'code']
    );
    assert.equal(serverMeta.presets[0].nameKey, 'preset.ts');
    assert.equal(serverMeta.presets[0].description, 'Time-series preset');
    assert.equal(serverMeta.plugins.length, 2);
    assert.equal(serverMeta.plugins[0].domain, 'log');
    assert.deepEqual(serverMeta.plugins[0].defaultPresets, ['timeseries']);
    assert.equal(serverMeta.plugins[1].id, 'custom_bloom');
    assert.equal(serverMeta.plugins[1].domain, 'common');
    assert.deepEqual(serverMeta.plugins[1].stages, ['file_prune', 'window_narrow']);
    assert.deepEqual(serverMeta.plugins[1].defaultPresets, ['timeseries']);
  });

  it('partitions plugins strictly by domain across log (timeseries) vs code presets', () => {
    assert.deepEqual([...PLUGIN_DOMAINS], ['common', 'log', 'code']);
    assert.equal(normalizePluginDomain('LOG'), 'log');
    assert.equal(normalizePluginDomain('code'), 'code');
    assert.equal(normalizePluginDomain('unknown', 'common'), 'common');

    // Code preset: strictly code + common plugins (no log timestamp plugins)
    const codeGroups = groupPluginsForPreset(DEFAULT_PLUGIN_CATALOG, 'code');
    assert.deepEqual(
      codeGroups.map((g) => g.domain),
      ['code', 'common']
    );
    assert.deepEqual(
      codeGroups[0].plugins.map((p) => p.id),
      ['mtime_window']
    );
    assert.deepEqual(
      codeGroups[1].plugins.map((p) => p.id),
      ['path_scope', 'mtime_guard', 'sidecar_sketch']
    );

    // Timeseries (log) preset: strictly log + common plugins (no code mtime_window)
    const logGroups = groupPluginsForPreset(DEFAULT_PLUGIN_CATALOG, 'timeseries');
    assert.deepEqual(
      logGroups.map((g) => g.domain),
      ['log', 'common']
    );
    assert.deepEqual(
      logGroups[0].plugins.map((p) => p.id),
      ['filename_date', 'time_bisect', 'line_time']
    );

    // Applicability checks & override sanitization prevent stale cross-domain overrides
    const timeBisect = DEFAULT_PLUGIN_CATALOG.find((p) => p.id === 'time_bisect')!;
    const mtimeWindow = DEFAULT_PLUGIN_CATALOG.find((p) => p.id === 'mtime_window')!;
    assert.equal(isPluginApplicableToPreset(timeBisect, 'code'), false);
    assert.equal(isPluginApplicableToPreset(mtimeWindow, 'timeseries'), false);

    assert.deepEqual(
      sanitizePluginOverridesForPreset(DEFAULT_PLUGIN_CATALOG, 'code', {
        enable: ['time_bisect', 'path_scope'],
        disable: ['filename_date', 'mtime_window'],
      }),
      { enable: ['path_scope'], disable: ['mtime_window'] }
    );
  });

  it('normalizes plugin overrides conservatively and toggles cleanly around preset defaults', () => {
    assert.deepEqual(normalizePluginOverrides(undefined), { enable: [], disable: [] });
    assert.deepEqual(normalizePluginOverrides(null), { enable: [], disable: [] });

    // Trims, deduplicates, sorts, and resolves conflicts conservatively (`disable` wins)
    const normalized = normalizePluginOverrides({
      enable: [' time_bisect ', 'filename_date', 'time_bisect', ''],
      disable: ['filename_date', ' mtime_window '],
    });
    assert.deepEqual(normalized, {
      enable: ['time_bisect'],
      disable: ['filename_date', 'mtime_window'],
    });
    assert.equal(hasPluginOverrides(normalized), true);
    assert.equal(hasPluginOverrides({ enable: [], disable: [] }), false);

    const mtimeWindow = DEFAULT_PLUGIN_CATALOG.find((p) => p.id === 'mtime_window')!;
    const timeBisect = DEFAULT_PLUGIN_CATALOG.find((p) => p.id === 'time_bisect')!;
    assert.equal(isPluginEffectiveEnabled(mtimeWindow, 'timeseries', { enable: [], disable: [] }), false);
    assert.equal(isPluginEffectiveEnabled(mtimeWindow, 'code', { enable: [], disable: [] }), true);
    assert.equal(isPluginEffectiveEnabled(timeBisect, 'timeseries', { enable: [], disable: [] }), true);
    assert.equal(isPluginEffectiveEnabled(timeBisect, 'code', { enable: [], disable: [] }), false);

    // Disabling time_bisect on `timeseries` records it in `disable`
    const offInLogs = togglePluginOverride(timeBisect, 'timeseries', { enable: [], disable: [] }, false);
    assert.deepEqual(offInLogs, { enable: [], disable: ['time_bisect'] });
    assert.equal(isPluginEffectiveEnabled(timeBisect, 'timeseries', offInLogs), false);

    // Turning it back on matches `timeseries` default and removes the override entry cleanly
    const backOnInLogs = togglePluginOverride(timeBisect, 'timeseries', offInLogs, true);
    assert.deepEqual(backOnInLogs, { enable: [], disable: [] });

    // Disabling mtime_window on `code` (on by default) puts it in `disable`
    const offInCode = togglePluginOverride(mtimeWindow, 'code', { enable: [], disable: [] }, false);
    assert.deepEqual(offInCode, { enable: [], disable: ['mtime_window'] });
    assert.equal(isPluginEffectiveEnabled(mtimeWindow, 'code', offInCode), false);

    // Also verifies `id_str` backend struct serialization compatibility
    const withIdStr = normalizeMetaPrefilterCatalog({
      presets: [{ id_str: 'timeseries', name_key: 'presets.timeseries' }, { id_str: 'code', name_key: 'presets.code' }],
      plugins: [{ id_str: 'time_bisect', name_key: 'plugins.time_bisect', stages: ['window_narrow'], default_presets: ['timeseries'], cost_hint: 'O(log N) pread' }],
    });
    assert.deepEqual(withIdStr.presets.map((p) => p.id), ['timeseries', 'code']);
    assert.equal(withIdStr.plugins[0].id, 'time_bisect');
    assert.equal(withIdStr.plugins[0].costHint, 'O(log N) pread');
  });

  it('resolves top-level and config-nested source presets and overrides cleanly', () => {
    const legacySource = makeSource('s-legacy');
    assert.equal(resolveSourcePluginPreset(legacySource), 'timeseries');
    assert.deepEqual(resolveSourcePluginOverrides(legacySource), { enable: [], disable: [] });

    const topLevelSource = makeSource('s-top', {
      pluginPreset: 'timeseries',
      plugins: { enable: ['mtime_window'], disable: ['sidecar_sketch'] },
    });
    assert.equal(resolveSourcePluginPreset(topLevelSource), 'timeseries');
    assert.deepEqual(resolveSourcePluginOverrides(topLevelSource), {
      enable: ['mtime_window'],
      disable: ['sidecar_sketch'],
    });

    const configNestedSource = makeSource('s-cfg', {
      config: {
        path: '/var/log/app',
        pluginPreset: 'code',
        plugins: { disable: ['mtime_guard'] },
      },
    });
    assert.equal(resolveSourcePluginPreset(configNestedSource), 'code');
    assert.deepEqual(resolveSourcePluginOverrides(configNestedSource), {
      enable: [],
      disable: ['mtime_guard'],
    });
  });

  it('computes deterministic sourcePluginsSig and isolates L0 cache keys on preset/plugin changes', () => {
    const s1Logs = makeSource('s1', { pluginPreset: 'timeseries' });
    const s1Code = makeSource('s1', { pluginPreset: 'code' });
    const s1CustomA = makeSource('s1', {
      pluginPreset: 'timeseries',
      plugins: { enable: ['b', 'a'], disable: ['c'] },
    });
    const s1CustomB = makeSource('s1', {
      pluginPreset: 'timeseries',
      plugins: { enable: ['a', 'b'], disable: ['c'] },
    });
    const s2 = makeSource('s2', { pluginPreset: 'timeseries' });

    const sigLogs = computeSourcePluginsSig([s1Logs, s2]);
    const sigLogsReordered = computeSourcePluginsSig([s2, s1Logs]);
    const sigCode = computeSourcePluginsSig([s1Code, s2]);
    const sigCustomA = computeSourcePluginsSig([s1CustomA, s2]);
    const sigCustomB = computeSourcePluginsSig([s1CustomB, s2]);

    assert.equal(sigLogs, sigLogsReordered);
    assert.notEqual(sigLogs, sigCode);
    assert.notEqual(sigLogs, sigCustomA);
    assert.equal(sigCustomA, sigCustomB);

    const fixedNow = new Date(2026, 10, 17, 12, 0, 0).getTime();
    const baseParams = {
      tenant: 'default',
      effectiveSources: ['s1', 's2'],
      excludedSources: [],
      types: [],
      timePreset: '1h' as const,
      timeMode: 'source' as const,
      tzOffsetMin: 480,
      sourceTimeFormatsSig: 's1=auto',
      steps: [createQueryStep('timeout')],
      contextLines: 0,
      hidden: false,
      respectIgnore: false,
      maxResults: 20000,
      nowMs: fixedNow,
    };

    const kLogs = buildQueryCacheKeys({ ...baseParams, sourcePluginsSig: sigLogs });
    const kCode = buildQueryCacheKeys({ ...baseParams, sourcePluginsSig: sigCode });
    const kCustom = buildQueryCacheKeys({ ...baseParams, sourcePluginsSig: sigCustomA });

    assert.notEqual(kLogs.baseKey, kCode.baseKey);
    assert.notEqual(kLogs.exactKey, kCode.exactKey);
    assert.notEqual(kLogs.baseKey, kCustom.baseKey);
    assert.notEqual(kLogs.exactKey, kCustom.exactKey);
    assert.equal(kLogs.historyId, kCode.historyId);
  });

  it('invalidates L0StepCache on preset switch and preserves pruning telemetry across L0 hits', () => {
    const fixedNow = 1794880800000;
    const l0 = new L0StepCache();
    const initialSources = [makeSource('logs', { pluginPreset: 'timeseries' })];
    const initialSyncSig = computeEnabledSourcesSyncSig(initialSources);

    const keysLogs = buildQueryCacheKeys({
      tenant: 'default',
      effectiveSources: ['logs'],
      excludedSources: [],
      types: [],
      timePreset: '24h',
      sourcePluginsSig: computeSourcePluginsSig(initialSources),
      steps: [createQueryStep('error')],
      hidden: false,
      respectIgnore: false,
      maxResults: 20000,
      nowMs: fixedNow,
    });

    l0.put(
      {
        exactKey: keysLogs.exactKey,
        baseKey: keysLogs.baseKey,
        sourceRevision: l0.sourceRevision,
        hadDraft: true,
        maxResults: 20000,
        timeStartMs: fixedNow - 86_400_000,
      },
      {
        fileGroups: [],
        flatHits: [],
        filesSearched: 12,
        filesMatched: 3,
        totalMatches: 42,
        matchedLines: 42,
        bytesSearched: 1024 * 1024,
        filesPruned: 19,
        bytesSaved: 64 * 1024 * 1024,
        limitHit: false,
      },
      fixedNow
    );

    const hit = l0.findValid(keysLogs.exactKey, keysLogs.baseKey, 20000, fixedNow + 500);
    assert.ok(hit !== null);
    assert.equal(hit.filesPruned, 19);
    assert.equal(hit.bytesSaved, 64 * 1024 * 1024);

    // Switching source preset from `timeseries` to `code` both misses via `sourcePluginsSig`
    // AND invalidates `L0StepCache` via `computeEnabledSourcesSyncSig`.
    const switchedSources = [makeSource('logs', { pluginPreset: 'code' })];
    const switchedSyncSig = computeEnabledSourcesSyncSig(switchedSources);
    assert.notEqual(switchedSyncSig, initialSyncSig);

    const keysCode = buildQueryCacheKeys({
      tenant: 'default',
      effectiveSources: ['logs'],
      excludedSources: [],
      types: [],
      timePreset: '24h',
      sourcePluginsSig: computeSourcePluginsSig(switchedSources),
      steps: [createQueryStep('error')],
      hidden: false,
      respectIgnore: false,
      maxResults: 20000,
      nowMs: fixedNow,
    });
    assert.equal(l0.findValid(keysCode.exactKey, keysCode.baseKey, 20000, fixedNow + 500), null);

    // Server-side source sync invalidation clears all prior L0 entries including old `keysLogs`
    l0.invalidate();
    assert.equal(l0.sourceRevision, 2);
    assert.equal(l0.findValid(keysLogs.exactKey, keysLogs.baseKey, 20000, fixedNow + 500), null);
  });

  it('formats done frame pruning telemetry and zh/en tooltips cleanly', () => {
    assert.deepEqual(formatPrunedTelemetry(0, 0), {
      visible: false,
      filesPruned: 0,
      bytesSaved: 0,
      compactText: '',
      filesText: '',
      savedText: '',
    });
    assert.equal(formatPrunedTelemetry(-3, 5000).visible, false);
    assert.equal(formatPrunedTelemetry(Number.NaN, 5000).visible, false);

    const filesOnly = formatPrunedTelemetry(12, 0);
    assert.equal(filesOnly.visible, true);
    assert.equal(filesOnly.compactText, '-12');
    assert.equal(filesOnly.savedText, '');
    assert.equal(
      messages.zh.telemetry.prunedTooltipFilesOnly(filesOnly.filesText),
      '预过滤剪枝跳过 12 个文件'
    );
    assert.equal(
      messages.en.telemetry.prunedTooltipFilesOnly(filesOnly.filesText),
      'Prefilter pruned 12 file(s)'
    );

    const withBytes = formatPrunedTelemetry(128, 44_354_764);
    assert.equal(withBytes.visible, true);
    assert.equal(withBytes.compactText, '-128 · 42.30 MB');
    assert.equal(withBytes.savedText, '42.30 MB');
    assert.equal(
      messages.zh.telemetry.prunedTooltipWithBytes(withBytes.filesText, withBytes.savedText),
      '预过滤剪枝跳过 128 个文件，免扫描 42.30 MB'
    );
    assert.equal(
      messages.en.telemetry.prunedTooltipWithBytes(withBytes.filesText, withBytes.savedText),
      'Prefilter pruned 128 file(s), saving 42.30 MB'
    );
  });
});
