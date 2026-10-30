<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import Switch from '../ui/Switch.svelte';
  import AddSourceForm from './AddSourceForm.svelte';
  import { AlertTriangle, Check, FileText, Folder, Plus, Trash2 } from 'lucide-svelte';

  const t = $derived(workbench.t.ui);

  // Two-step delete: first tap arms (icon turns into a check), second tap confirms.
  let armedId = $state<string | null>(null);
  let armTimer: ReturnType<typeof setTimeout> | null = null;

  function onDelete(id: string) {
    if (armedId === id) {
      if (armTimer) clearTimeout(armTimer);
      armedId = null;
      void workbench.removeSource(id);
      return;
    }
    armedId = id;
    if (armTimer) clearTimeout(armTimer);
    armTimer = setTimeout(() => (armedId = null), 2500);
  }
</script>

<div class="space-y-3">
  <div class="flex h-9 items-center justify-between">
    <span
      class="font-mono text-[12px] tabular-nums text-muted-foreground"
      title={t.sourcesCount}
    >
      {workbench.enabledSourceCount}/{workbench.sources.length}
    </span>
    <button
      type="button"
      onclick={() => (workbench.sourceAddOpen = !workbench.sourceAddOpen)}
      title={t.addSource}
      aria-label={t.addSource}
      aria-pressed={workbench.sourceAddOpen}
      class={`touch-target flex h-8 w-8 items-center justify-center rounded-lg transition-colors cursor-pointer ${
        workbench.sourceAddOpen
          ? 'bg-secondary text-foreground'
          : 'text-muted-foreground hover:bg-secondary/60 hover:text-foreground'
      }`}
    >
      <Plus class={`h-4 w-4 transition-transform ${workbench.sourceAddOpen ? 'rotate-45' : ''}`} />
    </button>
  </div>

  {#if workbench.sourceAddOpen}
    <AddSourceForm ondone={() => (workbench.sourceAddOpen = false)} />
  {/if}

  {#if workbench.sources.length === 0 && !workbench.sourceAddOpen}
    <button
      type="button"
      onclick={() => (workbench.sourceAddOpen = true)}
      class="flex w-full flex-col items-center gap-2 rounded-xl border border-dashed border-border/70 py-10 text-muted-foreground hover:text-foreground cursor-pointer"
    >
      <Plus class="h-5 w-5" />
      <span class="text-xs">{t.noSources}</span>
    </button>
  {:else}
    <div class="divide-y divide-border/40">
      {#each workbench.sources as src (src.id)}
        <div class={`flex min-h-14 items-center gap-3 py-1.5 ${src.enabled ? '' : 'opacity-60'}`}>
          <span
            class={`flex h-8 w-8 shrink-0 items-center justify-center ${
              src.exists ? 'text-muted-foreground' : 'text-status'
            }`}
            title={src.exists ? '' : t.missingPath}
          >
            {#if !src.exists}
              <AlertTriangle class="h-4 w-4" />
            {:else if src.kind === 'file'}
              <FileText class="h-4 w-4" />
            {:else}
              <Folder class="h-4 w-4" />
            {/if}
          </span>

          <div class="min-w-0 flex-1">
            <div class="truncate font-medium text-foreground/95">{src.name}</div>
            <div class="truncate font-mono text-[11.5px] text-muted-foreground" title={src.path}>
              {src.path}
            </div>
          </div>

          <Switch
            checked={src.enabled}
            title={src.enabled ? t.enabled : t.disabled}
            onchange={() => workbench.toggleSourceEnabled(src.id)}
          />
          <button
            type="button"
            onclick={() => onDelete(src.id)}
            title={armedId === src.id ? t.confirmDelete : t.delete}
            aria-label={armedId === src.id ? t.confirmDelete : t.delete}
            class={`touch-target flex h-8 w-8 shrink-0 items-center justify-center rounded-lg transition-colors cursor-pointer ${
              armedId === src.id
                ? 'bg-status/15 text-status'
                : 'text-muted-foreground/65 hover:bg-secondary hover:text-foreground'
            }`}
          >
            {#if armedId === src.id}
              <Check class="h-4 w-4" />
            {:else}
              <Trash2 class="h-4 w-4" />
            {/if}
          </button>
        </div>
      {/each}
    </div>
  {/if}
</div>
