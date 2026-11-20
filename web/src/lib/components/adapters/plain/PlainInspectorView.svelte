<script lang="ts">
  import { extractLeadingNanoTimestamp, highlightCodeWithMatches } from '$lib/utils';
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
  const hasStructuredExpansion = $derived(
    inspectorTab === 'structured' &&
      (structuredInfo.kind === 'json' ||
        structuredInfo.kind === 'embedded-json' ||
        structuredInfo.kind === 'kv' ||
        Boolean(structuredInfo.formatBadge))
  );
  const wrapCls = $derived(
    host.wordWrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre overflow-x-auto'
  );
</script>

{#if hasStructuredExpansion}
  <StructuredRecordView
    {structuredInfo}
    {highlightFormattedText}
    {recordKey}
    {renderCodeSegments}
  />
{:else}
  <div class="px-4 py-3 leading-[1.68] text-foreground font-normal">
    {#if inspectorTab === 'structured' && leadingTs}
      <div class="mb-1.5 inline-flex items-center gap-2 rounded bg-secondary/55 px-1.5 py-0.5 text-[10px] text-muted-foreground select-none">
        <span>{leadingTs.fullFormattedTime}</span>
      </div>
    {/if}
    {#if inspectorTab === 'raw'}
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
