<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { onMount } from 'svelte';
  import { Delete } from 'lucide-svelte';

  interface Props {
    onInsert: (sym: string) => void;
    onBackspace: () => void;
  }

  let { onInsert, onBackspace }: Props = $props();

  // Keyboard-attached offset: distance between layout viewport bottom and visual viewport bottom.
  let bottomOffset = $state(0);

  onMount(() => {
    const vv = window.visualViewport;
    if (!vv) return;
    let raf = 0;
    const update = () => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => {
        bottomOffset = Math.max(0, window.innerHeight - (vv.height + vv.offsetTop));
      });
    };
    update();
    vv.addEventListener('resize', update);
    vv.addEventListener('scroll', update);
    return () => {
      cancelAnimationFrame(raf);
      vv.removeEventListener('resize', update);
      vv.removeEventListener('scroll', update);
    };
  });

  const toggles = $derived([
    { label: '$r', active: workbench.hasRegexActive, run: () => workbench.toggleFlag('r') },
    { label: '$c', active: workbench.caseMode === 'sensitive', run: () => workbench.toggleFlag('c') },
    { label: '$w', active: workbench.wholeWord, run: () => workbench.toggleFlag('w') },
  ]);

  const symbols = ['@', '-', '"'];

  // Keep input focus (and the soft keyboard) while tapping toolbar buttons.
  function keepFocus(e: Event) {
    e.preventDefault();
  }

  const btn =
    'flex h-10 min-w-11 flex-1 items-center justify-center rounded-lg font-mono text-[14px] transition-colors active:bg-secondary';
</script>

<div
  role="toolbar"
  tabindex="-1"
  onmousedown={keepFocus}
  onpointerdown={keepFocus}
  style={`bottom: ${bottomOffset}px`}
  class="fixed inset-x-0 z-40 flex items-center gap-1 border-t border-border bg-card px-2 py-1.5"
>
  {#each toggles as tg (tg.label)}
    <button
      type="button"
      onclick={tg.run}
      class={`${btn} ${tg.active ? 'bg-primary/15 text-primary' : 'text-foreground'}`}
    >
      {tg.label}
    </button>
  {/each}
  <span class="mx-0.5 h-5 w-px bg-border"></span>
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
