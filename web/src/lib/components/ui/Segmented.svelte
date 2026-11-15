<script lang="ts" generics="T extends string | number | boolean">
  import type { Sun } from 'lucide-svelte';

  interface Option {
    value: T;
    /** Short text label (omit when using an icon). */
    label?: string;
    icon?: typeof Sun;
    title: string;
  }

  interface Props {
    options: Option[];
    value: T;
    onchange: (next: T) => void;
  }

  let { options, value, onchange }: Props = $props();
  let pickedOnDown: string | null = null;
</script>

<div
  role="radiogroup"
  class="inline-flex h-8 shrink-0 items-center rounded-lg border border-border/50 bg-secondary/65 dark:bg-secondary/55 p-0.5"
>
  {#each options as opt (String(opt.value))}
    {@const Icon = opt.icon}
    {@const key = String(opt.value)}
    <button
      type="button"
      role="radio"
      aria-checked={value === opt.value}
      aria-label={opt.title}
      title={opt.title}
      onpointerdown={(e) => {
        if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
          pickedOnDown = key;
          onchange(opt.value);
        }
      }}
      onclick={(e) => {
        if (pickedOnDown === key && e.detail > 0) {
          pickedOnDown = null;
          return;
        }
        pickedOnDown = null;
        onchange(opt.value);
      }}
      class={`touch-target flex h-6 min-w-8 items-center justify-center gap-1 rounded-md px-2 text-xs cursor-pointer ${
        value === opt.value
          ? 'bg-background text-foreground font-medium shadow-[0_1px_2px_hsl(0_0%_0%/0.06)] ring-1 ring-inset ring-border/70 dark:bg-accent dark:ring-border/90'
          : 'text-muted-foreground hover:text-foreground active:bg-background/50'
      }`}
    >
      {#if Icon}<Icon class="h-3.5 w-3.5" />{/if}
      {#if opt.label}<span>{opt.label}</span>{/if}
    </button>
  {/each}
</div>
