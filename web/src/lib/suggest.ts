/**
 * Pure suggestion & zero-result recovery helpers for the structured Search Mode.
 * Zero implicit `in:` / `time:` syntax parsing — suggestions stay 100% focused on:
 * - Result vocabulary word completion (`computeWordCompletion`)
 * - Single-step fish-style ghost completion (`ghostSuffix` / `historyGhost`)
 * - Non-blocking regex hint (`detectRegexLookTip`)
 * - Structured zero-result recovery actions (`zeroResultFixes`)
 */
import type { QueryStep, ScopeFilter, SearchHistoryEntry } from './types.ts';

export interface Suggestion {
  key: string;
  insert: string;
  label: string;
  hint: string;
  kind: string;
}

export interface ActiveToken {
  text: string;
  start: number;
  end: number;
}

export interface Vocabulary {
  entries: { lower: string; word: string; count: number; mixedCase: boolean }[];
}

export interface CompletionResult {
  token: ActiveToken | null;
  items: Suggestion[];
  autoSelect: boolean;
}

export interface ResultFix {
  key: string;
  label: string;
  steps?: QueryStep[];
  draft?: QueryStep | null;
  scopePatch?: Partial<ScopeFilter>;
}

export interface ZeroFixText {
  fixIgnoreCase: string;
  fixRelaxWord: string;
  fixClearSources: string;
  fixClearTime: string;
  fixRemoveStep: (label: string) => string;
}

const WORD_RE = /[A-Za-z_][A-Za-z0-9_]{2,47}/g;
const REGEX_LOOK_RE = /\\[dDsSwWb]|\.\*|\.\+|\[[^\]\s]+\][*+?]|\{\d+(?:,\d*)?\}|\(\?[:=!]/;

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
  const lead = pattern.length - pattern.trimStart().length;
  const text = pos > lead ? pattern.slice(lead, pos) : '';
  return { text, start: Math.min(lead, pos), end: pos };
}

export function computeWordCompletion(
  pattern: string,
  cursor: number,
  vocabulary: Vocabulary | null,
  wordCountLabel: (n: number) => string,
  kindWordLabel: string
): CompletionResult {
  const token = activeTokenAt(pattern, cursor);
  const none: CompletionResult = { token, items: [], autoSelect: false };
  if (!token || !vocabulary) return none;
  const word = token.text;
  if (word.length < 2 || !/^\w+$/.test(word)) return none;

  const lower = word.toLowerCase();
  const typedHasUpper = /[A-Z]/.test(word);
  const items: Suggestion[] = [];
  for (const e of vocabulary.entries) {
    if (items.length >= 6) break;
    if (e.lower === lower || !e.lower.startsWith(lower)) continue;
    const form = !typedHasUpper && e.mixedCase ? e.lower : e.word;
    if (typedHasUpper && !form.startsWith(word)) continue;
    items.push({
      key: `w:${e.lower}`,
      insert: form,
      label: form,
      hint: wordCountLabel(e.count),
      kind: kindWordLabel,
    });
  }
  return { token, items, autoSelect: false };
}

export function ghostSuffix(insert: string, typed: string): string {
  if (!typed || insert.length <= typed.length) return '';
  return insert.slice(0, typed.length).toLowerCase() === typed.toLowerCase()
    ? insert.slice(typed.length)
    : '';
}

/**
 * Matches ONLY single-step positive non-regex history entries so ghost text
 * never inserts multi-step connectors or internal flags into the clean search box.
 */
export function historyGhost(
  pattern: string,
  historyEntries: readonly SearchHistoryEntry[]
): string {
  if (!pattern.trim()) return '';
  const lower = pattern.toLowerCase();
  for (const entry of historyEntries) {
    if (entry.steps.length !== 0 || !entry.draft || entry.draft.exclude || entry.draft.isRegex) {
      continue;
    }
    const text = entry.draft.text;
    if (text.length > pattern.length && text.toLowerCase().startsWith(lower)) {
      return text.slice(pattern.length);
    }
  }
  return '';
}

export function detectRegexLookTip(
  pattern: string,
  isRegex: boolean,
  tipLooksRegex: (tok: string) => string
): { text: string } | null {
  if (isRegex) return null;
  const trimmed = pattern.trim();
  if (!trimmed) return null;
  if (!REGEX_LOOK_RE.test(trimmed)) return null;
  return { text: tipLooksRegex(trimmed) };
}

export function zeroResultFixes(
  steps: readonly QueryStep[],
  draft: QueryStep | null,
  scope: ScopeFilter,
  t: ZeroFixText
): ResultFix[] {
  const fixes: ResultFix[] = [];
  const normDraft = draft && draft.text.trim().length > 0 ? draft : null;

  const hasCase = steps.some((s) => s.caseSensitive) || Boolean(normDraft?.caseSensitive);
  if (hasCase) {
    fixes.push({
      key: 'disable-case',
      label: t.fixIgnoreCase,
      steps: steps.map((s) => ({ ...s, caseSensitive: false })),
      draft: normDraft ? { ...normDraft, caseSensitive: false } : null,
    });
  }

  const hasWholeWord = steps.some((s) => s.wholeWord) || Boolean(normDraft?.wholeWord);
  if (hasWholeWord) {
    fixes.push({
      key: 'disable-word',
      label: t.fixRelaxWord,
      steps: steps.map((s) => ({ ...s, wholeWord: false })),
      draft: normDraft ? { ...normDraft, wholeWord: false } : null,
    });
  }

  if (scope.sources.length > 0 || (scope.excludedSources?.length ?? 0) > 0) {
    fixes.push({
      key: 'clear-sources',
      label: t.fixClearSources,
      scopePatch: { sources: [], excludedSources: [] },
    });
  }

  if (scope.timePreset !== '') {
    fixes.push({
      key: 'clear-time',
      label: t.fixClearTime,
      scopePatch: { timePreset: '' },
    });
  }

  // Drop exclusions or trailing filters if needed
  const totalSteps = steps.length + (normDraft ? 1 : 0);
  if (totalSteps > 1) {
    for (let i = steps.length - 1; i >= 0; i--) {
      if (fixes.length >= 5) break;
      const s = steps[i];
      const nextSteps = steps.filter((_, idx) => idx !== i);
      const hasPositiveLeft =
        nextSteps.some((x) => !x.exclude) ||
        Boolean(normDraft && !normDraft.exclude) ||
        scope.timePreset !== '';
      if (!hasPositiveLeft) continue;
      fixes.push({
        key: `drop-step-${i}`,
        label: t.fixRemoveStep(`${s.exclude ? '-' : ''}${s.text}`),
        steps: nextSteps,
        draft: normDraft,
      });
    }
  }

  return fixes.slice(0, 5);
}
