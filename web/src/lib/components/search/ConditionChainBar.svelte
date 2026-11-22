<script lang="ts">
  import { flushSync } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { ChevronRight, X } from 'lucide-svelte';

  interface Props {
    onFocusInput: () => void;
    onSyncCursor: () => void;
  }

  let { onFocusInput, onSyncCursor }: Props = $props();
</script>

<div class="mt-2 flex flex-wrap items-center gap-1.5 px-1">
  {#each workbench.steps as step, idx (`${idx}:${step.text}`)}
    {#if idx > 0}
      <ChevronRight class="h-3 w-3 shrink-0 text-muted-foreground/45" />
    {/if}
    <div
      class={`inline-flex max-w-full items-center gap-1 rounded-lg border px-1.5 py-0.5 font-mono text-xs ${
        step.exclude
          ? 'border-status/35 bg-status/10 text-status'
          : 'border-border/75 bg-secondary/45 text-foreground'
      }`}
    >
      <span class="text-[10px] text-muted-foreground/65 select-none">#{idx + 1}</span>
      {#if step.exclude}
        <span class="inline-flex h-4 min-w-[16px] items-center justify-center rounded bg-status/15 px-1 font-mono text-[11px] font-semibold text-status select-none">
          -
        </span>
      {/if}

      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => {
          flushSync(() => {
            workbench.editStepInSearchBox(idx);
          });
          onFocusInput();
          onSyncCursor();
        }}
        title={workbench.t.searchBar.editStepTitle}
        class={`touch-target inline-flex min-w-0 items-center gap-1 truncate px-0.5 text-left hover:underline cursor-pointer ${
          step.exclude ? 'line-through decoration-status/60' : ''
        }`}
      >
        <span class="truncate">{step.text}</span>
        {#if step.caseSensitive}
          <span class="rounded bg-primary/15 px-1 py-0.2 text-[9.5px] font-semibold text-primary shrink-0">
            Aa
          </span>
        {/if}
        {#if step.wholeWord}
          <span class="rounded bg-primary/15 px-1 py-0.2 text-[9.5px] font-semibold text-primary shrink-0">
            ab
          </span>
        {/if}
        {#if step.isRegex}
          <span class="rounded bg-primary/15 px-1 py-0.2 text-[9.5px] font-semibold text-primary shrink-0">
            .*
          </span>
        {/if}
      </button>

      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => {
          workbench.removeStep(idx);
          onFocusInput();
        }}
        title={workbench.t.searchBar.removeStepTitle(step.text)}
        aria-label={workbench.t.searchBar.removeStepTitle(step.text)}
        class="touch-target inline-flex h-4 w-4 shrink-0 items-center justify-center rounded text-muted-foreground/70 hover:bg-secondary hover:text-foreground cursor-pointer"
      >
        <X class="h-3 w-3" />
      </button>
    </div>
  {/each}

  <button
    type="button"
    onmousedown={(e) => e.preventDefault()}
    onclick={() => {
      workbench.clearSearch();
      onFocusInput();
    }}
    title={workbench.t.searchBar.clearTitle}
    class="touch-target ml-1 rounded-md px-2 py-0.5 text-[11px] text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
  >
    {workbench.t.searchBar.clearAllSteps}
  </button>
</div>
