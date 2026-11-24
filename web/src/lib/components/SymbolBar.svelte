<script lang="ts">
  import { workbench } from '$lib/state.svelte';

  interface Props {
    onInsert: (sym: string) => void;
  }

  let { onInsert }: Props = $props();

  const regexSymbols: ReadonlyArray<{ sym: string; zh: string; en: string }> = [
    { sym: '.*', zh: '.* (任意字符)', en: '.* (any)' },
    { sym: '\\d+', zh: '\\d+ (数字)', en: '\\d+ (digits)' },
    { sym: '|', zh: '| (或)', en: '| (or)' },
    { sym: '()', zh: '() (分组)', en: '() (group)' },
    { sym: '^', zh: '^ (行首)', en: '^ (line start)' },
    { sym: '$', zh: '$ (行尾)', en: '$ (line end)' },
  ];

  function keepFocus(e: Event) {
    e.preventDefault();
  }

  const btn =
    'touch-target flex h-8 min-w-9 flex-1 items-center justify-center rounded-lg font-mono text-[13px] text-foreground hover:bg-secondary/60 active:bg-secondary cursor-pointer';
</script>

<div
  role="toolbar"
  tabindex="-1"
  onmousedown={keepFocus}
  onpointerdown={keepFocus}
  class="flex items-center gap-1 px-2.5 py-1.5"
>
  {#each regexSymbols as item (item.sym)}
    {@const tip = workbench.locale === 'zh' ? item.zh : item.en}
    <button
      type="button"
      onclick={() => onInsert(item.sym)}
      title={tip}
      aria-label={tip}
      class={btn}
    >
      {item.sym}
    </button>
  {/each}
</div>
