<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { TIME_FORMAT_PRESETS } from '$lib/time-range';
  import type { TimePreviewResponse } from '$lib/types';
  import { Clock, FileClock, X } from 'lucide-svelte';
  import Segmented from '../ui/Segmented.svelte';

  type TimeBasis = 'mtime' | 'content';

  let {
    value,
    onchange,
    onsubmit,
    oncancel,
  }: {
    value: string;
    onchange: (nextFormat: string, valid: boolean) => void;
    onsubmit?: () => void;
    oncancel?: () => void;
  } = $props();

  const t = $derived(workbench.t.ui);
  const tp = $derived(workbench.t.scopeBar.timePicker);
  const lang = $derived(workbench.locale);

  let basis = $state<TimeBasis>('mtime');
  let customDraft = $state('');
  let sampleLine = $state('');
  let preview = $state<TimePreviewResponse | null>(null);
  let previewForFormat = $state('');
  let lastEmitted = $state<{ fmt: string; valid: boolean } | null>(null);
  let previewSeq = 0;
  let presetToggledOnDown = false;

  const effectiveFormat = $derived(customDraft.trim() || 'auto');
  const isAuto = $derived(effectiveFormat.toLowerCase() === 'auto');

  const basisOptions = $derived([
    {
      value: 'mtime' as const,
      label: t.sourceTimeMtime,
      icon: FileClock,
      title: t.sourceTimeMtimeHint,
    },
    {
      value: 'content' as const,
      label: t.sourceTimeContent,
      icon: Clock,
      title: t.sourceTimeContentHint,
    },
  ]);

  function emit(fmt: string, valid: boolean) {
    if (lastEmitted && lastEmitted.fmt === fmt && lastEmitted.valid === valid) return;
    lastEmitted = { fmt, valid };
    onchange(fmt, valid);
  }

  function computeValid(fmt: string): boolean {
    if (!fmt || fmt.toLowerCase() === 'auto') return true;
    if (previewForFormat === fmt && preview) return preview.validFormat;
    return true;
  }

  $effect(() => {
    const ext = value.trim();
    if (!ext) {
      basis = 'mtime';
      customDraft = '';
      return;
    }
    basis = 'content';
    if (ext.toLowerCase() === 'auto') {
      if (customDraft.trim().toLowerCase() === 'auto') {
        customDraft = '';
      }
      return;
    }
    if (customDraft.trim() !== ext) {
      customDraft = ext;
    }
  });

  // Live syntax check + sample log line preview for both auto and custom formats
  $effect(() => {
    if (basis !== 'content') {
      preview = null;
      return;
    }
    const fmt = effectiveFormat;
    const sample = sampleLine.trim();
    if (fmt.toLowerCase() === 'auto' && !sample) {
      preview = null;
      previewForFormat = 'auto';
      return;
    }
    const seq = ++previewSeq;
    const timer = setTimeout(async () => {
      const res = await workbench.previewTimeFormat(fmt, sample);
      if (seq !== previewSeq) return;
      preview = res;
      previewForFormat = fmt;
      const currentFmt = customDraft.trim() || 'auto';
      if (basis === 'content' && currentFmt === fmt) {
        emit(fmt, fmt.toLowerCase() === 'auto' ? true : res.validFormat);
      }
    }, 120);
    return () => clearTimeout(timer);
  });

  function handleBasisChange(next: TimeBasis) {
    if (basis === next) return;
    basis = next;
    if (next === 'mtime') {
      emit('', true);
      return;
    }
    const fmt = customDraft.trim() || 'auto';
    emit(fmt, computeValid(fmt));
  }

  function applyPreset(presetValue: string, presetExample: string) {
    basis = 'content';
    const nextIsAuto = presetValue.toLowerCase() === 'auto';
    customDraft = nextIsAuto ? '' : presetValue;
    const trimmedSample = sampleLine.trim();
    const isSamplePresetExample = TIME_FORMAT_PRESETS.some((p) => p.example === trimmedSample);
    if (!trimmedSample || isSamplePresetExample) {
      sampleLine = presetExample;
    }
    preview = null;
    const fmt = nextIsAuto ? 'auto' : presetValue;
    emit(fmt, true);
  }

  function clearCustomFormat() {
    customDraft = '';
    preview = null;
    emit('auto', true);
  }

  function fillSelectedHitLine() {
    const firstLine = workbench.activeHit?.text.split(/\r?\n/, 1)[0]?.trim() ?? '';
    if (firstLine) sampleLine = firstLine;
  }

  const formatMatchesPreview = $derived(
    preview !== null && previewForFormat === effectiveFormat
  );
  const syntaxInvalid = $derived(
    !isAuto && formatMatchesPreview && preview?.validFormat === false
  );
</script>

<div class="space-y-2 rounded-lg border border-border/70 bg-secondary/15 p-2.5">
  <div class="flex flex-wrap items-center justify-between gap-2">
    <span class="text-[11px] font-medium text-muted-foreground">
      {t.sourceTimeBasisLabel}
    </span>
    <Segmented
      options={basisOptions}
      value={basis}
      onchange={handleBasisChange}
    />
  </div>

  <p class="text-[11px] leading-relaxed text-muted-foreground/90">
    {basis === 'mtime'
      ? t.sourceTimeMtimeHint
      : isAuto
        ? t.sourceTimeAutoHint
        : t.sourceTimeCustomHint}
  </p>

  {#if basis === 'content'}
    <div class="space-y-2 border-t border-border/50 pt-2">
      <!-- Preset chips (with 自动识别 as first option + yyyy-hm & human picture formats) -->
      <div class="flex flex-wrap items-center gap-1">
        {#each TIME_FORMAT_PRESETS as preset (preset.id)}
          {@const active =
            preset.id === 'auto'
              ? isAuto
              : !isAuto && effectiveFormat === preset.value}
          <button
            type="button"
            onpointerdown={(e) => {
              if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
                presetToggledOnDown = true;
                applyPreset(preset.value, preset.example);
              }
            }}
            onclick={(e) => {
              if (presetToggledOnDown && e.detail > 0) {
                presetToggledOnDown = false;
                return;
              }
              presetToggledOnDown = false;
              applyPreset(preset.value, preset.example);
            }}
            class={`touch-target rounded border px-2 py-0.5 text-[11px] font-mono active:bg-secondary/60 ${
              active
                ? 'border-primary/60 bg-primary/10 text-primary font-medium'
                : 'border-border/70 bg-background/80 text-muted-foreground hover:border-border hover:text-foreground'
            }`}
            title={preset.example}
          >
            {lang === 'zh' ? preset.labelZh : preset.labelEn}
          </button>
        {/each}
      </div>

      <!-- Format input: blank means 'auto'; enter e.g. yyyy-hm when auto cannot recognize -->
      <div class="space-y-1">
        <div class="flex items-center justify-between gap-2">
          <label
            for="wg-source-time-format"
            class="text-[11px] font-medium text-muted-foreground"
          >
            {t.sourceTimeFormatLabel}
          </label>
          {#if isAuto}
            <span class="rounded bg-secondary px-1.5 py-0.5 font-mono text-[10px] text-foreground/80">
              auto
            </span>
          {:else}
            <button
              type="button"
              onclick={clearCustomFormat}
              class="inline-flex items-center gap-0.5 rounded px-1.5 py-0.5 text-[10px] text-muted-foreground hover:bg-secondary hover:text-foreground"
              title={lang === 'zh' ? '恢复自动识别' : 'Reset to auto'}
            >
              <X class="h-2.5 w-2.5" />
              <span>{lang === 'zh' ? '恢复自动识别' : 'Use auto'}</span>
            </button>
          {/if}
        </div>
        <input
          id="wg-source-time-format"
          type="text"
          bind:value={customDraft}
          oninput={() => {
            const fmt = customDraft.trim() || 'auto';
            preview = null;
            emit(fmt, fmt.toLowerCase() === 'auto' ? true : computeValid(fmt));
          }}
          onkeydown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              onsubmit?.();
            } else if (e.key === 'Escape' && oncancel) {
              e.preventDefault();
              oncancel();
            }
          }}
          placeholder={t.sourceTimeFormatPlaceholder}
          spellcheck="false"
          autocomplete="off"
          class={`w-full rounded-md border bg-background px-2.5 py-1.5 font-mono text-[12px] text-foreground focus:outline-none [@media(any-pointer:coarse)]:text-[16px] ${
            syntaxInvalid
              ? 'border-status/70 focus:border-status'
              : 'border-border focus:border-primary'
          }`}
        />
        {#if syntaxInvalid}
          <div class="text-[11px] text-status">
            {preview?.errorMessage || preview?.error || tp.previewInvalid}
          </div>
        {/if}
      </div>

      <!-- Always-available live sample log line tester (works for BOTH auto & custom formats) -->
      <div class="space-y-1">
        <div class="flex items-center gap-1.5">
          <input
            type="text"
            bind:value={sampleLine}
            onkeydown={(e) => {
              if (e.key === 'Enter') {
                e.preventDefault();
                onsubmit?.();
              } else if (e.key === 'Escape' && oncancel) {
                e.preventDefault();
                oncancel();
              }
            }}
            placeholder={tp.samplePlaceholder}
            spellcheck="false"
            class="min-w-0 flex-1 rounded-md border border-border/70 bg-background/90 px-2.5 py-1 font-mono text-[11px] text-foreground focus:border-primary focus:outline-none [@media(any-pointer:coarse)]:text-[16px]"
          />
          {#if workbench.activeHit?.text}
            <button
              type="button"
              onclick={fillSelectedHitLine}
              class="touch-target shrink-0 rounded-md border border-border/70 bg-background px-2 py-1 text-[11px] text-muted-foreground hover:text-foreground"
            >
              {tp.sampleUseSelected}
            </button>
          {/if}
        </div>
        {#if !syntaxInvalid && sampleLine.trim().length > 0 && formatMatchesPreview}
          <div
            class={`rounded px-2 py-1 font-mono text-[11px] ${
              preview?.matched
                ? 'bg-primary/10 text-primary'
                : 'bg-secondary/60 text-muted-foreground'
            }`}
          >
            {#if preview?.matched && preview.isoUtc}
              <span>{tp.previewMatched}: {preview.localDisplay || preview.isoUtc}</span>
              {#if preview.localDisplay && preview.isoUtc && preview.localDisplay !== preview.isoUtc}
                <span class="ml-1.5 text-[10px] opacity-75">({preview.isoUtc})</span>
              {/if}
            {:else}
              <span>{isAuto ? tp.previewAutoNoMatch : tp.previewNoMatch}</span>
            {/if}
          </div>
        {/if}
      </div>
    </div>
  {/if}
</div>
