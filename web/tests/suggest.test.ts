import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { parseSearchQuery } from '../src/lib/query.ts';
import { messages } from '../src/lib/i18n.ts';
import {
  buildVocabulary,
  closestSource,
  collectPlaces,
  computeCompletion,
  describeQuery,
  ghostSuffix,
  historyGhost,
  legacyReplacement,
  queryTips,
  zeroResultFixes,
  type CompletionContext,
} from '../src/lib/suggest.ts';

const t = messages.zh.suggest;
const SOURCES = [
  { id: 'u-1', name: 'zedis-rust', path: '/code/zedis/src' },
  { id: 'u-2', name: 'rust-examples', path: '/code/examples' },
];
const places = collectPlaces(['zedis-rust/states/server/set.rs', 'zedis-rust/views/geo_map.rs', 'rust-examples/main.go']);
const vocabulary = buildVocabulary([
  'pub(crate) async fn first_load_set_value(conn: &mut RedisAsyncConn) {',
  '    // Get total number of members in the SET',
  'let members = cmd("SMEMBERS").arg(key);',
  'for m in members.iter() { Members::push(m) }',
]);

function ctx(pattern: string, extra: Partial<CompletionContext> = {}): CompletionContext {
  return { pattern, cursor: pattern.length, sources: SOURCES, places, vocabulary, starters: false, t, ...extra };
}
const labels = (p: string, extra: Partial<CompletionContext> = {}) => computeCompletion(ctx(p, extra)).items.map((i) => i.insert);

describe('computeCompletion', () => {
  it('in: lists sources, file types and folders from results; comma completes the next item', () => {
    const r = computeCompletion(ctx('x in:'));
    assert.equal(r.autoSelect, true);
    const ins = r.items.map((i) => i.insert);
    assert.ok(ins.includes('in:zedis-rust'));
    assert.ok(ins.includes('in:*.rs'));
    assert.ok(ins.includes('in:states/server/'));
    assert.deepEqual(labels('x in:zedis-rust,ex'), ['in:zedis-rust,rust-examples']);
    assert.ok(labels('x -in:zed').includes('-in:zedis-rust'));
  });

  it('time: presets and numeric expansion', () => {
    assert.deepEqual(labels('x time:t'), ['time:today']);
    assert.deepEqual(labels('x time:3'), ['time:3m', 'time:3h', 'time:3d']);
    assert.deepEqual(labels('x -time:'), []);
  });

  it('plain words: qualifier conversions are offered but never pre-selected', () => {
    const r = computeCompletion(ctx('error 1h'));
    assert.equal(r.autoSelect, false);
    assert.deepEqual(r.items.map((i) => i.insert), ['time:1h']);
    assert.deepEqual(labels('error .rs'), ['in:*.rs']);
    assert.ok(labels('error zed').includes('in:zedis-rust'));
    assert.deepEqual(labels('-'), ['-in:']);
  });

  it('completes words that occur in the current results (frequency first, case kept sensible)', () => {
    // `members` appears as members/Members/SMEMBERS-free: lowercase typed + mixed spellings → lowercase insert
    assert.equal(labels('memb')[0], 'members');
    assert.equal(labels('-memb')[0], '-members');
    assert.ok(labels('Redis').includes('RedisAsyncConn'));
    assert.ok(!labels('fi').includes('fi'));
    assert.deepEqual(labels('memb', { vocabulary: null }), []);
  });

  it('starter items on an empty box, nothing mid-word', () => {
    assert.deepEqual(labels('', { starters: true }), ['in:', 'time:']);
    assert.deepEqual(labels('', { starters: false }), []);
    assert.equal(computeCompletion({ ...ctx('members'), cursor: 3 }).token, null);
  });
});

describe('ghost text', () => {
  it('suffix of the suggestion, and rest of a history query', () => {
    assert.equal(ghostSuffix('members', 'memb'), 'ers');
    assert.equal(ghostSuffix('in:zedis-rust', 'zed'), '');
    assert.equal(historyGhost('pub fn', ['pub fn async members in:zedis-rust']), ' async members in:zedis-rust');
    assert.equal(historyGhost('', ['x']), '');
  });
});

describe('queryTips / zeroResultFixes / describeQuery', () => {
  const tips = (p: string) => queryTips(p, parseSearchQuery(p, Date.now(), SOURCES), SOURCES, t);

  it('regex-looking word → wrap in /…/', () => {
    const [tip] = tips('error \\d{4}');
    assert.equal(tip.fix?.pattern, 'error /\\d{4}/');
  });

  it('in: typo → did you mean; unknown plain value → path filter info', () => {
    const [typo] = tips('x in:zedis-rst');
    assert.equal(typo.fix?.pattern, 'x in:zedis-rust');
    assert.equal(closestSource('zzz', SOURCES), null);
    const [info] = tips('x in:server');
    assert.equal(info.fix, undefined);
  });

  it('bad time: value, legacy syntax migration, lone -x', () => {
    assert.ok(tips('x time:abc').some((tp) => tp.key === 'time:abc'));
    const legacy = tips('x $t(15m) $@(zedis-rust) $-(a b) @rust-examples').find((tp) => tp.key === 'legacy');
    assert.equal(legacy?.fix?.pattern, 'x time:15m in:zedis-rust -"a b" in:rust-examples');
    assert.equal(legacyReplacement('@Vector', () => false), null);
    assert.ok(tips('-O3').some((tp) => tp.key === 'lone-minus'));
  });

  it('zero results: nearby, ignore case, drop scope / terms', () => {
    const p = 'Error timeout -debug in:zedis-rust';
    const fixes = zeroResultFixes(p, parseSearchQuery(p, Date.now(), SOURCES), { strictLine: true, nearbyLines: 15 }, t);
    assert.equal(fixes[0].action, 'nearby');
    assert.equal(fixes[1].pattern, 'error timeout -debug in:zedis-rust');
    assert.ok(fixes.some((f) => f.pattern === 'Error timeout -debug'));
    assert.ok(fixes.some((f) => f.pattern === 'Error timeout in:zedis-rust'));
    assert.ok(fixes.length <= 5);
  });

  it('plain-language reading', () => {
    const p = 'pub async -test in:zedis-rust time:1h';
    assert.equal(
      describeQuery(parseSearchQuery(p, Date.now(), SOURCES), t),
      '找 pub + async · 排除 test · 在 zedis-rust · 时间 最近 1 小时'
    );
    assert.equal(describeQuery(parseSearchQuery('members'), t), '');
  });
});
