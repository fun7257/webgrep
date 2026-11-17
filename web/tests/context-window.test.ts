import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_CONTEXT_AUTO_LOAD_PACE,
  DEFAULT_CONTEXT_STEP_LINES,
  DEFAULT_INITIAL_CONTEXT_LINES,
  clampContextLineSetting,
  computeDownwardFetchWindow,
  computeInitialFetchWindow,
  computeMergedContextBounds,
  computeUpwardFetchWindow,
  formatContextRangeBadge,
  mergeContextLines,
  normalizeContextAutoLoadPace,
  resolveContextLoadCooldownMs,
} from '../src/lib/context-window.ts';

describe('Context Drawer incremental window helpers', () => {
  it('defaults to 10 initial/step lines and normal auto-load pace, clamping settings cleanly', () => {
    assert.equal(DEFAULT_INITIAL_CONTEXT_LINES, 10);
    assert.equal(DEFAULT_CONTEXT_STEP_LINES, 10);
    assert.equal(DEFAULT_CONTEXT_AUTO_LOAD_PACE, 'normal');
    assert.equal(clampContextLineSetting(undefined, 10), 10);
    assert.equal(clampContextLineSetting(Number.NaN, 10), 10);
    assert.equal(clampContextLineSetting(0, 10), 1);
    assert.equal(clampContextLineSetting(15.6, 10), 16);
    assert.equal(clampContextLineSetting(250, 10), 100);

    assert.equal(normalizeContextAutoLoadPace('slow'), 'slow');
    assert.equal(normalizeContextAutoLoadPace('fast'), 'fast');
    assert.equal(normalizeContextAutoLoadPace('invalid'), 'normal');
    assert.equal(resolveContextLoadCooldownMs('slow'), 480);
    assert.equal(resolveContextLoadCooldownMs('normal'), 240);
    assert.equal(resolveContextLoadCooldownMs('fast'), 90);
  });

  it('computeInitialFetchWindow centers on anchor line with safe bounds', () => {
    assert.deepEqual(computeInitialFetchWindow(1), {
      line: 1,
      context: 10,
      targetStart: 1,
      targetEnd: 11,
    });
    assert.deepEqual(computeInitialFetchWindow(75), {
      line: 75,
      context: 10,
      targetStart: 65,
      targetEnd: 85,
    });
    assert.deepEqual(computeInitialFetchWindow(0, 15), {
      line: 1,
      context: 15,
      targetStart: 1,
      targetEnd: 16,
    });
  });

  it('computeUpwardFetchWindow steps cleanly toward line 1 and stops at #1', () => {
    const wDef = computeUpwardFetchWindow(75);
    assert.ok(wDef !== null);
    assert.equal(wDef.targetStart, 65);
    assert.equal(wDef.targetEnd, 74);

    const w1 = computeUpwardFetchWindow(75, 25);
    assert.ok(w1 !== null);
    assert.equal(w1.targetStart, 50);
    assert.equal(w1.targetEnd, 74);
    assert.equal(w1.line - w1.context, 50);
    assert.ok(w1.line + w1.context >= 74);
    assert.ok(w1.context >= 1);

    const wClamp = computeUpwardFetchWindow(10, 25);
    assert.ok(wClamp !== null);
    assert.equal(wClamp.targetStart, 1);
    assert.equal(wClamp.targetEnd, 9);
    assert.ok(wClamp.line - wClamp.context <= 1);
    assert.ok(wClamp.line + wClamp.context >= 9);

    const wTwo = computeUpwardFetchWindow(2, 10);
    assert.ok(wTwo !== null);
    assert.equal(wTwo.targetStart, 1);
    assert.equal(wTwo.targetEnd, 1);
    assert.ok(wTwo.context >= 1);
    assert.ok(wTwo.line - wTwo.context <= 1);

    assert.equal(computeUpwardFetchWindow(1, 10), null);
    assert.equal(computeUpwardFetchWindow(0, 10), null);
  });

  it('computeDownwardFetchWindow steps forward, clamps at totalLines, and keeps streaming when totalLines=0', () => {
    const wDef = computeDownwardFetchWindow(85, 150, false);
    assert.ok(wDef !== null);
    assert.equal(wDef.targetStart, 86);
    assert.equal(wDef.targetEnd, 95);

    const wUnknownTotal = computeDownwardFetchWindow(50000, 0, false, 10);
    assert.ok(wUnknownTotal !== null);
    assert.equal(wUnknownTotal.targetStart, 50001);
    assert.equal(wUnknownTotal.targetEnd, 50010);

    const w1 = computeDownwardFetchWindow(95, 150, false, 25);
    assert.ok(w1 !== null);
    assert.equal(w1.targetStart, 96);
    assert.equal(w1.targetEnd, 120);
    assert.ok(w1.line - w1.context <= 96);
    assert.ok(w1.line + w1.context >= 120);

    const wClamp = computeDownwardFetchWindow(140, 150, false, 25);
    assert.ok(wClamp !== null);
    assert.equal(wClamp.targetStart, 141);
    assert.equal(wClamp.targetEnd, 150);
    assert.ok(wClamp.line - wClamp.context <= 141);
    assert.ok(wClamp.line + wClamp.context >= 150);

    assert.equal(computeDownwardFetchWindow(150, 150, false, 10), null);
    assert.equal(computeDownwardFetchWindow(95, 150, true, 10), null);
    assert.equal(computeDownwardFetchWindow(0, 150, false, 10), null);
  });

  it('mergeContextLines handles fast-path prepend/append and deduplication cleanly', () => {
    const mid = [
      { n: 50, text: 'line 50' },
      { n: 51, text: 'line 51' },
    ];
    const before = [
      { n: 48, text: 'line 48' },
      { n: 49, text: 'line 49' },
    ];
    const prepended = mergeContextLines(mid, before);
    assert.deepEqual(
      prepended.map((l) => l.n),
      [48, 49, 50, 51]
    );

    const after = [
      { n: 52, text: 'line 52' },
      { n: 53, text: 'line 53' },
    ];
    const appended = mergeContextLines(prepended, after);
    assert.deepEqual(
      appended.map((l) => l.n),
      [48, 49, 50, 51, 52, 53]
    );

    const overlapping = mergeContextLines(appended, [
      { n: 47, text: 'line 47' },
      { n: 48, text: 'line 48 updated' },
    ]);
    assert.deepEqual(
      overlapping.map((l) => l.n),
      [47, 48, 49, 50, 51, 52, 53]
    );
    assert.equal(overlapping[1].text, 'line 48 updated');
  });

  it('computeMergedContextBounds distinguishes unknown giant-file totalLines=0 from EOF', () => {
    const sample = [
      { n: 24995, text: 'a' },
      { n: 25004, text: 'b' },
    ];
    const giantMid = computeMergedContextBounds(sample, 0, false);
    assert.deepEqual(giantMid, {
      firstLine: 24995,
      lastLine: 25004,
      totalLines: 0,
      eof: false,
      canLoadBefore: true,
      canLoadAfter: true,
    });
    assert.equal(
      formatContextRangeBadge(giantMid.firstLine, giantMid.lastLine, giantMid.totalLines),
      '24995–25004'
    );

    const giantEof = computeMergedContextBounds(sample, 25004, true);
    assert.equal(giantEof.eof, true);
    assert.equal(giantEof.totalLines, 25004);
    assert.equal(giantEof.canLoadAfter, false);
    assert.equal(
      formatContextRangeBadge(giantEof.firstLine, giantEof.lastLine, giantEof.totalLines),
      '24995–25004 / 25004'
    );
  });
});
