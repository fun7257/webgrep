<script lang="ts">
  import { flushSync } from 'svelte';
  import type { HitItem } from '$lib/types';
  import {
    LINE_BREADCRUMB_H,
    buildLogVirtualLayout,
    getCachedParsedLog,
    getCachedPlainProbe,
    indexAtY,
    type RowActionItem,
    type RowMeasureContext,
  } from '$lib/adapters/index.ts';
  import { getCachedHighlightSegments, type HighlightSegment } from '$lib/utils';
  import VirtualScrollShell from '../VirtualScrollShell.svelte';
  import RowActionSheet from '../RowActionSheet.svelte';
  import type { AdapterResultsProps } from '../types.ts';
  import { Check, Copy } from 'lucide-svelte';

  let { host }: AdapterResultsProps = $props();

  interface VisibleLogRow {
    idx: number;
    key: string;
    item: HitItem;
    srcName: string;
    showSrc: boolean;
    fileChanged: boolean;
    dirLabel: string;
    fileName: string;
    timeLabel: string;
    timeFull: string;
    lines: number;
    height: number;
  }

  let copiedIdx = $state<number>(-1);
  let scrollTop = $state<number>(0);
  let viewportHeight = $state<number>(720);
  let scrollerWidth = $state<number>(960);

  const targetLines = $derived(host.wordWrap ? Math.max(1, Math.min(6, host.previewLines)) : 1);
  const previewCharBudget = $derived(Math.max(240, targetLines * 180));

  const streamLayout = $derived.by(() => {
    const fontPx = host.codeFontSize;
    const lineHeight = Math.round(fontPx * 1.56);
    const baseHitPad = host.resultDensity === 'compact' ? 12 : 18;
    const availTextWidth = Math.max(240, scrollerWidth - (host.isCompact ? 48 : 72));
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
      ctx,
      budget: previewCharBudget,
      getLineProbe: getCachedPlainProbe,
    });
    return { ...layout, lineHeight };
  });

  const visibleSlice = $derived.by(() => {
    const { offsets, lines, lineHeight, totalHeight } = streamLayout;
    const hits = host.hits;
    const hLen = hits.length;
    if (hLen === 0) {
      return {
        items: [] as VisibleLogRow[],
        offsetY: 0,
        totalHeight: 0,
        lineHeight,
      };
    }

    const minY = Math.max(0, scrollTop - host.overscanPx);
    const maxY = scrollTop + Math.max(400, viewportHeight) + host.overscanPx;
    const firstIdx = indexAtY(offsets, hLen, minY);
    const lastIdx = indexAtY(offsets, hLen, maxY);

    const items: VisibleLogRow[] = [];
    for (let i = firstIdx; i <= lastIdx; i++) {
      const it = hits[i];
      const meta = getCachedParsedLog(it);
      const prevFile = i > 0 ? hits[i - 1].file : '';
      const prevSlash = prevFile.indexOf('/');
      const prevSrc = prevSlash > 0 ? prevFile.slice(0, prevSlash) : '';
      items.push({
        idx: i,
        key: `${i}:${it.file}:${it.line}:${it.col}`,
        item: it,
        srcName: meta.srcName,
        showSrc: i === 0 || meta.srcName !== prevSrc,
        fileChanged: i === 0 || it.file !== prevFile,
        dirLabel: meta.dirLabel,
        fileName: meta.fileName,
        timeLabel: meta.timeLabel,
        timeFull: meta.timeFull || meta.timeRaw,
        lines: lines[i],
        height: offsets[i + 1] - offsets[i],
      });
    }

    return {
      items,
      offsetY: offsets[firstIdx],
      totalHeight,
      lineHeight,
    };
  });

  let pressedIdx = $state<number>(-1);
  let pointerDownSelectedIdx = -1;
  let menuRow = $state.raw<VisibleLogRow | null>(null);
  let pressTimer: ReturnType<typeof setTimeout> | null = null;
  let pressOrigin: { x: number; y: number } | null = null;
  let suppressClick = false;

  function cancelPress() {
    pressedIdx = -1;
    if (pressTimer !== null) clearTimeout(pressTimer);
    pressTimer = null;
    pressOrigin = null;
  }

  function onRowPointerDown(e: PointerEvent, row: VisibleLogRow) {
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
        if (!host.isCompact && host.rightInspectorOpen && host.inspectedPath) {
          pointerDownSelectedIdx = row.idx;
          host.selectHitByIndex(row.idx, false);
        } else {
          host.previewSelectHitByIndex(row.idx);
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

  function handleRowClick(e: MouseEvent, row: VisibleLogRow) {
    if (suppressClick) {
      suppressClick = false;
      pointerDownSelectedIdx = -1;
      return;
    }
    const handledOnDown = pointerDownSelectedIdx === row.idx && e.detail > 0;
    pointerDownSelectedIdx = -1;
    if (handledOnDown) return;
    if (!host.isCompact && !host.isTouch) {
      const sel = window.getSelection()?.toString() ?? '';
      if (sel.length > 0) return;
    }
    host.selectHitByIndex(row.idx, true);
  }

  function handleRowKeydown(e: KeyboardEvent, row: VisibleLogRow) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      host.selectHitByIndex(row.idx, true);
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
      {
        id: 'context',
        iconKind: 'context',
        label: host.t.inspector.contextDrawerTitle,
        title: host.t.inspector.openContextTitle,
        run: () => host.openContextDrawer(row.item.file, row.item.line, row.item.byteOffset),
      },
    ];
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

{#snippet renderSourceScopeChip(row: VisibleLogRow)}
  {#if row.showSrc && row.srcName}
    {#if host.isCompact}
      <span class="shrink-0 text-muted-foreground/80">{row.srcName}</span>
    {:else}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={(e) => {
          e.stopPropagation();
          if (e.altKey) host.excludeSource(row.srcName);
          else if (e.metaKey || e.ctrlKey || e.shiftKey) host.toggleSource(row.srcName);
          else host.soloSource(row.srcName);
        }}
        title={host.t.ui.onlyInSourceTitle(row.srcName)}
        class="touch-target shrink-0 rounded text-muted-foreground/80 hover:text-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-primary/50 cursor-pointer"
      >
        {row.srcName}
      </button>
    {/if}
  {/if}
{/snippet}

<div class="flex flex-1 min-h-0 flex-col overflow-clip">
  <VirtualScrollShell
    totalHeight={visibleSlice.totalHeight}
    offsetY={visibleSlice.offsetY}
    offsets={streamLayout.offsets}
    activeVirtualIdx={host.activeHitIndex}
    scrollResetKey={host.currentSearchId}
    scrollToActiveTick={host.scrollToActiveTick}
    codeFontSize={host.codeFontSize}
    canPullRefresh={host.hasExecutableQuery && !host.isSearching}
    bind:scrollTop
    bind:viewportHeight
    bind:scrollerWidth
    onRefresh={() => host.refreshSearch(true)}
  >
    {#each visibleSlice.items as row (row.key)}
      {@const item = row.item}
      {@const active = row.idx === host.activeHitIndex}
      {@const pressed = pressedIdx === row.idx}
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
            if (host.isCompact || host.isTouch) e.preventDefault();
          }}
          onclick={(e) => handleRowClick(e, row)}
          onkeydown={(e) => handleRowKeydown(e, row)}
          class={`group ${host.isTouch ? 'select-none' : ''} flex h-full flex-col justify-center gap-0.5 px-3 cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary/50 overflow-hidden rounded-lg ${
            active
              ? 'bg-secondary/90 ring-1 ring-inset ring-primary/35 shadow-[inset_2.5px_0_0_hsl(var(--primary))]'
              : pressed
                ? 'bg-secondary/65'
                : 'hover:bg-secondary/40 active:bg-secondary/60'
          }`}
        >
          <div class="flex shrink-0 items-center justify-between gap-3 select-none" style={`height: ${LINE_BREADCRUMB_H - 4}px`}>
            <div class="flex items-center gap-1.5 min-w-0 font-mono text-[11px] leading-none">
              {@render renderSourceScopeChip(row)}
              {#if row.fileChanged}
                <span class="min-w-0 truncate" title={item.file}>
                  <span class="text-muted-foreground/75">{row.dirLabel}</span><span class={active ? 'text-foreground' : 'text-foreground/85'}>{row.fileName}</span><span class="text-muted-foreground/75">:{item.line}</span>
                </span>
              {:else}
                <span class={`shrink-0 tabular-nums ${active ? 'text-foreground/85' : 'text-muted-foreground/75'}`} title={item.file}>:{item.line}</span>
              {/if}
              {#if row.timeLabel}
                <span title={row.timeFull} class="shrink-0 text-muted-foreground/80 tabular-nums">
                  {row.timeLabel}
                </span>
              {/if}
            </div>

            <button
              type="button"
              title={host.t.ui.copyContent}
              onclick={(e) => copyLineText(e, row.idx, item.text)}
              aria-label={host.t.ui.copyContent}
              class="touch-target shrink-0 rounded p-1 text-muted-foreground/70 hover:text-foreground focus-visible:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 cursor-pointer"
            >
              {#if copiedIdx === row.idx}
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
      </div>
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
