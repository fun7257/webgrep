<script lang="ts">
  import type { CodeStreamStats } from '$lib/adapters/index.ts';
  import type { AdapterHost } from '../types.ts';
  import { ChevronsDownUp, ChevronsUpDown, X } from 'lucide-svelte';

  interface Props {
    stats: CodeStreamStats;
    host: AdapterHost;
    activeLangFilter: string | null;
    activeDirFilter: string | null;
    matchedHitCount: number;
    allCollapsed: boolean;
    onToggleLang: (langId: string) => void;
    onToggleDir: (dir: string) => void;
    onClearLocalFilters: () => void;
    onToggleCollapseAll: () => void;
  }

  let {
    stats,
    host,
    activeLangFilter,
    activeDirFilter,
    matchedHitCount,
    allCollapsed,
    onToggleLang,
    onToggleDir,
    onClearLocalFilters,
    onToggleCollapseAll,
  }: Props = $props();

  const cv = $derived(host.t.codeView);
  const hasLocalFilter = $derived(activeLangFilter !== null || activeDirFilter !== null);
  const topDirs = $derived(stats.topDirs.slice(0, 3));
</script>

{#if stats.languages.length > 0 || stats.fileCount > 0}
  <div
    class="flex h-8 shrink-0 items-center justify-between gap-2 overflow-hidden border-b border-border/35 px-3 md:px-6 select-none"
  >
    <div class="flex min-w-0 items-center gap-1 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
      {#each stats.languages as lang (lang.id)}
        {@const active = activeLangFilter === lang.id}
        <button
          type="button"
          aria-pressed={active}
          onmousedown={(e) => e.preventDefault()}
          onclick={() => onToggleLang(lang.id)}
          title={cv.langFilterTitle(lang.label, lang.count)}
          aria-label={cv.langFilterTitle(lang.label, lang.count)}
          class={`touch-target inline-flex h-5 shrink-0 items-center gap-1 rounded px-1.5 font-mono text-[10.5px] leading-none whitespace-nowrap tabular-nums cursor-pointer ${
            active
              ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-medium'
              : 'bg-secondary/60 text-muted-foreground hover:bg-secondary hover:text-foreground active:bg-secondary/80'
          }`}
        >
          <span>{lang.label}</span>
          <span class="opacity-75">{lang.count.toLocaleString()}</span>
        </button>
      {/each}

      {#if topDirs.length > 0}
        <span class="hidden md:inline-block mx-0.5 h-3 w-px shrink-0 bg-border/50"></span>
        <div class="hidden md:flex items-center gap-1">
          {#each topDirs as d (d.dir)}
            {@const active = activeDirFilter === d.dir}
            <button
              type="button"
              aria-pressed={active}
              onmousedown={(e) => e.preventDefault()}
              onclick={() => onToggleDir(d.dir)}
              title={cv.dirFilterTitle(d.dir, d.count)}
              aria-label={cv.dirFilterTitle(d.dir, d.count)}
              class={`touch-target inline-flex h-5 max-w-[144px] shrink-0 items-center gap-1 rounded px-1.5 font-mono text-[10.5px] leading-none whitespace-nowrap tabular-nums cursor-pointer ${
                active
                  ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-medium'
                  : 'bg-secondary/45 text-muted-foreground hover:bg-secondary hover:text-foreground'
              }`}
            >
              <span class="truncate">{d.dir}</span>
              <span class="shrink-0 opacity-65">{d.count.toLocaleString()}</span>
            </button>
          {/each}
        </div>
      {/if}
    </div>

    <div class="flex shrink-0 items-center gap-1.5 font-mono text-[10.5px] tabular-nums">
      {#if hasLocalFilter}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={onClearLocalFilters}
          title={cv.clearLocalFilter}
          aria-label={cv.clearLocalFilter}
          class="touch-target inline-flex h-5 items-center gap-1 rounded bg-primary/15 px-1.5 text-primary ring-1 ring-inset ring-primary/30 hover:bg-primary/20 cursor-pointer"
        >
          <span>{cv.filteredSummary(matchedHitCount, host.hits.length)}</span>
          <X class="h-3 w-3" />
        </button>
      {:else if stats.fileCount > 0}
        <span class="hidden sm:inline text-muted-foreground/65">
          {cv.filesCount(stats.fileCount)}
        </span>
      {/if}

      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={onToggleCollapseAll}
        title={allCollapsed ? cv.expandAll : cv.collapseAll}
        aria-label={allCollapsed ? cv.expandAll : cv.collapseAll}
        class="touch-target inline-flex h-5 w-6 items-center justify-center rounded bg-secondary/55 text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
      >
        {#if allCollapsed}
          <ChevronsUpDown class="h-3 w-3" />
        {:else}
          <ChevronsDownUp class="h-3 w-3" />
        {/if}
      </button>
    </div>
  </div>
{/if}
