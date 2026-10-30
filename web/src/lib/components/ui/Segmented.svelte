<script lang="ts" generics="T extends string | boolean">
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
</script>

<div
  role="radiogroup"
  class="inline-flex h-8 shrink-0 items-center rounded-lg border border-border/80 bg-background/90 p-0.5"
>
  {#each options as opt (String(opt.value))}
    {@const Icon = opt.icon}
    <button
      type="button"
      role="radio"
      aria-checked={value === opt.value}
      aria-label={opt.title}
      title={opt.title}
      onclick={() => onchange(opt.value)}
      class={`touch-target flex h-6 min-w-8 items-center justify-center gap-1 rounded-md px-2 text-xs transition-colors cursor-pointer ${
        value === opt.value
          ? 'bg-primary text-primary-foreground'
          : 'text-muted-foreground hover:text-foreground'
      }`}
    >
      {#if Icon}<Icon class="h-3.5 w-3.5" />{/if}
      {#if opt.label}<span>{opt.label}</span>{/if}
    </button>
  {/each}
</div>
