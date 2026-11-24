<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import type { RowActionIconKind, RowActionItem } from '$lib/adapters/index.ts';
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

  const SHORT_LABELS: Record<RowActionIconKind, { zh: string; en: string }> = {
    copy: { zh: '复制', en: 'Copy' },
    'copy-path': { zh: '路径', en: 'Path' },
    trace: { zh: 'Trace', en: 'Trace' },
    context: { zh: '上下文', en: 'Context' },
    'solo-source': { zh: '仅此源', en: 'Solo' },
    'exclude-source': { zh: '排除', en: 'Exclude' },
  };
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  onclick={onClose}
  onkeydown={(e) => e.key === 'Escape' && onClose()}
  class="fixed inset-0 z-50 flex items-end bg-black/50 select-none"
>
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div
    role="dialog"
    aria-modal="true"
    aria-label={title}
    tabindex="-1"
    onclick={(e) => e.stopPropagation()}
    class="pb-safe w-full rounded-t-2xl border-t border-border bg-card p-3 focus:outline-none"
  >
    <div class="mx-auto mb-3 h-1 w-9 rounded-full bg-border"></div>
    <div class="mb-2 truncate px-2 font-mono text-[12px] text-muted-foreground">
      {title}
    </div>
    <div class="flex items-center justify-around gap-1.5">
      {#each actions as act (act.id)}
        {@const Icon = ICON_MAP[act.iconKind]}
        {@const shortLabel = SHORT_LABELS[act.iconKind][workbench.locale === 'zh' ? 'zh' : 'en']}
        <button
          type="button"
          onclick={() => {
            act.run();
            onClose();
          }}
          aria-label={act.title}
          title={act.title}
          class={`touch-target flex min-w-0 flex-1 max-w-[76px] flex-col items-center justify-center gap-1 rounded-xl px-1 py-2.5 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 ${
            act.accent
              ? 'bg-primary/15 text-primary active:bg-primary/25'
              : 'bg-secondary text-foreground active:bg-secondary/60'
          }`}
        >
          <Icon class="h-5 w-5 shrink-0" />
          <span class="max-w-full truncate text-[11px] font-medium leading-none">
            {shortLabel}
          </span>
        </button>
      {/each}
    </div>
  </div>
</div>
