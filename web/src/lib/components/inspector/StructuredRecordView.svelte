<script lang="ts">
  import { onDestroy, type Snippet } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import {
    copyTextToClipboard,
    detectInlineEpochHint,
    highlightCodeWithMatches,
    type CodeHighlightSegment,
    type HighlightSegment,
    type StructuredAnalysis,
  } from '$lib/utils';
  import { Check, ChevronDown, ChevronRight, Copy } from 'lucide-svelte';

  interface Props {
    structuredInfo: StructuredAnalysis;
    highlightFormattedText: (text: string) => HighlightSegment[];
    recordKey: string;
    renderCodeSegments: Snippet<[CodeHighlightSegment[]]>;
  }

  let { structuredInfo, highlightFormattedText, recordKey, renderCodeSegments }: Props = $props();

  let collapsedJsonPaths = $state<Record<string, boolean>>({});
  let copiedFieldPath = $state<string>('');
  let hoveredFieldPath = $state<string>('');
  let copiedFieldTimer: ReturnType<typeof setTimeout> | null = null;

  let alwaysShowFieldActions = $derived(workbench.isTouch || workbench.isCompact);

  onDestroy(() => {
    if (copiedFieldTimer !== null) clearTimeout(copiedFieldTimer);
  });

  // Reset per-record collapse and hover state when switching to another hit/record.
  $effect(() => {
    void recordKey;
    collapsedJsonPaths = {};
    hoveredFieldPath = '';
  });

  function toggleJsonPath(path: string, e: MouseEvent) {
    e.stopPropagation();
    collapsedJsonPaths[path] = !collapsedJsonPaths[path];
  }

  function copyFieldValue(path: string, val: string, e: MouseEvent) {
    e.stopPropagation();
    void copyTextToClipboard(val);
    copiedFieldPath = path;
    if (copiedFieldTimer !== null) clearTimeout(copiedFieldTimer);
    copiedFieldTimer = setTimeout(() => {
      if (copiedFieldPath === path) copiedFieldPath = '';
      copiedFieldTimer = null;
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

{#snippet renderJsonKey(isArray: boolean, keyName: string)}
  {#if isArray}
    <span class="text-muted-foreground/70">[{keyName}]</span>
  {:else}
    {@render renderHighlighted(keyName)}
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
                  {@render renderJsonKey(isArray, k)}
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
                    {@render renderJsonKey(isArray, k)}
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
                  {@render renderJsonKey(isArray, k)}
                </span>
                {#if isMultiLineStr}
                  <div class="rounded-md border border-border/45 bg-secondary/35 px-2.5 py-1.5 whitespace-pre-wrap break-words leading-[1.6] text-foreground">
                    {@render renderHighlighted(strVal)}
                  </div>
                {:else}
                  <span class="text-foreground break-all">
                    {#if v === ''}
                      <span class="text-muted-foreground/50 italic">""</span>
                    {:else}
                      {@render renderHighlighted(strVal)}
                    {/if}
                    {#if numEpochHint}
                      <span class="ml-1.5 inline-block rounded bg-secondary/55 px-1.5 py-0.2 text-[10px] text-muted-foreground">
                        → {numEpochHint}
                      </span>
                    {/if}
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
