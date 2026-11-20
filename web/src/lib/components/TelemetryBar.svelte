<script lang="ts">
  import { flushSync, type Component } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { formatPrunedTelemetry } from '$lib/prefilter';
  import { formatMs } from '$lib/utils';
  import type { ViewModePreference } from '$lib/types';
  import { PRESENTATION_ADAPTERS, getPresentationAdapter } from './adapters/registry.ts';
  import {
    AlertTriangle,
    Filter,
    Hash,
    Loader2,
    Sparkles,
    Square,
    Timer,
  } from 'lucide-svelte';

  let modePickedOnDown: ViewModePreference | null = null;

  const prunedView = $derived(
    workbench.isSearching
      ? { visible: false, filesPruned: 0, bytesSaved: 0, compactText: '', filesText: '', savedText: '' }
      : formatPrunedTelemetry(workbench.filesPruned, workbench.bytesSaved)
  );

  const prunedTitle = $derived.by(() => {
    if (!prunedView.visible) return '';
    return prunedView.savedText
      ? workbench.t.telemetry.prunedTooltipWithBytes(prunedView.filesText, prunedView.savedText)
      : workbench.t.telemetry.prunedTooltipFilesOnly(prunedView.filesText);
  });

  const batchSummary = $derived(workbench.adapterBatchSummary);
  const activeAutoLabel = $derived(
    getPresentationAdapter(workbench.activeViewAdapter).meta.label(workbench.t)
  );
  const mixedSummaryText = $derived.by(() => {
    if (!batchSummary.isMixed) return '';
    return PRESENTATION_ADAPTERS.filter((a) => batchSummary.sampleCounts[a.id] > 0)
      .map((a) => `${a.meta.label(workbench.t)} ${batchSummary.sampleCounts[a.id]}`)
      .join(' · ');
  });

  const viewOptions = $derived<
    Array<{
      id: ViewModePreference;
      icon: Component<{ class?: string }>;
      title: string;
      hasSample: boolean;
    }>
  >([
    {
      id: 'auto',
      icon: Sparkles as unknown as Component<{ class?: string }>,
      title: mixedSummaryText
        ? `${workbench.t.logView.modeAutoTitle(activeAutoLabel)} · ${workbench.t.logView.mixedHint(mixedSummaryText)}`
        : workbench.t.logView.modeAutoTitle(activeAutoLabel),
      hasSample: false,
    },
    ...PRESENTATION_ADAPTERS.map((adapter) => {
      const sampleCount = batchSummary.sampleCounts[adapter.id] ?? 0;
      const baseTitle = adapter.meta.title(workbench.t);
      return {
        id: adapter.id as ViewModePreference,
        icon: adapter.meta.icon,
        title:
          batchSummary.isMixed && sampleCount > 0
            ? `${baseTitle} (${sampleCount}/${batchSummary.sampleCount})`
            : baseTitle,
        hasSample: batchSummary.isMixed && sampleCount > 0,
      };
    }),
  ]);

  function onViewPointerDown(mode: ViewModePreference, e: PointerEvent) {
    if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
      e.preventDefault();
      modePickedOnDown = mode;
      flushSync(() => workbench.setViewMode(mode));
    }
  }

  function onViewClick(mode: ViewModePreference, e: MouseEvent) {
    if (modePickedOnDown === mode && e.detail > 0) {
      modePickedOnDown = null;
      return;
    }
    modePickedOnDown = null;
    flushSync(() => workbench.setViewMode(mode));
  }
</script>

{#if workbench.hasSearchedOnce || workbench.isSearching || workbench.errorMessage}
  <div
    class="flex items-center justify-between gap-2 px-3 md:px-7 pb-1.5 pt-0.5 text-xs text-muted-foreground/65 select-none"
  >
    <div class="flex h-6 flex-1 items-center gap-2 min-w-0 font-mono tabular-nums text-[12px]">
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

        {#if prunedView.visible}
          <span
            class="inline-flex h-5 max-w-full items-center gap-1 truncate rounded bg-secondary/65 px-1.5 text-[11px] leading-none text-muted-foreground/90 ring-1 ring-inset ring-border/50 shrink-0 tabular-nums"
            title={prunedTitle}
          >
            <Filter class="h-2.5 w-2.5 shrink-0" />
            <span class="truncate">{prunedView.compactText}</span>
          </span>
        {/if}
      {/if}
    </div>

    {#if workbench.flatHits.length > 0 && !workbench.errorMessage}
      <div
        role="group"
        aria-label={workbench.t.settings.viewModeLabel}
        class="inline-flex h-6 shrink-0 items-center gap-0.5 rounded-md border border-border/50 bg-secondary/45 p-0.5"
      >
        {#each viewOptions as opt (opt.id)}
          {@const Icon = opt.icon}
          {@const active = workbench.viewMode === opt.id}
          <button
            type="button"
            title={opt.title}
            aria-label={opt.title}
            aria-pressed={active}
            onmousedown={(e) => e.preventDefault()}
            onpointerdown={(e) => onViewPointerDown(opt.id, e)}
            onclick={(e) => onViewClick(opt.id, e)}
            class={`touch-target relative flex h-5 w-6 items-center justify-center rounded-[4px] cursor-pointer ${
              active
                ? 'bg-background text-foreground ring-1 ring-inset ring-border/70 shadow-[0_1px_1px_hsl(0_0%_0%/0.05)]'
                : 'text-muted-foreground/75 hover:text-foreground'
            }`}
          >
            <Icon class="h-3 w-3" />
            {#if opt.hasSample && !active}
              <span class="pointer-events-none absolute right-0.5 top-0.5 h-1 w-1 rounded-full bg-primary"></span>
            {/if}
          </button>
        {/each}
      </div>
    {/if}
  </div>
{/if}
