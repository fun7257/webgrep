<script lang="ts">
  import { flushSync } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { TIME_FORMAT_PRESETS } from '$lib/time-range';
  import type { TimePreviewResponse } from '$lib/types';
  import {
    AlertTriangle,
    Check,
    Clock,
    Crosshair,
    FlaskConical,
    Sparkles,
    X,
  } from 'lucide-svelte';

  let {
    value,
    defaultAutoValue = '',
    onchange,
    onsubmit,
    oncancel,
  }: {
    value: string;
    defaultAutoValue?: string;
    onchange: (nextFormat: string, valid: boolean) => void;
    onsubmit?: () => void;
    oncancel?: () => void;
  } = $props();

  const t = $derived(workbench.t.ui);
  const tp = $derived(workbench.t.scopeBar.timePicker);
  const lang = $derived(workbench.locale);

  let customDraft = $state('');
  let sampleLine = $state('');
  let preview = $state<TimePreviewResponse | null>(null);
  let previewForFormat = $state('');
  let lastEmitted = $state<{ fmt: string; valid: boolean } | null>(null);
  let previewSeq = 0;
  let presetToggledOnDown = false;

  const effectiveFormat = $derived(customDraft.trim() || 'auto');
  const isAuto = $derived(effectiveFormat.toLowerCase() === 'auto');

  function resolveEmittedFormat(draft: string): string {
    const trimmed = draft.trim();
    if (!trimmed || trimmed.toLowerCase() === 'auto') {
      return defaultAutoValue;
    }
    return trimmed;
  }

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
    if (!ext || ext.toLowerCase() === 'auto') {
      if (customDraft.trim() !== '') {
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
      if (currentFmt === fmt) {
        emit(resolveEmittedFormat(customDraft), fmt.toLowerCase() === 'auto' ? true : res.validFormat);
      }
    }, 120);
    return () => clearTimeout(timer);
  });

  function applyPreset(presetValue: string, presetExample: string) {
    const nextIsAuto = presetValue.toLowerCase() === 'auto';
    flushSync(() => {
      customDraft = nextIsAuto ? '' : presetValue;
      const trimmedSample = sampleLine.trim();
      const isSamplePresetExample = TIME_FORMAT_PRESETS.some((p) => p.example === trimmedSample);
      if (!trimmedSample || isSamplePresetExample) {
        sampleLine = presetExample;
      }
      preview = null;
    });
    emit(nextIsAuto ? defaultAutoValue : presetValue, true);
  }

  function clearCustomFormat() {
    customDraft = '';
    preview = null;
    emit(defaultAutoValue, true);
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
  const hasSampleResult = $derived(
    !syntaxInvalid && sampleLine.trim().length > 0 && formatMatchesPreview
  );
  const sampleMatched = $derived(hasSampleResult && Boolean(preview?.matched && preview?.isoUtc));
  const formatHint = $derived(isAuto ? t.sourceTimeAutoHint : t.sourceTimeCustomHint);
</script>

<div class="space-y-2 rounded-md border border-border/50 bg-background/75 p-2">
  <!-- Quick preset pills -->
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
        class={`touch-target inline-flex items-center gap-1 rounded border px-1.5 py-0.5 text-[10.5px] font-mono cursor-pointer active:bg-secondary/60 ${
          active
            ? 'border-primary/55 bg-primary/10 text-primary font-medium'
            : 'border-border/65 bg-background/80 text-muted-foreground hover:border-border hover:text-foreground'
        }`}
        title={preset.id === 'auto' ? t.sourceTimeAutoHint : preset.example}
      >
        {#if preset.id === 'auto'}
          <Sparkles class="h-2.5 w-2.5 shrink-0" />
        {/if}
        <span>{lang === 'zh' ? preset.labelZh : preset.labelEn}</span>
      </button>
    {/each}
  </div>

  <!-- Single format input -->
  <div class="space-y-1">
    <div class="relative">
      {#if syntaxInvalid}
        <AlertTriangle class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-status" />
      {:else if isAuto}
        <Sparkles class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground/75" />
      {:else}
        <Clock class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-primary/80" />
      {/if}
      <input
        type="text"
        bind:value={customDraft}
        oninput={() => {
          const fmt = customDraft.trim() || 'auto';
          preview = null;
          emit(
            resolveEmittedFormat(customDraft),
            fmt.toLowerCase() === 'auto' ? true : computeValid(fmt)
          );
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
        title={formatHint}
        aria-label={t.sourceTimeFormatLabel}
        placeholder={t.sourceTimeFormatPlaceholder}
        spellcheck="false"
        autocomplete="off"
        class={`h-8 w-full rounded-md border bg-background pl-8 pr-11 font-mono text-[11.5px] text-foreground placeholder:text-muted-foreground/60 focus:outline-none [@media(any-pointer:coarse)]:text-[16px] ${
          syntaxInvalid
            ? 'border-status/70 focus:border-status'
            : 'border-border/75 focus:border-primary/60'
        }`}
      />
      {#if isAuto}
        <span
          class="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 rounded bg-secondary/80 px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground"
        >
          {t.sourceBadgeAuto}
        </span>
      {:else}
        <button
          type="button"
          onclick={clearCustomFormat}
          title={t.sourceTimeAuto}
          aria-label={t.sourceTimeAuto}
          class="touch-target absolute right-1 top-1/2 flex h-6 w-6 -translate-y-1/2 items-center justify-center rounded text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
        >
          <X class="h-3 w-3" />
        </button>
      {/if}
    </div>
    {#if syntaxInvalid}
      <div class="flex items-center gap-1.5 text-[11px] text-status">
        <AlertTriangle class="h-3 w-3 shrink-0" />
        <span class="truncate">{preview?.errorMessage || preview?.error || tp.previewInvalid}</span>
      </div>
    {/if}
  </div>

  <!-- Compact optional sample-line verification row -->
  <div class="space-y-1">
    <div class="flex items-center gap-1.5">
      <div class="relative min-w-0 flex-1">
        {#if sampleMatched}
          <Check class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-primary" />
        {:else if hasSampleResult}
          <AlertTriangle class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-status" />
        {:else}
          <FlaskConical class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground/70" />
        {/if}
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
          title={hasSampleResult
            ? sampleMatched
              ? `${tp.previewMatched}: ${preview?.localDisplay || preview?.isoUtc}${preview?.isoUtc ? ` (${preview.isoUtc})` : ''}`
              : isAuto
                ? tp.previewAutoNoMatch
                : tp.previewNoMatch
            : tp.samplePlaceholder}
          aria-label={tp.samplePlaceholder}
          placeholder={tp.samplePlaceholder}
          spellcheck="false"
          class={`h-8 w-full rounded-md border bg-background/90 pl-8 font-mono text-[11px] text-foreground placeholder:text-muted-foreground/60 focus:outline-none [@media(any-pointer:coarse)]:text-[16px] ${
            sampleLine ? 'pr-7' : 'pr-2.5'
          } ${
            sampleMatched
              ? 'border-primary/45 focus:border-primary'
              : hasSampleResult
                ? 'border-status/55 focus:border-status'
                : 'border-border/70 focus:border-primary/60'
          }`}
        />
        {#if sampleLine}
          <button
            type="button"
            onclick={() => (sampleLine = '')}
            title={workbench.t.searchBar.clearDraftTitle}
            aria-label={workbench.t.searchBar.clearDraftTitle}
            class="touch-target absolute right-1 top-1/2 flex h-6 w-6 -translate-y-1/2 items-center justify-center rounded text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
          >
            <X class="h-3 w-3" />
          </button>
        {/if}
      </div>
      {#if workbench.activeHit?.text}
        <button
          type="button"
          onclick={fillSelectedHitLine}
          title={tp.sampleUseSelected}
          aria-label={tp.sampleUseSelected}
          class="touch-target flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-border/70 bg-background text-muted-foreground hover:bg-secondary/70 hover:text-foreground cursor-pointer"
        >
          <Crosshair class="h-3.5 w-3.5" />
        </button>
      {/if}
    </div>

    {#if hasSampleResult}
      <div
        class={`flex items-center gap-1.5 rounded px-2 py-1 font-mono text-[10.5px] ${
          sampleMatched
            ? 'bg-primary/10 text-primary'
            : 'bg-status/10 text-status'
        }`}
        title={sampleMatched
          ? preview?.isoUtc || ''
          : isAuto
            ? tp.previewAutoNoMatch
            : tp.previewNoMatch}
      >
        {#if sampleMatched}
          <Check class="h-3 w-3 shrink-0" />
          <span class="truncate tabular-nums">{preview?.localDisplay || preview?.isoUtc}</span>
        {:else}
          <AlertTriangle class="h-3 w-3 shrink-0" />
          <span class="truncate">{tp.previewNoMatch}</span>
        {/if}
      </div>
    {/if}
  </div>
</div>
