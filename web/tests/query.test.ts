import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  formatSearchTerm,
  parseDollarFlags,
  parseSearchQuery,
  removeInlineModifierFromPattern,
  toggleTermExclusion,
} from '../src/lib/query.ts';
import {
  analyzeStructuredLine,
  buildHighlightSegments,
  decodeHumanEscapes,
  extractLeadingNanoTimestamp,
  getCachedHitSnippet,
  highlightCodeWithMatches,
  universalPrettyStructure,
} from '../src/lib/utils.ts';

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

const SOURCES = [{ id: 'u-1', name: 'zedis-rust' }, { name: 'testdata' }, { name: 'legacy' }];

describe('parseSearchQuery (space / - / "" / in: / time: / /re/ / smart case)', () => {
  it('space-separated terms are all required; first one is the primary wire pattern', () => {
    const q = parseSearchQuery('pub fn async members');
    assert.equal(q.primaryPattern, 'pub');
    assert.equal(q.primaryRaw, 'pub');
    assert.deepEqual(q.contains, ['fn', 'async', 'members']);
    assert.deepEqual(q.excludes, []);
  });

  it('-word excludes, "phrase" keeps spaces, and a quoted leading dash stays literal', () => {
    const q = parseSearchQuery('error -timeout "retry in 50ms" -"health check" "-O3"');
    assert.equal(q.primaryPattern, 'error');
    assert.deepEqual(q.contains, ['retry in 50ms', '$c(-O3)']);
    assert.deepEqual(q.excludes, ['timeout', 'health check']);
    assert.ok(q.modifiers.some((m) => m.kind === 'include' && m.value === '"retry in 50ms"'));
  });

  it('symbols that are not operators stay literal (->, --release, "status":, @Vector(64, u8))', () => {
    const q = parseSearchQuery('-> --release "status": @Vector(64, u8) @import("std")', Date.now(), SOURCES);
    assert.equal(q.primaryPattern, '->');
    assert.deepEqual(q.contains, ['--release', '"status":', '$c(@Vector(64, u8))', '@import("std")']);
    assert.deepEqual(q.globs, []);
    assert.deepEqual(q.excludes, []);
  });

  it('a lone -O3 / -v is a search, not an exclusion', () => {
    const q = parseSearchQuery('-O3');
    assert.equal(q.primaryPattern, '$c(-O3)');
    assert.deepEqual(q.excludes, []);
  });

  it('in: covers data sources, file types and paths; -in: excludes; comma = OR', () => {
    const q = parseSearchQuery('members in:zedis-rust -in:legacy in:.rs,*.go -in:*_test.rs in:src/ in:server', Date.now(), SOURCES);
    assert.deepEqual(q.globs, ['zedis-rust', '!legacy']);
    assert.deepEqual(q.fileGlobs, ['*.rs', '*.go', '!*_test.rs', 'src/', 'server']);
    assert.equal(q.primaryPattern, 'members');
    assert.deepEqual(q.contains, []);
    assert.ok(q.modifiers.some((m) => m.kind === 'exclude-file' && m.value === 'legacy'));
    // `in:a,b` with two sources is ONE globs entry (backend ORs names inside an entry, ANDs entries).
    assert.deepEqual(parseSearchQuery('x in:zedis-rust,testdata', Date.now(), SOURCES).globs, ['zedis-rust,testdata']);
    // Qualifier keys are case-insensitive; an empty value is still being typed.
    const typing = parseSearchQuery('members IN:zedis-rust in:', Date.now(), SOURCES);
    assert.deepEqual(typing.globs, ['zedis-rust']);
    assert.deepEqual(typing.contains, []);
  });

  it('@ is plain text again (legacy @source only for an exact source name); other key: words stay literal', () => {
    const q = parseSearchQuery('@Vector @testdata http://x key:value "in:x"', Date.now(), SOURCES);
    assert.equal(q.primaryPattern, '$c(@Vector)');
    assert.deepEqual(q.globs, ['testdata']);
    assert.deepEqual(q.contains, ['http://x', 'key:value', 'in:x']);
  });

  it('smart case: uppercase letters make that term case-sensitive', () => {
    const q = parseSearchQuery('Error timeout -DEBUG');
    assert.equal(q.primaryPattern, '$c(Error)');
    assert.deepEqual(q.contains, ['timeout']);
    assert.deepEqual(q.excludes, ['$c(DEBUG)']);
  });

  it('/re/ is a regex for that term only; plain paths like /api/ stay literal', () => {
    const q = parseSearchQuery('/pub\\s+fn/ -/DEBUG|TRACE/ /api/v1 /\\d{4}');
    assert.equal(q.primaryPattern, '$r(pub\\s+fn)');
    assert.deepEqual(q.excludes, ['$rc(DEBUG|TRACE)']);
    assert.deepEqual(q.contains, ['/api/v1', '$r(\\d{4})']);
    assert.equal(q.hasScopedRegex, true);
    assert.ok(q.modifiers.some((m) => m.kind === 'exclude' && m.value === '/DEBUG|TRACE/'));
  });

  it('literal text that looks like a $x( modifier is escaped on the wire', () => {
    const q = parseSearchQuery('"$r(x)"');
    assert.equal(q.primaryPattern, '$r(\\$r\\(x\\))');
  });

  it('legacy $(), $-(), $@(), $r(), $c(), $w() keep working', () => {
    const q = parseSearchQuery('$(pub fn init) $-(retry in 50ms) $@(testdata) $-@(legacy) $cw(ErrorCode) -$r(DEBUG|TRACE)', Date.now(), SOURCES);
    assert.equal(q.primaryPattern, 'pub fn init');
    assert.deepEqual(q.contains, ['$cw(ErrorCode)']);
    assert.deepEqual(q.excludes, ['retry in 50ms', '$rc(DEBUG|TRACE)']);
    assert.deepEqual(q.globs, ['testdata', '!legacy']);
    assert.equal(q.hasScopedCase, true);
    assert.equal(q.hasScopedWord, true);
  });

  it('ignores bare operators and empty functions while typing', () => {
    const q = parseSearchQuery('error - $ $() $-() $@() $w()');
    assert.equal(q.primaryPattern, 'error');
    assert.deepEqual(q.contains, []);
    assert.deepEqual(q.excludes, []);
    assert.deepEqual(q.globs, []);
  });

  it('recognizes all dollar flag combinations', () => {
    assert.deepEqual(parseDollarFlags('$r'), { regex: true, caseSensitive: false, wholeWord: false });
    assert.deepEqual(parseDollarFlags('$cw'), { regex: false, caseSensitive: true, wholeWord: true });
    assert.deepEqual(parseDollarFlags('$rcw'), { regex: true, caseSensitive: true, wholeWord: true });
  });

  it('parses $t(...) relative and explicit time range modifiers', () => {
    const fixedNow = 1730340900000;
    const qRel = parseSearchQuery('time:15m timeout in:testdata', fixedNow, SOURCES);
    assert.equal(qRel.primaryPattern, 'timeout');
    assert.equal(qRel.hasScopedTime, true);
    assert.equal(qRel.timeStartMs, fixedNow - 15 * 60 * 1000);
    assert.equal(qRel.timeEndMs, 0);
    assert.deepEqual(qRel.globs, ['testdata']);
    assert.ok(qRel.modifiers.some((m) => m.kind === 'flag' && m.value === '15m'));

    const qDay = parseSearchQuery('time:2026-10-31 timeout', fixedNow);
    assert.ok(qDay.timeStartMs > 0);
    assert.ok(qDay.timeEndMs > qDay.timeStartMs);

    const qWindow = parseSearchQuery('time:10:00..10:30 timeout', fixedNow);
    assert.equal(qWindow.timeEndMs - qWindow.timeStartMs, 30 * 60 * 1000 + 59999);

    const qToday = parseSearchQuery('time:today timeout', fixedNow);
    const midnight = new Date(fixedNow);
    midnight.setHours(0, 0, 0, 0);
    assert.equal(qToday.timeStartMs, midnight.getTime());
    assert.equal(qToday.timeEndMs, 0);

    const qYesterday = parseSearchQuery('time:yesterday timeout', fixedNow);
    assert.equal(qYesterday.timeEndMs, midnight.getTime() - 1);

    // `time:1` while typing `time:15m` must not become the year 2001; legacy `$t()` still works.
    assert.equal(parseSearchQuery('time:1 timeout', fixedNow).hasScopedTime, false);
    assert.equal(parseSearchQuery('$t(15m) timeout', fixedNow).timeStartMs, fixedNow - 15 * 60 * 1000);
  });

  it('formatSearchTerm / toggleTermExclusion produce natural tokens', () => {
    assert.equal(formatSearchTerm('members'), 'members');
    assert.equal(formatSearchTerm('pub fn'), '"pub fn"');
    assert.equal(formatSearchTerm('-O3'), '"-O3"');
    assert.equal(formatSearchTerm('in:x'), '"in:x"');
    assert.equal(toggleTermExclusion('timeout'), '-timeout');
    assert.equal(toggleTermExclusion('-timeout'), 'timeout');
    assert.equal(toggleTermExclusion('"a b"'), '-"a b"');
    assert.equal(toggleTermExclusion('-"a b"'), '"a b"');
    assert.equal(toggleTermExclusion('$-(a b)'), '"a b"');
  });
});

describe('analyzeStructuredLine & buildHighlightSegments (Inspector formatting & highlights)', () => {
  it('result-row windowing skips leading indentation so the match stays visible', () => {
    const text = '            let size: usize = cmd("SCARD").arg(key).query_async(conn).await?;';
    const segs = buildHighlightSegments(text, undefined, [], true, true, 'scard');
    assert.equal(segs.map((s) => s.text).join('').startsWith('let size'), true);
    assert.ok(segs.some((s) => s.kind === 'primary' && s.text === 'SCARD'));
  });

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

  it('extracts 19-digit nanosecond timestamp and formats JSON payload cleanly', () => {
    const line =
      '1730340905123456789 {"level":"error","service":"payment-api","msg":"upstream timeout"}';
    const ts = extractLeadingNanoTimestamp(line);
    assert.ok(ts !== null);
    assert.equal(ts.nsStr, '1730340905123456789');
    assert.equal(
      ts.restText,
      '{"level":"error","service":"payment-api","msg":"upstream timeout"}'
    );

    const info = analyzeStructuredLine(line);
    assert.equal(info.kind, 'json');
    assert.ok(info.prefix?.includes('1730340905123456789'));
    assert.ok(info.formattedText.includes('"service": "payment-api"'));
    assert.ok(info.timeHint && info.timeHint.length > 0);
    assert.equal(info.formatBadge, 'JSON');
  });

  it('decodes Unicode \\uXXXX, URL %XX escapes, and recursively unpacks nested JSON strings', () => {
    const dockerLine =
      '{"stream":"stderr","log":"{\\"level\\":\\"error\\",\\"msg\\":\\"\\u8ba2\\u5355%E8%B6%85%E6%97%B6\\"}"}';
    const info = analyzeStructuredLine(dockerLine);
    assert.equal(info.kind, 'json');
    assert.equal(info.formatBadge, 'JSON');
    // Verify nested JSON string was unpacked into an object and Unicode + URL escapes were decoded to Chinese
    assert.ok(info.bodyFormattedText?.includes('"订单超时"'));
    assert.equal(decodeHumanEscapes('hello\\u4e16\\u754c%21'), 'hello世界!');
  });

  it('indents compressed single-line HTML and arbitrary brace/bracket structures', () => {
    const htmlLine = '<div class="card"><span class="title">Payment Failed</span><p>Retry in 5s</p></div>';
    const htmlInfo = analyzeStructuredLine(htmlLine);
    assert.equal(htmlInfo.formatBadge, 'HTML');
    assert.ok(htmlInfo.bodyFormattedText?.includes('\n  <span class="title">'));

    const structLine =
      'OrderEvent{id: 9012, customer: "alice", items: [sku_1001, sku_1002], meta: {region: ap-east, retry: 3, gateway: edge-01}}';
    const pretty = universalPrettyStructure(structLine);
    assert.equal(pretty.badge, 'STRUCT');
    assert.ok(pretty.formatted.includes('\n  id: 9012,'));
  });

  it('tokenizes code syntax (keywords, builtins, types, strings, comments) while preserving search match highlights', () => {
    const zigLine = 'pub fn scanChunk(buf: []const u8) @Vector(64, u8) { // fast path';
    const matchSegs = buildHighlightSegments(
      zigLine,
      undefined,
      [],
      true,
      false,
      'scanChunk',
      false
    );
    const codeSegs = highlightCodeWithMatches(zigLine, matchSegs);
    assert.equal(codeSegs.map((s) => s.text).join(''), zigLine);
    assert.ok(codeSegs.some((s) => s.text === 'pub' && s.syntaxKind === 'keyword'));
    assert.ok(codeSegs.some((s) => s.text === 'fn' && s.syntaxKind === 'keyword'));
    assert.ok(codeSegs.some((s) => s.text === 'scanChunk' && s.matchKind === 'primary'));
    assert.ok(codeSegs.some((s) => s.text === 'u8' && s.syntaxKind === 'type'));
    assert.ok(codeSegs.some((s) => s.text === '@Vector' && s.syntaxKind === 'builtin'));
    assert.ok(codeSegs.some((s) => s.text === '64' && s.syntaxKind === 'number'));
    assert.ok(codeSegs.some((s) => s.text.includes('// fast path') && s.syntaxKind === 'comment'));
  });

  it('builds 3-line hit snippets with shared outer indentation stripped and relative block indent preserved', () => {
    const hit = {
      file: 'zedis-rust/states/server/set.rs',
      line: 92,
      col: 13,
      prevText: '        if let Some(set) = self.sets.get_mut(key) {',
      text: '            let removed = set.remove(member);',
      nextText: '        }',
      spans: [{ start: 26, end: 36 }],
    };
    const snippet = getCachedHitSnippet(hit, ['Some'], true, 'literal:set.remove\u0001Some', 'set.remove', false);
    assert.ok(snippet.prev);
    assert.ok(snippet.next);
    // 8 shared spaces stripped;prev starts at col 0, match retains 4 spaces of relative block indent
    assert.equal(snippet.prev.map((s) => s.text).join(''), 'if let Some(set) = self.sets.get_mut(key) {');
    assert.ok(snippet.prev.some((s) => s.text === 'Some' && s.kind === 'contains-0'));
    assert.equal(snippet.match.map((s) => s.text).join(''), '    let removed = set.remove(member);');
    assert.ok(snippet.match.some((s) => s.text === 'set.remove' && s.kind === 'primary'));
    assert.equal(snippet.next.map((s) => s.text).join(''), '}');
  });
});
