<script lang="ts">
  import { onDestroy } from 'svelte';
  import { detectCodeLanguage } from '$lib/adapters/index.ts';
  import { highlightCodeWithMatches } from '$lib/utils';
  import type { AdapterInspectorProps } from '../types.ts';
  import { Check, Copy, Loader2, UnfoldVertical } from 'lucide-svelte';

  let {
    host,
    activeHit,
    activeLineText,
    targetLine,
    inspectedPath,
    fileData,
    loading,
    rawLineSegments,
    highlightFormattedText,
    renderCodeSegments,
  }: AdapterInspectorProps = $props();

  let copiedPathLine = $state(false);
  let copyTimer: ReturnType<typeof setTimeout> | null = null;

  onDestroy(() => {
    if (copyTimer !== null) clearTimeout(copyTimer);
  });

  const cv = $derived(host.t.codeView);
  const langInfo = $derived(detectCodeLanguage(inspectedPath));

  const linesToRender = $derived.by(() => {
    if (fileData && fileData.path === inspectedPath && fileData.lines.length > 0) {
      return fileData.lines;
    }
    return [{ n: targetLine, text: activeLineText }];
  });

  const firstLineNum = $derived(linesToRender[0]?.n ?? targetLine);
  const lastLineNum = $derived(linesToRender[linesToRender.length - 1]?.n ?? targetLine);
  const wrapCls = $derived(
    host.wordWrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre overflow-x-auto'
  );

  function copyPathWithLine() {
    if (!inspectedPath) return;
    host.copyText(`${inspectedPath}:${targetLine}`);
    copiedPathLine = true;
    if (copyTimer !== null) clearTimeout(copyTimer);
    copyTimer = setTimeout(() => {
      copiedPathLine = false;
      copyTimer = null;
    }, 1400);
  }
</script>

<div class="divide-y divide-border/45">
  <!-- Code Snippet Metadata Toolbar -->
  <div class="flex h-9 items-center justify-between gap-2 bg-card/55 px-3 select-none">
    <div class="flex min-w-0 items-center gap-1.5 font-mono text-[11px]">
      {#if langInfo}
        <span class="rounded bg-secondary/75 px-1.5 py-0.5 text-[10px] font-medium text-foreground/85">
          {langInfo.label}
        </span>
      {/if}
      <span class="tabular-nums text-muted-foreground/75">
        {cv.lineRange(firstLineNum, lastLineNum)}
      </span>
      {#if loading}
        <Loader2 class="h-3 w-3 animate-spin text-primary" />
      {/if}
    </div>

    <div class="flex shrink-0 items-center gap-1 font-mono text-[11px]">
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={copyPathWithLine}
        title={cv.copyPathLine}
        class="touch-target inline-flex h-6 items-center gap-1 rounded px-1.5 text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
      >
        {#if copiedPathLine}
          <Check class="h-3 w-3 text-primary" />
          <span class="text-primary">{cv.copiedPathLine}</span>
        {:else}
          <Copy class="h-3 w-3" />
          <span class="hidden sm:inline">{cv.copyPathLine}</span>
        {/if}
      </button>

      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => host.openContextDrawer(inspectedPath, targetLine, activeHit?.byteOffset)}
        title={host.t.inspector.openContextTitle}
        class="touch-target inline-flex h-6 items-center gap-1 rounded bg-secondary/65 px-2 text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
      >
        <UnfoldVertical class="h-3 w-3" />
        <span>{cv.openFullContext}</span>
      </button>
    </div>
  </div>

  <!-- Numbered Syntax-Highlighted Surrounding Code Block -->
  <div class="overflow-x-auto py-2 font-mono leading-[1.6]">
    {#each linesToRender as ln (ln.n)}
      {@const isTarget = ln.n === targetLine}
      {@const matchSegs = isTarget ? rawLineSegments : highlightFormattedText(ln.text)}
      <div
        class={`flex items-stretch ${
          isTarget
            ? 'bg-primary/10 shadow-[inset_2.5px_0_0_hsl(var(--primary))]'
            : 'hover:bg-secondary/35'
        }`}
      >
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={() => host.openContextDrawer(inspectedPath, ln.n, isTarget ? activeHit?.byteOffset : undefined)}
          title={host.t.inspector.openContextTitle}
          class={`w-12 shrink-0 select-none border-r border-border/35 pr-2.5 py-0.5 text-right text-[11px] tabular-nums cursor-pointer ${
            isTarget
              ? 'font-semibold text-primary'
              : 'text-muted-foreground/50 hover:text-foreground'
          }`}
        >
          {ln.n}
        </button>
        <div class={`min-w-0 flex-1 px-3 py-0.5 text-foreground ${wrapCls}`}>
          {@render renderCodeSegments(highlightCodeWithMatches(ln.text || ' ', matchSegs))}
        </div>
      </div>
    {/each}
  </div>
</div>
