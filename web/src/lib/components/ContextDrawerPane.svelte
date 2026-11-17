<script lang="ts">
  import { onDestroy, untrack } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import {
    computeMergedContextBounds,
    formatContextRangeBadge,
    resolveContextLoadCooldownMs,
  } from '$lib/context-window';
  import {
    buildHighlightSegments,
    copyTextToClipboard,
    formatContextRecordPretty,
    highlightCodeWithMatches,
    splitFilePath,
    syntaxKindToClass,
    type CodeHighlightSegment,
  } from '$lib/utils';
  import DrawerTemplate from './ui/DrawerTemplate.svelte';
  import {
    ArrowDown,
    ArrowUp,
    Braces,
    Check,
    Copy,
    FileText,
    Loader2,
    LocateFixed,
    UnfoldVertical,
  } from 'lucide-svelte';

  const NEAR_EDGE_PX = 28;

  let bodyEl = $state<HTMLDivElement | null>(null);
  let copiedAll = $state(false);
  let copiedAllTimer: ReturnType<typeof setTimeout> | null = null;
  const prettyMode = $derived(workbench.contextPrettyMode);

  onDestroy(() => {
    if (copiedAllTimer !== null) clearTimeout(copiedAllTimer);
  });

  let lastCenteredTick = 0;
  let suppressScrollUntil = 0;
  let nextAutoLoadAt = 0;

  const ins = $derived(workbench.t.inspector);
  const pathMeta = $derived(splitFilePath(workbench.contextPath || ''));
  const fileTitle = $derived(pathMeta.fileName || ins.contextDrawerTitle);

  const bounds = $derived(
    computeMergedContextBounds(
      workbench.contextLines,
      workbench.contextTotalLines,
      workbench.contextEof
    )
  );
  const rangeBadge = $derived(
    formatContextRangeBadge(bounds.firstLine, bounds.lastLine, bounds.totalLines)
  );
  const stepUpCount = $derived(
    bounds.firstLine > 1 ? Math.min(workbench.contextStepLines, bounds.firstLine - 1) : 0
  );
  const stepDownCount = $derived(
    bounds.totalLines > 0 && bounds.lastLine > 0
      ? Math.max(0, Math.min(workbench.contextStepLines, bounds.totalLines - bounds.lastLine))
      : workbench.contextStepLines
  );

  const isRegexMode = $derived(workbench.mode === 'regex');
  const queryHighlightKey = $derived(
    `${workbench.mode}:${workbench.primaryPattern}\u0001${workbench.contains.join('\u0001')}`
  );

  let cacheKeySeen = '';
  const lineSegCache = new Map<string, CodeHighlightSegment[]>();

  function getLineSegments(lineNum: number, rawText: string): CodeHighlightSegment[] {
    const displayText = prettyMode ? formatContextRecordPretty(rawText) : rawText;
    if (!displayText) {
      return [{ text: '', matchKind: 'plain', syntaxKind: 'plain' }];
    }

    const hit = workbench.inspectedHit;
    if (
      !prettyMode &&
      lineNum === workbench.contextAnchorLine &&
      hit &&
      hit.file === workbench.contextPath &&
      hit.line === lineNum &&
      hit.text.length === displayText.length &&
      hit.spans?.length > 0
    ) {
      const matchSegs = buildHighlightSegments(
        displayText,
        hit.spans,
        workbench.contains,
        true,
        false,
        workbench.primaryPattern,
        isRegexMode
      );
      return highlightCodeWithMatches(displayText, matchSegs);
    }

    if (cacheKeySeen !== queryHighlightKey) {
      cacheKeySeen = queryHighlightKey;
      lineSegCache.clear();
    }
    const entryKey = `${prettyMode ? '1' : '0'}\u0000${rawText}`;
    if (displayText.length <= 4096) {
      const cached = lineSegCache.get(entryKey);
      if (cached) return cached;
    }

    const matchSegs = buildHighlightSegments(
      displayText,
      undefined,
      workbench.contains,
      true,
      false,
      workbench.primaryPattern,
      isRegexMode
    );
    const segs = highlightCodeWithMatches(displayText, matchSegs);
    if (displayText.length <= 4096) {
      if (lineSegCache.size >= 1024) {
        const oldest = lineSegCache.keys().next().value;
        if (oldest !== undefined) lineSegCache.delete(oldest);
      }
      lineSegCache.set(entryKey, segs);
    }
    return segs;
  }

  function scrollToAnchor(smooth = true) {
    const container = bodyEl;
    if (!container) return;
    const row = container.querySelector(
      `[data-ctx-line="${workbench.contextAnchorLine}"]`
    ) as HTMLElement | null;
    if (!row) return;
    // Adjust strictly on `container.scrollTop` (never `scrollIntoView`), preventing ancestor
    // viewport/wrapper scroll jumps when the drawer slides in via offscreen translate3d.
    const containerRect = container.getBoundingClientRect();
    const rowRect = row.getBoundingClientRect();
    const maxScroll = Math.max(0, container.scrollHeight - container.clientHeight);
    const rawTarget =
      container.scrollTop +
      (rowRect.top - containerRect.top) -
      (container.clientHeight - rowRect.height) / 2;
    const targetTop = Math.max(0, Math.min(maxScroll, rawTarget));
    suppressScrollUntil = performance.now() + (smooth ? 450 : 120);
    if (smooth) {
      container.scrollTo({ top: targetTop, behavior: 'smooth' });
    } else {
      container.scrollTop = targetTop;
    }
  }

  $effect(() => {
    const tick = workbench.contextCenterTick;
    const container = bodyEl;
    const count = workbench.contextLines.length;
    if (!tick || tick === lastCenteredTick || !container || count === 0) return;
    lastCenteredTick = tick;
    nextAutoLoadAt = 0;
    queueMicrotask(() => {
      scrollToAnchor(false);
    });
  });

  function captureUpwardAnchor(): (() => void) | undefined {
    const container = bodyEl;
    const anchorLineNum = untrack(() => bounds.firstLine);
    if (!container || anchorLineNum <= 0) return undefined;
    const rowEl = container.querySelector(
      `[data-ctx-line="${anchorLineNum}"]`
    ) as HTMLElement | null;
    if (!rowEl) return undefined;
    const beforeOffset = rowEl.getBoundingClientRect().top - container.getBoundingClientRect().top;
    return () => {
      const nextRow = container.querySelector(
        `[data-ctx-line="${anchorLineNum}"]`
      ) as HTMLElement | null;
      if (!nextRow) return;
      // Measure post-layout offset first (browsers with native scroll-anchoring may already
      // update container.scrollTop during layout), then apply remaining delta to current scrollTop.
      const afterOffset =
        nextRow.getBoundingClientRect().top - container.getBoundingClientRect().top;
      const delta = afterOffset - beforeOffset;
      suppressScrollUntil = performance.now() + 140;
      if (Math.abs(delta) > 0.5) {
        container.scrollTop += delta;
      }
    };
  }

  function isLoadingAny(): boolean {
    return (
      workbench.contextLoadingInitial ||
      workbench.contextLoadingBefore ||
      workbench.contextLoadingAfter
    );
  }

  async function maybeAutoLoad(direction: 'before' | 'after') {
    const now = performance.now();
    if (isLoadingAny() || now < suppressScrollUntil || now < nextAutoLoadAt) return;
    const b = untrack(() => bounds);
    if (direction === 'before' && !b.canLoadBefore) return;
    if (direction === 'after' && !b.canLoadAfter) return;

    const cooldown = resolveContextLoadCooldownMs(untrack(() => workbench.contextAutoLoadPace));
    nextAutoLoadAt = now + cooldown;
    await workbench.loadContextMore(
      direction,
      direction === 'before' ? captureUpwardAnchor : undefined
    );
    nextAutoLoadAt = Math.max(nextAutoLoadAt, performance.now() + Math.min(60, cooldown));
  }

  // Automatic paced loading when scrolling to either edge (wheel, touch swipe, or scrollbar).
  $effect(() => {
    const container = bodyEl;
    if (!container) return;

    let prevScrollTop = container.scrollTop;
    let touchRefY: number | null = null;

    const onScroll = () => {
      const curTop = container.scrollTop;
      const maxTop = Math.max(0, container.scrollHeight - container.clientHeight);
      const now = performance.now();
      if (maxTop > 4 && now >= suppressScrollUntil) {
        if (curTop < prevScrollTop && curTop <= NEAR_EDGE_PX) {
          void maybeAutoLoad('before');
        } else if (curTop > prevScrollTop && curTop >= maxTop - NEAR_EDGE_PX) {
          void maybeAutoLoad('after');
        }
      }
      prevScrollTop = curTop;
    };

    const onWheel = (e: WheelEvent) => {
      if (Math.abs(e.deltaY) < 1.5) return;
      const curTop = container.scrollTop;
      const maxTop = Math.max(0, container.scrollHeight - container.clientHeight);
      if (e.deltaY < 0 && curTop <= NEAR_EDGE_PX) {
        void maybeAutoLoad('before');
      } else if (e.deltaY > 0 && curTop >= maxTop - NEAR_EDGE_PX) {
        void maybeAutoLoad('after');
      }
    };

    const onTouchStart = (e: TouchEvent) => {
      touchRefY = e.touches.length === 1 ? e.touches[0].clientY : null;
    };

    const onTouchMove = (e: TouchEvent) => {
      if (touchRefY === null || e.touches.length !== 1) return;
      const y = e.touches[0].clientY;
      const curTop = container.scrollTop;
      const maxTop = Math.max(0, container.scrollHeight - container.clientHeight);
      if (curTop <= NEAR_EDGE_PX && y - touchRefY >= 14) {
        touchRefY = y;
        void maybeAutoLoad('before');
      } else if (curTop >= maxTop - NEAR_EDGE_PX && touchRefY - y >= 14) {
        touchRefY = y;
        void maybeAutoLoad('after');
      } else if (curTop > NEAR_EDGE_PX && curTop < maxTop - NEAR_EDGE_PX) {
        touchRefY = y;
      }
    };

    const onTouchEnd = () => {
      touchRefY = null;
    };

    container.addEventListener('scroll', onScroll, { passive: true });
    container.addEventListener('wheel', onWheel, { passive: true });
    container.addEventListener('touchstart', onTouchStart, { passive: true });
    container.addEventListener('touchmove', onTouchMove, { passive: true });
    container.addEventListener('touchend', onTouchEnd, { passive: true });
    container.addEventListener('touchcancel', onTouchEnd, { passive: true });

    return () => {
      container.removeEventListener('scroll', onScroll);
      container.removeEventListener('wheel', onWheel);
      container.removeEventListener('touchstart', onTouchStart);
      container.removeEventListener('touchmove', onTouchMove);
      container.removeEventListener('touchend', onTouchEnd);
      container.removeEventListener('touchcancel', onTouchEnd);
    };
  });

  function copyLoadedLines() {
    if (workbench.contextLines.length === 0) return;
    const content = workbench.contextLines
      .map((l) => (prettyMode ? formatContextRecordPretty(l.text) : l.text))
      .join('\n');
    void copyTextToClipboard(content);
    copiedAll = true;
    if (copiedAllTimer !== null) clearTimeout(copiedAllTimer);
    copiedAllTimer = setTimeout(() => {
      copiedAll = false;
      copiedAllTimer = null;
    }, 1500);
  }
</script>

{#snippet renderSegments(segments: CodeHighlightSegment[])}
  {#if segments.length === 1 && segments[0].matchKind === 'plain' && segments[0].syntaxKind === 'plain'}
    {segments[0].text || ' '}
  {:else}
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
        {seg.text}
      {/if}
    {/each}
  {/if}
{/snippet}

<DrawerTemplate
  icon={UnfoldVertical}
  title={fileTitle}
  badge={rangeBadge}
  bind:bodyEl
  bodyClass="px-2.5 md:px-4 py-3 overscroll-contain"
>
  {#snippet headerActions()}
    {#if workbench.contextLines.length > 0}
      <button
        type="button"
        title={ins.jumpToAnchorTitle}
        aria-label={ins.jumpToAnchorTitle}
        onclick={() => scrollToAnchor(true)}
        class="touch-target inline-flex h-7 items-center gap-1 rounded-md px-2 font-mono text-[11.5px] font-medium tabular-nums text-muted-foreground/85 hover:bg-secondary/70 hover:text-foreground active:bg-secondary cursor-pointer"
      >
        <LocateFixed class="h-3.5 w-3.5 text-primary" />
        <span>#{workbench.contextAnchorLine}</span>
      </button>
      <button
        type="button"
        aria-pressed={prettyMode}
        title={prettyMode ? ins.rawBtn : ins.formattedBtn}
        aria-label={prettyMode ? ins.rawBtn : ins.formattedBtn}
        onclick={() => (workbench.contextPrettyMode = !workbench.contextPrettyMode)}
        class={`touch-target flex h-7 w-7 items-center justify-center rounded-md cursor-pointer ${
          prettyMode
            ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35'
            : 'text-muted-foreground/75 hover:bg-secondary/70 hover:text-foreground active:bg-secondary'
        }`}
      >
        {#if prettyMode}
          <Braces class="h-3.5 w-3.5" />
        {:else}
          <FileText class="h-3.5 w-3.5" />
        {/if}
      </button>
      <button
        type="button"
        title={ins.copyContextTitle}
        aria-label={ins.copyContextTitle}
        onclick={copyLoadedLines}
        class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/70 hover:text-foreground active:bg-secondary cursor-pointer"
      >
        {#if copiedAll}
          <Check class="h-3.5 w-3.5 text-primary" />
        {:else}
          <Copy class="h-3.5 w-3.5" />
        {/if}
      </button>
    {/if}
  {/snippet}

  {#if workbench.contextLoadingInitial && workbench.contextLines.length === 0}
    <div class="flex h-full min-h-[220px] items-center justify-center gap-2 text-[13px] text-muted-foreground">
      <Loader2 class="h-4 w-4 animate-spin text-primary" />
      <span>{ins.loading}</span>
    </div>
  {:else if workbench.contextError && workbench.contextLines.length === 0}
    <div class="rounded-lg border border-status/30 bg-status/10 px-3 py-2 text-[13px] text-status">
      {workbench.contextError}
    </div>
  {:else if workbench.contextBinary}
    <div class="flex h-full min-h-[180px] items-center justify-center text-[13px] text-muted-foreground">
      {ins.binaryContextNotice}
    </div>
  {:else if workbench.contextLines.length === 0}
    <div class="flex h-full min-h-[180px] items-center justify-center text-[13px] text-muted-foreground">
      {ins.emptyPrompt}
    </div>
  {:else}
    <div class="space-y-2">
      {#if !bounds.canLoadBefore}
        <div
          data-ctx-cap="start"
          class="py-1 text-center font-mono text-[11px] text-muted-foreground/70 select-none"
        >
          {ins.reachedStart}
        </div>
      {:else if workbench.contextLoadingBefore}
        <div
          data-ctx-status="top"
          class="flex items-center justify-center gap-1.5 py-1 text-[11.5px] text-primary select-none"
        >
          <Loader2 class="h-3 w-3 animate-spin" />
          <span>{ins.loadingAbove(stepUpCount)}</span>
        </div>
      {:else}
        <div
          data-ctx-status="top"
          class="flex items-center justify-center gap-1.5 py-1 text-[11px] text-muted-foreground/70 select-none"
        >
          <ArrowUp class="h-3 w-3 opacity-70" />
          <span>{ins.autoLoadAboveHint(stepUpCount)}</span>
        </div>
      {/if}

      {#if workbench.contextError}
        <div class="rounded-lg border border-status/30 bg-status/10 px-3 py-1.5 text-xs text-status">
          {workbench.contextError}
        </div>
      {/if}

      <div
        style={`font-size: ${workbench.codeFontSize}px`}
        class="overflow-x-auto rounded-xl border border-border/50 bg-card/35 font-mono select-text"
      >
        <div class="divide-y divide-border/25">
          {#each workbench.contextLines as item (item.n)}
            {@const isAnchor = item.n === workbench.contextAnchorLine}
            <div
              data-ctx-line={item.n}
              class={`flex items-start gap-2.5 px-2.5 md:px-3 py-1 leading-[1.6] ${
                isAnchor
                  ? 'bg-primary/[0.08] shadow-[inset_2px_0_0_0_hsl(var(--primary))]'
                  : 'hover:bg-secondary/35'
              }`}
            >
              <span
                class={`w-12 shrink-0 pt-[1px] text-right font-mono text-[11px] tabular-nums select-none ${
                  isAnchor ? 'font-semibold text-primary' : 'text-muted-foreground/70'
                }`}
              >
                {item.n}
              </span>
              <span
                class={`min-w-0 flex-1 ${
                  workbench.wordWrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre'
                } ${isAnchor ? 'text-foreground' : 'text-foreground/90'}`}
              >
                {@render renderSegments(getLineSegments(item.n, item.text))}
              </span>
            </div>
          {/each}
        </div>
      </div>

      {#if !bounds.canLoadAfter}
        <div
          data-ctx-cap="end"
          class="py-1 text-center font-mono text-[11px] text-muted-foreground/70 select-none"
        >
          {ins.reachedEnd(bounds.totalLines)}
        </div>
      {:else if workbench.contextLoadingAfter}
        <div
          data-ctx-status="bottom"
          class="flex items-center justify-center gap-1.5 py-1 text-[11.5px] text-primary select-none"
        >
          <Loader2 class="h-3 w-3 animate-spin" />
          <span>{ins.loadingBelow(stepDownCount)}</span>
        </div>
      {:else}
        <div
          data-ctx-status="bottom"
          class="flex items-center justify-center gap-1.5 py-1 text-[11px] text-muted-foreground/70 select-none"
        >
          <ArrowDown class="h-3 w-3 opacity-70" />
          <span>{ins.autoLoadBelowHint(stepDownCount)}</span>
        </div>
      {/if}
    </div>
  {/if}
</DrawerTemplate>
