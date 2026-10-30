<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { Database, SlidersHorizontal, Wifi, WifiOff } from 'lucide-svelte';

  const hasMissingSource = $derived(
    workbench.sources.length === 0 ||
      workbench.sources.some((s) => s.enabled && !s.exists)
  );

  const iconBtn =
    'touch-target relative flex h-8 w-8 items-center justify-center rounded-md transition-colors cursor-pointer';
</script>

<header
  class="pt-safe flex shrink-0 items-center justify-between bg-background px-3 md:px-6 select-none"
>
  <div class="flex h-11 items-center w-full justify-between">
    <!-- Left: connection status -->
    {#if workbench.wsStatus === 'connected'}
      <span
        class="flex h-8 w-8 items-center justify-center text-muted-foreground/70"
        title={workbench.t.header.connected}
      >
        <Wifi class="h-3.5 w-3.5" />
      </span>
    {:else}
      <button
        type="button"
        onclick={() => workbench.connectWebSocket()}
        class={`${iconBtn} text-status hover:bg-secondary/60`}
        title={workbench.t.header.reconnectTitle}
        aria-label={workbench.t.header.reconnect}
      >
        <WifiOff class="h-3.5 w-3.5 animate-pulse" />
      </button>
    {/if}

    <!-- Right: data sources & settings -->
    <div class="flex items-center gap-1">
      <button
        type="button"
        title={workbench.t.header.sourcesTriggerTitle}
        aria-label={workbench.t.header.manageBtn}
        onclick={() =>
          workbench.settingsOpen && workbench.settingsTab === 'sources'
            ? (workbench.settingsOpen = false)
            : workbench.openSettings('sources')}
        class={`${iconBtn} ${
          workbench.settingsOpen && workbench.settingsTab === 'sources'
            ? 'text-foreground bg-secondary/80'
            : 'text-muted-foreground/75 hover:text-foreground hover:bg-secondary/60'
        }`}
      >
        <Database class="h-3.5 w-3.5" />
        {#if hasMissingSource}
          <span class="absolute right-1 top-1 h-1.5 w-1.5 rounded-full bg-status"></span>
        {/if}
      </button>

      <button
        type="button"
        title={workbench.t.header.settingsTitle}
        aria-label={workbench.t.header.settingsTitle}
        onclick={() =>
          workbench.settingsOpen && workbench.settingsTab !== 'sources'
            ? (workbench.settingsOpen = false)
            : workbench.openSettings('general')}
        class={`${iconBtn} ${
          workbench.settingsOpen && workbench.settingsTab !== 'sources'
            ? 'text-foreground bg-secondary/80'
            : 'text-muted-foreground/75 hover:text-foreground hover:bg-secondary/60'
        }`}
      >
        <SlidersHorizontal class="h-3.5 w-3.5" />
      </button>
    </div>
  </div>
</header>
