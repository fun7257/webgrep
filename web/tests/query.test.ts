import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseDollarFlags,
  parseSearchQuery,
  removeInlineModifierFromPattern,
} from '../src/lib/query.ts';
import { analyzeStructuredLine, buildHighlightSegments } from '../src/lib/utils.ts';

describe('removeInlineModifierFromPattern (pill removal)', () => {
  it('removes -error from "upstream-error -error" without corrupting upstream-error', () => {
    const next = removeInlineModifierFromPattern('upstream-error -error', '-error');
    assert.equal(next, 'upstream-error');
  });

  it('removes middle modifier pill while preserving surrounding tokens', () => {
    const next = removeInlineModifierFromPattern(
      'ERROR -healthcheck +payment @testdata -@legacy',
      '-healthcheck'
    );
    assert.equal(next, 'ERROR +payment @testdata -@legacy');
  });

  it('removes scoped $w / $cw / $r tokens cleanly', () => {
    const next = removeInlineModifierFromPattern(
      'payment $w(ErrorCode) -$r(timeout|retry)',
      '-$r(timeout|retry)'
    );
    assert.equal(next, 'payment $w(ErrorCode)');
  });
});

describe('parseSearchQuery (progressive query syntax)', () => {
  it('parses progressive space-separated terms, excludes, and @source scopes', () => {
    const q = parseSearchQuery('ERROR payment -healthcheck @testdata -@legacy');
    assert.equal(q.primaryPattern, 'ERROR');
    assert.deepEqual(q.contains, ['payment']);
    assert.deepEqual(q.excludes, ['healthcheck']);
    assert.deepEqual(q.globs, ['testdata', '!legacy']);
  });

  it('parses scoped $w, $c, $r, $cw, $rw, $rcw modifiers and sets active flags', () => {
    const q = parseSearchQuery('$cw(ErrorCode) $rw(\\d{4}) -$r(DEBUG|TRACE)');
    assert.equal(q.primaryPattern, '$cw(ErrorCode)');
    assert.deepEqual(q.contains, ['$rw(\\d{4})']);
    assert.deepEqual(q.excludes, ['$r(DEBUG|TRACE)']);
    assert.equal(q.hasScopedRegex, true);
    assert.equal(q.hasScopedCase, true);
    assert.equal(q.hasScopedWord, true);
  });

  it('ignores empty $r() / $c() / $w() while user is typing inside parentheses', () => {
    const q = parseSearchQuery('ERROR $w()');
    assert.equal(q.primaryPattern, 'ERROR');
    assert.deepEqual(q.contains, []);
  });

  it('recognizes all dollar flag combinations', () => {
    assert.deepEqual(parseDollarFlags('$r'), {
      regex: true,
      caseSensitive: false,
      wholeWord: false,
    });
    assert.deepEqual(parseDollarFlags('$cw'), {
      regex: false,
      caseSensitive: true,
      wholeWord: true,
    });
    assert.deepEqual(parseDollarFlags('$rcw'), {
      regex: true,
      caseSensitive: true,
      wholeWord: true,
    });
  });
});

describe('analyzeStructuredLine & buildHighlightSegments (Inspector formatting & highlights)', () => {
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
});
