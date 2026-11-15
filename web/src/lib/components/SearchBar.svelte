<script lang="ts">
  import { untrack } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import type { QueryStep, SearchHistoryEntry } from '$lib/types';
  import {
    buildVocabulary,
    computeWordCompletion,
    detectRegexLookTip,
    ghostSuffix,
    historyGhost,
    type Suggestion,
    type Vocabulary,
  } from '$lib/suggest';
  import ScopeBar from './ScopeBar.svelte';
  import SymbolBar from './SymbolBar.svelte';
  import {
    ChevronRight,
    Clock,
    FolderGit2,
    Lightbulb,
    Loader2,
    Plus,
    Search,
    X,
  } from 'lucide-svelte';

  interface Props {
    inputEl?: HTMLInputElement | null;
    hero?: boolean;
  }

  let { inputEl = $bindable(null), hero = false }: Props = $props();

  let focused = $state(false);
  let dropdownOpen = $state(false);
  let activeIdx = $state(-1);
  let cursorPos = $state(0);

  // Lazy vocabulary built from loaded lines only when focused
  let cachedVocab = $state<Vocabulary | null>(null);
  let vocabSourceHits: unknown = null;

  function ensureVocabulary() {
    const hits = workbench.flatHits;
    if (vocabSourceHits === hits && cachedVocab) return;
    vocabSourceHits = hits;
    const lines = hits.map((h) => h.text);
    cachedVocab = lines.length > 0 ? buildVocabulary(lines, 1200) : null;
  }

  $effect(() => {
    const _hits = workbench.flatHits;
    if (!focused) return;
    untrack(() => ensureVocabulary());
  });

  function syncCursorPos() {
    if (!inputEl) return;
    cursorPos = inputEl.selectionStart ?? workbench.pattern.length;
  }

  const wordCompletion = $derived.by(() => {
    if (!focused || !dropdownOpen || !cachedVocab) {
      return { token: null, items: [] as Suggestion[], autoSelect: false };
    }
    return computeWordCompletion(
      workbench.pattern,
      cursorPos,
      cachedVocab,
      workbench.t.suggest.wordCount,
      workbench.t.suggest.kindWord
    );
  });

  const historySuggestions = $derived.by(() => {
    if (!focused || !dropdownOpen) return [] as SearchHistoryEntry[];
    const typed = workbench.pattern.trim().toLowerCase();
    const out: SearchHistoryEntry[] = [];
    for (const entry of workbench.searchHistory) {
      if (out.length >= 6) break;
      if (!typed || entry.label.toLowerCase().includes(typed)) {
        out.push(entry);
      }
    }
    return out;
  });

  const regexTip = $derived(
    detectRegexLookTip(workbench.pattern, workbench.isRegex, workbench.t.suggest.tipLooksRegex)
  );

  // Inline ghost completion (only when caret is at the end of the text)
  const caretAtEnd = $derived(cursorPos >= workbench.pattern.length);

  const inlineGhost = $derived.by(() => {
    if (!focused || !caretAtEnd) return '';
    const firstWord = wordCompletion.items[0];
    if (firstWord && wordCompletion.token?.text) {
      const s = ghostSuffix(firstWord.insert, wordCompletion.token.text);
      if (s) return s;
    }
    if (workbench.steps.length === 0 && !workbench.draftExclude && !workbench.isRegex) {
      return historyGhost(workbench.pattern, workbench.searchHistory);
    }
    return '';
  });

  type DropdownEntry =
    | { kind: 'history'; entry: SearchHistoryEntry }
    | { kind: 'word'; suggestion: Suggestion };

  const dropdownItems = $derived.by(() => {
    const list: DropdownEntry[] = [];
    for (const h of historySuggestions) list.push({ kind: 'history', entry: h });
    for (const s of wordCompletion.items) list.push({ kind: 'word', suggestion: s });
    return list;
  });

  const showSymbolBar = $derived(workbench.isCompact && focused);
  const hasOpenDropdown = $derived(
    focused && dropdownOpen && (dropdownItems.length > 0 || regexTip !== null)
  );
  const hasAttachedPanel = $derived(showSymbolBar || hasOpenDropdown);

  const placeholderText = $derived.by(() => {
    if (workbench.isRegex) return workbench.t.searchBar.placeholderRegex;
    if (workbench.steps.length > 0) {
      return workbench.t.searchBar.nextLevelPlaceholder(workbench.steps.length);
    }
    return workbench.t.searchBar.placeholder;
  });

  function stepFlagTag(step: QueryStep): string {
    let tags = '';
    if (step.caseSensitive) tags += 'Aa ';
    if (step.wholeWord) tags += 'ab ';
    if (step.isRegex) tags += '.*';
    return tags.trim();
  }

  function applyWordSuggestion(s: Suggestion) {
    const tok = wordCompletion.token;
    if (tok) {
      const before = workbench.pattern.slice(0, tok.start);
      const after = workbench.pattern.slice(tok.end);
      workbench.pattern = `${before}${s.insert}${after}`;
      const nextPos = before.length + s.insert.length;
      requestAnimationFrame(() => {
        inputEl?.focus();
        inputEl?.setSelectionRange(nextPos, nextPos);
        syncCursorPos();
      });
    } else {
      workbench.pattern = s.insert;
    }
    activeIdx = -1;
    dropdownOpen = false;
  }

  function applyDropdownItem(index: number) {
    const item = dropdownItems[index];
    if (!item) return;
    if (item.kind === 'word') {
      applyWordSuggestion(item.suggestion);
    } else {
      dropdownOpen = false;
      activeIdx = -1;
      workbench.applyHistoryEntry(item.entry);
      inputEl?.focus();
    }
  }

  function acceptGhost(): boolean {
    if (!inlineGhost) return false;
    workbench.pattern = `${workbench.pattern}${inlineGhost}`;
    const pos = workbench.pattern.length;
    requestAnimationFrame(() => {
      inputEl?.focus();
      inputEl?.setSelectionRange(pos, pos);
      syncCursorPos();
    });
    return true;
  }

  function insertSymbolAtCursor(sym: string) {
    if (!inputEl) {
      workbench.pattern += sym;
      return;
    }
    const start = inputEl.selectionStart ?? workbench.pattern.length;
    const end = inputEl.selectionEnd ?? start;
    const next = workbench.pattern.slice(0, start) + sym + workbench.pattern.slice(end);
    workbench.pattern = next;
    const caret = sym === '()' ? start + 1 : start + sym.length;
    requestAnimationFrame(() => {
      inputEl?.focus();
      inputEl?.setSelectionRange(caret, caret);
      syncCursorPos();
    });
  }

  function backspaceAtCursor() {
    if (!inputEl) {
      workbench.pattern = workbench.pattern.slice(0, -1);
      return;
    }
    const start = inputEl.selectionStart ?? workbench.pattern.length;
    const end = inputEl.selectionEnd ?? start;
    if (end > start) {
      workbench.pattern = workbench.pattern.slice(0, start) + workbench.pattern.slice(end);
      requestAnimationFrame(() => {
        inputEl?.focus();
        inputEl?.setSelectionRange(start, start);
        syncCursorPos();
      });
    } else if (start > 0) {
      workbench.pattern = workbench.pattern.slice(0, start - 1) + workbench.pattern.slice(start);
      requestAnimationFrame(() => {
        inputEl?.focus();
        inputEl?.setSelectionRange(start - 1, start - 1);
        syncCursorPos();
      });
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      if (workbench.isSearching) {
        workbench.cancelSearch();
      } else if (dropdownOpen && (dropdownItems.length > 0 || regexTip)) {
        dropdownOpen = false;
        activeIdx = -1;
      } else if (workbench.pattern.length > 0) {
        workbench.clearDraftInput();
        cursorPos = 0;
      } else if (workbench.hasAnyQueryInput) {
        workbench.clearSearch();
      } else {
        inputEl?.blur();
      }
      return;
    }

    if ((e.key === 'Tab' || e.key === 'ArrowRight') && !e.shiftKey && inlineGhost && caretAtEnd) {
      if (e.key === 'Tab' || (inputEl && inputEl.selectionStart === inputEl.selectionEnd)) {
        e.preventDefault();
        acceptGhost();
        return;
      }
    }

    if (hasOpenDropdown && dropdownItems.length > 0) {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        activeIdx = activeIdx < dropdownItems.length - 1 ? activeIdx + 1 : 0;
        return;
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        activeIdx = activeIdx > 0 ? activeIdx - 1 : dropdownItems.length - 1;
        return;
      }
    }

    if (e.key === 'Tab' && !e.shiftKey && workbench.flatHits.length > 0) {
      e.preventDefault();
      if (workbench.activeHitIndex < 0) workbench.selectHitByIndex(0, false);
      inputEl?.blur();
      return;
    }

    if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && !e.altKey && workbench.flatHits.length > 0) {
      e.preventDefault();
      workbench.navigateHits(e.key === 'ArrowDown' ? 1 : -1);
      return;
    }

    if (e.key === 'Enter' && e.shiftKey) {
      e.preventDefault();
      workbench.commitCurrentPattern();
      dropdownOpen = false;
      activeIdx = -1;
      cursorPos = 0;
      return;
    }

    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      if (hasOpenDropdown && activeIdx >= 0 && dropdownItems[activeIdx]) {
        applyDropdownItem(activeIdx);
      } else {
        dropdownOpen = false;
        activeIdx = -1;
        workbench.submitSearch();
      }
    }
  }

  function handleInput() {
    syncCursorPos();
    dropdownOpen = true;
    activeIdx = -1;
    if (focused) ensureVocabulary();
  }

  function handleFocus() {
    focused = true;
    dropdownOpen = true;
    syncCursorPos();
    ensureVocabulary();
  }

  function handleBlur() {
    focused = false;
    dropdownOpen = false;
    activeIdx = -1;
  }
</script>

<div
  class={hero
    ? `flex flex-1 flex-col items-center px-3 md:px-6 select-none ${
        showSymbolBar ? 'justify-start pt-4' : 'justify-center pb-[14vh]'
      }`
    : 'relative px-3 md:px-6 pt-2 md:pt-3 pb-1.5 select-none'}
>
  {#if hero}
    <!-- Google-Style Centered Brand Wordmark -->
    <div
      class={`${
        showSymbolBar ? 'mb-3' : 'mb-7'
      } flex flex-col items-center gap-2 text-center`}
    >
      <h1 class="font-mono text-4xl font-semibold tracking-tight text-foreground">
        webgrep
      </h1>
      {#if workbench.sourcesLoaded && workbench.sources.length === 0}
        <button
          type="button"
          onclick={() => workbench.openSettings('add-source')}
          class="inline-flex items-center gap-1.5 text-xs text-status hover:underline cursor-pointer"
        >
          <FolderGit2 class="h-3.5 w-3.5" />
          <span>{workbench.t.results.emptyNoSourceTitle} · {workbench.t.results.openSourceManagerBtn}</span>
        </button>
      {/if}
    </div>
  {/if}

  <!-- Unified Google-Style Single-Text Search Box Wrapper -->
  <div class={`relative ${hero ? 'w-full max-w-[680px]' : 'w-full'}`}>
    <div class="relative">
      <div
        class={`relative flex items-center gap-2 border transition-colors min-w-0 ${
          hero ? 'min-h-12 px-4 py-1' : 'min-h-11 px-3.5 py-1'
        } ${
          hasAttachedPanel
            ? 'rounded-t-[22px] rounded-b-none border-b-transparent border-border bg-card shadow-xl'
            : 'rounded-full border-border/80 bg-card/85 shadow-sm hover:border-border focus-within:border-border focus-within:bg-card focus-within:shadow-md'
        }`}
      >
        {#if workbench.isSearching}
          <div class="pointer-events-none absolute inset-x-4 bottom-0 h-[1.5px] overflow-hidden bg-primary/10">
            <div class="search-progress-shimmer h-full w-2/5 bg-gradient-to-r from-transparent via-primary to-transparent"></div>
          </div>
        {/if}

        <!-- Left Search Icon & Optional Include/Exclude Mode Badge -->
        <div class="flex items-center gap-1.5 text-muted-foreground shrink-0">
          {#if workbench.isSearching}
            <Loader2 class="h-4 w-4 animate-spin text-primary" />
          {:else}
            <button
              type="button"
              disabled={!workbench.hasExecutableQuery}
              onmousedown={(e) => e.preventDefault()}
              onclick={() => {
                dropdownOpen = false;
                workbench.submitSearch();
              }}
              title={workbench.t.searchBar.searchNowTitle}
              aria-label={workbench.t.searchBar.searchNowTitle}
              class={`touch-target flex h-5 w-5 items-center justify-center rounded transition-colors ${
                workbench.hasExecutableQuery
                  ? 'text-muted-foreground hover:text-foreground cursor-pointer'
                  : 'text-muted-foreground/60 cursor-default'
              }`}
            >
              <Search class="h-4 w-4" />
            </button>
          {/if}

          {#if workbench.canExcludeDraft}
            <button
              type="button"
              onmousedown={(e) => e.preventDefault()}
              onclick={() => workbench.toggleDraftExclude()}
              title={workbench.t.searchBar.draftExcludeTitle(workbench.draftExclude)}
              aria-label={workbench.t.searchBar.draftExcludeTitle(workbench.draftExclude)}
              class={`touch-target inline-flex h-5 items-center rounded px-1.5 font-mono text-[11px] font-semibold ring-1 ring-inset transition-colors cursor-pointer ${
                workbench.draftExclude
                  ? 'bg-status/15 text-status ring-status/35 hover:bg-status/25'
                  : 'bg-primary/12 text-primary ring-primary/25 hover:bg-primary/20'
              }`}
            >
              {workbench.draftExclude ? '-' : '+'}
            </button>
          {/if}
        </div>

        <!-- Pure Single-Text Search Input + Fish-Style Ghost Completion Overlay -->
        <div class="relative h-9 min-w-[96px] flex-1">
          {#if inlineGhost}
            <div
              aria-hidden="true"
              title={workbench.t.searchBar.acceptGhost}
              class="pointer-events-none absolute inset-0 flex items-center overflow-hidden whitespace-pre px-1 font-mono text-[14.5px] [@media(any-pointer:coarse)]:text-[16px]"
            >
              <span class="invisible">{workbench.pattern}</span><span class="text-muted-foreground/45">{inlineGhost}</span>
            </div>
          {/if}
          <input
            bind:this={inputEl}
            bind:value={workbench.pattern}
            type="text"
            enterkeyhint="search"
            autocapitalize="off"
            autocomplete="off"
            autocorrect="off"
            spellcheck={false}
            placeholder={placeholderText}
            onmousedown={() => {
              dropdownOpen = true;
              requestAnimationFrame(syncCursorPos);
            }}
            onfocus={handleFocus}
            onblur={handleBlur}
            oninput={handleInput}
            onkeydown={handleKeydown}
            onclick={syncCursorPos}
            onkeyup={syncCursorPos}
            onselect={syncCursorPos}
            class="relative h-full w-full min-w-0 bg-transparent px-1 font-mono text-[14.5px] [@media(any-pointer:coarse)]:text-[16px] text-foreground placeholder:text-muted-foreground/65 focus:outline-none"
          />
        </div>

        <!-- Right Side Controls: Explicit Toggles (Aa, ab, .*), Progressive Filter (+ 继续筛选), and Clear (×) -->
        <div class="flex items-center gap-1 shrink-0">
          <button
            type="button"
            aria-pressed={workbench.caseSensitive}
            title={workbench.t.searchBar.matchCaseTitle}
            aria-label={workbench.t.searchBar.matchCaseTitle}
            onmousedown={(e) => e.preventDefault()}
            onclick={() => workbench.toggleCaseSensitive()}
            class={`touch-target inline-flex h-7 min-w-[28px] items-center justify-center rounded-md px-1.5 font-mono text-[12px] leading-none transition-colors cursor-pointer select-none ${
              workbench.caseSensitive
                ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-semibold'
                : 'text-muted-foreground/75 hover:bg-secondary/60 hover:text-foreground'
            }`}
          >
            Aa
          </button>

          <button
            type="button"
            aria-pressed={workbench.wholeWord}
            title={workbench.t.searchBar.wholeWordTitle}
            aria-label={workbench.t.searchBar.wholeWordTitle}
            onmousedown={(e) => e.preventDefault()}
            onclick={() => workbench.toggleWholeWord()}
            class={`touch-target inline-flex h-7 min-w-[28px] items-center justify-center rounded-md px-1.5 font-mono text-[12px] leading-none transition-colors cursor-pointer select-none ${
              workbench.wholeWord
                ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-semibold'
                : 'text-muted-foreground/75 hover:bg-secondary/60 hover:text-foreground'
            }`}
          >
            ab
          </button>

          <button
            type="button"
            aria-pressed={workbench.isRegex}
            title={workbench.t.searchBar.useRegexTitle}
            aria-label={workbench.t.searchBar.useRegexTitle}
            onmousedown={(e) => e.preventDefault()}
            onclick={() => workbench.toggleRegexMode()}
            class={`touch-target inline-flex h-7 min-w-[28px] items-center justify-center rounded-md px-1.5 font-mono text-[12px] leading-none transition-colors cursor-pointer select-none ${
              workbench.isRegex
                ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-semibold'
                : 'text-muted-foreground/75 hover:bg-secondary/60 hover:text-foreground'
            }`}
          >
            .*
          </button>

          {#if workbench.pattern.trim().length > 0}
            <button
              type="button"
              title={workbench.t.searchBar.addNextFilterTitle}
              aria-label={workbench.t.searchBar.addNextFilterTitle}
              onmousedown={(e) => e.preventDefault()}
              onclick={() => {
                dropdownOpen = false;
                workbench.commitCurrentPattern();
                cursorPos = 0;
                inputEl?.focus();
              }}
              class="touch-target ml-0.5 inline-flex h-7 shrink-0 items-center gap-0.5 rounded-full bg-secondary/70 px-2.5 text-xs font-medium text-muted-foreground ring-1 ring-inset ring-border/70 hover:bg-secondary hover:text-foreground transition-colors cursor-pointer select-none"
            >
              <Plus class="h-3.5 w-3.5 shrink-0" />
              <span class="hidden sm:inline">{workbench.t.searchBar.addNextFilter.replace(/^\+\s*/, '')}</span>
              <span class="sm:hidden">{workbench.t.searchBar.addNextFilterShort.replace(/^\+\s*/, '')}</span>
            </button>
          {/if}

          {#if workbench.pattern.length > 0}
            <button
              type="button"
              title={workbench.t.searchBar.clearDraftTitle}
              aria-label={workbench.t.searchBar.clearDraftTitle}
              onmousedown={(e) => e.preventDefault()}
              onclick={() => {
                workbench.clearDraftInput();
                cursorPos = 0;
                inputEl?.focus();
              }}
              class="touch-target shrink-0 rounded-full p-1.5 text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
            >
              <X class="h-4 w-4" />
            </button>
          {/if}
        </div>
      </div>

      <!-- Seamlessly Attached Dropdown Panel -->
      {#if hasAttachedPanel}
        <div
          role="listbox"
          tabindex="-1"
          onmousedown={(e) => e.preventDefault()}
          class="absolute left-0 right-0 top-full z-40 overflow-hidden rounded-b-[22px] border border-t-0 border-border bg-card shadow-2xl"
        >
          {#if showSymbolBar}
            <div class="mx-3 border-t border-border/60"></div>
            <SymbolBar onInsert={insertSymbolAtCursor} onBackspace={backspaceAtCursor} />
          {/if}

          {#if historySuggestions.length > 0}
            <div class="mx-3 border-t border-border/60"></div>
            <div class="max-h-52 md:max-h-64 overflow-y-auto py-1 pb-2">
              {#each historySuggestions as entry, hi (entry.id)}
                {@const isSelected = hi === activeIdx}
                <div
                  role="button"
                  tabindex="-1"
                  onmouseenter={() => (activeIdx = hi)}
                  onclick={() => applyDropdownItem(hi)}
                  onkeydown={(e) => {
                    if (e.key === 'Enter') applyDropdownItem(hi);
                  }}
                  class={`group flex items-center justify-between gap-3 px-4 py-2.5 md:py-2 cursor-pointer transition-colors ${
                    isSelected ? 'bg-secondary/80' : 'hover:bg-secondary/50'
                  }`}
                >
                  <div class="flex items-center gap-3 min-w-0">
                    <Clock class="h-3.5 w-3.5 shrink-0 text-muted-foreground/75" />
                    <span class="font-mono text-[13.5px] text-foreground truncate">
                      {entry.label}
                    </span>
                    {#if entry.draft && stepFlagTag(entry.draft)}
                      <span class="rounded bg-secondary px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground shrink-0">
                        {stepFlagTag(entry.draft)}
                      </span>
                    {/if}
                  </div>

                  <button
                    type="button"
                    onclick={(e) => {
                      e.stopPropagation();
                      workbench.removeHistoryEntry(entry.id);
                    }}
                    class="touch-target shrink-0 rounded p-1.5 text-muted-foreground/60 hover:bg-secondary hover:text-foreground cursor-pointer"
                    title={workbench.t.ui.removeHistory}
                    aria-label={workbench.t.ui.removeHistory}
                  >
                    <X class="h-3.5 w-3.5" />
                  </button>
                </div>
              {/each}
            </div>
          {/if}

          {#if wordCompletion.items.length > 0}
            <div class="mx-3 border-t border-border/60"></div>
            <div class="max-h-52 md:max-h-64 overflow-y-auto space-y-0.5 p-1.5 pb-2">
              {#each wordCompletion.items as item, wi (item.key)}
                {@const idx = historySuggestions.length + wi}
                {@const isSelected = idx === activeIdx}
                <button
                  type="button"
                  onmouseenter={() => (activeIdx = idx)}
                  onclick={() => applyWordSuggestion(item)}
                  class={`flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2.5 md:py-1.5 text-left transition-colors cursor-pointer ${
                    isSelected ? 'bg-secondary text-foreground' : 'text-foreground hover:bg-secondary/60'
                  }`}
                >
                  <span class="flex items-center gap-2.5 min-w-0">
                    <span class="truncate font-mono text-xs font-medium">{item.label}</span>
                    {#if item.hint}
                      <span class="truncate text-[11px] text-muted-foreground/70">{item.hint}</span>
                    {/if}
                  </span>
                  <span class="shrink-0 text-[10px] text-muted-foreground/60">{item.kind}</span>
                </button>
              {/each}
            </div>
          {/if}

          {#if regexTip}
            <div class="mx-3 border-t border-border/60"></div>
            <div class="space-y-0.5 px-4 py-2 text-[11.5px] text-muted-foreground">
              <div class="flex items-center gap-2 min-w-0">
                <Lightbulb class="h-3 w-3 shrink-0 text-status/80" />
                <span class="truncate">{regexTip.text}</span>
                <button
                  type="button"
                  onclick={() => {
                    workbench.isRegex = true;
                    inputEl?.focus();
                  }}
                  class="touch-target shrink-0 rounded bg-primary/10 px-1.5 py-0.5 font-mono text-[11px] text-primary hover:bg-primary/20 transition-colors cursor-pointer"
                >
                  {workbench.t.searchBar.enableRegexAction}
                </button>
              </div>
            </div>
          {/if}
        </div>
      {/if}
    </div>

    <!-- Decoupled ScopeBar (Data Sources + Time Window) -->
    <ScopeBar {hero} />

    <!-- Infinite-Level Progressive Condition Chain Bar (#1 -> #2 -> #3 -> ...) -->
    {#if workbench.steps.length > 0}
      <div class="mt-2 flex flex-wrap items-center gap-1.5 px-1">
        {#each workbench.steps as step, idx (`${idx}:${step.text}`)}
          {@const canToggle = workbench.canToggleStepExclude(idx)}
          {#if idx > 0}
            <ChevronRight class="h-3 w-3 shrink-0 text-muted-foreground/45" />
          {/if}
          <div
            class={`inline-flex max-w-full items-center gap-1 rounded-lg border px-1.5 py-0.5 font-mono text-xs transition-colors ${
              step.exclude
                ? 'border-status/35 bg-status/10 text-status'
                : 'border-border/75 bg-secondary/45 text-foreground'
            }`}
          >
            <span class="text-[10px] text-muted-foreground/65 select-none">#{idx + 1}</span>
            <button
              type="button"
              disabled={!canToggle}
              onmousedown={(e) => e.preventDefault()}
              onclick={() => {
                workbench.toggleStepExclude(idx);
                inputEl?.focus();
              }}
              title={canToggle
                ? workbench.t.searchBar.toggleExcludeTitle(step.exclude)
                : `#${idx + 1}`}
              aria-label={canToggle
                ? workbench.t.searchBar.toggleExcludeTitle(step.exclude)
                : `#${idx + 1}`}
              class={`touch-target inline-flex h-4 min-w-[16px] items-center justify-center rounded px-1 font-mono text-[11px] font-semibold transition-colors ${
                step.exclude
                  ? 'bg-status/15 text-status'
                  : 'bg-primary/12 text-primary'
              } ${canToggle ? 'hover:opacity-80 cursor-pointer' : 'cursor-default'}`}
            >
              {step.exclude ? '-' : '+'}
            </button>

            <button
              type="button"
              onmousedown={(e) => e.preventDefault()}
              onclick={() => {
                workbench.editStepInSearchBox(idx);
                requestAnimationFrame(() => {
                  inputEl?.focus();
                  syncCursorPos();
                });
              }}
              title={workbench.t.searchBar.editStepTitle}
              class={`touch-target inline-flex min-w-0 items-center gap-1 truncate px-0.5 text-left hover:underline cursor-pointer ${
                step.exclude ? 'line-through decoration-status/60' : ''
              }`}
            >
              <span class="truncate">{step.text}</span>
              {#if step.caseSensitive}
                <span class="rounded bg-primary/15 px-1 py-0.2 text-[9.5px] font-semibold text-primary shrink-0">
                  Aa
                </span>
              {/if}
              {#if step.wholeWord}
                <span class="rounded bg-primary/15 px-1 py-0.2 text-[9.5px] font-semibold text-primary shrink-0">
                  ab
                </span>
              {/if}
              {#if step.isRegex}
                <span class="rounded bg-primary/15 px-1 py-0.2 text-[9.5px] font-semibold text-primary shrink-0">
                  .*
                </span>
              {/if}
            </button>

            <button
              type="button"
              onmousedown={(e) => e.preventDefault()}
              onclick={() => {
                workbench.removeStep(idx);
                inputEl?.focus();
              }}
              title={workbench.t.searchBar.removeStepTitle(step.text)}
              aria-label={workbench.t.searchBar.removeStepTitle(step.text)}
              class="touch-target inline-flex h-4 w-4 shrink-0 items-center justify-center rounded text-muted-foreground/70 hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
            >
              <X class="h-3 w-3" />
            </button>
          </div>
        {/each}

        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={() => {
            workbench.clearSearch();
            inputEl?.focus();
          }}
          title={workbench.t.searchBar.clearTitle}
          class="touch-target ml-1 rounded-md px-2 py-0.5 text-[11px] text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
        >
          {workbench.t.searchBar.clearAllSteps}
        </button>
      </div>
    {/if}
  </div>
</div>
