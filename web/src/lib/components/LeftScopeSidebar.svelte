<script lang="ts">
  import { flushSync } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { formatTimeScopeLabel, isBuiltinTimePreset } from '$lib/time-range';
  import TimeRangePicker from './TimeRangePicker.svelte';
  import SourcePickerContent from './pickers/SourcePickerContent.svelte';
  import { Clock, Database, Pin, RotateCcw, Settings2, X } from 'lucide-svelte';

  interface Props {
    onFocusMainInput?: () => void;
  }

  let { onFocusMainInput }: Props = $props();

  let railEl = $state<HTMLElement | null>(null);
  let flyoutEl = $state<HTMLDivElement | null>(null);
  let sourcePickerRef = $state<SourcePickerContent | null>(null);
  let railPickedOnDown: 'time' | 'sources' | null = null;

  const s = $derived(workbench.t.scopeBar);
  const timePreset = $derived(workbench.scope.timePreset);
  const hasTimeScope = $derived(timePreset !== '');
  const selectedCount = $derived(workbench.scope.sources.length);
  const excludedCount = $derived(workbench.scope.excludedSources?.length ?? 0);
  const hasSourceScope = $derived(selectedCount > 0 || excludedCount > 0);
  const timeOpen = $derived(workbench.railFlyout === 'time');
  const sourcesOpen = $derived(workbench.railFlyout === 'sources');

  const sourceCountBadge = $derived.by(() => {
    if (selectedCount > 0 && excludedCount > 0) return `${selectedCount}/-${excludedCount}`;
    if (selectedCount > 0) return `${selectedCount}/${workbench.sources.length}`;
    if (excludedCount > 0) return `-${excludedCount}`;
    return workbench.sourcesLoaded ? String(workbench.enabledSourceCount) : '';
  });

  const timeRailBadge = $derived.by(() => {
    if (!hasTimeScope) return '';
    if (isBuiltinTimePreset(timePreset)) {
      return s.timeShortLabels[timePreset] ?? timePreset;
    }
    return s.customTimeShort;
  });

  const timeTooltip = $derived(
    `${s.timeSectionTitle} · ${formatTimeScopeLabel(timePreset, s.timeLabels)}`
  );

  const sourceTooltip = $derived(
    `${s.sourcesSectionTitle} · ${
      hasSourceScope ? s.pickerSummaryCustom(selectedCount, excludedCount) : s.pickerSummaryAll
    }`
  );

  function onRailPointerDown(panel: 'time' | 'sources', e: PointerEvent) {
    if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
      e.preventDefault();
      railPickedOnDown = panel;
      flushSync(() => workbench.toggleRailFlyout(panel));
    }
  }

  function onRailClick(panel: 'time' | 'sources', e: MouseEvent) {
    if (railPickedOnDown === panel && e.detail > 0) {
      railPickedOnDown = null;
      return;
    }
    railPickedOnDown = null;
    flushSync(() => workbench.toggleRailFlyout(panel));
  }

  function handleWindowPointerDown(e: PointerEvent) {
    if (workbench.isCompact || workbench.leftSidebarOpen || workbench.railFlyout === null) return;
    const target = e.target as Node | null;
    if (!target) return;
    if (railEl?.contains(target) || flyoutEl?.contains(target)) return;
    workbench.closeRailFlyout();
  }

  function clearAllScope() {
    workbench.clearScopeTime();
    workbench.clearScopeSources();
    workbench.closeRailFlyout();
    onFocusMainInput?.();
  }
</script>

<svelte:window onpointerdown={handleWindowPointerDown} />

{#snippet sourcesHeader(showPin: boolean, showClose: boolean)}
  <div class="flex h-8 shrink-0 items-center justify-between gap-2 bg-card/30 px-2.5">
    <div class="flex min-w-0 items-center gap-1.5" title={s.sourcesSectionTitle}>
      <Database
        class={`h-3.5 w-3.5 shrink-0 ${hasSourceScope ? 'text-primary' : 'text-muted-foreground/75'}`}
      />
      {#if sourceCountBadge}
        <span
          class={`rounded px-1.5 py-0.5 font-mono text-[10.5px] leading-none tabular-nums ${
            hasSourceScope
              ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/30'
              : 'bg-secondary/65 text-muted-foreground'
          }`}
        >
          {sourceCountBadge}
        </span>
      {/if}
    </div>

    <div class="flex shrink-0 items-center gap-0.5">
      {#if hasSourceScope}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={() => workbench.clearScopeSources()}
          title={s.resetToAll}
          aria-label={s.resetToAll}
          class="touch-target flex h-5 w-5 items-center justify-center rounded text-muted-foreground/75 hover:bg-secondary hover:text-foreground cursor-pointer"
        >
          <RotateCcw class="h-3 w-3" />
        </button>
      {/if}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => workbench.openSourcesDrawer(false)}
        title={workbench.t.header.sourcesTriggerTitle}
        aria-label={workbench.t.header.sourcesTriggerTitle}
        class="touch-target flex h-6 w-6 items-center justify-center rounded text-muted-foreground/75 hover:bg-secondary hover:text-foreground cursor-pointer"
      >
        <Settings2 class="h-3.5 w-3.5" />
      </button>
      {#if showPin}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={() => workbench.toggleScopeSidebar()}
          title={s.pinSidebar}
          aria-label={s.pinSidebar}
          class="touch-target flex h-6 w-6 items-center justify-center rounded text-muted-foreground/75 hover:bg-secondary hover:text-foreground cursor-pointer"
        >
          <Pin class="h-3.5 w-3.5" />
        </button>
      {/if}
      {#if showClose}
        <button
          type="button"
          onclick={() => {
            workbench.closeRailFlyout();
            onFocusMainInput?.();
          }}
          title={workbench.t.ui.close}
          aria-label={workbench.t.ui.close}
          class="touch-target flex h-6 w-6 items-center justify-center rounded text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
        >
          <X class="h-3.5 w-3.5" />
        </button>
      {/if}
    </div>
  </div>
{/snippet}

{#snippet dockedSections(showClose: boolean, showUnpin: boolean)}
  <!-- Top Half: Time Range -->
  <section class="shrink-0 border-b border-border/50">
    <TimeRangePicker
      value={workbench.scope.timePreset}
      {showClose}
      pinned={showUnpin}
      onPin={showUnpin ? () => workbench.toggleScopeSidebar() : undefined}
      onClose={() => workbench.closeMobileScope()}
      onApply={(spec) => workbench.setScopeTime(spec)}
      {onFocusMainInput}
    />
  </section>

  <!-- Bottom Half: Data Sources -->
  <section class="flex min-h-[220px] flex-1 flex-col">
    {@render sourcesHeader(false, false)}
    <SourcePickerContent sidebar {onFocusMainInput} />
  </section>
{/snippet}

{#if workbench.isCompact}
  {#if workbench.mobileScopeOpen}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div
      class="fixed inset-0 z-40 bg-black/45"
      onclick={() => workbench.closeMobileScope()}
      onkeydown={(e) => {
        if (e.key === 'Escape') workbench.closeMobileScope();
      }}
    ></div>
    <aside
      aria-label={s.sidebarTitle}
      class="pt-safe pb-safe fixed inset-y-0 left-0 z-50 flex w-[min(86vw,300px)] flex-col overflow-y-auto border-r border-border bg-background shadow-2xl select-none"
    >
      {@render dockedSections(true, false)}
    </aside>
  {/if}
{:else if workbench.leftSidebarOpen}
  <!-- Desktop Pinned Docked Mode -->
  <aside
    aria-label={s.sidebarTitle}
    class="flex h-full w-[276px] xl:w-[292px] shrink-0 flex-col overflow-y-auto md:overflow-hidden border-r border-border/50 bg-card/15 select-none"
  >
    {@render dockedSections(false, true)}
  </aside>
{:else}
  <!-- Desktop 48px Icon Rail (default, zero intrusion on search viewport) -->
  <nav
    bind:this={railEl}
    aria-label={s.sidebarTitle}
    class="flex h-full w-12 shrink-0 flex-col items-center justify-between border-r border-border/45 bg-card/15 py-2 select-none"
  >
    <div class="flex w-full flex-col items-center gap-1.5 px-1">
      <!-- Time Scope Rail Trigger -->
      <button
        type="button"
        title={timeTooltip}
        aria-label={timeTooltip}
        aria-expanded={timeOpen}
        aria-haspopup="dialog"
        onpointerdown={(e) => onRailPointerDown('time', e)}
        onclick={(e) => onRailClick('time', e)}
        class={`flex w-10 min-h-[36px] flex-col items-center justify-center gap-0.5 rounded-lg py-1.5 cursor-pointer ${
          timeOpen && hasTimeScope
            ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/40'
            : timeOpen
              ? 'bg-secondary/85 text-foreground ring-1 ring-inset ring-border/70'
              : hasTimeScope
                ? 'bg-primary/10 text-primary ring-1 ring-inset ring-primary/25 hover:bg-primary/15'
                : 'text-muted-foreground/75 hover:bg-secondary/65 hover:text-foreground'
        }`}
      >
        <Clock class={hasTimeScope ? 'h-3.5 w-3.5 shrink-0' : 'h-4 w-4 shrink-0'} />
        {#if timeRailBadge}
          <span class="max-w-[36px] truncate font-mono text-[9.5px] font-medium leading-none tabular-nums">
            {timeRailBadge}
          </span>
        {/if}
      </button>

      <!-- Sources Scope Rail Trigger -->
      <button
        type="button"
        title={sourceTooltip}
        aria-label={sourceTooltip}
        aria-expanded={sourcesOpen}
        aria-haspopup="dialog"
        onpointerdown={(e) => onRailPointerDown('sources', e)}
        onclick={(e) => onRailClick('sources', e)}
        class={`flex w-10 min-h-[36px] flex-col items-center justify-center gap-0.5 rounded-lg py-1.5 cursor-pointer ${
          sourcesOpen && hasSourceScope
            ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/40'
            : sourcesOpen
              ? 'bg-secondary/85 text-foreground ring-1 ring-inset ring-border/70'
              : hasSourceScope
                ? 'bg-primary/10 text-primary ring-1 ring-inset ring-primary/25 hover:bg-primary/15'
                : 'text-muted-foreground/75 hover:bg-secondary/65 hover:text-foreground'
        }`}
      >
        <Database class="h-3.5 w-3.5 shrink-0" />
        {#if sourceCountBadge}
          <span class="max-w-[36px] truncate font-mono text-[9.5px] font-medium leading-none tabular-nums">
            {sourceCountBadge}
          </span>
        {/if}
      </button>

      <!-- One-Click Reset All Scope -->
      {#if workbench.hasActiveScope}
        <div class="my-0.5 w-5 border-t border-border/45"></div>
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={clearAllScope}
          title={s.clearAllScope}
          aria-label={s.clearAllScope}
          class="flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary hover:text-foreground cursor-pointer"
        >
          <RotateCcw class="h-3.5 w-3.5" />
        </button>
      {/if}
    </div>

    <!-- Bottom Rail Utilities: Pin Dock & Manage Sources -->
    <div class="flex w-full flex-col items-center gap-1 px-1">
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => workbench.toggleScopeSidebar()}
        title={s.pinSidebar}
        aria-label={s.pinSidebar}
        class="flex h-8 w-8 items-center justify-center rounded-md text-muted-foreground/70 hover:bg-secondary/65 hover:text-foreground cursor-pointer"
      >
        <Pin class="h-3.5 w-3.5" />
      </button>
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => workbench.openSourcesDrawer(false)}
        title={workbench.t.header.sourcesTriggerTitle}
        aria-label={workbench.t.header.sourcesTriggerTitle}
        class="flex h-8 w-8 items-center justify-center rounded-md text-muted-foreground/70 hover:bg-secondary/65 hover:text-foreground cursor-pointer"
      >
        <Settings2 class="h-3.5 w-3.5" />
      </button>
    </div>
  </nav>

  <!-- Floating Flyout Popover (Zero Layout Reflow) -->
  {#if workbench.railFlyout !== null}
    <div
      bind:this={flyoutEl}
      role="dialog"
      tabindex="-1"
      aria-label={workbench.railFlyout === 'time' ? s.timeSectionTitle : s.sourcesSectionTitle}
      onkeydown={(e) => {
        if (workbench.railFlyout === 'sources') {
          sourcePickerRef?.handleKeydown(e);
        }
      }}
      class="absolute left-12 top-2 z-40 ml-1.5 w-[288px] overflow-hidden rounded-xl border border-border/75 bg-popover shadow-2xl select-none"
    >
      {#if workbench.railFlyout === 'time'}
        <TimeRangePicker
          value={workbench.scope.timePreset}
          showClose
          pinned={false}
          onPin={() => workbench.toggleScopeSidebar()}
          onClose={() => {
            workbench.closeRailFlyout();
            onFocusMainInput?.();
          }}
          onApply={(spec) => {
            workbench.setScopeTime(spec);
            workbench.closeRailFlyout();
            onFocusMainInput?.();
          }}
          {onFocusMainInput}
        />
      {:else}
        <div class="flex max-h-[min(70vh,460px)] min-h-[200px] flex-col">
          {@render sourcesHeader(true, true)}
          <SourcePickerContent
            bind:this={sourcePickerRef}
            onClose={() => {
              workbench.closeRailFlyout();
              onFocusMainInput?.();
            }}
            {onFocusMainInput}
          />
        </div>
      {/if}
    </div>
  {/if}
{/if}
