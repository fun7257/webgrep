<script lang="ts">
  import { flushSync } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { Check, Lock, LockOpen } from 'lucide-svelte';
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
    if (dir > 0 && bound === 'start' && !effectiveEndIsNow) {
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
    const nextIsNow = !curIsNow;
    endIsNow = nextIsNow;
    if (!nextIsNow && !workbench.isTouch) {
      queueMicrotask(() => focusSlot('end', 'hour'));
    }
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

  const slotInputBaseCls =
    'relative z-10 h-5 [@media(any-pointer:coarse)]:h-7 rounded bg-transparent px-0.5 text-center font-mono text-[11.5px] tabular-nums focus:outline-none';
  const slotInputEditableCls =
    'text-foreground hover:bg-secondary/80 focus:bg-primary/20 focus:text-primary focus:ring-1 focus:ring-inset focus:ring-primary/45';
  const slotInputLockedCls = 'text-muted-foreground/75 cursor-default';
</script>

{#snippet renderSlotInput(
  bound: BoundSide,
  slot: DateTimeSlot,
  widthCls: string,
  ariaUnit: string,
  locked: boolean
)}
  {@const key = slotKey(bound, slot)}
  {@const rowLabel = bound === 'start' ? tp.startLabel : tp.endLabel}
  <input
    use:registerSlot={key}
    type="text"
    inputmode="numeric"
    autocomplete="off"
    spellcheck="false"
    disabled={locked}
    value={getSlotDisplayValue(bound, slot)}
    onfocus={(e) => handleSlotFocus(bound, slot, e)}
    onmouseup={(e) => handleSlotMouseUp(bound, slot, e)}
    onblur={() => handleSlotBlur(bound, slot)}
    oninput={(e) => handleSlotInput(bound, slot, e)}
    onkeydown={(e) => handleSlotKeydown(bound, slot, e)}
    onpaste={(e) => handleSlotPaste(bound, slot, e)}
    aria-label={`${rowLabel} ${ariaUnit}`}
    class={`${slotInputBaseCls} ${widthCls} ${locked ? slotInputLockedCls : slotInputEditableCls}`}
  />
{/snippet}

{#snippet renderBoundRow(bound: BoundSide)}
  {@const isEnd = bound === 'end'}
  {@const isLocked = isEnd && effectiveEndIsNow}
  {@const lockTitle = isLocked
    ? workbench.locale === 'zh'
      ? '已锁定为现在 · 点击解锁输入结束时间'
      : 'Locked to Now · Click to unlock end time'
    : workbench.locale === 'zh'
      ? '已解锁 · 点击锁定为现在'
      : 'Unlocked · Click to lock to Now'}
  <div class="flex items-center gap-1.5 min-w-0">
    <!-- Visual timeline node (○ start → ● end) -->
    <span
      aria-hidden="true"
      title={isEnd ? tp.endLabel : tp.startLabel}
      class={`relative z-10 h-2 w-2 shrink-0 rounded-full ${
        isEnd
          ? effectiveEndIsNow
            ? 'bg-primary ring-2 ring-primary/25'
            : 'bg-muted-foreground/75'
          : 'border-[1.5px] border-muted-foreground/75 bg-background'
      }`}
    ></span>

    <div
      class={`flex h-7 [@media(any-pointer:coarse)]:h-9 min-w-0 flex-1 items-center rounded-md border px-1.5 ${
        isLocked
          ? 'border-border/45 bg-secondary/25'
          : 'border-border/60 bg-background/75 focus-within:border-primary/60'
      }`}
    >
      <div class="flex items-center">
        {@render renderSlotInput(bound, 'year', 'w-[34px] [@media(any-pointer:coarse)]:w-[40px]', tp.yearLabel, isLocked)}
        <span class="font-mono text-[10px] text-muted-foreground/45 select-none">-</span>
        {@render renderSlotInput(bound, 'month', 'w-[19px] [@media(any-pointer:coarse)]:w-[24px]', tp.monthLabel, isLocked)}
        <span class="font-mono text-[10px] text-muted-foreground/45 select-none">-</span>
        {@render renderSlotInput(bound, 'day', 'w-[19px] [@media(any-pointer:coarse)]:w-[24px]', tp.dayLabel, isLocked)}
      </div>

      <span class="mx-1 h-3 w-px shrink-0 bg-border/55"></span>

      <div class="flex items-center">
        {@render renderSlotInput(bound, 'hour', 'w-[19px] [@media(any-pointer:coarse)]:w-[24px]', tp.hourLabel, isLocked)}
        <span class="font-mono text-[10px] text-muted-foreground/45 select-none">:</span>
        {@render renderSlotInput(bound, 'minute', 'w-[19px] [@media(any-pointer:coarse)]:w-[24px]', tp.minuteLabel, isLocked)}
        <span class="font-mono text-[10px] text-muted-foreground/45 select-none">:</span>
        {@render renderSlotInput(bound, 'second', 'w-[19px] [@media(any-pointer:coarse)]:w-[24px]', tp.secondLabel, isLocked)}
      </div>

      {#if isEnd}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onpointerdown={(e) => {
            if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
              e.preventDefault();
              e.stopPropagation();
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
          title={lockTitle}
          aria-label={lockTitle}
          aria-pressed={effectiveEndIsNow}
          class={`touch-target ml-auto flex h-5 w-5 shrink-0 items-center justify-center rounded cursor-pointer ${
            effectiveEndIsNow
              ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35 hover:bg-primary/20'
              : 'text-muted-foreground hover:bg-secondary hover:text-foreground active:bg-secondary'
          }`}
        >
          {#if effectiveEndIsNow}
            <Lock class="h-3 w-3" />
          {:else}
            <LockOpen class="h-3 w-3" />
          {/if}
        </button>
      {/if}
    </div>
  </div>
{/snippet}

<div class="space-y-1.5" title={tp.inputHint}>
  <div class="relative space-y-1.5">
    <!-- Vertical timeline rail connecting start dot to end dot -->
    <span
      aria-hidden="true"
      class="pointer-events-none absolute left-[3.5px] top-[14px] bottom-[14px] [@media(any-pointer:coarse)]:top-[18px] [@media(any-pointer:coarse)]:bottom-[18px] w-px bg-border/80"
    ></span>
    {@render renderBoundRow('start')}
    {@render renderBoundRow('end')}
  </div>

  {#if customDirty}
    <div class="flex items-center justify-end pl-3.5">
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={onSubmit}
        title={tp.apply}
        aria-label={tp.apply}
        class="touch-target inline-flex h-6 items-center gap-1 rounded-md bg-primary px-2.5 text-[11px] font-medium text-primary-foreground hover:opacity-90 active:opacity-80 cursor-pointer"
      >
        <Check class="h-3 w-3 shrink-0 stroke-[2.5]" />
        <span>{tp.apply}</span>
      </button>
    </div>
  {/if}
</div>
