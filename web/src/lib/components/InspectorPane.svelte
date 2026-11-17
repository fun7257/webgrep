<script lang="ts">
  import { flushSync, onDestroy } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import {
    analyzeStructuredLine,
    buildHighlightSegments,
    copyTextToClipboard,
    detectInlineEpochHint,
    extractLeadingNanoTimestamp,
    highlightCodeWithMatches,
    syntaxKindToClass,
    type CodeHighlightSegment,
    type HighlightSegment,
  } from '$lib/utils';
  import {
    ArrowLeft,
    Braces,
    Check,
    ChevronDown,
    ChevronRight,
    Copy,
    FileText,
    Loader2,
    Search,
    Share2,
    UnfoldVertical,
    X,
  } from 'lucide-svelte';

  let asideEl = $state<HTMLElement | null>(null);
  let scrollContainerEl = $state<HTMLDivElement | null>(null);
  let selectedText = $state<string>('');
  let copiedLine = $state<boolean>(false);
  let copiedShare = $state<boolean>(false);
  let copiedLineTimer: ReturnType<typeof setTimeout> | null = null;
  let copiedShareTimer: ReturnType<typeof setTimeout> | null = null;
  let collapsedJsonPaths = $state<Record<string, boolean>>({});
  let copiedFieldPath = $state<string>('');
  let hoveredFieldPath = $state<string>('');
  let tabToggledOnDown = false;

  onDestroy(() => {
    if (copiedLineTimer !== null) clearTimeout(copiedLineTimer);
    if (copiedShareTimer !== null) clearTimeout(copiedShareTimer);
  });

  let activeHit = $derived(workbench.inspectedHit ?? workbench.activeHit);
  let targetLine = $derived(activeHit?.line ?? workbench.inspectedLine);
  let fileData = $derived(workbench.inspectedFile);
  let alwaysShowFieldActions = $derived(workbench.isTouch || workbench.isCompact);
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
  let leadingTs = $derived(extractLeadingNanoTimestamp(activeLineText));
  let cleanPlainText = $derived(
    leadingTs && leadingTs.restText.length > 0 ? leadingTs.restText : activeLineText
  );

  // Reset scroll, hover, and collapse state when switching to another hit/record
  $effect(() => {
    const _path = workbench.inspectedPath;
    const _line = targetLine;
    void _path;
    void _line;
    collapsedJsonPaths = {};
    hoveredFieldPath = '';
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

  function toggleInspectorTab() {
    workbench.inspectorTab = workbench.inspectorTab === 'raw' ? 'structured' : 'raw';
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

  function appendSelectedText() {
    if (!selectedText) return;
    workbench.appendSearchTerm(selectedText);
    selectedText = '';
    window.getSelection()?.removeAllRanges();
  }

  function excludeSelectedText() {
    if (!selectedText) return;
    workbench.excludeSearchTerm(selectedText);
    selectedText = '';
    window.getSelection()?.removeAllRanges();
  }

  function searchSelectedText() {
    if (!selectedText) return;
    workbench.replaceSearchWithLiteral(selectedText);
    selectedText = '';
    window.getSelection()?.removeAllRanges();
  }

  function copyCurrentContent() {
    if (!activeLineText) return;
    const textToCopy =
      workbench.inspectorTab === 'structured'
        ? structuredInfo.formattedText || activeLineText
        : activeLineText;
    void copyTextToClipboard(textToCopy);
    copiedLine = true;
    if (copiedLineTimer !== null) clearTimeout(copiedLineTimer);
    copiedLineTimer = setTimeout(() => {
      copiedLine = false;
      copiedLineTimer = null;
    }, 1500);
  }

  async function sharePreviewLink() {
    if (typeof window === 'undefined' || !workbench.inspectedPath) return;
    const url = workbench.buildPreviewShareUrl(window.location.href);
    const ok = await copyTextToClipboard(url);
    try {
      window.history.replaceState(window.history.state, '', url);
    } catch {
      // ignore history errors
    }
    if (!ok) return;
    copiedShare = true;
    if (copiedShareTimer !== null) clearTimeout(copiedShareTimer);
    copiedShareTimer = setTimeout(() => {
      copiedShare = false;
      copiedShareTimer = null;
    }, 1500);
  }

  function toggleJsonPath(path: string, e: MouseEvent) {
    e.stopPropagation();
    collapsedJsonPaths[path] = !collapsedJsonPaths[path];
  }

  function copyFieldValue(path: string, val: string, e: MouseEvent) {
    e.stopPropagation();
    copyTextToClipboard(val);
    copiedFieldPath = path;
    setTimeout(() => {
      if (copiedFieldPath === path) copiedFieldPath = '';
    }, 1200);
  }

  function isJsonObjectOrArray(val: unknown): val is Record<string, unknown> | unknown[] {
    return typeof val === 'object' && val !== null;
  }

  function getJsonEntries(val: Record<string, unknown> | unknown[]): [string, unknown][] {
    if (Array.isArray(val)) {
      return val.map((item, idx) => [String(idx), item]);
    }
    return Object.entries(val);
  }

  function summarizeCollapsedJson(val: Record<string, unknown> | unknown[]): string {
    if (Array.isArray(val)) {
      const preview = val
        .slice(0, 3)
        .map((v) => (typeof v === 'object' && v !== null ? '{…}' : String(v)))
        .join(', ');
      return `[ ${preview}${val.length > 3 ? `, … (${val.length})` : ''} ]`;
    }
    const entries = Object.entries(val);
    const preview = entries
      .slice(0, 3)
      .map(([k, v]) => `${k}: ${typeof v === 'object' && v !== null ? '{…}' : String(v)}`)
      .join(', ');
    return `{ ${preview}${entries.length > 3 ? `, … (${entries.length})` : ''} }`;
  }

  let hasStructuredExpansion = $derived(
    workbench.inspectorTab === 'structured' &&
      (structuredInfo.kind === 'json' ||
        structuredInfo.kind === 'embedded-json' ||
        structuredInfo.kind === 'kv' ||
        Boolean(structuredInfo.formatBadge))
  );
</script>

{#snippet renderSegments(segments: HighlightSegment[])}
  {#if segments.length === 1 && segments[0].kind === 'plain'}
    {segments[0].text}
  {:else}
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
  {/if}
{/snippet}

{#snippet renderHighlighted(text: string)}
  {@render renderSegments(highlightFormattedText(text))}
{/snippet}

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

{#snippet renderFieldActions(path: string, rawVal: string)}
  {#if rawVal.trim().length > 0 && rawVal.length <= 200}
    {#if alwaysShowFieldActions || hoveredFieldPath === path || copiedFieldPath === path}
      <span
        class={alwaysShowFieldActions
          ? 'flex items-center gap-0.5 shrink-0 select-none'
          : 'absolute right-1 top-0.5 z-10 flex items-center gap-0.5 rounded-md border border-border/60 bg-popover/95 px-1 py-0.5 shadow-sm select-none'}
      >
        <button
          type="button"
          title={workbench.t.inspector.includeTitle(rawVal)}
          aria-label={workbench.t.inspector.includeTitle(rawVal)}
          onclick={(e) => {
            e.stopPropagation();
            workbench.appendSearchTerm(rawVal);
          }}
          class="rounded px-1.5 py-0.5 text-[10px] font-semibold bg-secondary/70 text-foreground hover:bg-secondary active:bg-primary/20 cursor-pointer"
        >
          +
        </button>
        <button
          type="button"
          title={workbench.t.inspector.excludeTitle(rawVal)}
          aria-label={workbench.t.inspector.excludeTitle(rawVal)}
          onclick={(e) => {
            e.stopPropagation();
            workbench.excludeSearchTerm(rawVal);
          }}
          class="rounded px-1.5 py-0.5 text-[10px] font-semibold bg-secondary/60 text-muted-foreground hover:bg-secondary hover:text-foreground active:bg-status/20 cursor-pointer"
        >
          -
        </button>
        <button
          type="button"
          title={workbench.t.inspector.copyFieldTitle}
          aria-label={workbench.t.inspector.copyFieldTitle}
          onclick={(e) => copyFieldValue(path, rawVal, e)}
          class="rounded p-1 text-muted-foreground hover:bg-secondary hover:text-foreground active:bg-secondary cursor-pointer"
        >
          {#if copiedFieldPath === path}
            <Check class="h-3 w-3 text-primary" />
          {:else}
            <Copy class="h-3 w-3" />
          {/if}
        </button>
      </span>
    {/if}
  {/if}
{/snippet}

{#snippet renderJsonTree(node: unknown, path: string, depth: number)}
  {#if isJsonObjectOrArray(node)}
    {@const entries = getJsonEntries(node)}
    {@const isArray = Array.isArray(node)}
    {#if entries.length === 0}
      <span class="text-muted-foreground">{isArray ? '[]' : '{}'}</span>
    {:else}
      <div class={depth > 0 ? 'ml-2 border-l border-border/55 pl-3 space-y-0.5 my-0.5' : 'space-y-0.5'}>
        {#each entries as [k, v] (`${path}.${k}`)}
          {@const childPath = `${path}.${k}`}
          {#if isJsonObjectOrArray(v)}
            {@const childEntries = getJsonEntries(v)}
            {@const isCollapsed = Boolean(collapsedJsonPaths[childPath])}
            {#if childEntries.length === 0}
              <div class="flex items-baseline gap-2.5 rounded px-1.5 py-0.5">
                <span class="text-muted-foreground shrink-0 select-none text-[12px]">
                  {#if isArray}
                    <span class="text-muted-foreground/70">[{k}]</span>
                  {:else}
                    {@render renderHighlighted(k)}
                  {/if}
                </span>
                <span class="text-muted-foreground">{Array.isArray(v) ? '[]' : '{}'}</span>
              </div>
            {:else}
              <div>
                <button
                  type="button"
                  onclick={(e) => toggleJsonPath(childPath, e)}
                  class="flex w-full items-center gap-1.5 rounded px-1 py-0.5 text-left hover:bg-secondary/40 active:bg-secondary/65 cursor-pointer"
                >
                  {#if isCollapsed}
                    <ChevronRight class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                  {:else}
                    <ChevronDown class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                  {/if}
                  <span class="text-muted-foreground font-medium shrink-0 text-[12px]">
                    {#if isArray}
                      <span class="text-muted-foreground/70">[{k}]</span>
                    {:else}
                      {@render renderHighlighted(k)}
                    {/if}
                  </span>
                  <span class="rounded bg-secondary/55 px-1.5 py-0.2 text-[10px] text-muted-foreground">
                    {Array.isArray(v) ? `[${childEntries.length}]` : `{${childEntries.length}}`}
                  </span>
                  {#if isCollapsed}
                    <span class="truncate text-[11px] text-muted-foreground/70">
                      {summarizeCollapsedJson(v)}
                    </span>
                  {/if}
                </button>
                {#if !isCollapsed}
                  {@render renderJsonTree(v, childPath, depth + 1)}
                {/if}
              </div>
            {/if}
          {:else}
            {@const strVal = v === null ? 'null' : String(v)}
            {@const isMultiLineStr = typeof v === 'string' && v.includes('\n')}
            {@const numEpochHint =
              typeof v === 'number' || (typeof v === 'string' && /^\d{10,19}$/.test(v))
                ? detectInlineEpochHint(String(v))
                : null}
            <div
              role="group"
              onpointerenter={() => {
                if (!alwaysShowFieldActions) hoveredFieldPath = childPath;
              }}
              onpointerleave={() => {
                if (!alwaysShowFieldActions && hoveredFieldPath === childPath) hoveredFieldPath = '';
              }}
              class="relative flex items-start justify-between gap-2 rounded px-1.5 py-0.5 hover:bg-secondary/40"
            >
              <div class={`min-w-0 flex-1 ${isMultiLineStr ? 'space-y-1' : 'flex items-baseline gap-2.5'}`}>
                <span class="text-muted-foreground shrink-0 select-none text-[12px] min-w-[76px]">
                  {#if isArray}
                    <span class="text-muted-foreground/70">[{k}]</span>
                  {:else}
                    {@render renderHighlighted(k)}
                  {/if}
                </span>
                {#if isMultiLineStr}
                  <div class="rounded-md border border-border/45 bg-secondary/35 px-2.5 py-1.5 whitespace-pre-wrap break-words leading-[1.6] text-foreground">
                    {@render renderHighlighted(strVal)}
                  </div>
                {:else if typeof v === 'string'}
                  <span class="text-foreground break-all">
                    {#if v.length === 0}
                      <span class="text-muted-foreground/50 italic">""</span>
                    {:else}
                      {@render renderHighlighted(v)}
                    {/if}
                    {#if numEpochHint}
                      <span class="ml-1.5 inline-block rounded bg-secondary/55 px-1.5 py-0.2 text-[10px] text-muted-foreground">
                        → {numEpochHint}
                      </span>
                    {/if}
                  </span>
                {:else if typeof v === 'number'}
                  <span class="text-foreground break-all">
                    {@render renderHighlighted(strVal)}
                    {#if numEpochHint}
                      <span class="ml-1.5 inline-block rounded bg-secondary/55 px-1.5 py-0.2 text-[10px] text-muted-foreground">
                        → {numEpochHint}
                      </span>
                    {/if}
                  </span>
                {:else}
                  <span class="text-foreground break-all">
                    {@render renderHighlighted(strVal)}
                  </span>
                {/if}
              </div>
              {@render renderFieldActions(childPath, strVal)}
            </div>
          {/if}
        {/each}
      </div>
    {/if}
  {:else}
    <span class="text-foreground break-all">{@render renderHighlighted(String(node ?? ''))}</span>
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
  <!-- Minimalist Noise-Free Header -->
  <div class="flex h-11 shrink-0 items-center justify-between gap-2 px-3 md:px-5 select-none">
    <div class="flex items-center gap-2 min-w-0 font-mono text-xs">
      {#if workbench.isCompact}
        <button
          type="button"
          onclick={closeDetail}
          aria-label={workbench.t.inspector.closeTitle}
          title={workbench.t.inspector.closeTitle}
          class="touch-target -ml-1 flex h-9 w-9 items-center justify-center rounded-md text-foreground hover:bg-secondary/60"
        >
          <ArrowLeft class="h-4 w-4" />
        </button>
      {/if}
      {#if inspectedProject}
        <span class="text-muted-foreground/75 shrink-0">
          @{inspectedProject}
        </span>
      {/if}
      {#if inspectedSubPath}
        <span class="truncate text-muted-foreground/60" title={`${inspectedSubPath}:${targetLine}`}>
          {inspectedSubPath}:{targetLine}
        </span>
      {/if}
    </div>

    <div class="flex items-center gap-1 shrink-0">
      {#if selectedText}
        {#if workbench.hasAnyQueryInput}
          <button
            type="button"
            onmousedown={(e) => e.preventDefault()}
            onclick={appendSelectedText}
            title={workbench.t.inspector.includeTitle(selectedText)}
            class="touch-target flex items-center gap-1 rounded-md bg-secondary/80 px-2 py-1 text-xs font-medium text-foreground hover:bg-secondary active:bg-secondary cursor-pointer"
          >
            <span>+</span>
            <span class="truncate max-w-[64px]">{selectedText}</span>
          </button>
          <button
            type="button"
            onmousedown={(e) => e.preventDefault()}
            onclick={excludeSelectedText}
            title={workbench.t.inspector.excludeTitle(selectedText)}
            class="touch-target flex items-center gap-1 rounded-md bg-secondary/60 px-2 py-1 text-xs font-medium text-muted-foreground hover:bg-secondary hover:text-foreground active:bg-secondary cursor-pointer"
          >
            <span>-</span>
            <span class="truncate max-w-[64px]">{selectedText}</span>
          </button>
        {/if}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={searchSelectedText}
          title={workbench.t.inspector.searchSelectionTitle(selectedText)}
          class="flex items-center gap-1 rounded-md bg-secondary/80 px-2 py-1 text-xs font-medium text-foreground hover:bg-secondary active:bg-secondary cursor-pointer"
        >
          <Search class="h-3 w-3" />
          <span class="truncate max-w-[72px]">{selectedText}</span>
        </button>
      {/if}

      {#if workbench.inspectedPath && targetLine > 0}
        <button
          type="button"
          data-inspector-context-btn
          aria-pressed={workbench.contextDrawerOpen}
          title={workbench.t.inspector.openContextTitle}
          aria-label={workbench.t.inspector.openContextTitle}
          onmousedown={(e) => e.preventDefault()}
          onclick={() => {
            flushSync(() => {
              void workbench.openContextDrawer(workbench.inspectedPath!, targetLine);
            });
          }}
          class={`touch-target rounded-md p-1.5 cursor-pointer ${
            workbench.contextDrawerOpen
              ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35'
              : 'text-muted-foreground/80 hover:bg-secondary/60 hover:text-foreground active:bg-secondary'
          }`}
        >
          <UnfoldVertical class="h-3.5 w-3.5" />
        </button>
      {/if}

      <!-- Formatted / Raw toggle (single icon button) -->
      <button
        type="button"
        onpointerdown={(e) => {
          if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
            tabToggledOnDown = true;
            toggleInspectorTab();
          }
        }}
        onclick={(e) => {
          if (tabToggledOnDown && e.detail > 0) {
            tabToggledOnDown = false;
            return;
          }
          tabToggledOnDown = false;
          toggleInspectorTab();
        }}
        title={workbench.inspectorTab === 'raw'
          ? workbench.t.inspector.formattedBtn
          : workbench.t.inspector.rawBtn}
        aria-label={workbench.inspectorTab === 'raw'
          ? workbench.t.inspector.formattedBtn
          : workbench.t.inspector.rawBtn}
        class="touch-target rounded-md p-1.5 text-muted-foreground/80 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
      >
        {#if workbench.inspectorTab === 'raw'}
          <Braces class="h-3.5 w-3.5" />
        {:else}
          <FileText class="h-3.5 w-3.5" />
        {/if}
      </button>

      {#if activeLineText}
        <button
          type="button"
          title={workbench.t.inspector.copyTitle}
          onclick={copyCurrentContent}
          class="touch-target rounded-md p-1.5 text-muted-foreground/70 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
        >
          {#if copiedLine}
            <Check class="h-3.5 w-3.5 text-primary" />
          {:else}
            <Copy class="h-3.5 w-3.5" />
          {/if}
        </button>
      {/if}

      {#if workbench.inspectedPath}
        <button
          type="button"
          title={copiedShare
            ? workbench.t.inspector.shareReplayCopied
            : workbench.t.inspector.shareReplayTitle}
          aria-label={workbench.t.inspector.shareReplayTitle}
          onmousedown={(e) => e.preventDefault()}
          onclick={() => void sharePreviewLink()}
          class="touch-target rounded-md p-1.5 text-muted-foreground/70 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
        >
          {#if copiedShare}
            <Check class="h-3.5 w-3.5 text-primary" />
          {:else}
            <Share2 class="h-3.5 w-3.5" />
          {/if}
        </button>
      {/if}

      <button
        type="button"
        title={workbench.t.inspector.closeTitle}
        onclick={closeDetail}
        class="touch-target rounded-md p-1.5 text-muted-foreground/70 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
      >
        <X class="h-3.5 w-3.5" />
      </button>
    </div>
  </div>

  <!-- Unified Code Editor & Structured Preview Canvas -->
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
      <div class="rounded-xl border border-border/50 bg-card/35 overflow-hidden">
        {#if hasStructuredExpansion}
          <!-- Humane Structured Record View (JSON / KV / HTML / STRUCT) -->
          <div class="px-4 py-3 leading-[1.65]">
            <div class="mb-2 flex flex-wrap items-center justify-between gap-2 border-b border-border/40 pb-1.5 text-[10px] select-none">
              <div class="flex items-center gap-2 min-w-0">
                {#if structuredInfo.formatBadge}
                  <span class="rounded bg-secondary/65 px-1.5 py-0.5 font-medium text-muted-foreground">
                    {structuredInfo.formatBadge}
                  </span>
                {/if}
                {#if structuredInfo.timeHint}
                  <span class="truncate rounded bg-secondary/55 px-1.5 py-0.5 text-[10px] text-muted-foreground">
                    {structuredInfo.timeHint}
                  </span>
                {/if}
              </div>
              {#if structuredInfo.jsonValue !== undefined && Object.keys(collapsedJsonPaths).length > 0}
                <button
                  type="button"
                  onclick={(e) => {
                    e.stopPropagation();
                    collapsedJsonPaths = {};
                  }}
                  class="rounded bg-secondary/55 px-1.5 py-0.5 text-[10px] text-muted-foreground hover:text-foreground active:bg-secondary cursor-pointer"
                >
                  {workbench.t.inspector.expandAllJson}
                </button>
              {/if}
            </div>

            {#if structuredInfo.kind === 'embedded-json' && structuredInfo.prefix}
              <div class="mb-1.5 rounded bg-secondary/35 px-2 py-1 text-xs text-muted-foreground break-all">
                {@render renderHighlighted(structuredInfo.prefix)}
              </div>
            {/if}

            {#if structuredInfo.jsonValue !== undefined}
              {@render renderJsonTree(structuredInfo.jsonValue, '$', 0)}
            {:else if structuredInfo.kind === 'kv' && structuredInfo.kvPairs}
              <div class="space-y-0.5">
                {#if structuredInfo.prefix}
                  <div class="mb-1 rounded bg-secondary/35 px-2 py-1 text-xs text-muted-foreground break-all">
                    {@render renderHighlighted(structuredInfo.prefix)}
                  </div>
                {/if}
                {#each structuredInfo.kvPairs as kv, idx (`kv:${idx}:${kv.key}`)}
                  {@const kvPath = `kv.${idx}`}
                  <div
                    role="group"
                    onpointerenter={() => {
                      if (!alwaysShowFieldActions) hoveredFieldPath = kvPath;
                    }}
                    onpointerleave={() => {
                      if (!alwaysShowFieldActions && hoveredFieldPath === kvPath) hoveredFieldPath = '';
                    }}
                    class="relative flex items-baseline justify-between gap-2 rounded px-1.5 py-0.5 hover:bg-secondary/40"
                  >
                    <div class="flex items-baseline gap-2.5 min-w-0 flex-1">
                      <span class="text-muted-foreground shrink-0 select-none text-[12px] min-w-[76px]">
                        {@render renderHighlighted(kv.key)}
                      </span>
                      <span class="text-foreground break-all">
                        {@render renderHighlighted(kv.value)}
                      </span>
                    </div>
                    {@render renderFieldActions(kvPath, kv.value)}
                  </div>
                {/each}
              </div>
            {:else}
              {@const bodyText = structuredInfo.bodyFormattedText ?? structuredInfo.formattedText}
              <div
                class={`${
                  workbench.wordWrap
                    ? 'whitespace-pre-wrap break-words'
                    : 'whitespace-pre overflow-x-auto'
                } leading-[1.68] text-foreground`}
              >
                {@render renderCodeSegments(
                  highlightCodeWithMatches(bodyText, highlightFormattedText(bodyText))
                )}
              </div>
            {/if}

            {#if structuredInfo.suffix}
              <div class="mt-1.5 rounded bg-secondary/35 px-2 py-1 text-xs text-muted-foreground break-all">
                {@render renderHighlighted(structuredInfo.suffix)}
              </div>
            {/if}
          </div>
        {:else}
          <!-- Full Untruncated Single-Record Plain / Raw View -->
          {@const wrapCls = workbench.wordWrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre overflow-x-auto'}
          <div class="px-4 py-3 leading-[1.68] text-foreground font-normal">
            {#if workbench.inspectorTab === 'structured' && leadingTs}
              <div class="mb-1.5 inline-flex items-center gap-2 rounded bg-secondary/55 px-1.5 py-0.5 text-[10px] text-muted-foreground select-none">
                <span>{leadingTs.fullFormattedTime}</span>
              </div>
            {/if}
            {#if workbench.inspectorTab === 'raw'}
              <div class={wrapCls}>
                {@render renderCodeSegments(highlightCodeWithMatches(activeLineText, rawLineSegments))}
              </div>
            {:else}
              {@const plainDisplay = cleanPlainText || ' '}
              <div class={wrapCls}>
                {@render renderCodeSegments(
                  highlightCodeWithMatches(plainDisplay, highlightFormattedText(plainDisplay))
                )}
              </div>
            {/if}
          </div>
        {/if}
      </div>
    {/if}
  </div>
</aside>
