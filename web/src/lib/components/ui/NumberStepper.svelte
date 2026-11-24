<script lang="ts">
  import { Minus, Plus } from 'lucide-svelte';

  interface Props {
    value: number;
    min?: number;
    max?: number;
    step?: number;
    prefix?: string;
    suffix?: string;
    widthClass?: string;
    onchange: (nextValue: number) => void;
  }

  let {
    value,
    min = 0,
    max = 100000,
    step = 1,
    prefix = '',
    suffix = '',
    widthClass = 'w-14',
    onchange,
  }: Props = $props();

  let isFocused = $state(false);
  let draft = $state('');

  let isInteger = $derived(Number.isInteger(step));
  let stepUnit = $derived(`${step}${suffix}`);
  let rangeHint = $derived(`${min} – ${max}${suffix ? ` ${suffix}` : ''}`);

  function clamp(n: number): number {
    if (!Number.isFinite(n)) return value;
    const rounded = isInteger ? Math.round(n) : Math.round(n * 10) / 10;
    return Math.max(min, Math.min(max, rounded));
  }

  function stepBy(delta: number) {
    const next = clamp(value + delta * step);
    if (isFocused) {
      draft = String(next);
    }
    if (next !== value) {
      onchange(next);
    }
  }

  function commitDraft() {
    const raw = draft.trim();
    if (!raw) {
      draft = String(value);
      return;
    }
    const parsed = isInteger ? parseInt(raw, 10) : parseFloat(raw);
    if (!Number.isFinite(parsed)) {
      draft = String(value);
      return;
    }
    const next = clamp(parsed);
    draft = String(next);
    if (next !== value) {
      onchange(next);
    }
  }

  function handleFocus() {
    isFocused = true;
    draft = String(value);
  }

  function handleInput(e: Event) {
    draft = (e.currentTarget as HTMLInputElement).value;
  }

  function handleBlur() {
    commitDraft();
    isFocused = false;
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'ArrowUp') {
      e.preventDefault();
      stepBy(1);
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      stepBy(-1);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      commitDraft();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      draft = String(value);
      (e.currentTarget as HTMLInputElement).blur();
    }
  }
</script>

<div
  class="inline-flex h-8 shrink-0 items-center rounded-lg border border-border/55 bg-secondary/50 dark:bg-secondary/45 p-0.5 shadow-sm focus-within:border-primary/60 focus-within:bg-background"
>
  <button
    type="button"
    title={`-${stepUnit}`}
    aria-label={`-${stepUnit}`}
    disabled={value <= min}
    onclick={() => stepBy(-1)}
    class="touch-target flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-background hover:text-foreground dark:hover:bg-accent active:opacity-80 disabled:opacity-30 disabled:pointer-events-none cursor-pointer"
  >
    <Minus class="h-3.5 w-3.5" aria-hidden="true" />
  </button>

  <div class="flex items-center px-1.5" title={rangeHint}>
    {#if prefix}
      <span class="font-mono text-xs text-muted-foreground select-none mr-0.5">{prefix}</span>
    {/if}
    <input
      type="text"
      inputmode={isInteger ? 'numeric' : 'decimal'}
      aria-label={rangeHint}
      value={isFocused ? draft : String(value)}
      onfocus={handleFocus}
      oninput={handleInput}
      onblur={handleBlur}
      onkeydown={handleKeydown}
      class={`${widthClass} bg-transparent text-center font-mono text-[13px] font-medium text-foreground tabular-nums focus:outline-none`}
    />
    {#if suffix}
      <span class="font-mono text-[11px] text-muted-foreground select-none ml-0.5">{suffix}</span>
    {/if}
  </div>

  <button
    type="button"
    title={`+${stepUnit}`}
    aria-label={`+${stepUnit}`}
    disabled={value >= max}
    onclick={() => stepBy(1)}
    class="touch-target flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-background hover:text-foreground dark:hover:bg-accent active:opacity-80 disabled:opacity-30 disabled:pointer-events-none cursor-pointer"
  >
    <Plus class="h-3.5 w-3.5" aria-hidden="true" />
  </button>
</div>
