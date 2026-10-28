<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { Keyboard, Moon, SlidersHorizontal, Sun } from 'lucide-svelte';

  const hasMissingSource = $derived(
    workbench.sources.length === 0 ||
      workbench.sources.some((s) => s.enabled && !s.exists)
  );

  // Smooth 120Hz count-up animation from 0 on initial entry, and on subsequent search increments
  let displayedCount = $state(0);
  let isAnimatingCount = $state(false);
  let hasPlayedInitialIntro = false;
  let lastAnimatedValue = 0;

  $effect(() => {
    const target = workbench.searchCount;
    if (target <= 0) {
      displayedCount = 0;
      lastAnimatedValue = 0;
      return;
    }

    const startValue = hasPlayedInitialIntro ? lastAnimatedValue : 0;
    if (startValue === target) return;

    const duration = hasPlayedInitialIntro ? 380 : 950;
    hasPlayedInitialIntro = true;
    isAnimatingCount = true;

    let rafId = 0;
    const startTime = performance.now();
    const delta = target - startValue;

    const step = (now: number) => {
      const elapsed = now - startTime;
      const progress = Math.min(1, elapsed / duration);
      // easeOutExpo: fast initial surge, silky deceleration into final digits
      const eased = progress === 1 ? 1 : 1 - Math.pow(2, -10 * progress);
      const nextVal = Math.round(startValue + delta * eased);
      lastAnimatedValue = nextVal;
      displayedCount = nextVal;

      if (progress < 1) {
        rafId = requestAnimationFrame(step);
      } else {
        lastAnimatedValue = target;
        displayedCount = target;
        isAnimatingCount = false;
      }
    };

    rafId = requestAnimationFrame(step);
    return () => {
      if (rafId) cancelAnimationFrame(rafId);
    };
  });
</script>

<header
  class="flex h-11 shrink-0 items-center justify-between bg-background px-6 select-none"
>
  <!-- Left: Borderless Dark Site-Wide Search Telemetry Counter -->
  <div class="flex items-center gap-3 min-w-0">
    <div
      class="inline-flex items-baseline gap-1.5"
      title={workbench.t.header.connected}
    >
      <span
        class={`font-mono text-[13px] font-medium tabular-nums tracking-tight transition-colors duration-300 ${
          isAnimatingCount ? 'text-foreground' : 'text-foreground/75'
        }`}
      >
        {displayedCount.toLocaleString()}
      </span>
      <span class="text-[11.5px] font-normal tracking-wide text-muted-foreground/55">
        {workbench.locale === 'zh' ? '次搜索' : 'searches'}
      </span>
    </div>

    {#if workbench.wsStatus !== 'connected'}
      <button
        type="button"
        onclick={() => workbench.connectWebSocket()}
        class="inline-flex items-center gap-1.5 font-mono text-[11px] text-muted-foreground/70 hover:text-foreground transition-colors cursor-pointer"
        title={workbench.t.header.reconnectTitle}
      >
        <span class="h-1.5 w-1.5 rounded-full bg-amber-400/90 animate-pulse"></span>
        <span>{workbench.t.header.reconnect}</span>
      </button>
    {/if}
  </div>

  <!-- Right: Shortcuts, Theme Toggle & Settings Button -->
  <div class="flex items-center gap-1">
    <button
      type="button"
      title={workbench.t.header.shortcutsTitle}
      onclick={() => {
        workbench.settingsOpen = false;
        workbench.shortcutsModalOpen = !workbench.shortcutsModalOpen;
      }}
      class={`flex h-7 w-7 items-center justify-center rounded-md transition-colors cursor-pointer ${
        workbench.shortcutsModalOpen
          ? 'text-foreground bg-secondary/80'
          : 'text-muted-foreground/75 hover:text-foreground hover:bg-secondary/60'
      }`}
    >
      <Keyboard class="h-3.5 w-3.5" />
    </button>

    <button
      type="button"
      title={workbench.darkMode ? workbench.t.header.lightMode : workbench.t.header.darkMode}
      onclick={() => workbench.toggleTheme()}
      class="flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:text-foreground hover:bg-secondary/60 transition-colors cursor-pointer"
    >
      {#if workbench.darkMode}
        <Sun class="h-3.5 w-3.5" />
      {:else}
        <Moon class="h-3.5 w-3.5" />
      {/if}
    </button>

    <button
      type="button"
      title={workbench.t.header.settingsTitle}
      onclick={() => {
        workbench.shortcutsModalOpen = false;
        workbench.settingsOpen = !workbench.settingsOpen;
      }}
      class={`relative flex h-7 w-7 items-center justify-center rounded-md transition-colors cursor-pointer ${
        workbench.settingsOpen
          ? 'text-foreground bg-secondary/80'
          : 'text-muted-foreground/75 hover:text-foreground hover:bg-secondary/60'
      }`}
    >
      <SlidersHorizontal class="h-3.5 w-3.5" />
      {#if hasMissingSource}
        <span class="absolute right-1 top-1 h-1.5 w-1.5 rounded-full bg-amber-400"></span>
      {/if}
    </button>
  </div>
</header>
