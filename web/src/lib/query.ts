export interface ParsedDollarFlags {
  regex: boolean;
  caseSensitive: boolean;
  wholeWord: boolean;
}

export interface ClassifiedQueryToken {
  raw: string;
  kind: 'primary' | 'include' | 'exclude' | 'file' | 'exclude-file' | 'flag';
  value: string;
  forceLiteral?: boolean;
}

export interface ParsedSearchQuery {
  primaryPattern: string;
  contains: string[];
  excludes: string[];
  globs: string[];
  modifiers: ClassifiedQueryToken[];
  hasScopedRegex: boolean;
  hasScopedCase: boolean;
  hasScopedWord: boolean;
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

export function parseSearchQuery(raw: string): ParsedSearchQuery {
  interface RawToken {
    raw: string;
    quoted: boolean;
  }
  const rawTokens: RawToken[] = [];
  let i = 0;
  const n = raw.length;

  while (i < n) {
    while (i < n && /\s/.test(raw[i])) i++;
    if (i >= n) break;
    const start = i;
    const firstCh = raw[i];
    const quoted = firstCh === '"' || firstCh === "'";

    // Check for scoped `$r(xxxxxxx)`, `$c(xxxxxxx)`, `$w(xxxxxxx)`, `$rc(...)`, `$cw(...)`, `$rw(...)`, `$rcw(...)` with balanced parentheses
    const scopedMatch = /^([-+!]?)(\$[a-zA-Z.*]+)\(/.exec(raw.slice(i));
    if (scopedMatch) {
      const dFlags = parseDollarFlags(scopedMatch[2]);
      if (dFlags) {
        const openParenPos = i + scopedMatch[0].length - 1;
        let depth = 1;
        let p = openParenPos + 1;
        let inCharClass = false;
        let classStart = -1;
        while (p < n && depth > 0) {
          const c = raw[p];
          if (c === '\\' && p + 1 < n) {
            p += 2;
            continue;
          }
          if (inCharClass) {
            if (
              c === ']' &&
              p > classStart + 1 &&
              !(
                p === classStart + 2 &&
                (raw[classStart + 1] === '^' || raw[classStart + 1] === '!')
              )
            ) {
              inCharClass = false;
            }
            p++;
            continue;
          }
          if (c === '[') {
            inCharClass = true;
            classStart = p;
          } else if (c === '(') {
            depth++;
          } else if (c === ')') {
            depth--;
          }
          p++;
        }
        i = p;
        rawTokens.push({ raw: raw.slice(start, i), quoted: false });
        continue;
      }
    }

    let inQuote: string | null = null;
    let inBracket = false;
    let bracketStart = -1;
    let parenDepth = 0;

    // Pre-check if any '[' or '(' from `start` has a matching closing delimiter before end of string
    const hasClosingFrom = (openPos: number, openCh: string, closeCh: string): boolean => {
      let depth = 0;
      for (let p = openPos; p < n; p++) {
        const c = raw[p];
        if (c === '\\' && p + 1 < n) {
          p++;
          continue;
        }
        if (c === openCh) depth++;
        else if (c === closeCh) {
          depth--;
          if (depth <= 0) return true;
        }
      }
      return false;
    };

    while (i < n) {
      const ch = raw[i];
      if (inQuote) {
        if (ch === '\\' && i + 1 < n) {
          i += 2;
          continue;
        }
        if (ch === inQuote) {
          inQuote = null;
        }
        i++;
      } else if (inBracket) {
        if (ch === '\\' && i + 1 < n) {
          i += 2;
          continue;
        }
        // In regex `[...]`, a `]` immediately after `[` or `[^` is a literal `]`, not closing the class
        if (
          ch === ']' &&
          i > bracketStart + 1 &&
          !(
            i === bracketStart + 2 &&
            (raw[bracketStart + 1] === '^' || raw[bracketStart + 1] === '!')
          )
        ) {
          inBracket = false;
        }
        i++;
      } else {
        // Escaped whitespace (`\ `) stays inside the current token
        if (ch === '\\' && i + 1 < n && /\s/.test(raw[i + 1])) {
          i += 2;
          continue;
        }
        if (ch === '"' || ch === "'") {
          inQuote = ch;
          i++;
        } else if (ch === '[' && hasClosingFrom(i, '[', ']')) {
          inBracket = true;
          bracketStart = i;
          i++;
        } else if (ch === '(' && hasClosingFrom(i, '(', ')')) {
          parenDepth++;
          i++;
        } else if (ch === ')' && parenDepth > 0) {
          parenDepth--;
          i++;
        } else if (/\s/.test(ch) && parenDepth === 0) {
          break;
        } else {
          i++;
        }
      }
    }
    rawTokens.push({ raw: raw.slice(start, i), quoted });
  }

  const stripQuotes = (s: string): string => {
    if (
      s.length >= 2 &&
      ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'")))
    ) {
      return s.slice(1, -1);
    }
    return s;
  };

  const normalizeGlobItem = (body: string, negate: boolean): string => {
    const clean = body.trim();
    if (!clean) return '';
    const neg = negate || clean.startsWith('!') ? '!' : '';
    const core = clean.startsWith('!') ? clean.slice(1) : clean;
    if (!core) return '';
    return `${neg}${core}`;
  };

  const splitGlobList = (val: string): string[] => {
    const items: string[] = [];
    let cur = '';
    let braceDepth = 0;
    for (let j = 0; j < val.length; j++) {
      const ch = val[j];
      if (ch === '{') braceDepth++;
      else if (ch === '}' && braceDepth > 0) braceDepth--;
      if (braceDepth === 0 && ch === ',') {
        if (cur.trim()) items.push(cur.trim());
        cur = '';
      } else {
        cur += ch;
      }
    }
    if (cur.trim()) items.push(cur.trim());
    return items;
  };

  const parseScopedDollarToken = (
    s: string
  ): { prefix: string; flags: ParsedDollarFlags; inner: string } | null => {
    const m =
      /^([-+!]?)(\$[a-zA-Z.*]+)\(([\s\S]*)\)$/.exec(s) ??
      /^([-+!]?)(\$[a-zA-Z.*]+)\(([\s\S]*)$/.exec(s);
    if (!m) return null;
    const df = parseDollarFlags(m[2]);
    if (!df) return null;
    return {
      prefix: m[1],
      flags: df,
      inner: m[3],
    };
  };

  // Pass 1: Detect scoped `$r(...)`, `$c(...)`, `$w(...)`, `$rc(...)`, `$rw(...)`, `$cw(...)`, `$rcw(...)`
  let hasScopedRegex = false;
  let hasScopedCase = false;
  let hasScopedWord = false;
  for (const tok of rawTokens) {
    if (tok.quoted) continue;
    const scoped = parseScopedDollarToken(tok.raw);
    if (scoped) {
      if (scoped.inner.length > 0) {
        if (scoped.flags.regex) hasScopedRegex = true;
        if (scoped.flags.caseSensitive) hasScopedCase = true;
        if (scoped.flags.wholeWord) hasScopedWord = true;
      }
      continue;
    }
  }

  const normalizeUnquotedValue = (s: string): string => {
    // In literal mode, unescape leading `\-`, `\+`, `\@`, `\$` and inline escaped spaces `\ `
    let out = s.replace(/\\(\s)/g, '$1');
    if (/^\\[-+@$]/.test(out)) {
      out = out.slice(1);
    }
    return out;
  };

  const classified: ClassifiedQueryToken[] = [];

  for (const tok of rawTokens) {
    if (tok.quoted) {
      const inner = stripQuotes(tok.raw);
      const hasDoubledQuotes =
        (tok.raw.startsWith('""') && tok.raw.endsWith('""')) ||
        (tok.raw.startsWith("''") && tok.raw.endsWith("''"));
      const v = hasDoubledQuotes ? inner : inner || tok.raw;
      if (v) {
        classified.push({
          raw: tok.raw,
          kind: 'primary',
          value: v,
          forceLiteral: hasDoubledQuotes,
        });
      }
      continue;
    }

    const scoped = parseScopedDollarToken(tok.raw);
    if (scoped) {
      if (!scoped.inner) {
        continue;
      }
      const flagCode =
        `${scoped.flags.regex ? 'r' : ''}${scoped.flags.caseSensitive ? 'c' : ''}${scoped.flags.wholeWord ? 'w' : ''}` ||
        'r';
      const canonicalScoped = `$${flagCode}(${scoped.inner})`;
      if (scoped.prefix === '-' || scoped.prefix === '!') {
        classified.push({ raw: tok.raw, kind: 'exclude', value: canonicalScoped });
      } else if (scoped.prefix === '+') {
        classified.push({ raw: tok.raw, kind: 'include', value: canonicalScoped });
      } else {
        classified.push({ raw: tok.raw, kind: 'primary', value: canonicalScoped });
      }
      continue;
    }

    if (
      /^[-+!]?\$$/.test(tok.raw) ||
      (tok.raw.startsWith('$') && parseDollarFlags(tok.raw) !== null) ||
      ((tok.raw.startsWith('-$') || tok.raw.startsWith('+$') || tok.raw.startsWith('!$')) &&
        parseDollarFlags(tok.raw.slice(1)) !== null)
    ) {
      continue;
    }

    const atMatch = /^@(.+)$/.exec(tok.raw);
    if (atMatch) {
      const v = stripQuotes(atMatch[1]);
      if (v) classified.push({ raw: tok.raw, kind: 'file', value: v });
      continue;
    }

    const negAtMatch = /^[-!]@(.+)$/.exec(tok.raw);
    if (negAtMatch) {
      const v = stripQuotes(negAtMatch[1]);
      if (v) classified.push({ raw: tok.raw, kind: 'exclude-file', value: v });
      continue;
    }

    const fileMatch = /^(?:f|file)[:：](.*)$/i.exec(tok.raw);
    if (fileMatch) {
      const v = stripQuotes(fileMatch[1]);
      if (v) classified.push({ raw: tok.raw, kind: 'file', value: v });
      continue;
    }

    const negFileMatch = /^(?:[-!]f|[-!]file)[:：](.*)$/i.exec(tok.raw);
    if (negFileMatch) {
      const v = stripQuotes(negFileMatch[1]);
      if (v) classified.push({ raw: tok.raw, kind: 'exclude-file', value: v });
      continue;
    }

    if (tok.raw === '@' || tok.raw === '-@' || tok.raw === '!@') {
      continue;
    }

    if (tok.raw.startsWith('+')) {
      const v = normalizeUnquotedValue(stripQuotes(tok.raw.slice(1)));
      if (v) classified.push({ raw: tok.raw, kind: 'include', value: v });
      continue;
    }

    if (tok.raw.startsWith('-')) {
      const v = normalizeUnquotedValue(stripQuotes(tok.raw.slice(1)));
      if (v) classified.push({ raw: tok.raw, kind: 'exclude', value: v });
      continue;
    }

    classified.push({
      raw: tok.raw,
      kind: 'primary',
      value: normalizeUnquotedValue(tok.raw),
    });
  }

  const hasPrimary = classified.some((c) => c.kind === 'primary');
  if (
    !hasPrimary &&
    classified.length > 0 &&
    (classified[0].kind === 'include' || classified[0].kind === 'exclude')
  ) {
    classified[0] = {
      raw: classified[0].raw,
      kind: 'primary',
      value: classified[0].raw,
    };
  }

  const primaryTokens: { token: ClassifiedQueryToken }[] = [];
  const contains: string[] = [];
  const excludes: string[] = [];
  const globs: string[] = [];
  const modifiers: ClassifiedQueryToken[] = [];

  for (const c of classified) {
    if (c.kind === 'primary') {
      primaryTokens.push({ token: c });
    } else if (c.kind === 'include') {
      contains.push(c.value);
      modifiers.push(c);
    } else if (c.kind === 'exclude') {
      excludes.push(c.value);
      modifiers.push(c);
    } else if (c.kind === 'file') {
      for (const item of splitGlobList(c.value)) {
        const norm = normalizeGlobItem(item, false);
        if (norm) globs.push(norm);
      }
      modifiers.push(c);
    } else if (c.kind === 'exclude-file') {
      for (const item of splitGlobList(c.value)) {
        const norm = normalizeGlobItem(item, true);
        if (norm) globs.push(norm);
      }
      modifiers.push(c);
    } else if (c.kind === 'flag') {
      modifiers.push(c);
    }
  }

  let finalPrimary = '';
  if (primaryTokens.length > 0) {
    const primaryIdx = 0;
    finalPrimary = primaryTokens[primaryIdx].token.value;
    for (let k = 0; k < primaryTokens.length; k++) {
      if (k === primaryIdx) continue;
      const pt = primaryTokens[k].token;
      contains.push(pt.value);
      modifiers.push({
        raw: pt.raw,
        kind: 'include',
        value: pt.value,
      });
    }
  }

  return {
    primaryPattern: finalPrimary,
    contains,
    excludes,
    globs,
    modifiers,
    hasScopedRegex,
    hasScopedCase,
    hasScopedWord,
  };
}

/**
 * Removes a single inline modifier token from `pattern` using whitespace/start/end boundary anchors
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
