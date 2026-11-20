<script lang="ts">
  import type { LogLevel, LogStreamStats } from '$lib/adapters/index.ts';
  import type { AdapterHost } from '../types.ts';

  interface Props {
    stats: LogStreamStats;
    host: AdapterHost;
  }

  let { stats, host }: Props = $props();

  const lv = $derived(host.t.logView);
  const topCats = $derived(stats.topCategories.slice(0, 3));
  const showStrip = $derived(stats.levels.length >= 2 || topCats.length >= 2);

  function levelTextClass(level: LogLevel): string {
    if (level === 'fatal' || level === 'error') {
      return 'text-status font-medium hover:bg-status/10';
    }
    if (level === 'warn') {
      return 'text-status/80 hover:bg-status/10';
    }
    if (level === 'info') {
      return 'text-muted-foreground hover:bg-secondary/60 hover:text-foreground';
    }
    return 'text-muted-foreground/65 hover:bg-secondary/60 hover:text-foreground';
  }

  function applyToken(token: string, altKey: boolean) {
    if (!token) return;
    if (altKey) {
      host.excludeTerm(token);
    } else {
      host.appendTerm(token);
    }
  }
</script>

{#if showStrip}
  <div
    class="flex h-7 shrink-0 items-center justify-between gap-3 overflow-hidden border-b border-border/25 px-3 md:px-6 select-none"
  >
    <div class="flex min-w-0 items-center gap-1 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
      {#each stats.levels as item (item.level)}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={(e) => applyToken(item.filterToken, e.altKey)}
          title={lv.levelFilterTitle(item.badge, item.count)}
          aria-label={lv.levelFilterTitle(item.badge, item.count)}
          class={`touch-target inline-flex h-5 shrink-0 items-center gap-1 rounded px-1.5 font-mono text-[10.5px] leading-none whitespace-nowrap tabular-nums cursor-pointer ${levelTextClass(item.level)}`}
        >
          <span>{item.badge}</span>
          <span class="opacity-70">{item.count.toLocaleString()}</span>
        </button>
      {/each}
    </div>

    {#if topCats.length >= 2}
      <div class="hidden sm:flex min-w-0 items-center justify-end gap-1 overflow-hidden">
        {#each topCats as cat (cat.category)}
          <button
            type="button"
            onmousedown={(e) => e.preventDefault()}
            onclick={(e) => applyToken(cat.filterToken, e.altKey)}
            title={lv.categoryFilterTitle(cat.category, cat.count)}
            aria-label={lv.categoryFilterTitle(cat.category, cat.count)}
            class="touch-target inline-flex h-5 max-w-[152px] shrink-0 items-center gap-1 rounded px-1.5 font-mono text-[10.5px] leading-none text-muted-foreground/70 hover:bg-secondary/60 hover:text-foreground whitespace-nowrap tabular-nums cursor-pointer"
          >
            <span class="truncate">{cat.category}</span>
            <span class="shrink-0 opacity-60">{cat.count.toLocaleString()}</span>
          </button>
        {/each}
      </div>
    {/if}
  </div>
{/if}
