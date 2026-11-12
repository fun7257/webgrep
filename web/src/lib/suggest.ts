/**
 * Smart completion & hints for the query language in `query.ts` (pure functions, no Svelte state).
 *
 * - `computeCompletion`  dropdown items for the token under the cursor:
 *     `in:` values (data sources, file types and folders from the results), `time:` values,
 *     plain word → qualifier (`zed` → `in:zedis-rust`, `.rs` → `in:*.rs`, `1h` → `time:1h`),
 *     and word completion from identifiers that occur in the current results (`memb` → `members`).
 * - `ghostSuffix` / `historyGhost`  fish-style inline ghost text (→ / Tab accepts).
 * - `queryHints`  non-blocking tips while typing (looks like a regex, `in:` typo, bad `time:`, old syntax…).
 * - `zeroResultFixes`  one-click ways out of an empty result (drop a term / scope, ignore case, nearby lines).
 * - `describeQuery`  one-line plain-language reading of the query.
 */
import {
  parseTimeModifierSpec,
  removeInlineModifierFromPattern,
  type ParsedSearchQuery,
} from './query.ts';

export interface SuggestText {
  kindSource: string;
  kindExt: string;
  kindDir: string;
  kindTime: string;
  kindKeyword: string;
  kindWord: string;
  hintIn: string;
  hintNotIn: string;
  hintTime: string;
  hintSource: (name: string) => string;
  hintNotSource: (name: string) => string;
  hintExt: (ext: string) => string;
  timeToday: string;
  timeYesterday: string;
  timeRecent: (n: string, unit: string) => string;
  wordCount: (n: number) => string;
  tipLooksRegex: (tok: string) => string;
  tipDidYouMean: (typed: string, name: string) => string;
  tipPathFilter: (value: string) => string;
  tipBadTime: (value: string) => string;
  tipLegacy: (from: string, to: string) => string;
  tipLoneMinus: (tok: string) => string;
  fixRemove: (label: string) => string;
  fixIgnoreCase: string;
  fixNearby: (n: number) => string;
  explainFind: string;
  explainExclude: string;
  explainIn: string;
  explainNotIn: string;
  explainTime: string;
}

export interface SourceRef {
  id: string;
  name: string;
  path: string;
}

export interface Suggestion {
  key: string;
  /** Full token text that replaces the token under the cursor. */
  insert: string;
  label: string;
  hint: string;
  kind: string;
  /** Finished token: append a space and search right away (otherwise keep typing, e.g. after `in:`). */
  complete: boolean;
}

export interface ActiveToken {
  text: string;
  start: number;
  end: number;
}

export interface Places {
  exts: string[];
  dirs: string[];
}

export interface Vocabulary {
  /** lowercase word → total count and the most frequent spelling */
  entries: { lower: string; word: string; count: number; mixedCase: boolean }[];
}

export interface CompletionContext {
  pattern: string;
  cursor: number;
  sources: readonly SourceRef[];
  places: Places;
  vocabulary: Vocabulary | null;
  /** Show starter items (`in:` / `time:`) on an empty box (when there is no history to show). */
  starters: boolean;
  t: SuggestText;
}

export interface CompletionResult {
  token: ActiveToken | null;
  items: Suggestion[];
  /** Value completion (after `in:` / `time:`): first item pre-selected, Enter takes it. */
  autoSelect: boolean;
}

export interface QueryTip {
  key: string;
  text: string;
  /** Pattern after applying the fix (absent for purely informational tips). */
  fix?: { label: string; pattern: string };
}

export interface ResultFix {
  key: string;
  label: string;
  /** New pattern, or `nearby` to re-enable the nearby-lines fallback. */
  pattern?: string;
  action?: 'nearby';
}

const COMMON_EXTS = ['rs', 'go', 'ts', 'zig', 'py', 'js', 'json', 'md', 'log', 'yaml'];
const TIME_PRESETS = ['15m', '1h', '24h', 'today', 'yesterday', '7d'];
const WORD_RE = /[A-Za-z_][A-Za-z0-9_]{2,47}/g;
const REGEX_LOOK = /\\[dDsSwWb]|\.\*|\.\+|\[[^\]\s]+\][*+?]|\{\d+(?:,\d*)?\}|\(\?[:=!]/;

// ---------------------------------------------------------------------------------------------
// Context builders
// ---------------------------------------------------------------------------------------------

/** File types and folders that occur in the current results (relative paths start with the source name). */
export function collectPlaces(files: Iterable<string>): Places {
  const exts = new Set<string>();
  const dirs = new Set<string>();
  for (const file of files) {
    const base = file.slice(file.lastIndexOf('/') + 1);
    const dot = base.lastIndexOf('.');
    if (dot > 0) exts.add(base.slice(dot + 1).toLowerCase());
    if (dirs.size < 40) {
      const parts = file.split('/').slice(1, -1);
      if (parts.length > 0) dirs.add(`${parts.join('/')}/`);
    }
  }
  return { exts: [...exts, ...COMMON_EXTS.filter((e) => !exts.has(e))], dirs: [...dirs] };
}

/** Identifier frequencies in result lines (at most `maxLines` lines are scanned). */
export function buildVocabulary(lines: Iterable<string>, maxLines = 3000): Vocabulary {
  const groups = new Map<string, { count: number; forms: Map<string, number> }>();
  let n = 0;
  for (const line of lines) {
    if (n++ >= maxLines) break;
    for (const m of line.matchAll(WORD_RE)) {
      const word = m[0];
      const lower = word.toLowerCase();
      let g = groups.get(lower);
      if (!g) {
        g = { count: 0, forms: new Map() };
        groups.set(lower, g);
      }
      g.count++;
      g.forms.set(word, (g.forms.get(word) ?? 0) + 1);
    }
  }
  const entries: Vocabulary['entries'] = [];
  for (const [lower, g] of groups) {
    let best = lower;
    let bestCount = -1;
    for (const [form, c] of g.forms) {
      if (c > bestCount) {
        best = form;
        bestCount = c;
      }
    }
    entries.push({ lower, word: best, count: g.count, mixedCase: g.forms.size > 1 });
  }
  entries.sort((a, b) => b.count - a.count || a.lower.length - b.lower.length);
  return { entries };
}

export function activeTokenAt(pattern: string, cursor: number): ActiveToken | null {
  const pos = cursor >= 0 && cursor <= pattern.length ? cursor : pattern.length;
  if (pos < pattern.length && !/\s/.test(pattern[pos])) return null;
  const text = /(\S*)$/.exec(pattern.slice(0, pos))?.[1] ?? '';
  if (text.includes('"')) return null;
  return { text, start: pos - text.length, end: pos };
}

// ---------------------------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------------------------

export function timeLabel(t: SuggestText, value: string): string {
  const v = value.toLowerCase();
  if (v === 'today' || v === '今天') return t.timeToday;
  if (v === 'yesterday' || v === '昨天') return t.timeYesterday;
  const m = /^(\d+)(s|m|h|d|w)$/.exec(v);
  return m ? t.timeRecent(m[1], m[2]) : value;
}

export function computeCompletion(ctx: CompletionContext): CompletionResult {
  const { t } = ctx;
  const token = activeTokenAt(ctx.pattern, ctx.cursor);
  const none: CompletionResult = { token, items: [], autoSelect: false };
  if (!token) return none;
  const text = token.text;

  if (!text) {
    if (!ctx.starters || ctx.pattern.trim()) return none;
    return {
      token,
      autoSelect: false,
      items: [
        { key: 'k:in', insert: 'in:', label: 'in:', hint: t.hintIn, kind: t.kindKeyword, complete: false },
        { key: 'k:time', insert: 'time:', label: 'time:', hint: t.hintTime, kind: t.kindKeyword, complete: false },
      ],
    };
  }

  const qual = /^(-?)(in|time):(.*)$/is.exec(text);
  if (qual) {
    const [, sign, rawKey, value] = qual;
    return {
      token,
      items: rawKey.toLowerCase() === 'time' ? (sign ? [] : timeValues(t, value)) : inValues(ctx, sign, value),
      autoSelect: true,
    };
  }

  if (text === '-') {
    return {
      token,
      autoSelect: false,
      items: [{ key: 'k:-in', insert: '-in:', label: '-in:', hint: t.hintNotIn, kind: t.kindKeyword, complete: false }],
    };
  }

  // Plain word (optionally an exclusion `-word`)
  const neg = /^-[A-Za-z_]/.test(text);
  const word = neg ? text.slice(1) : text;
  if (/^["/$@]/.test(word)) return none;
  const lower = word.toLowerCase();
  const items: Suggestion[] = [];

  if (!neg) {
    if (/^(?:\d+(?:s|m|h|d|w)|today|yesterday|今天|昨天)$/i.test(word)) {
      items.push({ key: `t:${lower}`, insert: `time:${lower}`, label: `time:${lower}`, hint: timeLabel(t, lower), kind: t.kindTime, complete: true });
    }
    const ext = /^\*?\.(\w+)$/.exec(word)?.[1];
    if (ext) {
      items.push({ key: `e:${ext}`, insert: `in:*.${ext}`, label: `in:*.${ext}`, hint: t.hintExt(ext), kind: t.kindExt, complete: true });
    }
    if (lower.length <= 2 && 'in:'.startsWith(lower)) {
      items.push({ key: 'k:in', insert: 'in:', label: 'in:', hint: t.hintIn, kind: t.kindKeyword, complete: false });
    }
    if (lower.length >= 2 && 'time:'.startsWith(lower)) {
      items.push({ key: 'k:time', insert: 'time:', label: 'time:', hint: t.hintTime, kind: t.kindKeyword, complete: false });
    }
  }

  // Words from the current results (prefix match, most frequent first)
  if (lower.length >= 2 && ctx.vocabulary && /^\w+$/.test(word)) {
    const typedHasUpper = /[A-Z]/.test(word);
    let added = 0;
    for (const e of ctx.vocabulary.entries) {
      if (added >= 5) break;
      if (e.lower === lower || !e.lower.startsWith(lower)) continue;
      // Typed lowercase and the word appears in several spellings → keep it case-insensitive.
      const form = !typedHasUpper && e.mixedCase ? e.lower : e.word;
      if (typedHasUpper && !form.startsWith(word)) continue;
      items.push({
        key: `w:${e.lower}`,
        insert: `${neg ? '-' : ''}${form}`,
        label: `${neg ? '-' : ''}${form}`,
        hint: t.wordCount(e.count),
        kind: t.kindWord,
        complete: true,
      });
      added++;
    }
  }

  if (!neg && lower.length >= 2) {
    for (const src of ctx.sources) {
      if (items.length >= 9) break;
      if (!src.name.toLowerCase().includes(lower)) continue;
      items.push({ key: `s:${src.id}`, insert: `in:${src.name}`, label: `in:${src.name}`, hint: t.hintSource(src.name), kind: t.kindSource, complete: true });
    }
  }
  return { token, items, autoSelect: false };
}

function timeValues(t: SuggestText, value: string): Suggestion[] {
  const q = value.toLowerCase();
  const values = /^\d+$/.test(q) ? [`${q}m`, `${q}h`, `${q}d`] : TIME_PRESETS.filter((p) => !q || p.startsWith(q));
  return values.map((v) => ({
    key: `t:${v}`,
    insert: `time:${v}`,
    label: `time:${v}`,
    hint: timeLabel(t, v),
    kind: t.kindTime,
    complete: true,
  }));
}

function inValues(ctx: CompletionContext, sign: string, value: string): Suggestion[] {
  const { t } = ctx;
  const lastComma = value.lastIndexOf(',');
  const prefix = `${sign}in:${value.slice(0, lastComma + 1)}`;
  const q = value.slice(lastComma + 1).toLowerCase();
  const items: Suggestion[] = [];
  for (const src of ctx.sources) {
    if (items.length >= 6) break;
    if (q && !src.name.toLowerCase().includes(q) && !src.id.toLowerCase().includes(q)) continue;
    items.push({
      key: `s:${src.id}`,
      insert: `${prefix}${src.name}`,
      label: src.name,
      hint: sign ? t.hintNotSource(src.name) : src.path,
      kind: t.kindSource,
      complete: true,
    });
  }
  const extQ = q.replace(/^\*?\./, '');
  let extCount = 0;
  for (const ext of ctx.places.exts) {
    if (extCount >= 4) break;
    if (extQ && !ext.startsWith(extQ)) continue;
    items.push({ key: `e:${ext}`, insert: `${prefix}*.${ext}`, label: `*.${ext}`, hint: t.hintExt(ext), kind: t.kindExt, complete: true });
    extCount++;
  }
  let dirCount = 0;
  for (const dir of ctx.places.dirs) {
    if (dirCount >= 4) break;
    if (q && !dir.toLowerCase().includes(q)) continue;
    items.push({ key: `d:${dir}`, insert: `${prefix}${dir}`, label: dir, hint: '', kind: t.kindDir, complete: true });
    dirCount++;
  }
  return items;
}

// ---------------------------------------------------------------------------------------------
// Ghost text
// ---------------------------------------------------------------------------------------------

/** Remaining text of `insert` after what was typed (case-insensitive prefix), or ''. */
export function ghostSuffix(insert: string, typed: string): string {
  if (!typed || insert.length <= typed.length) return '';
  return insert.slice(0, typed.length).toLowerCase() === typed.toLowerCase() ? insert.slice(typed.length) : '';
}

/** Rest of the most recent history query that starts with `pattern`. */
export function historyGhost(pattern: string, history: readonly string[]): string {
  if (!pattern.trim()) return '';
  const lower = pattern.toLowerCase();
  for (const h of history) {
    if (h.length > pattern.length && h.toLowerCase().startsWith(lower)) return h.slice(pattern.length);
  }
  return '';
}

// ---------------------------------------------------------------------------------------------
// Tips & fixes
// ---------------------------------------------------------------------------------------------

/** Whitespace tokens, keeping quoted phrases and legacy `$x(…)` calls together (enough for tips). */
export function splitRawTokens(pattern: string): string[] {
  return pattern.match(/[-!]?\$[-!@a-zA-Z.*]*\((?:[^()]|\([^()]*\))*\)?|-?"(?:\\.|[^"\\])*"?\S*|\S+/g) ?? [];
}

export function replaceToken(pattern: string, raw: string, next: string): string {
  const escaped = raw.replace(/[.*+?^${}()|[\]\\-]/g, '\\$&');
  return pattern.replace(new RegExp(`(^|\\s)${escaped}(?=\\s|$)`), (_m, lead: string) => `${lead}${next}`);
}

function levenshtein(a: string, b: string): number {
  if (a === b) return 0;
  const prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let diag = prev[0];
    prev[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const tmp = prev[j];
      prev[j] = Math.min(prev[j] + 1, prev[j - 1] + 1, diag + (a[i - 1] === b[j - 1] ? 0 : 1));
      diag = tmp;
    }
  }
  return prev[b.length];
}

/** Closest data source for a mistyped `in:` value (edit distance ≤ 2, or a clear prefix / substring). */
export function closestSource(value: string, sources: readonly SourceRef[]): SourceRef | null {
  const q = value.toLowerCase();
  let best: SourceRef | null = null;
  let bestScore = Infinity;
  for (const s of sources) {
    const name = s.name.toLowerCase();
    if (name === q) return null;
    const score = name.startsWith(q) && q.length >= 3 ? 0.5 : levenshtein(q, name);
    if (score < bestScore) {
      best = s;
      bestScore = score;
    }
  }
  return best && bestScore <= Math.min(2, Math.max(1, Math.floor(q.length / 3))) ? best : null;
}

/** Old `$…()` / `@source` token → new syntax, or null. */
export function legacyReplacement(raw: string, isSource: (name: string) => boolean): string | null {
  const quote = (s: string) => (/[\s"]/.test(s) || /^[-@/$]/.test(s) ? `"${s.replace(/(["\\])/g, '\\$1')}"` : s);
  let m: RegExpExecArray | null;
  if ((m = /^\$(?:t|time)\(([^)]*)\)$/i.exec(raw))) return `time:${m[1].trim()}`;
  if ((m = /^(?:\$([-!]?)@|([-!])\$@)\(([^)]*)\)$/.exec(raw))) return `${m[1] || m[2] ? '-' : ''}in:${m[3].trim().replace(/\s+/g, '')}`;
  if ((m = /^\$[-!]\(([\s\S]+)\)$/.exec(raw))) return `-${quote(m[1])}`;
  if ((m = /^\$\(([\s\S]+)\)$/.exec(raw))) return quote(m[1]);
  if ((m = /^(-?)\$r\(([\s\S]+)\)$/i.exec(raw))) return `${m[1]}/${m[2]}/`;
  if ((m = /^(-?)@([^\s(]+)$/.exec(raw)) && isSource(m[2])) return `${m[1]}in:${m[2]}`;
  return null;
}

export function queryTips(
  pattern: string,
  parsed: ParsedSearchQuery,
  sources: readonly SourceRef[],
  t: SuggestText
): QueryTip[] {
  const tips: QueryTip[] = [];
  const isSource = (n: string) => sources.some((s) => s.name.toLowerCase() === n.toLowerCase() || s.id === n);
  const tokens = splitRawTokens(pattern);

  // 1. Old syntax → one fix for all legacy tokens
  let migrated = pattern;
  let firstLegacy: [string, string] | null = null;
  for (const tok of tokens) {
    const next = legacyReplacement(tok, isSource);
    if (next) {
      migrated = replaceToken(migrated, tok, next);
      firstLegacy ??= [tok, next];
    }
  }
  if (firstLegacy) {
    tips.push({ key: 'legacy', text: t.tipLegacy(firstLegacy[0], firstLegacy[1]), fix: { label: firstLegacy[1], pattern: migrated } });
  }

  for (const tok of tokens) {
    // 2. Looks like a regex but is searched literally
    if (!/^-?["/$]/.test(tok) && !/^-?(?:in|time):/i.test(tok) && REGEX_LOOK.test(tok)) {
      const neg = tok.startsWith('-');
      const body = neg ? tok.slice(1) : tok;
      const next = `${neg ? '-' : ''}/${body}/`;
      tips.push({ key: `re:${tok}`, text: t.tipLooksRegex(tok), fix: { label: next, pattern: replaceToken(pattern, tok, next) } });
      continue;
    }

    // 3. `in:` values: typo of a data source, or an unexpected path-substring filter
    const inMatch = /^(-?)in:(.+)$/i.exec(tok);
    if (inMatch) {
      for (const item of inMatch[2].split(',')) {
        const clean = item.trim();
        if (!clean || isSource(clean) || /[*?/.]/.test(clean)) continue;
        const near = closestSource(clean, sources);
        if (near) {
          const next = tok.replace(clean, near.name);
          tips.push({ key: `in:${clean}`, text: t.tipDidYouMean(clean, near.name), fix: { label: next, pattern: replaceToken(pattern, tok, next) } });
        } else {
          tips.push({ key: `in:${clean}`, text: t.tipPathFilter(clean) });
        }
      }
      continue;
    }

    // 4. `time:` value that cannot be understood (ignored by the parser)
    const timeMatch = /^time:(.+)$/i.exec(tok);
    if (timeMatch && !/^\d{1,9}$/.test(timeMatch[1]) && !parseTimeModifierSpec(timeMatch[1])) {
      tips.push({ key: `time:${timeMatch[1]}`, text: t.tipBadTime(timeMatch[1]) });
    }
  }

  // 5. A lone `-x` is searched as text
  if (parsed.primaryRaw && /^-[A-Za-z0-9_]/.test(parsed.primaryRaw) && !parsed.modifiers.some((m) => m.kind === 'include')) {
    tips.push({ key: 'lone-minus', text: t.tipLoneMinus(parsed.primaryRaw) });
  }
  return tips.slice(0, 3);
}

export function zeroResultFixes(
  pattern: string,
  parsed: ParsedSearchQuery,
  opts: { strictLine: boolean; nearbyLines: number },
  t: SuggestText
): ResultFix[] {
  const fixes: ResultFix[] = [];
  const positives = [parsed.primaryRaw, ...parsed.modifiers.filter((m) => m.kind === 'include').map((m) => m.raw)].filter(Boolean);

  if (opts.strictLine && positives.length > 1) {
    fixes.push({ key: 'nearby', label: t.fixNearby(opts.nearbyLines), action: 'nearby' });
  }

  // Ignore case: lowercase every plain positive word that has an uppercase letter
  let lowered = pattern;
  for (const raw of positives) {
    if (/^["/$]/.test(raw) || !/[A-Z]/.test(raw)) continue;
    lowered = replaceToken(lowered, raw, raw.toLowerCase());
  }
  if (lowered !== pattern) fixes.push({ key: 'case', label: t.fixIgnoreCase, pattern: lowered });

  for (const m of parsed.modifiers) {
    if (m.kind === 'file' || m.kind === 'exclude-file' || m.kind === 'flag' || m.kind === 'exclude') {
      fixes.push({ key: `rm:${m.raw}`, label: t.fixRemove(m.raw), pattern: removeInlineModifierFromPattern(pattern, m.raw) });
    }
  }
  if (positives.length > 1) {
    for (const raw of [...positives].reverse()) {
      fixes.push({ key: `rm:${raw}`, label: t.fixRemove(raw), pattern: removeInlineModifierFromPattern(pattern, raw) });
    }
  }
  return fixes.slice(0, 5);
}

/** Plain-language reading, e.g. `找 pub + async · 排除 test · 在 zedis-rust · 时间 最近 1 小时` ('' when trivial). */
export function describeQuery(parsed: ParsedSearchQuery, t: SuggestText): string {
  const words = [parsed.primaryRaw, ...parsed.modifiers.filter((m) => m.kind === 'include').map((m) => m.value)].filter(Boolean);
  const excludes = parsed.modifiers.filter((m) => m.kind === 'exclude').map((m) => m.value);
  const ins = parsed.modifiers.filter((m) => m.kind === 'file').map((m) => m.value);
  const notIns = parsed.modifiers.filter((m) => m.kind === 'exclude-file').map((m) => m.value);
  const time = parsed.modifiers.find((m) => m.kind === 'flag');
  if (words.length <= 1 && !excludes.length && !ins.length && !notIns.length && !time) return '';
  const parts: string[] = [];
  if (words.length) parts.push(`${t.explainFind} ${words.join(' + ')}`);
  if (excludes.length) parts.push(`${t.explainExclude} ${excludes.join('、')}`);
  if (ins.length) parts.push(`${t.explainIn} ${ins.join('、')}`);
  if (notIns.length) parts.push(`${t.explainNotIn} ${notIns.join('、')}`);
  if (time) parts.push(`${t.explainTime} ${timeLabel(t, time.value)}`);
  return parts.join(' · ');
}
