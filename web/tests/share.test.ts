import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildShareReplayUrl,
  decodeShareReplay,
  encodeShareReplay,
  extractShareReplayFromUrl,
  resolvePinnedShareTime,
  stripShareParamFromUrl,
  type ShareReplayState,
} from '../src/lib/share.ts';

describe('share query & context replay codec', () => {
  it('round-trips multi-step queries, regex/case/word flags, CJK text, archives, and byte offsets', () => {
    const input: ShareReplayState = {
      steps: [
        { text: '订单超时 error_502', exclude: false, caseSensitive: true, wholeWord: false, isRegex: false },
        { text: 'healthcheck|metrics', exclude: true, caseSensitive: false, wholeWord: false, isRegex: true },
      ],
      draft: {
        text: '\\buid_\\d+\\b',
        exclude: false,
        caseSensitive: true,
        wholeWord: true,
        isRegex: true,
      },
      sources: ['api-logs', 'docker-prod'],
      excludedSources: ['archive-old'],
      timePreset: '2026-11-17 10:00:00..2026-11-17 10:15:00',
      timeStartMs: 1794880800000,
      timeEndMs: 1794881700000,
      hidden: true,
      respectIgnore: true,
      maxResults: 5000,
      contextPath: 'api-logs/bundles/2026-11-17.tar.gz::worker/main.log',
      contextAnchorLine: 4219,
      contextAnchorByte: 981240,
      contextPretty: true,
      inspectorRaw: true,
      openContext: true,
    };

    const encoded = encodeShareReplay(input);
    assert.ok(encoded.length > 0);
    assert.doesNotMatch(encoded, /[+/=]/);

    const decoded = decodeShareReplay(encoded);
    assert.deepEqual(decoded, input);

    const url = buildShareReplayUrl('http://100.64.0.1:8787/?foo=bar#hash', input);
    const extracted = extractShareReplayFromUrl(url);
    assert.deepEqual(extracted, input);

    assert.equal(stripShareParamFromUrl(url), '/');
  });

  it('pins relative and floating time ranges deterministically for exact replay', () => {
    const startMs = new Date(2026, 10, 17, 15, 0, 0, 0).getTime();
    const execMs = new Date(2026, 10, 17, 15, 15, 30, 0).getTime();

    const contentPinned = resolvePinnedShareTime('15m', startMs, 0, execMs, false);
    assert.equal(contentPinned.timePreset, '2026-11-17 15:00:00..2026-11-17 15:15:30');
    assert.equal(contentPinned.timeStartMs, startMs);
    assert.equal(contentPinned.timeEndMs, execMs);

    const mtimePinned = resolvePinnedShareTime('15m', startMs, 0, execMs, true);
    assert.equal(mtimePinned.timePreset, '2026-11-17 15:00:00..');
    assert.equal(mtimePinned.timeStartMs, startMs);
    assert.equal(mtimePinned.timeEndMs, 0);

    const customKept = resolvePinnedShareTime('2026-11-17 08:00:00..2026-11-17 09:00:00', 100, 200, execMs, false);
    assert.equal(customKept.timePreset, '2026-11-17 08:00:00..2026-11-17 09:00:00');
    assert.equal(customKept.timeStartMs, 100);
    assert.equal(customKept.timeEndMs, 200);

    const empty = resolvePinnedShareTime('', 0, 0, execMs, false);
    assert.deepEqual(empty, { timePreset: '', timeStartMs: 0, timeEndMs: 0 });
  });

  it('returns null gracefully on invalid or tampered tokens', () => {
    assert.equal(decodeShareReplay(''), null);
    assert.equal(decodeShareReplay('***invalid***'), null);
    assert.equal(decodeShareReplay('e30'), null); // {} missing v: 1
    assert.equal(extractShareReplayFromUrl('http://127.0.0.1:8787/'), null);
  });
});
