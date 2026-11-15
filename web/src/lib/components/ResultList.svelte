<script lang="ts">
  import { flushSync } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { zeroResultFixes } from '$lib/suggest';
  import type { HitItem } from '$lib/types';
  import {
    copyTextToClipboard,
    extractLeadingNanoTimestamp,
    getCachedHighlightSegments,
    skipLeadingNanoTimestampOffset,
    type HighlightSegment,
  } from '$lib/utils';
  import { FolderSearch, Ban, Check, Copy, Loader2, RefreshCw } from 'lucide-svelte';

  interface VirtualHitRow {
    idx: number;
    key: string;
    item: HitItem;
    srcName: string;
    /** True when the data source differs from the previous hit (breadcrumb only shown on change). */
    showSrc: boolean;
    /** True when the file differs from the previous hit (full path shown; otherwise just `:line`). */
    fileChanged: boolean;
    /** Parent folders inside the data source (last two levels), e.g. `states/server/`. */
    dirLabel: string;
    fileName: string;
    timeLabel: string;
    timeNs: string;
    /** Deterministic preview line count for this row (1–6). */
    lines: number;
    /** Deterministic pixel height for this row. */
    height: number;
  }

  let copiedIdx = $state<number>(-1);
  let scrollerEl = $state<HTMLDivElement | null>(null);
  let scrollTop = $state<number>(0);
  let viewportHeight = $state<number>(720);
  let scrollerWidth = $state<number>(960);

  const BREADCRUMB_H = 22;

  const targetLines = $derived(
    workbench.wordWrap ? Math.max(1, Math.min(6, workbench.previewLines)) : 1
  );
  const previewCharBudget = $derived(Math.max(240, targetLines * 180));

  // Reset scroll position when a new search starts
  $effect(() => {
    void workbench.currentSearchId;
    scrollTop = 0;
    if (scrollerEl) {
      scrollerEl.scrollTop = 0;
    }
  });

  // Width-independent column count cache & per-hit metadata cache keyed by HitItem object identity.
  const colEstimateCache = new WeakMap<HitItem, { budget: number; cols: number }>();

  interface CachedRowMeta {
    srcName: string;
    dirLabel: string;
    fileName: string;
    timeLabel: string;
    timeNs: string;
  }

  const rowMetaCache = new WeakMap<HitItem, CachedRowMeta>();

  function getRowMeta(it: HitItem): CachedRowMeta {
    let meta = rowMetaCache.get(it);
    if (meta) return meta;
    const slash = it.file.indexOf('/');
    const srcName = slash > 0 ? it.file.slice(0, slash) : '';
    const lastSlash = it.file.lastIndexOf('/');
    const dirParts = it.file
      .slice(slash > 0 ? slash + 1 : 0, Math.max(0, lastSlash))
      .split('/')
      .filter(Boolean);
    const dirLabel =
      dirParts.length > 2
        ? `…/${dirParts.slice(-2).join('/')}/`
        : dirParts.length
          ? `${dirParts.join('/')}/`
          : '';
    const fileName = lastSlash >= 0 ? it.file.slice(lastSlash + 1) : it.file;
    const tsInfo = extractLeadingNanoTimestamp(it.text);
    meta = {
      srcName,
      dirLabel,
      fileName,
      timeLabel: tsInfo ? tsInfo.formattedTime : '',
      timeNs: tsInfo ? tsInfo.nsStr : '',
    };
    rowMetaCache.set(it, meta);
    return meta;
  }

  function estimateColumns(raw: string, budget: number): number {
    const tsEnd = skipLeadingNanoTimestampOffset(raw);
    let start = tsEnd > 0 && tsEnd < raw.length ? tsEnd : 0;
    while (start < raw.length && (raw.charCodeAt(start) === 32 || raw.charCodeAt(start) === 9)) start++;
    const end = Math.min(raw.length, start + budget);
    let cols = 0;
    for (let i = start; i < end; i++) {
      // CJK / full-width glyphs render ~1em wide ≈ 1.67 monospace columns (0.6em each)
      cols += raw.charCodeAt(i) >= 0x2e80 ? 1.67 : 1;
    }
    return cols;
  }

  // Variable-height virtual layout: O(n) prefix sum of cached per-row heights, O(log n) viewport lookup.
  const streamLayout = $derived.by(() => {
    const hits = workbench.flatHits;
    const hLen = hits.length;
    const fontPx = workbench.codeFontSize;
    const lineHeight = Math.round(fontPx * 1.56);
    const baseHitPad = workbench.resultDensity === 'compact' ? 12 : 18;
    const maxPreview = targetLines;
    const budget = previewCharBudget;
    const availTextWidth = Math.max(240, scrollerWidth - (workbench.isCompact ? 48 : 72));
    const charsPerLine = Math.max(24, Math.floor(availTextWidth / (fontPx * 0.6)));

    const lines = new Uint8Array(hLen);
    const offsets = new Float64Array(hLen + 1);
    let acc = 0;
    for (let i = 0; i < hLen; i++) {
      const it = hits[i];
      let n = 1;
      if (maxPreview > 1) {
        let cached = colEstimateCache.get(it);
        if (!cached || cached.budget !== budget) {
          cached = { budget, cols: estimateColumns(it.text, budget) };
          colEstimateCache.set(it, cached);
        }
        // small slack so a barely-overflowing estimate doesn't reserve a mostly-empty extra line
        n = Math.min(maxPreview, Math.max(1, Math.ceil(cached.cols / charsPerLine - 0.12)));
      }
      lines[i] = n;
      offsets[i] = acc;
      acc += baseHitPad + BREADCRUMB_H + n * lineHeight;
    }
    offsets[hLen] = acc;

    return { hits, lines, offsets, lineHeight, baseHitPad, totalHeight: acc };
  });

  /** Largest index i such that offsets[i] <= y. */
  function indexAtY(offsets: Float64Array, count: number, y: number): number {
    let lo = 0;
    let hi = count - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (offsets[mid] <= y) lo = mid;
      else hi = mid - 1;
    }
    return lo;
  }

  // O(log n) viewport slice: allocates ONLY the ~20 visible snippet rows on screen
  const visibleSlice = $derived.by(() => {
    const { hits, lines, offsets, lineHeight, baseHitPad, totalHeight } = streamLayout;
    const hLen = hits.length;
    if (hLen === 0) {
      return {
        items: [] as VirtualHitRow[],
        offsetY: 0,
        totalHeight: 0,
        lineHeight,
      };
    }

    const overscanPx = workbench.frameProfile.overscanPx;
    const minY = Math.max(0, scrollTop - overscanPx);
    const maxY = scrollTop + Math.max(400, viewportHeight) + overscanPx;

    const firstIdx = indexAtY(offsets, hLen, minY);
    const lastIdx = indexAtY(offsets, hLen, maxY);

    const items: VirtualHitRow[] = [];
    for (let i = firstIdx; i <= lastIdx; i++) {
      const it = hits[i];
      const meta = getRowMeta(it);
      const prevFile = i > 0 ? hits[i - 1].file : '';
      const prevSlash = prevFile.indexOf('/');
      const prevSrc = prevSlash > 0 ? prevFile.slice(0, prevSlash) : '';
      const n = lines[i];
      items.push({
        showSrc: i === 0 || meta.srcName !== prevSrc,
        fileChanged: i === 0 || it.file !== prevFile,
        dirLabel: meta.dirLabel,
        fileName: meta.fileName,
        idx: i,
        key: `${i}:${it.file}:${it.line}:${it.col}`,
        item: it,
        srcName: meta.srcName,
        timeLabel: meta.timeLabel,
        timeNs: meta.timeNs,
        lines: n,
        height: baseHitPad + BREADCRUMB_H + n * lineHeight,
      });
    }

    return {
      items,
      offsetY: offsets[firstIdx],
      totalHeight,
      lineHeight,
    };
  });

  // O(1) auto-scroll when navigating hits via keyboard (↑/↓ or j/k)
  $effect(() => {
    const tick = workbench.scrollToActiveTick;
    if (tick === 0 || !scrollerEl) return;
    const activeIdx = workbench.activeHitIndex;
    const { offsets, hits } = streamLayout;
    if (activeIdx < 0 || activeIdx >= hits.length) return;

    const targetY = offsets[activeIdx];
    const targetBottom = offsets[activeIdx + 1];
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

  // Pull-down at scrollTop 0 re-runs the current search (touch only).
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
    if (fire && workbench.hasExecutableQuery && !workbench.isSearching) {
      workbench.executeSearch({ forceRefresh: true });
    }
  }

  // Instant pointer-down row highlight + touch long-press action sheet.
  let pressedIdx = $state<number>(-1);
  let pointerDownSelectedIdx = -1;
  let menuRow = $state.raw<VirtualHitRow | null>(null);
  let pressTimer: ReturnType<typeof setTimeout> | null = null;
  let pressOrigin: { x: number; y: number } | null = null;
  let suppressClick = false;

  function cancelPress() {
    pressedIdx = -1;
    if (pressTimer !== null) clearTimeout(pressTimer);
    pressTimer = null;
    pressOrigin = null;
  }

  function onRowPointerDown(e: PointerEvent, row: VirtualHitRow) {
    if ((e.target as Element | null)?.closest('button, a')) return;
    if (e.pointerType === 'touch') {
      flushSync(() => {
        pressedIdx = row.idx;
      });
      pressOrigin = { x: e.clientX, y: e.clientY };
      pressTimer = setTimeout(() => {
        pressTimer = null;
        pressedIdx = -1;
        suppressClick = true;
        menuRow = row;
        navigator.vibrate?.(8);
      }, 480);
      return;
    }

    if (
      e.pointerType === 'mouse' &&
      e.button === 0 &&
      !e.altKey &&
      !e.ctrlKey &&
      !e.metaKey &&
      !e.shiftKey
    ) {
      flushSync(() => {
        if (!workbench.isCompact && workbench.rightInspectorOpen && workbench.inspectedPath) {
          pointerDownSelectedIdx = row.idx;
          workbench.selectHitByIndex(row.idx, false);
        } else {
          workbench.previewSelectHitByIndex(row.idx);
        }
      });
    }
  }

  function onRowPointerMove(e: PointerEvent) {
    if (!pressOrigin) return;
    if (Math.abs(e.clientX - pressOrigin.x) > 8 || Math.abs(e.clientY - pressOrigin.y) > 8) {
      cancelPress();
    }
  }

  function copyFromMenu() {
    if (!menuRow) return;
    copyTextToClipboard(menuRow.item.text);
    menuRow = null;
  }

  function scopeFromMenu(exclude: boolean) {
    if (!menuRow || !menuRow.srcName) return;
    workbench.scopeSourceFromMenu(menuRow.srcName, exclude);
    menuRow = null;
  }

  function copyLineText(e: MouseEvent, idx: number, text: string) {
    e.stopPropagation();
    copyTextToClipboard(text);
    copiedIdx = idx;
    setTimeout(() => {
      if (copiedIdx === idx) copiedIdx = -1;
    }, 1400);
  }

  const isCaseInsensitive = true;
  const isRegexMode = $derived(workbench.mode === 'regex');
  const segmentCacheKey = $derived(
    `${workbench.mode}:${workbench.primaryPattern}\u0001${workbench.contains.join('\u0001')}\u0001${previewCharBudget}`
  );

  const zeroFixes = $derived(
    !workbench.isSearching && workbench.totalMatches === 0
      ? zeroResultFixes(
          workbench.steps,
          workbench.draftStep,
          workbench.scope,
          workbench.t.suggest
        )
      : []
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
  class="relative flex-1 overflow-y-auto overscroll-contain bg-background"
>
  {#if pullDist > 4}
    <div
      class="pointer-events-none absolute inset-x-0 top-0 z-10 flex justify-center"
      style={`transform: translate3d(0, ${pullDist - 28}px, 0); opacity: ${Math.min(1, pullDist / 40)}`}
    >
      <RefreshCw class="h-4 w-4 text-muted-foreground" />
    </div>
  {/if}
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
            {@const pressed = pressedIdx === row.idx}
            {@const segments = getCachedHighlightSegments(
              item,
              workbench.contains,
              isCaseInsensitive,
              segmentCacheKey,
              workbench.primaryPattern,
              isRegexMode,
              previewCharBudget
            )}
            <div
              style={`height: ${row.height}px`}
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
                  if (workbench.isCompact || workbench.isTouch) e.preventDefault();
                }}
                onclick={(e) => {
                  if (suppressClick) {
                    suppressClick = false;
                    pointerDownSelectedIdx = -1;
                    return;
                  }
                  const handledOnDown = pointerDownSelectedIdx === row.idx && e.detail > 0;
                  pointerDownSelectedIdx = -1;
                  if (handledOnDown) return;
                  // Touch long-press selections are handled via the action sheet; skip selection guard there.
                  if (!workbench.isCompact && !workbench.isTouch) {
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
                class={`group ${workbench.isTouch ? 'select-none' : ''} flex h-full flex-col justify-center gap-0.5 px-3 cursor-pointer focus:outline-none overflow-hidden rounded-lg ${
                  active
                    ? 'bg-secondary/90 ring-1 ring-inset ring-primary/35 shadow-[inset_2.5px_0_0_hsl(var(--primary))]'
                    : pressed
                      ? 'bg-secondary/65'
                      : 'hover:bg-secondary/40 active:bg-secondary/60'
                }`}
              >
                <!-- Layer 1: Subtle Project Attribution (@project) + File:Line + Copy Button -->
                <div class="flex h-[18px] shrink-0 items-center justify-between gap-3 select-none">
                  <div class="flex items-center gap-1.5 min-w-0 font-mono text-[11px] leading-none">
                    {#if row.showSrc && row.srcName}
                      {#if workbench.isCompact}
                        <span class="shrink-0 text-muted-foreground/70">{row.srcName}</span>
                      {:else}
                        <button
                          type="button"
                          onclick={(e) => {
                            e.stopPropagation();
                            if (e.altKey) {
                              workbench.toggleExcludeScopeSourceByName(row.srcName);
                            } else if (e.metaKey || e.ctrlKey || e.shiftKey) {
                              workbench.toggleScopeSourceByName(row.srcName);
                            } else {
                              workbench.selectSingleScopeSourceByName(row.srcName);
                            }
                          }}
                          title={workbench.t.ui.onlyInSourceTitle(row.srcName)}
                          class="shrink-0 text-muted-foreground/45 hover:text-foreground cursor-pointer"
                        >
                          {row.srcName}
                        </button>
                      {/if}
                    {/if}
                    <!-- file:line — full path when the file changes, otherwise only the line number -->
                    {#if row.fileChanged}
                      <span class="min-w-0 truncate" title={item.file}>
                        <span class="text-muted-foreground/45">{row.dirLabel}</span><span class={active ? 'text-foreground' : 'text-foreground/75'}>{row.fileName}</span><span class="text-muted-foreground/60">:{item.line}</span>
                      </span>
                    {:else}
                      <span class={`shrink-0 tabular-nums ${active ? 'text-foreground/80' : 'text-muted-foreground/50'}`} title={item.file}>:{item.line}</span>
                    {/if}
                    {#if row.timeLabel}
                      <span
                        title={row.timeNs}
                        class="shrink-0 text-muted-foreground/50 tabular-nums"
                      >
                        {row.timeLabel}
                      </span>
                    {/if}
                  </div>

                  <button
                    type="button"
                    title={workbench.t.ui.copyContent}
                    onclick={(e) => copyLineText(e, row.idx, item.text)}
                    aria-label={workbench.t.ui.copyContent}
                    class="touch-target shrink-0 rounded p-1 text-muted-foreground/60 hover:text-foreground opacity-60 group-hover:opacity-100"
                  >
                    {#if copiedIdx === row.idx}
                      <Check class="h-3.5 w-3.5 text-primary" />
                    {:else}
                      <Copy class="h-3.5 w-3.5" />
                    {/if}
                  </button>
                </div>

                <!-- Layer 2: Multi-line single-record content preview (1–6 lines) -->
                <div class="w-full min-w-0 overflow-hidden">
                  {#if workbench.wordWrap && row.lines > 1}
                    <div
                      style={`line-height: ${visibleSlice.lineHeight}px; max-height: ${row.lines * visibleSlice.lineHeight}px; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: ${row.lines}; overflow: hidden;`}
                      class="whitespace-pre-wrap break-all text-foreground"
                    >
                      {@render renderSegments(segments)}
                    </div>
                  {:else}
                    <div
                      style={`line-height: ${visibleSlice.lineHeight}px;`}
                      class="truncate whitespace-pre text-foreground"
                    >
                      {@render renderSegments(segments)}
                    </div>
                  {/if}
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
  {:else if workbench.hasSearchedOnce && workbench.hasExecutableQuery}
    <!-- Zero-Match State -->
    <div class="flex h-full flex-col items-center justify-center p-8 text-center select-none">
      <p class="text-base font-medium text-foreground">{workbench.t.results.noMatchesTitle}</p>
      <p class="mt-1.5 text-[13px] text-muted-foreground font-mono">
        {workbench.t.ui.finishedIn(workbench.elapsedMs.toFixed(2))}
      </p>
      <div class="mt-4 flex flex-wrap items-center justify-center gap-2">
        <!-- One-click ways out of an empty result (drop a term / scope, ignore case, nearby lines) -->
        {#each zeroFixes as fix (fix.key)}
          <button
            type="button"
            onclick={() => workbench.applyResultFix(fix)}
            class="touch-target rounded-lg bg-primary/10 px-3 py-1.5 font-mono text-[12.5px] text-primary hover:bg-primary/20 active:bg-primary/25 cursor-pointer"
          >
            {fix.label}
          </button>
        {/each}
        {#if workbench.activeFilterCount > 0}
          <button
            type="button"
            onclick={() => {
              workbench.resetAllFilters();
            }}
            class="rounded-lg border border-border bg-card px-3.5 py-1.5 text-[13px] font-medium text-foreground hover:bg-secondary active:bg-secondary/80 cursor-pointer"
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
          aria-label={workbench.t.ui.copy}
          title={workbench.t.ui.copy}
          class="flex h-14 w-14 items-center justify-center rounded-xl bg-secondary text-foreground active:bg-secondary/60"
        >
          <Copy class="h-5 w-5" />
        </button>
        {#if menuRow.srcName}
          <button
            type="button"
            onclick={() => scopeFromMenu(false)}
            aria-label={workbench.t.scopeBar.soloTitle(menuRow.srcName)}
            title={workbench.t.scopeBar.soloTitle(menuRow.srcName)}
            class="flex h-14 w-14 items-center justify-center rounded-xl bg-secondary text-foreground active:bg-secondary/60"
          >
            <FolderSearch class="h-5 w-5" />
          </button>
          <button
            type="button"
            onclick={() => scopeFromMenu(true)}
            aria-label={workbench.t.scopeBar.excludeTitle(menuRow.srcName)}
            title={workbench.t.scopeBar.excludeTitle(menuRow.srcName)}
            class="flex h-14 w-14 items-center justify-center rounded-xl bg-secondary text-foreground active:bg-secondary/60"
          >
            <Ban class="h-5 w-5" />
          </button>
        {/if}
      </div>
    </div>
  </div>
{/if}
