<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { createWorkbenchAdapterHost } from './adapters/types.ts';
  import { getPresentationAdapter } from './adapters/registry.ts';
  import { Database, Plus, SearchX } from 'lucide-svelte';

  const host = createWorkbenchAdapterHost();
  const activeAdapter = $derived(getPresentationAdapter(workbench.activeViewAdapter));
</script>

<div class="flex flex-1 min-h-0 flex-col overflow-clip">
  {#if workbench.flatHits.length > 0}
    {@const ActiveResultsView = activeAdapter.ResultsView}
    <ActiveResultsView {host} />
  {:else if !workbench.isSearching && workbench.sourcesLoaded && workbench.sources.length === 0}
    <div
      class="flex h-full flex-col items-center justify-center gap-3 p-8 text-center select-none"
      role="status"
    >
      <Database class="h-6 w-6 text-muted-foreground/45 stroke-[1.5]" />
      <span class="text-xs text-muted-foreground">{workbench.t.results.emptyNoSourceTitle}</span>
      <button
        type="button"
        onclick={() => workbench.openSourcesDrawer(true)}
        class="touch-target inline-flex h-7 items-center gap-1 rounded-full bg-primary/10 px-3 text-xs font-medium text-primary ring-1 ring-inset ring-primary/25 hover:bg-primary/15 active:bg-primary/20 cursor-pointer"
      >
        <Plus class="h-3.5 w-3.5 shrink-0" />
        <span>{workbench.t.scopeBar.addSourcePill}</span>
      </button>
    </div>
  {:else if !workbench.isSearching && workbench.hasSearchedOnce && workbench.hasExecutableQuery}
    <div
      class="flex h-full flex-col items-center justify-center gap-2 p-8 text-center select-none"
      role="status"
    >
      <SearchX class="h-6 w-6 text-muted-foreground/45 stroke-[1.5]" />
      <span class="text-xs text-muted-foreground/70">{workbench.t.results.noMatchesTitle}</span>
    </div>
  {/if}
</div>
