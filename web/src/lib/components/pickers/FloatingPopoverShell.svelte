<script lang="ts">
  import { untrack, type Snippet } from 'svelte';

  interface Props {
    panelEl?: HTMLDivElement | null;
    isCompact: boolean;
    ariaLabel: string;
    desktopWidthClass?: string;
    mobileMaxHeightClass?: string;
    onClose: () => void;
    onKeydown: (e: KeyboardEvent) => void;
    children: Snippet;
    footer?: Snippet;
  }

  let {
    panelEl = $bindable(null),
    isCompact,
    ariaLabel,
    desktopWidthClass = 'w-[376px] max-w-[calc(100vw-1.5rem)]',
    mobileMaxHeightClass = 'max-h-[82dvh]',
    onClose,
    onKeydown,
    children,
    footer,
  }: Props = $props();

  let offsetX = $state<number>(0);
  let maxPanelH = $state<number | null>(null);

  // Mobile bottom-sheet drag-to-dismiss state
  let dragY = $state<number>(0);
  let dragStart: number | null = null;

  function measureViewportBounds() {
    if (isCompact) {
      offsetX = 0;
      maxPanelH = null;
      return;
    }
    const el = panelEl;
    if (!el) return;
    const prevOffset = untrack(() => offsetX);
    const rect = el.getBoundingClientRect();
    const nextMaxPanelH = Math.max(240, Math.floor(window.innerHeight - rect.top - 12));
    const container = (el.closest('main') as HTMLElement | null)?.getBoundingClientRect();
    const minLeft = Math.max(8, container?.left ?? 8);
    const maxRight = Math.min(window.innerWidth - 8, container?.right ?? window.innerWidth - 8);
    const baseLeft = rect.left - prevOffset;
    const baseRight = rect.right - prevOffset;
    let nextOffset = 0;
    if (baseRight > maxRight) {
      nextOffset = Math.max(minLeft - baseLeft, maxRight - baseRight);
    } else if (baseLeft < minLeft) {
      nextOffset = minLeft - baseLeft;
    }
    maxPanelH = nextMaxPanelH;
    offsetX = nextOffset;
  }

  $effect(() => {
    void isCompact;
    void panelEl;
    if (!isCompact) {
      dragStart = null;
      dragY = 0;
    }
    measureViewportBounds();
  });

  function onHandleDown(e: PointerEvent) {
    dragStart = e.clientY;
    dragY = 0;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }

  function onHandleMove(e: PointerEvent) {
    if (dragStart === null) return;
    dragY = Math.max(0, e.clientY - dragStart);
  }

  function onHandleUp() {
    if (dragStart === null) return;
    const shouldClose = dragY > 80;
    dragStart = null;
    dragY = 0;
    if (shouldClose) onClose();
  }
</script>

<svelte:window onresize={measureViewportBounds} />

{#if isCompact}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="fixed inset-0 z-40 bg-black/50 backdrop-blur-[1px]"
    onclick={onClose}
    onkeydown={(e) => {
      if (e.key === 'Escape') onClose();
    }}
  ></div>
  <div
    bind:this={panelEl}
    role="dialog"
    tabindex="-1"
    aria-label={ariaLabel}
    onkeydown={onKeydown}
    style={dragY > 0 ? `transform: translate3d(0, ${dragY}px, 0); transition: none` : undefined}
    class={`pb-safe fixed inset-x-2.5 bottom-3 z-50 mx-auto flex ${mobileMaxHeightClass} max-w-[400px] flex-col overflow-hidden rounded-2xl border border-border/85 bg-popover text-popover-foreground shadow-2xl transition-transform focus:outline-none select-none`}
  >
    <div
      role="presentation"
      onpointerdown={onHandleDown}
      onpointermove={onHandleMove}
      onpointerup={onHandleUp}
      onpointercancel={onHandleUp}
      style="touch-action: none"
      class="flex h-5 shrink-0 cursor-grab items-center justify-center touch-none active:cursor-grabbing"
    >
      <div class="h-1 w-9 rounded-full bg-border"></div>
    </div>
    {@render children()}
    {@render footer?.()}
  </div>
{:else}
  <div
    bind:this={panelEl}
    role="dialog"
    tabindex="-1"
    aria-label={ariaLabel}
    onkeydown={onKeydown}
    style={`${offsetX !== 0 ? `transform: translate3d(${offsetX}px, 0, 0);` : ''}${maxPanelH !== null ? ` max-height: ${maxPanelH}px;` : ''}`}
    class={`absolute left-0 top-full z-50 mt-2.5 flex ${desktopWidthClass} flex-col overflow-hidden rounded-2xl border border-border/85 bg-popover text-popover-foreground shadow-2xl focus:outline-none select-none`}
  >
    {@render children()}
    {@render footer?.()}
  </div>
{/if}
