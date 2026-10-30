<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import type { HitItem } from '$lib/types';
  import {
    getCachedHighlightSegments,
    type HighlightSegment,
  } from '$lib/utils';
  import { AtSign, Ban, Check, Copy, Loader2 } from 'lucide-svelte';

  interface VirtualHitRow {
    idx: number;
    key: string;
    item: HitItem;
    srcName: string;
    /** True when the data source differs from the previous hit (breadcrumb only shown on change). */
    showSrc: boolean;
    fileName: string;
  }

  let copiedIdx = $state<number>(-1);
  let scrollerEl = $state<HTMLDivElement | null>(null);
  let scrollTop = $state<number>(0);
  let viewportHeight = $state<number>(720);
  let scrollerWidth = $state<number>(960);

  const OVERSCAN_PX = 420;
  const BREADCRUMB_H = 22;
  let lockedSearchId = -1;
  let lockedMaxLines = 1;

  // Reset scroll position and monotonic line-height lock when a new search starts
  $effect(() => {
    const id = workbench.currentSearchId;
    if (id !== lockedSearchId) {
      lockedSearchId = id;
      lockedMaxLines = 1;
    }
    scrollTop = 0;
    if (scrollerEl) {
      scrollerEl.scrollTop = 0;
    }
  });

  // O(1) Plan B Compact Snippet Stream Layout (Google / Linear Reading Experience)
  const streamLayout = $derived.by(() => {
    const hits = workbench.flatHits;
    const hLen = hits.length;
    const fontPx = workbench.codeFontSize;
    const lineHeight = Math.round(fontPx * 1.65);
    const baseHitPad = workbench.resultDensity === 'compact' ? 14 : 22;
    const wrapEnabled = workbench.wordWrap;

    if (hLen === 0) {
      return {
        hits,
        rowHeight: baseHitPad + BREADCRUMB_H + lineHeight,
        maxLines: 1,
        totalHeight: 0,
      };
    }

    let maxLines = 1;
    if (wrapEnabled) {
      const availTextWidth = Math.max(300, scrollerWidth - 64);
      const charsPerLine = Math.max(40, Math.floor(availTextWidth / (fontPx * 0.6)));
      let maxSampleLen = 0;
      const sampleCount = Math.min(hLen, 24);
      for (let i = 0; i < sampleCount; i++) {
        const len = hits[i].text.length;
        if (len > maxSampleLen) maxSampleLen = len;
      }
      const rawLines = Math.min(2, Math.max(1, Math.ceil((maxSampleLen || 60) / charsPerLine)));
      if (rawLines > lockedMaxLines) {
        lockedMaxLines = rawLines;
      }
      maxLines = lockedMaxLines;
    }

    const rowHeight = baseHitPad + BREADCRUMB_H + maxLines * lineHeight;
    return {
      hits,
      rowHeight,
      maxLines,
      totalHeight: hLen * rowHeight,
    };
  });

  // O(1) viewport slice: allocates ONLY the ~20 visible snippet rows on screen
  const visibleSlice = $derived.by(() => {
    const { hits, rowHeight, maxLines, totalHeight } = streamLayout;
    const hLen = hits.length;
    if (hLen === 0) {
      return {
        items: [] as VirtualHitRow[],
        offsetY: 0,
        totalHeight: 0,
        rowHeight,
        maxLines,
      };
    }

    const minY = Math.max(0, scrollTop - OVERSCAN_PX);
    const maxY = scrollTop + Math.max(400, viewportHeight) + OVERSCAN_PX;

    const firstIdx = Math.max(0, Math.floor(minY / rowHeight));
    const lastIdx = Math.min(hLen - 1, Math.floor(maxY / rowHeight));

    const items: VirtualHitRow[] = [];
    for (let i = firstIdx; i <= lastIdx; i++) {
      const it = hits[i];
      const slash = it.file.indexOf('/');
      const srcName = slash > 0 ? it.file.slice(0, slash) : '';
      const prevFile = i > 0 ? hits[i - 1].file : '';
      const prevSlash = prevFile.indexOf('/');
      const prevSrc = prevSlash > 0 ? prevFile.slice(0, prevSlash) : '';
      const lastSlash = it.file.lastIndexOf('/');
      items.push({
        showSrc: i === 0 || srcName !== prevSrc,
        fileName: lastSlash >= 0 ? it.file.slice(lastSlash + 1) : it.file,
        idx: i,
        key: `${i}:${it.file}:${it.line}:${it.col}`,
        item: it,
        srcName,
      });
    }

    return {
      items,
      offsetY: firstIdx * rowHeight,
      totalHeight,
      rowHeight,
      maxLines,
    };
  });

  // O(1) auto-scroll when navigating hits via keyboard (↑/↓ or j/k)
  $effect(() => {
    const tick = workbench.scrollToActiveTick;
    if (tick === 0 || !scrollerEl) return;
    const activeIdx = workbench.activeHitIndex;
    if (activeIdx < 0) return;

    const { rowHeight } = streamLayout;
    const targetY = activeIdx * rowHeight;
    const viewTop = scrollerEl.scrollTop;
    const viewBottom = viewTop + scrollerEl.clientHeight;
    if (targetY < viewTop + 36) {
      scrollerEl.scrollTop = Math.max(0, targetY - 36);
    } else if (targetY + rowHeight > viewBottom - 36) {
      scrollerEl.scrollTop = targetY + rowHeight - scrollerEl.clientHeight + 36;
    }
  });

  let scrollRaf: number | null = null;

  function handleScroll(e: Event) {
    const el = e.currentTarget as HTMLDivElement;
    const nextTop = el.scrollTop;
    const nextHeight = el.clientHeight;
    if (scrollRaf !== null) return;
    scrollRaf = requestAnimationFrame(() => {
      scrollRaf = null;
      scrollTop = nextTop;
      viewportHeight = nextHeight;
    });
  }

  // Long-press (touch) opens a bottom action sheet for the row.
  let menuRow = $state.raw<VirtualHitRow | null>(null);
  let pressTimer: ReturnType<typeof setTimeout> | null = null;
  let pressOrigin: { x: number; y: number } | null = null;
  let suppressClick = false;

  function cancelPress() {
    if (pressTimer !== null) clearTimeout(pressTimer);
    pressTimer = null;
    pressOrigin = null;
  }

  function onRowPointerDown(e: PointerEvent, row: VirtualHitRow) {
    if (e.pointerType !== 'touch') return;
    pressOrigin = { x: e.clientX, y: e.clientY };
    pressTimer = setTimeout(() => {
      pressTimer = null;
      suppressClick = true;
      menuRow = row;
      navigator.vibrate?.(8);
    }, 480);
  }

  function onRowPointerMove(e: PointerEvent) {
    if (!pressOrigin) return;
    if (Math.abs(e.clientX - pressOrigin.x) > 8 || Math.abs(e.clientY - pressOrigin.y) > 8) {
      cancelPress();
    }
  }

  function copyFromMenu() {
    if (!menuRow) return;
    navigator.clipboard?.writeText(menuRow.item.text);
    menuRow = null;
  }

  function scopeFromMenu(exclude: boolean) {
    if (!menuRow || !menuRow.srcName) return;
    const token = `${exclude ? '-' : ''}@${menuRow.srcName}`;
    const cur = workbench.pattern.trim();
    workbench.pattern = cur ? `${cur} ${token}` : token;
    workbench.scheduleSearch(true);
    menuRow = null;
  }

  function copyLineText(e: MouseEvent, idx: number, text: string) {
    e.stopPropagation();
    navigator.clipboard?.writeText(text);
    copiedIdx = idx;
    setTimeout(() => {
      if (copiedIdx === idx) copiedIdx = -1;
    }, 1400);
  }

  const isCaseInsensitive = $derived(workbench.caseMode !== 'sensitive');
  const isRegexMode = $derived(workbench.mode === 'regex');
  const segmentCacheKey = $derived(
    `${workbench.mode}:${workbench.caseMode}:${workbench.primaryPattern}\u0001${workbench.contains.join('\u0001')}`
  );
</script>

{#snippet renderSegments(segments: HighlightSegment[])}
  {#each segments as seg}
    {#if seg.kind === 'primary'}
      <mark class="match-span-primary">{seg.text}</mark>
    {:else if seg.kind === 'contains-0'}
      <mark class="match-span-contains-0">{seg.text}</mark>
    {:else if seg.kind === 'contains-1'}
      <mark class="match-span-contains-1">{seg.text}</mark>
    {:else if seg.kind === 'contains-2'}
      <mark class="match-span-contains-2">{seg.text}</mark>
    {:else}
      <span>{seg.text}</span>
    {/if}
  {/each}
{/snippet}

<div
  bind:this={scrollerEl}
  bind:clientHeight={viewportHeight}
  bind:clientWidth={scrollerWidth}
  onscroll={handleScroll}
  class="flex-1 overflow-y-auto overscroll-contain bg-background"
>
  {#if workbench.flatHits.length > 0}
    <div class="px-3 md:px-6 pb-8" style={`font-size: ${workbench.codeFontSize}px`}>
      <div
        class="relative w-full"
        style={`height: ${visibleSlice.totalHeight}px`}
      >
        <div
          class="virtual-slice-gpu absolute left-0 right-0 top-0"
          style={`transform: translate3d(0, ${visibleSlice.offsetY}px, 0)`}
        >
          {#each visibleSlice.items as row (row.key)}
            {@const item = row.item}
            {@const active = row.idx === workbench.activeHitIndex}
            {@const segments = getCachedHighlightSegments(
              item,
              workbench.contains,
              isCaseInsensitive,
              segmentCacheKey,
              workbench.primaryPattern,
              isRegexMode
            )}
            <div
              style={`height: ${visibleSlice.rowHeight}px`}
              class="virtual-row-strict box-border overflow-hidden font-mono"
            >
              <div
                role="button"
                tabindex="0"
                onpointerdown={(e) => onRowPointerDown(e, row)}
                onpointermove={onRowPointerMove}
                onpointerup={cancelPress}
                onpointercancel={cancelPress}
                oncontextmenu={(e) => {
                  if (workbench.isCompact) e.preventDefault();
                }}
                onclick={() => {
                  if (suppressClick) {
                    suppressClick = false;
                    return;
                  }
                  // Touch long-press selections are handled via the action sheet; skip selection guard there.
                  if (!workbench.isCompact) {
                    const sel = window.getSelection()?.toString() ?? '';
                    if (sel.length > 0) return;
                  }
                  workbench.selectHitByIndex(row.idx, true);
                }}
                onkeydown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    workbench.selectHitByIndex(row.idx, true);
                  }
                }}
                class={`group flex h-full flex-col justify-center gap-0.5 px-3 cursor-pointer focus:outline-none transition-colors overflow-hidden rounded-lg ${
                  active
                    ? 'bg-secondary/75'
                    : item.isContext
                      ? 'opacity-70 hover:bg-secondary/25'
                      : 'hover:bg-secondary/35'
                }`}
              >
                <!-- Layer 1: Subtle Project Attribution (@project) + Hover Copy Button -->
                <div class="flex h-[18px] shrink-0 items-center justify-between gap-3 select-none">
                  <div class="flex items-center gap-1.5 min-w-0 font-mono text-[11px] leading-none">
                    {#if workbench.isCompact}
                      {#if row.showSrc && row.srcName}
                        <span class="shrink-0 text-muted-foreground/70">@{row.srcName}</span>
                      {/if}
                      <span class="truncate text-muted-foreground/60">{row.fileName}:{item.line}</span>
                    {:else if row.showSrc && row.srcName}
                      <button
                        type="button"
                        onclick={(e) => {
                          e.stopPropagation();
                          workbench.toggleScopeToken(row.srcName);
                        }}
                        title={`点击限定项目 @${row.srcName}`}
                        class="shrink-0 text-muted-foreground/45 hover:text-foreground transition-colors cursor-pointer"
                      >
                        @{row.srcName}
                      </button>
                    {/if}
                  </div>

                  <button
                    type="button"
                    title={workbench.locale === 'zh' ? '复制该条内容' : 'Copy content'}
                    onclick={(e) => copyLineText(e, row.idx, item.text)}
                    aria-label={workbench.locale === 'zh' ? '复制该条内容' : 'Copy content'}
                    class="touch-target shrink-0 rounded p-1 text-muted-foreground/60 hover:text-foreground opacity-60 group-hover:opacity-100 transition-opacity"
                  >
                    {#if copiedIdx === row.idx}
                      <Check class="h-3.5 w-3.5 text-primary" />
                    {:else}
                      <Copy class="h-3.5 w-3.5" />
                    {/if}
                  </button>
                </div>

                <!-- Layer 2: 100% Complete Matched Content -->
                <div class="w-full min-w-0 overflow-hidden">
                  <div
                    class={`${
                      workbench.wordWrap
                        ? visibleSlice.maxLines === 2
                          ? 'line-clamp-2 break-all'
                          : 'line-clamp-1 break-all'
                        : 'truncate whitespace-pre'
                    } leading-[1.6] text-foreground`}
                  >
                    {@render renderSegments(segments)}
                  </div>
                </div>
              </div>
            </div>
          {/each}
        </div>
      </div>
    </div>
  {:else if workbench.isSearching}
    <!-- Searching / Scanning State -->
    <div class="flex h-full flex-col items-center justify-center gap-3 p-8 text-center select-none">
      <Loader2 class="h-6 w-6 animate-spin text-primary" />
      <p class="text-sm font-medium text-muted-foreground">
        {workbench.t.results.searchingTitle}
      </p>
    </div>
  {:else if workbench.hasSearchedOnce && workbench.primaryPattern.trim().length > 0}
    <!-- Zero-Match State -->
    <div class="flex h-full flex-col items-center justify-center p-8 text-center select-none">
      <p class="text-base font-medium text-foreground">{workbench.t.results.noMatchesTitle}</p>
      <p class="mt-1.5 text-[13px] text-muted-foreground font-mono">
        {workbench.locale === 'zh'
          ? `耗时 ${workbench.elapsedMs.toFixed(2)} ms`
          : `Finished in ${workbench.elapsedMs.toFixed(2)} ms`}
      </p>
      <div class="mt-4 flex flex-wrap items-center justify-center gap-2">
        {#if workbench.activeFilterCount > 0 || workbench.selectedPaths.length > 0 || workbench.wholeWord || workbench.caseMode === 'sensitive'}
          <button
            type="button"
            onclick={() => {
              workbench.resetAllFilters();
            }}
            class="rounded-lg border border-border bg-card px-3.5 py-1.5 text-[13px] font-medium text-foreground hover:bg-secondary transition-colors"
          >
            {workbench.t.results.resetFiltersBtn}
          </button>
        {/if}
      </div>
    </div>
  {/if}
</div>

{#if menuRow}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    onclick={() => (menuRow = null)}
    onkeydown={(e) => e.key === 'Escape' && (menuRow = null)}
    class="fixed inset-0 z-50 flex items-end bg-black/50 select-none"
  >
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div
      onclick={(e) => e.stopPropagation()}
      class="pb-safe w-full rounded-t-2xl border-t border-border bg-card p-3"
    >
      <div class="mx-auto mb-3 h-1 w-9 rounded-full bg-border"></div>
      <div class="mb-2 truncate px-2 font-mono text-[12px] text-muted-foreground">
        {menuRow.fileName}:{menuRow.item.line}
      </div>
      <div class="flex items-center justify-around">
        <button
          type="button"
          onclick={copyFromMenu}
          aria-label={workbench.locale === 'zh' ? '复制' : 'Copy'}
          title={workbench.locale === 'zh' ? '复制' : 'Copy'}
          class="flex h-14 w-14 items-center justify-center rounded-xl bg-secondary text-foreground active:bg-secondary/60"
        >
          <Copy class="h-5 w-5" />
        </button>
        {#if menuRow.srcName}
          <button
            type="button"
            onclick={() => scopeFromMenu(false)}
            aria-label={`@${menuRow.srcName}`}
            title={`@${menuRow.srcName}`}
            class="flex h-14 w-14 items-center justify-center rounded-xl bg-secondary text-foreground active:bg-secondary/60"
          >
            <AtSign class="h-5 w-5" />
          </button>
          <button
            type="button"
            onclick={() => scopeFromMenu(true)}
            aria-label={`-@${menuRow.srcName}`}
            title={`-@${menuRow.srcName}`}
            class="flex h-14 w-14 items-center justify-center rounded-xl bg-secondary text-foreground active:bg-secondary/60"
          >
            <Ban class="h-5 w-5" />
          </button>
        {/if}
      </div>
    </div>
  </div>
{/if}
