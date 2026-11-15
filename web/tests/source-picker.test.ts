import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  applySingleSourceSelection,
  countSourcesByKind,
  filterSourcesForPicker,
  isSourceRefInList,
  normalizeSourceKind,
  resolveScopeSourceSummary,
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
});
