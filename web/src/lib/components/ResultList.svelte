<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { zeroResultFixes } from '$lib/suggest';
  import { createWorkbenchAdapterHost } from './adapters/types.ts';
  import { getPresentationAdapter } from './adapters/registry.ts';
  import { Loader2 } from 'lucide-svelte';

  const host = createWorkbenchAdapterHost();
  const activeAdapter = $derived(getPresentationAdapter(workbench.activeViewAdapter));

  const zeroFixes = $derived(
    !workbench.isSearching && workbench.totalMatches === 0
      ? zeroResultFixes(
          workbench.steps,
          workbench.draftStep,
          workbench.scope,
          workbench.t.suggest
        )
      : []
  );
</script>

<div class="flex flex-1 min-h-0 flex-col overflow-clip">
  {#if workbench.flatHits.length > 0}
    {@const ActiveResultsView = activeAdapter.ResultsView}
    <ActiveResultsView {host} />
  {:else if workbench.isSearching}
    <!-- Searching / Scanning State -->
    <div class="flex h-full flex-col items-center justify-center gap-3 p-8 text-center select-none">
      <Loader2 class="h-6 w-6 animate-spin text-primary" />
      <p class="text-sm font-medium text-muted-foreground">
        {workbench.t.results.searchingTitle}
      </p>
    </div>
  {:else if workbench.hasSearchedOnce && workbench.hasExecutableQuery}
    <!-- Zero-Match State -->
    <div class="flex h-full flex-col items-center justify-center p-8 text-center select-none">
      <p class="text-base font-medium text-foreground">{workbench.t.results.noMatchesTitle}</p>
      <p class="mt-1.5 text-[13px] text-muted-foreground font-mono">
        {workbench.t.ui.finishedIn(workbench.elapsedMs.toFixed(2))}
      </p>
      <div class="mt-4 flex flex-wrap items-center justify-center gap-2">
        <!-- One-click ways out of an empty result (drop a term / scope, ignore case, nearby lines) -->
        {#each zeroFixes as fix (fix.key)}
          <button
            type="button"
            onclick={() => workbench.applyResultFix(fix)}
            class="touch-target rounded-lg bg-primary/10 px-3 py-1.5 font-mono text-[12.5px] text-primary hover:bg-primary/20 active:bg-primary/25 cursor-pointer"
          >
            {fix.label}
          </button>
        {/each}
        {#if workbench.activeFilterCount > 0}
          <button
            type="button"
            onclick={() => {
              workbench.resetAllFilters();
            }}
            class="rounded-lg border border-border bg-card px-3.5 py-1.5 text-[13px] font-medium text-foreground hover:bg-secondary active:bg-secondary/80 cursor-pointer"
          >
            {workbench.t.results.resetFiltersBtn}
          </button>
        {/if}
      </div>
    </div>
  {/if}
</div>
