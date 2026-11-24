<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import {
    normalizePluginPreset,
    type NormalizedPluginOverrides,
  } from '$lib/prefilter';
  import type { DataSourceItem, PluginOverrides, PluginPreset } from '$lib/types';
  import Segmented from '../ui/Segmented.svelte';
  import {
    AlertTriangle,
    Check,
    Clock,
    Code2,
    Layers,
    Loader2,
    ScrollText,
    Sparkles,
  } from 'lucide-svelte';

  interface Props {
    preset: PluginPreset;
    overrides?: PluginOverrides;
    source?: DataSourceItem;
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
    source,
    onchange,
    timeFormat: _timeFormat = '',
    defaultAutoTimeFormat = '',
    ontimeformatchange,
    onsubmit: _onsubmit,
    oncancel: _oncancel,
  }: Props = $props();

  const t = $derived(workbench.t.ui);
  const catalog = $derived(workbench.prefilterCatalog);
  const isZh = $derived(workbench.locale === 'zh');

  type DetectState =
    | { status: 'idle' }
    | { status: 'loading' }
    | { status: 'matched'; typeLabel: string; sampleTime: string; sampleFile: string }
    | { status: 'unrecognized' };

  let detecting = $state(false);
  let detectSeq = 0;

  const normalizedPreset = $derived(normalizePluginPreset(preset));
  const showTimeDetectSection = $derived(Boolean(source) && normalizedPreset !== 'code');
  const savedDetect = $derived(source ? workbench.getDetectedTimeType(source.id) : null);

  const detectState = $derived.by<DetectState>(() => {
    if (detecting) return { status: 'loading' };
    if (!savedDetect) return { status: 'idle' };
    if (savedDetect.status === 'matched') {
      return {
        status: 'matched',
        typeLabel: savedDetect.typeLabel,
        sampleTime: savedDetect.sampleTime,
        sampleFile: savedDetect.sampleFile,
      };
    }
    return { status: 'unrecognized' };
  });

  $effect(() => {
    void source?.id;
    detecting = false;
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
      detecting = false;
      ontimeformatchange?.('', true);
    } else if (normalizedPreset === 'code') {
      ontimeformatchange?.(defaultAutoTimeFormat, true);
    }
    if (nextPreset === normalizedPreset) return;
    onchange(nextPreset, { enable: [], disable: [] });
  }

  async function runDetect() {
    if (!source || detecting) return;
    const seq = ++detectSeq;
    detecting = true;
    ontimeformatchange?.(defaultAutoTimeFormat, true);
    await workbench.detectSourceTimeType(source);
    if (seq !== detectSeq) return;
    detecting = false;
  }
</script>

<div class="space-y-2">
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

  {#if showTimeDetectSection}
    <div class="border-t border-border/40 pt-2">
      <div class="flex items-center justify-between gap-2">
        <span class="inline-flex shrink-0 items-center gap-1.5 text-[11.5px] font-medium text-muted-foreground">
          <Clock class="h-3.5 w-3.5 shrink-0 text-muted-foreground/80" />
          <span>{isZh ? '时间类型' : 'Time Type'}</span>
        </span>

        <div class="flex min-w-0 items-center gap-1.5">
          <!-- Time Type Status Window -->
          {#if detectState.status === 'loading'}
            <span class="inline-flex items-center gap-1 rounded-md bg-secondary/65 px-2 py-1 font-mono text-[10.5px] leading-none text-muted-foreground">
              <Loader2 class="h-3 w-3 animate-spin shrink-0" />
              <span>{isZh ? '识别中…' : 'Detecting…'}</span>
            </span>
          {:else if detectState.status === 'matched'}
            <span
              title={`${detectState.typeLabel} · ${detectState.sampleTime} (${detectState.sampleFile})`}
              class="inline-flex min-w-0 max-w-[200px] items-center gap-1 rounded-md bg-primary/12 px-2 py-1 font-mono text-[10.5px] leading-none text-primary ring-1 ring-inset ring-primary/30"
            >
              <Check class="h-3 w-3 shrink-0" />
              <span class="truncate">{detectState.typeLabel}</span>
            </span>
          {:else if detectState.status === 'unrecognized'}
            <span class="inline-flex items-center gap-1 rounded-md bg-status/12 px-2 py-1 font-mono text-[10.5px] leading-none text-status ring-1 ring-inset ring-status/30">
              <AlertTriangle class="h-3 w-3 shrink-0" />
              <span>{isZh ? '无法识别' : 'Unrecognized'}</span>
            </span>
          {:else}
            <span class="inline-flex items-center rounded-md bg-secondary/55 px-2 py-1 font-mono text-[10.5px] leading-none text-muted-foreground">
              {isZh ? '未检测' : 'Not checked'}
            </span>
          {/if}

          <button
            type="button"
            disabled={detectState.status === 'loading'}
            onclick={() => void runDetect()}
            title={isZh ? '采样日志自动识别时间类型' : 'Sample log lines to detect timestamp type'}
            class="touch-target inline-flex h-6 shrink-0 items-center gap-1 rounded-md border border-border/70 bg-background px-2 text-[11px] font-medium text-foreground hover:bg-secondary/70 active:bg-secondary disabled:opacity-50 cursor-pointer"
          >
            <Sparkles class="h-3 w-3 shrink-0 text-primary" />
            <span>{isZh ? '识别' : 'Detect'}</span>
          </button>
        </div>
      </div>

      {#if detectState.status === 'matched' && detectState.sampleTime}
        <div class="mt-1.5 flex items-center justify-end gap-1.5 font-mono text-[10.5px] text-muted-foreground tabular-nums">
          <span class="truncate">{detectState.sampleFile}</span>
          <span>·</span>
          <span class="shrink-0 text-foreground/85">{detectState.sampleTime}</span>
        </div>
      {/if}
    </div>
  {/if}
</div>
