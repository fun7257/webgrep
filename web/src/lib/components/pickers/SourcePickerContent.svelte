<script lang="ts">
  import { flushSync, untrack } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import type { DataSourceItem } from '$lib/types';
  import {
    countSourcesByKind,
    fuzzyFilterSourcesForPicker,
    getSourceSubtitle,
    isSourceRefInList,
    splitHighlightRanges,
    type HighlightRange,
    type SourceKindFilter,
  } from '$lib/source-picker';
  import {
    AlertTriangle,
    Check,
    Container,
    Database,
    FileText,
    Folder,
    Minus,
    Plus,
    Search,
    Settings2,
    X,
  } from 'lucide-svelte';

  interface Props {
    inline?: boolean;
    onClose?: () => void;
    onFocusMainInput?: () => void;
    panelEl?: HTMLDivElement | null;
    onBodyKeydown?: (e: KeyboardEvent) => void;
  }

  let {
    inline = false,
    onClose,
    onFocusMainInput,
    panelEl = $bindable(null),
    onBodyKeydown,
  }: Props = $props();

  let searchQuery = $state<string>('');
  let kindFilter = $state<SourceKindFilter>('all');
  let focusedIdx = $state<number>(0);

  let searchInputEl = $state<HTMLInputElement | null>(null);
  let listEl = $state<HTMLDivElement | null>(null);
  let toggledOnDown: string | null = null;

  const s = $derived(workbench.t.scopeBar);
  const ui = $derived(workbench.t.ui);
  const counts = $derived(countSourcesByKind(workbench.sources));
  const fuzzyResults = $derived(
    fuzzyFilterSourcesForPicker(workbench.sources, kindFilter, searchQuery)
  );

  const kindTabs = $derived.by(() => {
    const out: { id: SourceKindFilter; label: string; count: number }[] = [
      { id: 'all', label: s.kindAll, count: counts.all },
    ];
    if (counts.dir > 0 || kindFilter === 'dir') out.push({ id: 'dir', label: s.kindDir, count: counts.dir });
    if (counts.file > 0 || kindFilter === 'file') out.push({ id: 'file', label: s.kindFile, count: counts.file });
    if (counts.docker > 0 || kindFilter === 'docker') {
      out.push({ id: 'docker', label: s.kindDocker, count: counts.docker });
    }
    return out;
  });

  // Only show kind bar when 2+ source kinds exist (all + >= 2 distinct kinds)
  const showKindBar = $derived(kindTabs.length >= 3);
  const hasSourceScope = $derived(
    workbench.scope.sources.length > 0 || (workbench.scope.excludedSources?.length ?? 0) > 0
  );
  const showAllRow = $derived(
    !searchQuery.trim() && kindFilter === 'all' && workbench.sources.length > 0
  );
  const allFilteredSelected = $derived.by(() => {
    if (fuzzyResults.length === 0) return false;
    const selected = workbench.scope.sources;
    return fuzzyResults.every((item) => isSourceRefInList(item.source, selected));
  });
  const canCheckFiltered = $derived(
    (searchQuery.trim().length > 0 || kindFilter !== 'all') &&
      fuzzyResults.length > 0 &&
      !allFilteredSelected
  );
  const footerText = $derived.by(() => {
    if (!hasSourceScope) return s.pickerFooterAll(workbench.enabledSourceCount);
    return s.pickerSummaryCustom(
      workbench.scope.sources.length,
      workbench.scope.excludedSources?.length ?? 0
    );
  });

  // Popover mode: desktop gets immediate autofocus on the fuzzy search input.
  // Inline hero mode leaves main search input focused.
  $effect(() => {
    untrack(() => {
      focusedIdx = showAllRow ? -1 : 0;
    });
    if (inline) return;
    queueMicrotask(() => {
      if (!workbench.sourcePickerOpen) return;
      if (!workbench.isCompact && !workbench.isTouch) {
        searchInputEl?.focus({ preventScroll: true });
      } else {
        panelEl?.focus({ preventScroll: true });
      }
    });
  });

  // Clamp keyboard index cleanly when filtered list changes
  $effect(() => {
    const minIdx = showAllRow ? -1 : 0;
    const maxIdx = fuzzyResults.length - 1;
    if (fuzzyResults.length === 0) {
      focusedIdx = showAllRow ? -1 : 0;
    } else if (focusedIdx < minIdx) {
      focusedIdx = minIdx;
    } else if (focusedIdx > maxIdx) {
      focusedIdx = maxIdx;
    }
  });

  function scrollFocusedIntoView(idx: number) {
    queueMicrotask(() => {
      const target = listEl?.querySelector(`[data-picker-idx="${idx}"]`) as HTMLElement | null;
      target?.scrollIntoView({ block: 'nearest' });
    });
  }

  function handleOptionPointerDown(key: string, e: PointerEvent, action: () => void) {
    if (e.pointerType === 'mouse' && e.button === 0 && !e.metaKey && !e.ctrlKey && !e.shiftKey) {
      e.preventDefault();
      e.stopPropagation();
      toggledOnDown = key;
      flushSync(action);
    }
  }

  function handleOptionClick(key: string, e: MouseEvent, action: () => void) {
    if (toggledOnDown === key && e.detail > 0) {
      toggledOnDown = null;
      return;
    }
    toggledOnDown = null;
    action();
  }

  function toggleItem(srcId: string, excludeMod: boolean) {
    if (excludeMod) {
      workbench.toggleExcludeScopeSource(srcId);
    } else {
      workbench.toggleScopeSource(srcId);
    }
  }

  function checkAllMatched() {
    if (fuzzyResults.length === 0) return;
    const matchedIds = new Set(fuzzyResults.map((r) => r.source.id));
    const merged = new Set(workbench.scope.sources);
    for (const id of matchedIds) merged.add(id);
    const nextExcluded = (workbench.scope.excludedSources ?? []).filter((id) => !matchedIds.has(id));
    workbench.setScopeSources(Array.from(merged), nextExcluded);
  }

  export function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      if (inline) {
        if (searchQuery) {
          searchQuery = '';
          return;
        }
        onFocusMainInput?.();
        return;
      }
      onClose?.();
      if (!workbench.isCompact && !workbench.isTouch) onFocusMainInput?.();
      return;
    }

    if (e.key === 'Tab' && !e.shiftKey) {
      e.preventDefault();
      e.stopPropagation();
      if (!inline) onClose?.();
      onFocusMainInput?.();
      return;
    }

    const minIdx = showAllRow ? -1 : 0;
    const maxIdx = fuzzyResults.length - 1;
    const hasRows = showAllRow || fuzzyResults.length > 0;

    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      if (!hasRows) return;
      e.preventDefault();
      focusedIdx =
        e.key === 'ArrowDown'
          ? focusedIdx < maxIdx
            ? focusedIdx + 1
            : minIdx
          : focusedIdx > minIdx
            ? focusedIdx - 1
            : maxIdx;
      scrollFocusedIntoView(focusedIdx);
      return;
    }

    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      if (e.metaKey || e.ctrlKey) {
        if (!inline) onClose?.();
        onFocusMainInput?.();
        if (workbench.hasExecutableQuery) workbench.submitSearch();
        return;
      }
      if (focusedIdx === -1 && showAllRow) {
        workbench.clearScopeSources();
        return;
      }
      const target = fuzzyResults[focusedIdx];
      if (target) toggleItem(target.source.id, e.altKey);
    }
  }

  function kindIconFor(src: DataSourceItem) {
    if (src.kind === 'docker') return Container;
    if (src.kind === 'file') return FileText;
    return Folder;
  }

  function optionRowClass(checked: boolean, excluded: boolean, isFocused: boolean): string {
    const base = checked
      ? 'bg-primary/[0.08] hover:bg-primary/[0.12]'
      : excluded
        ? 'bg-status/[0.08] hover:bg-status/[0.12]'
        : isFocused
          ? 'bg-secondary/80'
          : 'hover:bg-secondary/55';
    return `${base}${isFocused && checked ? ' ring-1 ring-inset ring-primary/35' : ''}`;
  }
</script>

{#snippet renderHighlighted(text: string, ranges: readonly HighlightRange[])}
  {#each splitHighlightRanges(text, ranges) as piece, i (i)}
    {#if piece.match}
      <span class="font-semibold text-primary">{piece.text}</span>
    {:else}
      {piece.text}
    {/if}
  {/each}
{/snippet}

{#snippet checkIndicator(checked: boolean, excluded: boolean)}
  <span
    aria-hidden="true"
    class={`flex h-4 w-4 shrink-0 items-center justify-center rounded-[4px] border ${
      checked
        ? 'border-primary bg-primary text-primary-foreground'
        : excluded
          ? 'border-status bg-status/15 text-status'
          : 'border-border bg-background/75 group-hover:border-muted-foreground/60'
    }`}
  >
    {#if checked}
      <Check class="h-3 w-3 stroke-[2.75]" />
    {:else if excluded}
      <Minus class="h-3 w-3 stroke-[2.5]" />
    {/if}
  </span>
{/snippet}

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  onkeydown={inline ? (onBodyKeydown ?? handleKeydown) : undefined}
  class={inline ? 'flex flex-col overflow-hidden rounded-2xl border border-border/55 bg-card/55 shadow-sm' : 'flex min-h-0 flex-1 flex-col'}
>
  <!-- 1. Top Fuzzy Search Input Bar -->
  <div class={`flex shrink-0 items-center gap-2 border-b border-border/55 px-3 ${inline ? 'h-9' : 'h-10'}`}>
    <Search class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
    <input
      bind:this={searchInputEl}
      type="text"
      bind:value={searchQuery}
      oninput={() => {
        focusedIdx = 0;
      }}
      placeholder={s.pickerSearchPlaceholder}
      spellcheck="false"
      autocomplete="off"
      class="h-full min-w-0 flex-1 bg-transparent text-[13px] [@media(any-pointer:coarse)]:text-[16px] text-foreground placeholder:text-muted-foreground/60 focus:outline-none"
    />

    {#if searchQuery.length > 0}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => {
          searchQuery = '';
          focusedIdx = showAllRow ? -1 : 0;
          searchInputEl?.focus();
        }}
        title={workbench.t.searchBar.clearDraftTitle}
        aria-label={workbench.t.searchBar.clearDraftTitle}
        class="touch-target flex h-6 w-6 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
      >
        <X class="h-3.5 w-3.5" />
      </button>
    {/if}

    {#if canCheckFiltered}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={checkAllMatched}
        class="touch-target inline-flex h-6 shrink-0 items-center rounded-md border border-border/65 bg-secondary/70 px-2 text-[11px] font-medium text-foreground hover:bg-secondary active:bg-secondary/80 cursor-pointer"
      >
        {s.checkFiltered(fuzzyResults.length)}
      </button>
    {:else if hasSourceScope && !searchQuery.trim()}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => workbench.clearScopeSources()}
        class="touch-target inline-flex h-6 shrink-0 items-center rounded-md px-2 text-[11px] font-medium text-muted-foreground hover:bg-secondary hover:text-foreground active:bg-secondary/80 cursor-pointer"
      >
        {s.resetToAll}
      </button>
    {/if}

    {#if inline}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => workbench.openSourcesDrawer(false)}
        title={workbench.t.header.sourcesTitle}
        aria-label={workbench.t.header.sourcesTitle}
        class="touch-target flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary hover:text-foreground cursor-pointer"
      >
        <Settings2 class="h-3.5 w-3.5" />
      </button>
    {/if}
  </div>

  <!-- 2. Progressive Kind Filter Bar (only when 2+ source kinds exist) -->
  {#if showKindBar}
    <div class="shrink-0 border-b border-border/45 px-2.5 py-1.5">
      <div class="flex items-center gap-0.5 rounded-lg border border-border/50 bg-secondary/65 dark:bg-secondary/55 p-0.5">
        {#each kindTabs as tab (tab.id)}
          {@const active = kindFilter === tab.id}
          {@const selectKind = () => {
            kindFilter = tab.id;
            focusedIdx = tab.id === 'all' && !searchQuery.trim() ? -1 : 0;
          }}
          <button
            type="button"
            onmousedown={(e) => e.preventDefault()}
            onpointerdown={(e) => handleOptionPointerDown(`kind:${tab.id}`, e, selectKind)}
            onclick={(e) => handleOptionClick(`kind:${tab.id}`, e, selectKind)}
            class={`touch-target inline-flex h-6 flex-1 items-center justify-center gap-1 rounded-md px-2 text-[11.5px] cursor-pointer ${
              active
                ? 'bg-background dark:bg-secondary text-foreground font-medium shadow-[0_1px_2px_hsl(0_0%_0%/0.06)] ring-1 ring-inset ring-border/70'
                : 'text-muted-foreground hover:text-foreground'
            }`}
          >
            <span class="truncate">{tab.label}</span>
            <span class="font-mono text-[10px] tabular-nums opacity-65">{tab.count}</span>
          </button>
        {/each}
      </div>
    </div>
  {/if}

  <!-- 3. Checkable Data Source List -->
  <div
    bind:this={listEl}
    role="listbox"
    aria-multiselectable="true"
    aria-label={s.pickerTitle}
    class={`min-h-0 overflow-y-auto overscroll-contain p-1.5 space-y-0.5 ${
      inline
        ? 'h-[248px] sm:h-[268px] shrink-0'
        : workbench.isCompact
          ? 'flex-1 min-h-[220px]'
          : 'h-[300px] shrink-0'
    }`}
  >
    {#if workbench.sources.length === 0}
      <div class="flex h-full flex-col items-center justify-center gap-2.5 px-4 text-center">
        <Database class="h-5 w-5 text-muted-foreground/55" />
        <span class="text-xs text-muted-foreground">{s.noSourcesHint}</span>
        <button
          type="button"
          onclick={() => {
            if (!inline) onClose?.();
            workbench.openSourcesDrawer(true);
          }}
          class="touch-target inline-flex h-7 items-center gap-1 rounded-md border border-border/70 bg-secondary/60 px-2.5 text-xs font-medium text-foreground hover:bg-secondary active:bg-secondary/80 cursor-pointer"
        >
          <Plus class="h-3.5 w-3.5 shrink-0" />
          <span>{s.addSourcePill}</span>
        </button>
      </div>
    {:else}
      {#if showAllRow}
        {@const allChecked = !hasSourceScope}
        {@const clearAll = () => workbench.clearScopeSources()}
        <button
          type="button"
          role="option"
          data-picker-idx="-1"
          aria-selected={allChecked}
          onmousedown={(e) => e.preventDefault()}
          onpointerdown={(e) => handleOptionPointerDown('all', e, clearAll)}
          onclick={(e) => handleOptionClick('all', e, clearAll)}
          onmouseenter={() => (focusedIdx = -1)}
          class={`touch-target group flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left cursor-pointer ${optionRowClass(allChecked, false, (!inline || searchQuery.trim().length > 0) && focusedIdx === -1)}`}
        >
          {@render checkIndicator(allChecked, false)}
          <Database class={`h-3.5 w-3.5 shrink-0 ${allChecked ? 'text-primary' : 'text-muted-foreground'}`} />
          <span class="min-w-0 flex-1 truncate text-[12.5px] font-medium text-foreground">
            {s.allSources}
          </span>
          <span class="shrink-0 rounded-full bg-secondary/75 px-1.5 py-0.5 font-mono text-[10.5px] tabular-nums text-muted-foreground">
            {workbench.enabledSourceCount}
          </span>
        </button>
        <div class="mx-1.5 my-1 border-t border-border/45"></div>
      {/if}

      {#if fuzzyResults.length === 0}
        <div class="flex h-full items-center justify-center px-3 text-center text-xs text-muted-foreground">
          {s.pickerNoMatch}
        </div>
      {:else}
        {#each fuzzyResults as entry, idx (entry.source.id)}
          {@const src = entry.source}
          {@const checked = isSourceRefInList(src, workbench.scope.sources)}
          {@const excluded = isSourceRefInList(src, workbench.scope.excludedSources ?? [])}
          {@const Icon = kindIconFor(src)}
          {@const subtitle = getSourceSubtitle(src)}
          {@const showFocused = !inline && focusedIdx === idx}
          <button
            type="button"
            role="option"
            data-picker-idx={idx}
            aria-selected={checked}
            onmousedown={(e) => e.preventDefault()}
            onpointerdown={(e) => handleOptionPointerDown(`src:${src.id}`, e, () => toggleItem(src.id, e.altKey))}
            onclick={(e) => handleOptionClick(`src:${src.id}`, e, () => toggleItem(src.id, e.altKey))}
            onmouseenter={() => (focusedIdx = idx)}
            title={s.cardClickTitle(src.name)}
            class={`touch-target group flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left cursor-pointer ${optionRowClass(checked, excluded, showFocused)} ${!src.enabled && !checked ? 'opacity-65' : ''}`}
          >
            {@render checkIndicator(checked, excluded)}
            {#if !src.exists}
              <AlertTriangle class="h-3.5 w-3.5 shrink-0 text-status" />
            {:else}
              <Icon class={`h-3.5 w-3.5 shrink-0 ${checked ? 'text-primary' : excluded ? 'text-status' : 'text-muted-foreground'}`} />
            {/if}
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-1.5 min-w-0">
                <span class={`truncate font-mono text-[12.5px] font-medium ${excluded ? 'line-through text-status' : 'text-foreground'}`}>
                  {@render renderHighlighted(src.name, entry.nameRanges)}
                </span>
                {#if !src.enabled}
                  <span class="shrink-0 rounded bg-secondary px-1 py-0.2 text-[10px] text-muted-foreground">
                    {ui.disabled}
                  </span>
                {/if}
              </div>
              <div class="truncate font-mono text-[11px] text-muted-foreground/75">
                {@render renderHighlighted(subtitle, entry.subtitleRanges)}
              </div>
            </div>
          </button>
        {/each}
      {/if}
    {/if}
  </div>

  <!-- 4. Bottom Status & Hint Footer -->
  <div class="flex h-8 shrink-0 items-center justify-between gap-2 border-t border-border/50 bg-muted/30 px-3 text-[11px] text-muted-foreground">
    <span class="truncate font-mono tabular-nums">{footerText}</span>
    <span class="hidden sm:inline shrink-0 text-muted-foreground/75">{s.pickerKeyHint}</span>
  </div>
</div>
