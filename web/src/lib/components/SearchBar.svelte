<script lang="ts">
  import { flushSync, untrack } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import type { HitItem, SearchHistoryEntry } from '$lib/types';
  import {
    buildVocabulary,
    computeWordCompletion,
    detectRegexLookTip,
    ghostSuffix,
    historyGhost,
    type Suggestion,
    type Vocabulary,
  } from '$lib/suggest';
  import SearchScopeTriggers from './search/SearchScopeTriggers.svelte';
  import SearchAttachedDropdown from './search/SearchAttachedDropdown.svelte';
  import ConditionChainBar from './search/ConditionChainBar.svelte';
  import SourcePickerContent from './pickers/SourcePickerContent.svelte';
  import { Loader2, Plus, Search, X } from 'lucide-svelte';

  interface Props {
    inputEl?: HTMLInputElement | null;
    hero?: boolean;
  }

  let { inputEl = $bindable(null), hero = false }: Props = $props();

  let focused = $state(false);
  let dropdownOpen = $state(false);
  let activeIdx = $state(-1);
  let cursorPos = $state(0);

  // Lazy idle vocabulary built from loaded lines without blocking input focus
  let cachedVocab = $state<Vocabulary | null>(null);
  let vocabSourceHits: unknown = null;
  let vocabHandle: number | null = null;
  let vocabUsingIdle = false;
  let toggledFlagOnDown: string | null = null;
  let pointerFocusingInput = false;

  let searchBoxWrapEl = $state<HTMLDivElement | null>(null);
  let sourcePickerWrapEl = $state<HTMLDivElement | null>(null);
  let timePickerWrapEl = $state<HTMLDivElement | null>(null);

  function cancelScheduledVocabulary() {
    if (vocabHandle === null) return;
    if (vocabUsingIdle && typeof cancelIdleCallback === 'function') {
      cancelIdleCallback(vocabHandle);
    } else {
      clearTimeout(vocabHandle);
    }
    vocabHandle = null;
  }

  function* iterHitTexts(hits: readonly HitItem[], limit: number): IterableIterator<string> {
    const cap = Math.min(limit, hits.length);
    for (let i = 0; i < cap; i++) {
      yield hits[i].text;
    }
  }

  function scheduleVocabularyBuild() {
    const hits = workbench.flatHits;
    if (hits.length === 0) {
      cancelScheduledVocabulary();
      vocabSourceHits = hits;
      cachedVocab = null;
      return;
    }
    if (workbench.isSearching) return;
    if (vocabSourceHits === hits && cachedVocab) return;

    cancelScheduledVocabulary();
    const buildNow = () => {
      vocabHandle = null;
      if (!focused || workbench.flatHits !== hits) return;
      vocabSourceHits = hits;
      cachedVocab = buildVocabulary(iterHitTexts(hits, 800), 800);
    };

    if (typeof requestIdleCallback === 'function') {
      vocabUsingIdle = true;
      vocabHandle = requestIdleCallback(buildNow, { timeout: 120 });
    } else {
      vocabUsingIdle = false;
      vocabHandle = window.setTimeout(buildNow, 16);
    }
  }

  $effect(() => {
    const _hits = workbench.flatHits;
    const _searching = workbench.isSearching;
    const _focused = focused;
    void _hits;
    void _searching;
    if (!_focused) {
      cancelScheduledVocabulary();
      return;
    }
    untrack(() => scheduleVocabularyBuild());
    return () => cancelScheduledVocabulary();
  });

  function handleFlagPointerDown(flag: string, e: PointerEvent, action: () => void) {
    if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
      e.preventDefault();
      toggledFlagOnDown = flag;
      flushSync(action);
    }
  }

  function handleFlagClick(flag: string, e: MouseEvent, action: () => void) {
    if (toggledFlagOnDown === flag && e.detail > 0) {
      toggledFlagOnDown = null;
      return;
    }
    toggledFlagOnDown = null;
    action();
  }

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
      if (!typed || entry.label.toLowerCase().includes(typed)) out.push(entry);
    }
    return out;
  });

  const regexTip = $derived(
    detectRegexLookTip(workbench.pattern, workbench.isRegex, workbench.t.suggest.tipLooksRegex)
  );
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
  const hasAttachedPanel = $derived(
    !workbench.sourcePickerOpen &&
      !workbench.timePickerOpen &&
      (showSymbolBar || hasOpenDropdown)
  );

  const placeholderText = $derived.by(() => {
    if (workbench.isRegex) return workbench.t.searchBar.placeholderRegex;
    if (workbench.steps.length > 0) {
      return workbench.t.searchBar.nextLevelPlaceholder(workbench.steps.length);
    }
    return workbench.t.searchBar.placeholder;
  });

  function commitPatternAndCaret(nextPattern: string, caretPos: number) {
    flushSync(() => {
      workbench.pattern = nextPattern;
    });
    inputEl?.focus();
    inputEl?.setSelectionRange(caretPos, caretPos);
    syncCursorPos();
  }

  function applyWordSuggestion(s: Suggestion) {
    const tok = wordCompletion.token;
    if (tok) {
      const before = workbench.pattern.slice(0, tok.start);
      const after = workbench.pattern.slice(tok.end);
      commitPatternAndCaret(`${before}${s.insert}${after}`, before.length + s.insert.length);
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
    commitPatternAndCaret(`${workbench.pattern}${inlineGhost}`, workbench.pattern.length + inlineGhost.length);
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
    commitPatternAndCaret(next, sym === '()' ? start + 1 : start + sym.length);
  }

  function backspaceAtCursor() {
    if (!inputEl) {
      workbench.pattern = workbench.pattern.slice(0, -1);
      return;
    }
    const start = inputEl.selectionStart ?? workbench.pattern.length;
    const end = inputEl.selectionEnd ?? start;
    if (end > start) {
      commitPatternAndCaret(workbench.pattern.slice(0, start) + workbench.pattern.slice(end), start);
    } else if (start > 0) {
      commitPatternAndCaret(
        workbench.pattern.slice(0, start - 1) + workbench.pattern.slice(start),
        start - 1
      );
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

    if (
      !hasOpenDropdown &&
      e.key === 'ArrowDown' &&
      !e.altKey &&
      workbench.flatHits.length === 0 &&
      workbench.searchHistory.length > 0
    ) {
      e.preventDefault();
      flushSync(() => {
        dropdownOpen = true;
      });
      activeIdx = dropdownItems.length > 0 ? 0 : -1;
      return;
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
      workbench.navigateHits(e.key === 'ArrowDown' ? 1 : -1, e.repeat);
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
    if (focused) scheduleVocabularyBuild();
  }

  function preparePointerFocus() {
    if (workbench.sourcePickerOpen) workbench.closeSourcePicker();
    if (workbench.timePickerOpen) workbench.closeTimePicker();
    pointerFocusingInput = true;
    flushSync(() => {
      dropdownOpen = true;
    });
    setTimeout(syncCursorPos, 0);
  }

  function isPillPaddingTarget(target: EventTarget | null): boolean {
    if (!(target instanceof Element)) return false;
    return !(
      target === inputEl ||
      target.closest('button') ||
      sourcePickerWrapEl?.contains(target) ||
      timePickerWrapEl?.contains(target)
    );
  }

  function handlePillSurfacePointerDown(e: PointerEvent) {
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    if (!isPillPaddingTarget(e.target)) return;
    preparePointerFocus();
    inputEl?.focus();
  }

  function handlePillSurfaceMousedown(e: MouseEvent) {
    if (e.button !== 0 || !isPillPaddingTarget(e.target)) return;
    e.preventDefault();
    inputEl?.focus();
  }

  function handleFocus() {
    if (workbench.sourcePickerOpen) workbench.closeSourcePicker();
    if (workbench.timePickerOpen) workbench.closeTimePicker();
    focused = true;
    if (pointerFocusingInput) {
      pointerFocusingInput = false;
      dropdownOpen = true;
    }
    syncCursorPos();
  }

  function handleBlur() {
    focused = false;
    dropdownOpen = false;
    activeIdx = -1;
    pointerFocusingInput = false;
    cancelScheduledVocabulary();
  }

  function handleWindowPointerDown(e: PointerEvent) {
    const target = e.target as Node;
    if (workbench.sourcePickerOpen && sourcePickerWrapEl && !sourcePickerWrapEl.contains(target)) {
      workbench.closeSourcePicker();
    }
    if (workbench.timePickerOpen && timePickerWrapEl && !timePickerWrapEl.contains(target)) {
      workbench.closeTimePicker();
    }
    if (dropdownOpen && searchBoxWrapEl && !searchBoxWrapEl.contains(target)) {
      dropdownOpen = false;
      activeIdx = -1;
    }
  }

  function resetDropdownForPicker() {
    dropdownOpen = false;
    activeIdx = -1;
  }
</script>

<svelte:window onpointerdown={handleWindowPointerDown} />

{#snippet flagToggle(id: string, active: boolean, title: string, label: string, toggle: () => void)}
  <button
    type="button"
    aria-pressed={active}
    {title}
    aria-label={title}
    onmousedown={(e) => e.preventDefault()}
    onpointerdown={(e) => handleFlagPointerDown(id, e, toggle)}
    onclick={(e) => handleFlagClick(id, e, toggle)}
    class={`touch-target inline-flex h-7 min-w-[22px] sm:min-w-[28px] items-center justify-center rounded-md px-1 sm:px-1.5 font-mono text-[11px] sm:text-[12px] leading-none cursor-pointer select-none ${
      active
        ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-semibold'
        : 'text-muted-foreground/75 hover:bg-secondary/60 hover:text-foreground active:bg-secondary'
    }`}
  >
    {label}
  </button>
{/snippet}

<div
  class={hero
    ? `flex flex-1 flex-col items-center px-2 sm:px-3 md:px-6 select-none ${
        showSymbolBar ? 'justify-start pt-4' : 'justify-center pb-[6vh]'
      }`
    : 'relative px-2 sm:px-3 md:px-6 pt-2 md:pt-3 pb-1.5 select-none'}
>
  {#if hero}
    <!-- Google-Style Centered Brand Wordmark -->
    <div class={`${showSymbolBar ? 'mb-3' : 'mb-6'} flex flex-col items-center gap-2 text-center`}>
      <h1 class="font-mono text-4xl font-semibold tracking-tight text-foreground">webgrep</h1>
    </div>
  {/if}

  <!-- Unified Google-Style Single-Text Search Box Wrapper -->
  <div class={`relative ${hero ? 'w-full max-w-[680px]' : 'w-full'}`}>
    <div bind:this={searchBoxWrapEl} class="relative">
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        onpointerdown={handlePillSurfacePointerDown}
        onmousedown={handlePillSurfaceMousedown}
        class={`relative flex items-center gap-1 sm:gap-2 border min-w-0 ${
          hero ? 'min-h-12 px-2 sm:px-4 py-1' : 'min-h-11 px-2 sm:px-3.5 py-1'
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

        <!-- Left Cluster: Search Icon + Embedded Scope Triggers + Optional +/- Mode -->
        <div class="flex items-center gap-0.5 sm:gap-1.5 text-muted-foreground shrink-0">
          {#if workbench.isSearching}
            <Loader2 class="h-4 w-4 animate-spin text-primary" />
          {:else}
            <button
              type="button"
              disabled={!workbench.hasExecutableQuery}
              onmousedown={(e) => e.preventDefault()}
              onclick={() => {
                dropdownOpen = false;
                workbench.closeSourcePicker();
                workbench.closeTimePicker();
                workbench.submitSearch();
              }}
              title={workbench.t.searchBar.searchNowTitle}
              aria-label={workbench.t.searchBar.searchNowTitle}
              class={`touch-target flex h-5 w-5 items-center justify-center rounded ${
                workbench.hasExecutableQuery
                  ? 'text-muted-foreground hover:text-foreground cursor-pointer'
                  : 'text-muted-foreground/60 cursor-default'
              }`}
            >
              <Search class="h-4 w-4" />
            </button>
          {/if}

          <SearchScopeTriggers
            bind:sourceWrapEl={sourcePickerWrapEl}
            bind:timeWrapEl={timePickerWrapEl}
            onBeforeOpenPicker={resetDropdownForPicker}
            onFocusMainInput={() => inputEl?.focus()}
          />
        </div>

        <!-- Pure Single-Text Search Input + Fish-Style Ghost Completion Overlay -->
        <div class="relative h-9 min-w-[56px] sm:min-w-[96px] flex-1">
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
            onpointerdown={preparePointerFocus}
            onfocus={handleFocus}
            onblur={handleBlur}
            oninput={handleInput}
            onkeydown={handleKeydown}
            onclick={() => {
              pointerFocusingInput = false;
              if (focused) dropdownOpen = true;
              syncCursorPos();
            }}
            onkeyup={syncCursorPos}
            onselect={syncCursorPos}
            class="relative h-full w-full min-w-0 bg-transparent px-1 font-mono text-[14.5px] [@media(any-pointer:coarse)]:text-[16px] text-foreground placeholder:text-muted-foreground/65 focus:outline-none"
          />
        </div>

        <!-- Right Side Controls: Explicit Toggles (Aa, ab, .*), Progressive Filter (+ Filter), and Clear (×) -->
        <div class="flex items-center gap-0.5 sm:gap-1 shrink-0">
          {@render flagToggle('case', workbench.caseSensitive, workbench.t.searchBar.matchCaseTitle, 'Aa', () => workbench.toggleCaseSensitive())}
          {@render flagToggle('word', workbench.wholeWord, workbench.t.searchBar.wholeWordTitle, 'ab', () => workbench.toggleWholeWord())}
          {@render flagToggle('regex', workbench.isRegex, workbench.t.searchBar.useRegexTitle, '.*', () => workbench.toggleRegexMode())}

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
              class="touch-target ml-0.5 inline-flex h-6 w-6 sm:h-7 sm:w-auto shrink-0 items-center justify-center sm:gap-0.5 rounded-full bg-secondary/70 sm:px-2.5 text-xs font-medium text-muted-foreground ring-1 ring-inset ring-border/70 hover:bg-secondary hover:text-foreground active:bg-secondary cursor-pointer select-none"
            >
              <Plus class="h-3.5 w-3.5 shrink-0" />
              <span class="hidden sm:inline">{workbench.t.searchBar.addNextFilter.replace(/^\+\s*/, '')}</span>
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
              class="touch-target shrink-0 rounded-full p-1 sm:p-1.5 text-muted-foreground hover:bg-secondary hover:text-foreground active:bg-secondary cursor-pointer"
            >
              <X class="h-3.5 w-3.5 sm:h-4 sm:w-4" />
            </button>
          {/if}
        </div>
      </div>

      {#if hasAttachedPanel}
        <SearchAttachedDropdown
          {showSymbolBar}
          {historySuggestions}
          wordItems={wordCompletion.items}
          {regexTip}
          bind:activeIdx
          onInsertSymbol={insertSymbolAtCursor}
          onBackspaceSymbol={backspaceAtCursor}
          onSelectHistory={applyDropdownItem}
          onSelectWord={applyWordSuggestion}
          onEnableRegex={() => {
            workbench.isRegex = true;
            inputEl?.focus();
          }}
        />
      {/if}
    </div>

    {#if workbench.steps.length > 0}
      <ConditionChainBar onFocusInput={() => inputEl?.focus()} onSyncCursor={syncCursorPos} />
    {/if}

    {#if hero && !showSymbolBar}
      <div class="mt-4">
        <SourcePickerContent inline onFocusMainInput={() => inputEl?.focus()} />
      </div>
    {/if}
  </div>
</div>
