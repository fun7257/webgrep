<script lang="ts">
  import { flushSync } from 'svelte';
  import type { HitItem } from '$lib/types';
  import {
    LogStreamStatsTracker,
    buildLogVirtualLayout,
    doesTextContainActiveQuery,
    getCachedLogProbe,
    getCachedParsedLog,
    getCachedPlainMeta,
    getCachedPlainProbe,
    indexAtY,
    type LogLevel,
    type LogStreamStats,
    type ParsedLogRecord,
    type RowActionItem,
    type RowMeasureContext,
  } from '$lib/adapters/index.ts';
  import {
    buildHighlightSegments,
    getCachedHighlightSegments,
    type HighlightSegment,
  } from '$lib/utils';
  import VirtualScrollShell from '../VirtualScrollShell.svelte';
  import RowActionSheet from '../RowActionSheet.svelte';
  import LogSummaryStrip from './LogSummaryStrip.svelte';
  import type { AdapterResultsProps } from '../types.ts';
  import { Check, Copy } from 'lucide-svelte';

  let { host }: AdapterResultsProps = $props();

  interface VisibleLogHitRow {
    kind: 'hit';
    key: string;
    hitIdx: number;
    item: HitItem;
    isNativeLog: boolean;
    logRecord: ParsedLogRecord | null;
    srcName: string;
    showSrc: boolean;
    fileChanged: boolean;
    dirLabel: string;
    fileName: string;
    lines: number;
    height: number;
  }

  interface VisibleLogDateRow {
    kind: 'date';
    key: string;
    dateKey: string;
    height: number;
  }

  type VisibleLogRow = VisibleLogHitRow | VisibleLogDateRow;

  let copiedIdx = $state<number>(-1);
  let scrollTop = $state<number>(0);
  let viewportHeight = $state<number>(720);
  let scrollerWidth = $state<number>(960);

  const statsTracker = new LogStreamStatsTracker();
  const logStats = $derived<LogStreamStats>(
    statsTracker.update(host.hits, host.sourceByName, host.viewMode)
  );

  const targetLines = $derived(host.wordWrap ? Math.max(1, Math.min(6, host.previewLines)) : 1);
  const previewCharBudget = $derived(Math.max(240, targetLines * 180));

  const streamLayout = $derived.by(() => {
    const fontPx = host.codeFontSize;
    const lineHeight = Math.round(fontPx * 1.56);
    const baseHitPad = host.resultDensity === 'compact' ? 10 : 14;
    // Account for left time+level gutter (~140px desktop, ~96px mobile) so line wrap height stays accurate
    const availTextWidth = Math.max(200, scrollerWidth - (host.isCompact ? 116 : 220));
    const charsPerLine = Math.max(24, Math.floor(availTextWidth / (fontPx * 0.6)));
    const ctx: RowMeasureContext = {
      fontPx,
      lineHeight,
      baseHitPad,
      maxPreviewLines: targetLines,
      wordWrap: host.wordWrap,
      charsPerLine,
      isCompact: host.isCompact,
      density: host.resultDensity,
    };

    const layout = buildLogVirtualLayout({
      hits: host.hits,
      sourceByName: host.sourceByName,
      forceLogSurface: host.viewMode === 'log',
      ctx,
      budget: previewCharBudget,
      getLogProbe: getCachedLogProbe,
      getPlainProbe: getCachedPlainProbe,
    });
    return { ...layout, lineHeight };
  });

  const activeVirtualIdx = $derived(
    host.activeHitIndex >= 0 && host.activeHitIndex < streamLayout.hitIdxToVirtualIdx.length
      ? streamLayout.hitIdxToVirtualIdx[host.activeHitIndex]
      : -1
  );

  const visibleSlice = $derived.by(() => {
    const { items, offsets, lineHeight, denseLogMode, totalHeight } = streamLayout;
    const vLen = items.length;
    if (vLen === 0) {
      return {
        rows: [] as VisibleLogRow[],
        offsetY: 0,
        totalHeight: 0,
        lineHeight,
        denseLogMode,
      };
    }

    const minY = Math.max(0, scrollTop - host.overscanPx);
    const maxY = scrollTop + Math.max(400, viewportHeight) + host.overscanPx;
    const firstV = indexAtY(offsets, vLen, minY);
    const lastV = indexAtY(offsets, vLen, maxY);

    const rows: VisibleLogRow[] = [];
    for (let v = firstV; v <= lastV; v++) {
      const entry = items[v];
      if (entry.kind === 'date') {
        rows.push({
          kind: 'date',
          key: entry.key,
          dateKey: entry.dateKey,
          height: entry.height,
        });
        continue;
      }

      const it = entry.item;
      const meta = getCachedPlainMeta(it);
      const prevHit = entry.hitIdx > 0 ? host.hits[entry.hitIdx - 1] : null;
      const prevFile = prevHit ? prevHit.file : '';
      const prevSlash = prevFile.indexOf('/');
      const prevSrc = prevSlash > 0 ? prevFile.slice(0, prevSlash) : '';
      const logRecord = entry.isNativeLog ? getCachedParsedLog(it) : null;

      rows.push({
        kind: 'hit',
        key: entry.key,
        hitIdx: entry.hitIdx,
        item: it,
        isNativeLog: entry.isNativeLog,
        logRecord,
        srcName: meta.srcName,
        showSrc: entry.hitIdx === 0 || meta.srcName !== prevSrc,
        fileChanged: entry.hitIdx === 0 || it.file !== prevFile,
        dirLabel: meta.dirLabel,
        fileName: meta.fileName,
        lines: entry.lines,
        height: entry.height,
      });
    }

    return {
      rows,
      offsetY: offsets[firstV],
      totalHeight,
      lineHeight,
      denseLogMode,
    };
  });

  // WeakMap-memoized log summary & category highlight segments
  const logHighlightCache = new WeakMap<
    HitItem,
    {
      key: string;
      summarySegs: HighlightSegment[];
      catSegs: HighlightSegment[];
      matchInHeadline: boolean;
    }
  >();

  function getCachedLogHighlight(
    item: HitItem,
    log: ParsedLogRecord,
    containsTerms: readonly string[],
    cacheKey: string,
    primaryPattern: string,
    isRegex: boolean
  ) {
    const existing = logHighlightCache.get(item);
    if (existing && existing.key === cacheKey) return existing;

    const summarySegs = buildHighlightSegments(
      log.summary || ' ',
      undefined,
      containsTerms,
      true,
      false,
      primaryPattern,
      isRegex
    );
    const catSegs = log.category
      ? buildHighlightSegments(
          log.category,
          undefined,
          containsTerms,
          true,
          false,
          primaryPattern,
          isRegex
        )
      : [];

    const visibleHeadline = log.category ? `${log.summary}\n${log.category}` : log.summary;
    const matchInHeadline = doesTextContainActiveQuery(
      visibleHeadline,
      primaryPattern,
      containsTerms,
      isRegex
    );

    const entry = { key: cacheKey, summarySegs, catSegs, matchInHeadline };
    logHighlightCache.set(item, entry);
    return entry;
  }

  // Long-press & pointer interaction state
  let pressedIdx = $state<number>(-1);
  let pointerDownSelectedIdx = -1;
  let menuRow = $state.raw<VisibleLogHitRow | null>(null);
  let pressTimer: ReturnType<typeof setTimeout> | null = null;
  let pressOrigin: { x: number; y: number } | null = null;
  let suppressClick = false;

  function cancelPress() {
    pressedIdx = -1;
    if (pressTimer !== null) clearTimeout(pressTimer);
    pressTimer = null;
    pressOrigin = null;
  }

  function onRowPointerDown(e: PointerEvent, row: VisibleLogHitRow) {
    if ((e.target as Element | null)?.closest('button, a')) return;
    if (e.pointerType === 'touch') {
      flushSync(() => {
        pressedIdx = row.hitIdx;
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
        if (!host.isCompact && host.rightInspectorOpen && host.inspectedPath) {
          pointerDownSelectedIdx = row.hitIdx;
          host.selectHitByIndex(row.hitIdx, false);
        } else {
          host.previewSelectHitByIndex(row.hitIdx);
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

  function handleRowClick(e: MouseEvent, row: VisibleLogHitRow) {
    if (suppressClick) {
      suppressClick = false;
      pointerDownSelectedIdx = -1;
      return;
    }
    const handledOnDown = pointerDownSelectedIdx === row.hitIdx && e.detail > 0;
    pointerDownSelectedIdx = -1;
    if (handledOnDown) return;
    if (!host.isCompact && !host.isTouch) {
      const sel = window.getSelection()?.toString() ?? '';
      if (sel.length > 0) return;
    }
    host.selectHitByIndex(row.hitIdx, true);
  }

  function handleRowKeydown(e: KeyboardEvent, row: VisibleLogHitRow) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      host.selectHitByIndex(row.hitIdx, true);
    }
  }

  function copyLineText(e: MouseEvent, idx: number, text: string) {
    e.stopPropagation();
    host.copyText(text);
    copiedIdx = idx;
    setTimeout(() => {
      if (copiedIdx === idx) copiedIdx = -1;
    }, 1400);
  }

  function levelTextClass(level: LogLevel): string {
    if (level === 'fatal' || level === 'error') {
      return 'text-status font-semibold';
    }
    if (level === 'warn') {
      return 'text-status/80 font-medium';
    }
    if (level === 'info') {
      return 'text-muted-foreground/85';
    }
    return 'text-muted-foreground/50';
  }

  function logRowClass(active: boolean, pressed: boolean, level: LogLevel): string {
    if (active) {
      return 'bg-secondary/85 ring-1 ring-inset ring-primary/35 shadow-[inset_2.5px_0_0_hsl(var(--primary))]';
    }
    if (pressed) {
      return 'bg-secondary/60';
    }
    if (level === 'fatal' || level === 'error') {
      return 'shadow-[inset_2px_0_0_hsl(var(--status)/0.55)] hover:bg-secondary/40 active:bg-secondary/55';
    }
    return 'hover:bg-secondary/40 active:bg-secondary/55';
  }

  const isCaseInsensitive = true;
  const isRegexMode = $derived(host.searchMode === 'regex');
  const segmentCacheKey = $derived(
    `${host.searchMode}:${host.primaryPattern}\u0001${host.contains.join('\u0001')}\u0001${previewCharBudget}`
  );

  const menuActions = $derived.by((): RowActionItem[] => {
    const row = menuRow;
    if (!row) return [];
    const actions: RowActionItem[] = [
      {
        id: 'copy',
        iconKind: 'copy',
        label: host.t.ui.copy,
        title: host.t.ui.copy,
        run: () => host.copyText(row.item.text),
      },
    ];
    if (row.logRecord?.traceId) {
      const traceId = row.logRecord.traceId;
      actions.push({
        id: 'trace',
        iconKind: 'trace',
        accent: true,
        label: host.t.logView.traceFollowBtn,
        title: host.t.logView.traceFromMenuTitle(traceId),
        run: () => host.replaceQuery(traceId),
      });
    }
    actions.push({
      id: 'context',
      iconKind: 'context',
      label: host.t.inspector.contextDrawerTitle,
      title: host.t.inspector.openContextTitle,
      run: () => host.openContextDrawer(row.item.file, row.item.line, row.item.byteOffset),
    });
    if (row.srcName) {
      const srcName = row.srcName;
      actions.push(
        {
          id: 'solo',
          iconKind: 'solo-source',
          label: srcName,
          title: host.t.scopeBar.soloTitle(srcName),
          run: () => host.scopeSourceFromMenu(srcName, false),
        },
        {
          id: 'exclude',
          iconKind: 'exclude-source',
          label: `!${srcName}`,
          title: host.t.scopeBar.excludeTitle(srcName),
          run: () => host.scopeSourceFromMenu(srcName, true),
        }
      );
    }
    return actions;
  });
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

{#snippet renderNativeLogRow(row: VisibleLogHitRow, log: ParsedLogRecord, active: boolean, pressed: boolean)}
  {@const hl = getCachedLogHighlight(
    row.item,
    log,
    host.contains,
    segmentCacheKey,
    host.primaryPattern,
    isRegexMode
  )}
  {@const fallbackSegs = !hl.matchInHeadline
    ? getCachedHighlightSegments(
        row.item,
        host.contains,
        isCaseInsensitive,
        segmentCacheKey,
        host.primaryPattern,
        isRegexMode,
        previewCharBudget
      )
    : null}

  <div
    role="button"
    tabindex="0"
    onpointerdown={(e) => onRowPointerDown(e, row)}
    onpointermove={onRowPointerMove}
    onpointerup={cancelPress}
    onpointercancel={cancelPress}
    oncontextmenu={(e) => {
      if (host.isCompact || host.isTouch) e.preventDefault();
    }}
    onclick={(e) => handleRowClick(e, row)}
    onkeydown={(e) => handleRowKeydown(e, row)}
    class={`group ${host.isTouch ? 'select-none' : ''} flex h-full items-start gap-2.5 px-2.5 ${
      host.resultDensity === 'compact' ? 'py-[5px]' : 'py-[7px]'
    } cursor-pointer focus:outline-none overflow-hidden rounded-md ${logRowClass(active, pressed, log.level)}`}
  >
    <!-- Quiet left gutter: Time + Level (plain typography, zero boxes) -->
    {#if log.timeShort || log.levelBadge}
      <div
        style={`line-height: ${visibleSlice.lineHeight}px;`}
        class="flex shrink-0 items-baseline gap-2 font-mono text-[11.5px] select-none"
      >
        {#if log.timeShort}
          <span
            title={log.timeFull || log.timeRaw}
            class="w-[82px] shrink-0 tabular-nums text-muted-foreground/70"
          >
            {log.timeShort}
          </span>
        {/if}
        {#if log.levelBadge}
          <span class={`w-[28px] shrink-0 text-[11px] ${levelTextClass(log.level)}`}>
            {log.levelBadge}
          </span>
        {/if}
      </div>
    {/if}

    <!-- Clean primary log message + match-centered fallback excerpt if needed -->
    <div class="min-w-0 flex-1 overflow-hidden font-mono text-foreground">
      {#if !visibleSlice.denseLogMode && row.lines > 1}
        <div
          style={`line-height: ${visibleSlice.lineHeight}px; max-height: ${row.lines * visibleSlice.lineHeight}px; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: ${row.lines}; overflow: hidden;`}
          class="whitespace-pre-wrap break-all"
        >
          {@render renderSegments(hl.summarySegs)}
          {#if fallbackSegs}
            <span class="mx-1.5 text-muted-foreground/40">·</span><span class="text-muted-foreground/85">{@render renderSegments(fallbackSegs)}</span>
          {/if}
        </div>
      {:else}
        <div
          style={`line-height: ${visibleSlice.lineHeight}px;`}
          class="truncate whitespace-pre"
        >
          {@render renderSegments(hl.summarySegs)}
          {#if fallbackSegs}
            <span class="mx-1.5 text-muted-foreground/40">·</span><span class="text-muted-foreground/85">{@render renderSegments(fallbackSegs)}</span>
          {/if}
        </div>
      {/if}
    </div>

    <!-- Quiet right-edge attribution (category / file:line / hover copy) -->
    <div
      style={`line-height: ${visibleSlice.lineHeight}px;`}
      class="flex shrink-0 items-center gap-2 font-mono text-[11px] select-none"
    >
      {#if log.category}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={(e) => {
            e.stopPropagation();
            if (e.altKey) host.excludeTerm(log.categoryFilterToken || log.category);
            else host.appendTerm(log.categoryFilterToken || log.category);
          }}
          title={host.t.logView.rowCategoryTitle(log.category)}
          class="hidden lg:inline-block max-w-[128px] truncate text-muted-foreground/55 hover:text-primary cursor-pointer"
        >
          {@render renderSegments(hl.catSegs)}
        </button>
      {/if}

      {#if row.fileChanged}
        <span class="hidden sm:inline truncate max-w-[140px] text-muted-foreground/50 tabular-nums" title={row.item.file}>
          {row.fileName}:{row.item.line}
        </span>
      {:else}
        <span class="hidden sm:inline text-muted-foreground/40 tabular-nums" title={row.item.file}>
          :{row.item.line}
        </span>
      {/if}

      <button
        type="button"
        title={host.t.ui.copyContent}
        onclick={(e) => copyLineText(e, row.hitIdx, row.item.text)}
        aria-label={host.t.ui.copyContent}
        class="touch-target shrink-0 rounded p-0.5 text-muted-foreground/55 hover:text-foreground opacity-0 group-hover:opacity-100 focus:opacity-100"
      >
        {#if copiedIdx === row.hitIdx}
          <Check class="h-3.5 w-3.5 text-primary" />
        {:else}
          <Copy class="h-3.5 w-3.5" />
        {/if}
      </button>
    </div>
  </div>
{/snippet}

{#snippet renderFallbackHitRow(row: VisibleLogHitRow, active: boolean, pressed: boolean)}
  {@const item = row.item}
  {@const segments = getCachedHighlightSegments(
    item,
    host.contains,
    isCaseInsensitive,
    segmentCacheKey,
    host.primaryPattern,
    isRegexMode,
    previewCharBudget
  )}
  <div
    role="button"
    tabindex="0"
    onpointerdown={(e) => onRowPointerDown(e, row)}
    onpointermove={onRowPointerMove}
    onpointerup={cancelPress}
    onpointercancel={cancelPress}
    oncontextmenu={(e) => {
      if (host.isCompact || host.isTouch) e.preventDefault();
    }}
    onclick={(e) => handleRowClick(e, row)}
    onkeydown={(e) => handleRowKeydown(e, row)}
    class={`group ${host.isTouch ? 'select-none' : ''} flex h-full flex-col justify-center gap-0.5 px-3 cursor-pointer focus:outline-none overflow-hidden rounded-md ${
      active
        ? 'bg-secondary/85 ring-1 ring-inset ring-primary/35 shadow-[inset_2.5px_0_0_hsl(var(--primary))]'
        : pressed
          ? 'bg-secondary/60'
          : 'hover:bg-secondary/40 active:bg-secondary/55'
    }`}
  >
    <div class="flex h-[18px] shrink-0 items-center justify-between gap-3 select-none">
      <div class="flex items-center gap-1.5 min-w-0 font-mono text-[11px] leading-none">
        {#if row.fileChanged}
          <span class="min-w-0 truncate" title={item.file}>
            <span class="text-muted-foreground/45">{row.dirLabel}</span><span class={active ? 'text-foreground' : 'text-foreground/75'}>{row.fileName}</span><span class="text-muted-foreground/60">:{item.line}</span>
          </span>
        {:else}
          <span class={`shrink-0 tabular-nums ${active ? 'text-foreground/80' : 'text-muted-foreground/50'}`} title={item.file}>:{item.line}</span>
        {/if}
      </div>

      <button
        type="button"
        title={host.t.ui.copyContent}
        onclick={(e) => copyLineText(e, row.hitIdx, item.text)}
        aria-label={host.t.ui.copyContent}
        class="touch-target shrink-0 rounded p-0.5 text-muted-foreground/55 hover:text-foreground opacity-0 group-hover:opacity-100 focus:opacity-100"
      >
        {#if copiedIdx === row.hitIdx}
          <Check class="h-3.5 w-3.5 text-primary" />
        {:else}
          <Copy class="h-3.5 w-3.5" />
        {/if}
      </button>
    </div>

    <div class="w-full min-w-0 overflow-hidden">
      {#if host.wordWrap && row.lines > 1}
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
{/snippet}

<div class="flex flex-1 min-h-0 flex-col overflow-clip">
  {#if logStats.logCount > 0}
    <LogSummaryStrip stats={logStats} {host} />
  {/if}

  <VirtualScrollShell
    totalHeight={visibleSlice.totalHeight}
    offsetY={visibleSlice.offsetY}
    offsets={streamLayout.offsets}
    {activeVirtualIdx}
    scrollResetKey={host.currentSearchId}
    scrollToActiveTick={host.scrollToActiveTick}
    codeFontSize={host.codeFontSize}
    canPullRefresh={host.hasExecutableQuery && !host.isSearching}
    bind:scrollTop
    bind:viewportHeight
    bind:scrollerWidth
    onRefresh={() => host.refreshSearch(true)}
  >
    {#each visibleSlice.rows as row (row.key)}
      {#if row.kind === 'date'}
        <div
          style={`height: ${row.height}px`}
          class="virtual-row-strict flex items-center gap-2 px-2 select-none"
        >
          <span class="font-mono text-[10.5px] tabular-nums text-muted-foreground/65">
            {row.dateKey}
          </span>
          <div class="h-px flex-1 bg-border/35"></div>
        </div>
      {:else}
        {@const active = row.hitIdx === host.activeHitIndex}
        {@const pressed = pressedIdx === row.hitIdx}
        <div
          style={`height: ${row.height}px`}
          class="virtual-row-strict box-border overflow-hidden font-mono"
        >
          {#if row.isNativeLog && row.logRecord}
            {@render renderNativeLogRow(row, row.logRecord, active, pressed)}
          {:else}
            {@render renderFallbackHitRow(row, active, pressed)}
          {/if}
        </div>
      {/if}
    {/each}
  </VirtualScrollShell>
</div>

{#if menuRow}
  <RowActionSheet
    title={`${menuRow.fileName}:${menuRow.item.line}`}
    actions={menuActions}
    onClose={() => (menuRow = null)}
  />
{/if}
