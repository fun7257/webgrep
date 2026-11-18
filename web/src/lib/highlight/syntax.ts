import { skipLeadingNanoTimestampOffset } from '../format.ts';
import type { HighlightSegment } from './segments.ts';

export type SyntaxTokenKind =
  | 'plain'
  | 'comment'
  | 'string'
  | 'keyword'
  | 'type'
  | 'builtin'
  | 'literal'
  | 'number'
  | 'function'
  | 'property'
  | 'punctuation'
  | 'timestamp'
  | 'url'
  | 'log-error'
  | 'log-warn'
  | 'log-info'
  | 'log-debug';

export interface CodeHighlightSegment {
  text: string;
  matchKind: HighlightSegment['kind'];
  syntaxKind: SyntaxTokenKind;
}

export interface SyntaxSpan {
  start: number;
  end: number;
  kind: SyntaxTokenKind;
}

/**
 * Maps a `SyntaxTokenKind` to its corresponding CSS token class (empty string for `'plain'`).
 */
export function syntaxKindToClass(kind: SyntaxTokenKind): string {
  return kind === 'plain' ? '' : `syn-${kind}`;
}

const MAX_SYNTAX_CHARS = 16_384;

const LOG_LEVEL_KEYS = new Set([
  'l',
  'level',
  'lvl',
  'severity',
  'loglevel',
  'log_level',
]);

function classifyLogLevel(raw: string): SyntaxTokenKind | null {
  switch (raw.toUpperCase()) {
    case 'ERROR':
    case 'FATAL':
    case 'PANIC':
    case 'CRIT':
    case 'CRITICAL':
    case 'SEVERE':
    case 'ERR':
      return 'log-error';
    case 'WARN':
    case 'WARNING':
      return 'log-warn';
    case 'INFO':
    case 'NOTICE':
      return 'log-info';
    case 'DEBUG':
    case 'TRACE':
      return 'log-debug';
    default:
      return null;
  }
}

const ISO_TIMESTAMP_RE =
  /^(?:\d{4}[-/]\d{2}[-/]\d{2}(?:[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d{1,9})?(?:Z|[+-]\d{2}:?\d{2})?)?|\d{2}:\d{2}:\d{2}(?:[.,]\d{1,9})?)$/;

const URL_TOKEN_RE = /^(?:https?|wss?|ftp|file|tcp|unix):\/\/[^\s"'<>)\],;]+/;

function onlySpacesBeforeOnLine(text: string, pos: number): boolean {
  for (let p = pos - 1; p >= 0; p--) {
    const c = text[p];
    if (c === '\n') return true;
    if (c !== ' ' && c !== '\t') return false;
  }
  return true;
}

function isLogfmtAssignAt(text: string, eqPos: number, start: number, prevChar: string): boolean {
  return (
    text[eqPos] === '=' &&
    text[eqPos + 1] !== '=' &&
    text[eqPos + 1] !== '>' &&
    (start === 0 || /[\s,;(\[{]/.test(prevChar))
  );
}

function isYamlKeyColonAt(text: string, colonPos: number, n: number, start: number): boolean {
  return (
    text[colonPos] === ':' &&
    text[colonPos + 1] !== ':' &&
    (colonPos + 1 === n ||
      text[colonPos + 1] === ' ' ||
      text[colonPos + 1] === '\t' ||
      text[colonPos + 1] === '\n') &&
    onlySpacesBeforeOnLine(text, start)
  );
}

const CODE_KEYWORDS = new Set([
  // Zig / Rust / C / C++ / Go
  'pub', 'fn', 'const', 'var', 'let', 'mut', 'return', 'if', 'else', 'for', 'while', 'loop',
  'switch', 'case', 'default', 'break', 'continue', 'defer', 'errdefer', 'try', 'catch',
  'orelse', 'comptime', 'inline', 'noinline', 'export', 'extern', 'packed', 'align',
  'linksection', 'callconv', 'suspend', 'resume', 'nosuspend', 'async', 'await',
  'struct', 'enum', 'union', 'error', 'opaque', 'test', 'usingnamespace', 'threadlocal',
  'volatile', 'allowzero', 'noalias', 'asm', 'unreachable', 'undefined',
  'impl', 'trait', 'use', 'mod', 'crate', 'where', 'ref', 'move', 'unsafe', 'dyn', 'type',
  'match', 'package', 'import', 'func', 'chan', 'go', 'select', 'fallthrough', 'range',
  'sizeof', 'typedef', 'static', 'register', 'auto', 'goto', 'namespace', 'template',
  'typename', 'virtual', 'override', 'final', 'public', 'private', 'protected', 'friend',
  // TS / JS / Python / Java / SQL
  'function', 'class', 'interface', 'extends', 'implements', 'new', 'typeof', 'instanceof',
  'in', 'of', 'from', 'as', 'yield', 'delete', 'void', 'throw', 'finally', 'debugger',
  'def', 'elif', 'except', 'lambda', 'pass', 'raise', 'with', 'global', 'nonlocal',
  'and', 'or', 'not', 'is', 'assert', 'del',
]);

const SQL_DOCKER_KEYWORDS = new Set([
  'SELECT', 'FROM', 'WHERE', 'JOIN', 'LEFT', 'RIGHT', 'INNER', 'OUTER', 'ON',
  'INSERT', 'INTO', 'VALUES', 'UPDATE', 'SET', 'DELETE', 'CREATE', 'ALTER', 'DROP',
  'TABLE', 'INDEX', 'ORDER', 'GROUP', 'BY', 'HAVING', 'LIMIT', 'OFFSET', 'DISTINCT',
  'UNION', 'ALL', 'AS', 'AND', 'OR', 'NOT', 'IS',
  'RUN', 'CMD', 'COPY', 'ADD', 'ENV', 'ARG', 'EXPOSE', 'WORKDIR', 'ENTRYPOINT',
  'USER', 'LABEL', 'VOLUME',
]);

const HTTP_METHODS = new Set(['GET', 'POST', 'PUT', 'PATCH', 'HEAD', 'OPTIONS']);

const CODE_TYPES = new Set([
  'u8', 'u16', 'u32', 'u64', 'u128', 'usize', 'i8', 'i16', 'i32', 'i64', 'i128', 'isize',
  'c_short', 'c_ushort', 'c_int', 'c_uint', 'c_long', 'c_ulong', 'c_longlong', 'c_ulonglong',
  'c_char', 'c_void', 'f16', 'f32', 'f64', 'f80', 'f128', 'bool', 'void', 'noreturn',
  'anyerror', 'anytype', 'anyopaque', 'anyframe', 'comptime_int', 'comptime_float',
  'string', 'number', 'boolean', 'bigint', 'symbol', 'unknown', 'never', 'any', 'object',
  'int', 'float', 'double', 'char', 'short', 'long', 'unsigned', 'signed', 'size_t', 'ssize_t',
  'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t', 'int8_t', 'int16_t', 'int32_t', 'int64_t',
  'uintptr_t', 'intptr_t', 'byte', 'rune', 'error',
  'String', 'Vec', 'Option', 'Result', 'Box', 'Arc', 'Rc', 'Cell', 'RefCell', 'Self',
  'Array', 'Map', 'Set', 'WeakMap', 'WeakSet', 'Promise', 'Record', 'Partial', 'Readonly',
]);

const CODE_LITERALS = new Set([
  'true', 'false', 'null', 'undefined', 'nil', 'None', 'True', 'False', 'NaN', 'Infinity',
  'self', 'this', 'super', 'Some', 'Ok', 'Err',
]);

/**
 * Single-pass lexical tokenizer covering common programming languages, JSON/JSONL,
 * logfmt, YAML/TOML/INI, SQL, URLs, timestamps, and log severity levels.
 */
export function tokenizeCodeSyntax(text: string): SyntaxSpan[] {
  const spans: SyntaxSpan[] = [];
  const fullLen = text.length;
  const n = Math.min(fullLen, MAX_SYNTAX_CHARS);
  let i = 0;
  let lastPropertyKeyLower = '';

  const pushSpan = (start: number, end: number, kind: SyntaxTokenKind) => {
    if (end <= start) return;
    const prev = spans[spans.length - 1];
    if (prev && prev.kind === kind && prev.end === start) {
      prev.end = end;
    } else {
      spans.push({ start, end, kind });
    }
  };

  // Detect leading 19-digit Unix nanosecond timestamp (`<ns> <payload>`)
  const nanoRest = skipLeadingNanoTimestampOffset(text);
  if (nanoRest > 0 && nanoRest <= n) {
    pushSpan(0, 19, 'timestamp');
    pushSpan(19, nanoRest, 'plain');
    i = nanoRest;
  }

  while (i < n) {
    const ch = text[i];
    const next = i + 1 < n ? text[i + 1] : '';

    // 1. Whitespace
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') {
      const start = i;
      let sawNewline = false;
      while (
        i < n &&
        (text[i] === ' ' || text[i] === '\t' || text[i] === '\n' || text[i] === '\r')
      ) {
        if (text[i] === '\n') sawNewline = true;
        i++;
      }
      if (sawNewline) lastPropertyKeyLower = '';
      pushSpan(start, i, 'plain');
      continue;
    }

    // 2. Comments (`//` outside `://` URLs, `/*...*/`, `<!--...-->`, SQL `-- ...`, INI `;...`, `#...`)
    if (ch === '/' && next === '/' && (i === 0 || text[i - 1] !== ':')) {
      const start = i;
      while (i < n && text[i] !== '\n') i++;
      lastPropertyKeyLower = '';
      pushSpan(start, i, 'comment');
      continue;
    }
    if (ch === '/' && next === '*') {
      const start = i;
      i += 2;
      while (i < n && !(text[i] === '*' && text[i + 1] === '/')) i++;
      if (i < n) i += 2;
      lastPropertyKeyLower = '';
      pushSpan(start, Math.min(i, n), 'comment');
      continue;
    }
    if (ch === '<' && text.slice(i, i + 4) === '<!--') {
      const start = i;
      i += 4;
      while (i < n && text.slice(i, i + 3) !== '-->') i++;
      if (i < n) i += 3;
      lastPropertyKeyLower = '';
      pushSpan(start, Math.min(i, n), 'comment');
      continue;
    }
    if (
      ch === '-' &&
      next === '-' &&
      (i + 2 === n || text[i + 2] === ' ' || text[i + 2] === '\t') &&
      (i === 0 || text[i - 1] === ' ' || text[i - 1] === '\t' || text[i - 1] === '\n')
    ) {
      const start = i;
      while (i < n && text[i] !== '\n') i++;
      lastPropertyKeyLower = '';
      pushSpan(start, i, 'comment');
      continue;
    }
    if (ch === ';' && (i === 0 || text[i - 1] === '\n')) {
      const start = i;
      while (i < n && text[i] !== '\n') i++;
      lastPropertyKeyLower = '';
      pushSpan(start, i, 'comment');
      continue;
    }

    // 2a. TOML / INI `[section]` & Unified diff `@@ -a,b +c,d @@` at start of line
    if (ch === '[' && (i === 0 || text[i - 1] === '\n')) {
      const secMatch = /^\[([a-zA-Z_][a-zA-Z0-9_.-]*)\](?=\s|$)/.exec(text.slice(i, i + 64));
      if (secMatch && classifyLogLevel(secMatch[1]) === null) {
        const start = i;
        i += secMatch[0].length;
        lastPropertyKeyLower = '';
        pushSpan(start, i, 'builtin');
        continue;
      }
    }
    if (ch === '@' && next === '@' && (i === 0 || text[i - 1] === '\n')) {
      const hunkMatch = /^@@\s+-[0-9,]+\s+\+[0-9,]+\s+@@/.exec(text.slice(i, i + 48));
      if (hunkMatch) {
        const start = i;
        i += hunkMatch[0].length;
        lastPropertyKeyLower = '';
        pushSpan(start, i, 'builtin');
        continue;
      }
    }

    // 2b. Rust attributes (`#[derive(...)]`, `#![allow(...)]`) -> highlight as builtin
    if (ch === '#' && (next === '[' || (next === '!' && text[i + 2] === '['))) {
      const start = i;
      i += next === '!' ? 3 : 2;
      let depth = 1;
      while (i < n && depth > 0 && text[i] !== '\n') {
        if (text[i] === '[') depth++;
        else if (text[i] === ']') depth--;
        i++;
      }
      lastPropertyKeyLower = '';
      pushSpan(start, i, 'builtin');
      continue;
    }

    if (
      ch === '#' &&
      (i === 0 || text[i - 1] === ' ' || text[i - 1] === '\t' || text[i - 1] === '\n') &&
      !/^#(?:include|define|ifdef|ifndef|endif|pragma|elif|else|error|if)\b/.test(text.slice(i))
    ) {
      const start = i;
      while (i < n && text[i] !== '\n') i++;
      lastPropertyKeyLower = '';
      pushSpan(start, i, 'comment');
      continue;
    }

    // 2c. Apostrophes / Rust lifetimes / Strings
    if (ch === "'" && i > 0 && /[a-zA-Z0-9]/.test(text[i - 1])) {
      lastPropertyKeyLower = '';
      pushSpan(i, i + 1, 'punctuation');
      i++;
      continue;
    }
    if (ch === "'" && /^'[a-zA-Z_][a-zA-Z0-9_]*(?!')/.test(text.slice(i, i + 32))) {
      const start = i;
      i++;
      while (i < n && /[a-zA-Z0-9_]/.test(text[i])) i++;
      lastPropertyKeyLower = '';
      pushSpan(start, i, 'type');
      continue;
    }

    // 3. String literals, JSON keys, and semantic JSON string values (timestamps / levels / URLs)
    if (ch === '"' || ch === "'" || ch === '`') {
      const quote = ch;
      const start = i;
      i++;
      while (i < n) {
        const c = text[i];
        if (c === '\\') {
          i = Math.min(n, i + 2);
          continue;
        }
        if (c === quote) {
          i++;
          break;
        }
        if (c === '\n' && quote !== '`') break;
        i++;
      }
      const hasClosing = i > start + 1 && text[i - 1] === quote;
      let lookahead = i;
      while (lookahead < n && (text[lookahead] === ' ' || text[lookahead] === '\t')) {
        lookahead++;
      }
      const isJsonKey =
        quote === '"' &&
        hasClosing &&
        lookahead < n &&
        text[lookahead] === ':' &&
        text[lookahead + 1] !== ':';

      if (isJsonKey) {
        lastPropertyKeyLower = text.slice(start + 1, i - 1).toLowerCase();
        pushSpan(start, i, 'property');
      } else {
        const inner = text.slice(start + 1, hasClosing ? i - 1 : i);
        let kind: SyntaxTokenKind = 'string';
        if (lastPropertyKeyLower && LOG_LEVEL_KEYS.has(lastPropertyKeyLower)) {
          kind = classifyLogLevel(inner) ?? 'string';
        } else if (inner.length >= 8 && inner.length <= 40 && ISO_TIMESTAMP_RE.test(inner)) {
          kind = 'timestamp';
        } else if (URL_TOKEN_RE.test(inner) && !/\s/.test(inner)) {
          kind = 'url';
        }
        lastPropertyKeyLower = '';
        pushSpan(start, i, kind);
      }
      continue;
    }

    // 4. Zig `@builtin` / decorators / C preprocessor `#include`
    if (
      (ch === '@' || ch === '#') &&
      i + 1 < n &&
      /[a-zA-Z_]/.test(text[i + 1])
    ) {
      const start = i;
      i++;
      while (i < n && /[a-zA-Z0-9_]/.test(text[i])) i++;
      lastPropertyKeyLower = '';
      pushSpan(start, i, 'builtin');
      continue;
    }

    // 5. HTML / JSX tags (`<div`, `</span`)
    if (ch === '<' && (next === '/' || /[a-zA-Z]/.test(next))) {
      const start = i;
      i += next === '/' ? 2 : 1;
      while (i < n && /[a-zA-Z0-9:_-]/.test(text[i])) i++;
      lastPropertyKeyLower = '';
      pushSpan(start, i, 'builtin');
      continue;
    }

    // 6. Unquoted timestamps, IPv4(:port), and numbers
    if (
      (ch >= '0' && ch <= '9') ||
      (ch === '.' && next >= '0' && next <= '9' && (i === 0 || !/[a-zA-Z0-9_]/.test(text[i - 1])))
    ) {
      const canMatchMultiToken =
        ch >= '0' && ch <= '9' && (i === 0 || !/[a-zA-Z0-9_]/.test(text[i - 1]));
      if (canMatchMultiToken) {
        if (i + 4 < n && (text[i + 4] === '-' || text[i + 4] === '/')) {
          const tsMatch =
            /^\d{4}[-/]\d{2}[-/]\d{2}(?:[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d{1,9})?(?:Z|[+-]\d{2}:?\d{2})?)?/.exec(
              text.slice(i, i + 40)
            );
          if (tsMatch) {
            const start = i;
            i += tsMatch[0].length;
            lastPropertyKeyLower = '';
            pushSpan(start, i, 'timestamp');
            continue;
          }
        }
        if (i + 5 < n && text[i + 2] === ':' && text[i + 5] === ':') {
          const timeMatch = /^\d{2}:\d{2}:\d{2}(?:[.,]\d{1,9})?(?![0-9:])/.exec(
            text.slice(i, i + 24)
          );
          if (timeMatch) {
            const start = i;
            i += timeMatch[0].length;
            lastPropertyKeyLower = '';
            pushSpan(start, i, 'timestamp');
            continue;
          }
        }
        if (
          (i + 1 < n && text[i + 1] === '.') ||
          (i + 2 < n && text[i + 2] === '.') ||
          (i + 3 < n && text[i + 3] === '.')
        ) {
          const ipMatch = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?::\d{1,5})?(?![0-9.])/.exec(
            text.slice(i, i + 24)
          );
          if (ipMatch) {
            const start = i;
            i += ipMatch[0].length;
            lastPropertyKeyLower = '';
            pushSpan(start, i, 'number');
            continue;
          }
        }
      }

      const start = i;
      if (ch === '0' && (next === 'x' || next === 'X' || next === 'b' || next === 'B' || next === 'o' || next === 'O')) {
        i += 2;
        while (i < n && /[0-9a-fA-F_]/.test(text[i])) i++;
      } else {
        while (i < n && /[0-9_]/.test(text[i])) i++;
        if (i < n && text[i] === '.' && text[i + 1] !== '.') {
          i++;
          while (i < n && /[0-9_]/.test(text[i])) i++;
        }
        if (i < n && (text[i] === 'e' || text[i] === 'E')) {
          i++;
          if (i < n && (text[i] === '+' || text[i] === '-')) i++;
          while (i < n && /[0-9_]/.test(text[i])) i++;
        }
      }
      // Optional numeric type/unit suffix (e.g. `u64`, `usize`, `ms`)
      while (i < n && /[a-zA-Z0-9_]/.test(text[i])) i++;
      lastPropertyKeyLower = '';
      pushSpan(start, i, 'number');
      continue;
    }

    // 7. URLs, Hyphen/Dot Config Keys, Log Levels, Keywords, Types, Functions, Properties
    if (/[a-zA-Z_$]/.test(ch)) {
      if (
        (ch === 'h' || ch === 'w' || ch === 'f' || ch === 't' || ch === 'u') &&
        text.includes('://', i)
      ) {
        const urlMatch = URL_TOKEN_RE.exec(text.slice(i, i + 512));
        if (urlMatch) {
          let rawUrl = urlMatch[0];
          while (rawUrl.endsWith('.')) rawUrl = rawUrl.slice(0, -1);
          const start = i;
          i += rawUrl.length;
          lastPropertyKeyLower = '';
          pushSpan(start, i, 'url');
          continue;
        }
      }

      const start = i;
      const prevChar = start > 0 ? text[start - 1] : '';
      i++;
      while (i < n && /[a-zA-Z0-9_$]/.test(text[i])) i++;
      const word = text.slice(start, i);

      // Hyphenated / dotted logfmt or YAML keys (`x-request-id=1`, `content-type: ...`)
      if (i < n && (text[i] === '-' || text[i] === '.')) {
        let endKey = i;
        while (endKey < n && /[a-zA-Z0-9_.-]/.test(text[endKey])) endKey++;
        if (
          endKey > i &&
          (isLogfmtAssignAt(text, endKey, start, prevChar) ||
            isYamlKeyColonAt(text, endKey, n, start))
        ) {
          i = endKey;
          lastPropertyKeyLower = text.slice(start, endKey).toLowerCase();
          pushSpan(start, i, 'property');
          continue;
        }
      }

      // Unquoted log-level value right after `level=WARN`
      if (lastPropertyKeyLower && LOG_LEVEL_KEYS.has(lastPropertyKeyLower) && prevChar === '=') {
        const lvlKind = classifyLogLevel(word);
        lastPropertyKeyLower = '';
        if (lvlKind) {
          pushSpan(start, i, lvlKind);
          continue;
        }
      }

      // Tight logfmt / env key (`status=200`, `PORT=8787`) or YAML key at start of line (`server:`)
      if (isLogfmtAssignAt(text, i, start, prevChar) || isYamlKeyColonAt(text, i, n, start)) {
        lastPropertyKeyLower = word.toLowerCase();
        pushSpan(start, i, 'property');
        continue;
      }

      lastPropertyKeyLower = '';

      let lookahead = i;
      while (lookahead < n && (text[lookahead] === ' ' || text[lookahead] === '\t')) {
        lookahead++;
      }
      const nextNonSpace = lookahead < n ? text[lookahead] : '';

      let kind: SyntaxTokenKind = 'plain';
      if (word.length >= 3 && word === word.toUpperCase()) {
        const lvlKind = classifyLogLevel(word);
        if (lvlKind) {
          kind = lvlKind;
        } else if (word === 'NULL') {
          kind = 'literal';
        } else if (SQL_DOCKER_KEYWORDS.has(word)) {
          kind = 'keyword';
        } else if (HTTP_METHODS.has(word)) {
          kind = 'builtin';
        }
      }
      if (kind === 'plain') {
        if (CODE_KEYWORDS.has(word)) {
          kind = 'keyword';
        } else if (CODE_LITERALS.has(word)) {
          kind = 'literal';
        } else if (CODE_TYPES.has(word)) {
          kind = 'type';
        } else if (nextNonSpace === '(' || (text[i] === '!' && text[i + 1] === '(')) {
          kind = 'function';
        } else if (/^[A-Z][a-zA-Z0-9_]*$/.test(word) && /[a-z]/.test(word)) {
          kind = 'type';
        } else if (
          prevChar === '.' ||
          (nextNonSpace === ':' && text[lookahead + 1] !== ':')
        ) {
          kind = 'property';
        }
      }

      pushSpan(start, i, kind);
      continue;
    }

    // 8. Punctuation & operators
    if (ch === ',' || ch === ';' || ch === '{' || ch === '}') {
      lastPropertyKeyLower = '';
    }
    const start = i;
    i++;
    pushSpan(start, i, 'punctuation');
  }

  if (n < fullLen) {
    pushSpan(n, fullLen, 'plain');
  }

  return spans;
}

/**
 * Merges code syntax highlighting tokens with search match segments (`primary`, `contains-0/1/2`)
 * so search hits stand out with `<mark>` while all surrounding code has crisp syntax highlighting.
 */
export function highlightCodeWithMatches(
  text: string,
  matchSegments: HighlightSegment[]
): CodeHighlightSegment[] {
  if (!text) return [{ text: '', matchKind: 'plain', syntaxKind: 'plain' }];

  const syntaxSpans = tokenizeCodeSyntax(text);
  const out: CodeHighlightSegment[] = [];

  // Map matchSegments into [start, end, matchKind] ranges over `text`
  let cursor = 0;
  let synIdx = 0;

  for (const mSeg of matchSegments) {
    const segLen = mSeg.text.length;
    if (segLen === 0) continue;
    const segStart = cursor;
    const segEnd = cursor + segLen;
    cursor = segEnd;

    if (mSeg.kind !== 'plain') {
      out.push({
        text: mSeg.text,
        matchKind: mSeg.kind,
        syntaxKind: 'plain',
      });
      continue;
    }

    // Slice this plain segment across `syntaxSpans`
    let pos = segStart;
    while (pos < segEnd) {
      while (synIdx < syntaxSpans.length && syntaxSpans[synIdx].end <= pos) {
        synIdx++;
      }
      const syn = syntaxSpans[synIdx];
      if (!syn || syn.start > pos) {
        const nextBound = syn ? Math.min(segEnd, syn.start) : segEnd;
        out.push({
          text: text.slice(pos, nextBound),
          matchKind: 'plain',
          syntaxKind: 'plain',
        });
        pos = nextBound;
      } else {
        const sliceEnd = Math.min(segEnd, syn.end);
        out.push({
          text: text.slice(pos, sliceEnd),
          matchKind: 'plain',
          syntaxKind: syn.kind,
        });
        pos = sliceEnd;
      }
    }
  }

  return out;
}
