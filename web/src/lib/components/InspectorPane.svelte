<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import {
    analyzeStructuredLine,
    buildHighlightSegments,
  } from '$lib/utils';
  import {
    ArrowLeft,
    Braces,
    Check,
    Copy,
    FileText,
    Loader2,
    Search,
    X,
  } from 'lucide-svelte';

  let asideEl = $state<HTMLElement | null>(null);
  let scrollContainerEl = $state<HTMLDivElement | null>(null);
  let selectedText = $state<string>('');
  let copiedLine = $state<boolean>(false);

  let activeHit = $derived(workbench.activeHit);
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
        ? fileData.lines.find((l) => l.n === workbench.inspectedLine)?.text
        : undefined;
    if (fromFile !== undefined && fromFile.length > 0) {
      return fromFile;
    }
    if (activeHit && activeHit.file === workbench.inspectedPath) {
      return activeHit.text;
    }
    return fromFile ?? '';
  });

  // Global match-case no longer exists: case sensitivity is expressed per token via `$c(…)`.
  const isCaseInsensitive = true;
  let isRegexMode = $derived(workbench.mode === 'regex');

  let structuredInfo = $derived(analyzeStructuredLine(activeLineText));
  let isStructuredLog = $derived(
    structuredInfo.kind === 'json' ||
      structuredInfo.kind === 'embedded-json' ||
      structuredInfo.kind === 'kv'
  );
  let contextLines = $derived(
    fileData && fileData.path === workbench.inspectedPath && fileData.lines.length > 0
      ? fileData.lines
      : activeLineText
        ? [{ n: workbench.inspectedLine, text: activeLineText }]
        : []
  );

  // Auto-scroll the active line into center view when inspecting a multi-line code/HTML/text file
  $effect(() => {
    const targetPath = workbench.inspectedPath;
    const targetLine = workbench.inspectedLine;
    const linesCount = contextLines.length;
    if (!targetPath || !targetLine || linesCount <= 1 || !scrollContainerEl) return;
    requestAnimationFrame(() => {
      const activeEl = scrollContainerEl?.querySelector('[data-active-line="true"]') as HTMLElement | null;
      if (activeEl && scrollContainerEl) {
        const containerRect = scrollContainerEl.getBoundingClientRect();
        const elRect = activeEl.getBoundingClientRect();
        const offset = elRect.top - containerRect.top - containerRect.height / 2 + elRect.height / 2;
        if (Math.abs(offset) > containerRect.height * 0.28) {
          scrollContainerEl.scrollTop += offset;
        }
      }
    });
  });

  function highlightFormattedText(text: string) {
    if (!text) return [{ text: '', kind: 'plain' as const }];
    const segments = buildHighlightSegments(
      text,
      undefined,
      workbench.contains,
      isCaseInsensitive,
      false,
      workbench.primaryPattern,
      isRegexMode
    );
    if (
      !segments.some((s) => s.kind === 'primary') &&
      activeHit?.spans &&
      activeHit.spans.length > 0
    ) {
      const fallbackSpans: { start: number; end: number }[] = [];
      const hay = isCaseInsensitive ? text.toLowerCase() : text;
      for (const sp of activeHit.spans) {
        const sub = activeHit.text.slice(sp.start, sp.end);
        if (!sub) continue;
        const needle = isCaseInsensitive ? sub.toLowerCase() : sub;
        let pos = 0;
        while (pos < hay.length) {
          const idx = hay.indexOf(needle, pos);
          if (idx === -1) break;
          fallbackSpans.push({ start: idx, end: idx + needle.length });
          pos = idx + Math.max(1, needle.length);
        }
      }
      if (fallbackSpans.length > 0) {
        return buildHighlightSegments(
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
    return segments;
  }

  let rawLineSegments = $derived.by(() => {
    const canUseExactSpans =
      activeHit &&
      activeHit.file === workbench.inspectedPath &&
      activeHit.line === workbench.inspectedLine &&
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

  function searchSelectedText() {
    if (!selectedText) return;
    workbench.pattern = selectedText;
    selectedText = '';
    window.getSelection()?.removeAllRanges();
    workbench.executeSearch();
  }

  function copyCurrentContent() {
    if (!activeLineText) return;
    const textToCopy =
      workbench.inspectorTab === 'structured'
        ? structuredInfo.formattedText || activeLineText
        : activeLineText;
    navigator.clipboard?.writeText(textToCopy);
    copiedLine = true;
    setTimeout(() => (copiedLine = false), 1500);
  }
</script>

{#snippet renderHighlighted(text: string)}
  {#each highlightFormattedText(text) as seg}
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
        <span class="truncate text-muted-foreground/60" title={`${inspectedSubPath}:${workbench.inspectedLine}`}>
          {inspectedSubPath}:{workbench.inspectedLine}
        </span>
      {/if}
    </div>

    <div class="flex items-center gap-1 shrink-0">
      {#if selectedText}
        {#if workbench.pattern.trim().length > 0}
          <button
            type="button"
            onmousedown={(e) => e.preventDefault()}
            onclick={appendSelectedText}
            title={`在当前结果中继续深搜 "${selectedText}"`}
            class="flex items-center gap-1 rounded-md bg-secondary/80 px-2 py-1 text-xs font-medium text-foreground hover:bg-secondary transition-colors"
          >
            <span>+</span>
            <span class="truncate max-w-[72px]">{selectedText}</span>
          </button>
        {/if}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={searchSelectedText}
          title={workbench.t.inspector.searchSelectionTitle(selectedText)}
          class="flex items-center gap-1 rounded-md bg-foreground px-2 py-1 text-xs font-medium text-background"
        >
          <Search class="h-3 w-3" />
          <span class="truncate max-w-[72px]">{selectedText}</span>
        </button>
      {/if}

      <!-- Formatted / Raw toggle (single icon button) -->
      <button
        type="button"
        onclick={() =>
          (workbench.inspectorTab = workbench.inspectorTab === 'raw' ? 'structured' : 'raw')}
        title={workbench.inspectorTab === 'raw'
          ? workbench.t.inspector.formattedBtn
          : workbench.t.inspector.rawBtn}
        aria-label={workbench.inspectorTab === 'raw'
          ? workbench.t.inspector.formattedBtn
          : workbench.t.inspector.rawBtn}
        class="touch-target rounded-md p-1.5 text-muted-foreground/80 hover:bg-secondary/60 hover:text-foreground transition-colors"
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
          class="touch-target rounded-md p-1.5 text-muted-foreground/70 hover:bg-secondary/60 hover:text-foreground transition-colors"
        >
          {#if copiedLine}
            <Check class="h-3.5 w-3.5 text-primary" />
          {:else}
            <Copy class="h-3.5 w-3.5" />
          {/if}
        </button>
      {/if}

      <button
        type="button"
        title={workbench.t.inspector.closeTitle}
        onclick={closeDetail}
        class="touch-target rounded-md p-1.5 text-muted-foreground/70 hover:bg-secondary/60 hover:text-foreground transition-colors"
      >
        <X class="h-3.5 w-3.5" />
      </button>
    </div>
  </div>

  <!-- Borderless Reading Canvas: Adaptive Structured Event Card vs Multi-Line Code/HTML Context -->
  <div
    bind:this={scrollContainerEl}
    style={`font-size: ${workbench.codeFontSize}px`}
    class="flex-1 min-h-0 overflow-y-auto px-3 md:px-5 pb-6 pt-1 font-mono"
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
    {:else if workbench.inspectorTab === 'raw'}
      <div
        class={`${
          workbench.wordWrap ? 'whitespace-pre-wrap break-all' : 'whitespace-pre overflow-x-auto'
        } leading-7 text-foreground/90`}
      >
        {#each rawLineSegments as seg}
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
      </div>
    {:else if structuredInfo.kind === 'kv' && structuredInfo.kvPairs}
      <div class="space-y-2 leading-7">
        {#if structuredInfo.prefix}
          <div class="text-muted-foreground font-mono pb-1 border-b border-border/40 break-all">
            {@render renderHighlighted(structuredInfo.prefix)}
          </div>
        {/if}
        {#each structuredInfo.kvPairs as kv, idx (`kv:${idx}:${kv.key}`)}
          <div class="flex items-baseline gap-3">
            <span class="text-muted-foreground/70 shrink-0 select-none">
              {@render renderHighlighted(kv.key)}
            </span>
            <span class="text-foreground/95 break-all">
              {@render renderHighlighted(kv.value)}
            </span>
          </div>
        {/each}
        {#if structuredInfo.suffix}
          <div class="text-muted-foreground font-mono pt-1 border-t border-border/40 break-all">
            {@render renderHighlighted(structuredInfo.suffix)}
          </div>
        {/if}
      </div>
    {:else if isStructuredLog}
      <div
        class={`${
          workbench.wordWrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre overflow-x-auto'
        } leading-7 text-foreground/90`}
      >
        {@render renderHighlighted(structuredInfo.formattedText)}
      </div>
    {:else}
      <!-- Multi-Line Context View for Code, HTML, Markdown, Stack Traces & Text -->
      <div class="space-y-0.5">
        {#if fileData && fileData.path === workbench.inspectedPath && fileData.startLine > 1}
          <button
            type="button"
            onclick={() => workbench.expandInspectorContext(30)}
            class="mb-1 flex w-full items-center justify-center rounded-md py-1 text-[11px] text-muted-foreground/60 hover:bg-secondary/50 hover:text-foreground transition-colors cursor-pointer select-none"
          >
            ↑ {workbench.t.inspector.expandContext}
          </button>
        {/if}

        {#each contextLines as ln (ln.n)}
          {@const isTarget = ln.n === workbench.inspectedLine}
          <div
            data-active-line={isTarget ? 'true' : undefined}
            class={`flex items-baseline gap-3 rounded px-2 py-0.5 leading-[1.65] ${
              isTarget
                ? 'bg-secondary/75 border-l-2 border-primary text-foreground'
                : 'text-foreground/80 hover:bg-secondary/30'
            }`}
          >
            <span
              class={`w-9 shrink-0 select-none text-right text-[11px] tabular-nums ${
                isTarget ? 'font-semibold text-primary' : 'text-muted-foreground/45'
              }`}
            >
              {ln.n}
            </span>
            <div
              class={`min-w-0 flex-1 ${
                workbench.wordWrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre overflow-x-auto'
              }`}
            >
              {@render renderHighlighted(ln.text)}
            </div>
          </div>
        {/each}

        {#if fileData && fileData.path === workbench.inspectedPath && !fileData.eof}
          <button
            type="button"
            onclick={() => workbench.expandInspectorContext(30)}
            class="mt-1 flex w-full items-center justify-center rounded-md py-1 text-[11px] text-muted-foreground/60 hover:bg-secondary/50 hover:text-foreground transition-colors cursor-pointer select-none"
          >
            ↓ {workbench.t.inspector.expandContext}
          </button>
        {/if}
      </div>
    {/if}
  </div>
</aside>
