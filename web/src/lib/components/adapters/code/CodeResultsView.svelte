<script lang="ts">
  import { flushSync } from 'svelte';
  import type { HitItem } from '$lib/types';
  import {
    CodeStreamStatsTracker,
    buildCodeVirtualLayout,
    getCachedPlainMeta,
    getCachedPlainProbe,
    indexAtY,
    type CodeStreamStats,
    type CodeVirtualItem,
    type RowActionItem,
    type RowMeasureContext,
  } from '$lib/adapters/index.ts';
  import {
    getCachedHighlightSegments,
    highlightCodeWithMatches,
    syntaxKindToClass,
    type CodeHighlightSegment,
  } from '$lib/utils';
  import VirtualScrollShell from '../VirtualScrollShell.svelte';
  import RowActionSheet from '../RowActionSheet.svelte';
  import CodeSummaryStrip from './CodeSummaryStrip.svelte';
  import type { AdapterResultsProps } from '../types.ts';
  import { Check, ChevronDown, ChevronRight, Copy, UnfoldVertical } from 'lucide-svelte';

  let { host }: AdapterResultsProps = $props();

  let copiedKey = $state<string>('');
  let scrollTop = $state<number>(0);
  let viewportHeight = $state<number>(720);
  let scrollerWidth = $state<number>(960);

  // View-local instant filters (0ms, zero query chain mutation, reset on new search)
  let activeLangFilter = $state<string | null>(null);
  let activeDirFilter = $state<string | null>(null);

  $effect(() => {
    void host.currentSearchId;
    activeLangFilter = null;
    activeDirFilter = null;
  });

  const statsTracker = new CodeStreamStatsTracker();
  const codeStats = $derived<CodeStreamStats>(statsTracker.update(host.hits));

  const targetLines = $derived(host.wordWrap ? Math.max(1, Math.min(3, host.previewLines)) : 1);
  const previewCharBudget = $derived(Math.max(240, targetLines * 180));

  const streamLayout = $derived.by(() => {
    const fontPx = host.codeFontSize;
    const lineHeight = Math.round(fontPx * 1.56);
    const baseHitPad = host.resultDensity === 'compact' ? 8 : 12;
    const availTextWidth = Math.max(220, scrollerWidth - (host.isCompact ? 92 : 120));
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

    const layout = buildCodeVirtualLayout({
      hits: host.hits,
      collapsedFiles: host.collapsedFiles,
      activeLangFilter,
      activeDirFilter,
      ctx,
      budget: previewCharBudget,
      getPlainMeta: getCachedPlainMeta,
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
    const { items, offsets, lineHeight, totalHeight } = streamLayout;
    const vLen = items.length;
    if (vLen === 0) {
      return {
        items: [] as CodeVirtualItem[],
        offsetY: 0,
        totalHeight: 0,
        lineHeight,
      };
    }

    const minY = Math.max(0, scrollTop - host.overscanPx);
    const maxY = scrollTop + Math.max(400, viewportHeight) + host.overscanPx;
    const firstV = indexAtY(offsets, vLen, minY);
    const lastV = indexAtY(offsets, vLen, maxY);

    return {
      items: items.slice(firstV, lastV + 1),
      offsetY: offsets[firstV],
      totalHeight,
      lineHeight,
    };
  });

  // WeakMap-memoized syntax + match highlighted code segments per HitItem
  const codeHighlightCache = new WeakMap<
    HitItem,
    { key: string; segs: CodeHighlightSegment[] }
  >();

  const isCaseInsensitive = true;
  const isRegexMode = $derived(host.searchMode === 'regex');
  const segmentCacheKey = $derived(
    `${host.searchMode}:${host.primaryPattern}\u0001${host.contains.join('\u0001')}\u0001${previewCharBudget}`
  );

  function getCachedCodeSegments(item: HitItem): CodeHighlightSegment[] {
    const cached = codeHighlightCache.get(item);
    if (cached && cached.key === segmentCacheKey) return cached.segs;

    const matchSegs = getCachedHighlightSegments(
      item,
      host.contains,
      isCaseInsensitive,
      segmentCacheKey,
      host.primaryPattern,
      isRegexMode,
      previewCharBudget
    );
    const snippet = matchSegs.map((s) => s.text).join('');
    const segs = highlightCodeWithMatches(snippet, matchSegs);
    codeHighlightCache.set(item, { key: segmentCacheKey, segs });
    return segs;
  }

  function flashCopy(e: MouseEvent, key: string, text: string) {
    e.stopPropagation();
    host.copyText(text);
    copiedKey = key;
    setTimeout(() => {
      if (copiedKey === key) copiedKey = '';
    }, 1400);
  }

  // Long-press & mouse interaction
  type HitVirtualRow = Extract<CodeVirtualItem, { kind: 'hit' }>;
  let pressedIdx = $state<number>(-1);
  let pointerDownSelectedIdx = -1;
  let menuRow = $state.raw<HitVirtualRow | null>(null);
  let pressTimer: ReturnType<typeof setTimeout> | null = null;
  let pressOrigin: { x: number; y: number } | null = null;
  let suppressClick = false;

  function cancelPress() {
    pressedIdx = -1;
    if (pressTimer !== null) clearTimeout(pressTimer);
    pressTimer = null;
    pressOrigin = null;
  }

  function onHitPointerDown(e: PointerEvent, row: HitVirtualRow) {
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

  function onHitPointerMove(e: PointerEvent) {
    if (!pressOrigin) return;
    if (Math.abs(e.clientX - pressOrigin.x) > 8 || Math.abs(e.clientY - pressOrigin.y) > 8) {
      cancelPress();
    }
  }

  function handleHitClick(e: MouseEvent, row: HitVirtualRow) {
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

  function handleHitKeydown(e: KeyboardEvent, row: HitVirtualRow) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      host.selectHitByIndex(row.hitIdx, true);
    }
  }

  function toggleLang(langId: string) {
    activeLangFilter = activeLangFilter === langId ? null : langId;
  }

  function toggleDir(dir: string) {
    activeDirFilter = activeDirFilter === dir ? null : dir;
  }

  function clearLocalFilters() {
    activeLangFilter = null;
    activeDirFilter = null;
  }

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
        id: 'copy-path',
        iconKind: 'copy-path',
        label: host.t.codeView.copyPathLine,
        title: host.t.codeView.copyPathLine,
        run: () => host.copyText(`${row.item.file}:${row.item.line}`),
      },
      {
        id: 'context',
        iconKind: 'context',
        accent: true,
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

{#snippet renderCodeSegments(segments: CodeHighlightSegment[])}
  {#each segments as seg}
    {#if seg.matchKind === 'primary'}
      <mark class="match-span-primary">{seg.text}</mark>
    {:else if seg.matchKind === 'contains-0'}
      <mark class="match-span-contains-0">{seg.text}</mark>
    {:else if seg.matchKind === 'contains-1'}
      <mark class="match-span-contains-1">{seg.text}</mark>
    {:else if seg.matchKind === 'contains-2'}
      <mark class="match-span-contains-2">{seg.text}</mark>
    {:else if seg.syntaxKind !== 'plain'}
      <span class={syntaxKindToClass(seg.syntaxKind)}>{seg.text}</span>
    {:else}
      <span>{seg.text}</span>
    {/if}
  {/each}
{/snippet}

{#snippet renderFileHeader(row: Extract<CodeVirtualItem, { kind: 'file-header' }>)}
  <div
    class="group flex h-full items-center justify-between gap-2 pt-1.5 select-none"
  >
    <div
      role="button"
      tabindex="0"
      aria-expanded={!row.collapsed}
      onclick={() => host.toggleFileGroupCollapse(row.file)}
      onkeydown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          host.toggleFileGroupCollapse(row.file);
        }
      }}
      class="flex h-[28px] min-w-0 flex-1 items-center justify-between gap-2 rounded-lg border border-border/45 bg-card/60 px-2.5 hover:bg-secondary/60 cursor-pointer focus:outline-none"
    >
      <div class="flex min-w-0 items-center gap-1.5 font-mono text-[11.5px] leading-none">
        {#if row.collapsed}
          <ChevronRight class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
        {:else}
          <ChevronDown class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
        {/if}

        {#if row.showSrc && row.srcName}
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
            class="shrink-0 rounded bg-secondary/75 px-1.5 py-0.5 text-[10px] text-muted-foreground hover:text-foreground cursor-pointer"
          >
            {row.srcName}
          </button>
        {/if}

        <span class="min-w-0 truncate" title={row.file}>
          <span class="text-muted-foreground/55">{row.dirLabel}</span><span class="font-medium text-foreground">{row.fileName}</span>
        </span>

        {#if row.lang}
          <span class="hidden sm:inline-flex shrink-0 rounded bg-secondary/50 px-1 py-0.5 text-[9.5px] text-muted-foreground/75">
            {row.lang.ext}
          </span>
        {/if}
      </div>

      <div class="flex shrink-0 items-center gap-1 font-mono text-[10.5px]">
        <button
          type="button"
          title={host.t.results.copyPathTitle}
          aria-label={host.t.results.copyPathTitle}
          onclick={(e) => flashCopy(e, `path:${row.file}`, row.file)}
          class="touch-target rounded p-1 text-muted-foreground/55 hover:text-foreground opacity-0 group-hover:opacity-100 focus:opacity-100 cursor-pointer"
        >
          {#if copiedKey === `path:${row.file}`}
            <Check class="h-3 w-3 text-primary" />
          {:else}
            <Copy class="h-3 w-3" />
          {/if}
        </button>

        <button
          type="button"
          title={host.t.codeView.openFullContext}
          aria-label={host.t.codeView.openFullContext}
          onclick={(e) => {
            e.stopPropagation();
            const firstHit = host.hits[row.firstHitIdx];
            if (firstHit) {
              host.openContextDrawer(firstHit.file, firstHit.line, firstHit.byteOffset);
            }
          }}
          class="touch-target hidden sm:inline-flex rounded p-1 text-muted-foreground/55 hover:text-foreground opacity-0 group-hover:opacity-100 focus:opacity-100 cursor-pointer"
        >
          <UnfoldVertical class="h-3 w-3" />
        </button>

        <span
          class="inline-flex h-4 min-w-[20px] items-center justify-center rounded bg-secondary/75 px-1.5 text-[10px] font-medium tabular-nums text-muted-foreground"
        >
          {row.matchCount}
        </span>
      </div>
    </div>
  </div>
{/snippet}

{#snippet renderCodeHit(row: HitVirtualRow, active: boolean, pressed: boolean)}
  {@const segs = getCachedCodeSegments(row.item)}
  <div
    role="button"
    tabindex="0"
    onpointerdown={(e) => onHitPointerDown(e, row)}
    onpointermove={onHitPointerMove}
    onpointerup={cancelPress}
    onpointercancel={cancelPress}
    oncontextmenu={(e) => {
      if (host.isCompact || host.isTouch) e.preventDefault();
    }}
    onclick={(e) => handleHitClick(e, row)}
    onkeydown={(e) => handleHitKeydown(e, row)}
    class={`group ${host.isTouch ? 'select-none' : ''} flex h-full items-stretch cursor-pointer focus:outline-none overflow-hidden rounded-md ml-1.5 ${
      active
        ? 'bg-secondary/90 ring-1 ring-inset ring-primary/35 shadow-[inset_2.5px_0_0_hsl(var(--primary))]'
        : pressed
          ? 'bg-secondary/65'
          : 'hover:bg-secondary/40 active:bg-secondary/60'
    }`}
  >
    <div
      class={`flex w-11 shrink-0 items-start justify-end border-r border-border/35 pr-2.5 font-mono text-[11px] tabular-nums select-none ${
        host.resultDensity === 'compact' ? 'pt-1' : 'pt-1.5'
      } ${active ? 'text-primary font-semibold' : 'text-muted-foreground/55'}`}
    >
      {row.item.line}
    </div>

    <div
      class={`flex min-w-0 flex-1 items-start justify-between gap-2 pl-2.5 pr-1.5 ${
        host.resultDensity === 'compact' ? 'py-1' : 'py-1.5'
      }`}
    >
      <div class="min-w-0 flex-1 overflow-hidden">
        {#if host.wordWrap && row.lines > 1}
          <div
            style={`line-height: ${visibleSlice.lineHeight}px; max-height: ${row.lines * visibleSlice.lineHeight}px; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: ${row.lines}; overflow: hidden;`}
            class="whitespace-pre-wrap break-all font-mono text-foreground"
          >
            {@render renderCodeSegments(segs)}
          </div>
        {:else}
          <div
            style={`line-height: ${visibleSlice.lineHeight}px;`}
            class="truncate whitespace-pre font-mono text-foreground"
          >
            {@render renderCodeSegments(segs)}
          </div>
        {/if}
      </div>

      <button
        type="button"
        title={host.t.ui.copyContent}
        onclick={(e) => flashCopy(e, `hit:${row.hitIdx}`, row.item.text)}
        aria-label={host.t.ui.copyContent}
        class="touch-target shrink-0 rounded p-1 text-muted-foreground/60 hover:text-foreground opacity-0 group-hover:opacity-100 focus:opacity-100"
      >
        {#if copiedKey === `hit:${row.hitIdx}`}
          <Check class="h-3.5 w-3.5 text-primary" />
        {:else}
          <Copy class="h-3.5 w-3.5" />
        {/if}
      </button>
    </div>
  </div>
{/snippet}

<div class="flex flex-1 min-h-0 flex-col overflow-clip">
  <CodeSummaryStrip
    stats={codeStats}
    {host}
    {activeLangFilter}
    {activeDirFilter}
    matchedHitCount={streamLayout.matchedHitCount}
    allCollapsed={streamLayout.allCollapsed}
    onToggleLang={toggleLang}
    onToggleDir={toggleDir}
    onClearLocalFilters={clearLocalFilters}
    onToggleCollapseAll={() => host.setAllGroupsCollapsed(!streamLayout.allCollapsed)}
  />

  <VirtualScrollShell
    totalHeight={visibleSlice.totalHeight}
    offsetY={visibleSlice.offsetY}
    offsets={streamLayout.offsets}
    {activeVirtualIdx}
    scrollResetKey={`${host.currentSearchId}:${activeLangFilter ?? ''}:${activeDirFilter ?? ''}`}
    scrollToActiveTick={host.scrollToActiveTick}
    codeFontSize={host.codeFontSize}
    canPullRefresh={host.hasExecutableQuery && !host.isSearching}
    bind:scrollTop
    bind:viewportHeight
    bind:scrollerWidth
    onRefresh={() => host.refreshSearch(true)}
  >
    {#each visibleSlice.items as row (row.key)}
      <div style={`height: ${row.height}px`} class="virtual-row-strict box-border overflow-hidden">
        {#if row.kind === 'file-header'}
          {@render renderFileHeader(row)}
        {:else}
          {@render renderCodeHit(row, row.hitIdx === host.activeHitIndex, pressedIdx === row.hitIdx)}
        {/if}
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
