<script lang="ts">
  import { workbench } from '$lib/state.svelte';

  interface Props {
    checked: boolean;
    title?: string;
    onchange: (nextChecked: boolean) => void;
  }

  let { checked, title = '', onchange }: Props = $props();

  const resolvedLabel = $derived(title || (workbench.locale === 'zh' ? '切换开关' : 'Toggle'));
</script>

<button
  type="button"
  role="switch"
  title={resolvedLabel}
  aria-label={resolvedLabel}
  aria-checked={checked}
  onclick={() => onchange(!checked)}
  class={`touch-target group relative inline-flex h-5 w-9 shrink-0 cursor-pointer items-center rounded-full border active:scale-[0.97] focus:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 ${
    checked
      ? 'border-transparent bg-primary shadow-sm'
      : 'border-border/80 bg-secondary/90 hover:bg-secondary'
  }`}
>
  <span
    class={`pointer-events-none inline-block h-3.5 w-3.5 transform rounded-full shadow-sm transition-transform duration-[var(--motion-switch,67ms)] ease-out ${
      checked
        ? 'translate-x-4 bg-primary-foreground'
        : 'translate-x-0.5 bg-muted-foreground/80 group-hover:bg-foreground'
    }`}
  ></span>
</button>
