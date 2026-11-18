<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import {
    hasPluginOverrides,
    isPluginDefaultEnabledForPreset,
    isPluginEffectiveEnabled,
    normalizePluginOverrides,
    normalizePluginPreset,
    togglePluginOverride,
    type NormalizedPluginMetadata,
    type NormalizedPluginOverrides,
  } from '$lib/prefilter';
  import type { PluginOverrides, PluginPreset } from '$lib/types';
  import Segmented from '../ui/Segmented.svelte';
  import Switch from '../ui/Switch.svelte';
  import SourceTimeFormatEditor from './SourceTimeFormatEditor.svelte';
  import { ChevronDown, ChevronRight, Clock, Filter, RotateCcw } from 'lucide-svelte';

  interface Props {
    preset: PluginPreset;
    overrides: PluginOverrides;
    onchange: (nextPreset: PluginPreset, nextOverrides: NormalizedPluginOverrides) => void;
    timeFormat?: string;
    defaultAutoTimeFormat?: string;
    ontimeformatchange?: (nextFormat: string, valid: boolean) => void;
    onsubmit?: () => void;
    oncancel?: () => void;
  }

  let {
    preset,
    overrides,
    onchange,
    timeFormat = '',
    defaultAutoTimeFormat = '',
    ontimeformatchange,
    onsubmit,
    oncancel,
  }: Props = $props();

  const t = $derived(workbench.t.ui);
  const catalog = $derived(workbench.prefilterCatalog);

  let expanded = $state(false);
  let formatExpanded = $state(false);

  const normalizedPreset = $derived(normalizePluginPreset(preset));
  const normOverrides = $derived(normalizePluginOverrides(overrides));
  const customized = $derived(hasPluginOverrides(normOverrides));

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
        title: text?.hint ?? p.description,
      };
    })
  );

  const activePresetHint = $derived(
    t.sourcePrefilterPresets[normalizedPreset]?.hint ??
      catalog.presets.find((p) => p.id === normalizedPreset)?.description ??
      ''
  );

  const activePluginCount = $derived(
    catalog.plugins.reduce(
      (acc, plugin) =>
        acc + (isPluginEffectiveEnabled(plugin, normalizedPreset, normOverrides) ? 1 : 0),
      0
    )
  );

  function handlePresetChange(nextPreset: PluginPreset) {
    if (nextPreset === 'code') {
      formatExpanded = false;
      ontimeformatchange?.('', true);
    } else if (normalizedPreset === 'code' && !hasCustomFormat) {
      ontimeformatchange?.(defaultAutoTimeFormat, true);
    }
    if (nextPreset === normalizedPreset && !customized) return;
    onchange(nextPreset, { enable: [], disable: [] });
  }

  function handleTogglePlugin(plugin: NormalizedPluginMetadata, nextEnabled: boolean) {
    const nextOverrides = togglePluginOverride(plugin, normalizedPreset, normOverrides, nextEnabled);
    onchange(normalizedPreset, nextOverrides);
  }

  function handleResetOverrides() {
    if (!customized) return;
    onchange(normalizedPreset, { enable: [], disable: [] });
  }
</script>

<div class="space-y-1.5 rounded-lg border border-border/70 bg-secondary/15 p-2.5">
  <div class="flex flex-wrap items-center justify-between gap-2" title={activePresetHint}>
    <span class="text-[11px] font-medium text-muted-foreground">
      {t.sourcePrefilterPresetLabel}
    </span>
    <Segmented
      options={presetOptions}
      value={normalizedPreset}
      onchange={handlePresetChange}
    />
  </div>

  <p class="text-[11px] leading-relaxed text-muted-foreground/85">
    {activePresetHint}
  </p>

  {#if showTimeFormatSection}
    <div class="border-t border-border/45 pt-1.5">
      <div class="flex items-center justify-between gap-2">
        <button
          type="button"
          aria-expanded={formatExpanded}
          onclick={() => (formatExpanded = !formatExpanded)}
          title={hasCustomFormat ? trimmedFormat : t.sourceTimeAutoHint}
          class="touch-target inline-flex min-w-0 items-center gap-1.5 rounded px-1 py-0.5 text-[11px] text-muted-foreground hover:text-foreground cursor-pointer"
        >
          {#if formatExpanded}
            <ChevronDown class="h-3 w-3 shrink-0" />
          {:else}
            <ChevronRight class="h-3 w-3 shrink-0" />
          {/if}
          <Clock class="h-3 w-3 shrink-0" />
          <span class="truncate">{t.sourceTimeFormatLabel}</span>
        </button>

        <button
          type="button"
          onclick={() => (formatExpanded = !formatExpanded)}
          title={hasCustomFormat ? trimmedFormat : t.sourceTimeAutoHint}
          class={`rounded px-1.5 py-0.5 font-mono text-[10px] cursor-pointer ${
            hasCustomFormat
              ? 'bg-primary/10 font-medium text-primary ring-1 ring-inset ring-primary/20'
              : 'bg-secondary/75 text-muted-foreground hover:text-foreground'
          }`}
        >
          {hasCustomFormat ? trimmedFormat : 'auto'}
        </button>
      </div>

      {#if formatExpanded}
        <div class="mt-1.5">
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

  <div class="border-t border-border/45 pt-1.5">
    <div class="flex items-center justify-between gap-2">
      <button
        type="button"
        aria-expanded={expanded}
        onclick={() => (expanded = !expanded)}
        title={activePresetHint}
        class="touch-target inline-flex min-w-0 items-center gap-1.5 rounded px-1 py-0.5 text-[11px] text-muted-foreground hover:text-foreground cursor-pointer"
      >
        {#if expanded}
          <ChevronDown class="h-3 w-3 shrink-0" />
        {:else}
          <ChevronRight class="h-3 w-3 shrink-0" />
        {/if}
        <Filter class="h-3 w-3 shrink-0" />
        <span class="truncate">{t.sourcePrefilterCustomize}</span>
      </button>

      <div class="flex shrink-0 items-center gap-1.5">
        {#if customized}
          <span
            class="rounded bg-primary/10 px-1.5 py-0.5 font-mono text-[10px] font-medium tabular-nums text-primary ring-1 ring-inset ring-primary/20"
            title={t.sourcePrefilterOverriddenTitle}
          >
            {t.sourcePrefilterCustomBadge(normOverrides.enable.length, normOverrides.disable.length)}
          </span>
          {#if expanded}
            <button
              type="button"
              onclick={handleResetOverrides}
              title={t.sourcePrefilterReset}
              aria-label={t.sourcePrefilterReset}
              class="touch-target inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10.5px] text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
            >
              <RotateCcw class="h-2.5 w-2.5" />
              <span>{t.sourcePrefilterReset}</span>
            </button>
          {/if}
        {:else}
          <span class="font-mono text-[10.5px] tabular-nums text-muted-foreground/75">
            {activePluginCount}/{catalog.plugins.length}
          </span>
        {/if}
      </div>
    </div>

    {#if expanded}
      <div class="mt-1.5 divide-y divide-border/35 rounded-md border border-border/50 bg-background/75 px-2.5">
        {#each catalog.plugins as plugin (plugin.id)}
          {@const checked = isPluginEffectiveEnabled(plugin, normalizedPreset, normOverrides)}
          {@const defaultOn = isPluginDefaultEnabledForPreset(plugin, normalizedPreset)}
          {@const overridden = checked !== defaultOn}
          {@const text = t.sourcePrefilterPlugins[plugin.id]}
          {@const label = text?.label ?? plugin.id}
          {@const desc = [text?.desc || plugin.description || plugin.id, plugin.stages.join(' · '), plugin.costHint]
            .filter(Boolean)
            .join(' · ')}
          <div class="flex min-h-9 items-center justify-between gap-2 py-1" title={desc}>
            <div class="flex min-w-0 items-center gap-1.5">
              {#if overridden}
                <span
                  class="h-1.5 w-1.5 shrink-0 rounded-full bg-primary"
                  title={t.sourcePrefilterOverriddenTitle}
                ></span>
              {/if}
              <span class="truncate text-[11.5px] text-foreground/90">{label}</span>
              <code class="hidden sm:inline shrink-0 font-mono text-[10px] text-muted-foreground/70">
                {plugin.id}
              </code>
            </div>
            <Switch
              {checked}
              title={desc}
              onchange={(next) => handleTogglePlugin(plugin, next)}
            />
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>
