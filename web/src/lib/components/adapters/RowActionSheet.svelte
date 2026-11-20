<script lang="ts">
  import type { RowActionItem } from '$lib/adapters/index.ts';
  import { Ban, Copy, FileCode, FolderSearch, Link2, UnfoldVertical } from 'lucide-svelte';

  interface Props {
    title: string;
    actions: readonly RowActionItem[];
    onClose: () => void;
  }

  let { title, actions, onClose }: Props = $props();

  const ICON_MAP = {
    copy: Copy,
    'copy-path': FileCode,
    trace: Link2,
    context: UnfoldVertical,
    'solo-source': FolderSearch,
    'exclude-source': Ban,
  } as const;
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  onclick={onClose}
  onkeydown={(e) => e.key === 'Escape' && onClose()}
  class="fixed inset-0 z-50 flex items-end bg-black/50 select-none"
>
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    onclick={(e) => e.stopPropagation()}
    class="pb-safe w-full rounded-t-2xl border-t border-border bg-card p-3"
  >
    <div class="mx-auto mb-3 h-1 w-9 rounded-full bg-border"></div>
    <div class="mb-2 truncate px-2 font-mono text-[12px] text-muted-foreground">
      {title}
    </div>
    <div class="flex items-center justify-around">
      {#each actions as act (act.id)}
        {@const Icon = ICON_MAP[act.iconKind]}
        <button
          type="button"
          onclick={() => {
            act.run();
            onClose();
          }}
          aria-label={act.title}
          title={act.title}
          class={`flex h-14 w-14 items-center justify-center rounded-xl ${
            act.accent
              ? 'bg-primary/15 text-primary active:bg-primary/25'
              : 'bg-secondary text-foreground active:bg-secondary/60'
          }`}
        >
          <Icon class="h-5 w-5" />
        </button>
      {/each}
    </div>
  </div>
</div>
