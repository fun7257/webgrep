<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { formatMs } from '$lib/utils';
  import { AlertTriangle, Hash, Loader2, Rows3, Square, Timer, X } from 'lucide-svelte';

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
  let scopeAndTimeModifiers = $derived(
    workbench.inlineModifiers.filter(
      (m) => m.kind === 'file' || m.kind === 'exclude-file' || m.kind === 'flag'
    )
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

        {#if workbench.nearbyLines > 0 && !workbench.isSearching}
          <!-- Results come from the nearby-lines fallback: say so, and let the user go back to strict lines -->
          <button
            type="button"
            onclick={() => workbench.disableNearbyLines()}
            title={workbench.t.telemetry.nearbyTitle(workbench.nearbyLines)}
            class="touch-target inline-flex items-center gap-1 rounded bg-primary/10 px-1.5 py-1 font-mono text-[11px] text-primary hover:bg-primary/20 transition-colors shrink-0 cursor-pointer"
          >
            <Rows3 class="h-3 w-3" />
            <span>{workbench.t.telemetry.nearbyChip(workbench.nearbyLines)}</span>
            <X class="h-2.5 w-2.5 opacity-60" />
          </button>
        {/if}

        {#if workbench.limitHit}
          <span
            class="inline-flex items-center text-status shrink-0"
            title={workbench.t.telemetry.cappedAt(workbench.maxResults)}
          >
            <AlertTriangle class="h-3 w-3" />
          </span>
        {/if}

        <!-- Borderless Active Drill-Down Chips (@source / $t / +word / -word) -->
        {#if scopeAndTimeModifiers.length > 0 || includeModifiers.length > 0 || excludeModifiers.length > 0}
          <div class="flex flex-wrap items-center gap-1 ml-1">
            {#each scopeAndTimeModifiers as mod, idx (`st:${idx}:${mod.raw}`)}
              <button
                type="button"
                title={workbench.t.telemetry.removeChip(mod.raw)}
                onclick={() => workbench.removeInlineModifier(mod.raw)}
                class="touch-target inline-flex items-center gap-1 rounded bg-secondary/50 px-1.5 py-1 font-mono text-[11px] text-foreground/85 hover:bg-secondary transition-colors cursor-pointer"
              >
                <span class="truncate max-w-[140px]">
                  {mod.kind === 'file'
                    ? `in:${mod.value}`
                    : mod.kind === 'exclude-file'
                      ? `-in:${mod.value}`
                      : `time:${mod.value}`}
                </span>
                <X class="h-2.5 w-2.5 opacity-60" />
              </button>
            {/each}
            {#each includeModifiers as mod, idx (`inc:${idx}:${mod.raw}`)}
              <span
                class={`inline-flex items-center rounded font-mono text-[11px] transition-colors ${
                  CONTAINS_CHIP_CLASSES[idx % CONTAINS_CHIP_CLASSES.length]
                }`}
              >
                <button
                  type="button"
                  title={workbench.t.telemetry.toExclude(mod.value)}
                  onclick={() => workbench.toggleInlineModifierExclude(mod.raw)}
                  class="touch-target pl-1.5 pr-1 py-1 truncate max-w-[140px] cursor-pointer"
                >
                  +{mod.value}
                </button>
                <button
                  type="button"
                  title={workbench.t.telemetry.removeChip(mod.value)}
                  aria-label={workbench.t.telemetry.removeChip(mod.value)}
                  onclick={() => workbench.removeInlineModifier(mod.raw)}
                  class="touch-target pr-1.5 pl-0.5 py-1 opacity-60 hover:opacity-100 cursor-pointer"
                >
                  <X class="h-2.5 w-2.5" />
                </button>
              </span>
            {/each}
            {#each excludeModifiers as mod, idx (`exc:${idx}:${mod.raw}`)}
              <span
                class="inline-flex items-center rounded bg-secondary/50 font-mono text-[11px] text-muted-foreground hover:text-foreground transition-colors"
              >
                <button
                  type="button"
                  title={workbench.t.telemetry.toInclude(mod.value)}
                  onclick={() => workbench.toggleInlineModifierExclude(mod.raw)}
                  class="touch-target pl-1.5 pr-1 py-1 truncate max-w-[140px] cursor-pointer"
                >
                  -{mod.value}
                </button>
                <button
                  type="button"
                  title={workbench.t.telemetry.removeChip(mod.value)}
                  aria-label={workbench.t.telemetry.removeChip(mod.value)}
                  onclick={() => workbench.removeInlineModifier(mod.raw)}
                  class="touch-target pr-1.5 pl-0.5 py-1 opacity-60 hover:opacity-100 cursor-pointer"
                >
                  <X class="h-2.5 w-2.5" />
                </button>
              </span>
            {/each}
          </div>
        {/if}
      {/if}
    </div>
  </div>
{/if}
