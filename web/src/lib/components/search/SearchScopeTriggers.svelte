<script lang="ts">
  import { flushSync } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { formatTimeTriggerLabel, isBuiltinTimePreset } from '$lib/time-range';
  import TimeRangePicker from '../TimeRangePicker.svelte';
  import { ChevronDown, Clock, X } from 'lucide-svelte';

  interface Props {
    timeWrapEl?: HTMLDivElement | null;
    onBeforeOpenPicker: () => void;
    onFocusMainInput: () => void;
  }

  let {
    timeWrapEl = $bindable(null),
    onBeforeOpenPicker,
    onFocusMainInput,
  }: Props = $props();

  let timeTriggerOnDown = false;
  let draftExcludeOnDown = false;

  const scopeStrings = $derived(workbench.t.scopeBar);
  const hasTimeScope = $derived(workbench.scope.timePreset !== '');
  const hasCustomTime = $derived(hasTimeScope && !isBuiltinTimePreset(workbench.scope.timePreset));
  const timeTriggerLabel = $derived(
    formatTimeTriggerLabel(
      workbench.scope.timePreset,
      scopeStrings.timeShortLabels,
      scopeStrings.timeTriggerAny
    )
  );

  function isPrimaryMouseDown(e: PointerEvent): boolean {
    return e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey;
  }

  function handleTimeTriggerPointerDown(e: PointerEvent) {
    if (isPrimaryMouseDown(e) && !workbench.timePickerOpen) {
      e.preventDefault();
      timeTriggerOnDown = true;
      onBeforeOpenPicker();
      flushSync(() => workbench.openTimePicker());
    }
  }

  function handleTimeTriggerClick(e: MouseEvent) {
    if (timeTriggerOnDown && e.detail > 0) {
      timeTriggerOnDown = false;
      return;
    }
    timeTriggerOnDown = false;
    onBeforeOpenPicker();
    workbench.toggleTimePicker();
  }

  function handleDraftExcludePointerDown(e: PointerEvent) {
    if (isPrimaryMouseDown(e)) {
      e.preventDefault();
      draftExcludeOnDown = true;
      flushSync(() => workbench.toggleDraftExclude());
    }
  }

  function handleDraftExcludeClick(e: MouseEvent) {
    if (draftExcludeOnDown && e.detail > 0) {
      draftExcludeOnDown = false;
      return;
    }
    draftExcludeOnDown = false;
    workbench.toggleDraftExclude();
  }
</script>

<!-- Embedded Time Range Selector right next to the Search icon -->
<div bind:this={timeWrapEl} class="relative flex items-center shrink-0">
  <div
    class={`inline-flex h-7 items-center rounded-md text-xs select-none ${
      hasTimeScope
        ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-medium hover:bg-primary/20'
        : workbench.timePickerOpen
          ? 'bg-secondary text-foreground ring-1 ring-inset ring-border/75 font-medium'
          : 'text-muted-foreground hover:bg-secondary/70 hover:text-foreground active:bg-secondary'
    }`}
  >
    <button
      type="button"
      aria-haspopup="dialog"
      aria-expanded={workbench.timePickerOpen}
      title={scopeStrings.openTimePickerTitle}
      aria-label={scopeStrings.openTimePickerTitle}
      onpointerdown={handleTimeTriggerPointerDown}
      onclick={handleTimeTriggerClick}
      class={`touch-target inline-flex h-full items-center gap-1 cursor-pointer ${
        hasTimeScope
          ? 'px-1.5 sm:pl-2 sm:pr-1 rounded-md sm:rounded-l-md sm:rounded-r-none'
          : 'px-1.5 sm:px-2 rounded-md'
      }`}
    >
      <Clock
        class={`shrink-0 ${
          hasTimeScope ? 'hidden sm:block h-3 w-3' : 'h-3.5 w-3.5 sm:h-3 sm:w-3'
        }`}
      />
      {#if hasTimeScope}
        <span
          class={`truncate font-mono tabular-nums ${
            hasCustomTime ? 'max-w-[40px] sm:max-w-[144px]' : 'max-w-[44px] sm:max-w-[112px]'
          }`}
        >
          {timeTriggerLabel}
        </span>
      {:else}
        <span class="hidden sm:inline truncate">{timeTriggerLabel}</span>
        <ChevronDown
          class={`hidden sm:block h-3 w-3 shrink-0 opacity-65 transition-transform ${
            workbench.timePickerOpen ? 'rotate-180' : ''
          }`}
        />
      {/if}
    </button>

    {#if hasTimeScope}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onpointerdown={(e) => e.stopPropagation()}
        onclick={(e) => {
          e.stopPropagation();
          workbench.setScopeTime('');
          workbench.closeTimePicker();
        }}
        title={scopeStrings.clearScope}
        aria-label={scopeStrings.clearScope}
        class="touch-target hidden sm:inline-flex h-full w-5 items-center justify-center rounded-r-md hover:bg-primary/25 cursor-pointer"
      >
        <X class="h-3 w-3" />
      </button>
    {/if}
  </div>

  {#if workbench.timePickerOpen}
    <TimeRangePicker
      value={workbench.scope.timePreset}
      onApply={(spec) => {
        workbench.setScopeTime(spec);
        workbench.closeTimePicker();
      }}
      onClose={() => workbench.closeTimePicker()}
      {onFocusMainInput}
    />
  {/if}
</div>

<span aria-hidden="true" class="ml-0.5 h-4 w-px shrink-0 bg-border/65"></span>

{#if workbench.canExcludeDraft}
  <button
    type="button"
    onmousedown={(e) => e.preventDefault()}
    onpointerdown={handleDraftExcludePointerDown}
    onclick={handleDraftExcludeClick}
    title={workbench.t.searchBar.draftExcludeTitle(workbench.draftExclude)}
    aria-label={workbench.t.searchBar.draftExcludeTitle(workbench.draftExclude)}
    class={`touch-target inline-flex h-5 items-center rounded px-1 sm:px-1.5 font-mono text-[11px] font-semibold ring-1 ring-inset cursor-pointer ${
      workbench.draftExclude
        ? 'bg-status/15 text-status ring-status/35 hover:bg-status/25'
        : 'bg-primary/12 text-primary ring-primary/25 hover:bg-primary/20'
    }`}
  >
    {workbench.draftExclude ? '-' : '+'}
  </button>
{/if}
