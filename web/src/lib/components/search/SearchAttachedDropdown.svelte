<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { getHistoryScopeFlags } from '$lib/query';
  import type { QueryStep, SearchHistoryEntry } from '$lib/types';
  import type { Suggestion } from '$lib/suggest';
  import SymbolBar from '../SymbolBar.svelte';
  import { Clock, Database, History, Lightbulb, X } from 'lucide-svelte';

  interface Props {
    showSymbolBar: boolean;
    historySuggestions: readonly SearchHistoryEntry[];
    wordItems: readonly Suggestion[];
    regexTip: { text: string } | null;
    activeIdx: number;
    onInsertSymbol: (sym: string) => void;
    onSelectHistory: (index: number) => void;
    onSelectWord: (suggestion: Suggestion) => void;
    onEnableRegex: () => void;
  }

  let {
    showSymbolBar,
    historySuggestions,
    wordItems,
    regexTip,
    activeIdx = $bindable(-1),
    onInsertSymbol,
    onSelectHistory,
    onSelectWord,
    onEnableRegex,
  }: Props = $props();

  function stepFlagTag(step: QueryStep): string {
    let tags = '';
    if (step.caseSensitive) tags += 'Aa ';
    if (step.wholeWord) tags += 'ab ';
    if (step.isRegex) tags += '.*';
    return tags.trim();
  }
</script>

<div
  role="listbox"
  tabindex="-1"
  onmousedown={(e) => e.preventDefault()}
  class="absolute left-0 right-0 top-full z-40 overflow-hidden rounded-b-[22px] border border-t-0 border-border bg-card shadow-2xl"
>
  {#if showSymbolBar}
    <div class="mx-3 border-t border-border/60"></div>
    <SymbolBar onInsert={onInsertSymbol} />
  {/if}

  {#if historySuggestions.length > 0}
    <div class="mx-3 border-t border-border/60"></div>
    <div class="max-h-52 md:max-h-64 overflow-y-auto py-1 pb-2">
      {#each historySuggestions as entry, hi (entry.id)}
        {@const isSelected = hi === activeIdx}
        {@const scopeFlags = getHistoryScopeFlags(entry.scope)}
        <div
          role="button"
          tabindex="-1"
          onmouseenter={() => (activeIdx = hi)}
          onpointerdown={() => (activeIdx = hi)}
          onclick={() => onSelectHistory(hi)}
          onkeydown={(e) => {
            if (e.key === 'Enter') onSelectHistory(hi);
          }}
          class={`group flex items-center justify-between gap-3 px-4 py-2.5 md:py-2 cursor-pointer active:bg-secondary ${
            isSelected ? 'bg-secondary/80' : 'hover:bg-secondary/50'
          }`}
        >
          <div class="flex items-center gap-2 min-w-0">
            <History class="h-3.5 w-3.5 shrink-0 text-muted-foreground/70" />
            <span class="font-mono text-[13.5px] text-foreground truncate">{entry.label}</span>
            {#if entry.draft && stepFlagTag(entry.draft)}
              <span class="rounded bg-secondary px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground shrink-0">
                {stepFlagTag(entry.draft)}
              </span>
            {/if}
            {#if scopeFlags.hasSources}
              <span
                title={workbench.t.searchBar.historyHasSourceTitle}
                aria-label={workbench.t.searchBar.historyHasSourceTitle}
                class="inline-flex h-4 w-4 items-center justify-center rounded bg-primary/10 text-primary ring-1 ring-inset ring-primary/20 shrink-0"
              >
                <Database class="h-2.5 w-2.5 shrink-0" />
              </span>
            {/if}
            {#if scopeFlags.hasTime}
              <span
                title={workbench.t.searchBar.historyHasTimeTitle}
                aria-label={workbench.t.searchBar.historyHasTimeTitle}
                class="inline-flex h-4 w-4 items-center justify-center rounded bg-primary/10 text-primary ring-1 ring-inset ring-primary/20 shrink-0"
              >
                <Clock class="h-2.5 w-2.5 shrink-0" />
              </span>
            {/if}
          </div>

          <button
            type="button"
            onclick={(e) => {
              e.stopPropagation();
              workbench.removeHistoryEntry(entry.id);
            }}
            class="touch-target shrink-0 rounded p-1.5 text-muted-foreground/70 hover:bg-secondary hover:text-foreground cursor-pointer"
            title={workbench.t.ui.removeHistory}
            aria-label={workbench.t.ui.removeHistory}
          >
            <X class="h-3.5 w-3.5" />
          </button>
        </div>
      {/each}
    </div>
  {/if}

  {#if wordItems.length > 0}
    <div class="mx-3 border-t border-border/60"></div>
    <div class="max-h-52 md:max-h-64 overflow-y-auto space-y-0.5 p-1.5 pb-2">
      {#each wordItems as item, wi (item.key)}
        {@const idx = historySuggestions.length + wi}
        {@const isSelected = idx === activeIdx}
        <button
          type="button"
          onmouseenter={() => (activeIdx = idx)}
          onpointerdown={() => (activeIdx = idx)}
          onclick={() => onSelectWord(item)}
          class={`flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2.5 md:py-1.5 text-left cursor-pointer active:bg-secondary ${
            isSelected ? 'bg-secondary text-foreground' : 'text-foreground hover:bg-secondary/60'
          }`}
        >
          <span class="truncate font-mono text-xs font-medium">{item.label}</span>
          {#if item.hint}
            <span class="shrink-0 font-mono text-[11px] tabular-nums text-muted-foreground/70">{item.hint}</span>
          {/if}
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
          onclick={onEnableRegex}
          class="touch-target shrink-0 rounded bg-primary/10 px-1.5 py-0.5 font-mono text-[11px] text-primary hover:bg-primary/20 active:bg-primary/25 cursor-pointer"
        >
          {workbench.t.searchBar.enableRegexAction}
        </button>
      </div>
    </div>
  {/if}
</div>
