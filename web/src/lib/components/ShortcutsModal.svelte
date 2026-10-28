<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { Keyboard, X } from 'lucide-svelte';
</script>

{#if workbench.shortcutsModalOpen}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    onclick={() => (workbench.shortcutsModalOpen = false)}
    onkeydown={(e) => {
      if (e.key === 'Escape') workbench.shortcutsModalOpen = false;
    }}
    class="fixed inset-0 z-50 flex items-center justify-center bg-black/65 backdrop-blur-xs p-4 select-none"
  >
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div
      onclick={(e) => e.stopPropagation()}
      class="w-full max-w-md rounded-xl border border-border bg-card p-5 shadow-2xl space-y-4"
    >
      <div class="flex items-center justify-between border-b border-border pb-3">
        <div class="flex items-center gap-2">
          <Keyboard class="h-4 w-4 text-primary" />
          <h3 class="text-sm font-semibold text-foreground">{workbench.t.shortcuts.title}</h3>
        </div>
        <button
          type="button"
          onclick={() => (workbench.shortcutsModalOpen = false)}
          class="rounded p-1 text-muted-foreground hover:bg-secondary hover:text-foreground"
        >
          <X class="h-4 w-4" />
        </button>
      </div>

      <div class="divide-y divide-border text-[13px]">
        {#each workbench.t.shortcuts.items as s (s.key)}
          <div class="flex items-center justify-between py-2.5">
            <span class="text-foreground">{s.desc}</span>
            <kbd
              class="rounded border border-border bg-secondary px-2 py-0.5 font-mono text-xs font-medium text-foreground"
            >
              {s.key}
            </kbd>
          </div>
        {/each}
      </div>
    </div>
  </div>
{/if}
