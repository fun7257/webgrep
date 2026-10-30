<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { formatMs } from '$lib/utils';
  import { AlertTriangle, Hash, Loader2, Square, Timer, X } from 'lucide-svelte';

  const CONTAINS_CHIP_CLASSES = [
    'bg-primary/10 text-primary hover:bg-primary/20',
    'bg-primary/10 text-primary hover:bg-primary/20',
    'bg-primary/10 text-primary hover:bg-primary/20',
  ];

  let includeModifiers = $derived(
    workbench.inlineModifiers.filter((m) => m.kind === 'include')
  );
  let excludeModifiers = $derived(
    workbench.inlineModifiers.filter((m) => m.kind === 'exclude')
  );
</script>

{#if workbench.hasSearchedOnce || workbench.isSearching || workbench.errorMessage}
  <div
    class="flex flex-wrap items-center justify-between gap-2 px-3 md:px-7 pb-1.5 pt-0.5 text-xs text-muted-foreground/65 select-none"
  >
    <div class="flex flex-wrap items-center gap-2 min-w-0 font-mono tabular-nums text-[12px]">
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
            class="touch-target inline-flex h-6 w-6 items-center justify-center rounded bg-secondary/60 text-foreground hover:bg-secondary transition-colors shrink-0"
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

        <!-- Borderless Active Drill-Down Chips (+word / -word) -->
        {#if includeModifiers.length > 0 || excludeModifiers.length > 0}
          <div class="flex flex-wrap items-center gap-1 ml-1">
            {#each includeModifiers as mod, idx (`inc:${idx}:${mod.raw}`)}
              <button
                type="button"
                title={`点击移除 "${mod.value}"`}
                onclick={() => workbench.removeInlineModifier(mod.raw)}
                class={`touch-target inline-flex items-center gap-1 rounded px-1.5 py-1 font-mono text-[11px] transition-colors cursor-pointer ${
                  CONTAINS_CHIP_CLASSES[idx % CONTAINS_CHIP_CLASSES.length]
                }`}
              >
                <span class="truncate max-w-[140px]">+{mod.value}</span>
                <X class="h-2.5 w-2.5 opacity-60" />
              </button>
            {/each}
            {#each excludeModifiers as mod, idx (`exc:${idx}:${mod.raw}`)}
              <button
                type="button"
                title={`点击移除 "${mod.value}"`}
                onclick={() => workbench.removeInlineModifier(mod.raw)}
                class="touch-target inline-flex items-center gap-1 rounded bg-secondary/50 px-1.5 py-1 font-mono text-[11px] text-muted-foreground hover:text-foreground transition-colors cursor-pointer"
              >
                <span class="truncate max-w-[140px]">-{mod.value}</span>
                <X class="h-2.5 w-2.5 opacity-60" />
              </button>
            {/each}
          </div>
        {/if}
      {/if}
    </div>
  </div>
{/if}
