<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import {
    normalizePluginPreset,
    type NormalizedPluginOverrides,
  } from '$lib/prefilter';
  import type { PluginOverrides, PluginPreset } from '$lib/types';
  import Segmented from '../ui/Segmented.svelte';
  import SourceTimeFormatEditor from './SourceTimeFormatEditor.svelte';
  import { ChevronDown, ChevronRight, Clock, Code2, Layers, ScrollText } from 'lucide-svelte';

  interface Props {
    preset: PluginPreset;
    overrides?: PluginOverrides;
    onchange: (nextPreset: PluginPreset, nextOverrides: NormalizedPluginOverrides) => void;
    timeFormat?: string;
    defaultAutoTimeFormat?: string;
    ontimeformatchange?: (nextFormat: string, valid: boolean) => void;
    onsubmit?: () => void;
    oncancel?: () => void;
  }

  let {
    preset,
    overrides: _overrides,
    onchange,
    timeFormat = '',
    defaultAutoTimeFormat = '',
    ontimeformatchange,
    onsubmit,
    oncancel,
  }: Props = $props();

  const t = $derived(workbench.t.ui);
  const catalog = $derived(workbench.prefilterCatalog);

  let formatExpanded = $state(false);

  const normalizedPreset = $derived(normalizePluginPreset(preset));
  const trimmedFormat = $derived(timeFormat.trim());
  const hasCustomFormat = $derived(
    Boolean(trimmedFormat) && trimmedFormat.toLowerCase() !== 'auto'
  );
  const showTimeFormatSection = $derived(
    Boolean(ontimeformatchange) && normalizedPreset !== 'code'
  );

  $effect(() => {
    if (hasCustomFormat) {
      formatExpanded = true;
    }
  });

  const presetOptions = $derived(
    catalog.presets.map((p) => {
      const text = t.sourcePrefilterPresets[p.id];
      return {
        value: p.id,
        label: text?.label ?? p.id,
        icon: p.id === 'code' ? Code2 : ScrollText,
        title: text?.hint ?? p.description,
      };
    })
  );

  const activePresetHint = $derived(
    t.sourcePrefilterPresets[normalizedPreset]?.hint ??
      catalog.presets.find((p) => p.id === normalizedPreset)?.description ??
      ''
  );

  function handlePresetChange(nextPreset: PluginPreset) {
    if (nextPreset === 'code') {
      formatExpanded = false;
      ontimeformatchange?.('', true);
    } else if (normalizedPreset === 'code' && !hasCustomFormat) {
      ontimeformatchange?.(defaultAutoTimeFormat, true);
    }
    if (nextPreset === normalizedPreset) return;
    onchange(nextPreset, { enable: [], disable: [] });
  }
</script>

<div class="space-y-2 rounded-lg border border-border/65 bg-secondary/15 p-2.5">
  <div class="flex items-center justify-between gap-2" title={activePresetHint}>
    <span class="inline-flex min-w-0 items-center gap-1.5 text-[11.5px] font-medium text-muted-foreground">
      <Layers class="h-3.5 w-3.5 shrink-0 text-muted-foreground/80" />
      <span class="truncate">{t.sourcePrefilterPresetLabel}</span>
    </span>
    <Segmented
      options={presetOptions}
      value={normalizedPreset}
      onchange={handlePresetChange}
    />
  </div>

  {#if showTimeFormatSection}
    <div class="border-t border-border/45 pt-2">
      <button
        type="button"
        aria-expanded={formatExpanded}
        onclick={() => (formatExpanded = !formatExpanded)}
        title={hasCustomFormat ? `${t.sourceTimeFormatLabel}: ${trimmedFormat}` : t.sourceTimeAutoHint}
        class="touch-target flex w-full items-center justify-between gap-2 rounded-md px-1 py-0.5 text-[11.5px] text-muted-foreground hover:text-foreground cursor-pointer"
      >
        <span class="inline-flex min-w-0 items-center gap-1.5">
          {#if formatExpanded}
            <ChevronDown class="h-3.5 w-3.5 shrink-0 text-muted-foreground/75" />
          {:else}
            <ChevronRight class="h-3.5 w-3.5 shrink-0 text-muted-foreground/75" />
          {/if}
          <Clock class="h-3.5 w-3.5 shrink-0 text-muted-foreground/80" />
          <span class="truncate">{t.sourceTimeFormatLabel}</span>
        </span>

        <span
          class={`max-w-[55%] shrink-0 truncate rounded px-1.5 py-0.5 font-mono text-[10.5px] ${
            hasCustomFormat
              ? 'bg-primary/10 font-medium text-primary ring-1 ring-inset ring-primary/20'
              : 'bg-secondary/75 text-muted-foreground'
          }`}
        >
          {hasCustomFormat ? trimmedFormat : t.sourceBadgeAuto}
        </span>
      </button>

      {#if formatExpanded}
        <div class="mt-2">
          <SourceTimeFormatEditor
            value={timeFormat}
            defaultAutoValue={defaultAutoTimeFormat}
            onchange={(fmt, valid) => ontimeformatchange?.(fmt, valid)}
            {onsubmit}
            {oncancel}
          />
        </div>
      {/if}
    </div>
  {/if}
</div>
