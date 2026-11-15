<script lang="ts">
  import { untrack } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import type { DataSourceItem } from '$lib/types';
  import {
    countSourcesByKind,
    filterSourcesForPicker,
    isSourceRefInList,
    toggleExcludeSourceSelection,
    toggleMultiSourceSelection,
    type SourceKindFilter,
  } from '$lib/source-picker';
  import {
    AlertTriangle,
    Check,
    Container,
    Database,
    FileText,
    Folder,
    Minus,
    Search,
    SlidersHorizontal,
    X,
  } from 'lucide-svelte';

  let searchQuery = $state<string>('');
  let kindFilter = $state<SourceKindFilter>('all');
  let draftSources = $state<string[]>([]);
  let draftExcluded = $state<string[]>([]);
  let multiMode = $state<boolean>(false);
  let focusedIdx = $state<number>(0);
  let searchInputEl = $state<HTMLInputElement | null>(null);
  let dialogEl = $state<HTMLDivElement | null>(null);

  // Mobile bottom sheet drag-to-dismiss state (matches SettingsPopover gesture)
  let dragY = $state<number>(0);
  let dragStart: number | null = null;
  let wasOpen = false;

  const s = $derived(workbench.t.scopeBar);
  const ui = $derived(workbench.t.ui);

  const counts = $derived(countSourcesByKind(workbench.sources));
  const filteredSources = $derived(
    filterSourcesForPicker(workbench.sources, kindFilter, searchQuery)
  );

  const kindTabs = $derived.by(() => {
    const out: { id: SourceKindFilter; label: string; count: number }[] = [
      { id: 'all', label: s.kindAll, count: counts.all },
    ];
    if (counts.dir > 0 || kindFilter === 'dir') {
      out.push({ id: 'dir', label: s.kindDir, count: counts.dir });
    }
    if (counts.file > 0 || kindFilter === 'file') {
      out.push({ id: 'file', label: s.kindFile, count: counts.file });
    }
    if (counts.docker > 0 || kindFilter === 'docker') {
      out.push({ id: 'docker', label: s.kindDocker, count: counts.docker });
    }
    return out;
  });

  const hasCurrentScope = $derived(
    workbench.scope.sources.length > 0 || (workbench.scope.excludedSources?.length ?? 0) > 0
  );
  const hasDraftScope = $derived(draftSources.length > 0 || draftExcluded.length > 0);

  $effect(() => {
    const open = workbench.sourcePickerOpen;
    if (open && !wasOpen) {
      wasOpen = true;
      untrack(() => {
        draftSources = [...workbench.scope.sources];
        draftExcluded = [...(workbench.scope.excludedSources ?? [])];
        multiMode =
          workbench.scope.sources.length > 1 ||
          (workbench.scope.excludedSources?.length ?? 0) > 0;
        searchQuery = '';
        kindFilter = 'all';
        focusedIdx = 0;
        dragY = 0;
        dragStart = null;
        if (!workbench.isCompact && !workbench.isTouch) {
          queueMicrotask(() => searchInputEl?.focus());
        } else {
          queueMicrotask(() => dialogEl?.focus({ preventScroll: true }));
        }
      });
    } else if (!open && wasOpen) {
      wasOpen = false;
    }
  });

  $effect(() => {
    if (focusedIdx >= filteredSources.length) {
      focusedIdx = Math.max(0, filteredSources.length - 1);
    }
  });

  function close() {
    workbench.closeSourcePicker();
  }

  function toggleDraftInclude(id: string) {
    const next = toggleMultiSourceSelection(
      { sources: draftSources, excludedSources: draftExcluded },
      id
    );
    draftSources = next.sources;
    draftExcluded = next.excludedSources;
  }

  function toggleDraftExclude(id: string) {
    const next = toggleExcludeSourceSelection(
      { sources: draftSources, excludedSources: draftExcluded },
      id
    );
    draftSources = next.sources;
    draftExcluded = next.excludedSources;
  }

  function soloSource(id: string) {
    workbench.setScopeSources([id], []);
    close();
  }

  function selectAllFiltered() {
    if (filteredSources.length === 0) return;
    const filteredIds = new Set(filteredSources.map((x) => x.id));
    const merged = new Set(draftSources);
    for (const item of filteredSources) {
      merged.add(item.id);
    }
    draftSources = Array.from(merged);
    draftExcluded = draftExcluded.filter((x) => !filteredIds.has(x));
  }

  function clearDraftSelection() {
    draftSources = [];
    draftExcluded = [];
  }

  function applyAndClose() {
    workbench.setScopeSources(draftSources, draftExcluded);
    close();
  }

  function searchAllAndClose() {
    workbench.clearScopeSources();
    close();
  }

  function sourceSubtitle(src: DataSourceItem): string {
    return src.summary || src.config?.endpoint || src.path;
  }

  function toggleCheckbox(id: string) {
    multiMode = true;
    toggleDraftInclude(id);
  }

  function handleCardClick(e: MouseEvent, id: string) {
    if (e.altKey) {
      multiMode = true;
      toggleDraftExclude(id);
      return;
    }
    if (multiMode || e.metaKey || e.ctrlKey || e.shiftKey) {
      multiMode = true;
      toggleDraftInclude(id);
      return;
    }
    soloSource(id);
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      close();
      return;
    }
    if (e.key === 'ArrowDown') {
      if (filteredSources.length > 0) {
        e.preventDefault();
        focusedIdx = (focusedIdx + 1) % filteredSources.length;
      }
      return;
    }
    if (e.key === 'ArrowUp') {
      if (filteredSources.length > 0) {
        e.preventDefault();
        focusedIdx = (focusedIdx - 1 + filteredSources.length) % filteredSources.length;
      }
      return;
    }
    if (e.key === 'Enter') {
      if (e.target !== searchInputEl && e.target !== dialogEl) return;
      e.preventDefault();
      if (e.metaKey || e.ctrlKey || multiMode) {
        applyAndClose();
      } else if (filteredSources[focusedIdx]) {
        soloSource(filteredSources[focusedIdx].id);
      } else {
        applyAndClose();
      }
    }
  }

  function onHandleDown(e: PointerEvent) {
    dragStart = e.clientY;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }

  function onHandleMove(e: PointerEvent) {
    if (dragStart === null) return;
    dragY = Math.max(0, e.clientY - dragStart);
  }

  function onHandleUp() {
    if (dragStart === null) return;
    const shouldClose = dragY > 96;
    dragStart = null;
    dragY = 0;
    if (shouldClose) close();
  }
</script>

{#if workbench.sourcePickerOpen}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    onclick={close}
    onkeydown={(e) => {
      if (e.key === 'Escape') close();
    }}
    class="fixed inset-0 z-50 flex items-end md:items-center justify-center bg-black/60 backdrop-blur-xs p-0 md:p-4 select-none"
  >
    <div
      bind:this={dialogEl}
      role="dialog"
      tabindex="-1"
      aria-modal="true"
      aria-label={s.pickerTitle}
      onclick={(e) => e.stopPropagation()}
      onkeydown={handleKeydown}
      style={dragY > 0 ? `transform: translate3d(0, ${dragY}px, 0); transition: none` : undefined}
      class="pb-safe flex max-h-[86dvh] md:max-h-[80dvh] w-full max-w-[640px] flex-col overflow-hidden rounded-t-2xl md:rounded-2xl border border-border/80 bg-card shadow-2xl transition-transform focus:outline-none"
    >
      <!-- Mobile drag handle -->
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        onpointerdown={onHandleDown}
        onpointermove={onHandleMove}
        onpointerup={onHandleUp}
        onpointercancel={onHandleUp}
        style="touch-action: none"
        class="flex h-5 shrink-0 cursor-grab items-center justify-center md:hidden"
      >
        <span class="h-1 w-9 rounded-full bg-border"></span>
      </div>

      <!-- Top Search Bar -->
      <div class="flex h-12 shrink-0 items-center gap-2 border-b border-border/60 px-4">
        <Search class="h-4 w-4 shrink-0 text-muted-foreground" />
        <input
          bind:this={searchInputEl}
          type="text"
          bind:value={searchQuery}
          oninput={() => (focusedIdx = 0)}
          placeholder={s.pickerSearchPlaceholder}
          spellcheck="false"
          autocomplete="off"
          class="h-full min-w-0 flex-1 bg-transparent text-[13.5px] text-foreground placeholder:text-muted-foreground/65 focus:outline-none [@media(any-pointer:coarse)]:text-[16px]"
        />
        {#if searchQuery.length > 0}
          <button
            type="button"
            onclick={() => {
              searchQuery = '';
              focusedIdx = 0;
              if (!workbench.isCompact && !workbench.isTouch) searchInputEl?.focus();
            }}
            title={workbench.t.searchBar.clearDraftTitle}
            aria-label={workbench.t.searchBar.clearDraftTitle}
            class="touch-target flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
          >
            <X class="h-3.5 w-3.5" />
          </button>
        {/if}
        <button
          type="button"
          onclick={close}
          title={workbench.t.settings.closeTitle}
          aria-label={workbench.t.settings.closeTitle}
          class="touch-target flex h-8 w-8 shrink-0 items-center justify-center rounded-lg text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
        >
          <X class="h-4 w-4" />
        </button>
      </div>

      <!-- Kind Filter Tabs + Batch Actions -->
      <div class="flex shrink-0 flex-wrap items-center justify-between gap-2 border-b border-border/50 bg-secondary/15 px-3 py-2 md:px-4">
        <div class="flex flex-wrap items-center gap-1">
          {#each kindTabs as tab (tab.id)}
            {@const active = kindFilter === tab.id}
            <button
              type="button"
              onclick={() => {
                kindFilter = tab.id;
                focusedIdx = 0;
              }}
              class={`touch-target inline-flex h-7 items-center gap-1 rounded-full border px-2.5 text-[11.5px] transition-colors cursor-pointer ${
                active
                  ? 'border-primary/35 bg-primary/15 text-primary font-medium'
                  : 'border-border/60 bg-background/60 text-muted-foreground hover:bg-secondary hover:text-foreground'
              }`}
            >
              <span>{tab.label}</span>
              <span class="font-mono text-[10.5px] opacity-75 tabular-nums">{tab.count}</span>
            </button>
          {/each}
        </div>

        <div class="flex items-center gap-1.5">
          {#if filteredSources.length > 0}
            <button
              type="button"
              onclick={() => (multiMode = !multiMode)}
              aria-pressed={multiMode}
              class={`touch-target inline-flex h-7 items-center gap-1.5 rounded-full border px-2.5 text-[11.5px] transition-colors cursor-pointer ${
                multiMode
                  ? 'border-primary/35 bg-primary/15 text-primary font-medium'
                  : 'border-border/60 bg-background/60 text-muted-foreground hover:bg-secondary hover:text-foreground'
              }`}
            >
              <span
                class={`flex h-3 w-3 items-center justify-center rounded-[3px] border ${
                  multiMode ? 'border-primary bg-primary text-primary-foreground' : 'border-border'
                }`}
              >
                {#if multiMode}
                  <Check class="h-2.5 w-2.5" />
                {/if}
              </span>
              <span>{s.multiModeBtn}</span>
            </button>
          {/if}
          {#if multiMode && filteredSources.length > 0}
            <button
              type="button"
              onclick={selectAllFiltered}
              class="touch-target rounded-md px-2 py-1 text-[11.5px] text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
            >
              {s.selectFiltered}
            </button>
          {/if}
          {#if hasDraftScope}
            <button
              type="button"
              onclick={clearDraftSelection}
              class="touch-target rounded-md px-2 py-1 text-[11.5px] text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
            >
              {s.clearSelection}
            </button>
          {/if}
        </div>
      </div>

      <!-- Responsive Multi-Column Source Grid -->
      <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain p-3 md:p-4">
        {#if filteredSources.length === 0}
          <div class="flex h-40 flex-col items-center justify-center gap-2 text-center text-xs text-muted-foreground">
            <span>{workbench.sources.length === 0 ? s.noSourcesHint : s.pickerNoMatch}</span>
            {#if workbench.sources.length === 0}
              <button
                type="button"
                onclick={() => workbench.openSettings('add-source')}
                class="touch-target rounded-lg border border-border bg-secondary/50 px-3 py-1.5 text-xs font-medium text-foreground hover:bg-secondary transition-colors cursor-pointer"
              >
                + {s.addSourcePill}
              </button>
            {/if}
          </div>
        {:else}
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
            {#if !searchQuery.trim() && kindFilter === 'all'}
              <button
                type="button"
                onclick={searchAllAndClose}
                class={`col-span-full flex items-center justify-between gap-2.5 rounded-xl border px-3 py-2 text-left transition-colors cursor-pointer ${
                  !hasDraftScope
                    ? 'border-primary/45 bg-primary/10'
                    : 'border-border/70 bg-background/50 hover:bg-secondary/35'
                }`}
              >
                <span class="flex min-w-0 items-center gap-2.5">
                  <span
                    class={`flex h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-secondary/65 ${
                      !hasDraftScope ? 'text-primary' : 'text-muted-foreground'
                    }`}
                  >
                    <Database class="h-3.5 w-3.5" />
                  </span>
                  <span class="min-w-0">
                    <span class="block text-xs font-medium text-foreground">{s.allSources}</span>
                    <span class="block truncate text-[11px] text-muted-foreground/80">
                      {s.allSourcesSub}
                    </span>
                  </span>
                </span>
                {#if !hasDraftScope}
                  <Check class="h-4 w-4 shrink-0 text-primary" />
                {/if}
              </button>
            {/if}

            {#each filteredSources as src, idx (src.id)}
              {@const checked = isSourceRefInList(src, draftSources)}
              {@const excluded = isSourceRefInList(src, draftExcluded)}
              {@const isKeyboardFocused = idx === focusedIdx && !workbench.isTouch}
              {@const sub = sourceSubtitle(src)}
              <div
                onmouseenter={() => (focusedIdx = idx)}
                class={`flex items-center gap-1 rounded-xl border pl-1.5 transition-colors ${
                  checked
                    ? 'border-primary/45 bg-primary/10'
                    : excluded
                      ? 'border-status/40 bg-status/10'
                      : isKeyboardFocused
                        ? 'border-foreground/30 bg-secondary/45'
                        : 'border-border/70 bg-background/50 hover:bg-secondary/35'
                } ${!src.enabled && !checked ? 'opacity-70' : ''}`}
              >
                <!-- Independent checkbox: clicking immediately enters multi-select & toggles source -->
                <button
                  type="button"
                  onclick={() => toggleCheckbox(src.id)}
                  aria-label={src.name}
                  aria-pressed={checked}
                  class="touch-target flex h-8 w-8 shrink-0 items-center justify-center rounded-lg hover:bg-secondary/60 transition-colors cursor-pointer"
                >
                  <span
                    class={`flex h-4 w-4 items-center justify-center rounded border transition-colors ${
                      checked
                        ? 'border-primary bg-primary text-primary-foreground'
                        : excluded
                          ? 'border-status bg-status text-background'
                          : multiMode
                            ? 'border-border bg-background'
                            : 'border-border/60 bg-background/60'
                    }`}
                  >
                    {#if checked}
                      <Check class="h-3 w-3" />
                    {:else if excluded}
                      <Minus class="h-3 w-3" />
                    {/if}
                  </span>
                </button>

                <!-- Card body: single-click picks directly & closes (unless multi-select mode) -->
                <button
                  type="button"
                  onclick={(e) => handleCardClick(e, src.id)}
                  title={multiMode ? undefined : s.cardClickTitle(src.name)}
                  class="flex min-w-0 flex-1 items-center gap-2.5 py-2.5 pr-1 text-left cursor-pointer"
                >
                  <span
                    class={`flex h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-secondary/65 ${
                      !src.exists
                        ? 'text-status'
                        : checked
                          ? 'text-primary'
                          : 'text-muted-foreground'
                    }`}
                    title={!src.exists ? (src.kind === 'docker' ? ui.missingDocker : ui.missingPath) : undefined}
                  >
                    {#if !src.exists}
                      <AlertTriangle class="h-3.5 w-3.5" />
                    {:else if src.kind === 'docker'}
                      <Container class="h-3.5 w-3.5" />
                    {:else if src.kind === 'file'}
                      <FileText class="h-3.5 w-3.5" />
                    {:else}
                      <Folder class="h-3.5 w-3.5" />
                    {/if}
                  </span>

                  <span class="min-w-0 flex-1">
                    <span class="flex items-center gap-1.5 min-w-0">
                      <span class="truncate font-mono text-xs font-medium text-foreground">
                        {src.name}
                      </span>
                      {#if !src.enabled}
                        <span class="shrink-0 rounded bg-secondary px-1 py-0.5 text-[10px] text-muted-foreground">
                          {ui.disabled}
                        </span>
                      {/if}
                    </span>
                    <span class="block truncate font-mono text-[11px] text-muted-foreground/80" title={sub}>
                      {sub}
                    </span>
                  </span>
                </button>

                <!-- Quick Only + Exclude buttons (multi-select mode only, keeps single-pick cards clean) -->
                {#if multiMode || excluded}
                <div class="flex shrink-0 items-center gap-1 pr-2">
                  {#if multiMode}
                    <button
                      type="button"
                      onclick={() => soloSource(src.id)}
                      title={s.soloTitle(src.name)}
                      class="touch-target inline-flex h-7 items-center rounded-md border border-border/70 bg-background/80 px-2 text-[11px] font-medium text-foreground/85 hover:border-primary/40 hover:bg-primary/10 hover:text-primary transition-colors cursor-pointer"
                    >
                      {s.soloBtn}
                    </button>
                  {/if}
                  <button
                    type="button"
                    onclick={() => {
                      multiMode = true;
                      toggleDraftExclude(src.id);
                    }}
                    title={s.excludeTitle(src.name)}
                    aria-label={s.excludeTitle(src.name)}
                    aria-pressed={excluded}
                    class={`touch-target flex h-7 w-7 items-center justify-center rounded-md border transition-colors cursor-pointer ${
                      excluded
                        ? 'border-status/50 bg-status/15 text-status'
                        : 'border-border/70 bg-background/80 text-muted-foreground hover:border-status/40 hover:bg-status/10 hover:text-status'
                    }`}
                  >
                    <Minus class="h-3.5 w-3.5" />
                  </button>
                </div>
                {/if}
              </div>
            {/each}
          </div>
        {/if}
      </div>

      <!-- Sticky Footer Bar -->
      <div class="flex shrink-0 items-center justify-between gap-2 border-t border-border/60 bg-card px-4 py-2.5">
        <button
          type="button"
          onclick={() => workbench.openSettings('sources')}
          class="touch-target inline-flex h-8 items-center gap-1.5 rounded-lg px-2 text-xs text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
        >
          <SlidersHorizontal class="h-3.5 w-3.5 shrink-0" />
          <span>{s.manageSources}</span>
        </button>

        {#if multiMode}
          <div class="flex items-center gap-2">
            <span class="hidden sm:inline font-mono text-[11px] text-muted-foreground">
              {hasDraftScope
                ? s.pickerSummaryCustom(draftSources.length, draftExcluded.length)
                : s.pickerSummaryAll}
            </span>
            {#if hasCurrentScope || hasDraftScope}
              <button
                type="button"
                onclick={searchAllAndClose}
                class="touch-target inline-flex h-8 items-center rounded-lg border border-border/70 bg-secondary/40 px-2.5 text-xs text-foreground hover:bg-secondary transition-colors cursor-pointer"
              >
                {s.searchAllBtn}
              </button>
            {/if}
            <button
              type="button"
              onclick={applyAndClose}
              class="touch-target inline-flex h-8 items-center rounded-lg bg-primary px-3.5 text-xs font-medium text-primary-foreground hover:opacity-90 transition-opacity cursor-pointer"
            >
              {s.applySelection}
            </button>
          </div>
        {:else}
          <span class="truncate text-[11px] text-muted-foreground/75">{s.singleModeHint}</span>
        {/if}
      </div>
    </div>
  </div>
{/if}
