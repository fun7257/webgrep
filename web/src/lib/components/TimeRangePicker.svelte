<script lang="ts">
  import { untrack } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import type { TimePreset } from '$lib/types';
  import { splitHighlightRanges, type HighlightRange } from '$lib/source-picker';
  import {
    DATETIME_SLOTS,
    FLAT_QUICK_TIME_PRESETS,
    QUICK_TIME_PRESET_GROUPS,
    buildSpecFromDateTimeParts,
    clampDateTimeParts,
    dateToParts,
    extractPastedDateTime,
    extractedToDateTimeParts,
    formatTimeScopeLabel,
    isBuiltinTimePreset,
    matchQuickTimeCandidates,
    resolveSyncedDateTimeParts,
    stepDateTimeSlot,
    type DateTimeParts,
    type DateTimeSlot,
  } from '$lib/time-range';
  import { Check, Clock, FileClock, Search, SlidersHorizontal, Timer, X } from 'lucide-svelte';

  interface Props {
    value: TimePreset;
    onApply: (spec: TimePreset) => void;
    onClose: () => void;
    onFocusMainInput?: () => void;
  }

  type BoundSide = 'start' | 'end';

  let { value, onApply, onClose, onFocusMainInput }: Props = $props();

  const initialSynced = untrack(() => resolveSyncedDateTimeParts(value));
  const initialFocusIdx = untrack(() => {
    if (value === '') return -1;
    const idx = FLAT_QUICK_TIME_PRESETS.indexOf(value);
    return idx >= 0 ? idx : -2;
  });

  let quickQuery = $state<string>('');
  let focusedIdx = $state<number>(initialFocusIdx);

  let startParts = $state<DateTimeParts>({ ...initialSynced.start });
  let endParts = $state<DateTimeParts>({ ...initialSynced.end });
  let endIsNow = $state<boolean>(initialSynced.endIsNow);
  let customDirty = $state<boolean>(false);
  let hoverPreset = $state<TimePreset | null>(null);

  let focusedKey = $state<string | null>(null);
  let rawEditText = $state<string>('');
  let justFocusedKey: string | null = null;
  const slotEls: Record<string, HTMLInputElement | null> = {};

  let panelEl = $state<HTMLDivElement | null>(null);
  let quickInputEl = $state<HTMLInputElement | null>(null);
  let listEl = $state<HTMLDivElement | null>(null);
  let offsetX = $state<number>(0);
  let maxPanelH = $state<number | null>(null);
  let nowToggledOnDown = false;

  // Mobile bottom sheet drag-to-dismiss state
  let dragY = $state<number>(0);
  let dragStart: number | null = null;

  const s = $derived(workbench.t.scopeBar);
  const tp = $derived(s.timePicker);
  const basis = $derived(workbench.getEffectiveTimeBasisSummary());
  const hasQuickQuery = $derived(quickQuery.trim().length > 0);
  const quickCandidates = $derived(
    hasQuickQuery ? matchQuickTimeCandidates(quickQuery, s.timeLabels, s.timeShortLabels) : []
  );

  const basisShortLabel = $derived(
    basis.contentCount === 0
      ? tp.basisShortMtime
      : basis.mtimeCount === 0
        ? tp.basisShortContent(basis.contentCount)
        : tp.basisShortMixed(basis.contentCount, basis.mtimeCount)
  );

  const basisFullTitle = $derived(
    `${
      basis.contentCount === 0
        ? tp.basisMtimeOnly
        : basis.mtimeCount === 0
          ? tp.basisContentOnly(basis.contentCount)
          : tp.basisMixed(basis.contentCount, basis.mtimeCount)
    } · ${tp.configureSourceTime}`
  );

  const activeCandidateSpec = $derived.by((): TimePreset | null => {
    if (customDirty) return null;
    if (hoverPreset !== null) return hoverPreset;
    if (hasQuickQuery) {
      return quickCandidates[focusedIdx]?.spec ?? null;
    }
    if (focusedIdx === -1) return '';
    if (focusedIdx >= 0 && focusedIdx < FLAT_QUICK_TIME_PRESETS.length) {
      return FLAT_QUICK_TIME_PRESETS[focusedIdx];
    }
    return null;
  });

  const previewSynced = $derived(
    !customDirty && activeCandidateSpec !== null
      ? resolveSyncedDateTimeParts(activeCandidateSpec)
      : null
  );

  const displayedStart = $derived(previewSynced ? previewSynced.start : startParts);
  const displayedEnd = $derived(previewSynced ? previewSynced.end : endParts);
  const effectiveEndIsNow = $derived(previewSynced ? previewSynced.endIsNow : endIsNow);

  const compiledSpec = $derived(
    buildSpecFromDateTimeParts(displayedStart, displayedEnd, effectiveEndIsNow)
  );

  const hasCustomSpecBadge = $derived(
    !customDirty && value !== '' && !isBuiltinTimePreset(value) && !hasQuickQuery
  );

  const footerPreviewLabel = $derived.by(() => {
    if (activeCandidateSpec !== null && !customDirty) {
      return activeCandidateSpec === '' ? '' : formatTimeScopeLabel(activeCandidateSpec, s.timeLabels);
    }
    if (!customDirty && value === '') {
      return '';
    }
    if (!customDirty && value !== '') {
      return formatTimeScopeLabel(value, s.timeLabels);
    }
    return formatTimeScopeLabel(compiledSpec, s.timeLabels);
  });

  // Initial focus: desktop gets immediate autofocus on the top quick-expression bar
  $effect(() => {
    queueMicrotask(() => {
      if (!workbench.timePickerOpen) return;
      if (!workbench.isCompact && !workbench.isTouch) {
        quickInputEl?.focus({ preventScroll: true });
      } else {
        panelEl?.focus({ preventScroll: true });
      }
    });
  });

  // Keep keyboard index clamped within filtered candidates when typing
  $effect(() => {
    if (!hasQuickQuery) return;
    if (quickCandidates.length === 0) {
      focusedIdx = -1;
    } else if (focusedIdx < 0 || focusedIdx >= quickCandidates.length) {
      focusedIdx = 0;
    }
  });

  // Clamp horizontal/vertical viewport bounds cleanly once mounted
  $effect(() => {
    if (workbench.isCompact) {
      offsetX = 0;
      maxPanelH = null;
      return;
    }
    const el = panelEl;
    if (!el) return;
    const prevOffset = untrack(() => offsetX);
    const rect = el.getBoundingClientRect();
    const nextMaxPanelH = Math.max(240, Math.floor(window.innerHeight - rect.top - 12));
    const container = (el.closest('main') as HTMLElement | null)?.getBoundingClientRect();
    const minLeft = Math.max(8, container?.left ?? 8);
    const maxRight = Math.min(window.innerWidth - 8, container?.right ?? window.innerWidth - 8);
    const baseLeft = rect.left - prevOffset;
    const baseRight = rect.right - prevOffset;
    let nextOffset = 0;
    if (baseRight > maxRight) {
      nextOffset = Math.max(minLeft - baseLeft, maxRight - baseRight);
    } else if (baseLeft < minLeft) {
      nextOffset = minLeft - baseLeft;
    }
    maxPanelH = nextMaxPanelH;
    offsetX = nextOffset;
  });

  function scrollCandidateIntoView(idx: number) {
    queueMicrotask(() => {
      const target = listEl?.querySelector(`[data-time-idx="${idx}"]`) as HTMLElement | null;
      target?.scrollIntoView({ block: 'nearest' });
    });
  }

  function slotKey(bound: BoundSide, slot: DateTimeSlot): string {
    return `${bound}:${slot}`;
  }

  function registerSlot(node: HTMLInputElement, key: string) {
    slotEls[key] = node;
    return {
      destroy() {
        if (slotEls[key] === node) {
          delete slotEls[key];
        }
      },
    };
  }

  function getParts(bound: BoundSide): DateTimeParts {
    return bound === 'start' ? startParts : endParts;
  }

  function setParts(bound: BoundSide, next: DateTimeParts) {
    if (bound === 'start') {
      startParts = next;
    } else {
      endParts = next;
    }
  }

  function getSlotDisplayValue(bound: BoundSide, slot: DateTimeSlot): string {
    const key = slotKey(bound, slot);
    if (focusedKey === key) return rawEditText;
    return (bound === 'start' ? displayedStart : displayedEnd)[slot];
  }

  function focusSlot(bound: BoundSide, slot: DateTimeSlot) {
    const el = slotEls[slotKey(bound, slot)];
    if (!el) return;
    el.focus();
    queueMicrotask(() => el.select());
  }

  function moveSlot(bound: BoundSide, slot: DateTimeSlot, dir: -1 | 1) {
    const idx = DATETIME_SLOTS.indexOf(slot);
    const nextIdx = idx + dir;
    if (nextIdx >= 0 && nextIdx < DATETIME_SLOTS.length) {
      focusSlot(bound, DATETIME_SLOTS[nextIdx]);
      return;
    }
    if (dir > 0 && bound === 'start') {
      focusSlot('end', DATETIME_SLOTS[0]);
    } else if (dir < 0 && bound === 'end') {
      focusSlot('start', DATETIME_SLOTS[DATETIME_SLOTS.length - 1]);
    }
  }

  function shouldAutoAdvance(slot: DateTimeSlot, digits: string): boolean {
    if (slot === 'year') return digits.length >= 4;
    if (digits.length >= 2) return true;
    if (digits.length !== 1) return false;
    const n = Number(digits);
    switch (slot) {
      case 'month':
        return n >= 2;
      case 'day':
        return n >= 4;
      case 'hour':
        return n >= 3;
      case 'minute':
      case 'second':
        return n >= 6;
    }
  }

  function commitRawSlot(bound: BoundSide, slot: DateTimeSlot, digits: string): DateTimeParts {
    const cur = getParts(bound);
    const merged: DateTimeParts = {
      ...cur,
      [slot]: digits.length > 0 ? digits : cur[slot],
    };
    const clamped = clampDateTimeParts(merged);
    setParts(bound, clamped);
    return clamped;
  }

  function selectPreset(preset: TimePreset) {
    const synced = resolveSyncedDateTimeParts(preset);
    startParts = { ...synced.start };
    endParts = { ...synced.end };
    endIsNow = synced.endIsNow;
    customDirty = false;
    hoverPreset = null;
    onApply(preset);
    if (!workbench.isCompact && !workbench.isTouch) {
      onFocusMainInput?.();
    }
  }

  function toggleEndNow() {
    if (previewSynced && !customDirty) {
      startParts = { ...previewSynced.start };
    }
    hoverPreset = null;
    customDirty = true;
    const nowParts = dateToParts(new Date());
    endParts = nowParts;
    endIsNow = !endIsNow;
  }

  function handleSlotFocus(bound: BoundSide, slot: DateTimeSlot, e: FocusEvent) {
    if (previewSynced && !customDirty) {
      startParts = { ...previewSynced.start };
      endParts = { ...previewSynced.end };
      endIsNow = previewSynced.endIsNow;
    }
    const key = slotKey(bound, slot);
    focusedKey = key;
    justFocusedKey = key;
    hoverPreset = null;
    rawEditText = getParts(bound)[slot];
    const el = e.currentTarget as HTMLInputElement;
    queueMicrotask(() => {
      if (document.activeElement === el) {
        el.select();
      }
    });
  }

  function handleSlotMouseUp(bound: BoundSide, slot: DateTimeSlot, e: MouseEvent) {
    const key = slotKey(bound, slot);
    if (justFocusedKey === key) {
      e.preventDefault();
      justFocusedKey = null;
    }
  }

  function handleSlotBlur(bound: BoundSide, slot: DateTimeSlot) {
    const key = slotKey(bound, slot);
    if (justFocusedKey === key) justFocusedKey = null;
    if (focusedKey !== key) return;
    commitRawSlot(bound, slot, rawEditText.replace(/\D/g, ''));
    focusedKey = null;
  }

  function handleSlotInput(bound: BoundSide, slot: DateTimeSlot, e: Event) {
    const el = e.currentTarget as HTMLInputElement;
    const maxLen = slot === 'year' ? 4 : 2;
    const digits = el.value.replace(/\D/g, '').slice(0, maxLen);
    if (el.value !== digits) {
      el.value = digits;
    }
    rawEditText = digits;
    customDirty = true;
    if (bound === 'end') {
      endIsNow = false;
    }

    if (shouldAutoAdvance(slot, digits)) {
      const clamped = commitRawSlot(bound, slot, digits);
      rawEditText = clamped[slot];
      const idx = DATETIME_SLOTS.indexOf(slot);
      if (idx < DATETIME_SLOTS.length - 1) {
        focusSlot(bound, DATETIME_SLOTS[idx + 1]);
      } else {
        queueMicrotask(() => {
          if (document.activeElement === el) el.select();
        });
      }
    }
  }

  function handleSlotKeydown(bound: BoundSide, slot: DateTimeSlot, e: KeyboardEvent) {
    const el = e.currentTarget as HTMLInputElement;

    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      submitCustomRange();
      return;
    }

    if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      e.preventDefault();
      e.stopPropagation();
      const base = commitRawSlot(bound, slot, rawEditText.replace(/\D/g, ''));
      const stepMag = e.shiftKey && (slot === 'minute' || slot === 'second') ? 5 : 1;
      const next = stepDateTimeSlot(base, slot, e.key === 'ArrowUp' ? stepMag : -stepMag);
      setParts(bound, next);
      rawEditText = next[slot];
      customDirty = true;
      if (bound === 'end') {
        endIsNow = false;
      }
      queueMicrotask(() => el.select());
      return;
    }

    const selStart = el.selectionStart ?? 0;
    const selEnd = el.selectionEnd ?? 0;
    const selAll = selStart === 0 && selEnd === el.value.length && el.value.length > 0;

    if (e.key === 'ArrowLeft') {
      e.stopPropagation();
      if (selAll || selStart === 0) {
        e.preventDefault();
        moveSlot(bound, slot, -1);
      }
      return;
    }

    if (e.key === 'ArrowRight') {
      e.stopPropagation();
      if (selAll || selEnd === el.value.length) {
        e.preventDefault();
        moveSlot(bound, slot, 1);
      }
      return;
    }

    if (e.key === '-' || e.key === '/' || e.key === ':' || e.key === ' ') {
      e.preventDefault();
      e.stopPropagation();
      const idx = DATETIME_SLOTS.indexOf(slot);
      if (idx < DATETIME_SLOTS.length - 1) {
        focusSlot(bound, DATETIME_SLOTS[idx + 1]);
      }
      return;
    }

    if (e.key === 'Backspace') {
      e.stopPropagation();
      if (el.value.length === 0 || (selStart === 0 && selEnd === 0)) {
        e.preventDefault();
        moveSlot(bound, slot, -1);
      }
    }
  }

  function handleSlotPaste(bound: BoundSide, slot: DateTimeSlot, e: ClipboardEvent) {
    const raw = (e.clipboardData?.getData('text') ?? '').trim();
    if (!raw) return;

    const maxLen = slot === 'year' ? 4 : 2;
    if (/^\d+$/.test(raw) && raw.length <= maxLen) {
      return;
    }

    const rangeSep = raw.includes('..') ? '..' : raw.includes(' ~ ') ? ' ~ ' : null;
    if (rangeSep) {
      const [leftRaw, rightRaw] = raw.split(rangeSep, 2);
      const nowMs = Date.now();
      const leftParsed = leftRaw.trim() ? extractPastedDateTime(leftRaw, nowMs, false) : null;
      const rightParsed = rightRaw.trim() ? extractPastedDateTime(rightRaw, nowMs, true) : null;
      if (leftParsed || rightParsed) {
        e.preventDefault();
        if (leftParsed) {
          startParts = extractedToDateTimeParts(leftParsed, false);
        }
        if (rightParsed) {
          endParts = extractedToDateTimeParts(rightParsed, true);
          endIsNow = false;
        } else if (!rightRaw.trim()) {
          endParts = dateToParts(new Date(nowMs));
          endIsNow = true;
        }
        customDirty = true;
        rawEditText = getParts(bound)[slot];
        return;
      }
    }

    const parsed = extractPastedDateTime(raw, Date.now(), bound === 'end');
    if (!parsed) return;
    e.preventDefault();
    const nextParts = extractedToDateTimeParts(parsed, bound === 'end');
    setParts(bound, nextParts);
    customDirty = true;
    if (bound === 'end') {
      endIsNow = false;
    }
    rawEditText = nextParts[slot];
  }

  function submitCustomRange() {
    if (focusedKey) {
      const [b, sSlot] = focusedKey.split(':') as [BoundSide, DateTimeSlot];
      const clamped = commitRawSlot(b, sSlot, rawEditText.replace(/\D/g, ''));
      rawEditText = clamped[sSlot];
    }

    if (!customDirty && previewSynced && activeCandidateSpec !== null) {
      selectPreset(activeCandidateSpec);
      return;
    }

    if (!customDirty && value !== '') {
      onApply(value);
      if (!workbench.isCompact && !workbench.isTouch) {
        onFocusMainInput?.();
      }
      return;
    }

    const normStart = clampDateTimeParts(startParts);
    startParts = normStart;
    if (!endIsNow) {
      endParts = clampDateTimeParts(endParts);
    }
    onApply(buildSpecFromDateTimeParts(normStart, endParts, endIsNow));
    if (!workbench.isCompact && !workbench.isTouch) {
      onFocusMainInput?.();
    }
  }

  function handlePanelKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      onClose();
      if (!workbench.isCompact && !workbench.isTouch) {
        onFocusMainInput?.();
      }
      return;
    }

    if (e.key === 'Tab' && !e.shiftKey && (e.target === quickInputEl || e.target === panelEl)) {
      e.preventDefault();
      e.stopPropagation();
      onClose();
      onFocusMainInput?.();
      return;
    }

    if (focusedKey !== null) return;

    if (hasQuickQuery) {
      const count = quickCandidates.length;
      if (e.key === 'ArrowDown') {
        if (count === 0) return;
        e.preventDefault();
        customDirty = false;
        hoverPreset = null;
        focusedIdx = focusedIdx < count - 1 ? focusedIdx + 1 : 0;
        scrollCandidateIntoView(focusedIdx);
        return;
      }
      if (e.key === 'ArrowUp') {
        if (count === 0) return;
        e.preventDefault();
        customDirty = false;
        hoverPreset = null;
        focusedIdx = focusedIdx > 0 ? focusedIdx - 1 : count - 1;
        scrollCandidateIntoView(focusedIdx);
        return;
      }
      if (e.key === 'Enter') {
        e.preventDefault();
        e.stopPropagation();
        const target = quickCandidates[focusedIdx] ?? quickCandidates[0];
        if (target) {
          selectPreset(target.spec);
        } else if (customDirty) {
          submitCustomRange();
        }
        return;
      }
      return;
    }

    const maxPresetIdx = FLAT_QUICK_TIME_PRESETS.length - 1;
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      customDirty = false;
      hoverPreset = null;
      focusedIdx = focusedIdx < maxPresetIdx && focusedIdx >= -1 ? focusedIdx + 1 : -1;
      return;
    }
    if (e.key === 'ArrowUp') {
      e.preventDefault();
      customDirty = false;
      hoverPreset = null;
      focusedIdx = focusedIdx > -1 ? focusedIdx - 1 : maxPresetIdx;
      return;
    }
    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      if (!customDirty && focusedIdx === -1) {
        selectPreset('');
        return;
      }
      if (!customDirty && focusedIdx >= 0 && focusedIdx < FLAT_QUICK_TIME_PRESETS.length) {
        selectPreset(FLAT_QUICK_TIME_PRESETS[focusedIdx]);
        return;
      }
      submitCustomRange();
    }
  }

  function onHandleDown(e: PointerEvent) {
    dragStart = e.clientY;
    dragY = 0;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }

  function onHandleMove(e: PointerEvent) {
    if (dragStart === null) return;
    dragY = Math.max(0, e.clientY - dragStart);
  }

  function onHandleUp() {
    if (dragStart === null) return;
    const shouldClose = dragY > 80;
    dragStart = null;
    dragY = 0;
    if (shouldClose) onClose();
  }

  const slotInputCls =
    'relative z-10 h-6 [@media(any-pointer:coarse)]:h-7 rounded bg-secondary/55 px-0.5 text-center font-mono text-xs tabular-nums hover:bg-secondary focus:bg-primary/20 focus:text-primary focus:ring-1 focus:ring-inset focus:ring-primary/45 focus:outline-none';
</script>

{#snippet renderHighlighted(text: string, ranges: readonly HighlightRange[])}
  {#each splitHighlightRanges(text, ranges) as piece, i (i)}
    {#if piece.match}
      <span class="font-semibold text-primary">{piece.text}</span>
    {:else}
      {piece.text}
    {/if}
  {/each}
{/snippet}

{#snippet renderSlotInput(
  bound: BoundSide,
  slot: DateTimeSlot,
  widthCls: string,
  ariaUnit: string,
  muted: boolean
)}
  {@const key = slotKey(bound, slot)}
  {@const rowLabel = bound === 'start' ? tp.startLabel : tp.endLabel}
  <input
    use:registerSlot={key}
    type="text"
    inputmode="numeric"
    autocomplete="off"
    spellcheck="false"
    value={getSlotDisplayValue(bound, slot)}
    onfocus={(e) => handleSlotFocus(bound, slot, e)}
    onmouseup={(e) => handleSlotMouseUp(bound, slot, e)}
    onblur={() => handleSlotBlur(bound, slot)}
    oninput={(e) => handleSlotInput(bound, slot, e)}
    onkeydown={(e) => handleSlotKeydown(bound, slot, e)}
    onpaste={(e) => handleSlotPaste(bound, slot, e)}
    aria-label={`${rowLabel} ${ariaUnit}`}
    class={`${slotInputCls} ${widthCls} ${muted ? 'text-muted-foreground' : 'text-foreground'}`}
  />
{/snippet}

{#snippet renderBoundRow(bound: BoundSide)}
  {@const isEnd = bound === 'end'}
  {@const mutedDigits = isEnd && effectiveEndIsNow}
  <div class="grid grid-cols-[auto_1fr] items-center gap-2">
    <span class="text-[11.5px] text-muted-foreground select-none">
      {isEnd ? tp.endLabel : tp.startLabel}
    </span>
    <div class="flex h-9 [@media(any-pointer:coarse)]:h-10 min-w-0 items-center rounded-lg border border-border/75 bg-background/85 px-2 focus-within:border-primary/60">
      <div class="flex items-center">
        {@render renderSlotInput(bound, 'year', 'w-[42px] [@media(any-pointer:coarse)]:w-[48px]', tp.yearLabel, mutedDigits)}
        <span class="px-0.5 text-[11px] text-muted-foreground/65 select-none">{tp.yearUnit}</span>
        {@render renderSlotInput(bound, 'month', 'w-[26px] [@media(any-pointer:coarse)]:w-[30px]', tp.monthLabel, mutedDigits)}
        <span class="px-0.5 text-[11px] text-muted-foreground/65 select-none">{tp.monthUnit}</span>
        {@render renderSlotInput(bound, 'day', 'w-[26px] [@media(any-pointer:coarse)]:w-[30px]', tp.dayLabel, mutedDigits)}
        {#if tp.dayUnit}
          <span class="pl-0.5 text-[11px] text-muted-foreground/65 select-none">{tp.dayUnit}</span>
        {/if}
      </div>

      <span class="mx-1.5 h-3.5 w-px shrink-0 bg-border/60"></span>

      <div class="flex items-center">
        {@render renderSlotInput(bound, 'hour', 'w-[26px] [@media(any-pointer:coarse)]:w-[30px]', tp.hourLabel, mutedDigits)}
        <span class="px-[1px] font-mono text-[11px] text-muted-foreground/65 select-none">:</span>
        {@render renderSlotInput(bound, 'minute', 'w-[26px] [@media(any-pointer:coarse)]:w-[30px]', tp.minuteLabel, mutedDigits)}
        <span class="px-[1px] font-mono text-[11px] text-muted-foreground/65 select-none">:</span>
        {@render renderSlotInput(bound, 'second', 'w-[26px] [@media(any-pointer:coarse)]:w-[30px]', tp.secondLabel, mutedDigits)}
      </div>

      {#if isEnd}
        <button
          type="button"
          onpointerdown={(e) => {
            if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
              nowToggledOnDown = true;
              toggleEndNow();
            }
          }}
          onclick={(e) => {
            if (nowToggledOnDown && e.detail > 0) {
              nowToggledOnDown = false;
              return;
            }
            nowToggledOnDown = false;
            toggleEndNow();
          }}
          title={tp.nowTitle}
          class={`touch-target ml-auto inline-flex h-6 shrink-0 items-center rounded-md px-1.5 text-[11px] cursor-pointer ${
            effectiveEndIsNow
              ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/30 font-medium'
              : 'text-muted-foreground/80 hover:bg-secondary hover:text-foreground active:bg-secondary'
          }`}
        >
          {tp.nowBtn}
        </button>
      {/if}
    </div>
  </div>
{/snippet}

{#snippet pickerContent()}
  <!-- 1. Top Quick-Search / Shorthand / Timestamp-Paste Bar -->
  <div class="flex h-10 shrink-0 items-center gap-2 border-b border-border/55 px-3">
    <Search class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
    <input
      bind:this={quickInputEl}
      type="text"
      bind:value={quickQuery}
      oninput={() => {
        customDirty = false;
        hoverPreset = null;
        focusedIdx = 0;
      }}
      placeholder={s.timeSearchPlaceholder}
      spellcheck="false"
      autocomplete="off"
      class="h-full min-w-0 flex-1 bg-transparent text-[13px] [@media(any-pointer:coarse)]:text-[16px] text-foreground placeholder:text-muted-foreground/60 focus:outline-none"
    />

    {#if quickQuery.length > 0}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => {
          quickQuery = '';
          customDirty = false;
          focusedIdx = value === '' ? -1 : FLAT_QUICK_TIME_PRESETS.indexOf(value);
          quickInputEl?.focus();
        }}
        title={workbench.t.searchBar.clearDraftTitle}
        aria-label={workbench.t.searchBar.clearDraftTitle}
        class="touch-target flex h-6 w-6 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
      >
        <X class="h-3.5 w-3.5" />
      </button>
    {:else if value !== '' || customDirty}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => selectPreset('')}
        class="touch-target inline-flex h-6 shrink-0 items-center rounded-md px-2 text-[11px] font-medium text-muted-foreground hover:bg-secondary hover:text-foreground active:bg-secondary/80 cursor-pointer"
      >
        {tp.reset}
      </button>
    {/if}
  </div>

  <!-- 2. Body: Filtered Quick Candidates OR Structured 3x4 Matrix + Pre-filled Synced Slots -->
  <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain p-2.5 space-y-2.5">
    {#if hasQuickQuery}
      <div
        bind:this={listEl}
        role="listbox"
        aria-label={s.timePickerTitle}
        class="max-h-[184px] overflow-y-auto overscroll-contain space-y-0.5"
      >
        {#if quickCandidates.length === 0}
          <div class="px-3 py-5 text-center text-xs text-muted-foreground">
            {s.timeNoMatch}
          </div>
        {:else}
          {#each quickCandidates as cand, idx (cand.key)}
            {@const checked = !customDirty && value === cand.spec}
            {@const isFocused = focusedIdx === idx}
            <button
              type="button"
              role="option"
              data-time-idx={idx}
              aria-selected={checked}
              onmousedown={(e) => e.preventDefault()}
              onmouseenter={() => {
                focusedIdx = idx;
                hoverPreset = cand.spec;
              }}
              onmouseleave={() => {
                if (hoverPreset === cand.spec) hoverPreset = null;
              }}
              onclick={() => selectPreset(cand.spec)}
              class={`touch-target flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left cursor-pointer ${
                checked
                  ? 'bg-primary/[0.08] hover:bg-primary/[0.12]'
                  : isFocused
                    ? 'bg-secondary/80'
                    : 'hover:bg-secondary/55'
              } ${isFocused && checked ? 'ring-1 ring-inset ring-primary/35' : ''}`}
            >
              <span
                aria-hidden="true"
                class={`flex h-4 w-4 shrink-0 items-center justify-center rounded-[4px] border ${
                  checked
                    ? 'border-primary bg-primary text-primary-foreground'
                    : 'border-border bg-background/80'
                }`}
              >
                {#if checked}
                  <Check class="h-3 w-3 stroke-[2.75]" />
                {/if}
              </span>

              {#if cand.isCustom}
                <Timer class="h-3.5 w-3.5 shrink-0 text-primary" />
              {:else}
                <Clock
                  class={`h-3.5 w-3.5 shrink-0 ${
                    checked ? 'text-primary' : 'text-muted-foreground'
                  }`}
                />
              {/if}

              <span class="min-w-0 flex-1 truncate text-[12.5px] font-medium text-foreground">
                {@render renderHighlighted(cand.fullLabel, cand.fullRanges)}
              </span>

              <span class="shrink-0 rounded bg-secondary/75 px-1.5 py-0.5 font-mono text-[11px] tabular-nums text-muted-foreground">
                {@render renderHighlighted(cand.shortLabel, cand.shortRanges)}
              </span>

              {#if isFocused && !workbench.isCompact}
                <span class="shrink-0 text-[10px] text-primary/80 font-medium">
                  {s.timeQuickApplyBadge}
                </span>
              {/if}
            </button>
          {/each}
        {/if}
      </div>
    {:else}
      <!-- Pinned Any Time Option + Active Source Time Basis Badge -->
      {@const anyActive = !customDirty && value === ''}
      {@const anyFocused = !customDirty && focusedIdx === -1}
      <div class="flex items-center justify-between gap-2">
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onmouseenter={() => {
            if (!customDirty && !workbench.isTouch) hoverPreset = '';
          }}
          onmouseleave={() => {
            if (hoverPreset === '') hoverPreset = null;
          }}
          onclick={() => selectPreset('')}
          title={s.timeLabels['']}
          class={`touch-target inline-flex h-7 items-center gap-1.5 rounded-lg px-2 text-xs cursor-pointer active:bg-primary/20 ${
            anyActive
              ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-medium'
              : anyFocused
                ? 'bg-secondary/80 text-foreground ring-1 ring-inset ring-border'
                : 'bg-secondary/45 text-foreground/85 hover:bg-secondary/80 hover:text-foreground'
          }`}
        >
          <span
            aria-hidden="true"
            class={`flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded-[3px] border ${
              anyActive
                ? 'border-primary bg-primary text-primary-foreground'
                : 'border-border/80 bg-background/75'
            }`}
          >
            {#if anyActive}
              <Check class="h-2.5 w-2.5 stroke-[2.75]" />
            {/if}
          </span>
          <span>{s.timeLabels['']}</span>
        </button>

        <button
          type="button"
          onclick={() => {
            onClose();
            workbench.openSourcesDrawer(false);
          }}
          title={basisFullTitle}
          class="touch-target inline-flex min-w-0 items-center gap-1 rounded-md px-1.5 py-1 text-[11px] text-muted-foreground/80 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
        >
          {#if basis.contentCount > 0}
            <Clock class="h-3 w-3 shrink-0 text-primary/80" />
          {:else}
            <FileClock class="h-3 w-3 shrink-0" />
          {/if}
          <span class="truncate">{basisShortLabel}</span>
          <SlidersHorizontal class="h-2.5 w-2.5 shrink-0 opacity-65" />
        </button>
      </div>

      {#if hasCustomSpecBadge}
        <div class="flex items-center justify-between gap-2 rounded-lg bg-primary/[0.08] px-2.5 py-1.5 ring-1 ring-inset ring-primary/25">
          <div class="flex min-w-0 items-center gap-2">
            <span class="flex h-4 w-4 shrink-0 items-center justify-center rounded-[4px] border border-primary bg-primary text-primary-foreground">
              <Check class="h-3 w-3 stroke-[2.75]" />
            </span>
            <span class="truncate text-xs font-medium text-foreground">
              {formatTimeScopeLabel(value, s.timeLabels)}
            </span>
          </div>
          <span class="shrink-0 font-mono text-[11px] tabular-nums text-primary">
            {value}
          </span>
        </div>
      {/if}

      <!-- Structured 3x4 Quick Preset Matrix -->
      <div
        role="presentation"
        class="space-y-1.5"
        onmouseleave={() => {
          hoverPreset = null;
        }}
      >
        {#each QUICK_TIME_PRESET_GROUPS as group, gIdx (group.id)}
          <div class="grid grid-cols-4 gap-1.5">
            {#each group.presets as preset, pIdx (preset)}
              {@const flatIdx = gIdx * 4 + pIdx}
              {@const active = !customDirty && value === preset}
              {@const keyFocused = !customDirty && focusedIdx === flatIdx}
              {@const isNamedDay = preset === 'today' || preset === 'yesterday'}
              <button
                type="button"
                onmousedown={(e) => e.preventDefault()}
                onmouseenter={() => {
                  if (!customDirty && !workbench.isTouch) hoverPreset = preset;
                }}
                onclick={() => selectPreset(preset)}
                title={s.timeLabels[preset] ?? preset}
                class={`touch-target flex h-8 items-center justify-center rounded-lg text-xs tabular-nums cursor-pointer active:bg-primary/20 ${
                  isNamedDay ? '' : 'font-mono'
                } ${
                  active
                    ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 font-medium'
                    : keyFocused
                      ? 'bg-secondary/85 text-foreground ring-1 ring-inset ring-border'
                      : 'bg-secondary/45 text-foreground/90 hover:bg-secondary/80 hover:text-foreground'
                }`}
              >
                {s.timeShortLabels[preset] ?? s.timeLabels[preset] ?? preset}
              </button>
            {/each}
          </div>
        {/each}
      </div>
    {/if}

    <div class="border-t border-border/50"></div>

    <!-- 3. Pre-filled, Synced, Segmented Year/Month/Day Hour:Minute:Second Rows -->
    <div class="space-y-1.5">
      {@render renderBoundRow('start')}
      {@render renderBoundRow('end')}
    </div>
  </div>

  <!-- 4. Unified Micro-Footer matching SourcePickerPopover -->
  <div class="flex h-9 shrink-0 items-center justify-between gap-2 border-t border-border/50 bg-muted/30 px-3">
    <div class="min-w-0 flex-1">
      {#if footerPreviewLabel}
        <span class="block truncate font-mono text-[11px] tabular-nums text-muted-foreground">
          {footerPreviewLabel}
        </span>
      {:else}
        <span class="block truncate text-[11px] text-muted-foreground/70">
          {tp.inputHint}
        </span>
      {/if}
    </div>

    <button
      type="button"
      onclick={submitCustomRange}
      class={`touch-target inline-flex h-[26px] shrink-0 items-center rounded-md px-2.5 text-xs font-medium cursor-pointer active:opacity-85 ${
        customDirty || (hasQuickQuery && quickCandidates.length > 0)
          ? 'bg-primary text-primary-foreground hover:opacity-90'
          : 'bg-secondary/75 text-foreground hover:bg-secondary'
      }`}
    >
      {tp.apply}
    </button>
  </div>
{/snippet}

{#if workbench.isCompact}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="fixed inset-0 z-40 bg-black/50 backdrop-blur-[1px]"
    onclick={onClose}
    onkeydown={(e) => {
      if (e.key === 'Escape') onClose();
    }}
  ></div>
  <div
    bind:this={panelEl}
    role="dialog"
    tabindex="-1"
    aria-label={s.timePickerTitle}
    onkeydown={handlePanelKeydown}
    style={dragY > 0 ? `transform: translate3d(0, ${dragY}px, 0); transition: none` : undefined}
    class="pb-safe fixed inset-x-2.5 bottom-3 z-50 mx-auto flex max-h-[82dvh] max-w-[400px] flex-col overflow-hidden rounded-2xl border border-border/85 bg-popover text-popover-foreground shadow-2xl transition-transform focus:outline-none select-none"
  >
    <div
      role="presentation"
      onpointerdown={onHandleDown}
      onpointermove={onHandleMove}
      onpointerup={onHandleUp}
      onpointercancel={onHandleUp}
      style="touch-action: none"
      class="flex h-5 shrink-0 cursor-grab items-center justify-center touch-none active:cursor-grabbing"
    >
      <div class="h-1 w-9 rounded-full bg-border"></div>
    </div>
    {@render pickerContent()}
  </div>
{:else}
  <div
    bind:this={panelEl}
    role="dialog"
    tabindex="-1"
    aria-label={s.timePickerTitle}
    onkeydown={handlePanelKeydown}
    style={`${offsetX !== 0 ? `transform: translateX(${offsetX}px);` : ''}${maxPanelH !== null ? ` max-height: ${maxPanelH}px;` : ''}`}
    class="absolute left-0 top-full z-50 mt-2.5 flex w-[376px] max-w-[calc(100vw-1.5rem)] flex-col overflow-hidden rounded-2xl border border-border/85 bg-popover text-popover-foreground shadow-2xl focus:outline-none select-none"
  >
    {@render pickerContent()}
  </div>
{/if}
