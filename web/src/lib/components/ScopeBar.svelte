<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { resolveScopeSourceSummary } from '$lib/source-picker';
  import { formatTimeScopeLabel, isBuiltinTimePreset } from '$lib/time-range';
  import TimeRangePicker from './TimeRangePicker.svelte';
  import {
    ChevronDown,
    Clock,
    Container,
    Database,
    FileText,
    Folder,
    Plus,
    X,
  } from 'lucide-svelte';

  interface Props {
    hero?: boolean;
  }

  let { hero = false }: Props = $props();

  let timeOpen = $state<boolean>(false);
  let barEl = $state<HTMLDivElement | null>(null);

  const s = $derived(workbench.t.scopeBar);

  const sourceSummary = $derived(
    resolveScopeSourceSummary(
      workbench.sources,
      workbench.scope.sources,
      workbench.scope.excludedSources ?? []
    )
  );

  const hasSourceScope = $derived(sourceSummary.mode !== 'all');
  const hasTimeScope = $derived(workbench.scope.timePreset !== '');
  const hasBothScopes = $derived(hasSourceScope && hasTimeScope);

  const sourceLabel = $derived.by(() => {
    switch (sourceSummary.mode) {
      case 'all':
        return s.allSources;
      case 'single':
        return sourceSummary.singleSource?.name ?? workbench.scope.sources[0] ?? s.allSources;
      case 'multi':
        return s.sourcesSelected(sourceSummary.selectedCount);
      case 'excluded':
        return s.excludedSources(sourceSummary.excludedCount);
      case 'mixed':
        return `${sourceSummary.selectedCount} · -${sourceSummary.excludedCount}`;
    }
  });

  const timeLabel = $derived(formatTimeScopeLabel(workbench.scope.timePreset, s.timeLabels));
  const hasCustomTime = $derived(
    Boolean(workbench.scope.timePreset) && !isBuiltinTimePreset(workbench.scope.timePreset)
  );

  function handleWindowPointerDown(e: PointerEvent) {
    if (!timeOpen || !barEl) return;
    if (!barEl.contains(e.target as Node)) {
      timeOpen = false;
    }
  }

  function handleWindowKeydown(e: KeyboardEvent) {
    if (timeOpen && e.key === 'Escape') {
      e.stopPropagation();
      timeOpen = false;
    }
  }

  const pillBase =
    'touch-target inline-flex h-7 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border px-2.5 text-[11.5px] transition-colors cursor-pointer select-none';
  const pillIdle =
    'border-transparent bg-transparent text-muted-foreground/80 hover:bg-secondary/60 hover:text-foreground';
  const pillActive =
    'border-primary/35 bg-primary/15 text-primary font-medium ring-1 ring-inset ring-primary/20 hover:bg-primary/20';
  const pillStatusActive =
    'border-status/35 bg-status/10 text-status font-medium hover:bg-status/15';
</script>

<svelte:window onpointerdown={handleWindowPointerDown} onkeydown={handleWindowKeydown} />

<div
  bind:this={barEl}
  class={`relative mt-2 flex flex-wrap items-center gap-1.5 ${
    hero ? 'justify-center' : 'px-0.5'
  }`}
>
  <!-- 1. Data Sources Picker Trigger -->
  {#if workbench.sources.length === 0 && workbench.sourcesLoaded}
    <button
      type="button"
      onclick={() => {
        timeOpen = false;
        workbench.openSettings('add-source');
      }}
      class={`${pillBase} border-dashed border-border/75 text-muted-foreground hover:border-foreground/30 hover:bg-secondary/50 hover:text-foreground`}
    >
      <Plus class="h-3 w-3 shrink-0" />
      <span>{s.addSourcePill}</span>
    </button>
  {:else}
    <button
      type="button"
      onclick={() => {
        timeOpen = false;
        workbench.openSourcePicker();
      }}
      title={s.openSourcePickerTitle}
      class={`${pillBase} ${
        sourceSummary.mode === 'excluded'
          ? `${pillStatusActive} pr-1.5`
          : hasSourceScope
            ? `${pillActive} pr-1.5`
            : pillIdle
      }`}
    >
      {#if sourceSummary.mode === 'single' && sourceSummary.singleSource?.kind === 'docker'}
        <Container class="h-3 w-3 shrink-0" />
      {:else if sourceSummary.mode === 'single' && sourceSummary.singleSource?.kind === 'file'}
        <FileText class="h-3 w-3 shrink-0" />
      {:else if sourceSummary.mode === 'single' && sourceSummary.singleSource?.kind === 'dir'}
        <Folder class="h-3 w-3 shrink-0" />
      {:else}
        <Database class="h-3 w-3 shrink-0" />
      {/if}
      <span class={`max-w-[160px] truncate ${sourceSummary.mode === 'single' ? 'font-mono' : ''}`}>
        {sourceLabel}
      </span>
      {#if !hasSourceScope}
        <ChevronDown class="h-3 w-3 shrink-0 opacity-60" />
      {:else}
        <span
          role="button"
          tabindex="-1"
          onclick={(e) => {
            e.stopPropagation();
            workbench.clearScopeSources();
          }}
          onkeydown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.stopPropagation();
              workbench.clearScopeSources();
            }
          }}
          title={s.clearScope}
          aria-label={s.clearScope}
          class="ml-0.5 inline-flex h-4 w-4 items-center justify-center rounded-full hover:bg-primary/20"
        >
          <X class="h-2.5 w-2.5" />
        </span>
      {/if}
    </button>
  {/if}

  <!-- 2. Time Window Picker Trigger -->
  <div class="relative shrink-0">
    <button
      type="button"
      onclick={() => (timeOpen = !timeOpen)}
      class={`${pillBase} ${hasTimeScope ? `${pillActive} pr-1.5` : pillIdle}`}
    >
      <Clock class="h-3 w-3 shrink-0" />
      <span class={`max-w-[190px] truncate ${hasCustomTime ? 'font-mono tabular-nums' : ''}`}>
        {timeLabel}
      </span>
      {#if !hasTimeScope}
        <ChevronDown class="h-3 w-3 shrink-0 opacity-60" />
      {:else}
        <span
          role="button"
          tabindex="-1"
          onclick={(e) => {
            e.stopPropagation();
            workbench.setScopeTime('');
            timeOpen = false;
          }}
          onkeydown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.stopPropagation();
              workbench.setScopeTime('');
              timeOpen = false;
            }
          }}
          title={s.clearScope}
          aria-label={s.clearScope}
          class="ml-0.5 inline-flex h-4 w-4 items-center justify-center rounded-full hover:bg-primary/20"
        >
          <X class="h-2.5 w-2.5" />
        </span>
      {/if}
    </button>

    {#if timeOpen}
      <TimeRangePicker
        value={workbench.scope.timePreset}
        onApply={(spec) => {
          workbench.setScopeTime(spec);
          timeOpen = false;
        }}
        onClose={() => {
          timeOpen = false;
        }}
      />
    {/if}
  </div>

  {#if hasBothScopes}
    <button
      type="button"
      onclick={() => workbench.clearScopeAll()}
      class="touch-target rounded-full px-2 py-0.5 text-[11px] text-muted-foreground/80 hover:bg-secondary/60 hover:text-foreground transition-colors cursor-pointer"
    >
      {s.clearScope}
    </button>
  {/if}
</div>
