/**
 * Query language — three operators plus two qualifiers:
 *
 *   a b c        every term must appear (AND, order-independent)
 *   -x           exclude results containing x
 *   "a b"        exact phrase (spaces & symbols kept); `"-O3"` searches a literal leading dash
 *   in:x         where to search: a data source name, a file pattern (`in:*.rs`, `in:.rs`), or a path
 *                (`in:src/`, `in:server`); `-in:x` excludes, `in:a,b` means a OR b
 *   time:x       when: `time:15m`, `time:today`, `time:10:00..10:30`, `time:2026-10-31`
 *   /re/         regular expression for that term only
 *   Smart case:  all-lowercase terms ignore case, any uppercase letter makes that term case-sensitive.
 *
 * Legacy `@source`, `$()`, `$-()`, `$@()`, `$t()`, `$r()`, `$c()`, `$w()` are still understood but no longer
 * advertised. Terms are translated into backend wire terms (`$c(…)`, `$r(…)`, `$rc(…)`), data sources into
 * `globs` and file/path patterns into `fileGlobs`, so the server needs no knowledge of the surface syntax.
 */

export interface ParsedDollarFlags {
  regex: boolean;
  caseSensitive: boolean;
  wholeWord: boolean;
}

export interface ClassifiedQueryToken {
  /** Exact token text as typed (used to strip / toggle it inside the input string). */
  raw: string;
  kind: 'primary' | 'include' | 'exclude' | 'file' | 'exclude-file' | 'flag';
  /** Human-facing label (`"a b"`, `/re/`, `word`, source name, `*.rs`, `$t(15m)`). */
  value: string;
}

export interface ParsedSearchQuery {
  /** Wire value of the first positive term. */
  primaryPattern: string;
  /** Raw text of the first positive term as typed. */
  primaryRaw: string;
  contains: string[];
  excludes: string[];
  /** Data source names (`!` prefix = exclude). */
  globs: string[];
  /** File / path patterns (`!` prefix = exclude). */
  fileGlobs: string[];
  modifiers: ClassifiedQueryToken[];
  hasScopedRegex: boolean;
  hasScopedCase: boolean;
  hasScopedWord: boolean;
  hasScopedTime: boolean;
  timeStartMs: number;
  timeEndMs: number;
}

function parseSingleTimePoint(expr: string, nowMs: number, isEnd: boolean): number | null {
  const s = expr.trim();
  if (!s) return null;

  // 1. Relative duration: 30s, 5m, 15m, 1h, 6h, 24h, 7d, 2w
  const rel = /^(\d+(?:\.\d+)?)\s*(s|sec|m|min|h|hr|d|day|w)$/i.exec(s);
  if (rel) {
    const num = Number(rel[1]);
    const unit = rel[2].toLowerCase();
    const mult =
      unit.startsWith('s')
        ? 1000
        : unit.startsWith('m')
          ? 60_000
          : unit.startsWith('h')
            ? 3_600_000
            : unit.startsWith('d')
              ? 86_400_000
              : 7 * 86_400_000;
    return Math.max(1, Math.round(nowMs - num * mult));
  }

  // 2. Time-of-day only (`HH:MM` or `HH:MM:SS`) -> anchored to today in local time
  const tod = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(s);
  if (tod) {
    const d = new Date(nowMs);
    const hh = Number(tod[1]);
    const mm = Number(tod[2]);
    const ss = tod[3] !== undefined ? Number(tod[3]) : isEnd ? 59 : 0;
    const ms = tod[3] !== undefined ? (isEnd ? 999 : 0) : isEnd ? 999 : 0;
    d.setHours(hh, mm, ss, ms);
    return d.getTime();
  }

  // 3. Date-only (`YYYY-MM-DD`)
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) {
    const iso = isEnd ? `${s}T23:59:59.999` : `${s}T00:00:00.000`;
    const parsed = Date.parse(iso);
    return Number.isFinite(parsed) ? parsed : null;
  }

  // 4. Full ISO date-time or epoch milliseconds / seconds
  if (/^\d{10,19}$/.test(s)) {
    if (s.length >= 16) return Math.floor(Number(s.slice(0, 13)));
    if (s.length >= 13) return Number(s.slice(0, 13));
    return Number(s) * 1000;
  }

  const normalizedIso = s.includes(' ') && !s.includes('T') ? s.replace(' ', 'T') : s;
  const parsed = Date.parse(normalizedIso);
  return Number.isFinite(parsed) ? parsed : null;
}

export function parseTimeModifierSpec(
  rawSpec: string,
  nowMs = Date.now()
): { startMs: number; endMs: number } | null {
  const clean = rawSpec.trim();
  if (!clean) return null;

  // Named days: `today`, `yesterday` (local time)
  const named = clean.toLowerCase();
  if (named === 'today' || named === '今天' || named === 'yesterday' || named === '昨天') {
    const d = new Date(nowMs);
    d.setHours(0, 0, 0, 0);
    if (named === 'today' || named === '今天') return { startMs: d.getTime(), endMs: 0 };
    const end = d.getTime() - 1;
    d.setDate(d.getDate() - 1);
    return { startMs: d.getTime(), endMs: end };
  }

  // Range syntax: `A..B` or `A~B`
  const rangeSep = clean.includes('..') ? '..' : clean.includes('~') ? '~' : null;
  if (rangeSep) {
    const [leftRaw, rightRaw] = clean.split(rangeSep, 2);
    const startMs = leftRaw.trim() ? parseSingleTimePoint(leftRaw, nowMs, false) : 0;
    const endMs = rightRaw.trim() ? parseSingleTimePoint(rightRaw, nowMs, true) : 0;
    if (startMs === null || endMs === null) return null;
    if (startMs === 0 && endMs === 0) return null;
    if (startMs > 0 && endMs > 0 && startMs > endMs) {
      return { startMs: endMs, endMs: startMs };
    }
    return { startMs, endMs };
  }

  // Date-only `YYYY-MM-DD` covers the entire day `[00:00:00.000, 23:59:59.999]`
  if (/^\d{4}-\d{2}-\d{2}$/.test(clean)) {
    const startMs = parseSingleTimePoint(clean, nowMs, false);
    const endMs = parseSingleTimePoint(clean, nowMs, true);
    if (startMs !== null && endMs !== null) {
      return { startMs, endMs };
    }
  }

  const startMs = parseSingleTimePoint(clean, nowMs, false);
  if (startMs === null) return null;
  return { startMs, endMs: 0 };
}

export function parseDollarFlags(raw: string): ParsedDollarFlags | null {
  if (!raw.startsWith('$') || raw.length < 2) return null;
  const body = raw.slice(1).toLowerCase();

  if (body === 'r' || body === 're' || body === 'regex' || body === '.*') {
    return { regex: true, caseSensitive: false, wholeWord: false };
  }
  if (body === 'c' || body === 'case' || body === 'aa' || body === 's') {
    return { regex: false, caseSensitive: true, wholeWord: false };
  }
  if (body === 'w' || body === 'word' || body === 'b' || body === '\\b') {
    return { regex: false, caseSensitive: false, wholeWord: true };
  }
  // Support combined shorthand flags such as $rc, $rw, $cw, $rcw (in any order)
  if (body.length >= 2 && body.length <= 3 && /^[rcw]+$/.test(body)) {
    return {
      regex: body.includes('r'),
      caseSensitive: body.includes('c'),
      wholeWord: body.includes('w'),
    };
  }

  return null;
}

export interface KnownSourceRef {
  id?: string;
  name: string;
}

const REGEX_META = /[\\.*+?^$()[\]{}|]/;
const LEGACY_FUNC_HEAD = /^(?:(\$[-!]?@(?:)|\b)|([-+!]?\$[a-zA-Z.*]*|\$[-!]?))\(/;

function escapeRegex(s: string): string {
  return s.replace(/[\\.*+?^${}()|[\]]/g, '\\$&');
}

/** Smart case: an ASCII uppercase letter (outside regex escapes such as `\D`) makes a term case-sensitive. */
function hasSmartUpper(s: string, isRegex: boolean): boolean {
  return /[A-Z]/.test(isRegex ? s.replace(/\\./g, '') : s);
}

/** Wire form of a literal term (smart case → `$c(…)`). */
function wireLiteral(value: string, forceCase = false, wholeWord = false): string {
  const cased = forceCase || hasSmartUpper(value, false);
  const flags = `${cased ? 'c' : ''}${wholeWord ? 'w' : ''}`;
  // Literal text that itself looks like a `$x(` modifier is regex-escaped so the server never reinterprets it.
  if (/^\$[a-zA-Z.*]*\(/.test(value)) {
    return `$r${flags}(${escapeRegex(value)})`;
  }
  return flags ? `$${flags}(${value})` : value;
}

/** Wire form of a regex term (smart case → `$rc(…)`). */
function wireRegex(body: string, forceCase = false, wholeWord = false): string {
  const cased = forceCase || hasSmartUpper(body, true);
  return `$r${cased ? 'c' : ''}${wholeWord ? 'w' : ''}(${body})`;
}

interface RawToken {
  raw: string;
  kind: 'legacy' | 'phrase' | 'regex' | 'word';
  neg: boolean;
  body: string;
}

/** Returns the end index of a legacy `$x(…)` function token starting at `i`, or -1. */
function scanLegacyFunc(raw: string, i: number): number {
  const m = LEGACY_FUNC_HEAD.exec(raw.slice(i));
  if (!m) return -1;
  const head = m[0].slice(0, -1);
  const norm = /^[-+!]/.test(head) ? `$${head[0]}${head.slice(2)}` : head;
  const body = norm.slice(1).toLowerCase();
  const valid =
    ['', '-', '!', '@', '-@', '!@', 't', 'time'].includes(body) ||
    parseDollarFlags(`$${body.replace(/^[-!+]/, '')}`) !== null;
  if (!valid) return -1;

  const n = raw.length;
  const isRegexLike = body.includes('r') || body.includes('.*');
  let depth = 1;
  let p = i + m[0].length;
  let inClass = false;
  let classStart = -1;
  while (p < n && depth > 0) {
    const c = raw[p];
    if (c === '\\' && p + 1 < n) {
      p += 2;
      continue;
    }
    if (isRegexLike && inClass) {
      if (
        c === ']' &&
        p > classStart + 1 &&
        !(p === classStart + 2 && (raw[classStart + 1] === '^' || raw[classStart + 1] === '!'))
      ) {
        inClass = false;
      }
      p++;
      continue;
    }
    if (isRegexLike && c === '[') {
      inClass = true;
      classStart = p;
    } else if (c === '(') {
      depth++;
    } else if (c === ')') {
      depth--;
    }
    p++;
  }
  return p;
}

/** Plain word: ends at whitespace; balanced `(...)` (e.g. `@Vector(64, u8)`) and `\ ` stay inside. */
function scanWord(raw: string, i: number): number {
  const n = raw.length;
  let depth = 0;
  while (i < n) {
    const ch = raw[i];
    if (ch === '\\' && i + 1 < n && /\s/.test(raw[i + 1])) {
      i += 2;
      continue;
    }
    if (ch === '(' && hasClosingParen(raw, i)) {
      depth++;
    } else if (ch === ')' && depth > 0) {
      depth--;
    } else if (/\s/.test(ch) && depth === 0) {
      break;
    }
    i++;
  }
  return i;
}

function hasClosingParen(raw: string, open: number): boolean {
  let depth = 0;
  for (let p = open; p < raw.length; p++) {
    const c = raw[p];
    if (c === '\\' && p + 1 < raw.length) {
      p++;
      continue;
    }
    if (c === '(') depth++;
    else if (c === ')' && --depth <= 0) return true;
  }
  return false;
}

/**
 * `/re/` scanner starting at the opening slash `j`. A regex must contain a regex metacharacter, so plain
 * paths such as `/api/` or `/usr/lib` stay literal. While typing, an unclosed `/re` (up to the next
 * whitespace, without inner `/`) is already treated as a regex.
 */
function scanRegex(raw: string, j: number): { end: number; body: string } | null {
  const n = raw.length;
  for (let k = j + 1; k < n; k++) {
    if (raw[k] === '\\' && k + 1 < n) {
      k++;
      continue;
    }
    if (raw[k] === '/' && (k + 1 >= n || /\s/.test(raw[k + 1]))) {
      const body = raw.slice(j + 1, k);
      return body && REGEX_META.test(body) ? { end: k + 1, body } : null;
    }
  }
  let e = j + 1;
  while (e < n && !/\s/.test(raw[e])) e++;
  const body = raw.slice(j + 1, e);
  if (body && !body.includes('/') && REGEX_META.test(body)) return { end: e, body };
  return null;
}

function tokenize(raw: string): RawToken[] {
  const out: RawToken[] = [];
  const n = raw.length;
  let i = 0;
  while (i < n) {
    while (i < n && /\s/.test(raw[i])) i++;
    if (i >= n) break;
    const start = i;

    const legacyEnd = scanLegacyFunc(raw, i);
    if (legacyEnd > i) {
      out.push({ raw: raw.slice(start, legacyEnd), kind: 'legacy', neg: false, body: '' });
      i = legacyEnd;
      continue;
    }

    const neg = raw[i] === '-' && (raw[i + 1] === '"' || raw[i + 1] === '/');
    const j = neg ? i + 1 : i;

    if (raw[j] === '"') {
      let k = j + 1;
      let closed = false;
      while (k < n) {
        if (raw[k] === '\\' && k + 1 < n) {
          k += 2;
          continue;
        }
        if (raw[k] === '"') {
          closed = true;
          break;
        }
        k++;
      }
      const unescape = (s: string) => s.replace(/\\(["\\])/g, '$1');
      if (!closed) {
        // Still typing the phrase: everything after the quote belongs to it.
        out.push({ raw: raw.slice(start), kind: 'phrase', neg, body: unescape(raw.slice(j + 1)) });
        break;
      }
      if (k + 1 >= n || /\s/.test(raw[k + 1])) {
        out.push({ raw: raw.slice(start, k + 1), kind: 'phrase', neg, body: unescape(raw.slice(j + 1, k)) });
        i = k + 1;
        continue;
      }
      // `"status":` — quotes are part of the text, fall through to a plain word.
    }

    if (raw[j] === '/') {
      const re = scanRegex(raw, j);
      if (re) {
        out.push({ raw: raw.slice(start, re.end), kind: 'regex', neg, body: re.body });
        i = re.end;
        continue;
      }
    }

    i = scanWord(raw, start);
    out.push({ raw: raw.slice(start, i), kind: 'word', neg: false, body: raw.slice(start, i) });
  }
  return out;
}

function splitList(val: string): string[] {
  const items: string[] = [];
  let cur = '';
  let brace = 0;
  for (const ch of val) {
    if (ch === '{') brace++;
    else if (ch === '}' && brace > 0) brace--;
    if (brace === 0 && ch === ',') {
      if (cur.trim()) items.push(cur.trim());
      cur = '';
    } else {
      cur += ch;
    }
  }
  if (cur.trim()) items.push(cur.trim());
  return items;
}

export function parseSearchQuery(
  raw: string,
  nowMs = Date.now(),
  knownSources: readonly (string | KnownSourceRef)[] = []
): ParsedSearchQuery {
  const sourceRefs = knownSources.map((s) =>
    typeof s === 'string' ? { id: '', name: s.toLowerCase() } : { id: (s.id ?? '').toLowerCase(), name: s.name.toLowerCase() }
  );
  const findSource = (name: string) => {
    const q = name.toLowerCase();
    return sourceRefs.find((s) => s.name === q || (s.id && s.id === q));
  };

  interface Term {
    raw: string;
    wire: string;
    label: string;
    /** Came from a bare `-word`; turned back into a literal search when there is no positive term. */
    fromMinus?: boolean;
  }
  const positives: Term[] = [];
  const negatives: Term[] = [];
  const globs: string[] = [];
  const fileGlobs: string[] = [];
  const scopeMods: ClassifiedQueryToken[] = [];
  let hasScopedRegex = false;
  let hasScopedCase = false;
  let hasScopedWord = false;
  let hasScopedTime = false;
  let timeStartMs = 0;
  let timeEndMs = 0;

  const addTerm = (neg: boolean, term: Term) => (neg ? negatives : positives).push(term);
  /**
   * `in:` value resolution (per comma-separated item):
   * 1. exact data source name / id     → `globs` (data source filter)
   * 2. `.rs`                           → `fileGlobs` `*.rs`
   * 3. anything else (`*.rs`, `src/`, `server`) → `fileGlobs` (glob, or path substring without wildcards)
   */
  const addScope = (rawTok: string, value: string, neg: boolean) => {
    let added = false;
    // The backend ANDs separate `globs` entries and ORs comma-separated names inside one entry,
    // so positive sources from one `in:a,b` token are joined into a single entry (a OR b).
    const orSources: string[] = [];
    for (const item of splitList(value)) {
      const clean = item.replace(/^[-!@]+/, '').trim();
      if (!clean) continue;
      const bang = neg || /^[-!]/.test(item) ? '!' : '';
      if (findSource(clean)) {
        if (bang) globs.push(`!${clean}`);
        else orSources.push(clean);
      } else if (/^\.[^/*?]+$/.test(clean)) {
        fileGlobs.push(`${bang}*${clean}`);
      } else {
        fileGlobs.push(`${bang}${clean}`);
      }
      added = true;
    }
    if (orSources.length > 0) globs.push(orSources.join(','));
    if (added) {
      scopeMods.push({ raw: rawTok, kind: neg ? 'exclude-file' : 'file', value: value.replace(/^[-!@]+/, '') });
    }
  };
  const addTime = (rawTok: string, spec: string) => {
    // Bare numbers (`time:1` while typing `time:15m`) would otherwise parse as a calendar year.
    if (/^\d{1,9}$/.test(spec.trim())) return;
    const tr = parseTimeModifierSpec(spec, nowMs);
    if (!tr) return;
    hasScopedTime = true;
    timeStartMs = tr.startMs;
    timeEndMs = tr.endMs;
    scopeMods.push({ raw: rawTok, kind: 'flag', value: spec.trim() });
  };

  for (const tok of tokenize(raw)) {
    if (tok.kind === 'phrase') {
      if (tok.body) addTerm(tok.neg, { raw: tok.raw, wire: wireLiteral(tok.body), label: `"${tok.body}"` });
      continue;
    }
    if (tok.kind === 'regex') {
      hasScopedRegex = true;
      addTerm(tok.neg, { raw: tok.raw, wire: wireRegex(tok.body), label: `/${tok.body}/` });
      continue;
    }
    if (tok.kind === 'legacy') {
      classifyLegacy(tok.raw);
      continue;
    }

    const w = tok.raw;
    // Bare operators while the user is still typing (`-`, `$`) are ignored.
    if (/^(?:-|\$[-!]?@?|\$(?:t|time)|[-+!]?\$[rcw]{0,3})$/i.test(w)) continue;

    // Qualifiers: `in:x` / `-in:x` (where) and `time:x` (when). Empty values are still being typed.
    const qual = /^(-?)(in|time):(.*)$/is.exec(w);
    if (qual) {
      const [, sign, key, value] = qual;
      if (key.toLowerCase() === 'in') {
        addScope(w, value, sign === '-');
      } else if (!sign) {
        addTime(w, value);
      }
      continue;
    }

    // Legacy `@source` / `-@source`: only an exact configured source name (`@Vector` stays literal).
    const legacyAt = /^(-?)@(.+)$/.exec(w);
    if (legacyAt && findSource(legacyAt[2])) {
      addScope(w, legacyAt[2], legacyAt[1] === '-');
      continue;
    }

    if (/^-[\p{L}\p{N}_]/u.test(w)) {
      const body = normalizeLiteral(w.slice(1));
      negatives.push({ raw: w, wire: wireLiteral(body), label: body, fromMinus: true });
      continue;
    }

    const value = normalizeLiteral(w);
    positives.push({ raw: w, wire: wireLiteral(value), label: value });
  }

  // `-O3` / `-v` typed on their own are searches, not exclusions.
  if (positives.length === 0 && negatives.some((t) => t.fromMinus)) {
    for (let k = negatives.length - 1; k >= 0; k--) {
      const t = negatives[k];
      if (!t.fromMinus) continue;
      negatives.splice(k, 1);
      const value = normalizeLiteral(t.raw);
      positives.unshift({ raw: t.raw, wire: wireLiteral(value), label: value });
    }
  }

  const modifiers: ClassifiedQueryToken[] = [...scopeMods];
  for (let k = 1; k < positives.length; k++) {
    modifiers.push({ raw: positives[k].raw, kind: 'include', value: positives[k].label });
  }
  for (const t of negatives) {
    modifiers.push({ raw: t.raw, kind: 'exclude', value: t.label });
  }

  return {
    primaryPattern: positives[0]?.wire ?? '',
    primaryRaw: positives[0]?.raw ?? '',
    contains: positives.slice(1).map((t) => t.wire),
    excludes: negatives.map((t) => t.wire),
    globs,
    fileGlobs,
    modifiers,
    hasScopedRegex,
    hasScopedCase,
    hasScopedWord,
    hasScopedTime,
    timeStartMs,
    timeEndMs,
  };

  function normalizeLiteral(s: string): string {
    const out = s.replace(/\\(\s)/g, '$1');
    return out.startsWith('\\$') ? out.slice(1) : out;
  }

  /** Legacy `$()` / `$-()` / `$@()` / `$t()` / `$r()` / `$c()` / `$w()` tokens. */
  function classifyLegacy(tokRaw: string) {
    const phrase = /^\$\(([\s\S]*?)\)?$/.exec(tokRaw);
    if (phrase) {
      if (phrase[1]) addTerm(false, { raw: tokRaw, wire: wireLiteral(phrase[1]), label: `"${phrase[1]}"` });
      return;
    }
    const exclude = /^\$[-!]\(([\s\S]*?)\)?$/.exec(tokRaw);
    if (exclude) {
      if (exclude[1]) addTerm(true, { raw: tokRaw, wire: wireLiteral(exclude[1]), label: exclude[1] });
      return;
    }
    const source = /^(?:\$([-!]?)@|([-!])\$@)\(([\s\S]*?)\)?$/.exec(tokRaw);
    if (source) {
      const value = source[3].trim();
      const neg = Boolean(source[1] || source[2]) || /^[-!]/.test(value);
      if (value.replace(/^[-!@]+/, '')) addScope(tokRaw, value, neg);
      return;
    }
    const time = /^[-+!]?\$(?:t|time)\(([\s\S]*?)\)?$/i.exec(tokRaw)?.[1];
    if (time !== undefined) {
      addTime(tokRaw, time);
      return;
    }
    const mode = /^(?:\$([-+!]?)([a-zA-Z.*]+)|([-+!]?)\$([a-zA-Z.*]+))\(([\s\S]*?)\)?$/.exec(tokRaw);
    if (mode) {
      const sign = mode[1] || mode[3] || '';
      const df = parseDollarFlags(`$${mode[2] || mode[4] || ''}`);
      const body = mode[5];
      if (!df || !body) return;
      if (df.regex) hasScopedRegex = true;
      if (df.caseSensitive) hasScopedCase = true;
      if (df.wholeWord) hasScopedWord = true;
      const wire = df.regex
        ? wireRegex(body, df.caseSensitive, df.wholeWord)
        : wireLiteral(body, df.caseSensitive, df.wholeWord);
      addTerm(sign === '-' || sign === '!', { raw: tokRaw, wire, label: tokRaw.replace(/^[-+!]/, '') });
    }
  }
}

/**
 * Removes a single token from `pattern` using whitespace/start/end boundary anchors
 * so substrings inside other tokens (e.g. removing `-error` from `upstream-error -error`) are never corrupted.
 */
export function removeInlineModifierFromPattern(pattern: string, rawToken: string): string {
  const escaped = rawToken.replace(/[.*+?^${}()|[\]\\-]/g, '\\$&');
  const regex = new RegExp(`(^|\\s)${escaped}(?=\\s|$)`);
  if (regex.test(pattern)) {
    return pattern.replace(regex, '$1').replace(/\s{2,}/g, ' ').trim();
  }
  return pattern
    .split(/\s+/)
    .filter((t) => t !== rawToken)
    .join(' ');
}

/** Formats free text (e.g. a selection in the inspector) as a single search term. */
export function formatSearchTerm(text: string): string {
  const clean = text.trim();
  if (!clean) return '';
  const needsQuotes =
    /[\s"]/.test(clean) || /^[-@/$]/.test(clean) || /^(?:in|time):/i.test(clean);
  return needsQuotes ? `"${clean.replace(/(["\\])/g, '\\$1')}"` : clean;
}

/** Flips a term between "must contain" and "exclude" (`foo` ⇄ `-foo`, `"a b"` ⇄ `-"a b"`). */
export function toggleTermExclusion(rawToken: string): string {
  const t = rawToken.trim();
  const legacyExclude = /^\$[-!]\(([\s\S]*)\)$/.exec(t);
  if (legacyExclude) return formatSearchTerm(legacyExclude[1]);
  const legacyPhrase = /^\$\(([\s\S]*)\)$/.exec(t);
  if (legacyPhrase) return `-${formatSearchTerm(legacyPhrase[1])}`;
  const negLegacyMode = /^[-!](\$[a-zA-Z.*]+\([\s\S]*\))$/.exec(t);
  if (negLegacyMode) return negLegacyMode[1];
  if (/^-(?:["/@]|[\p{L}\p{N}_])/u.test(t)) return t.slice(1);
  return `-${t}`;
}
