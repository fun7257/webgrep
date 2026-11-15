<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { formatMs } from '$lib/utils';
  import { AlertTriangle, Hash, Loader2, Square, Timer } from 'lucide-svelte';
</script>

{#if workbench.hasSearchedOnce || workbench.isSearching || workbench.errorMessage}
  <div
    class="flex flex-wrap items-center justify-between gap-2 px-3 md:px-7 pb-1.5 pt-0.5 text-xs text-muted-foreground/65 select-none"
  >
    <div class="flex h-6 items-center gap-2 min-w-0 font-mono tabular-nums text-[12px]">
      {#if workbench.errorMessage}
        <span class="flex items-center gap-1.5 text-status font-medium truncate">
          <AlertTriangle class="h-3.5 w-3.5 shrink-0" />
          <span class="truncate">{workbench.errorMessage}</span>
        </span>
      {:else}
        <span
          class="inline-flex items-center gap-1 text-muted-foreground shrink-0"
          title={workbench.t.telemetry.matchesCount(workbench.totalMatches.toLocaleString())}
        >
          <Hash class="h-3 w-3" />
          {workbench.totalMatches.toLocaleString()}
        </span>

        {#if workbench.isSearching}
          <span
            class="inline-flex items-center text-muted-foreground shrink-0"
            title={workbench.t.telemetry.searching}
          >
            <Loader2 class="h-3 w-3 animate-spin" />
          </span>
          <button
            type="button"
            onclick={() => workbench.cancelSearch()}
            title={workbench.t.telemetry.stopSearch}
            aria-label={workbench.t.telemetry.stopSearch}
            class="touch-target inline-flex h-6 w-6 items-center justify-center rounded bg-secondary/60 text-foreground hover:bg-secondary active:bg-secondary/80 active:scale-[0.97] shrink-0"
          >
            <Square class="h-2.5 w-2.5 fill-current" />
          </button>
        {:else if workbench.elapsedMs > 0}
          <span class="inline-flex items-center gap-1 shrink-0 opacity-75">
            <Timer class="h-3 w-3" />
            {formatMs(workbench.elapsedMs)}
          </span>
        {/if}

        {#if workbench.limitHit}
          <span
            class="inline-flex items-center text-status shrink-0"
            title={workbench.t.telemetry.cappedAt(workbench.maxResults)}
          >
            <AlertTriangle class="h-3 w-3" />
          </span>
        {/if}
      {/if}
    </div>
  </div>
{/if}
