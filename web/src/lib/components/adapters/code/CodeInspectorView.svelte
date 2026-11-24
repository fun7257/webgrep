<script lang="ts">
  import { detectCodeLanguage } from '$lib/adapters/index.ts';
  import { highlightCodeWithMatches } from '$lib/utils';
  import type { AdapterInspectorProps } from '../types.ts';
  import { Loader2 } from 'lucide-svelte';

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
  const showLineRange = $derived(linesToRender.length > 1 && lastLineNum > firstLineNum);
  const showMetaStrip = $derived(Boolean(langInfo) || showLineRange || loading);
  const wrapCls = $derived(
    host.wordWrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre overflow-x-auto'
  );
</script>

<div class="divide-y divide-border/45">
  {#if showMetaStrip}
    <div class="flex h-8 items-center gap-1.5 bg-card/55 px-3 font-mono text-[11px] select-none">
      {#if langInfo}
        <span class="rounded bg-secondary/75 px-1.5 py-0.5 text-[10px] font-medium text-foreground/85">
          {langInfo.label}
        </span>
      {/if}
      {#if showLineRange}
        <span class="tabular-nums text-muted-foreground/75">
          {cv.lineRange(firstLineNum, lastLineNum)}
        </span>
      {/if}
      {#if loading}
        <Loader2 class="h-3 w-3 animate-spin text-primary" />
      {/if}
    </div>
  {/if}

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
          class={`touch-target w-12 shrink-0 select-none border-r border-border/35 pr-2.5 py-0.5 text-right text-[11px] tabular-nums cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary/50 ${
            isTarget
              ? 'font-semibold text-primary'
              : 'text-muted-foreground/75 hover:text-foreground'
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
