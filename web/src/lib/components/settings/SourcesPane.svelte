<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { filterSourcesForPicker } from '$lib/source-picker';
  import type { DataSourceEntry } from '$lib/types';
  import Switch from '../ui/Switch.svelte';
  import AddSourceForm from './AddSourceForm.svelte';
  import SourceTimeFormatEditor from './SourceTimeFormatEditor.svelte';
  import {
    AlertTriangle,
    Check,
    Clock,
    Container,
    FileText,
    Folder,
    Plus,
    Search,
    Trash2,
    X,
  } from 'lucide-svelte';

  const t = $derived(workbench.t.ui);

  // Two-step delete: first tap arms (icon turns into a check), second tap confirms.
  let armedId = $state<string | null>(null);
  let armTimer: ReturnType<typeof setTimeout> | null = null;
  let editingFormatId = $state<string | null>(null);
  let formatDraft = $state<string>('');
  let formatValid = $state<boolean>(true);
  let formatError = $state<string | null>(null);
  let savingFormat = $state<boolean>(false);
  let sourceFilter = $state<string>('');

  const displayedSources = $derived(
    sourceFilter.trim()
      ? filterSourcesForPicker(workbench.sources, 'all', sourceFilter)
      : workbench.sources
  );

  function resolveEffectiveTimeFormat(src: DataSourceEntry): string {
    if (src.config?.timeFormat !== undefined && src.config?.timeFormat !== null) {
      return src.config.timeFormat.trim();
    }
    return src.kind === 'docker' ? 'auto' : '';
  }

  function toggleEditFormat(src: DataSourceEntry) {
    if (editingFormatId === src.id) {
      editingFormatId = null;
      formatError = null;
      return;
    }
    editingFormatId = src.id;
    formatDraft = resolveEffectiveTimeFormat(src);
    formatValid = true;
    formatError = null;
  }

  async function saveSourceFormat(src: DataSourceEntry) {
    if (savingFormat || !formatValid) return;
    savingFormat = true;
    formatError = null;
    try {
      await workbench.upsertDirectorySource({
        id: src.id,
        kind: src.kind,
        name: src.name,
        path: src.path,
        config: src.config,
        enabled: src.enabled,
        timeFormat: formatDraft.trim(),
      });
      editingFormatId = null;
    } catch (err) {
      formatError = err instanceof Error ? err.message : t.addFailed;
    } finally {
      savingFormat = false;
    }
  }

  function onDelete(id: string) {
    if (armedId === id) {
      if (armTimer) clearTimeout(armTimer);
      armedId = null;
      if (editingFormatId === id) editingFormatId = null;
      void workbench.removeSource(id);
      return;
    }
    armedId = id;
    if (armTimer) clearTimeout(armTimer);
    armTimer = setTimeout(() => (armedId = null), 2500);
  }
</script>

<div class="space-y-3">
  <div class="flex h-9 items-center justify-between gap-2">
    <span
      class="shrink-0 font-mono text-[12px] tabular-nums text-muted-foreground"
      title={t.sourcesCount}
    >
      {workbench.enabledSourceCount}/{workbench.sources.length}
    </span>
    {#if workbench.sources.length > 4}
      <div class="relative min-w-0 flex-1 max-w-[260px]">
        <Search class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground/70" />
        <input
          type="text"
          bind:value={sourceFilter}
          placeholder={t.filterSourcesPlaceholder}
          spellcheck="false"
          autocomplete="off"
          class="h-8 w-full rounded-lg border border-border/70 bg-background pl-8 pr-7 text-xs text-foreground placeholder:text-muted-foreground/60 focus:border-foreground/40 focus:outline-none [@media(any-pointer:coarse)]:text-[16px]"
        />
        {#if sourceFilter}
          <button
            type="button"
            onclick={() => (sourceFilter = '')}
            title={workbench.t.searchBar.clearDraftTitle}
            aria-label={workbench.t.searchBar.clearDraftTitle}
            class="absolute right-1.5 top-1/2 flex h-5 w-5 -translate-y-1/2 items-center justify-center rounded text-muted-foreground hover:bg-secondary hover:text-foreground cursor-pointer"
          >
            <X class="h-3 w-3" />
          </button>
        {/if}
      </div>
    {/if}
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

  {#if workbench.sourcesLoaded && workbench.sources.length === 0 && !workbench.sourceAddOpen}
    <button
      type="button"
      onclick={() => (workbench.sourceAddOpen = true)}
      class="flex w-full flex-col items-center gap-2 rounded-xl border border-dashed border-border/70 py-10 text-muted-foreground hover:text-foreground cursor-pointer"
    >
      <Plus class="h-5 w-5" />
      <span class="text-xs">{t.noSources}</span>
    </button>
  {:else if workbench.sources.length > 0}
    {#if displayedSources.length === 0}
      <div class="py-8 text-center text-xs text-muted-foreground">
        {workbench.t.scopeBar.pickerNoMatch}
      </div>
    {:else}
      <div class="divide-y divide-border/40">
        {#each displayedSources as src (src.id)}
        {@const effectiveFormat = resolveEffectiveTimeFormat(src)}
        <div class="py-1.5">
          <div class={`flex min-h-12 items-center gap-3 ${src.enabled ? '' : 'opacity-60'}`}>
            <span
              class={`flex h-8 w-8 shrink-0 items-center justify-center ${
                src.exists ? 'text-muted-foreground' : 'text-status'
              }`}
              title={src.exists ? '' : src.kind === 'docker' ? t.missingDocker : t.missingPath}
            >
              {#if !src.exists}
                <AlertTriangle class="h-4 w-4" />
              {:else if src.kind === 'docker'}
                <Container class="h-4 w-4" />
              {:else if src.kind === 'file'}
                <FileText class="h-4 w-4" />
              {:else}
                <Folder class="h-4 w-4" />
              {/if}
            </span>

            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-1.5 min-w-0">
                <span class="truncate font-medium text-foreground/95">@{src.name}</span>
                {#if effectiveFormat}
                  <span
                    class="max-w-[140px] shrink-0 truncate rounded bg-primary/12 px-1.5 py-0.5 font-mono text-[10.5px] text-primary"
                    title={effectiveFormat === 'auto' ? t.sourceTimeAutoHint : effectiveFormat}
                  >
                    {effectiveFormat === 'auto' ? t.sourceBadgeAuto : effectiveFormat}
                  </span>
                {/if}
              </div>
              <div class="truncate font-mono text-[11.5px] text-muted-foreground" title={src.summary || src.path}>
                {src.summary || src.path}
              </div>
            </div>

            <button
              type="button"
              onclick={() => toggleEditFormat(src)}
              title={t.editTimeFormat}
              aria-label={t.editTimeFormat}
              aria-pressed={editingFormatId === src.id}
              class={`touch-target flex h-8 w-8 shrink-0 items-center justify-center rounded-lg transition-colors cursor-pointer ${
                editingFormatId === src.id
                  ? 'bg-secondary text-foreground'
                  : effectiveFormat
                    ? 'text-primary hover:bg-secondary'
                    : 'text-muted-foreground/70 hover:bg-secondary hover:text-foreground'
              }`}
            >
              <Clock class="h-4 w-4" />
            </button>

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

          {#if editingFormatId === src.id}
            <div class="mt-2 space-y-2 rounded-lg border border-border/60 bg-secondary/20 p-2.5">
              <SourceTimeFormatEditor
                value={formatDraft}
                onchange={(fmt, valid) => {
                  formatDraft = fmt;
                  formatValid = valid;
                  formatError = null;
                }}
                onsubmit={() => void saveSourceFormat(src)}
                oncancel={() => {
                  editingFormatId = null;
                  formatError = null;
                }}
              />
              {#if formatError}
                <div class="flex items-center gap-1.5 text-[11px] text-status">
                  <AlertTriangle class="h-3.5 w-3.5 shrink-0" />
                  <span class="truncate">{formatError}</span>
                </div>
              {/if}
              <div class="flex justify-end gap-1.5">
                <button
                  type="button"
                  onclick={() => {
                    editingFormatId = null;
                    formatError = null;
                  }}
                  class="touch-target rounded-md px-2.5 py-1 text-xs text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
                >
                  {t.cancel}
                </button>
                <button
                  type="button"
                  disabled={savingFormat || !formatValid}
                  onclick={() => saveSourceFormat(src)}
                  class="touch-target rounded-md bg-primary px-3 py-1 text-xs font-medium text-primary-foreground hover:opacity-90 disabled:opacity-40 transition-opacity cursor-pointer"
                >
                  {t.save}
                </button>
              </div>
            </div>
          {/if}
        </div>
      {/each}
      </div>
    {/if}
  {/if}
</div>
