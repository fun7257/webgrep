<script lang="ts">
  import { flushSync, untrack } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import type { DataSourceItem } from '$lib/types';
  import {
    fuzzyFilterSourcesForPicker,
    getSourceSubtitle,
    isSourceRefInList,
    splitHighlightRanges,
    type HighlightRange,
  } from '$lib/source-picker';
  import { resolveSourcePluginPreset } from '$lib/prefilter';
  import {
    AlertTriangle,
    Check,
    CheckCheck,
    Code2,
    Database,
    FileText,
    Folder,
    Minus,
    Plus,
    ScrollText,
    Search,
    X,
  } from 'lucide-svelte';

  interface Props {
    sidebar?: boolean;
    onClose?: () => void;
    onFocusMainInput?: () => void;
  }

  let {
    sidebar = false,
    onClose,
    onFocusMainInput,
  }: Props = $props();

  let searchQuery = $state<string>('');
  let focusedIdx = $state<number>(0);

  let searchInputEl = $state<HTMLInputElement | null>(null);
  let listEl = $state<HTMLDivElement | null>(null);
  let toggledOnDown: string | null = null;

  const s = $derived(workbench.t.scopeBar);
  const ui = $derived(workbench.t.ui);
  const fuzzyResults = $derived(
    fuzzyFilterSourcesForPicker(workbench.sources, 'all', searchQuery)
  );

  const allFilteredSelected = $derived.by(() => {
    if (fuzzyResults.length === 0) return false;
    const selected = workbench.scope.sources;
    return fuzzyResults.every((item) => isSourceRefInList(item.source, selected));
  });
  const canCheckFiltered = $derived(
    searchQuery.trim().length > 0 && fuzzyResults.length > 0 && !allFilteredSelected
  );

  $effect(() => {
    untrack(() => {
      focusedIdx = 0;
    });
    if (sidebar) return;
    queueMicrotask(() => {
      if (!workbench.isCompact && !workbench.isTouch) {
        searchInputEl?.focus({ preventScroll: true });
      }
    });
  });

  $effect(() => {
    const maxIdx = fuzzyResults.length - 1;
    if (fuzzyResults.length === 0) {
      focusedIdx = 0;
    } else if (focusedIdx < 0) {
      focusedIdx = 0;
    } else if (focusedIdx > maxIdx) {
      focusedIdx = maxIdx;
    }
  });

  function scrollFocusedIntoView(idx: number) {
    queueMicrotask(() => {
      if (!listEl) return;
      const target = listEl.querySelector(`[data-picker-idx="${idx}"]`) as HTMLElement | null;
      if (!target) return;
      const listRect = listEl.getBoundingClientRect();
      const targetRect = target.getBoundingClientRect();
      if (targetRect.top < listRect.top) {
        listEl.scrollTop -= listRect.top - targetRect.top + 6;
      } else if (targetRect.bottom > listRect.bottom) {
        listEl.scrollTop += targetRect.bottom - listRect.bottom + 6;
      }
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
      if (sidebar) {
        if (searchQuery) {
          searchQuery = '';
          return;
        }
        if (onClose) {
          onClose();
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
      if (!sidebar) onClose?.();
      onFocusMainInput?.();
      return;
    }

    const maxIdx = fuzzyResults.length - 1;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      if (fuzzyResults.length === 0) return;
      e.preventDefault();
      focusedIdx =
        e.key === 'ArrowDown'
          ? focusedIdx < maxIdx
            ? focusedIdx + 1
            : 0
          : focusedIdx > 0
            ? focusedIdx - 1
            : maxIdx;
      scrollFocusedIntoView(focusedIdx);
      return;
    }

    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      if (e.metaKey || e.ctrlKey) {
        if (!sidebar) onClose?.();
        onFocusMainInput?.();
        if (workbench.hasExecutableQuery) workbench.submitSearch();
        return;
      }
      const target = fuzzyResults[focusedIdx];
      if (target) toggleItem(target.source.id, e.altKey);
    }
  }

  function kindIconFor(src: DataSourceItem) {
    if (src.kind === 'file') return FileText;
    return Folder;
  }

  /** Compact human-scannable sub-label (full raw path/URI stays in `title`). */
  function compactSubtitle(src: DataSourceItem, rawSub: string): string {
    if (!rawSub) return '';
    // Strip trailing file name if identical to src.name, keep parent tail
    const norm = rawSub.replace(/\\/g, '/');
    const lastSlash = norm.lastIndexOf('/');
    const base = lastSlash >= 0 ? norm.slice(lastSlash + 1) : norm;
    const target = base === src.name && lastSlash > 0 ? norm.slice(0, lastSlash) : norm;
    const parts = target.split('/').filter(Boolean);
    if (parts.length <= 2) return target;
    return `…/${parts.slice(-2).join('/')}`;
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

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  onkeydown={sidebar ? handleKeydown : undefined}
  class="flex min-h-0 flex-1 flex-col"
>
  <!-- 1. Clean Full-Width Fuzzy Filter Bar -->
  <div class="flex h-8 shrink-0 items-center gap-1.5 border-b border-border/35 px-2.5">
    <Search class="h-3 w-3 shrink-0 text-muted-foreground/70" />
    <input
      bind:this={searchInputEl}
      type="text"
      bind:value={searchQuery}
      oninput={() => {
        focusedIdx = 0;
      }}
      placeholder={s.pickerSearchPlaceholder}
      aria-label={s.pickerSearchPlaceholder}
      title={s.pickerSearchPlaceholder}
      spellcheck="false"
      autocomplete="off"
      class="h-full min-w-0 flex-1 bg-transparent text-[12px] [@media(any-pointer:coarse)]:text-[16px] text-foreground placeholder:text-muted-foreground/70 focus:outline-none"
    />

    {#if searchQuery.length > 0}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => {
          searchQuery = '';
          focusedIdx = 0;
          searchInputEl?.focus();
        }}
        title={workbench.t.searchBar.clearDraftTitle}
        aria-label={workbench.t.searchBar.clearDraftTitle}
        class="touch-target flex h-5 w-5 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
      >
        <X class="h-3 w-3" />
      </button>
    {/if}

    {#if canCheckFiltered}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={checkAllMatched}
        title={s.checkFiltered(fuzzyResults.length)}
        aria-label={s.checkFiltered(fuzzyResults.length)}
        class="touch-target inline-flex h-5 w-5 shrink-0 items-center justify-center rounded bg-secondary/75 text-foreground hover:bg-secondary cursor-pointer"
      >
        <CheckCheck class="h-3 w-3" />
      </button>
    {/if}
  </div>

  <!-- 2. Visual Data Source List -->
  <div
    bind:this={listEl}
    role="listbox"
    aria-multiselectable="true"
    aria-label={s.pickerTitle}
    class="min-h-0 flex-1 overflow-y-auto overscroll-contain p-1.5 space-y-1"
  >
    {#if workbench.sources.length === 0}
      <div class="flex h-full flex-col items-center justify-center gap-2 px-4 text-center">
        <Database class="h-5 w-5 text-muted-foreground/45" />
        <button
          type="button"
          onclick={() => {
            if (!sidebar) onClose?.();
            workbench.openSourcesDrawer(true);
          }}
          title={s.addSourcePill}
          class="touch-target inline-flex h-7 items-center gap-1 rounded-md border border-border/70 bg-secondary/60 px-2.5 text-xs font-medium text-foreground hover:bg-secondary cursor-pointer"
        >
          <Plus class="h-3.5 w-3.5 shrink-0" />
          <span>{s.addSourcePill}</span>
        </button>
      </div>
    {:else if fuzzyResults.length === 0}
      <div class="flex h-full items-center justify-center px-3 text-center text-xs text-muted-foreground">
        {s.pickerNoMatch}
      </div>
    {:else}
      {#each fuzzyResults as entry, idx (entry.source.id)}
        {@const src = entry.source}
        {@const checked = isSourceRefInList(src, workbench.scope.sources)}
        {@const excluded = isSourceRefInList(src, workbench.scope.excludedSources ?? [])}
        {@const focused = idx === focusedIdx}
        {@const srcMode = resolveSourcePluginPreset(src)}
        {@const modeLabel = ui.sourcePrefilterPresets[srcMode]?.label ?? srcMode}
        {@const Icon = kindIconFor(src)}
        {@const rawSub = getSourceSubtitle(src)}
        {@const shortSub = compactSubtitle(src, rawSub)}
        <button
          type="button"
          role="option"
          data-picker-idx={idx}
          aria-selected={checked}
          onmousedown={(e) => e.preventDefault()}
          onpointerdown={(e) =>
            handleOptionPointerDown(`src:${src.id}`, e, () => toggleItem(src.id, e.altKey))}
          onclick={(e) =>
            handleOptionClick(`src:${src.id}`, e, () => toggleItem(src.id, e.altKey))}
          onmouseenter={() => (focusedIdx = idx)}
          title={`[${modeLabel}] ${s.cardClickTitle(src.name)}${rawSub ? `\n${rawSub}` : ''}${!src.enabled ? ` (${ui.disabled})` : ''}`}
          class={`touch-target group flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left cursor-pointer ${
            checked
              ? focused
                ? 'bg-primary/[0.15] ring-1 ring-inset ring-primary/55'
                : 'bg-primary/[0.1] ring-1 ring-inset ring-primary/30 hover:bg-primary/[0.14]'
              : excluded
                ? focused
                  ? 'bg-status/[0.14] ring-1 ring-inset ring-status/50'
                  : 'bg-status/[0.08] ring-1 ring-inset ring-status/25 hover:bg-status/[0.12]'
                : focused
                  ? 'bg-secondary/75 ring-1 ring-inset ring-border/70'
                  : 'hover:bg-secondary/55'
          } ${!src.enabled && !checked ? 'opacity-70' : ''}`}
        >
          <!-- Visual Kind Squircle -->
          <span
            class={`flex h-7 w-7 shrink-0 items-center justify-center rounded-lg ${
              !src.exists
                ? 'bg-status/15 text-status'
                : checked
                  ? 'bg-primary/15 text-primary'
                  : excluded
                    ? 'bg-status/15 text-status'
                    : 'bg-secondary/70 text-muted-foreground group-hover:text-foreground'
            }`}
          >
            {#if !src.exists}
              <AlertTriangle class="h-3.5 w-3.5" />
            {:else}
              <Icon class="h-3.5 w-3.5" />
            {/if}
          </span>

          <!-- Compact Name + Short Origin -->
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-1 min-w-0">
              <span
                class={`truncate font-mono text-[12px] font-medium leading-tight ${
                  excluded ? 'line-through text-status' : 'text-foreground'
                }`}
              >
                {@render renderHighlighted(src.name, entry.nameRanges)}
              </span>
              {#if srcMode === 'code'}
                <Code2 class="h-3 w-3 shrink-0 text-muted-foreground/70" />
              {:else}
                <ScrollText class="h-3 w-3 shrink-0 text-muted-foreground/70" />
              {/if}
            </div>
            {#if shortSub}
              <div class="mt-0.5 truncate font-mono text-[10.5px] leading-tight text-muted-foreground">
                {shortSub}
              </div>
            {/if}
          </div>

          <!-- Minimal State Indicator -->
          {#if checked}
            <Check class="h-3.5 w-3.5 shrink-0 text-primary stroke-[2.5]" />
          {:else if excluded}
            <Minus class="h-3.5 w-3.5 shrink-0 text-status stroke-[2.5]" />
          {/if}
        </button>
      {/each}
    {/if}
  </div>
</div>
