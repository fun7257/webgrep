<script lang="ts">
  import { untrack } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import type { TimePreset } from '$lib/types';
  import { splitHighlightRanges, type HighlightRange } from '$lib/source-picker';
  import {
    FLAT_QUICK_TIME_PRESETS,
    QUICK_TIME_PRESET_GROUPS,
    buildSpecFromDateTimeParts,
    clampDateTimeParts,
    formatTimeScopeLabel,
    isBuiltinTimePreset,
    matchQuickTimeCandidates,
    resolveSyncedDateTimeParts,
    type DateTimeParts,
  } from '$lib/time-range';
  import FloatingPopoverShell from './pickers/FloatingPopoverShell.svelte';
  import DateTimeRangeSlots from './pickers/DateTimeRangeSlots.svelte';
  import { Check, Clock, Search, Timer, X } from 'lucide-svelte';

  interface Props {
    value: TimePreset;
    onApply: (spec: TimePreset) => void;
    onClose: () => void;
    onFocusMainInput?: () => void;
  }

  let { value, onApply, onClose, onFocusMainInput }: Props = $props();

  const initialSynced = untrack(() => resolveSyncedDateTimeParts(value));
  const initialFocusIdx = untrack(() => {
    if (value === '') return -1;
    const idx = FLAT_QUICK_TIME_PRESETS.indexOf(value);
    return idx >= 0 ? idx : -2;
  });

  let quickQuery = $state<string>('');
  let focusedIdx = $state<number>(initialFocusIdx);
  let startParts = $state<DateTimeParts>({ ...initialSynced.start });
  let endParts = $state<DateTimeParts>({ ...initialSynced.end });
  let endIsNow = $state<boolean>(initialSynced.endIsNow);
  let customDirty = $state<boolean>(false);
  let hoverPreset = $state<TimePreset | null>(null);
  let focusedKey = $state<string | null>(null);

  let panelEl = $state<HTMLDivElement | null>(null);
  let quickInputEl = $state<HTMLInputElement | null>(null);
  let listEl = $state<HTMLDivElement | null>(null);
  let slotsRef = $state<DateTimeRangeSlots | null>(null);

  const s = $derived(workbench.t.scopeBar);
  const tp = $derived(s.timePicker);
  const hasQuickQuery = $derived(quickQuery.trim().length > 0);
  const quickCandidates = $derived(
    hasQuickQuery ? matchQuickTimeCandidates(quickQuery, s.timeLabels, s.timeShortLabels) : []
  );

  const activeCandidateSpec = $derived.by((): TimePreset | null => {
    if (customDirty) return null;
    if (hoverPreset !== null) return hoverPreset;
    if (hasQuickQuery) {
      return quickCandidates[focusedIdx]?.spec ?? null;
    }
    if (focusedIdx === -1) return '';
    if (focusedIdx >= 0 && focusedIdx < FLAT_QUICK_TIME_PRESETS.length) {
      return FLAT_QUICK_TIME_PRESETS[focusedIdx];
    }
    return null;
  });

  const previewSynced = $derived(
    !customDirty && activeCandidateSpec !== null
      ? resolveSyncedDateTimeParts(activeCandidateSpec)
      : null
  );

  const displayedStart = $derived(previewSynced ? previewSynced.start : startParts);
  const displayedEnd = $derived(previewSynced ? previewSynced.end : endParts);
  const effectiveEndIsNow = $derived(previewSynced ? previewSynced.endIsNow : endIsNow);
  const compiledSpec = $derived(
    buildSpecFromDateTimeParts(displayedStart, displayedEnd, effectiveEndIsNow)
  );
  const hasCustomSpecBadge = $derived(
    !customDirty && value !== '' && !isBuiltinTimePreset(value) && !hasQuickQuery
  );

  const footerPreviewLabel = $derived.by(() => {
    if (activeCandidateSpec !== null && !customDirty) {
      return activeCandidateSpec === '' ? '' : formatTimeScopeLabel(activeCandidateSpec, s.timeLabels);
    }
    if (!customDirty && value === '') return '';
    if (!customDirty && value !== '') return formatTimeScopeLabel(value, s.timeLabels);
    return formatTimeScopeLabel(compiledSpec, s.timeLabels);
  });

  // Initial focus: desktop gets immediate autofocus on the top quick-expression bar
  $effect(() => {
    queueMicrotask(() => {
      if (!workbench.timePickerOpen) return;
      if (!workbench.isCompact && !workbench.isTouch) {
        quickInputEl?.focus({ preventScroll: true });
      } else {
        panelEl?.focus({ preventScroll: true });
      }
    });
  });

  // Keep keyboard index clamped within filtered candidates when typing
  $effect(() => {
    if (!hasQuickQuery) return;
    if (quickCandidates.length === 0) {
      focusedIdx = -1;
    } else if (focusedIdx < 0 || focusedIdx >= quickCandidates.length) {
      focusedIdx = 0;
    }
  });

  function scrollCandidateIntoView(idx: number) {
    queueMicrotask(() => {
      const target = listEl?.querySelector(`[data-time-idx="${idx}"]`) as HTMLElement | null;
      target?.scrollIntoView({ block: 'nearest' });
    });
  }

  function focusMainIfDesktop() {
    if (!workbench.isCompact && !workbench.isTouch) {
      onFocusMainInput?.();
    }
  }

  function selectPreset(preset: TimePreset) {
    const synced = resolveSyncedDateTimeParts(preset);
    startParts = { ...synced.start };
    endParts = { ...synced.end };
    endIsNow = synced.endIsNow;
    customDirty = false;
    hoverPreset = null;
    onApply(preset);
    focusMainIfDesktop();
  }

  function submitCustomRange() {
    slotsRef?.commitFocusedSlot();

    if (!customDirty && previewSynced && activeCandidateSpec !== null) {
      selectPreset(activeCandidateSpec);
      return;
    }

    if (!customDirty && value !== '') {
      onApply(value);
      focusMainIfDesktop();
      return;
    }

    const normStart = clampDateTimeParts(startParts);
    startParts = normStart;
    if (!endIsNow) {
      endParts = clampDateTimeParts(endParts);
    }
    onApply(buildSpecFromDateTimeParts(normStart, endParts, endIsNow));
    focusMainIfDesktop();
  }

  function handlePanelKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      onClose();
      focusMainIfDesktop();
      return;
    }

    if (e.key === 'Tab' && !e.shiftKey && (e.target === quickInputEl || e.target === panelEl)) {
      e.preventDefault();
      e.stopPropagation();
      onClose();
      onFocusMainInput?.();
      return;
    }

    if (focusedKey !== null) return;

    if (hasQuickQuery) {
      const count = quickCandidates.length;
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        if (count === 0) return;
        e.preventDefault();
        customDirty = false;
        hoverPreset = null;
        focusedIdx =
          e.key === 'ArrowDown'
            ? focusedIdx < count - 1
              ? focusedIdx + 1
              : 0
            : focusedIdx > 0
              ? focusedIdx - 1
              : count - 1;
        scrollCandidateIntoView(focusedIdx);
        return;
      }
      if (e.key === 'Enter') {
        e.preventDefault();
        e.stopPropagation();
        const target = quickCandidates[focusedIdx] ?? quickCandidates[0];
        if (target) {
          selectPreset(target.spec);
        } else if (customDirty) {
          submitCustomRange();
        }
      }
      return;
    }

    const maxPresetIdx = FLAT_QUICK_TIME_PRESETS.length - 1;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      customDirty = false;
      hoverPreset = null;
      focusedIdx =
        e.key === 'ArrowDown'
          ? focusedIdx < maxPresetIdx && focusedIdx >= -1
            ? focusedIdx + 1
            : -1
          : focusedIdx > -1
            ? focusedIdx - 1
            : maxPresetIdx;
      return;
    }

    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      if (!customDirty && focusedIdx === -1) {
        selectPreset('');
        return;
      }
      if (!customDirty && focusedIdx >= 0 && focusedIdx < FLAT_QUICK_TIME_PRESETS.length) {
        selectPreset(FLAT_QUICK_TIME_PRESETS[focusedIdx]);
        return;
      }
      submitCustomRange();
    }
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

{#snippet footer()}
  <div class="flex h-9 shrink-0 items-center justify-between gap-2 border-t border-border/50 bg-muted/30 px-3">
    <div class="min-w-0 flex-1">
      {#if footerPreviewLabel}
        <span class="block truncate font-mono text-[11px] tabular-nums text-muted-foreground">
          {footerPreviewLabel}
        </span>
      {:else}
        <span class="block truncate text-[11px] text-muted-foreground/70">
          {tp.inputHint}
        </span>
      {/if}
    </div>

    <button
      type="button"
      onclick={submitCustomRange}
      class={`touch-target inline-flex h-[26px] shrink-0 items-center rounded-md px-2.5 text-xs font-medium cursor-pointer active:opacity-85 ${
        customDirty || (hasQuickQuery && quickCandidates.length > 0)
          ? 'bg-primary text-primary-foreground hover:opacity-90'
          : 'bg-secondary/75 text-foreground hover:bg-secondary'
      }`}
    >
      {tp.apply}
    </button>
  </div>
{/snippet}

<FloatingPopoverShell
  bind:panelEl
  isCompact={workbench.isCompact}
  ariaLabel={s.timePickerTitle}
  desktopWidthClass="w-[376px] max-w-[calc(100vw-1.5rem)]"
  mobileMaxHeightClass="max-h-[82dvh]"
  {onClose}
  onKeydown={handlePanelKeydown}
  {footer}
>
  <!-- 1. Top Quick-Search / Shorthand / Timestamp-Paste Bar -->
  <div class="flex h-10 shrink-0 items-center gap-2 border-b border-border/55 px-3">
    <Search class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
    <input
      bind:this={quickInputEl}
      type="text"
      bind:value={quickQuery}
      oninput={() => {
        customDirty = false;
        hoverPreset = null;
        focusedIdx = 0;
      }}
      placeholder={s.timeSearchPlaceholder}
      spellcheck="false"
      autocomplete="off"
      class="h-full min-w-0 flex-1 bg-transparent text-[13px] [@media(any-pointer:coarse)]:text-[16px] text-foreground placeholder:text-muted-foreground/60 focus:outline-none"
    />

    {#if quickQuery.length > 0}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => {
          quickQuery = '';
          customDirty = false;
          focusedIdx = value === '' ? -1 : FLAT_QUICK_TIME_PRESETS.indexOf(value);
          quickInputEl?.focus();
        }}
        title={workbench.t.searchBar.clearDraftTitle}
        aria-label={workbench.t.searchBar.clearDraftTitle}
        class="touch-target flex h-6 w-6 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
      >
        <X class="h-3.5 w-3.5" />
      </button>
    {:else if value !== '' || customDirty}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => selectPreset('')}
        class="touch-target inline-flex h-6 shrink-0 items-center rounded-md px-2 text-[11px] font-medium text-muted-foreground hover:bg-secondary hover:text-foreground active:bg-secondary/80 cursor-pointer"
      >
        {tp.reset}
      </button>
    {/if}
  </div>

  <!-- 2. Body: Filtered Quick Candidates OR Structured 3x4 Matrix + Pre-filled Synced Slots -->
  <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain p-2.5 space-y-2.5">
    {#if hasQuickQuery}
      <div
        bind:this={listEl}
        role="listbox"
        aria-label={s.timePickerTitle}
        class="max-h-[184px] overflow-y-auto overscroll-contain space-y-0.5"
      >
        {#if quickCandidates.length === 0}
          <div class="px-3 py-5 text-center text-xs text-muted-foreground">
            {s.timeNoMatch}
          </div>
        {:else}
          {#each quickCandidates as cand, idx (cand.key)}
            {@const checked = !customDirty && value === cand.spec}
            {@const isFocused = focusedIdx === idx}
            <button
              type="button"
              role="option"
              data-time-idx={idx}
              aria-selected={checked}
              onmousedown={(e) => e.preventDefault()}
              onmouseenter={() => {
                focusedIdx = idx;
                hoverPreset = cand.spec;
              }}
              onmouseleave={() => {
                if (hoverPreset === cand.spec) hoverPreset = null;
              }}
              onclick={() => selectPreset(cand.spec)}
              class={`touch-target flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left cursor-pointer ${
                checked
                  ? 'bg-primary/[0.08] hover:bg-primary/[0.12]'
                  : isFocused
                    ? 'bg-secondary/80'
                    : 'hover:bg-secondary/55'
              } ${isFocused && checked ? 'ring-1 ring-inset ring-primary/35' : ''}`}
            >
              <span
                aria-hidden="true"
                class={`flex h-4 w-4 shrink-0 items-center justify-center rounded-[4px] border ${
                  checked
                    ? 'border-primary bg-primary text-primary-foreground'
                    : 'border-border bg-background/80'
                }`}
              >
                {#if checked}
                  <Check class="h-3 w-3 stroke-[2.75]" />
                {/if}
              </span>

              {#if cand.isCustom}
                <Timer class="h-3.5 w-3.5 shrink-0 text-primary" />
              {:else}
                <Clock class={`h-3.5 w-3.5 shrink-0 ${checked ? 'text-primary' : 'text-muted-foreground'}`} />
              {/if}

              <span class="min-w-0 flex-1 truncate text-[12.5px] font-medium text-foreground">
                {@render renderHighlighted(cand.fullLabel, cand.fullRanges)}
              </span>

              <span class="shrink-0 rounded bg-secondary/75 px-1.5 py-0.5 font-mono text-[11px] tabular-nums text-muted-foreground">
                {@render renderHighlighted(cand.shortLabel, cand.shortRanges)}
              </span>

              {#if isFocused && !workbench.isCompact}
                <span class="shrink-0 text-[10px] text-primary/80 font-medium">
                  {s.timeQuickApplyBadge}
                </span>
              {/if}
            </button>
          {/each}
        {/if}
      </div>
    {:else}
      <!-- Pinned Any Time Option -->
      {@const anyActive = !customDirty && value === ''}
      {@const anyFocused = !customDirty && focusedIdx === -1}
      <div class="flex items-center justify-between gap-2">
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onmouseenter={() => {
            if (!customDirty && !workbench.isTouch) hoverPreset = '';
          }}
          onmouseleave={() => {
            if (hoverPreset === '') hoverPreset = null;
          }}
          onclick={() => selectPreset('')}
          title={s.timeLabels['']}
          class={`touch-target inline-flex h-7 items-center gap-1.5 rounded-lg px-2 text-xs cursor-pointer active:bg-primary/20 ${
            anyActive
              ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-medium'
              : anyFocused
                ? 'bg-secondary/80 text-foreground ring-1 ring-inset ring-border'
                : 'bg-secondary/45 text-foreground/85 hover:bg-secondary/80 hover:text-foreground'
          }`}
        >
          <span
            aria-hidden="true"
            class={`flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded-[3px] border ${
              anyActive
                ? 'border-primary bg-primary text-primary-foreground'
                : 'border-border/80 bg-background/75'
            }`}
          >
            {#if anyActive}
              <Check class="h-2.5 w-2.5 stroke-[2.75]" />
            {/if}
          </span>
          <span>{s.timeLabels['']}</span>
        </button>
      </div>

      {#if hasCustomSpecBadge}
        <div class="flex items-center justify-between gap-2 rounded-lg bg-primary/[0.08] px-2.5 py-1.5 ring-1 ring-inset ring-primary/25">
          <div class="flex min-w-0 items-center gap-2">
            <span class="flex h-4 w-4 shrink-0 items-center justify-center rounded-[4px] border border-primary bg-primary text-primary-foreground">
              <Check class="h-3 w-3 stroke-[2.75]" />
            </span>
            <span class="truncate text-xs font-medium text-foreground">
              {formatTimeScopeLabel(value, s.timeLabels)}
            </span>
          </div>
          <span class="shrink-0 font-mono text-[11px] tabular-nums text-primary">{value}</span>
        </div>
      {/if}

      <!-- Structured 3x4 Quick Preset Matrix -->
      <div
        role="presentation"
        class="space-y-1.5"
        onmouseleave={() => {
          hoverPreset = null;
        }}
      >
        {#each QUICK_TIME_PRESET_GROUPS as group, gIdx (group.id)}
          <div class="grid grid-cols-4 gap-1.5">
            {#each group.presets as preset, pIdx (preset)}
              {@const flatIdx = gIdx * 4 + pIdx}
              {@const active = !customDirty && value === preset}
              {@const keyFocused = !customDirty && focusedIdx === flatIdx}
              {@const isNamedDay = preset === 'today' || preset === 'yesterday'}
              <button
                type="button"
                onmousedown={(e) => e.preventDefault()}
                onmouseenter={() => {
                  if (!customDirty && !workbench.isTouch) hoverPreset = preset;
                }}
                onclick={() => selectPreset(preset)}
                title={s.timeLabels[preset] ?? preset}
                class={`touch-target flex h-8 items-center justify-center rounded-lg text-xs tabular-nums cursor-pointer active:bg-primary/20 ${
                  isNamedDay ? '' : 'font-mono'
                } ${
                  active
                    ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-medium'
                    : keyFocused
                      ? 'bg-secondary/85 text-foreground ring-1 ring-inset ring-border'
                      : 'bg-secondary/45 text-foreground/90 hover:bg-secondary/80 hover:text-foreground'
                }`}
              >
                {s.timeShortLabels[preset] ?? s.timeLabels[preset] ?? preset}
              </button>
            {/each}
          </div>
        {/each}
      </div>
    {/if}

    <div class="border-t border-border/50"></div>

    <!-- 3. Pre-filled, Synced, Segmented Year/Month/Day Hour:Minute:Second Rows -->
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
</FloatingPopoverShell>
