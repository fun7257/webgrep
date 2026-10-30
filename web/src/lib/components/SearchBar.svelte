<script lang="ts">
  import { parseDollarFlags, workbench } from '$lib/state.svelte';
  import type { SearchHistoryEntry } from '$lib/types';
  import {
    Check,
    Clock,
    FolderGit2,
    Loader2,
    Search,
    X,
  } from 'lucide-svelte';
  import SymbolBar from './SymbolBar.svelte';

  interface Props {
    inputEl?: HTMLInputElement | null;
    hero?: boolean;
  }

  let { inputEl = $bindable(null), hero = false }: Props = $props();
  let selectedSuggestIdx = $state(0);
  let selectedHistoryIdx = $state(-1);
  let suggestDismissed = $state(true);
  let isInputFocused = $state(false);
  let cursorPos = $state(-1);

  function syncCursorPos() {
    if (inputEl && typeof inputEl.selectionStart === 'number') {
      cursorPos = inputEl.selectionStart;
    } else {
      cursorPos = workbench.pattern.length;
    }
  }

  interface ScopeSuggestItem {
    id: string;
    label: string;
    path: string;
    enabled: boolean;
  }

  // Detect if the active token at cursor (or end of input) is an @project query
  let activeAtToken = $derived.by(() => {
    const raw = workbench.pattern;
    const head =
      cursorPos >= 0 && cursorPos <= raw.length ? raw.slice(0, cursorPos) : raw;
    const tail =
      cursorPos >= 0 && cursorPos <= raw.length ? raw.slice(cursorPos) : '';
    if (tail.length > 0 && !/^\s/.test(tail)) return null;

    const match = /(?:^|\s)([-!]?@)([^\s]*)$/.exec(head);
    if (!match) return null;
    const tokenStart = match.index + (head[match.index] === ' ' ? 1 : 0);
    return {
      prefix: match[1],
      rawQuery: match[2],
      query: match[2].toLowerCase(),
      tokenStart,
      tokenEnd: head.length,
    };
  });

  // Detect if the active token at cursor (or end of input) is a scoped $ modifier query (e.g. "$", "$r", "$c", "$w", "$rc")
  let activeDollarToken = $derived.by(() => {
    const raw = workbench.pattern;
    const head =
      cursorPos >= 0 && cursorPos <= raw.length ? raw.slice(0, cursorPos) : raw;
    const tail =
      cursorPos >= 0 && cursorPos <= raw.length ? raw.slice(cursorPos) : '';
    if (tail.length > 0 && !/^\s/.test(tail)) return null;

    const match = /(?:^|\s)([-+!]?\$)([^\s(]*)$/.exec(head);
    if (!match) return null;
    const tokenStart = match.index + (head[match.index] === ' ' ? 1 : 0);
    return {
      prefix: match[1],
      query: match[2].toLowerCase(),
      tokenStart,
      tokenEnd: head.length,
    };
  });

  // Google-style search history suggestions:
  // Shown when input is focused, neither @scope nor $flag autocomplete is active, and not dismissed.
  let historySuggestions = $derived.by((): SearchHistoryEntry[] => {
    if (!isInputFocused || suggestDismissed || activeAtToken || activeDollarToken) {
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

  // Project-only @ autocomplete: only recognizes configured projects (by name or UUID)
  let scopeSuggestions = $derived.by((): ScopeSuggestItem[] => {
    if (!activeAtToken || suggestDismissed) return [];
    const q = activeAtToken.query.replace(/^[/\\-]+/, '');
    const out: ScopeSuggestItem[] = [];
    const maxItems = 12;

    for (const src of workbench.sources) {
      if (out.length >= maxItems) break;
      if (
        !q ||
        src.name.toLowerCase().includes(q) ||
        src.id.toLowerCase().includes(q)
      ) {
        out.push({
          id: src.id,
          label: src.name,
          path: src.path,
          enabled: src.enabled,
        });
      }
    }

    return out;
  });

  let flagSuggestions = $derived.by(() => {
    if (!activeDollarToken || suggestDismissed) return [];
    const q = activeDollarToken.query;

    const primaryFlags = [
      {
        token: '$r()',
        badge: '.*',
        label: workbench.t.searchBar.flagRegexLabel,
        desc: workbench.t.searchBar.flagRegexDesc,
        aliases: ['r', 're', 'regex', '.*'],
        disabled: false,
      },
      {
        token: '$c()',
        badge: 'Aa',
        label: workbench.t.searchBar.flagCaseLabel,
        desc: workbench.t.searchBar.flagCaseDesc,
        aliases: ['c', 'case', 'aa', 's'],
        disabled: false,
      },
      {
        token: '$w()',
        badge: '\\b',
        label: workbench.t.searchBar.flagWordLabel,
        desc: workbench.t.searchBar.flagWordDesc,
        aliases: ['w', 'word', 'b', '\\b'],
        disabled: false,
      },
    ];

    const comboFlags = [
      {
        token: '$rc()',
        badge: '.* Aa',
        label:
          workbench.locale === 'zh'
            ? '局部正则 + 区分大小写 $rc(...)'
            : 'Scoped Regex + Match Case $rc(...)',
        desc: '',
        aliases: ['rc', 'cr'],
        disabled: false,
      },
      {
        token: '$rw()',
        badge: '.* \\b',
        label:
          workbench.locale === 'zh'
            ? '局部正则 + 全词匹配 $rw(...)'
            : 'Scoped Regex + Whole Word $rw(...)',
        desc: '',
        aliases: ['rw', 'wr'],
        disabled: false,
      },
      {
        token: '$cw()',
        badge: 'Aa \\b',
        label:
          workbench.locale === 'zh'
            ? '局部区分大小写 + 全词匹配 $cw(...)'
            : 'Scoped Match Case + Whole Word $cw(...)',
        desc: '',
        aliases: ['cw', 'wc'],
        disabled: false,
      },
      {
        token: '$rcw()',
        badge: '.* Aa \\b',
        label:
          workbench.locale === 'zh'
            ? '局部正则 + 区分大小写 + 全词 $rcw(...)'
            : 'Scoped Regex + Case + Whole Word $rcw(...)',
        desc: '',
        aliases: ['rcw', 'rwc', 'crw', 'cwr', 'wrc', 'wcr'],
        disabled: false,
      },
    ];

    if (!q) return primaryFlags;
    const allFlags = [...primaryFlags, ...comboFlags];
    return allFlags.filter(
      (item) =>
        item.token.slice(1, -2).startsWith(q) ||
        item.aliases.some((a) => a.startsWith(q)) ||
        item.label.toLowerCase().includes(q)
    );
  });

  let effectiveFlagIdx = $derived.by(() => {
    if (flagSuggestions.length === 0) return -1;
    const candidate = flagSuggestions[selectedSuggestIdx];
    if (candidate && !candidate.disabled) return selectedSuggestIdx;
    return flagSuggestions.findIndex((item) => !item.disabled);
  });

  const hasOpenDropdown = $derived(
    (flagSuggestions.length > 0 && Boolean(activeDollarToken)) ||
      (scopeSuggestions.length > 0 && Boolean(activeAtToken)) ||
      historySuggestions.length > 0
  );

  function applyScopeSuggestion(scopeLabel: string) {
    if (!activeAtToken) return;
    const before = workbench.pattern.slice(0, activeAtToken.tokenStart);
    const after = workbench.pattern.slice(activeAtToken.tokenEnd);
    const inserted = `${activeAtToken.prefix}${scopeLabel} `;
    workbench.pattern = `${before}${inserted}${after.replace(/^\s+/, '')}`;
    const nextCursor = before.length + inserted.length;
    cursorPos = nextCursor;
    suggestDismissed = false;
    selectedSuggestIdx = 0;
    workbench.scheduleSearch(true);
    requestAnimationFrame(() => {
      inputEl?.focus();
      inputEl?.setSelectionRange(nextCursor, nextCursor);
    });
  }

  function applyFlagSuggestion(flagToken: string) {
    if (!activeDollarToken) return;
    const before = workbench.pattern.slice(0, activeDollarToken.tokenStart);
    const after = workbench.pattern.slice(activeDollarToken.tokenEnd);
    const signPrefix = activeDollarToken.prefix.startsWith('-')
      ? '-'
      : activeDollarToken.prefix.startsWith('+')
        ? '+'
        : activeDollarToken.prefix.startsWith('!')
          ? '!'
          : '';
    const inserted = `${signPrefix}${flagToken}`;
    workbench.pattern = `${before}${inserted}${after}`;
    const nextCursor = before.length + inserted.length - 1;
    cursorPos = nextCursor;
    suggestDismissed = false;
    selectedSuggestIdx = 0;
    requestAnimationFrame(() => {
      inputEl?.focus();
      inputEl?.setSelectionRange(nextCursor, nextCursor);
    });
  }

  function insertSymbol(sym: string) {
    if (!inputEl) return;
    const raw = workbench.pattern;
    const pos = Math.min(inputEl.selectionStart ?? raw.length, raw.length);
    const before = raw.slice(0, pos);
    const after = raw.slice(pos);
    const needSpace = before.length > 0 && !/\s$/.test(before);
    const paired = sym === '"';
    const inserted = `${needSpace ? ' ' : ''}${paired ? '""' : sym}`;
    workbench.pattern = `${before}${inserted}${after}`;
    const nextCursor = before.length + inserted.length - (paired ? 1 : 0);
    cursorPos = nextCursor;
    suggestDismissed = false;
    selectedSuggestIdx = 0;
    workbench.scheduleSearch();
    requestAnimationFrame(() => {
      inputEl?.focus();
      inputEl?.setSelectionRange(nextCursor, nextCursor);
    });
  }

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
    // Auto-pair `$r(` / `$c(` / `$w(` / `$rc(` -> `$r(|)` / `$c(|)` / `$w(|)` when typing `(`
    if (e.key === '(' && activeDollarToken && activeDollarToken.query) {
      const df = parseDollarFlags(`$${activeDollarToken.query}`);
      if (df) {
        e.preventDefault();
        const before = workbench.pattern.slice(0, activeDollarToken.tokenStart);
        const after = workbench.pattern.slice(activeDollarToken.tokenEnd);
        const inserted = `${activeDollarToken.prefix}${activeDollarToken.query}()`;
        workbench.pattern = `${before}${inserted}${after}`;
        const nextCursor = before.length + inserted.length - 1;
        cursorPos = nextCursor;
        suggestDismissed = false;
        selectedSuggestIdx = 0;
        requestAnimationFrame(() => {
          inputEl?.focus();
          inputEl?.setSelectionRange(nextCursor, nextCursor);
        });
        return;
      }
    }

    if (flagSuggestions.length > 0 && activeDollarToken) {
      const enabledIndices = flagSuggestions
        .map((item, idx) => (item.disabled ? -1 : idx))
        .filter((idx) => idx >= 0);

      if (e.key === 'ArrowDown') {
        e.preventDefault();
        if (enabledIndices.length > 0) {
          const curPos = enabledIndices.indexOf(effectiveFlagIdx);
          selectedSuggestIdx = enabledIndices[(curPos + 1) % enabledIndices.length];
        }
        return;
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        if (enabledIndices.length > 0) {
          const curPos = enabledIndices.indexOf(effectiveFlagIdx);
          selectedSuggestIdx =
            enabledIndices[(curPos - 1 + enabledIndices.length) % enabledIndices.length];
        }
        return;
      }
      if (e.key === 'Tab' || e.key === 'Enter') {
        if (effectiveFlagIdx >= 0) {
          const chosen = flagSuggestions[effectiveFlagIdx];
          if (chosen && !chosen.disabled) {
            e.preventDefault();
            applyFlagSuggestion(chosen.token);
            return;
          }
        }
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        suggestDismissed = true;
        return;
      }
    }

    if (scopeSuggestions.length > 0 && activeAtToken) {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        selectedSuggestIdx = (selectedSuggestIdx + 1) % scopeSuggestions.length;
        return;
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        selectedSuggestIdx =
          (selectedSuggestIdx - 1 + scopeSuggestions.length) % scopeSuggestions.length;
        return;
      }
      if (e.key === 'Tab' || e.key === 'Enter') {
        const chosen = scopeSuggestions[selectedSuggestIdx] ?? scopeSuggestions[0];
        if (chosen) {
          e.preventDefault();
          applyScopeSuggestion(chosen.label);
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
      !activeAtToken &&
      !activeDollarToken &&
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
    ? 'flex flex-1 flex-col items-center justify-center px-3 md:px-6 pb-[14vh] select-none'
    : 'relative px-3 md:px-6 pt-2 md:pt-3 pb-1.5 select-none'}
>
  {#if hero}
    <!-- Google-Style Centered Brand Wordmark -->
    <div class="mb-7 flex flex-col items-center gap-2 text-center">
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
        hasOpenDropdown
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
          selectedSuggestIdx = 0;
          selectedHistoryIdx = -1;
          workbench.scheduleSearch();
        }}
        onkeydown={handleMainKeydown}
        placeholder={workbench.hasRegexActive
          ? workbench.t.searchBar.placeholderRegex
          : workbench.t.searchBar.placeholderLiteral}
        spellcheck="false"
        autocomplete="off"
        class="h-full min-w-0 flex-1 bg-transparent px-1 font-mono text-[14.5px] text-foreground placeholder:text-muted-foreground/65 focus:outline-none"
      />

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

    <!-- 1. Google-Style Seamlessly Attached Search History Dropdown -->
    {#if historySuggestions.length > 0}
      <div
        role="listbox"
        tabindex="-1"
        onmousedown={(e) => e.preventDefault()}
        class="absolute left-0 right-0 top-full z-40 overflow-hidden rounded-b-[22px] border border-t-0 border-border bg-card pb-2 shadow-2xl"
      >
        <div class="mx-4 border-t border-border/60"></div>
        <div class="py-1">
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
                {#if entry.caseMode === 'sensitive'}
                  <span class="rounded bg-secondary px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground shrink-0">
                    Aa
                  </span>
                {/if}
                {#if entry.wholeWord}
                  <span class="rounded bg-secondary px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground shrink-0">
                    \b
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
                title={workbench.locale === 'zh' ? '从搜索记录中删除' : 'Remove from history'}
                aria-label={workbench.locale === 'zh' ? '从搜索记录中删除' : 'Remove from history'}
              >
                <X class="h-3.5 w-3.5" />
              </button>
            </div>
          {/each}
        </div>
      </div>
    {/if}

    <!-- 2. Seamlessly Attached $flag Mode Autocomplete Dropdown -->
    {#if flagSuggestions.length > 0 && activeDollarToken}
      <div
        role="listbox"
        tabindex="-1"
        onmousedown={(e) => e.preventDefault()}
        class="absolute left-0 right-0 top-full z-40 overflow-hidden rounded-b-[22px] border border-t-0 border-border bg-card p-1.5 pb-2 shadow-2xl"
      >
        <div class="mx-2.5 mb-1 border-t border-border/50"></div>
        <div class="space-y-0.5">
          {#each flagSuggestions as item, idx (item.token)}
            {@const isSelected = !item.disabled && idx === effectiveFlagIdx}
            <button
              type="button"
              disabled={item.disabled}
              onclick={() => applyFlagSuggestion(item.token)}
              class={`flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2.5 md:py-1.5 text-left transition-colors ${
                item.disabled
                  ? 'opacity-45 cursor-not-allowed text-muted-foreground'
                  : isSelected
                    ? 'bg-secondary text-foreground'
                    : 'text-foreground hover:bg-secondary/60'
              }`}
            >
              <div class="flex items-center gap-2.5 min-w-0">
                <span class="font-mono text-xs font-semibold text-foreground shrink-0 w-12">
                  {item.token}
                </span>
                <span class="text-xs text-muted-foreground truncate">
                  {item.label}
                </span>
              </div>
              {#if item.disabled}
                <Check class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
              {/if}
            </button>
          {/each}
        </div>
      </div>
    {/if}

    <!-- 3. Seamlessly Attached Project-Only @ Autocomplete Dropdown -->
    {#if scopeSuggestions.length > 0 && activeAtToken}
      <div
        role="listbox"
        tabindex="-1"
        onmousedown={(e) => e.preventDefault()}
        class="absolute left-0 right-0 top-full z-40 overflow-hidden rounded-b-[22px] border border-t-0 border-border bg-card p-1.5 pb-2 shadow-2xl"
      >
        <div class="mx-2.5 mb-1 border-t border-border/50"></div>
        <div class="max-h-64 overflow-y-auto space-y-0.5">
          {#each scopeSuggestions as item, idx (item.id)}
            {@const isSelected = idx === selectedSuggestIdx}
            <button
              type="button"
              onmouseenter={() => (selectedSuggestIdx = idx)}
              onclick={() => applyScopeSuggestion(item.label)}
              class={`flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2.5 md:py-1.5 font-mono text-xs text-left transition-colors ${
                isSelected
                  ? 'bg-secondary text-foreground'
                  : 'text-foreground hover:bg-secondary/60'
              }`}
            >
              <span class="truncate font-medium">@{item.label}</span>
              <span class="truncate text-[11px] text-muted-foreground/60">
                {item.path}
              </span>
            </button>
          {/each}
        </div>
      </div>
    {/if}
  </div>
</div>

{#if workbench.isCompact && isInputFocused}
  <SymbolBar onInsert={insertSymbol} onBackspace={backspaceToken} />
{/if}
