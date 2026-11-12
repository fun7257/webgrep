<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import type { SearchHistoryEntry } from '$lib/types';
  import {
    Clock,
    Lightbulb,
    FolderGit2,
    Loader2,
    Search,
    X,
  } from 'lucide-svelte';
  import SymbolBar from './SymbolBar.svelte';
  import {
    buildVocabulary,
    collectPlaces,
    computeCompletion,
    describeQuery,
    ghostSuffix,
    historyGhost,
    queryTips,
    type Suggestion,
  } from '$lib/suggest';

  interface Props {
    inputEl?: HTMLInputElement | null;
    hero?: boolean;
  }

  let { inputEl = $bindable(null), hero = false }: Props = $props();
  let selectedSuggestIdx = $state(-1);
  let selectedHistoryIdx = $state(-1);
  let suggestDismissed = $state(true);
  let isInputFocused = $state(false);
  let cursorPos = $state(-1);
  /** Input text wider than the box (ghost text would be misaligned, so it is hidden). */
  let inputOverflowing = $state(false);

  function syncCursorPos() {
    if (inputEl && typeof inputEl.selectionStart === 'number') {
      cursorPos = inputEl.selectionStart;
      inputOverflowing = inputEl.scrollWidth > inputEl.clientWidth + 1;
    } else {
      cursorPos = workbench.pattern.length;
    }
  }

  // Smart completion & hints (pure logic in `$lib/suggest`).
  let places = $derived(collectPlaces(workbench.fileGroups.map((g) => g.file)));
  let vocabulary = $derived(
    workbench.flatHits.length > 0 ? buildVocabulary(workbench.flatHits.map((h) => h.text)) : null
  );
  let historyPatterns = $derived(workbench.searchHistory.map((h) => h.pattern));

  let completion = $derived.by(() => {
    const empty = { token: null, items: [] as Suggestion[], autoSelect: false };
    if (suggestDismissed || !isInputFocused) return empty;
    return computeCompletion({
      pattern: workbench.pattern,
      cursor: cursorPos,
      sources: workbench.sources,
      places,
      vocabulary,
      starters: workbench.searchHistory.length === 0,
      t: workbench.t.suggest,
    });
  });
  let activeToken = $derived(completion.token);

  let effectiveSuggestIdx = $derived(
    completion.items.length === 0
      ? -1
      : selectedSuggestIdx >= 0
        ? Math.min(selectedSuggestIdx, completion.items.length - 1)
        : completion.autoSelect
          ? 0
          : -1
  );

  /** Item that Tab / → would take: the highlighted one, else the first. */
  let tabItem = $derived(completion.items[Math.max(0, effectiveSuggestIdx)] ?? null);

  /** Fish-style ghost text after the cursor (only when the cursor is at the end and the text fits). */
  let ghost = $derived.by((): { text: string; item: Suggestion | null } => {
    const pat = workbench.pattern;
    if (!isInputFocused || inputOverflowing || (cursorPos >= 0 && cursorPos < pat.length)) {
      return { text: '', item: null };
    }
    if (tabItem && activeToken) {
      const text = ghostSuffix(tabItem.insert, activeToken.text);
      if (text) return { text, item: tabItem };
    }
    if (completion.items.length === 0 && !suggestDismissed) {
      const text = historyGhost(pat, historyPatterns);
      if (text) return { text, item: null };
    }
    return { text: '', item: null };
  });

  let parsedForTips = $derived(workbench.parsedQuery);
  let tips = $derived(
    isInputFocused && !suggestDismissed && workbench.pattern.trim()
      ? queryTips(workbench.pattern, parsedForTips, workbench.sources, workbench.t.suggest)
      : []
  );
  let explanation = $derived(
    isInputFocused && !suggestDismissed ? describeQuery(parsedForTips, workbench.t.suggest) : ''
  );

  // Google-style search history suggestions (only when no completion is showing).
  let historySuggestions = $derived.by((): SearchHistoryEntry[] => {
    if (!isInputFocused || suggestDismissed || completion.items.length > 0) {
      return [];
    }
    const all = workbench.searchHistory;
    if (all.length === 0) return [];
    const q = workbench.pattern.trim().toLowerCase();
    if (!q) {
      return all.slice(0, 8);
    }
    return all
      .filter(
        (h) =>
          h.pattern.toLowerCase().includes(q) &&
          h.pattern.trim().toLowerCase() !== q
      )
      .slice(0, 6);
  });

  const hasOpenDropdown = $derived(
    completion.items.length > 0 || historySuggestions.length > 0 || tips.length > 0 || explanation !== ''
  );

  const showSymbolBar = $derived(workbench.isCompact && isInputFocused);
  const hasAttachedPanel = $derived(showSymbolBar || hasOpenDropdown);

  function setPatternAndCursor(next: string, cursor: number, search: boolean) {
    workbench.pattern = next;
    cursorPos = cursor;
    suggestDismissed = false;
    selectedSuggestIdx = -1;
    if (search) workbench.scheduleSearch(true);
    requestAnimationFrame(() => {
      inputEl?.focus();
      inputEl?.setSelectionRange(cursor, cursor);
      syncCursorPos();
    });
  }

  function applySuggestion(item: Suggestion) {
    if (!activeToken) return;
    const before = workbench.pattern.slice(0, activeToken.start);
    const after = workbench.pattern.slice(activeToken.end);
    const inserted = item.complete ? `${item.insert} ` : item.insert;
    setPatternAndCursor(
      `${before}${inserted}${item.complete ? after.replace(/^\s+/, '') : after}`,
      before.length + inserted.length,
      item.complete
    );
  }

  /** Accepts the ghost text: the suggestion it came from, or the rest of a history query. */
  function acceptGhost(): boolean {
    if (!ghost.text) return false;
    if (ghost.item) {
      applySuggestion(ghost.item);
    } else {
      const next = `${workbench.pattern}${ghost.text}`;
      setPatternAndCursor(next, next.length, true);
    }
    return true;
  }

  function applyTipFix(next: string) {
    setPatternAndCursor(next, next.length, true);
  }

  function insertSymbol(sym: string) {
    if (!inputEl) return;
    const raw = workbench.pattern;
    const selStart = Math.min(inputEl.selectionStart ?? raw.length, raw.length);
    const selEnd = Math.min(inputEl.selectionEnd ?? selStart, raw.length);

    // Smart in-place wrapping for paired tokens (`//` regex via Alt+R, `""` phrase):
    // 1. If text is selected in `<input>`, wrap the selection in-place: `/selected/ `
    // 2. If cursor is on/at the end of a plain word `foo|`, wrap `foo` in-place: `/foo/ `
    const pair: [string, string] | null = sym.endsWith('()')
      ? [sym.slice(0, -1), ')']
      : sym === '//'
        ? ['/', '/']
        : sym === '""' || sym === '"'
          ? ['"', '"']
          : null;
    if (pair) {
      const [open, close] = pair;
      if (selStart < selEnd) {
        const selected = raw.slice(selStart, selEnd);
        const before = raw.slice(0, selStart);
        const after = raw.slice(selEnd);
        const wrapped = `${open}${selected}${close} `;
        workbench.pattern = `${before}${wrapped}${after.replace(/^\s+/, '')}`;
        const nextCursor = before.length + wrapped.length;
        cursorPos = nextCursor;
        suggestDismissed = true;
        workbench.scheduleSearch(true);
        requestAnimationFrame(() => {
          inputEl?.focus();
          inputEl?.setSelectionRange(nextCursor, nextCursor);
        });
        return;
      }

      // Check if cursor is touching/inside an existing plain word (not starting with `$`)
      let wStart = selStart;
      let wEnd = selStart;
      while (wStart > 0 && !/\s/.test(raw[wStart - 1])) wStart--;
      while (wEnd < raw.length && !/\s/.test(raw[wEnd])) wEnd++;
      const word = raw.slice(wStart, wEnd);
      if (word.length > 0 && !/^-?[$"/@]/.test(word)) {
        const before = raw.slice(0, wStart);
        const after = raw.slice(wEnd);
        const wrapped = `${open}${word}${close} `;
        workbench.pattern = `${before}${wrapped}${after.replace(/^\s+/, '')}`;
        const nextCursor = before.length + wrapped.length;
        cursorPos = nextCursor;
        suggestDismissed = true;
        workbench.scheduleSearch(true);
        requestAnimationFrame(() => {
          inputEl?.focus();
          inputEl?.setSelectionRange(nextCursor, nextCursor);
        });
        return;
      }
    }

    const pos = selStart;
    const before = raw.slice(0, pos);
    const after = raw.slice(pos);
    const needSpace = before.length > 0 && !/\s$/.test(before);
    // Tokens that come in pairs ( `"` → `""`, `//` ) put the cursor between the pair.
    const paired = pair !== null;
    const inserted = `${needSpace ? ' ' : ''}${sym === '"' ? '""' : sym}`;
    workbench.pattern = `${before}${inserted}${after}`;
    const nextCursor = before.length + inserted.length - (paired ? 1 : 0);
    cursorPos = nextCursor;
    suggestDismissed = false;
    selectedSuggestIdx = -1;
    workbench.scheduleSearch();
    requestAnimationFrame(() => {
      inputEl?.focus();
      inputEl?.setSelectionRange(nextCursor, nextCursor);
    });
  }

  $effect(() => {
    workbench.insertToken = insertSymbol;
    return () => {
      workbench.insertToken = null;
    };
  });

  function backspaceToken() {
    const raw = workbench.pattern.replace(/\s+$/, '');
    const idx = raw.lastIndexOf(' ');
    workbench.pattern = idx >= 0 ? raw.slice(0, idx + 1) : '';
    cursorPos = workbench.pattern.length;
    workbench.scheduleSearch();
    requestAnimationFrame(() => {
      inputEl?.focus();
      inputEl?.setSelectionRange(cursorPos, cursorPos);
    });
  }

  function selectHistoryItem(entry: SearchHistoryEntry) {
    selectedHistoryIdx = -1;
    suggestDismissed = true;
    workbench.applyHistoryEntry(entry);
  }

  function handleMainKeydown(e: KeyboardEvent) {
    // → at the end of the input accepts the ghost text (fish-style)
    if (e.key === 'ArrowRight' && !e.shiftKey && !e.altKey && !e.metaKey && !e.ctrlKey && ghost.text) {
      const pos = inputEl?.selectionStart ?? workbench.pattern.length;
      if (pos === workbench.pattern.length && acceptGhost()) {
        e.preventDefault();
        return;
      }
    }
    // Tab with only a history ghost (no dropdown items)
    if (e.key === 'Tab' && !e.shiftKey && completion.items.length === 0 && ghost.text && acceptGhost()) {
      e.preventDefault();
      return;
    }
    const items = completion.items;
    if (items.length > 0) {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        selectedSuggestIdx = (effectiveSuggestIdx + 1) % items.length;
        return;
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        selectedSuggestIdx =
          effectiveSuggestIdx <= 0 ? items.length - 1 : effectiveSuggestIdx - 1;
        return;
      }
      // Tab always takes a suggestion; Enter only when one is selected (plain words keep Enter = search).
      if ((e.key === 'Tab' && !e.shiftKey) || (e.key === 'Enter' && effectiveSuggestIdx >= 0)) {
        const chosen = items[Math.max(0, effectiveSuggestIdx)];
        if (chosen) {
          e.preventDefault();
          applySuggestion(chosen);
          return;
        }
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        suggestDismissed = true;
        return;
      }
    }

    // Google-style History Dropdown keyboard navigation
    if (
      e.key === 'ArrowDown' &&
      suggestDismissed &&
      workbench.searchHistory.length > 0 &&
      workbench.flatHits.length === 0
    ) {
      e.preventDefault();
      suggestDismissed = false;
      selectedHistoryIdx = 0;
      return;
    }

    if (historySuggestions.length > 0) {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        selectedHistoryIdx =
          selectedHistoryIdx + 1 >= historySuggestions.length
            ? 0
            : selectedHistoryIdx + 1;
        return;
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        selectedHistoryIdx =
          selectedHistoryIdx <= 0
            ? historySuggestions.length - 1
            : selectedHistoryIdx - 1;
        return;
      }
      if (e.key === 'Enter' && selectedHistoryIdx >= 0) {
        const chosen = historySuggestions[selectedHistoryIdx];
        if (chosen) {
          e.preventDefault();
          selectHistoryItem(chosen);
          return;
        }
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        suggestDismissed = true;
        selectedHistoryIdx = -1;
        return;
      }
    }

    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      suggestDismissed = true;
      selectedHistoryIdx = -1;
      workbench.executeSearch(false);
    } else if (e.key === 'Escape') {
      if (workbench.isSearching) {
        workbench.cancelSearch();
      } else if (workbench.pattern) {
        workbench.clearSearch();
      } else {
        inputEl?.blur();
      }
    } else if (e.key === 'Tab' && !e.shiftKey && workbench.flatHits.length > 0) {
      // Move focus from the search box to the result list (j/k, Enter, [ ] take over).
      e.preventDefault();
      if (workbench.activeHitIndex < 0) workbench.selectHitByIndex(0, false);
      inputEl?.blur();
    } else if (e.key === 'ArrowDown' && workbench.flatHits.length > 0) {
      if (e.altKey) return;
      e.preventDefault();
      workbench.navigateHits(1);
    } else if (e.key === 'ArrowUp' && workbench.flatHits.length > 0) {
      if (e.altKey) return;
      e.preventDefault();
      workbench.navigateHits(-1);
    }
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
      {#if workbench.sources.length === 0}
        <button
          type="button"
          onclick={() => workbench.openSettings('add-source')}
          class="inline-flex items-center gap-1.5 text-xs text-status hover:underline"
        >
          <FolderGit2 class="h-3.5 w-3.5" />
          <span>尚未配置项目 · 点击添加本地项目目录</span>
        </button>
      {/if}
    </div>
  {/if}

  <!-- Unified Google-Style Search Box Wrapper -->
  <div class={`relative ${hero ? 'w-full max-w-[640px]' : 'w-full'}`}>
    <div
      class={`relative flex items-center gap-2.5 border transition-colors min-w-0 ${
        hero ? 'h-12 px-4' : 'h-11 px-3.5'
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

      <!-- Left Search Icon -->
      <div class="text-muted-foreground shrink-0">
        {#if workbench.isSearching}
          <Loader2 class="h-4 w-4 animate-spin text-primary" />
        {:else}
          <Search class="h-4 w-4" />
        {/if}
      </div>

      <!-- Main Search Input -->
      <!-- Input + fish-style ghost completion overlay (same font metrics, never intercepts pointer events) -->
      <div class="relative h-full min-w-0 flex-1">
      {#if ghost.text}
        <div
          aria-hidden="true"
          title={workbench.t.searchBar.acceptGhost}
          class="pointer-events-none absolute inset-0 flex items-center overflow-hidden whitespace-pre px-1 font-mono text-[14.5px]"
        >
          <span class="invisible">{workbench.pattern}</span><span class="text-muted-foreground/45">{ghost.text}</span>
        </div>
      {/if}
      <input
        bind:this={inputEl}
        type="text"
        bind:value={workbench.pattern}
        onmousedown={() => {
          suggestDismissed = false;
          requestAnimationFrame(syncCursorPos);
        }}
        onclick={syncCursorPos}
        onkeyup={syncCursorPos}
        onfocus={() => {
          isInputFocused = true;
          syncCursorPos();
        }}
        onblur={() => {
          isInputFocused = false;
          suggestDismissed = true;
          selectedHistoryIdx = -1;
        }}
        oninput={() => {
          syncCursorPos();
          suggestDismissed = false;
          selectedSuggestIdx = -1;
          selectedHistoryIdx = -1;
          workbench.scheduleSearch();
        }}
        onkeydown={handleMainKeydown}
        placeholder={workbench.hasRegexActive
          ? workbench.t.searchBar.placeholderRegex
          : workbench.t.searchBar.placeholderLiteral}
        spellcheck="false"
        autocomplete="off"
        class="relative h-full w-full min-w-0 bg-transparent px-1 font-mono text-[14.5px] text-foreground placeholder:text-muted-foreground/65 focus:outline-none"
      />
      </div>

      <!-- Clear Button -->
      {#if workbench.pattern}
        <button
          type="button"
          title={workbench.t.searchBar.clearTitle}
          onmousedown={(e) => e.preventDefault()}
          onclick={() => {
            workbench.clearSearch();
            inputEl?.focus();
          }}
          aria-label={workbench.t.searchBar.clearTitle}
          class="touch-target shrink-0 rounded-full p-1.5 text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors"
        >
          <X class="h-4 w-4" />
        </button>
      {/if}
    </div>

    {#if hasAttachedPanel}
      <div
        role="listbox"
        tabindex="-1"
        onmousedown={(e) => e.preventDefault()}
        class="absolute left-0 right-0 top-full z-40 overflow-hidden rounded-b-[22px] border border-t-0 border-border bg-card shadow-2xl"
      >
        {#if showSymbolBar}
          <div class="mx-3 border-t border-border/60"></div>
          <SymbolBar onInsert={insertSymbol} onBackspace={backspaceToken} />
        {/if}

        <!-- 1. Google-Style Seamlessly Attached Search History Dropdown -->
        {#if historySuggestions.length > 0}
          <div class="mx-3 border-t border-border/60"></div>
          <div class="max-h-52 md:max-h-64 overflow-y-auto py-1 pb-2">
            {#each historySuggestions as entry, idx (`${entry.mode}:${entry.pattern}`)}
              {@const isSelected = idx === selectedHistoryIdx}
              <div
                role="button"
                tabindex="-1"
                onmouseenter={() => (selectedHistoryIdx = idx)}
                onclick={() => selectHistoryItem(entry)}
                onkeydown={(e) => {
                  if (e.key === 'Enter') selectHistoryItem(entry);
                }}
                class={`group flex items-center justify-between gap-3 px-4 py-2.5 md:py-2 cursor-pointer transition-colors ${
                  isSelected ? 'bg-secondary/80' : 'hover:bg-secondary/50'
                }`}
              >
                <div class="flex items-center gap-3 min-w-0">
                  <Clock class="h-3.5 w-3.5 shrink-0 text-muted-foreground/75" />
                  <span class="font-mono text-[13.5px] text-foreground truncate">
                    {entry.pattern}
                  </span>
                  {#if entry.mode === 'regex'}
                    <span class="rounded bg-secondary px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground shrink-0">
                      .*
                    </span>
                  {/if}
                </div>

                <button
                  type="button"
                  onclick={(e) => {
                    e.stopPropagation();
                    workbench.removeHistoryEntry(entry.pattern, entry.mode);
                  }}
                  class="touch-target shrink-0 rounded p-1.5 text-muted-foreground/60 hover:bg-secondary hover:text-foreground"
                  title={workbench.t.ui.removeHistory}
                  aria-label={workbench.t.ui.removeHistory}
                >
                  <X class="h-3.5 w-3.5" />
                </button>
              </div>
            {/each}
          </div>
        {/if}

        <!-- 2. Unified completion: in: (data sources / file types / directories), time:, and word → qualifier -->
        {#if completion.items.length > 0}
          <div class="mx-3 border-t border-border/60"></div>
          <div class="max-h-52 md:max-h-64 overflow-y-auto space-y-0.5 p-1.5 pb-2">
            {#each completion.items as item, idx (item.key)}
              {@const isSelected = idx === effectiveSuggestIdx}
              <button
                type="button"
                onmouseenter={() => (selectedSuggestIdx = idx)}
                onclick={() => applySuggestion(item)}
                class={`flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2.5 md:py-1.5 text-left transition-colors ${
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

        <!-- 3. Tips (one-click fixes) and a plain-language reading of the query -->
        {#if tips.length > 0 || explanation}
          <div class="mx-3 border-t border-border/60"></div>
          <div class="space-y-0.5 px-4 py-2 text-[11.5px] text-muted-foreground">
            {#each tips as tip (tip.key)}
              <div class="flex items-center gap-2 min-w-0">
                <Lightbulb class="h-3 w-3 shrink-0 text-status/80" />
                <span class="truncate">{tip.text}</span>
                {#if tip.fix}
                  {@const fix = tip.fix}
                  <button
                    type="button"
                    onclick={() => applyTipFix(fix.pattern)}
                    class="touch-target shrink-0 rounded bg-primary/10 px-1.5 py-0.5 font-mono text-[11px] text-primary hover:bg-primary/20 transition-colors"
                  >
                    {fix.label}
                  </button>
                {/if}
              </div>
            {/each}
            {#if explanation}
              <div class="truncate font-mono text-[11px] text-muted-foreground/60" title={explanation}>
                {explanation}
              </div>
            {/if}
          </div>
        {/if}
      </div>
    {/if}
  </div>
</div>
