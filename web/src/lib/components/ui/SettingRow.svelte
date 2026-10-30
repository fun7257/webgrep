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

<div class="flex min-h-11 items-center gap-3" title={hint || label}>
  <Icon class="h-4 w-4 shrink-0 text-muted-foreground" />
  <span class="min-w-0 flex-1 truncate text-foreground/90">{label}</span>
  {@render children?.()}
</div>
