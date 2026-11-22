<script lang="ts">
  import { flushSync } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import {
    Blocks,
    Database,
    Keyboard,
    Lock,
    PanelLeft,
    SlidersHorizontal,
  } from 'lucide-svelte';

  type HeaderTarget = 'sidebar' | 'sources' | 'mcp' | 'shortcuts' | 'settings';

  const hasMissingSource = $derived(
    workbench.sourcesLoaded &&
      (workbench.sources.length === 0 ||
        workbench.sources.some((s) => s.enabled && !s.exists))
  );
  const sidebarTitle = $derived(
    workbench.isCompact
      ? workbench.t.header.toggleSidebar
      : workbench.leftSidebarOpen
        ? workbench.t.scopeBar.unpinSidebar
        : workbench.t.scopeBar.pinSidebar
  );

  const iconBtn =
    'touch-target relative flex h-8 w-8 items-center justify-center rounded-md active:bg-secondary/80 cursor-pointer';
  const activeBtn = 'bg-secondary/85 text-foreground ring-1 ring-inset ring-border/60';
  const idleBtn = 'text-muted-foreground/75 hover:text-foreground hover:bg-secondary/60';

  let btnPickedOnDown: HeaderTarget | null = null;

  function togglePanel(target: HeaderTarget) {
    if (target === 'sidebar') {
      workbench.toggleScopeSidebar();
    } else if (target === 'sources') {
      if (workbench.sourcesDrawerOpen) workbench.closeRightDrawer();
      else workbench.openSourcesDrawer(false);
    } else if (target === 'mcp') {
      if (workbench.mcpDrawerOpen) workbench.closeRightDrawer();
      else workbench.openMcpDrawer();
    } else if (target === 'shortcuts') {
      if (workbench.shortcutsDrawerOpen) workbench.closeRightDrawer();
      else workbench.openShortcutsDrawer();
    } else {
      if (workbench.settingsOpen) workbench.closeRightDrawer();
      else workbench.openSettingsDrawer();
    }
  }

  function onBtnPointerDown(target: HeaderTarget, e: PointerEvent) {
    if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
      btnPickedOnDown = target;
      flushSync(() => togglePanel(target));
    }
  }

  function onBtnClick(target: HeaderTarget, e: MouseEvent) {
    if (btnPickedOnDown === target && e.detail > 0) {
      btnPickedOnDown = null;
      return;
    }
    btnPickedOnDown = null;
    flushSync(() => togglePanel(target));
  }
</script>

<header
  class="pt-safe flex shrink-0 items-center justify-between bg-background pl-2 pr-3 md:pl-2 md:pr-6 select-none"
>
  <div class="flex h-11 items-center w-full justify-between">
    <!-- Left: scope sidebar toggle (aligned over the 48px icon rail on desktop) -->
    <button
      type="button"
      title={sidebarTitle}
      aria-label={sidebarTitle}
      aria-expanded={workbench.scopeSidebarOpen}
      onpointerdown={(e) => onBtnPointerDown('sidebar', e)}
      onclick={(e) => onBtnClick('sidebar', e)}
      class={`${iconBtn} ${workbench.scopeSidebarOpen ? activeBtn : idleBtn}`}
    >
      <PanelLeft class="h-3.5 w-3.5" />
      {#if workbench.isCompact && !workbench.scopeSidebarOpen && workbench.hasActiveScope}
        <span class="absolute right-1 top-1 h-1.5 w-1.5 rounded-full bg-primary"></span>
      {/if}
    </button>

    <!-- Right: standalone top-level menus (数据源 · MCP · 快捷键说明 · 设置) -->
    <div class="flex items-center gap-1">
      <button
        type="button"
        title={workbench.t.header.sourcesTriggerTitle}
        aria-label={workbench.t.header.manageBtn}
        aria-expanded={workbench.sourcesDrawerOpen}
        onpointerdown={(e) => onBtnPointerDown('sources', e)}
        onclick={(e) => onBtnClick('sources', e)}
        class={`${iconBtn} ${workbench.sourcesDrawerOpen ? activeBtn : idleBtn}`}
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
        onpointerdown={(e) => onBtnPointerDown('mcp', e)}
        onclick={(e) => onBtnClick('mcp', e)}
        class={`${iconBtn} ${workbench.mcpDrawerOpen ? activeBtn : idleBtn}`}
      >
        <Blocks class="h-3.5 w-3.5" />
        {#if workbench.mcpLoaded && workbench.mcpEnabled}
          <span
            class="absolute right-1 top-1 h-1.5 w-1.5 rounded-full bg-primary/85"
          ></span>
        {/if}
      </button>

      <button
        type="button"
        title={workbench.t.header.shortcutsTitle}
        aria-label={workbench.t.header.shortcutsBtn}
        aria-expanded={workbench.shortcutsDrawerOpen}
        onpointerdown={(e) => onBtnPointerDown('shortcuts', e)}
        onclick={(e) => onBtnClick('shortcuts', e)}
        class={`${iconBtn} ${workbench.shortcutsDrawerOpen ? activeBtn : idleBtn}`}
      >
        <Keyboard class="h-3.5 w-3.5" />
      </button>

      <button
        type="button"
        title={workbench.t.header.settingsTitle}
        aria-label={workbench.t.header.settingsBtn}
        aria-expanded={workbench.settingsOpen}
        onpointerdown={(e) => onBtnPointerDown('settings', e)}
        onclick={(e) => onBtnClick('settings', e)}
        class={`${iconBtn} ${workbench.settingsOpen ? activeBtn : idleBtn}`}
      >
        <SlidersHorizontal class="h-3.5 w-3.5" />
      </button>

      {#if workbench.authRequired}
        <button
          type="button"
          title={workbench.t.auth.lockTitle}
          aria-label={workbench.t.auth.lockBtn}
          onclick={() => void workbench.logout()}
          class={`${iconBtn} ${idleBtn}`}
        >
          <Lock class="h-3.5 w-3.5" />
        </button>
      {/if}
    </div>
  </div>
</header>
