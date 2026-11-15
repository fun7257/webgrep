import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  applySingleSourceSelection,
  countSourcesByKind,
  filterSourcesForPicker,
  fuzzyFilterSourcesForPicker,
  fuzzyMatchText,
  isSourceRefInList,
  mergeHighlightRanges,
  normalizeSourceKind,
  resolveScopeSourceSummary,
  splitHighlightRanges,
  toggleExcludeSourceSelection,
  toggleMultiSourceSelection,
} from '../src/lib/source-picker.ts';
import type { DataSourceItem } from '../src/lib/types.ts';

function makeSource(
  id: string,
  name: string,
  kind: DataSourceItem['kind'] = 'dir',
  enabled = true,
  path = `/data/${name}`,
  endpoint: string | null = null
): DataSourceItem {
  return {
    id,
    kind,
    name,
    enabled,
    ready: true,
    summary: endpoint ? `${endpoint} (${name})` : path,
    config: { path, endpoint },
    path,
    exists: true,
  };
}

describe('Source picker pure logic', () => {
  it('single-click pill switches straight to target and toggles back to all when clicked twice', () => {
    const s1 = applySingleSourceSelection({ sources: [], excludedSources: [] }, 'src-a');
    assert.deepEqual(s1, { sources: ['src-a'], excludedSources: [] });

    // Switching from A -> B goes directly to [B], never [A, B]
    const s2 = applySingleSourceSelection(s1, 'src-b');
    assert.deepEqual(s2, { sources: ['src-b'], excludedSources: [] });

    // Clicking sole active B again clears back to All ([])
    const s3 = applySingleSourceSelection(s2, 'src-b');
    assert.deepEqual(s3, { sources: [], excludedSources: [] });

    // Single-clicking while multi-select or exclusions exist collapses cleanly to just [src-a]
    const s4 = applySingleSourceSelection(
      { sources: ['src-a', 'src-b'], excludedSources: ['src-c'] },
      'src-a'
    );
    assert.deepEqual(s4, { sources: ['src-a'], excludedSources: [] });
  });

  it('multi-select and exclude toggles remain mutually exclusive', () => {
    const m1 = toggleMultiSourceSelection({ sources: ['a'], excludedSources: ['b'] }, 'b');
    assert.deepEqual(m1, { sources: ['a', 'b'], excludedSources: [] });

    const m2 = toggleMultiSourceSelection(m1, 'a');
    assert.deepEqual(m2, { sources: ['b'], excludedSources: [] });

    const ex1 = toggleExcludeSourceSelection(m2, 'b');
    assert.deepEqual(ex1, { sources: [], excludedSources: ['b'] });

    const ex2 = toggleExcludeSourceSelection(ex1, 'b');
    assert.deepEqual(ex2, { sources: [], excludedSources: [] });
  });

  it('resolveScopeSourceSummary handles all, single, multi, excluded, and mixed states', () => {
    const sources: DataSourceItem[] = [
      makeSource('1', 'app-a', 'dir', true),
      makeSource('2', '1000w.log', 'file', true),
      makeSource('3', 'docker', 'docker', true),
    ];

    assert.deepEqual(resolveScopeSourceSummary(sources, [], []), {
      mode: 'all',
      singleSource: null,
      selectedCount: 0,
      excludedCount: 0,
    });

    const single = resolveScopeSourceSummary(sources, ['3'], []);
    assert.equal(single.mode, 'single');
    assert.equal(single.singleSource?.id, '3');
    assert.equal(single.selectedCount, 1);
    assert.equal(single.excludedCount, 0);

    const singleByName = resolveScopeSourceSummary(sources, ['APP-A'], []);
    assert.equal(singleByName.mode, 'single');
    assert.equal(singleByName.singleSource?.id, '1');

    const singleMissing = resolveScopeSourceSummary(sources, ['deleted-id'], []);
    assert.equal(singleMissing.mode, 'single');
    assert.equal(singleMissing.singleSource, null);

    assert.deepEqual(resolveScopeSourceSummary(sources, ['1', '2'], []), {
      mode: 'multi',
      singleSource: null,
      selectedCount: 2,
      excludedCount: 0,
    });

    assert.deepEqual(resolveScopeSourceSummary(sources, [], ['3']), {
      mode: 'excluded',
      singleSource: null,
      selectedCount: 0,
      excludedCount: 1,
    });

    assert.deepEqual(resolveScopeSourceSummary(sources, ['1'], ['3']), {
      mode: 'mixed',
      singleSource: null,
      selectedCount: 1,
      excludedCount: 1,
    });
  });

  it('counts and filters sources by kind, search query, name/path/endpoint, with enabled first', () => {
    const sources: DataSourceItem[] = [
      makeSource('1', 'disabled-api', 'dir', false, '/srv/disabled-api'),
      makeSource('2', 'webgrep', 'dir', true, '/Users/fun/code/webgrep'),
      makeSource('3', '1000w.log', 'file', true, '/var/log/1000w.log'),
      makeSource('4', 'nginx-ctr', 'docker', true, 'unix:///var/run/docker.sock::nginx', 'auto::nginx'),
    ];

    assert.equal(normalizeSourceKind('custom'), 'dir');
    assert.deepEqual(countSourcesByKind(sources), { all: 4, dir: 2, file: 1, docker: 1 });

    // Enabled sources come first while disabled goes after
    const allFiltered = filterSourcesForPicker(sources, 'all', '');
    assert.deepEqual(
      allFiltered.map((x) => x.id),
      ['2', '3', '4', '1']
    );

    // Kind + query matching summary/endpoint/path
    assert.deepEqual(
      filterSourcesForPicker(sources, 'docker', 'NGINX').map((x) => x.id),
      ['4']
    );
    assert.deepEqual(
      filterSourcesForPicker(sources, 'file', '/var/log').map((x) => x.id),
      ['3']
    );
    assert.deepEqual(
      filterSourcesForPicker(sources, 'dir', 'disabled').map((x) => x.id),
      ['1']
    );
    assert.equal(isSourceRefInList(sources[1], ['WEBGREP']), true);
  });

  it('fuzzyFilterSourcesForPicker supports subsequence matching, word-boundary DP, multi-token queries, and highlights', () => {
    const sources: DataSourceItem[] = [
      makeSource('1', 'Sample Logs', 'dir', true, '/var/log/sample-logs'),
      makeSource('2', 'webgrep', 'dir', true, '/Users/fun/code/webgrep'),
      makeSource('3', 'nginx-ctr', 'docker', true, 'unix:///var/run/docker.sock::nginx', 'auto::nginx-ctr'),
      makeSource('4', 'app-router', 'dir', true, '/var/log/app.log'),
      makeSource('5', 'disabled-web', 'dir', false, '/tmp/disabled-web'),
    ];

    // Subsequence matching
    assert.deepEqual(
      fuzzyFilterSourcesForPicker(sources, 'all', 'wgp').map((r) => r.source.id),
      ['2']
    );
    assert.deepEqual(
      fuzzyFilterSourcesForPicker(sources, 'all', 'slog').map((r) => r.source.id),
      ['1']
    );
    assert.deepEqual(
      fuzzyFilterSourcesForPicker(sources, 'all', 'ngctr').map((r) => r.source.id),
      ['3']
    );

    // Non-matching query returns empty
    assert.deepEqual(fuzzyFilterSourcesForPicker(sources, 'all', 'zzz'), []);

    // Word-boundary highlight preference: '/var/log/app.log' searching 'al' highlights 'a' at 9 and 'l' at 13
    const boundaryHit = fuzzyMatchText('/var/log/app.log', 'al');
    assert.ok(boundaryHit);
    assert.deepEqual(boundaryHit.ranges, [
      { start: 9, end: 10 },
      { start: 13, end: 14 },
    ]);

    // Prefix name match outranks deeper path subsequence match (enabled still stays ahead of disabled)
    const ranked = fuzzyFilterSourcesForPicker(
      [
        makeSource('path-hit', 'other-service', 'dir', true, '/srv/w_e_b/x'),
        makeSource('name-prefix', 'webgrep', 'dir', true, '/Users/fun/webgrep'),
        makeSource('disabled-prefix', 'web-dis', 'dir', false, '/tmp/web-dis'),
      ],
      'all',
      'web'
    );
    assert.deepEqual(
      ranked.map((r) => r.source.id),
      ['name-prefix', 'path-hit', 'disabled-prefix']
    );

    // Whitespace-separated multi-token query matches across name and endpoint/summary/path
    const multiTok = fuzzyFilterSourcesForPicker(sources, 'all', 'auto ngc');
    assert.deepEqual(
      multiTok.map((r) => r.source.id),
      ['3']
    );

    // Highlight range merging & segment splitting
    assert.deepEqual(
      mergeHighlightRanges([
        { start: 3, end: 5 },
        { start: 0, end: 2 },
        { start: 2, end: 4 },
      ]),
      [{ start: 0, end: 5 }]
    );
    assert.deepEqual(
      splitHighlightRanges('webgrep', [
        { start: 0, end: 1 },
        { start: 3, end: 4 },
        { start: 6, end: 7 },
      ]),
      [
        { text: 'w', match: true },
        { text: 'eb', match: false },
        { text: 'g', match: true },
        { text: 're', match: false },
        { text: 'p', match: true },
      ]
    );
  });
});
