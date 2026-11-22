<script lang="ts">
  import type { SlidersHorizontal } from 'lucide-svelte';
  import { X } from 'lucide-svelte';
  import type { Snippet } from 'svelte';
  import { workbench } from '$lib/state.svelte';

  interface Props {
    icon: typeof SlidersHorizontal;
    title: string;
    badge?: string;
    badgeTitle?: string;
    headerActions?: Snippet;
    footer?: Snippet;
    children: Snippet;
    bodyEl?: HTMLDivElement | null;
    bodyClass?: string;
    onClose?: () => void;
  }

  let {
    icon: Icon,
    title,
    badge = '',
    badgeTitle = '',
    headerActions,
    footer,
    children,
    bodyEl = $bindable(null),
    bodyClass = 'px-4 md:px-5 py-4 text-[13px]',
    onClose = () => workbench.closeRightDrawer(),
  }: Props = $props();
</script>

<div class="flex min-h-0 flex-1 flex-col select-none bg-background text-foreground">
  <div class="flex h-12 shrink-0 items-center justify-between gap-3 border-b border-border/50 px-4 md:px-5">
    <div class="flex min-w-0 items-center gap-2.5">
      <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-md bg-secondary/70 text-foreground/80">
        <Icon class="h-3.5 w-3.5" />
      </span>
      <h2
        title={title}
        class="truncate text-[13.5px] font-semibold tracking-[-0.01em] text-foreground"
      >
        {title}
      </h2>
      {#if badge}
        <span
          title={badgeTitle || undefined}
          class="shrink-0 rounded-full bg-secondary/75 px-2 py-0.5 font-mono text-[11px] tabular-nums text-muted-foreground"
        >
          {badge}
        </span>
      {/if}
    </div>

    <div class="flex shrink-0 items-center gap-1">
      {@render headerActions?.()}
      <button
        type="button"
        title={workbench.t.settings.closePanelTitle}
        aria-label={workbench.t.settings.closePanelTitle}
        onclick={onClose}
        class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/70 hover:text-foreground active:bg-secondary cursor-pointer"
      >
        <X class="h-4 w-4" />
      </button>
    </div>
  </div>

  <div
    bind:this={bodyEl}
    class={`min-h-0 flex-1 overflow-y-auto overscroll-contain ${bodyClass}`}
  >
    {@render children()}
  </div>

  {@render footer?.()}
</div>
