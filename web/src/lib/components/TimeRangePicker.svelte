<script lang="ts">
  import { untrack } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import type { TimePreset } from '$lib/types';
  import {
    BUILTIN_TIME_PRESETS,
    buildCalendarMonthGrid,
    buildCustomRangeSpec,
    formatTimeScopeLabel,
    formatYmd,
    isValidYmd,
    parseCustomRangeDraft,
    parsePastedDateTime,
  } from '$lib/time-range';
  import { ChevronLeft, ChevronRight, Clock, FileClock, RotateCcw, X } from 'lucide-svelte';

  interface Props {
    value: TimePreset;
    onApply: (spec: TimePreset) => void;
    onClose: () => void;
  }

  let { value, onApply, onClose }: Props = $props();

  const initialNow = new Date();
  const initialDraft = untrack(() => parseCustomRangeDraft(value, initialNow.getTime()));
  const initialRefDate = initialDraft.startDate && isValidYmd(initialDraft.startDate)
    ? new Date(
        Number(initialDraft.startDate.slice(0, 4)),
        Number(initialDraft.startDate.slice(5, 7)) - 1,
        1
      )
    : initialNow;

  let startDate = $state<string>(initialDraft.startDate);
  let startTime = $state<string>(initialDraft.startTime);
  let endDate = $state<string>(initialDraft.endDate);
  let endTime = $state<string>(initialDraft.endTime);

  let viewYear = $state<number>(initialRefDate.getFullYear());
  let viewMonth = $state<number>(initialRefDate.getMonth());
  let pickingPhase = $state<'start' | 'end'>('start');
  let hoverDate = $state<string | null>(null);
  let validationError = $state<'invalid_start' | 'invalid_end' | null>(null);

  let panelEl = $state<HTMLDivElement | null>(null);
  let offsetX = $state<number>(0);
  let maxPanelH = $state<number | null>(null);

  const s = $derived(workbench.t.scopeBar);
  const tp = $derived(s.timePicker);
  const basis = $derived(workbench.getEffectiveTimeBasisSummary());

  const todayYmd = $derived(formatYmd(new Date()));

  const monthLabel = $derived(
    `${viewYear}-${String(viewMonth + 1).padStart(2, '0')}`
  );

  const calendarCells = $derived(buildCalendarMonthGrid(viewYear, viewMonth, todayYmd));

  const effectiveRange = $derived.by(() => {
    const validStart = isValidYmd(startDate) ? startDate : '';
    const validEnd = isValidYmd(endDate) ? endDate : '';
    if (pickingPhase === 'end' && validStart && hoverDate) {
      return hoverDate < validStart
        ? { lo: hoverDate, hi: validStart }
        : { lo: validStart, hi: hoverDate };
    }
    if (validStart && validEnd) {
      return validEnd < validStart
        ? { lo: validEnd, hi: validStart }
        : { lo: validStart, hi: validEnd };
    }
    if (validStart) {
      return { lo: validStart, hi: validStart };
    }
    if (validEnd) {
      return { lo: validEnd, hi: validEnd };
    }
    return { lo: '', hi: '' };
  });

  const compiledPreview = $derived.by(() =>
    buildCustomRangeSpec({ startDate, startTime, endDate, endTime })
  );

  const previewLabel = $derived.by(() => {
    if (compiledPreview.error || !compiledPreview.spec) return '';
    return formatTimeScopeLabel(compiledPreview.spec, s.timeLabels);
  });

  $effect(() => {
    if (workbench.isCompact) {
      offsetX = 0;
      return;
    }
    const el = panelEl;
    if (!el) return;
    offsetX = 0;
    const raf = requestAnimationFrame(() => {
      const rect = el.getBoundingClientRect();
      // Keep the whole panel (incl. Apply footer) inside the viewport; scroll internally if needed.
      maxPanelH = Math.max(240, Math.floor(window.innerHeight - rect.top - 12));
      const container = (el.closest('main') as HTMLElement | null)?.getBoundingClientRect();
      const minLeft = Math.max(8, container?.left ?? 8);
      const maxRight = Math.min(window.innerWidth - 8, container?.right ?? window.innerWidth - 8);
      if (rect.right > maxRight) {
        offsetX = Math.max(minLeft - rect.left, maxRight - rect.right);
      } else if (rect.left < minLeft) {
        offsetX = minLeft - rect.left;
      }
    });
    return () => cancelAnimationFrame(raf);
  });

  function shiftMonth(delta: number) {
    const next = new Date(viewYear, viewMonth + delta, 1);
    viewYear = next.getFullYear();
    viewMonth = next.getMonth();
  }

  function jumpToToday() {
    const now = new Date();
    viewYear = now.getFullYear();
    viewMonth = now.getMonth();
  }

  function syncMonthToDate(ymd: string) {
    if (!isValidYmd(ymd)) return;
    viewYear = Number(ymd.slice(0, 4));
    viewMonth = Number(ymd.slice(5, 7)) - 1;
  }

  function handleDayClick(ymd: string, inMonth: boolean) {
    validationError = null;
    if (!inMonth) {
      syncMonthToDate(ymd);
    }
    if (pickingPhase === 'start' || !startDate) {
      startDate = ymd;
      endDate = ymd;
      if (!startTime.trim()) startTime = '00:00:00';
      if (!endTime.trim()) endTime = '23:59:59';
      pickingPhase = 'end';
      return;
    }

    if (ymd < startDate) {
      endDate = startDate;
      startDate = ymd;
    } else {
      endDate = ymd;
    }
    if (!endTime.trim()) endTime = '23:59:59';
    pickingPhase = 'start';
    hoverDate = null;
  }

  function handlePaste(target: 'start' | 'end', e: ClipboardEvent) {
    const raw = e.clipboardData?.getData('text') ?? '';
    const parsed = parsePastedDateTime(raw);
    if (!parsed) return;
    e.preventDefault();
    validationError = null;
    if (target === 'start') {
      startDate = parsed.date;
      if (parsed.time) startTime = parsed.time;
      syncMonthToDate(parsed.date);
    } else {
      endDate = parsed.date;
      if (parsed.time) endTime = parsed.time;
      syncMonthToDate(parsed.date);
    }
  }

  function handleInputKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      submitCustomRange();
    }
  }

  function setEndNow() {
    validationError = null;
    endDate = '';
    endTime = '';
    pickingPhase = 'start';
    hoverDate = null;
  }

  function clearStart() {
    validationError = null;
    startDate = '';
    startTime = '';
    pickingPhase = 'start';
    hoverDate = null;
  }

  function submitCustomRange() {
    const res = buildCustomRangeSpec({ startDate, startTime, endDate, endTime });
    if (res.error === 'empty') {
      onApply('');
      return;
    }
    if (res.error === 'invalid_start' || res.error === 'invalid_end') {
      validationError = res.error;
      return;
    }
    validationError = null;
    onApply(res.spec);
  }
</script>

{#snippet pickerContent()}
  <!-- 0. Read-only Summary of Active Sources' Time Filtering Basis -->
  <div class="mb-2 flex items-center justify-between gap-2 rounded-lg bg-secondary/45 px-2.5 py-1.5 text-[11px]">
    <span class="flex min-w-0 items-center gap-1.5 text-muted-foreground">
      {#if basis.contentCount > 0}
        <Clock class="h-3 w-3 shrink-0 text-primary/80" />
      {:else}
        <FileClock class="h-3 w-3 shrink-0" />
      {/if}
      <span class="truncate">
        {basis.contentCount === 0
          ? tp.basisMtimeOnly
          : basis.mtimeCount === 0
            ? tp.basisContentOnly(basis.contentCount)
            : tp.basisMixed(basis.contentCount, basis.mtimeCount)}
      </span>
    </span>
    <button
      type="button"
      onclick={() => {
        onClose();
        workbench.openSettings('sources');
      }}
      class="shrink-0 font-medium text-primary hover:underline cursor-pointer"
    >
      {tp.configureSourceTime}
    </button>
  </div>

  <!-- 1. Quick Preset Chips -->
  <div class="flex flex-wrap gap-1">
    {#each BUILTIN_TIME_PRESETS as preset (preset)}
      {@const active = value === preset}
      <button
        type="button"
        onclick={() => onApply(preset)}
        title={s.timeLabels[preset] ?? preset}
        class={`touch-target rounded-md border px-2 py-1 text-[11.5px] font-mono transition-colors cursor-pointer ${
          active
            ? 'border-primary/40 bg-primary/15 text-primary font-medium'
            : 'border-border/60 bg-secondary/40 text-foreground hover:bg-secondary'
        }`}
      >
        {s.timeShortLabels[preset] ?? s.timeLabels[preset] ?? preset}
      </button>
    {/each}
  </div>

  <div class="my-2.5 border-t border-border/60"></div>

  <!-- 2. Calendar Range Selector -->
  <div class="select-none">
    <div class="mb-2 flex items-center justify-between gap-1">
      <button
        type="button"
        onclick={() => shiftMonth(-1)}
        title={tp.prevMonth}
        aria-label={tp.prevMonth}
        class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
      >
        <ChevronLeft class="h-3.5 w-3.5" />
      </button>

      <div class="flex items-center gap-2 min-w-0">
        <span class="font-mono text-xs font-medium tabular-nums text-foreground">
          {monthLabel}
        </span>
        <button
          type="button"
          onclick={jumpToToday}
          class="rounded px-1.5 py-0.5 text-[11px] text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
        >
          {tp.jumpToday}
        </button>
        {#if pickingPhase === 'end'}
          <span class="truncate text-[11px] text-primary">{tp.hintPickEnd}</span>
        {/if}
      </div>

      <button
        type="button"
        onclick={() => shiftMonth(1)}
        title={tp.nextMonth}
        aria-label={tp.nextMonth}
        class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
      >
        <ChevronRight class="h-3.5 w-3.5" />
      </button>
    </div>

    <div class="grid grid-cols-7 text-center text-[11px] text-muted-foreground/70 mb-1">
      {#each tp.weekdays as wd}
        <span class="py-0.5">{wd}</span>
      {/each}
    </div>

    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div
      class="grid grid-cols-7 gap-y-0.5"
      onmouseleave={() => {
        hoverDate = null;
      }}
    >
      {#each calendarCells as cell (cell.ymd)}
        {@const isStart = Boolean(effectiveRange.lo && cell.ymd === effectiveRange.lo)}
        {@const isEnd = Boolean(effectiveRange.hi && cell.ymd === effectiveRange.hi)}
        {@const isSingle = isStart && isEnd}
        {@const inRange = Boolean(
          effectiveRange.lo &&
            effectiveRange.hi &&
            cell.ymd > effectiveRange.lo &&
            cell.ymd < effectiveRange.hi
        )}
        <button
          type="button"
          onclick={() => handleDayClick(cell.ymd, cell.inMonth)}
          onmouseenter={() => {
            if (pickingPhase === 'end') hoverDate = cell.ymd;
          }}
          class={`touch-target relative flex h-8 items-center justify-center font-mono text-[12px] tabular-nums transition-colors cursor-pointer ${
            isStart || isEnd
              ? isSingle
                ? 'rounded-md bg-primary text-primary-foreground font-semibold'
                : isStart
                  ? 'rounded-l-md bg-primary text-primary-foreground font-semibold'
                  : 'rounded-r-md bg-primary text-primary-foreground font-semibold'
              : inRange
                ? 'bg-primary/15 text-foreground hover:bg-primary/25'
                : cell.inMonth
                  ? 'rounded-md text-foreground hover:bg-secondary/70'
                  : 'rounded-md text-muted-foreground/70 opacity-60 hover:bg-secondary/50'
          }`}
        >
          <span>{cell.day}</span>
          {#if cell.isToday && !isStart && !isEnd}
            <span class="absolute bottom-1 left-1/2 h-1 w-1 -translate-x-1/2 rounded-full bg-primary"></span>
          {/if}
        </button>
      {/each}
    </div>
  </div>

  <div class="my-2.5 border-t border-border/60"></div>

  <!-- 3. Precision Start / End Date + Time Inputs (Paste ISO / Unix Supported) -->
  <div class="space-y-1.5">
    <div class="flex items-center gap-1.5">
      <span class="w-8 shrink-0 text-[11.5px] text-muted-foreground">{tp.startLabel}</span>
      <input
        type="text"
        bind:value={startDate}
        oninput={() => (validationError = null)}
        onpaste={(e) => handlePaste('start', e)}
        onkeydown={handleInputKeydown}
        placeholder={tp.datePlaceholder}
        aria-label={`${tp.startLabel} ${tp.datePlaceholder}`}
        class="h-7 min-w-0 flex-1 rounded-md border border-border/70 bg-background px-2 font-mono text-xs tabular-nums text-foreground placeholder:text-muted-foreground/70 focus:border-primary/60 focus:outline-none [@media(any-pointer:coarse)]:text-[16px]"
      />
      <input
        type="text"
        bind:value={startTime}
        oninput={() => (validationError = null)}
        onpaste={(e) => handlePaste('start', e)}
        onkeydown={handleInputKeydown}
        placeholder={tp.startTimePlaceholder}
        aria-label={`${tp.startLabel} ${tp.startTimePlaceholder}`}
        class="h-7 w-[86px] shrink-0 rounded-md border border-border/70 bg-background px-2 font-mono text-xs tabular-nums text-foreground placeholder:text-muted-foreground/70 focus:border-primary/60 focus:outline-none [@media(any-pointer:coarse)]:text-[16px]"
      />
      <button
        type="button"
        onclick={clearStart}
        disabled={!startDate && !startTime}
        title={tp.clearField}
        aria-label={tp.clearField}
        class="touch-target flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-secondary hover:text-foreground disabled:opacity-30 disabled:pointer-events-none transition-colors cursor-pointer"
      >
        <X class="h-3 w-3" />
      </button>
    </div>

    <div class="flex items-center gap-1.5">
      <span class="w-8 shrink-0 text-[11.5px] text-muted-foreground">{tp.endLabel}</span>
      <input
        type="text"
        bind:value={endDate}
        oninput={() => (validationError = null)}
        onpaste={(e) => handlePaste('end', e)}
        onkeydown={handleInputKeydown}
        placeholder={tp.endDatePlaceholder}
        aria-label={`${tp.endLabel} ${tp.endDatePlaceholder}`}
        class="h-7 min-w-0 flex-1 rounded-md border border-border/70 bg-background px-2 font-mono text-xs tabular-nums text-foreground placeholder:text-muted-foreground/70 focus:border-primary/60 focus:outline-none [@media(any-pointer:coarse)]:text-[16px]"
      />
      <input
        type="text"
        bind:value={endTime}
        oninput={() => (validationError = null)}
        onpaste={(e) => handlePaste('end', e)}
        onkeydown={handleInputKeydown}
        placeholder={endDate ? tp.endTimePlaceholder : tp.nowBtn}
        aria-label={`${tp.endLabel} ${tp.endTimePlaceholder}`}
        class="h-7 w-[86px] shrink-0 rounded-md border border-border/70 bg-background px-2 font-mono text-xs tabular-nums text-foreground placeholder:text-muted-foreground/70 focus:border-primary/60 focus:outline-none [@media(any-pointer:coarse)]:text-[16px]"
      />
      <button
        type="button"
        onclick={setEndNow}
        title={tp.nowTitle}
        class={`touch-target h-7 w-7 shrink-0 rounded-md text-[11px] transition-colors cursor-pointer flex items-center justify-center ${
          !endDate && !endTime
            ? 'bg-secondary text-foreground font-medium'
            : 'text-muted-foreground hover:bg-secondary hover:text-foreground'
        }`}
      >
        {tp.nowBtn}
      </button>
    </div>
  </div>

  <!-- 4. Preview & Action Footer -->
  <div class="sticky -bottom-3 -mx-3 -mb-3 mt-2.5 flex items-center justify-between gap-2 border-t border-border/60 bg-card px-3 pb-3 pt-2">
    <div class="min-w-0 flex-1">
      {#if validationError === 'invalid_start'}
        <span class="block truncate text-[11px] text-status">{tp.invalidStart}</span>
      {:else if validationError === 'invalid_end'}
        <span class="block truncate text-[11px] text-status">{tp.invalidEnd}</span>
      {:else if previewLabel}
        <span class="block truncate font-mono text-[11px] tabular-nums text-muted-foreground">
          {previewLabel}
        </span>
      {/if}
    </div>

    <div class="flex shrink-0 items-center gap-1.5">
      <button
        type="button"
        onclick={() => onApply('')}
        title={tp.reset}
        class="touch-target inline-flex h-7 items-center gap-1 rounded-md px-2 text-xs text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
      >
        <RotateCcw class="h-3 w-3" />
        <span>{tp.reset}</span>
      </button>
      <button
        type="button"
        onclick={submitCustomRange}
        disabled={compiledPreview.error !== null && compiledPreview.error !== 'empty'}
        class="touch-target inline-flex h-7 items-center rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:opacity-90 disabled:opacity-40 transition-opacity cursor-pointer"
      >
        {tp.apply}
      </button>
    </div>
  </div>
{/snippet}

{#if workbench.isCompact}
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="fixed inset-0 z-40 bg-background/60 backdrop-blur-[1px]"
    onclick={onClose}
  ></div>
  <div
    bind:this={panelEl}
    role="dialog"
    aria-label={s.anyTime}
    class="pb-safe fixed inset-x-3 bottom-3 z-50 mx-auto max-h-[85vh] max-w-[368px] overflow-y-auto rounded-2xl border border-border bg-card p-3 shadow-2xl"
  >
    {@render pickerContent()}
  </div>
{:else}
  <div
    bind:this={panelEl}
    role="dialog"
    aria-label={s.anyTime}
    style={`${offsetX !== 0 ? `transform: translateX(${offsetX}px);` : ''}${maxPanelH !== null ? ` max-height: ${maxPanelH}px;` : ''}`}
    class="absolute left-0 top-full z-50 mt-1.5 max-h-[calc(100vh-6rem)] w-[328px] max-w-[calc(100vw-1.5rem)] overflow-y-auto overscroll-contain rounded-2xl border border-border bg-card p-3 shadow-2xl"
  >
    {@render pickerContent()}
  </div>
{/if}
