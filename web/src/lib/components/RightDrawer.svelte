<script lang="ts">
  import { onDestroy } from 'svelte';
  import { workbench, type DrawerPanelId } from '$lib/state.svelte';
  import SettingsPopover from './SettingsPopover.svelte';

  const isOpen = $derived(workbench.rightDrawerOpen);

  let mounted = $state(false);
  let entered = $state(false);
  let activeMode = $state<DrawerPanelId | null>(null);
  let panelEl = $state<HTMLDivElement | null>(null);
  let exitTimer: ReturnType<typeof setTimeout> | null = null;
  let previousFocus: HTMLElement | null = null;

  let dragStartY: number | null = null;
  let dragY = $state(0);
  let dragging = $state(false);

  const drawerLabel = $derived.by(() => {
    switch (activeMode) {
      case 'sources':
        return workbench.t.settings.panelSourcesTitle;
      case 'mcp':
        return workbench.t.settings.panelMcpTitle;
      case 'shortcuts':
        return workbench.t.settings.panelShortcutsTitle;
      case 'context':
        return workbench.t.inspector.contextDrawerTitle;
      case 'settings':
      default:
        return workbench.t.settings.panelSettingsTitle;
    }
  });

  function finishExit() {
    if (exitTimer !== null) {
      clearTimeout(exitTimer);
      exitTimer = null;
    }
    if (!isOpen) {
      mounted = false;
      activeMode = null;
      dragY = 0;
      dragging = false;
    }
  }

  function restoreFocus() {
    const target = previousFocus;
    previousFocus = null;
    if (target && target.isConnected) {
      target.focus({ preventScroll: true });
    }
  }

  $effect(() => {
    if (isOpen && workbench.drawerPanel !== null) {
      activeMode = workbench.drawerPanel;
      if (exitTimer !== null) {
        clearTimeout(exitTimer);
        exitTimer = null;
      }
      dragY = 0;
      dragging = false;

      if (!mounted) {
        if (typeof document !== 'undefined' && document.activeElement instanceof HTMLElement) {
          previousFocus = document.activeElement;
        }
        entered = false;
        mounted = true;
        return;
      }

      if (!entered && panelEl) {
        // Force style commit at current transform so reversal/entry animates cleanly on Frame 1
        void panelEl.getBoundingClientRect();
        entered = true;
        if (typeof document !== 'undefined' && !panelEl.contains(document.activeElement)) {
          panelEl.focus({ preventScroll: true });
        }
      }
      return;
    }

    if (mounted) {
      entered = false;
      restoreFocus();
      if (exitTimer === null) {
        exitTimer = setTimeout(finishExit, workbench.frameProfile.sheetMotionMs + 60);
      }
    }
  });

  onDestroy(() => {
    if (exitTimer !== null) {
      clearTimeout(exitTimer);
      exitTimer = null;
    }
  });

  function handleTransitionEnd(e: TransitionEvent) {
    if (e.target !== panelEl || e.propertyName !== 'transform') return;
    if (!isOpen) {
      finishExit();
    }
  }

  function handleScrimPointerDown(e: PointerEvent) {
    if (e.pointerType === 'mouse' && e.button === 0) {
      e.preventDefault();
      e.stopPropagation();
      workbench.closeRightDrawer();
    }
  }

  function handleScrimClick(e: MouseEvent) {
    e.stopPropagation();
    if (isOpen) {
      workbench.closeRightDrawer();
    }
  }

  function onHandleDown(e: PointerEvent) {
    dragStartY = e.clientY;
    dragging = true;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }

  function onHandleMove(e: PointerEvent) {
    if (dragStartY === null) return;
    dragY = Math.max(0, e.clientY - dragStartY);
  }

  function onHandleUp() {
    if (dragStartY === null) return;
    const shouldClose = dragY > 96;
    dragStartY = null;
    dragging = false;
    dragY = 0;
    if (shouldClose) {
      entered = false;
      workbench.closeRightDrawer();
    }
  }
</script>

{#if mounted && activeMode}
  {@const isContextMode = activeMode === 'context'}
  {@const desktopSide = isContextMode ? 'right' : 'left'}
  <div
    class={`drawer-overlay-root fixed md:absolute inset-0 z-50 md:z-30 flex items-end md:items-stretch overflow-clip ${
      desktopSide === 'left' ? 'md:left-12 md:justify-start' : 'md:justify-end'
    } ${isOpen ? 'pointer-events-auto' : 'pointer-events-none'}`}
  >
    <!-- Mobile dimming scrim; optically transparent on desktop -->
    <div
      class="drawer-scrim absolute inset-0 bg-black/25 dark:bg-black/45 md:bg-transparent dark:md:bg-transparent"
      data-open={entered ? 'true' : 'false'}
      aria-hidden="true"
      onpointerdown={handleScrimPointerDown}
      onclick={handleScrimClick}
    ></div>

    <div
      bind:this={panelEl}
      role="dialog"
      aria-modal="false"
      aria-label={drawerLabel}
      tabindex={-1}
      ontransitionend={handleTransitionEnd}
      class={`drawer-panel pb-safe md:pb-0 relative z-10 flex w-full focus:outline-none ${
        isContextMode
          ? 'h-[84dvh] max-h-[88dvh] md:h-full md:max-h-none md:w-[560px] lg:w-[680px] xl:w-[760px] rounded-t-2xl md:rounded-tr-none md:rounded-tl-xl border-t md:border-t-0 md:border-l border-border/65 shadow-[0_-10px_28px_-10px_hsl(0_0%_0%/0.18)] md:shadow-[-10px_4px_28px_-12px_hsl(215_25%_12%/0.09)] dark:md:shadow-[-14px_4px_36px_-10px_hsl(0_0%_0%/0.55)]'
          : 'max-h-[82dvh] h-[78dvh] md:h-full md:max-h-none md:w-[440px] lg:w-[460px] rounded-t-2xl md:rounded-tl-none md:rounded-r-xl border-t md:border-t-0 md:border-r border-border/65 shadow-[0_-10px_28px_-10px_hsl(0_0%_0%/0.18)] md:shadow-[10px_4px_28px_-12px_hsl(215_25%_12%/0.09)] dark:md:shadow-[14px_4px_36px_-10px_hsl(0_0%_0%/0.55)]'
      } flex-col overflow-hidden bg-background text-foreground`}
      data-open={entered ? 'true' : 'false'}
      data-side={desktopSide}
      data-dragging={dragging ? 'true' : 'false'}
      style:transform={dragging || dragY > 0 ? `translate3d(0, ${dragY}px, 0)` : undefined}
    >
      <!-- Mobile pull-to-dismiss handle -->
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        onpointerdown={onHandleDown}
        onpointermove={onHandleMove}
        onpointerup={onHandleUp}
        onpointercancel={onHandleUp}
        style="touch-action: none"
        class="flex h-5 shrink-0 cursor-grab items-center justify-center md:hidden"
      >
        <span class="h-1 w-9 rounded-full bg-border"></span>
      </div>

      {#key activeMode}
        <SettingsPopover mode={activeMode} />
      {/key}
    </div>
  </div>
{/if}

<style>
  .drawer-overlay-root {
    isolation: isolate;
    contain: layout paint;
  }

  .drawer-scrim {
    opacity: 0;
    transition: opacity var(--motion-sheet, 150ms) cubic-bezier(0.4, 0, 1, 1);
  }
  .drawer-scrim[data-open='true'] {
    opacity: 1;
    transition: opacity var(--motion-drawer-in, 183ms) cubic-bezier(0.22, 1, 0.36, 1);
  }

  .drawer-panel {
    transform: translate3d(0, 100%, 0);
    will-change: transform;
    transition: transform var(--motion-sheet, 150ms) cubic-bezier(0.4, 0, 1, 1);
  }
  .drawer-panel[data-open='true'] {
    transform: translate3d(0, 0, 0);
    transition: transform var(--motion-drawer-in, 183ms) cubic-bezier(0.22, 1, 0.36, 1);
  }
  @media (min-width: 768px) {
    .drawer-panel[data-side='right'] {
      transform: translate3d(100%, 0, 0);
    }
    .drawer-panel[data-side='left'] {
      transform: translate3d(-100%, 0, 0);
    }
    .drawer-panel[data-open='true'] {
      transform: translate3d(0, 0, 0);
    }
  }
  .drawer-panel[data-dragging='true'] {
    transition: none;
  }

  @media (prefers-reduced-motion: reduce) {
    .drawer-scrim,
    .drawer-panel {
      transition-duration: 1ms !important;
    }
  }
</style>
