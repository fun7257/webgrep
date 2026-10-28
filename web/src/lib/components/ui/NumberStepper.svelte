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

  let isInteger = $derived(Number.isInteger(step));

  function clamp(n: number): number {
    if (!Number.isFinite(n)) return value;
    const rounded = isInteger ? Math.round(n) : Math.round(n * 10) / 10;
    return Math.max(min, Math.min(max, rounded));
  }

  function stepBy(delta: number) {
    const next = clamp(value + delta * step);
    if (next !== value) {
      onchange(next);
    }
  }

  function handleInput(e: Event) {
    const raw = (e.currentTarget as HTMLInputElement).value.trim();
    if (!raw) return;
    const parsed = isInteger ? parseInt(raw, 10) : parseFloat(raw);
    if (!Number.isFinite(parsed)) return;
    onchange(clamp(parsed));
  }

  function handleBlur(e: FocusEvent) {
    const input = e.currentTarget as HTMLInputElement;
    input.value = String(value);
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'ArrowUp') {
      e.preventDefault();
      stepBy(1);
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      stepBy(-1);
    }
  }
</script>

<div
  class="inline-flex h-8 items-center rounded-lg border border-border/80 bg-background/90 p-0.5 shadow-2xs focus-within:border-primary/80 focus-within:ring-2 focus-within:ring-primary/15 transition-all"
>
  <button
    type="button"
    title="Decrease"
    disabled={value <= min}
    onclick={() => stepBy(-1)}
    class="flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-secondary hover:text-foreground disabled:opacity-30 disabled:pointer-events-none transition-colors"
  >
    <Minus class="h-3 w-3" />
  </button>

  <div class="flex items-center px-1.5">
    {#if prefix}
      <span class="font-mono text-xs text-muted-foreground select-none mr-0.5">{prefix}</span>
    {/if}
    <input
      type="text"
      inputmode={isInteger ? 'numeric' : 'decimal'}
      value={value}
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
    title="Increase"
    disabled={value >= max}
    onclick={() => stepBy(1)}
    class="flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-secondary hover:text-foreground disabled:opacity-30 disabled:pointer-events-none transition-colors"
  >
    <Plus class="h-3 w-3" />
  </button>
</div>
