<script lang="ts">
  import { onDestroy } from 'svelte';
  import { parseLogLine, type LogLevel } from '$lib/adapters/index.ts';
  import {
    extractLeadingNanoTimestamp,
    highlightCodeWithMatches,
    type HighlightSegment,
    type StructuredAnalysis,
  } from '$lib/utils';
  import StructuredRecordView from '../../inspector/StructuredRecordView.svelte';
  import type { AdapterInspectorProps } from '../types.ts';
  import { Check, Link2 } from 'lucide-svelte';

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

  let copiedTs = $state(false);
  let copiedTsTimer: ReturnType<typeof setTimeout> | null = null;

  onDestroy(() => {
    if (copiedTsTimer !== null) clearTimeout(copiedTsTimer);
  });

  const lv = $derived(host.t.logView);
  const record = $derived(
    activeLineText && inspectorTab === 'structured' ? parseLogLine(activeLineText) : null
  );
  const leadingTs = $derived(
    !record && inspectorTab === 'structured' ? extractLeadingNanoTimestamp(activeLineText) : null
  );
  const cleanPlainText = $derived(
    leadingTs && leadingTs.restText.length > 0 ? leadingTs.restText : activeLineText
  );

  function levelTextClass(level: LogLevel): string {
    if (level === 'fatal' || level === 'error') {
      return 'text-status font-semibold';
    }
    if (level === 'warn') {
      return 'text-status/85 font-medium';
    }
    if (level === 'info') {
      return 'text-foreground/80 font-medium';
    }
    return 'text-muted-foreground';
  }

  function copyTimestamp() {
    const raw = record?.timeRaw || record?.timeFull;
    if (!raw) return;
    host.copyText(raw);
    copiedTs = true;
    if (copiedTsTimer !== null) clearTimeout(copiedTsTimer);
    copiedTsTimer = setTimeout(() => {
      copiedTs = false;
      copiedTsTimer = null;
    }, 1200);
  }

  const fieldsAnalysis = $derived.by((): StructuredAnalysis | null => {
    if (!record?.structuredData || Object.keys(record.structuredData).length === 0) return null;
    const pretty = JSON.stringify(record.structuredData, null, 2);
    return {
      kind: 'json',
      jsonValue: record.structuredData,
      formatBadge: record.truncated ? lv.truncatedBadge : lv.fieldsSection,
      formattedText: pretty,
      bodyFormattedText: pretty,
      charCount: pretty.length,
    };
  });

  const hasGenericStructured = $derived(
    inspectorTab === 'structured' &&
      (structuredInfo.kind === 'json' ||
        structuredInfo.kind === 'embedded-json' ||
        structuredInfo.kind === 'kv' ||
        Boolean(structuredInfo.formatBadge))
  );
</script>

{#snippet renderMatchSpans(segments: HighlightSegment[])}
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

{#if inspectorTab === 'raw'}
  <div class="px-4 py-3 leading-[1.68] text-foreground font-normal whitespace-pre-wrap break-words">
    {@render renderCodeSegments(highlightCodeWithMatches(activeLineText, rawLineSegments))}
  </div>
{:else if record}
  <div class="divide-y divide-border/40">
    <!-- Minimal Universal Log Summary Header -->
    <div class="space-y-2 px-4 py-3">
      <div class="flex flex-wrap items-center gap-x-2.5 gap-y-1 font-mono text-[11.5px] select-none">
        {#if record.levelBadge}
          <span class={levelTextClass(record.level)}>{record.levelBadge}</span>
        {/if}

        {#if record.timeFull || record.timeRaw}
          <button
            type="button"
            onclick={copyTimestamp}
            title={lv.copyTimestampTitle}
            class="inline-flex items-center gap-1 tabular-nums text-muted-foreground hover:text-foreground cursor-pointer"
          >
            <span>{record.timeFull || record.timeRaw}</span>
            {#if copiedTs}
              <Check class="h-3 w-3 text-primary" />
            {/if}
          </button>
        {/if}

        {#if record.category}
          <button
            type="button"
            onclick={(e) => {
              if (e.altKey) host.excludeTerm(record.categoryFilterToken || record.category);
              else host.appendTerm(record.categoryFilterToken || record.category);
            }}
            title={lv.rowCategoryTitle(record.category)}
            class="max-w-full truncate text-muted-foreground/85 hover:text-primary cursor-pointer"
          >
            {@render renderMatchSpans(highlightFormattedText(record.category))}
          </button>
        {/if}

        {#if record.traceId}
          <button
            type="button"
            onclick={(e) => {
              if (e.altKey) host.appendTerm(record.traceId);
              else host.replaceQuery(record.traceId);
            }}
            title={lv.traceFollowTitle(record.traceId)}
            class="inline-flex items-center gap-1 text-primary/85 hover:text-primary cursor-pointer"
          >
            <Link2 class="h-3 w-3 shrink-0" />
            <span>{record.traceId}</span>
          </button>
        {/if}

        {#if record.truncated}
          <span title={lv.truncatedNotice} class="text-[10.5px] text-status">
            {lv.truncatedBadge}
          </span>
        {/if}
      </div>

      {#if record.summary}
        <div class="text-[13px] leading-[1.65] text-foreground whitespace-pre-wrap break-words">
          {@render renderMatchSpans(highlightFormattedText(record.summary))}
        </div>
      {/if}

      {#if record.errorText && record.errorText !== record.summary}
        <div class="border-l-2 border-status/50 pl-3 text-[12.5px] leading-[1.6] text-foreground/90 whitespace-pre-wrap break-words">
          {@render renderMatchSpans(highlightFormattedText(record.errorText))}
        </div>
      {/if}
    </div>

    <!-- Universal Structured Fields Explorer -->
    {#if fieldsAnalysis}
      <StructuredRecordView
        structuredInfo={fieldsAnalysis}
        {highlightFormattedText}
        {recordKey}
        {renderCodeSegments}
      />
    {:else if record.format === 'kv' && structuredInfo.kvPairs}
      <StructuredRecordView
        {structuredInfo}
        {highlightFormattedText}
        {recordKey}
        {renderCodeSegments}
      />
    {/if}

    {#if record.truncated && record.truncatedTail}
      <div class="space-y-1 px-4 py-2.5">
        <div class="text-[10.5px] text-muted-foreground select-none">
          {lv.truncatedTailLabel}
        </div>
        <div class="text-[12px] leading-[1.6] text-muted-foreground/85 whitespace-pre-wrap break-all">
          {@render renderCodeSegments(
            highlightCodeWithMatches(
              record.truncatedTail,
              highlightFormattedText(record.truncatedTail)
            )
          )}
        </div>
      </div>
    {/if}
  </div>
{:else if hasGenericStructured}
  <StructuredRecordView
    {structuredInfo}
    {highlightFormattedText}
    {recordKey}
    {renderCodeSegments}
  />
{:else}
  <div class="px-4 py-3 leading-[1.68] text-foreground font-normal whitespace-pre-wrap break-words">
    {#if leadingTs}
      <div class="mb-1.5 inline-flex items-center gap-2 rounded bg-secondary/55 px-1.5 py-0.5 text-[10px] text-muted-foreground select-none">
        <span>{leadingTs.fullFormattedTime}</span>
      </div>
    {/if}
    <div>
      {@render renderCodeSegments(
        highlightCodeWithMatches(cleanPlainText || ' ', highlightFormattedText(cleanPlainText || ' '))
      )}
    </div>
  </div>
{/if}
