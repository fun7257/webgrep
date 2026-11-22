<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import TimeRangePicker from './TimeRangePicker.svelte';
  import SourcePickerContent from './pickers/SourcePickerContent.svelte';
  import { Database, RotateCcw, Settings2 } from 'lucide-svelte';

  interface Props {
    onFocusMainInput?: () => void;
  }

  let { onFocusMainInput }: Props = $props();

  const s = $derived(workbench.t.scopeBar);
  const selectedCount = $derived(workbench.scope.sources.length);
  const excludedCount = $derived(workbench.scope.excludedSources?.length ?? 0);
  const hasSourceScope = $derived(selectedCount > 0 || excludedCount > 0);
  const sourceCountBadge = $derived.by(() => {
    if (selectedCount > 0 && excludedCount > 0) return `${selectedCount} / -${excludedCount}`;
    if (selectedCount > 0) return `${selectedCount}/${workbench.sources.length}`;
    if (excludedCount > 0) return `-${excludedCount}`;
    return String(workbench.enabledSourceCount);
  });
</script>

{#snippet sidebarSections(showClose: boolean)}
  <!-- Top Half: Time Range -->
  <section class="shrink-0 border-b border-border/50">
    <TimeRangePicker
      value={workbench.scope.timePreset}
      {showClose}
      onClose={() => workbench.closeMobileScope()}
      onApply={(spec) => workbench.setScopeTime(spec)}
      {onFocusMainInput}
    />
  </section>

  <!-- Bottom Half: Data Sources -->
  <section class="flex min-h-[220px] flex-1 flex-col">
    <div class="flex h-8 shrink-0 items-center justify-between gap-2 bg-card/30 px-2.5">
      <div class="flex min-w-0 items-center gap-1.5" title={s.sourcesSectionTitle}>
        <Database class={`h-3.5 w-3.5 shrink-0 ${hasSourceScope ? 'text-primary' : 'text-muted-foreground/75'}`} />
        <span
          class={`rounded px-1.5 py-0.5 font-mono text-[10.5px] leading-none tabular-nums ${
            hasSourceScope
              ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/30'
              : 'bg-secondary/65 text-muted-foreground'
          }`}
        >
          {sourceCountBadge}
        </span>
      </div>

      <div class="flex shrink-0 items-center gap-0.5">
        {#if hasSourceScope}
          <button
            type="button"
            onmousedown={(e) => e.preventDefault()}
            onclick={() => workbench.clearScopeSources()}
            title={s.resetToAll}
            aria-label={s.resetToAll}
            class="touch-target flex h-5 w-5 items-center justify-center rounded text-muted-foreground/75 hover:bg-secondary hover:text-foreground cursor-pointer"
          >
            <RotateCcw class="h-3 w-3" />
          </button>
        {/if}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={() => workbench.openSourcesDrawer(false)}
          title={workbench.t.header.sourcesTriggerTitle}
          aria-label={workbench.t.header.sourcesTriggerTitle}
          class="touch-target flex h-6 w-6 items-center justify-center rounded text-muted-foreground/75 hover:bg-secondary hover:text-foreground cursor-pointer"
        >
          <Settings2 class="h-3.5 w-3.5" />
        </button>
      </div>
    </div>

    <SourcePickerContent sidebar {onFocusMainInput} />
  </section>
{/snippet}

{#if workbench.isCompact}
  {#if workbench.mobileScopeOpen}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div
      class="fixed inset-0 z-40 bg-black/45"
      onclick={() => workbench.closeMobileScope()}
      onkeydown={(e) => {
        if (e.key === 'Escape') workbench.closeMobileScope();
      }}
    ></div>
    <aside
      aria-label={s.sidebarTitle}
      class="pt-safe pb-safe fixed inset-y-0 left-0 z-50 flex w-[min(86vw,300px)] flex-col overflow-y-auto border-r border-border bg-background shadow-2xl select-none"
    >
      {@render sidebarSections(true)}
    </aside>
  {/if}
{:else if workbench.leftSidebarOpen}
  <aside
    aria-label={s.sidebarTitle}
    class="flex h-full w-[276px] xl:w-[292px] shrink-0 flex-col overflow-y-auto md:overflow-hidden border-r border-border/50 bg-card/15 select-none"
  >
    {@render sidebarSections(false)}
  </aside>
{/if}
