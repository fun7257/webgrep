<script lang="ts">
  import { untrack } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import type { TimePreset } from '$lib/types';
  import {
    QUICK_TIME_PRESET_GROUPS,
    buildSpecFromDateTimeParts,
    clampDateTimeParts,
    resolveSyncedDateTimeParts,
    type DateTimeParts,
  } from '$lib/time-range';
  import DateTimeRangeSlots from './pickers/DateTimeRangeSlots.svelte';
  import { Clock, Eraser, X } from 'lucide-svelte';

  interface Props {
    value: TimePreset;
    showClose?: boolean;
    onClose?: () => void;
    onApply: (spec: TimePreset) => void;
    onCommitSilent?: (spec: TimePreset) => void;
    onFocusMainInput?: () => void;
  }

  let {
    value,
    showClose = false,
    onClose,
    onApply,
    onCommitSilent,
    onFocusMainInput,
  }: Props = $props();

  const initialSynced = untrack(() => resolveSyncedDateTimeParts(value));

  let startParts = $state<DateTimeParts>({ ...initialSynced.start });
  let endParts = $state<DateTimeParts>({ ...initialSynced.end });
  let endIsNow = $state<boolean>(initialSynced.endIsNow);
  let customDirty = $state<boolean>(false);
  let hoverPreset = $state<TimePreset | null>(null);
  let focusedKey = $state<string | null>(null);

  let slotsRef = $state<DateTimeRangeSlots | null>(null);
  let lastSyncedValue = untrack(() => value);

  const s = $derived(workbench.t.scopeBar);
  const hasTimeScope = $derived(value !== '');

  const previewSynced = $derived(
    !customDirty && hoverPreset !== null ? resolveSyncedDateTimeParts(hoverPreset) : null
  );

  const displayedStart = $derived(previewSynced ? previewSynced.start : startParts);
  const displayedEnd = $derived(previewSynced ? previewSynced.end : endParts);
  const effectiveEndIsNow = $derived(previewSynced ? previewSynced.endIsNow : endIsNow);

  // Sync slots whenever external `scope.timePreset` changes (clear, history, share replay)
  $effect(() => {
    const cur = value;
    if (cur !== lastSyncedValue) {
      lastSyncedValue = cur;
      const synced = resolveSyncedDateTimeParts(cur);
      startParts = { ...synced.start };
      endParts = { ...synced.end };
      endIsNow = synced.endIsNow;
      customDirty = false;
      hoverPreset = null;
    }
  });

  function selectPreset(preset: TimePreset) {
    const synced = resolveSyncedDateTimeParts(preset);
    startParts = { ...synced.start };
    endParts = { ...synced.end };
    endIsNow = synced.endIsNow;
    customDirty = false;
    hoverPreset = null;
    lastSyncedValue = preset;
    onApply(preset);
  }

  function submitCustomRange() {
    slotsRef?.commitFocusedSlot();

    if (!customDirty && previewSynced && hoverPreset !== null) {
      selectPreset(hoverPreset);
      return;
    }

    if (!customDirty && value !== '') {
      onApply(value);
      return;
    }

    const normStart = clampDateTimeParts(startParts);
    startParts = normStart;
    if (!endIsNow) {
      endParts = clampDateTimeParts(endParts);
    }
    const nextSpec = buildSpecFromDateTimeParts(normStart, endParts, endIsNow);
    lastSyncedValue = nextSpec;
    customDirty = false;
    onApply(nextSpec);
  }

  /** Commit pending custom time edits silently (e.g. on outside-click flyout dismiss). */
  export function commitIfDirty(): boolean {
    if (!customDirty) return false;
    slotsRef?.commitFocusedSlot();
    const normStart = clampDateTimeParts(startParts);
    startParts = normStart;
    if (!endIsNow) {
      endParts = clampDateTimeParts(endParts);
    }
    const nextSpec = buildSpecFromDateTimeParts(normStart, endParts, endIsNow);
    customDirty = false;
    if (!nextSpec || nextSpec === value) return false;
    lastSyncedValue = nextSpec;
    if (onCommitSilent) {
      onCommitSilent(nextSpec);
    } else {
      onApply(nextSpec);
    }
    return true;
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      onClose?.();
      onFocusMainInput?.();
    }
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div onkeydown={handleKeydown} class="flex flex-col">
  <!-- Compact inline strip: Clock + label + conditional reset/close -->
  <div class="flex h-8 shrink-0 items-center justify-between gap-2 bg-card/30 px-2.5">
    <div class="flex min-w-0 items-center gap-1.5" title={s.timeSectionTitle}>
      <Clock class={`h-3.5 w-3.5 shrink-0 ${hasTimeScope ? 'text-primary' : 'text-muted-foreground/75'}`} />
      <span class="shrink-0 text-[11.5px] font-medium text-muted-foreground">
        {s.timeSectionTitle}
      </span>
    </div>

    <div class="flex shrink-0 items-center gap-0.5">
      {#if hasTimeScope}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={() => selectPreset('')}
          title={s.timeLabels['']}
          aria-label={s.timeLabels['']}
          class="touch-target flex h-5 w-5 shrink-0 items-center justify-center rounded text-muted-foreground/75 hover:bg-secondary hover:text-foreground cursor-pointer"
        >
          <Eraser class="h-3.5 w-3.5" />
        </button>
      {/if}
      {#if showClose && onClose}
        <button
          type="button"
          onclick={onClose}
          title={workbench.t.settings.closePanelTitle}
          aria-label={workbench.t.settings.closePanelTitle}
          class="touch-target flex h-6 w-6 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
        >
          <X class="h-3.5 w-3.5" />
        </button>
      {/if}
    </div>
  </div>

  <!-- Preset Matrix & Editable Start → End Timeline Slots -->
  <div class="p-2.5 pt-2 space-y-2">
    <div
      role="presentation"
      class="space-y-1"
      onmouseleave={() => {
        hoverPreset = null;
      }}
    >
      {#each QUICK_TIME_PRESET_GROUPS as group (group.id)}
        <div class="grid grid-cols-4 gap-1">
          {#each group.presets as preset (preset)}
            {@const active = !customDirty && value === preset}
            {@const isNamedDay = preset === 'today' || preset === 'yesterday'}
            <button
              type="button"
              onmousedown={(e) => e.preventDefault()}
              onmouseenter={() => {
                if (!customDirty && !workbench.isTouch) hoverPreset = preset;
              }}
              onclick={() => selectPreset(active ? '' : preset)}
              title={s.timeLabels[preset] ?? preset}
              class={`touch-target flex h-6 items-center justify-center rounded text-[11px] tabular-nums cursor-pointer active:bg-primary/20 ${
                isNamedDay ? '' : 'font-mono'
              } ${
                active
                  ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-medium'
                  : 'bg-secondary/40 text-foreground/85 hover:bg-secondary/80 hover:text-foreground'
              }`}
            >
              {s.timeShortLabels[preset] ?? s.timeLabels[preset] ?? preset}
            </button>
          {/each}
        </div>
      {/each}
    </div>

    <DateTimeRangeSlots
      bind:this={slotsRef}
      bind:startParts
      bind:endParts
      bind:endIsNow
      bind:customDirty
      bind:focusedKey
      {displayedStart}
      {displayedEnd}
      {effectiveEndIsNow}
      {previewSynced}
      onClearHoverPreset={() => (hoverPreset = null)}
      onSubmit={submitCustomRange}
    />
  </div>
</div>
