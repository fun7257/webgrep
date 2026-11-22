<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { Delete } from 'lucide-svelte';

  interface Props {
    onInsert: (sym: string) => void;
    onBackspace: () => void;
  }

  let { onInsert, onBackspace }: Props = $props();

  const regexSymbols = ['\\d+', '|', '.*', '()'];

  function keepFocus(e: Event) {
    e.preventDefault();
  }

  const btn =
    'touch-target flex h-8 min-w-10 flex-1 items-center justify-center rounded-lg font-mono text-[13.5px] hover:bg-secondary/60 active:bg-secondary';
</script>

<div
  role="toolbar"
  tabindex="-1"
  onmousedown={keepFocus}
  onpointerdown={keepFocus}
  class="flex items-center gap-1 px-2.5 py-1.5"
>
  <button
    type="button"
    onclick={() => workbench.toggleRegexMode()}
    class={`${btn} ${
      workbench.isRegex ? 'bg-primary/15 text-primary font-semibold' : 'text-foreground'
    }`}
  >
    .*
  </button>
  {#each regexSymbols as sym (sym)}
    <button
      type="button"
      onclick={() => onInsert(sym)}
      class={`${btn} text-foreground`}
    >
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
