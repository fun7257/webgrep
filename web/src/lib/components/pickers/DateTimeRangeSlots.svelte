<script lang="ts">
  import { flushSync } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import {
    DATETIME_SLOTS,
    clampDateTimeParts,
    dateToParts,
    extractPastedDateTime,
    extractedToDateTimeParts,
    stepDateTimeSlot,
    type DateTimeParts,
    type DateTimeSlot,
    type SyncedTimeRangeState,
  } from '$lib/time-range';

  type BoundSide = 'start' | 'end';

  interface Props {
    startParts: DateTimeParts;
    endParts: DateTimeParts;
    endIsNow: boolean;
    customDirty: boolean;
    focusedKey?: string | null;
    displayedStart: DateTimeParts;
    displayedEnd: DateTimeParts;
    effectiveEndIsNow: boolean;
    previewSynced: SyncedTimeRangeState | null;
    onClearHoverPreset: () => void;
    onSubmit: () => void;
  }

  let {
    startParts = $bindable(),
    endParts = $bindable(),
    endIsNow = $bindable(),
    customDirty = $bindable(),
    focusedKey = $bindable(null),
    displayedStart,
    displayedEnd,
    effectiveEndIsNow,
    previewSynced,
    onClearHoverPreset,
    onSubmit,
  }: Props = $props();

  let rawEditText = $state<string>('');
  let justFocusedKey: string | null = null;
  let nowToggledOnDown = false;
  const slotEls: Record<string, HTMLInputElement | null> = {};

  const tp = $derived(workbench.t.scopeBar.timePicker);

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

  /** Commit any unblurred active slot digits before applying a custom range. */
  export function commitFocusedSlot() {
    if (!focusedKey) return;
    const [b, sSlot] = focusedKey.split(':') as [BoundSide, DateTimeSlot];
    const clamped = commitRawSlot(b, sSlot, rawEditText.replace(/\D/g, ''));
    rawEditText = clamped[sSlot];
  }

  function toggleEndNow() {
    if (previewSynced && !customDirty) {
      startParts = { ...previewSynced.start };
    }
    const curIsNow = previewSynced && !customDirty ? previewSynced.endIsNow : endIsNow;
    focusedKey = null;
    onClearHoverPreset();
    customDirty = true;
    endParts = dateToParts(new Date());
    endIsNow = !curIsNow;
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
    onClearHoverPreset();
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
      commitFocusedSlot();
      onSubmit();
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

  const slotInputCls =
    'relative z-10 h-6 [@media(any-pointer:coarse)]:h-7 rounded bg-secondary/55 px-0.5 text-center font-mono text-xs tabular-nums hover:bg-secondary focus:bg-primary/20 focus:text-primary focus:ring-1 focus:ring-inset focus:ring-primary/45 focus:outline-none';
</script>

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
          onmousedown={(e) => e.preventDefault()}
          onpointerdown={(e) => {
            if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
              e.preventDefault();
              nowToggledOnDown = true;
              flushSync(toggleEndNow);
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

<div class="space-y-1.5">
  {@render renderBoundRow('start')}
  {@render renderBoundRow('end')}
</div>
