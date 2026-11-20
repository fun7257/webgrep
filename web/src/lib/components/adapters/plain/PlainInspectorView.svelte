<script lang="ts">
  import { extractLeadingNanoTimestamp, type HighlightSegment } from '$lib/utils';
  import StructuredRecordView from '../../inspector/StructuredRecordView.svelte';
  import type { AdapterInspectorProps } from '../types.ts';

  let {
    host,
    activeLineText,
    inspectorTab,
    recordKey,
    structuredInfo,
    rawLineSegments,
    highlightFormattedText,
    renderCodeSegments,
  }: AdapterInspectorProps = $props();

  const leadingTs = $derived(extractLeadingNanoTimestamp(activeLineText));
  const cleanPlainText = $derived(
    leadingTs && leadingTs.restText.length > 0 ? leadingTs.restText : activeLineText
  );
  const displayTimeHint = $derived(
    leadingTs?.fullFormattedTime || structuredInfo.timeHint || ''
  );
  const hasJsonOrKv = $derived(
    inspectorTab === 'structured' &&
      (structuredInfo.kind === 'json' ||
        structuredInfo.kind === 'embedded-json' ||
        structuredInfo.kind === 'kv')
  );
  const wrapCls = $derived(
    host.wordWrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre overflow-x-auto'
  );
</script>

{#snippet renderMatchSpans(segments: HighlightSegment[])}
  {#if segments.length === 1 && segments[0].kind === 'plain'}
    {segments[0].text || ' '}
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

{#if hasJsonOrKv}
  <StructuredRecordView
    {structuredInfo}
    {highlightFormattedText}
    {recordKey}
    {renderCodeSegments}
  />
{:else if inspectorTab === 'raw'}
  <div class={`px-4 py-3 leading-[1.68] text-foreground font-normal ${wrapCls}`}>
    {@render renderMatchSpans(rawLineSegments)}
  </div>
{:else}
  {@const plainDisplay = (leadingTs ? cleanPlainText : activeLineText) || ' '}
  <div class="px-4 py-3 leading-[1.68] text-foreground font-normal">
    {#if displayTimeHint}
      <div class="mb-1.5 inline-flex items-center gap-2 rounded bg-secondary/55 px-1.5 py-0.5 text-[10.5px] font-mono tabular-nums text-muted-foreground select-none">
        <span>{displayTimeHint}</span>
      </div>
    {/if}
    <div class={wrapCls}>
      {@render renderMatchSpans(highlightFormattedText(plainDisplay))}
    </div>
  </div>
{/if}
