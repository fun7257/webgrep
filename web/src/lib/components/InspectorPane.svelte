<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { formatSearchTerm } from '$lib/query';
  import {
    analyzeStructuredLine,
    buildHighlightSegments,
    copyTextToClipboard,
    detectInlineEpochHint,
    extractLeadingNanoTimestamp,
    highlightCodeWithMatches,
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
    X,
  } from 'lucide-svelte';

  let asideEl = $state<HTMLElement | null>(null);
  let scrollContainerEl = $state<HTMLDivElement | null>(null);
  let selectedText = $state<string>('');
  let copiedLine = $state<boolean>(false);
  let collapsedJsonPaths = $state<Record<string, boolean>>({});
  let copiedFieldPath = $state<string>('');

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

  // Case sensitivity is expressed per term (smart case → `$c(…)` wire terms), never globally.
  const isCaseInsensitive = true;
  let isRegexMode = $derived(workbench.mode === 'regex');

  let structuredInfo = $derived(analyzeStructuredLine(activeLineText));
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

  function excludeSelectedText() {
    if (!selectedText) return;
    workbench.excludeSearchTerm(selectedText);
    selectedText = '';
    window.getSelection()?.removeAllRanges();
  }

  function searchSelectedText() {
    if (!selectedText) return;
    workbench.pattern = formatSearchTerm(selectedText);
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
    copyTextToClipboard(textToCopy);
    copiedLine = true;
    setTimeout(() => (copiedLine = false), 1500);
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

  let rawLineCodeSegments = $derived(
    highlightCodeWithMatches(activeLineText, rawLineSegments)
  );

  let hasStructuredExpansion = $derived(
    workbench.inspectorTab === 'structured' &&
      (structuredInfo.kind === 'json' ||
        structuredInfo.kind === 'embedded-json' ||
        structuredInfo.kind === 'kv' ||
        structuredInfo.formatBadge === 'HTML')
  );
</script>

{#snippet renderHighlighted(text: string)}
  {#each highlightCodeWithMatches(text, highlightFormattedText(text)) as seg}
    {#if seg.matchKind === 'primary'}
      <mark class="match-span-primary">{seg.text}</mark>
    {:else if seg.matchKind === 'contains-0'}
      <mark class="match-span-contains-0">{seg.text}</mark>
    {:else if seg.matchKind === 'contains-1'}
      <mark class="match-span-contains-1">{seg.text}</mark>
    {:else if seg.matchKind === 'contains-2'}
      <mark class="match-span-contains-2">{seg.text}</mark>
    {:else if seg.syntaxKind !== 'plain'}
      <span class={`syn-${seg.syntaxKind}`}>{seg.text}</span>
    {:else}
      <span>{seg.text}</span>
    {/if}
  {/each}
{/snippet}

{#snippet renderFieldActions(path: string, rawVal: string)}
  {#if rawVal.trim().length > 0 && rawVal.length <= 200}
    <span class="opacity-0 group-hover/kv:opacity-100 flex items-center gap-0.5 shrink-0 select-none transition-opacity">
      <button
        type="button"
        title={`深搜包含 "${rawVal}"`}
        onclick={(e) => {
          e.stopPropagation();
          workbench.appendSearchTerm(rawVal);
        }}
        class="rounded px-1.5 py-0.5 text-[10px] font-semibold bg-secondary/80 text-foreground hover:bg-primary hover:text-primary-foreground transition-colors"
      >
        +
      </button>
      <button
        type="button"
        title={`排除 -${formatSearchTerm(rawVal)}`}
        onclick={(e) => {
          e.stopPropagation();
          workbench.excludeSearchTerm(rawVal);
        }}
        class="rounded px-1.5 py-0.5 text-[10px] font-semibold bg-secondary/60 text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors"
      >
        -
      </button>
      <button
        type="button"
        title="复制字段值"
        onclick={(e) => copyFieldValue(path, rawVal, e)}
        class="rounded p-1 text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors"
      >
        {#if copiedFieldPath === path}
          <Check class="h-3 w-3 text-primary" />
        {:else}
          <Copy class="h-3 w-3" />
        {/if}
      </button>
    </span>
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
                <span class="syn-property shrink-0 select-none text-[12px]">
                  {#if isArray}
                    <span class="text-muted-foreground/65">[{k}]</span>
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
                  class="flex w-full items-center gap-1.5 rounded px-1 py-0.5 text-left hover:bg-background/60 transition-colors cursor-pointer"
                >
                  {#if isCollapsed}
                    <ChevronRight class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                  {:else}
                    <ChevronDown class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                  {/if}
                  <span class="syn-property font-medium shrink-0 text-[12px]">
                    {#if isArray}
                      <span class="text-muted-foreground/75">[{k}]</span>
                    {:else}
                      {@render renderHighlighted(k)}
                    {/if}
                  </span>
                  <span class="rounded bg-background/70 px-1.5 py-0.2 text-[10px] text-muted-foreground/80">
                    {Array.isArray(v) ? `[${childEntries.length}]` : `{${childEntries.length}}`}
                  </span>
                  {#if isCollapsed}
                    <span class="truncate text-[11px] text-muted-foreground/65">
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
            <div class="group/kv flex items-start justify-between gap-2 rounded px-1.5 py-0.5 hover:bg-background/65 transition-colors">
              <div class={`min-w-0 flex-1 ${isMultiLineStr ? 'space-y-1' : 'flex items-baseline gap-2.5'}`}>
                <span class="syn-property shrink-0 select-none text-[12px] min-w-[76px]">
                  {#if isArray}
                    <span class="text-muted-foreground/65">[{k}]</span>
                  {:else}
                    {@render renderHighlighted(k)}
                  {/if}
                </span>
                {#if isMultiLineStr}
                  <div class="rounded-md border border-border/45 bg-background/75 px-2.5 py-1.5 whitespace-pre-wrap break-words leading-[1.6] text-foreground">
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
                      <span class="ml-1.5 inline-block rounded bg-background/80 px-1.5 py-0.2 text-[10px] text-muted-foreground">
                        → {numEpochHint}
                      </span>
                    {/if}
                  </span>
                {:else if typeof v === 'number'}
                  <span class="syn-number font-medium break-all">
                    {@render renderHighlighted(strVal)}
                    {#if numEpochHint}
                      <span class="ml-1.5 inline-block rounded bg-background/80 px-1.5 py-0.2 text-[10px] font-normal text-muted-foreground">
                        → {numEpochHint}
                      </span>
                    {/if}
                  </span>
                {:else}
                  <span class="syn-literal font-medium break-all">
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
            <span class="truncate max-w-[64px]">{selectedText}</span>
          </button>
          <button
            type="button"
            onmousedown={(e) => e.preventDefault()}
            onclick={excludeSelectedText}
            title={`从当前结果中排除 -${formatSearchTerm(selectedText)}`}
            class="flex items-center gap-1 rounded-md bg-secondary/60 px-2 py-1 text-xs font-medium text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors"
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
      <div class="rounded-xl border border-border/55 bg-card/35 overflow-hidden shadow-2xs">
        {#if fileData && fileData.path === workbench.inspectedPath && fileData.startLine > 1}
          <button
            type="button"
            onclick={() => workbench.expandInspectorContext(30)}
            class="flex w-full items-center justify-center border-b border-border/35 bg-secondary/20 py-1.5 text-[11px] text-muted-foreground/70 hover:bg-secondary/50 hover:text-foreground transition-colors cursor-pointer select-none"
          >
            ↑ {workbench.t.inspector.expandContext}
          </button>
        {/if}

        <div class="py-1">
          {#each contextLines as ln (ln.n)}
            {@const isTarget = ln.n === workbench.inspectedLine}
            {@const cleanLineText =
              workbench.inspectorTab === 'raw'
                ? ln.text
                : (extractLeadingNanoTimestamp(ln.text)?.restText ?? ln.text)}
            {@const isLongStructuredContext =
              !isTarget &&
              workbench.inspectorTab === 'structured' &&
              cleanLineText.length > 140 &&
              (cleanLineText.trimStart().startsWith('{') || cleanLineText.includes('="'))}
            <!-- svelte-ignore a11y_click_events_have_key_events -->
            <!-- svelte-ignore a11y_no_static_element_interactions -->
            <div
              data-active-line={isTarget ? 'true' : undefined}
              onclick={() => {
                if (!window.getSelection()?.toString()) {
                  workbench.inspectedLine = ln.n;
                }
              }}
              class={`group flex items-stretch transition-colors cursor-pointer ${
                isTarget
                  ? 'bg-primary/[0.08] dark:bg-primary/[0.13] shadow-[inset_3px_0_0_0_hsl(var(--primary))]'
                  : 'hover:bg-secondary/35'
              }`}
            >
              <!-- Fixed-width Line Number Gutter (100% aligned across all lines) -->
              <span
                class={`w-12 shrink-0 select-none border-r border-border/35 pr-3 py-0.5 text-right text-[11px] leading-[1.68] tabular-nums ${
                  isTarget
                    ? 'font-semibold text-primary'
                    : 'text-muted-foreground/45 group-hover:text-muted-foreground/75'
                }`}
              >
                {ln.n}
              </span>

              {#if isTarget && hasStructuredExpansion}
                <!-- In-Place Humane Structured View (replaces the ugly single-line raw JSON/KV directly) -->
                <div class="min-w-0 flex-1 pl-3 pr-3.5 py-2 leading-[1.65]">
                  <div class="mb-2 flex flex-wrap items-center justify-between gap-2 border-b border-border/35 pb-1.5 text-[10px] select-none">
                    <div class="flex items-center gap-2 min-w-0">
                      {#if structuredInfo.formatBadge}
                        <span class="rounded bg-primary/15 px-1.5 py-0.5 font-semibold uppercase tracking-wider text-primary">
                          {structuredInfo.formatBadge}
                        </span>
                      {/if}
                      {#if structuredInfo.timeHint}
                        <span class="truncate rounded bg-background/75 px-1.5 py-0.5 text-[10px] text-muted-foreground">
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
                        class="rounded bg-background/70 px-1.5 py-0.5 text-[10px] text-muted-foreground hover:text-foreground transition-colors"
                      >
                        展开全部
                      </button>
                    {/if}
                  </div>

                  {#if structuredInfo.kind === 'embedded-json' && structuredInfo.prefix}
                    <div class="mb-1.5 rounded bg-background/55 px-2 py-1 text-xs text-muted-foreground break-all">
                      {@render renderHighlighted(structuredInfo.prefix)}
                    </div>
                  {/if}

                  {#if structuredInfo.jsonValue !== undefined}
                    {@render renderJsonTree(structuredInfo.jsonValue, '$', 0)}
                  {:else if structuredInfo.kind === 'kv' && structuredInfo.kvPairs}
                    <div class="space-y-0.5">
                      {#if structuredInfo.prefix}
                        <div class="mb-1 rounded bg-background/55 px-2 py-1 text-xs text-muted-foreground break-all">
                          {@render renderHighlighted(structuredInfo.prefix)}
                        </div>
                      {/if}
                      {#each structuredInfo.kvPairs as kv, idx (`kv:${idx}:${kv.key}`)}
                        <div class="group/kv flex items-baseline justify-between gap-2 rounded px-1.5 py-0.5 hover:bg-background/65 transition-colors">
                          <div class="flex items-baseline gap-2.5 min-w-0 flex-1">
                            <span class="syn-property shrink-0 select-none text-[12px] min-w-[76px]">
                              {@render renderHighlighted(kv.key)}
                            </span>
                            <span class="text-foreground break-all">
                              {@render renderHighlighted(kv.value)}
                            </span>
                          </div>
                          {@render renderFieldActions(`kv.${idx}`, kv.value)}
                        </div>
                      {/each}
                    </div>
                  {:else}
                    <div
                      class={`${
                        workbench.wordWrap
                          ? 'whitespace-pre-wrap break-words'
                          : 'whitespace-pre overflow-x-auto'
                      } leading-[1.68] text-foreground`}
                    >
                      {@render renderHighlighted(
                        structuredInfo.bodyFormattedText ?? structuredInfo.formattedText
                      )}
                    </div>
                  {/if}

                  {#if structuredInfo.suffix}
                    <div class="mt-1.5 rounded bg-background/55 px-2 py-1 text-xs text-muted-foreground break-all">
                      {@render renderHighlighted(structuredInfo.suffix)}
                    </div>
                  {/if}
                </div>
              {:else}
                <!-- Code / Plain Line Cell (preserves indentation & applies syntax + match highlighting) -->
                <div
                  class={`min-w-0 flex-1 pl-3.5 pr-4 py-0.5 leading-[1.68] ${
                    isTarget ? 'text-foreground font-normal' : 'text-foreground/85'
                  } ${
                    isLongStructuredContext
                      ? 'truncate'
                      : workbench.wordWrap
                        ? 'whitespace-pre-wrap break-words'
                        : 'whitespace-pre overflow-x-auto'
                  }`}
                >
                  {#if isTarget && workbench.inspectorTab === 'raw'}
                    {#each rawLineCodeSegments as seg}
                      {#if seg.matchKind === 'primary'}
                        <mark class="match-span-primary">{seg.text}</mark>
                      {:else if seg.matchKind === 'contains-0'}
                        <mark class="match-span-contains-0">{seg.text}</mark>
                      {:else if seg.matchKind === 'contains-1'}
                        <mark class="match-span-contains-1">{seg.text}</mark>
                      {:else if seg.matchKind === 'contains-2'}
                        <mark class="match-span-contains-2">{seg.text}</mark>
                      {:else if seg.syntaxKind !== 'plain'}
                        <span class={`syn-${seg.syntaxKind}`}>{seg.text}</span>
                      {:else}
                        <span>{seg.text}</span>
                      {/if}
                    {/each}
                  {:else}
                    {@render renderHighlighted(cleanLineText || ' ')}
                  {/if}
                </div>
              {/if}
            </div>
          {/each}
        </div>

        {#if fileData && fileData.path === workbench.inspectedPath && !fileData.eof}
          <button
            type="button"
            onclick={() => workbench.expandInspectorContext(30)}
            class="flex w-full items-center justify-center border-t border-border/35 bg-secondary/20 py-1.5 text-[11px] text-muted-foreground/70 hover:bg-secondary/50 hover:text-foreground transition-colors cursor-pointer select-none"
          >
            ↓ {workbench.t.inspector.expandContext}
          </button>
        {/if}
      </div>
    {/if}
  </div>
</aside>
