<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import GeneralPane from './settings/GeneralPane.svelte';
  import ShortcutsPane from './settings/ShortcutsPane.svelte';
  import SourcesPane from './settings/SourcesPane.svelte';
  import { FolderGit2, Keyboard, RotateCcw, SlidersHorizontal, X } from 'lucide-svelte';

  type TabId = 'general' | 'sources' | 'shortcuts';

  const tabs = $derived([
    { id: 'general' as const, icon: SlidersHorizontal, title: workbench.t.settings.tabGeneral },
    { id: 'sources' as const, icon: FolderGit2, title: workbench.t.settings.tabSources },
    { id: 'shortcuts' as const, icon: Keyboard, title: workbench.t.settings.tabShortcuts },
  ]);

  const activeTitle = $derived(tabs.find((tab) => tab.id === workbench.settingsTab)?.title);

  function close() {
    workbench.settingsOpen = false;
    workbench.sourceAddOpen = false;
  }

  function switchTab(tab: TabId) {
    workbench.settingsTab = tab;
  }

  // Mobile bottom sheet: drag the handle down to dismiss.
  let dragY = $state(0);
  let dragStart: number | null = null;

  function onHandleDown(e: PointerEvent) {
    dragStart = e.clientY;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }

  function onHandleMove(e: PointerEvent) {
    if (dragStart === null) return;
    dragY = Math.max(0, e.clientY - dragStart);
  }

  function onHandleUp() {
    if (dragStart === null) return;
    const shouldClose = dragY > 96;
    dragStart = null;
    dragY = 0;
    if (shouldClose) close();
  }
</script>

{#if workbench.settingsOpen}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    onclick={close}
    onkeydown={(e) => {
      if (e.key === 'Escape') close();
    }}
    class="fixed inset-0 z-50 flex items-end md:items-center justify-center bg-black/60 backdrop-blur-xs p-0 md:p-4 select-none"
  >
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div
      onclick={(e) => e.stopPropagation()}
      style={dragY > 0 ? `transform: translate3d(0, ${dragY}px, 0); transition: none` : undefined}
      class="pb-safe flex h-[600px] md:h-[540px] max-h-[88dvh] w-full max-w-[640px] flex-col md:flex-row overflow-hidden rounded-t-2xl md:rounded-2xl border border-border/80 bg-card shadow-2xl transition-transform"
    >
      <!-- Drag handle (mobile only) -->
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

      <!-- Icon tab rail: horizontal on mobile, vertical on desktop -->
      <nav
        class="flex shrink-0 flex-row md:flex-col items-center gap-1 border-b md:border-b-0 md:border-r border-border/60 bg-secondary/20 px-2 py-1.5 md:p-2"
      >
        {#each tabs as tab (tab.id)}
          {@const Icon = tab.icon}
          <button
            type="button"
            onclick={() => switchTab(tab.id)}
            title={tab.title}
            aria-label={tab.title}
            aria-current={workbench.settingsTab === tab.id}
            class={`touch-target flex h-10 w-10 items-center justify-center rounded-lg transition-colors cursor-pointer ${
              workbench.settingsTab === tab.id
                ? 'bg-secondary text-foreground'
                : 'text-muted-foreground hover:bg-secondary/50 hover:text-foreground'
            }`}
          >
            <Icon class="h-4 w-4" />
          </button>
        {/each}
      </nav>

      <section class="flex min-h-0 min-w-0 flex-1 flex-col bg-card">
        <div class="flex h-12 shrink-0 items-center justify-between border-b border-border/50 px-4 md:px-6">
          <div class="truncate text-[14px] font-semibold text-foreground">{activeTitle}</div>
          <div class="flex items-center gap-1">
            {#if workbench.settingsTab === 'general'}
              <button
                type="button"
                title={workbench.t.settings.resetTitle}
                aria-label={workbench.t.settings.resetTitle}
                onclick={() => workbench.resetSettings()}
                class="touch-target flex h-8 w-8 items-center justify-center rounded-lg text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
              >
                <RotateCcw class="h-3.5 w-3.5" />
              </button>
            {/if}
            <button
              type="button"
              title={workbench.t.settings.closeTitle}
              aria-label={workbench.t.settings.closeTitle}
              onclick={close}
              class="touch-target flex h-8 w-8 items-center justify-center rounded-lg text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
            >
              <X class="h-4 w-4" />
            </button>
          </div>
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 md:px-6 py-4 text-[13px]">
          {#if workbench.settingsTab === 'general'}
            <GeneralPane />
          {:else if workbench.settingsTab === 'sources'}
            <SourcesPane />
          {:else}
            <ShortcutsPane />
          {/if}
        </div>
      </section>
    </div>
  </div>
{/if}
