<script lang="ts">
  import { cn } from '$lib/utils';
  import type { Snippet } from 'svelte';

  interface Props {
    variant?: 'default' | 'secondary' | 'outline' | 'status';
    class?: string;
    children?: Snippet;
  }

  let {
    variant = 'default',
    class: className = '',
    children,
  }: Props = $props();

  const variantClasses: Record<NonNullable<Props['variant']>, string> = {
    default: 'bg-primary/15 text-primary border-primary/30',
    secondary: 'bg-secondary text-secondary-foreground border-border',
    outline: 'text-foreground border-border bg-transparent',
    status: 'bg-status/15 text-status border-status/30',
  };
</script>

<span
  class={cn(
    'inline-flex items-center gap-1 rounded border px-1.5 py-0.5 text-[11px] font-medium leading-none transition-colors tabular-nums',
    variantClasses[variant],
    className
  )}
>
  {@render children?.()}
</span>
