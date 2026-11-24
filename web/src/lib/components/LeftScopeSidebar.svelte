<script lang="ts">
  import { flushSync, onDestroy } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { formatTimeScopeLabel, isBuiltinTimePreset } from '$lib/time-range';
  import TimeRangePicker from './TimeRangePicker.svelte';
  import SourcePickerContent from './pickers/SourcePickerContent.svelte';
  import {
    Blocks,
    Clock,
    Database,
    Eraser,
    Keyboard,
    Layers,
    Lock,
    SlidersHorizontal,
    WifiOff,
    X,
  } from 'lucide-svelte';

  interface Props {
    onFocusMainInput?: () => void;
  }

  let { onFocusMainInput }: Props = $props();

  type RailAction =
    | 'time'
    | 'sources'
    | 'manage-sources'
    | 'mcp'
    | 'shortcuts'
    | 'settings';

  let railEl = $state<HTMLElement | null>(null);
  let flyoutEl = $state<HTMLDivElement | null>(null);
  let mobilePanelEl = $state<HTMLElement | null>(null);
  let timePickerRef = $state<TimeRangePicker | null>(null);
  let sourcePickerRef = $state<SourcePickerContent | null>(null);
  let railPickedOnDown: RailAction | null = null;

  // Silky GPU mount/enter state for desktop floating flyout
  let flyoutMounted = $state(false);
  let flyoutEntered = $state(false);
  let flyoutPanel = $state<'time' | 'sources' | null>(null);
  let flyoutExitTimer: ReturnType<typeof setTimeout> | null = null;

  // Silky GPU mount/enter state for mobile slide-in drawer
  let mobileMounted = $state(false);
  let mobileEntered = $state(false);
  let mobileExitTimer: ReturnType<typeof setTimeout> | null = null;

  const s = $derived(workbench.t.scopeBar);
  const timePreset = $derived(workbench.scope.timePreset);
  const hasTimeScope = $derived(timePreset !== '');
  const selectedCount = $derived(workbench.scope.sources.length);
  const excludedCount = $derived(workbench.scope.excludedSources?.length ?? 0);
  const hasSourceScope = $derived(selectedCount > 0 || excludedCount > 0);
  const timeOpen = $derived(workbench.railFlyout === 'time');
  const sourcesOpen = $derived(workbench.railFlyout === 'sources');

  const hasMissingSource = $derived(
    workbench.sourcesLoaded &&
      (workbench.sources.length === 0 || workbench.sources.some((src) => src.enabled && !src.exists))
  );
  const isOffline = $derived(workbench.wsStatus === 'offline' || workbench.wsDegraded);

  const sourceCountBadge = $derived.by(() => {
    if (selectedCount > 0 && excludedCount > 0) return `${selectedCount}/-${excludedCount}`;
    if (selectedCount > 0) return `${selectedCount}/${workbench.sources.length}`;
    if (excludedCount > 0) return `-${excludedCount}`;
    return workbench.sourcesLoaded ? String(workbench.enabledSourceCount) : '';
  });

  const sourceHeaderBadge = $derived.by(() => {
    if (hasSourceScope) return sourceCountBadge;
    return workbench.sourcesLoaded ? `${s.sourceTriggerAll} ${workbench.enabledSourceCount}` : '';
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

  const utilBtn =
    'touch-target relative flex h-8 w-8 items-center justify-center rounded-md active:bg-secondary/80 cursor-pointer';
  const utilActive = 'bg-secondary/85 text-foreground ring-1 ring-inset ring-border/60';
  const utilIdle = 'text-muted-foreground/75 hover:text-foreground hover:bg-secondary/60';

  function finishFlyoutExit() {
    if (flyoutExitTimer !== null) {
      clearTimeout(flyoutExitTimer);
      flyoutExitTimer = null;
    }
    if (workbench.railFlyout === null || workbench.isCompact) {
      flyoutMounted = false;
      flyoutPanel = null;
    }
  }

  function finishMobileExit() {
    if (mobileExitTimer !== null) {
      clearTimeout(mobileExitTimer);
      mobileExitTimer = null;
    }
    if (!workbench.mobileScopeOpen || !workbench.isCompact) {
      mobileMounted = false;
    }
  }

  $effect(() => {
    const active = !workbench.isCompact ? workbench.railFlyout : null;
    if (active !== null) {
      flyoutPanel = active;
      if (flyoutExitTimer !== null) {
        clearTimeout(flyoutExitTimer);
        flyoutExitTimer = null;
      }
      if (!flyoutMounted) {
        flyoutEntered = false;
        flyoutMounted = true;
        return;
      }
      if (!flyoutEntered && flyoutEl) {
        void flyoutEl.getBoundingClientRect();
        flyoutEntered = true;
      }
      return;
    }
    if (flyoutMounted) {
      flyoutEntered = false;
      if (flyoutExitTimer === null) {
        flyoutExitTimer = setTimeout(finishFlyoutExit, workbench.frameProfile.sheetMotionMs + 60);
      }
    }
  });

  $effect(() => {
    const open = workbench.isCompact && workbench.mobileScopeOpen;
    if (open) {
      if (mobileExitTimer !== null) {
        clearTimeout(mobileExitTimer);
        mobileExitTimer = null;
      }
      if (!mobileMounted) {
        mobileEntered = false;
        mobileMounted = true;
        return;
      }
      if (!mobileEntered && mobilePanelEl) {
        void mobilePanelEl.getBoundingClientRect();
        mobileEntered = true;
      }
      return;
    }
    if (mobileMounted) {
      mobileEntered = false;
      if (mobileExitTimer === null) {
        mobileExitTimer = setTimeout(finishMobileExit, workbench.frameProfile.sheetMotionMs + 60);
      }
    }
  });

  onDestroy(() => {
    if (flyoutExitTimer !== null) clearTimeout(flyoutExitTimer);
    if (mobileExitTimer !== null) clearTimeout(mobileExitTimer);
  });

  function runRailAction(action: RailAction) {
    if (workbench.railFlyout === 'time') {
      timePickerRef?.commitIfDirty();
    }
    if (action === 'time' || action === 'sources') {
      workbench.toggleRailFlyout(action);
    } else if (action === 'manage-sources') {
      if (workbench.sourcesDrawerOpen) workbench.closeRightDrawer();
      else workbench.openSourcesDrawer(workbench.sources.length === 0);
    } else if (action === 'mcp') {
      if (workbench.mcpDrawerOpen) workbench.closeRightDrawer();
      else workbench.openMcpDrawer();
    } else if (action === 'shortcuts') {
      if (workbench.shortcutsDrawerOpen) workbench.closeRightDrawer();
      else workbench.openShortcutsDrawer();
    } else {
      if (workbench.settingsOpen) workbench.closeRightDrawer();
      else workbench.openSettingsDrawer();
    }
  }

  function onRailPointerDown(action: RailAction, e: PointerEvent) {
    if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
      e.preventDefault();
      railPickedOnDown = action;
      flushSync(() => runRailAction(action));
    }
  }

  function onRailClick(action: RailAction, e: MouseEvent) {
    if (railPickedOnDown === action && e.detail > 0) {
      railPickedOnDown = null;
      return;
    }
    railPickedOnDown = null;
    flushSync(() => runRailAction(action));
  }

  function handleWindowPointerDown(e: PointerEvent) {
    if (workbench.isCompact || workbench.railFlyout === null) return;
    const path = typeof e.composedPath === 'function' ? e.composedPath() : [];
    if (
      (railEl && path.includes(railEl)) ||
      (flyoutEl && path.includes(flyoutEl))
    ) {
      return;
    }
    const target = e.target as Node | null;
    if (target && (railEl?.contains(target) || flyoutEl?.contains(target))) return;
    if (workbench.railFlyout === 'time') {
      timePickerRef?.commitIfDirty();
    }
    workbench.closeRailFlyout();
  }

  function clearAllScope() {
    workbench.clearScopeAll();
    workbench.closeRailFlyout();
    onFocusMainInput?.();
  }
</script>

<svelte:window onpointerdown={handleWindowPointerDown} />

{#snippet sourcesHeader(showClose = false)}
  <div class="flex h-8 shrink-0 items-center justify-between gap-2 bg-card/30 px-2.5">
    <div class="flex min-w-0 items-center gap-1.5" title={s.sourcesSectionTitle}>
      <Layers
        class={`h-3.5 w-3.5 shrink-0 ${hasSourceScope ? 'text-primary' : 'text-muted-foreground/75'}`}
      />
      <span class="shrink-0 text-[11.5px] font-medium text-muted-foreground">
        {s.sourcesSectionTitle}
      </span>
      {#if sourceHeaderBadge}
        <span
          class={`rounded px-1.5 py-0.5 font-mono text-[10.5px] leading-none tabular-nums ${
            hasSourceScope
              ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/30'
              : 'bg-secondary/65 text-muted-foreground'
          }`}
        >
          {sourceHeaderBadge}
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
          class="touch-target flex h-5 w-5 shrink-0 items-center justify-center rounded text-muted-foreground/75 hover:bg-secondary hover:text-foreground cursor-pointer"
        >
          <Eraser class="h-3.5 w-3.5" />
        </button>
      {/if}
      {#if showClose}
        <button
          type="button"
          onclick={() => workbench.closeMobileScope()}
          title={workbench.t.settings.closePanelTitle}
          aria-label={workbench.t.settings.closePanelTitle}
          class="touch-target flex h-6 w-6 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
        >
          <X class="h-3.5 w-3.5" />
        </button>
      {/if}
    </div>
  </div>
{/snippet}

{#snippet mobileSections()}
  {#if workbench.hasLogSourceInScope}
    <section class="shrink-0 border-b border-border/50">
      <TimeRangePicker
        value={workbench.scope.timePreset}
        showClose
        onClose={() => workbench.closeMobileScope()}
        onApply={(spec) => workbench.setScopeTime(spec)}
        {onFocusMainInput}
      />
    </section>
  {/if}

  <section class="flex min-h-[220px] flex-1 flex-col">
    {@render sourcesHeader(!workbench.hasLogSourceInScope)}
    <SourcePickerContent
      sidebar
      onClose={() => workbench.closeMobileScope()}
      {onFocusMainInput}
    />
  </section>
{/snippet}

{#if workbench.isCompact}
  {#if mobileMounted}
    <div
      class={`fixed inset-0 z-40 ${workbench.mobileScopeOpen ? 'pointer-events-auto' : 'pointer-events-none'}`}
    >
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        class="left-scrim absolute inset-0 bg-black/45"
        data-open={mobileEntered ? 'true' : 'false'}
        onclick={() => workbench.closeMobileScope()}
        onkeydown={(e) => {
          if (e.key === 'Escape') workbench.closeMobileScope();
        }}
      ></div>
      <aside
        bind:this={mobilePanelEl}
        aria-label={s.sidebarTitle}
        data-open={mobileEntered ? 'true' : 'false'}
        ontransitionend={(e) => {
          if (e.target === mobilePanelEl && e.propertyName === 'transform' && !workbench.mobileScopeOpen) {
            finishMobileExit();
          }
        }}
        class="left-mobile-drawer pt-safe pb-safe absolute inset-y-0 left-0 z-10 flex w-[min(92vw,320px)] flex-col overflow-y-auto border-r border-border bg-background shadow-2xl select-none"
      >
        {@render mobileSections()}
      </aside>
    </div>
  {/if}
{:else}
  <!-- Desktop Unified 48px Left Rail (scope flyouts + utility drawers) -->
  <nav
    bind:this={railEl}
    aria-label={s.sidebarTitle}
    class="relative z-40 flex h-full w-12 shrink-0 flex-col items-center justify-between border-r border-border/45 bg-card/15 py-2 select-none"
  >
    <!-- Top Cluster: Time & Source Scope -->
    <div class="flex w-full flex-col items-center gap-1.5 px-1">
      {#if workbench.hasLogSourceInScope}
        <!-- Time Scope Trigger (auto-hidden when scope is code-only) -->
        <button
          type="button"
          title={timeTooltip}
          aria-label={timeTooltip}
          aria-expanded={timeOpen}
          aria-haspopup="dialog"
          onpointerdown={(e) => onRailPointerDown('time', e)}
          onclick={(e) => onRailClick('time', e)}
          class={`touch-target flex w-10 min-h-[36px] flex-col items-center justify-center gap-0.5 rounded-lg py-1.5 cursor-pointer ${
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
      {/if}

      <!-- Sources Scope Trigger -->
      <button
        type="button"
        title={sourceTooltip}
        aria-label={sourceTooltip}
        aria-expanded={sourcesOpen}
        aria-haspopup="dialog"
        onpointerdown={(e) => onRailPointerDown('sources', e)}
        onclick={(e) => onRailClick('sources', e)}
        class={`touch-target flex w-10 min-h-[36px] flex-col items-center justify-center gap-0.5 rounded-lg py-1.5 cursor-pointer ${
          sourcesOpen && hasSourceScope
            ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/40'
            : sourcesOpen
              ? 'bg-secondary/85 text-foreground ring-1 ring-inset ring-border/70'
              : hasSourceScope
                ? 'bg-primary/10 text-primary ring-1 ring-inset ring-primary/25 hover:bg-primary/15'
                : 'text-muted-foreground/75 hover:bg-secondary/65 hover:text-foreground'
        }`}
      >
        <Layers class="h-3.5 w-3.5 shrink-0" />
        {#if sourceCountBadge}
          <span class="max-w-[36px] truncate font-mono text-[9.5px] font-medium leading-none tabular-nums">
            {sourceCountBadge}
          </span>
        {/if}
      </button>

      <!-- One-Click Clear All Scope -->
      {#if workbench.hasActiveScope}
        <div class="my-0.5 w-5 border-t border-border/45"></div>
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={clearAllScope}
          title={s.clearAllScope}
          aria-label={s.clearAllScope}
          class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary hover:text-foreground cursor-pointer"
        >
          <Eraser class="h-3.5 w-3.5" />
        </button>
      {/if}
    </div>

    <!-- Bottom Cluster: Utility Drawers -->
    <div class="flex w-full flex-col items-center gap-1 px-1">
      {#if isOffline}
        <button
          type="button"
          title={workbench.t.header.reconnectTitle}
          aria-label={workbench.t.header.reconnectTitle}
          onclick={() => workbench.connectWebSocket()}
          class={`${utilBtn} text-status hover:bg-status/15`}
        >
          <WifiOff class="h-3.5 w-3.5" />
        </button>
      {/if}

      <button
        type="button"
        title={workbench.t.header.sourcesTriggerTitle}
        aria-label={workbench.t.header.manageBtn}
        aria-expanded={workbench.sourcesDrawerOpen}
        onpointerdown={(e) => onRailPointerDown('manage-sources', e)}
        onclick={(e) => onRailClick('manage-sources', e)}
        class={`${utilBtn} ${workbench.sourcesDrawerOpen ? utilActive : utilIdle}`}
      >
        <Database class="h-3.5 w-3.5" />
        {#if hasMissingSource}
          <span class="absolute right-1 top-1 h-1.5 w-1.5 rounded-full bg-status"></span>
        {/if}
      </button>

      <button
        type="button"
        title={workbench.t.header.mcpTitle}
        aria-label={workbench.t.header.mcpBtn}
        aria-expanded={workbench.mcpDrawerOpen}
        onpointerdown={(e) => onRailPointerDown('mcp', e)}
        onclick={(e) => onRailClick('mcp', e)}
        class={`${utilBtn} ${workbench.mcpDrawerOpen ? utilActive : utilIdle}`}
      >
        <Blocks class="h-3.5 w-3.5" />
        {#if workbench.mcpLoaded && workbench.mcpEnabled}
          <span class="absolute right-1 top-1 h-1.5 w-1.5 rounded-full bg-primary/85"></span>
        {/if}
      </button>

      <button
        type="button"
        title={workbench.t.header.shortcutsTitle}
        aria-label={workbench.t.header.shortcutsBtn}
        aria-expanded={workbench.shortcutsDrawerOpen}
        onpointerdown={(e) => onRailPointerDown('shortcuts', e)}
        onclick={(e) => onRailClick('shortcuts', e)}
        class={`${utilBtn} ${workbench.shortcutsDrawerOpen ? utilActive : utilIdle}`}
      >
        <Keyboard class="h-3.5 w-3.5" />
      </button>

      <button
        type="button"
        title={workbench.t.header.settingsTitle}
        aria-label={workbench.t.header.settingsBtn}
        aria-expanded={workbench.settingsOpen}
        onpointerdown={(e) => onRailPointerDown('settings', e)}
        onclick={(e) => onRailClick('settings', e)}
        class={`${utilBtn} ${workbench.settingsOpen ? utilActive : utilIdle}`}
      >
        <SlidersHorizontal class="h-3.5 w-3.5" />
      </button>

      {#if workbench.authRequired}
        <button
          type="button"
          title={workbench.t.auth.lockTitle}
          aria-label={workbench.t.auth.lockBtn}
          onclick={() => void workbench.logout()}
          class={`${utilBtn} ${utilIdle}`}
        >
          <Lock class="h-3.5 w-3.5" />
        </button>
      {/if}
    </div>
  </nav>

  <!-- Silky GPU Floating Flyout Popover (Zero Layout Reflow) -->
  {#if flyoutMounted && flyoutPanel !== null}
    <div
      bind:this={flyoutEl}
      role="dialog"
      tabindex="-1"
      aria-label={flyoutPanel === 'time' ? s.timeSectionTitle : s.sourcesSectionTitle}
      data-open={flyoutEntered ? 'true' : 'false'}
      ontransitionend={(e) => {
        if (e.target === flyoutEl && e.propertyName === 'transform' && workbench.railFlyout === null) {
          finishFlyoutExit();
        }
      }}
      onkeydown={(e) => {
        if (flyoutPanel === 'sources') {
          sourcePickerRef?.handleKeydown(e);
        }
      }}
      class={`left-flyout absolute left-12 top-2 z-40 ml-1.5 w-[288px] overflow-hidden rounded-xl border border-border/75 bg-popover shadow-2xl select-none ${
        workbench.railFlyout !== null ? 'pointer-events-auto' : 'pointer-events-none'
      }`}
    >
      {#if flyoutPanel === 'time'}
        <TimeRangePicker
          bind:this={timePickerRef}
          value={workbench.scope.timePreset}
          onClose={() => {
            workbench.closeRailFlyout();
            onFocusMainInput?.();
          }}
          onApply={(spec) => {
            workbench.setScopeTime(spec);
            workbench.closeRailFlyout();
            onFocusMainInput?.();
          }}
          onCommitSilent={(spec) => workbench.setScopeTime(spec)}
          {onFocusMainInput}
        />
      {:else}
        <div class="flex max-h-[min(70vh,460px)] min-h-[200px] flex-col">
          {@render sourcesHeader(false)}
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

<style>
  .left-flyout {
    transform: translate3d(-12px, 0, 0) scale(0.985);
    opacity: 0;
    transform-origin: left top;
    will-change: transform, opacity;
    transition:
      transform var(--motion-sheet, 150ms) cubic-bezier(0.4, 0, 1, 1),
      opacity var(--motion-sheet, 150ms) cubic-bezier(0.4, 0, 1, 1);
  }
  .left-flyout[data-open='true'] {
    transform: translate3d(0, 0, 0) scale(1);
    opacity: 1;
    transition:
      transform var(--motion-drawer-in, 183ms) cubic-bezier(0.22, 1, 0.36, 1),
      opacity var(--motion-drawer-in, 183ms) cubic-bezier(0.22, 1, 0.36, 1);
  }

  .left-scrim {
    opacity: 0;
    transition: opacity var(--motion-sheet, 150ms) cubic-bezier(0.4, 0, 1, 1);
  }
  .left-scrim[data-open='true'] {
    opacity: 1;
    transition: opacity var(--motion-drawer-in, 183ms) cubic-bezier(0.22, 1, 0.36, 1);
  }

  .left-mobile-drawer {
    transform: translate3d(-100%, 0, 0);
    will-change: transform;
    transition: transform var(--motion-sheet, 150ms) cubic-bezier(0.4, 0, 1, 1);
  }
  .left-mobile-drawer[data-open='true'] {
    transform: translate3d(0, 0, 0);
    transition: transform var(--motion-drawer-in, 183ms) cubic-bezier(0.22, 1, 0.36, 1);
  }

  @media (prefers-reduced-motion: reduce) {
    .left-flyout,
    .left-scrim,
    .left-mobile-drawer {
      transition-duration: 1ms !important;
    }
  }
</style>
