<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { buildCommands } from '$lib/commands';
  import { Search } from 'lucide-svelte';

  let query = $state('');
  let selected = $state(0);
  let inputEl = $state<HTMLInputElement | null>(null);

  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    const all = buildCommands();
    return q ? all.filter((c) => c.title.toLowerCase().includes(q) || c.id.includes(q)) : all;
  });

  $effect(() => {
    if (workbench.paletteOpen) {
      query = '';
      selected = 0;
      queueMicrotask(() => inputEl?.focus());
    }
  });

  $effect(() => {
    if (selected >= filtered.length) selected = Math.max(0, filtered.length - 1);
  });

  function close() {
    workbench.paletteOpen = false;
  }

  function runAt(idx: number) {
    const cmd = filtered[idx];
    if (!cmd) return;
    close();
    cmd.run();
  }

  function onKeydown(e: KeyboardEvent) {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      selected = filtered.length ? (selected + 1) % filtered.length : 0;
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      selected = filtered.length ? (selected - 1 + filtered.length) % filtered.length : 0;
    } else if (e.key === 'Enter') {
      e.preventDefault();
      runAt(selected);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      close();
    }
  }
</script>

{#if workbench.paletteOpen}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    onclick={close}
    onkeydown={onKeydown}
    class="fixed inset-0 z-[60] flex items-start justify-center bg-black/55 backdrop-blur-xs p-0 md:p-4 md:pt-[14vh] select-none"
  >
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div
      onclick={(e) => e.stopPropagation()}
      class="pt-safe w-full md:max-w-[480px] overflow-hidden md:rounded-xl border-b md:border border-border bg-card shadow-2xl"
    >
      <div class="flex h-12 items-center gap-2.5 border-b border-border/60 px-4">
        <Search class="h-4 w-4 shrink-0 text-muted-foreground" />
        <input
          bind:this={inputEl}
          bind:value={query}
          onkeydown={onKeydown}
          placeholder={workbench.t.palette.placeholder}
          spellcheck="false"
          autocomplete="off"
          class="h-full min-w-0 flex-1 bg-transparent text-[14px] text-foreground placeholder:text-muted-foreground/65 focus:outline-none"
        />
      </div>
      <div role="listbox" class="max-h-[60dvh] overflow-y-auto p-1.5">
        {#each filtered as cmd, idx (cmd.id)}
          {@const Icon = cmd.icon}
          <button
            type="button"
            role="option"
            aria-selected={idx === selected}
            onmouseenter={() => (selected = idx)}
            onclick={() => runAt(idx)}
            class={`flex w-full items-center gap-3 rounded-lg px-3 py-3 md:py-2 text-left text-[13.5px] transition-colors ${
              idx === selected ? 'bg-secondary text-foreground' : 'text-foreground/90'
            }`}
          >
            <Icon class="h-4 w-4 shrink-0 text-muted-foreground" />
            <span class="flex-1 truncate">{cmd.title}</span>
            {#if cmd.shortcut}
              <kbd class="shrink-0 rounded border border-border bg-secondary px-1.5 py-0.5 font-mono text-[11px] text-muted-foreground">{cmd.shortcut}</kbd>
            {/if}
          </button>
        {:else}
          <div class="px-3 py-6 text-center text-[13px] text-muted-foreground">
            {workbench.t.palette.empty}
          </div>
        {/each}
      </div>
    </div>
  </div>
{/if}
