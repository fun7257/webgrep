import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildVocabulary,
  computeWordCompletion,
  detectRegexLookTip,
  ghostSuffix,
  historyGhost,
  zeroResultFixes,
} from '../src/lib/suggest.ts';
import { createQueryStep } from '../src/lib/query.ts';
import type { ScopeFilter, SearchHistoryEntry } from '../src/lib/types.ts';

describe('Word completion & History ghost', () => {
  it('completes words from loaded result lines', () => {
    const vocab = buildVocabulary([
      'pub fn searchArchiveSlice() void {}',
      'pub fn searchArchive() void {}',
      'searchArchiveSlice();',
    ]);
    const res = computeWordCompletion(
      'searchAr',
      8,
      vocab,
      (n) => `${n}x`,
      'word'
    );
    assert.ok(res.items.length >= 2);
    assert.equal(res.items[0].label, 'searchArchiveSlice');
    assert.equal(res.items[0].hint, '2x');
    assert.equal(ghostSuffix(res.items[0].insert, 'searchAr'), 'chiveSlice');
  });

  it('historyGhost matches only clean positive non-regex single-step history', () => {
    const scope: ScopeFilter = { sources: [], excludedSources: [], types: [], timePreset: '' };
    const entries: SearchHistoryEntry[] = [
      {
        id: '1',
        steps: [createQueryStep('error')],
        draft: createQueryStep('timeout'),
        scope,
        label: 'error → timeout',
        timestamp: 100,
      },
      {
        id: '2',
        steps: [],
        draft: createQueryStep('foo\\d+', { isRegex: true }),
        scope,
        label: 'foo\\d+',
        timestamp: 200,
      },
      {
        id: '3',
        steps: [],
        draft: createQueryStep('upstream_timeout'),
        scope,
        label: 'upstream_timeout',
        timestamp: 300,
      },
    ];

    assert.equal(historyGhost('upst', entries), 'ream_timeout');
    assert.equal(historyGhost('err', entries), '');
    assert.equal(historyGhost('foo', entries), '');
  });
});

describe('Regex look-alike tip & zero-result fixes', () => {
  it('flags regex metacharacters when isRegex is false', () => {
    const tip = detectRegexLookTip('err_\\d+', false, (t) => `looks regex: ${t}`);
    assert.deepEqual(tip, { text: 'looks regex: err_\\d+' });
    assert.equal(detectRegexLookTip('err_\\d+', true, (t) => t), null);
    assert.equal(detectRegexLookTip('hello world', false, (t) => t), null);
  });

  it('proposes relaxing Aa, ab, trailing step, and scope filters on zero results', () => {
    const steps = [
      createQueryStep('Error', { caseSensitive: true }),
      createQueryStep('timeout', { wholeWord: true }),
    ];
    const draft = createQueryStep('health', { exclude: true });
    const scope: ScopeFilter = {
      sources: ['s1'],
      excludedSources: [],
      types: ['log'],
      timePreset: '15m',
    };
    const fixes = zeroResultFixes(steps, draft, scope, {
      fixRemoveStep: (label) => `rm ${label}`,
      fixIgnoreCase: 'ignore case',
      fixRelaxWord: 'relax word',
      fixClearSources: 'clear sources',
      fixClearTime: 'clear time',
    });

    assert.ok(fixes.some((f) => f.key === 'disable-case'));
    assert.ok(fixes.some((f) => f.key === 'disable-word'));
    assert.ok(fixes.some((f) => f.key === 'clear-time'));
    assert.ok(!fixes.some((f) => f.key === 'clear-types'));
    assert.ok(fixes.some((f) => f.key === 'clear-sources'));

    const stepFixes = zeroResultFixes(
      [createQueryStep('Error'), createQueryStep('timeout')],
      null,
      { sources: [], excludedSources: [], types: [], timePreset: '' },
      {
        fixRemoveStep: (label) => `rm ${label}`,
        fixIgnoreCase: 'ignore case',
        fixRelaxWord: 'relax word',
        fixClearSources: 'clear sources',
        fixClearTime: 'clear time',
      }
    );
    assert.ok(stepFixes.some((f) => f.key === 'drop-step-1'));
  });
});
