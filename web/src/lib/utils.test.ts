import {
  cn,
  copyTextToClipboard,
  detectInlineEpochHint,
  extractLeadingNanoTimestamp,
  formatBytes,
  formatMs,
  formatThroughput,
  skipLeadingNanoTimestampOffset,
  splitFilePath,
  type NanoTimestampInfo,
} from './format.ts';
import {
  buildHighlightSegments,
  collectTermSpans,
  compileTermMatcher,
  getCachedHighlightSegments,
  type CompiledTermMatcher,
  type HighlightSegment,
} from './highlight/segments.ts';
import {
  analyzeStructuredLine,
  decodeHumanEscapes,
  formatContextRecordPretty,
  universalPrettyStructure,
  type StructuredAnalysis,
} from './structured/analyzer.ts';
import {
  highlightCodeWithMatches,
  syntaxKindToClass,
  tokenizeCodeSyntax,
  type CodeHighlightSegment,
  type SyntaxSpan,
  type SyntaxTokenKind,
} from './highlight/syntax.ts';
import * as utilsFacade from './utils.ts';
import type {
  CodeHighlightSegment as FacadeCodeHighlightSegment,
  HighlightSegment as FacadeHighlightSegment,
  NanoTimestampInfo as FacadeNanoTimestampInfo,
  StructuredAnalysis as FacadeStructuredAnalysis,
  SyntaxTokenKind as FacadeSyntaxTokenKind,
} from './utils.ts';
import type { HitItem } from './types.ts';

function assertOk(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}

function assertEqual<T>(actual: T, expected: T, message = 'Assertion mismatch'): void {
  if (!Object.is(actual, expected)) {
    throw new Error(
      `${message}: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`
    );
  }
}

function assertNotEqual<T>(actual: T, unexpected: T, message = 'Expected values to differ'): void {
  if (Object.is(actual, unexpected)) {
    throw new Error(`${message}: both equal ${JSON.stringify(actual)}`);
  }
}

function deepEquals(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') {
    return false;
  }
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  const objA = a as Record<string, unknown>;
  const objB = b as Record<string, unknown>;
  const keysA = Object.keys(objA);
  const keysB = Object.keys(objB);
  if (keysA.length !== keysB.length) return false;
  for (const key of keysA) {
    if (!Object.prototype.hasOwnProperty.call(objB, key)) return false;
    if (!deepEquals(objA[key], objB[key])) return false;
  }
  return true;
}

function assertDeepEqual(actual: unknown, expected: unknown, message = 'Deep assertion mismatch'): void {
  if (!deepEquals(actual, expected)) {
    throw new Error(
      `${message}: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`
    );
  }
}

function assertSplit(
  input: string,
  expected: { dir: string; name: string; ext: string }
): void {
  const actual = splitFilePath(input);
  assertDeepEqual(actual, expected, `splitFilePath(${JSON.stringify(input)})`);
}

export function runSplitFilePathTests(): void {
  assertSplit('README.md', {
    dir: '',
    name: 'README.md',
    ext: 'md',
  });
  assertSplit('src/lib/utils.ts', {
    dir: 'src/lib/',
    name: 'utils.ts',
    ext: 'ts',
  });
  assertSplit('web-grep-v0.1.7.tar.gz::README.md', {
    dir: 'web-grep-v0.1.7.tar.gz::',
    name: 'README.md',
    ext: 'md',
  });
  assertSplit('agent/web-grep-v0.1.7.tar.gz::package.json', {
    dir: 'agent/web-grep-v0.1.7.tar.gz::',
    name: 'package.json',
    ext: 'json',
  });
  assertSplit('dir/archive.tar.gz::sub/file.zig', {
    dir: 'dir/archive.tar.gz::sub/',
    name: 'file.zig',
    ext: 'zig',
  });
  assertSplit('bundle.zip::logs/2026/app.log', {
    dir: 'bundle.zip::logs/2026/',
    name: 'app.log',
    ext: 'log',
  });
  assertSplit('docker/nginx', {
    dir: 'docker/',
    name: 'nginx',
    ext: '',
  });
  assertSplit('docker/api-111111111111', {
    dir: 'docker/',
    name: 'api-111111111111',
    ext: '',
  });
  assertSplit('logs\\2026\\server.LOG', {
    dir: 'logs/2026/',
    name: 'server.LOG',
    ext: 'log',
  });

  // Preserves 4096-entry cache identity and handles >4096 rollover cleanly
  const cachedRef1 = splitFilePath('cache/test/a.ts');
  const cachedRef2 = utilsFacade.splitFilePath('cache/test/a.ts');
  assertEqual(cachedRef1, cachedRef2, 'splitFilePath cache reference');

  for (let i = 0; i < 4105; i++) {
    const entry = splitFilePath(`bulk/dir-${i}/file-${i}.txt`);
    assertEqual(entry.ext, 'txt', 'bulk splitFilePath ext');
  }
  const postRollover = splitFilePath('cache/test/a.ts');
  assertDeepEqual(postRollover, { dir: 'cache/test/', name: 'a.ts', ext: 'ts' });
}

function runFacadeCompatibilityTests(): void {
  // format.ts
  assertEqual(utilsFacade.cn, cn);
  assertEqual(utilsFacade.copyTextToClipboard, copyTextToClipboard);
  assertEqual(utilsFacade.formatBytes, formatBytes);
  assertEqual(utilsFacade.formatMs, formatMs);
  assertEqual(utilsFacade.formatThroughput, formatThroughput);
  assertEqual(utilsFacade.splitFilePath, splitFilePath);
  assertEqual(utilsFacade.skipLeadingNanoTimestampOffset, skipLeadingNanoTimestampOffset);
  assertEqual(utilsFacade.extractLeadingNanoTimestamp, extractLeadingNanoTimestamp);
  assertEqual(utilsFacade.detectInlineEpochHint, detectInlineEpochHint);

  // highlight/segments.ts
  assertEqual(utilsFacade.buildHighlightSegments, buildHighlightSegments);
  assertEqual(utilsFacade.getCachedHighlightSegments, getCachedHighlightSegments);

  // structured/analyzer.ts
  assertEqual(utilsFacade.decodeHumanEscapes, decodeHumanEscapes);
  assertEqual(utilsFacade.universalPrettyStructure, universalPrettyStructure);
  assertEqual(utilsFacade.analyzeStructuredLine, analyzeStructuredLine);
  assertEqual(utilsFacade.formatContextRecordPretty, formatContextRecordPretty);

  // highlight/syntax.ts
  assertEqual(utilsFacade.syntaxKindToClass, syntaxKindToClass);
  assertEqual(utilsFacade.highlightCodeWithMatches, highlightCodeWithMatches);

  // Type compatibility across direct submodules and barrel facade
  const nano: NanoTimestampInfo = {
    nsStr: '1730340905123456789',
    formattedTime: '10-31 10:15:05.123',
    fullFormattedTime: '2024-10-31 10:15:05.123',
    restText: 'ok',
    prefixLen: 20,
  };
  const facadeNano: FacadeNanoTimestampInfo = nano;
  assertEqual(facadeNano.nsStr, nano.nsStr);

  const seg: HighlightSegment = { text: 'err', kind: 'primary' };
  const facadeSeg: FacadeHighlightSegment = seg;
  assertEqual(facadeSeg.kind, 'primary');

  const synKind: SyntaxTokenKind = 'keyword';
  const facadeSynKind: FacadeSyntaxTokenKind = synKind;
  assertEqual(facadeSynKind, 'keyword');

  const codeSeg: CodeHighlightSegment = {
    text: 'fn',
    matchKind: 'plain',
    syntaxKind: synKind,
  };
  const facadeCodeSeg: FacadeCodeHighlightSegment = codeSeg;
  assertEqual(facadeCodeSeg.syntaxKind, 'keyword');

  const analysis: StructuredAnalysis = analyzeStructuredLine('{"ok":true}');
  const facadeAnalysis: FacadeStructuredAnalysis = analysis;
  assertEqual(facadeAnalysis.kind, 'json');
}

function runFormatTests(): void {
  assertEqual(cn('px-2 py-1', 'px-4', false && 'hidden'), 'py-1 px-4');
  assertEqual(copyTextToClipboard('hello'), false);
  assertEqual(copyTextToClipboard(''), false);

  assertEqual(formatBytes(0), '0 B');
  assertEqual(formatBytes(-5), '0 B');
  assertEqual(formatBytes(Number.NaN), '0 B');
  assertEqual(formatBytes(512), '512 B');
  assertEqual(formatBytes(2048), '2.0 KB');
  assertEqual(formatBytes(5 * 1024 * 1024), '5.00 MB');
  assertEqual(formatBytes(2.5 * 1024 * 1024 * 1024), '2.50 GB');

  assertEqual(formatMs(-1), '0.00 ms');
  assertEqual(formatMs(12.345), '12.35 ms');
  assertEqual(formatMs(1500), '1.50 s');

  assertEqual(formatThroughput(0, 100), '');
  assertEqual(formatThroughput(1024, 0), '');
  assertEqual(formatThroughput(50 * 1024 * 1024, 1000), '50 MB/s');
  assertEqual(formatThroughput(2 * 1024 * 1024 * 1024, 1000), '2.00 GB/s');

  const line = '1730340905123456789\t  ERROR timeout';
  assertEqual(skipLeadingNanoTimestampOffset(line), 22);
  const info = extractLeadingNanoTimestamp(line);
  assertOk(info !== null, 'expected leading nano timestamp');
  assertEqual(info.nsStr, '1730340905123456789');
  assertEqual(info.prefixLen, 22);
  assertEqual(info.restText, 'ERROR timeout');
  assertEqual(info.fullFormattedTime.length, 23);

  assertEqual(detectInlineEpochHint(line), info.fullFormattedTime);
  const secHint = detectInlineEpochHint('ts=1730340905 status=200');
  assertOk(
    secHint !== null && /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.000$/.test(secHint),
    'expected valid 10s epoch hint'
  );
  assertEqual(detectInlineEpochHint('order_id=9999999999999'), null);
}

function runHighlightSegmentTests(): void {
  assertEqual(compileTermMatcher('   ', false, true), null);

  const m1: CompiledTermMatcher | null = compileTermMatcher('lru_alpha', false, true);
  const m2 = compileTermMatcher('lru_alpha', false, true);
  assertOk(m1 !== null, 'expected compiled matcher');
  assertEqual(m1, m2, 'compileTermMatcher cache hit');

  const scopedWord = compileTermMatcher('$cw(Token)', false, true);
  assertOk(scopedWord !== null && scopedWord.isScoped && scopedWord.regex !== null, 'scoped $cw matcher');

  const invalidRegex = compileTermMatcher('$r([unclosed)', false, true);
  assertOk(invalidRegex !== null, 'invalid scoped regex returns matcher');
  assertEqual(invalidRegex.isScoped, true);
  assertEqual(invalidRegex.regex, null);

  // Promote m1 then fill 256 slots to verify LRU eviction of untouched entries while m1 stays cached
  const untouched = compileTermMatcher('lru_evict_target', false, true);
  assertOk(untouched !== null, 'expected untouched matcher');
  assertEqual(compileTermMatcher('lru_alpha', false, true), m1);
  for (let i = 0; i < 255; i++) {
    compileTermMatcher(`lru_filler_${i}`, false, true);
  }
  assertEqual(compileTermMatcher('lru_alpha', false, true), m1);
  const recomputed = compileTermMatcher('lru_evict_target', false, true);
  assertNotEqual(recomputed, untouched, 'expected oldest matcher evicted after 256 entries');

  // collectTermSpans
  const line = 'Error timeout on "api/v1" (x1 x2)';
  const getLower = () => line.toLowerCase();
  assertDeepEqual(collectTermSpans(line, getLower, 'timeout', false, true), [
    { start: 6, end: 13 },
  ]);
  assertDeepEqual(collectTermSpans(line, getLower, '"api/v1"', false, true), [
    { start: 17, end: 25 },
  ]);
  assertDeepEqual(
    collectTermSpans('Error timeout on api/v1', () => 'error timeout on api/v1', '"api/v1"', false, true),
    [{ start: 17, end: 23 }]
  );
  assertDeepEqual(collectTermSpans('abc', () => 'abc', 'a*', true, true), [{ start: 0, end: 1 }]);

  // getCachedHighlightSegments WeakMap + leading nanosecond stripping
  const hit: HitItem = {
    file: 'logs/app.log',
    line: 12,
    col: 1,
    text: '1730340905123456789 ERROR downstream connection refused',
    spans: [{ start: 20, end: 25 }],
  };
  const keyA = 'c:ERROR\u0001540';
  const segs1 = getCachedHighlightSegments(hit, [], true, keyA, 'ERROR', false, 540);
  const segs2 = getCachedHighlightSegments(hit, [], true, keyA, 'ERROR', false, 540);
  assertEqual(segs1, segs2, 'WeakMap memoization hit');
  assertEqual(segs1[0]?.text, 'ERROR');
  assertEqual(segs1[0]?.kind, 'primary');
  assertEqual(segs1.map((s) => s.text).join('').includes('1730340905123456789'), false);

  const keyB = 'c:1730340905\u0001540';
  const segsKept = getCachedHighlightSegments(hit, [], true, keyB, '1730340905', false, 540);
  assertNotEqual(segsKept, segs1, 'cacheKey change recomputes');
  assertEqual(segsKept[0]?.text, '1730340905123456789 ');
  assertEqual(segsKept[0]?.kind, 'plain');

  const timeOnlyHit: HitItem = {
    file: 'logs/app.log',
    line: 13,
    col: 1,
    text: '1730340905123456789 INFO started',
    spans: [{ start: 0, end: 19 }],
  };
  const timeOnlySegs = getCachedHighlightSegments(timeOnlyHit, [], true, 'timeonly\u0001540', '', false, 540);
  assertEqual(timeOnlySegs.map((s) => s.text).join(''), 'INFO started');

  const prefixMatchHit: HitItem = {
    file: 'logs/app.log',
    line: 14,
    col: 1,
    text: '1730340905123456789 INFO started',
    spans: [{ start: 0, end: 10 }],
  };
  const prefixMatchSegs = getCachedHighlightSegments(prefixMatchHit, [], true, keyB, '1730340905', false, 540);
  assertEqual(prefixMatchSegs[0]?.text, '1730340905');
  assertEqual(prefixMatchSegs[0]?.kind, 'primary');
}

function runStructuredAnalyzerTests(): void {
  assertEqual(decodeHumanEscapes('plain ascii'), 'plain ascii');
  assertEqual(decodeHumanEscapes('a\\u4e2d%20b\\n\\t\x1b[32mok\x1b[0m'), 'a中 b\n  ok');
  assertEqual(decodeHumanEscapes('bad=%ZZ'), 'bad=%ZZ');

  const html = universalPrettyStructure(
    '<section><header><h1>Title</h1></header><div><span>Body</span></div></section>'
  );
  assertEqual(html.badge, 'HTML');
  assertOk(html.formatted.includes('\n  <header>'), 'expected indented HTML');

  assertEqual(formatContextRecordPretty('plain log line'), 'plain log line');
  assertOk(formatContextRecordPretty('{"k":1}').includes('\n'), 'expected formatted JSON');

  // 128-entry LRU cache check
  const kept = '{"id":"lru-keep","v":1}';
  const evicted = '{"id":"lru-evict","v":2}';
  const keptRes = analyzeStructuredLine(kept);
  const evictedRes = analyzeStructuredLine(evicted);
  assertEqual(analyzeStructuredLine(kept), keptRes, 'promote kept to MRU');
  for (let i = 0; i < 127; i++) {
    analyzeStructuredLine(`{"id":"fill-${i}"}`);
  }
  assertEqual(analyzeStructuredLine(kept), keptRes, 'kept remains in 128-entry LRU');
  assertNotEqual(analyzeStructuredLine(evicted), evictedRes, 'oldest entry evicted');

  // > 256KB bypasses LRU cache cleanly
  const hugeLine = 'x'.repeat(262_145);
  const huge1 = analyzeStructuredLine(hugeLine);
  const huge2 = analyzeStructuredLine(hugeLine);
  assertEqual(huge1.charCount, 262_145);
  assertNotEqual(huge1, huge2, 'oversized lines bypass LRU cache');
}

function runSyntaxHighlightTests(): void {
  assertEqual(syntaxKindToClass('plain'), '');
  assertEqual(syntaxKindToClass('log-warn'), 'syn-log-warn');
  assertEqual(syntaxKindToClass('timestamp'), 'syn-timestamp');

  const rustLine = "#[derive(Debug)]\nfn get<'a>(x: &'a str) -> Option<u64> { /* ok */ Some(0x1f) }";
  const spans: SyntaxSpan[] = tokenizeCodeSyntax(rustLine);
  assertOk(
    spans.some((s) => rustLine.slice(s.start, s.end) === '#[derive(Debug)]' && s.kind === 'builtin'),
    'Rust attribute token'
  );
  assertOk(
    spans.some((s) => rustLine.slice(s.start, s.end) === "'a" && s.kind === 'type'),
    'Rust lifetime token'
  );
  assertOk(
    spans.some((s) => rustLine.slice(s.start, s.end) === '/* ok */' && s.kind === 'comment'),
    'Block comment token'
  );
  assertOk(
    spans.some((s) => rustLine.slice(s.start, s.end) === '0x1f' && s.kind === 'number'),
    'Hex number token'
  );

  // Lines exceeding 16,384 chars keep full text with trailing plain span
  const overLimit = `const x = 1; ${'a '.repeat(9000)}`;
  const overSpans = tokenizeCodeSyntax(overLimit);
  assertEqual(overSpans[overSpans.length - 1]?.end, overLimit.length);
  assertEqual(overSpans[overSpans.length - 1]?.kind, 'plain');

  // Empty input fast path
  assertDeepEqual(highlightCodeWithMatches('', []), [
    { text: '', matchKind: 'plain', syntaxKind: 'plain' },
  ]);

  const matchSegs = buildHighlightSegments(rustLine, undefined, [], false, false, 'Option', false);
  const merged = highlightCodeWithMatches(rustLine, matchSegs);
  assertEqual(merged.map((s) => s.text).join(''), rustLine);
  assertOk(
    merged.some((s) => s.text === 'Option' && s.matchKind === 'primary' && s.syntaxKind === 'plain'),
    'Match segment preserves primary highlight over syntax'
  );
}

runSplitFilePathTests();
runFacadeCompatibilityTests();
runFormatTests();
runHighlightSegmentTests();
runStructuredAnalyzerTests();
runSyntaxHighlightTests();
