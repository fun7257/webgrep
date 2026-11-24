<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import {
    analyzeStructuredLine,
    buildHighlightSegments,
    extractLeadingNanoTimestamp,
    syntaxKindToClass,
    type CodeHighlightSegment,
    type HighlightSegment,
  } from '$lib/utils';
  import { Loader2 } from 'lucide-svelte';
  import InspectorHeader from './inspector/InspectorHeader.svelte';
  import { createWorkbenchAdapterHost } from './adapters/types.ts';
  import { getPresentationAdapter } from './adapters/registry.ts';

  const host = createWorkbenchAdapterHost();
  const activeAdapter = $derived(getPresentationAdapter(workbench.activeInspectorAdapter));

  let asideEl = $state<HTMLElement | null>(null);
  let scrollContainerEl = $state<HTMLDivElement | null>(null);
  let selectedText = $state<string>('');

  let activeHit = $derived(workbench.inspectedHit ?? workbench.activeHit);
  let targetLine = $derived(activeHit?.line ?? workbench.inspectedLine);
  let fileData = $derived(workbench.inspectedFile);
  let inspectedProject = $derived.by(() => {
    const p = workbench.inspectedPath || '';
    const slash = p.indexOf('/');
    return slash > 0 ? p.slice(0, slash) : '';
  });
  let inspectedSubPath = $derived.by(() => {
    const p = workbench.inspectedPath || '';
    const slash = p.indexOf('/');
    return slash > 0 ? p.slice(slash + 1) : p;
  });

  // Prefer the full untruncated line from /api/file once loaded; fall back to streaming hit text immediately.
  let activeLineText = $derived.by(() => {
    const fromFile =
      fileData && fileData.path === workbench.inspectedPath
        ? fileData.lines.find((l) => l.n === targetLine)?.text
        : undefined;
    if (fromFile !== undefined && fromFile.length > 0) {
      return fromFile;
    }
    if (activeHit && activeHit.file === workbench.inspectedPath) {
      return activeHit.text;
    }
    return fromFile ?? '';
  });

  // Case sensitivity is expressed per term (`$c(…)` wire terms), never globally.
  const isCaseInsensitive = true;
  let isRegexMode = $derived(workbench.mode === 'regex');

  let structuredInfo = $derived(analyzeStructuredLine(activeLineText));
  let hasStructuredDiff = $derived.by(() => {
    if (!activeAdapter.supportsStructuredToggle || !activeLineText) return false;
    if (
      structuredInfo.kind === 'json' ||
      structuredInfo.kind === 'embedded-json' ||
      structuredInfo.kind === 'kv'
    ) {
      return true;
    }
    return Boolean(structuredInfo.timeHint) || Boolean(extractLeadingNanoTimestamp(activeLineText));
  });
  let recordKey = $derived(`${workbench.inspectedPath ?? ''}:${targetLine}`);

  // Reset scroll position when switching to another hit/record.
  $effect(() => {
    void recordKey;
    if (scrollContainerEl) {
      scrollContainerEl.scrollTop = 0;
    }
  });

  const hasRegexOrAnchorPrimary = $derived(
    isRegexMode ||
      workbench.primaryPattern.includes('$r') ||
      workbench.primaryPattern.includes('^') ||
      workbench.primaryPattern.includes('$')
  );

  const anchorFallbackNeedles = $derived.by(() => {
    if (!hasRegexOrAnchorPrimary || !activeHit?.spans || activeHit.spans.length === 0) {
      return [] as { exact: string; lower: string }[];
    }
    const seen = new Set<string>();
    const out: { exact: string; lower: string }[] = [];
    for (const sp of activeHit.spans) {
      const sub = activeHit.text.slice(sp.start, sp.end);
      if (!sub) continue;
      const norm = isCaseInsensitive ? sub.toLowerCase() : sub;
      if (seen.has(norm)) continue;
      seen.add(norm);
      out.push({ exact: sub, lower: norm });
      if (out.length >= 8) break;
    }
    return out;
  });

  const queryHighlightKey = $derived.by(() => {
    const base = `${workbench.mode}:${workbench.primaryPattern}\u0001${workbench.contains.join('\u0001')}`;
    if (anchorFallbackNeedles.length === 0) return base;
    return `${base}\u0002${anchorFallbackNeedles.map((n) => n.exact).join('\u0001')}`;
  });

  let fieldCacheKey = '';
  const fieldHighlightCache = new Map<string, HighlightSegment[]>();

  function highlightFormattedText(text: string): HighlightSegment[] {
    if (!text) return [{ text: '', kind: 'plain' }];
    if (fieldCacheKey !== queryHighlightKey) {
      fieldCacheKey = queryHighlightKey;
      fieldHighlightCache.clear();
    }
    if (text.length <= 2048) {
      const cached = fieldHighlightCache.get(text);
      if (cached) return cached;
    }

    let segments = buildHighlightSegments(
      text,
      undefined,
      workbench.contains,
      isCaseInsensitive,
      false,
      workbench.primaryPattern,
      isRegexMode
    );

    if (
      anchorFallbackNeedles.length > 0 &&
      !segments.some((s) => s.kind === 'primary')
    ) {
      const fallbackSpans: { start: number; end: number }[] = [];
      const hay = isCaseInsensitive ? text.toLowerCase() : text;
      for (const item of anchorFallbackNeedles) {
        const needle = isCaseInsensitive ? item.lower : item.exact;
        let pos = 0;
        while (pos < hay.length) {
          const idx = hay.indexOf(needle, pos);
          if (idx === -1) break;
          fallbackSpans.push({ start: idx, end: idx + needle.length });
          pos = idx + Math.max(1, needle.length);
        }
      }
      if (fallbackSpans.length > 0) {
        segments = buildHighlightSegments(
          text,
          fallbackSpans,
          workbench.contains,
          isCaseInsensitive,
          false,
          workbench.primaryPattern,
          isRegexMode
        );
      }
    }

    if (text.length <= 2048) {
      if (fieldHighlightCache.size >= 512) {
        const oldest = fieldHighlightCache.keys().next().value;
        if (oldest !== undefined) fieldHighlightCache.delete(oldest);
      }
      fieldHighlightCache.set(text, segments);
    }
    return segments;
  }

  let rawLineSegments = $derived.by(() => {
    const canUseExactSpans =
      activeHit &&
      activeHit.file === workbench.inspectedPath &&
      activeHit.line === targetLine &&
      activeHit.text.length === activeLineText.length &&
      activeHit.spans?.length > 0;

    if (canUseExactSpans && activeHit) {
      return buildHighlightSegments(
        activeLineText,
        activeHit.spans,
        workbench.contains,
        isCaseInsensitive,
        false,
        workbench.primaryPattern,
        isRegexMode
      );
    }
    return highlightFormattedText(activeLineText);
  });

  function handleMouseUp() {
    const sel = window.getSelection()?.toString().trim() ?? '';
    selectedText = sel.length > 0 && sel.length <= 256 ? sel : '';
  }

  // Touch: there is no mouseup after a long-press selection; follow selectionchange instead.
  function handleSelectionChange() {
    if ((!workbench.isCompact && !workbench.isTouch) || !asideEl) return;
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || !sel.anchorNode || !asideEl.contains(sel.anchorNode)) {
      selectedText = '';
      return;
    }
    handleMouseUp();
  }

  function closeDetail() {
    workbench.detailOpen = false;
    if (!workbench.isCompact) workbench.rightInspectorOpen = false;
  }

  // Edge swipe (from left edge, rightwards) closes the full-screen detail view on mobile.
  let swipeStart: { x: number; y: number } | null = null;

  function onPointerDown(e: PointerEvent) {
    if (!workbench.isCompact || e.pointerType !== 'touch' || e.clientX > 32) return;
    swipeStart = { x: e.clientX, y: e.clientY };
  }

  function onPointerUp(e: PointerEvent) {
    if (!swipeStart) return;
    const dx = e.clientX - swipeStart.x;
    const dy = Math.abs(e.clientY - swipeStart.y);
    swipeStart = null;
    if (dx > 72 && dy < 48) closeDetail();
  }

  function clearSelectionText() {
    selectedText = '';
    window.getSelection()?.removeAllRanges();
  }

  function appendSelectedText() {
    if (!selectedText) return;
    workbench.appendSearchTerm(selectedText);
    clearSelectionText();
  }

  function excludeSelectedText() {
    if (!selectedText) return;
    workbench.excludeSearchTerm(selectedText);
    clearSelectionText();
  }

  function searchSelectedText() {
    if (!selectedText) return;
    workbench.replaceSearchWithLiteral(selectedText);
    clearSelectionText();
  }
</script>

{#snippet renderCodeSegments(segments: CodeHighlightSegment[])}
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

<svelte:document onselectionchange={handleSelectionChange} />

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<aside
  bind:this={asideEl}
  style={workbench.isCompact ? undefined : `width: ${workbench.rightInspectorWidth}px`}
  onmouseup={handleMouseUp}
  onpointerdown={onPointerDown}
  onpointerup={onPointerUp}
  class={`flex h-full flex-col bg-background overflow-hidden ${
    workbench.isCompact ? 'w-full pt-safe pb-safe' : 'shrink-0 border-l border-border/40'
  }`}
>
  <InspectorHeader
    {inspectedProject}
    {inspectedSubPath}
    {targetLine}
    anchorByteHint={activeHit &&
    activeHit.file === workbench.inspectedPath &&
    activeHit.line === targetLine
      ? activeHit.byteOffset
      : null}
    {selectedText}
    {activeLineText}
    showStructuredToggle={hasStructuredDiff}
    structuredFormattedText={activeAdapter.getFormattedCopyText?.(activeLineText, activeHit) ??
      structuredInfo.formattedText}
    onAppendSelection={appendSelectedText}
    onExcludeSelection={excludeSelectedText}
    onSearchSelection={searchSelectedText}
    onClearSelection={clearSelectionText}
    onClose={closeDetail}
  />

  <!-- Surface-Dispatched Inspector Canvas -->
  <div
    bind:this={scrollContainerEl}
    style={`font-size: ${workbench.codeFontSize}px`}
    class="flex-1 min-h-0 overflow-y-auto px-2.5 md:px-4 pb-6 pt-1 font-mono"
  >
    {#if workbench.inspectorLoading && !activeLineText}
      <div class="flex h-full items-center justify-center gap-2 text-[13px] text-muted-foreground">
        <Loader2 class="h-4 w-4 animate-spin text-primary" />
        <span>{workbench.t.inspector.loading}</span>
      </div>
    {:else if workbench.inspectorError && !activeLineText}
      <div class="text-[13px] text-status">
        {workbench.inspectorError}
      </div>
    {:else if !activeLineText}
      <div class="flex h-full items-center justify-center text-[13px] text-muted-foreground">
        {workbench.t.inspector.emptyPrompt}
      </div>
    {:else}
      {@const ActiveInspectorView = activeAdapter.InspectorView}
      <div class="rounded-xl border border-border/50 bg-card/35 overflow-hidden">
        <ActiveInspectorView
          {host}
          {activeHit}
          {activeLineText}
          {targetLine}
          inspectedPath={workbench.inspectedPath ?? ''}
          {fileData}
          loading={workbench.inspectorLoading}
          inspectorTab={workbench.inspectorTab}
          {recordKey}
          {structuredInfo}
          {rawLineSegments}
          {highlightFormattedText}
          {renderCodeSegments}
        />
      </div>
    {/if}
  </div>
</aside>
