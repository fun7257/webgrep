<script lang="ts">
  import type { Sun } from 'lucide-svelte';
  import type { Snippet } from 'svelte';

  interface Props {
    icon: typeof Sun;
    label: string;
    /** Longer explanation, shown as tooltip only (keeps the row text-light). */
    hint?: string;
    children?: Snippet;
  }

  let { icon: Icon, label, hint = '', children }: Props = $props();
</script>

<div class="flex min-h-11 items-center gap-3 py-1.5" title={hint || label}>
  <Icon class="h-4 w-4 shrink-0 text-muted-foreground/80" aria-hidden="true" />
  <span class="min-w-0 flex-1 truncate text-[13px] text-foreground/95">{label}</span>
  <div class="flex shrink-0 items-center">
    {@render children?.()}
  </div>
</div>
