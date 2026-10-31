<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { Delete } from 'lucide-svelte';

  interface Props {
    onInsert: (sym: string) => void;
    onBackspace: () => void;
  }

  let { onInsert, onBackspace }: Props = $props();

  // Each tap inserts a NEW scoped `$x()` token (multiple scoped modes can coexist);
  // the highlight only reflects that a mode is currently active.
  const toggles = $derived([
    { label: '$r', token: '$r()', active: workbench.hasRegexActive },
    { label: '$c', token: '$c()', active: workbench.hasCaseActive },
    { label: '$w', token: '$w()', active: workbench.hasWordActive },
    { label: '$t', token: '$t()', active: workbench.hasTimeActive },
  ]);

  const symbols = ['@', '-', '"'];

  // Keep input focus (and the soft keyboard) while tapping toolbar buttons.
  function keepFocus(e: Event) {
    e.preventDefault();
  }

  const btn =
    'touch-target flex h-8 min-w-10 flex-1 items-center justify-center rounded-lg font-mono text-[13.5px] transition-colors hover:bg-secondary/60 active:bg-secondary';
</script>

<div
  role="toolbar"
  tabindex="-1"
  onmousedown={keepFocus}
  onpointerdown={keepFocus}
  class="flex items-center gap-1 px-2.5 py-1.5"
>
  {#each toggles as tg (tg.label)}
    <button
      type="button"
      onclick={() => onInsert(tg.token)}
      class={`${btn} ${tg.active ? 'bg-primary/15 text-primary font-medium' : 'text-foreground'}`}
    >
      {tg.label}
    </button>
  {/each}
  <span class="mx-0.5 h-4 w-px bg-border"></span>
  {#each symbols as sym (sym)}
    <button type="button" onclick={() => onInsert(sym)} class={`${btn} text-foreground`}>
      {sym}
    </button>
  {/each}
  <button
    type="button"
    onclick={onBackspace}
    aria-label="Backspace token"
    class={`${btn} text-muted-foreground`}
  >
    <Delete class="h-4 w-4" />
  </button>
</div>
