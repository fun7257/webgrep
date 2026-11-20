<script lang="ts">
  import type { Snippet } from 'svelte';
  import { RefreshCw } from 'lucide-svelte';

  interface Props {
    totalHeight: number;
    offsetY: number;
    offsets: Float64Array;
    activeVirtualIdx: number;
    scrollResetKey: number | string;
    scrollToActiveTick: number;
    codeFontSize: number;
    canPullRefresh: boolean;
    scrollTop?: number;
    viewportHeight?: number;
    scrollerWidth?: number;
    onRefresh?: () => void;
    children: Snippet;
  }

  let {
    totalHeight,
    offsetY,
    offsets,
    activeVirtualIdx,
    scrollResetKey,
    scrollToActiveTick,
    codeFontSize,
    canPullRefresh,
    scrollTop = $bindable(0),
    viewportHeight = $bindable(720),
    scrollerWidth = $bindable(960),
    onRefresh,
    children,
  }: Props = $props();

  let scrollerEl = $state<HTMLDivElement | null>(null);
  let lastScrollTick = 0;

  // Reset scroll to top on new search
  $effect(() => {
    void scrollResetKey;
    lastScrollTick = 0;
    scrollTop = 0;
    if (scrollerEl) {
      scrollerEl.scrollTop = 0;
    }
  });

  // O(1) auto-scroll when navigating hits via keyboard (Up/Down or j/k)
  $effect(() => {
    const tick = scrollToActiveTick;
    if (tick === 0 || tick === lastScrollTick || !scrollerEl) return;
    lastScrollTick = tick;
    if (activeVirtualIdx < 0 || activeVirtualIdx + 1 >= offsets.length) return;

    const targetY = offsets[activeVirtualIdx];
    const targetBottom = offsets[activeVirtualIdx + 1];
    const viewTop = scrollerEl.scrollTop;
    const viewBottom = viewTop + scrollerEl.clientHeight;
    if (targetY < viewTop + 36) {
      scrollerEl.scrollTop = Math.max(0, targetY - 36);
    } else if (targetBottom > viewBottom - 36) {
      scrollerEl.scrollTop = targetBottom - scrollerEl.clientHeight + 36;
    }
  });

  let scrollRaf: number | null = null;
  let pendingScrollTop = 0;
  let pendingViewportHeight = 720;

  $effect(() => {
    return () => {
      if (scrollRaf !== null) {
        cancelAnimationFrame(scrollRaf);
        scrollRaf = null;
      }
    };
  });

  function handleScroll(e: Event) {
    const el = e.currentTarget as HTMLDivElement;
    pendingScrollTop = el.scrollTop;
    pendingViewportHeight = el.clientHeight;
    if (scrollRaf !== null) return;
    scrollRaf = requestAnimationFrame(() => {
      scrollRaf = null;
      scrollTop = pendingScrollTop;
      viewportHeight = pendingViewportHeight;
    });
  }

  // Pull-down at scrollTop 0 re-runs the current search (touch only)
  const PULL_THRESHOLD = 72;
  let pullDist = $state(0);
  let pullStartY: number | null = null;

  function onTouchStart(e: TouchEvent) {
    if (!scrollerEl || scrollerEl.scrollTop > 0 || e.touches.length !== 1) return;
    pullStartY = e.touches[0].clientY;
  }

  function onTouchMove(e: TouchEvent) {
    if (pullStartY === null) return;
    if (scrollerEl && scrollerEl.scrollTop > 0) {
      pullStartY = null;
      pullDist = 0;
      return;
    }
    const dy = e.touches[0].clientY - pullStartY;
    pullDist = dy > 0 ? Math.min(dy * 0.5, PULL_THRESHOLD * 1.4) : 0;
  }

  function onTouchEnd() {
    if (pullStartY === null) return;
    const fire = pullDist >= PULL_THRESHOLD / 2;
    pullStartY = null;
    pullDist = 0;
    if (fire && canPullRefresh) {
      onRefresh?.();
    }
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  bind:this={scrollerEl}
  bind:clientHeight={viewportHeight}
  bind:clientWidth={scrollerWidth}
  onscroll={handleScroll}
  ontouchstart={onTouchStart}
  ontouchmove={onTouchMove}
  ontouchend={onTouchEnd}
  ontouchcancel={onTouchEnd}
  class="relative flex-1 min-h-0 overflow-y-auto overscroll-contain bg-background"
>
  {#if pullDist > 4}
    <div
      class="pointer-events-none absolute inset-x-0 top-0 z-10 flex justify-center"
      style={`transform: translate3d(0, ${pullDist - 28}px, 0); opacity: ${Math.min(1, pullDist / 40)}`}
    >
      <RefreshCw class="h-4 w-4 text-muted-foreground" />
    </div>
  {/if}

  <div class="px-3 md:px-6 pb-8" style={`font-size: ${codeFontSize}px`}>
    <div class="relative w-full" style={`height: ${totalHeight}px`}>
      <div
        class="virtual-slice-gpu absolute left-0 right-0 top-0"
        style={`transform: translate3d(0, ${offsetY}px, 0)`}
      >
        {@render children()}
      </div>
    </div>
  </div>
</div>
