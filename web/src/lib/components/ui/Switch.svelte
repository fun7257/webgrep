<script lang="ts">
  interface Props {
    checked: boolean;
    title?: string;
    onchange: (nextChecked: boolean) => void;
  }

  let { checked, title = 'Toggle option', onchange }: Props = $props();
</script>

<button
  type="button"
  role="switch"
  {title}
  aria-checked={checked}
  onclick={() => onchange(!checked)}
  class={`touch-target group relative inline-flex h-5 w-9 shrink-0 cursor-pointer items-center rounded-full border border-transparent transition-colors duration-150 focus:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 ${
    checked
      ? 'bg-primary shadow-xs'
      : 'bg-secondary/90 border-border/80 hover:bg-secondary'
  }`}
>
  <span
    class={`pointer-events-none inline-block h-3.5 w-3.5 transform rounded-full shadow-sm transition-transform duration-150 ${
      checked
        ? 'translate-x-4 bg-primary-foreground'
        : 'translate-x-0.5 bg-muted-foreground/80 group-hover:bg-foreground'
    }`}
  ></span>
</button>
