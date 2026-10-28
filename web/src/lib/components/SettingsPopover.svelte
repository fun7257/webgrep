<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import type { DirSuggestEntry } from '$lib/types';
  import NumberStepper from './ui/NumberStepper.svelte';
  import Switch from './ui/Switch.svelte';
  import {
    AlertTriangle,
    FileText,
    Folder,
    FolderGit2,
    FolderOpen,
    FolderPlus,
    Loader2,
    Plus,
    RotateCcw,
    SlidersHorizontal,
    Trash2,
    X,
  } from 'lucide-svelte';

  type SettingsTabId = 'general' | 'sources' | 'add-source';

  // Add Source form state
  let kindInput = $state<'dir' | 'file'>('dir');
  let pathInput = $state('');
  let nameInput = $state('');
  let submitting = $state(false);
  let submitError = $state<string | null>(null);

  let dirSuggestions = $state.raw<DirSuggestEntry[]>([]);
  let showDirSuggest = $state(false);
  let selectedDirIdx = $state(0);
  let dirSuggestTimer: ReturnType<typeof setTimeout> | null = null;
  let pathInputEl = $state<HTMLInputElement | null>(null);

  let derivedDefaultName = $derived.by(() => {
    const clean = pathInput.trim().replace(/\/+$/, '');
    if (!clean) return '';
    const parts = clean.split('/');
    return parts[parts.length - 1] || '';
  });

  function updateSearchSetting(fn: () => void) {
    fn();
    workbench.saveSettings();
    if (workbench.pattern.trim().length > 0) {
      workbench.scheduleSearch(true);
    }
  }

  function updateDisplaySetting(fn: () => void) {
    fn();
    workbench.saveSettings();
  }

  function closeModal() {
    workbench.settingsOpen = false;
    showDirSuggest = false;
    submitError = null;
  }

  function switchTab(tab: SettingsTabId) {
    workbench.settingsTab = tab;
    showDirSuggest = false;
    submitError = null;
  }

  function selectKind(nextKind: 'dir' | 'file') {
    if (kindInput === nextKind) return;
    kindInput = nextKind;
    submitError = null;
    triggerPathAutocomplete(pathInput);
    requestAnimationFrame(() => pathInputEl?.focus());
  }

  function triggerPathAutocomplete(val: string) {
    if (dirSuggestTimer) clearTimeout(dirSuggestTimer);
    dirSuggestTimer = setTimeout(async () => {
      const list = await workbench.fetchDirSuggestions(val, kindInput);
      dirSuggestions = list;
      selectedDirIdx = 0;
      showDirSuggest = list.length > 0;
    }, 60);
  }

  function applySuggestion(entry: DirSuggestEntry, drillDown = false) {
    const isDirectory = entry.isDir !== false;
    const shouldDrillDown = isDirectory && (drillDown || kindInput === 'file');
    const nextPath = shouldDrillDown
      ? entry.path.endsWith('/')
        ? entry.path
        : `${entry.path}/`
      : entry.path;

    pathInput = nextPath;

    if (shouldDrillDown) {
      triggerPathAutocomplete(nextPath);
      requestAnimationFrame(() => pathInputEl?.focus());
    } else {
      showDirSuggest = false;
    }
  }

  function handlePathKeydown(e: KeyboardEvent) {
    if (showDirSuggest && dirSuggestions.length > 0) {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        selectedDirIdx = (selectedDirIdx + 1) % dirSuggestions.length;
        return;
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        selectedDirIdx =
          (selectedDirIdx - 1 + dirSuggestions.length) % dirSuggestions.length;
        return;
      }
      if (e.key === 'Tab') {
        e.preventDefault();
        const chosen = dirSuggestions[selectedDirIdx] ?? dirSuggestions[0];
        if (chosen) {
          applySuggestion(chosen, true);
        }
        return;
      }
      if (e.key === 'Enter') {
        const chosen = dirSuggestions[selectedDirIdx];
        const currentVal = pathInput.trim();
        if (chosen && chosen.path !== currentVal) {
          e.preventDefault();
          applySuggestion(chosen, false);
          return;
        }
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        showDirSuggest = false;
        return;
      }
    }

    if (e.key === 'Enter') {
      e.preventDefault();
      void handleAddSourceSubmit();
    }
  }

  async function handleAddSourceSubmit() {
    const cleanPath = pathInput.trim();
    if (!cleanPath) {
      submitError =
        kindInput === 'file' ? '请输入服务端单文件路径' : '请输入服务端目录路径';
      return;
    }
    const finalName = (nameInput.trim() || derivedDefaultName || 'project').trim();

    submitting = true;
    submitError = null;
    try {
      await workbench.upsertDirectorySource({
        kind: kindInput,
        name: finalName,
        path: cleanPath,
        config: { path: cleanPath },
        enabled: true,
      });
      pathInput = '';
      nameInput = '';
      showDirSuggest = false;
      workbench.settingsTab = 'sources';
    } catch (err) {
      submitError = err instanceof Error ? err.message : '添加失败';
    } finally {
      submitting = false;
    }
  }
</script>

{#if workbench.settingsOpen}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    onclick={closeModal}
    onkeydown={(e) => {
      if (e.key === 'Escape') closeModal();
    }}
    class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-xs p-4 select-none"
  >
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div
      onclick={(e) => {
        e.stopPropagation();
        showDirSuggest = false;
      }}
      class="flex h-[520px] max-h-[calc(100vh-2rem)] w-full max-w-[680px] overflow-hidden rounded-2xl border border-border/80 bg-card shadow-2xl"
    >
      <!-- Left Sidebar Navigation (macOS System Settings Style) -->
      <aside class="flex w-[188px] shrink-0 flex-col border-r border-border/60 bg-secondary/20 p-3">
        <div class="px-2.5 pb-2.5 pt-1 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground/70">
          {workbench.locale === 'zh' ? '系统设置' : 'Settings'}
        </div>

        <nav class="flex flex-col gap-1 text-[13px]">
          <button
            type="button"
            onclick={() => switchTab('general')}
            class={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors cursor-pointer ${
              workbench.settingsTab === 'general'
                ? 'bg-secondary font-medium text-foreground shadow-2xs'
                : 'text-muted-foreground hover:bg-secondary/50 hover:text-foreground'
            }`}
          >
            <SlidersHorizontal class="h-4 w-4 shrink-0" />
            <span class="truncate">{workbench.locale === 'zh' ? '通用与检索' : 'General'}</span>
          </button>

          <button
            type="button"
            onclick={() => switchTab('sources')}
            class={`flex w-full items-center justify-between gap-2 rounded-lg px-2.5 py-2 text-left transition-colors cursor-pointer ${
              workbench.settingsTab === 'sources'
                ? 'bg-secondary font-medium text-foreground shadow-2xs'
                : 'text-muted-foreground hover:bg-secondary/50 hover:text-foreground'
            }`}
          >
            <div class="flex items-center gap-2.5 min-w-0">
              <FolderGit2 class="h-4 w-4 shrink-0" />
              <span class="truncate">{workbench.locale === 'zh' ? '数据源' : 'Sources'}</span>
            </div>
            {#if workbench.sources.length > 0}
              <span class="font-mono text-[11px] text-muted-foreground">
                {workbench.enabledSourceCount}/{workbench.sources.length}
              </span>
            {/if}
          </button>

          <button
            type="button"
            onclick={() => switchTab('add-source')}
            class={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors cursor-pointer ${
              workbench.settingsTab === 'add-source'
                ? 'bg-secondary font-medium text-foreground shadow-2xs'
                : 'text-muted-foreground hover:bg-secondary/50 hover:text-foreground'
            }`}
          >
            <FolderPlus class="h-4 w-4 shrink-0" />
            <span class="truncate">{workbench.locale === 'zh' ? '添加数据源' : 'Add Source'}</span>
          </button>
        </nav>
      </aside>

      <!-- Right Content Area -->
      <section class="flex flex-1 flex-col min-w-0 bg-card">
        <!-- Content Header -->
        <div class="flex h-12 shrink-0 items-center justify-between border-b border-border/50 px-6">
          <div class="text-[14px] font-semibold text-foreground">
            {#if workbench.settingsTab === 'general'}
              {workbench.locale === 'zh' ? '通用与检索' : 'General & Search'}
            {:else if workbench.settingsTab === 'sources'}
              {workbench.locale === 'zh' ? '数据源' : 'Data Sources'}
            {:else}
              {workbench.locale === 'zh' ? '添加数据源' : 'Add Data Source'}
            {/if}
          </div>

          <div class="flex items-center gap-1.5">
            {#if workbench.settingsTab === 'general'}
              <button
                type="button"
                title={workbench.t.settings.resetTitle}
                onclick={() => workbench.resetSettings()}
                class="flex items-center gap-1 rounded-lg px-2 py-1 text-xs font-medium text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
              >
                <RotateCcw class="h-3 w-3" />
                <span>{workbench.t.settings.reset}</span>
              </button>
            {/if}

            <button
              type="button"
              title={workbench.t.settings.closeTitle}
              onclick={closeModal}
              class="rounded-lg p-1 text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
            >
              <X class="h-4 w-4" />
            </button>
          </div>
        </div>

        <!-- Scrollable Pane Body -->
        <div class="flex-1 overflow-y-auto px-6 py-5 text-[13px]">
          {#if workbench.settingsTab === 'general'}
            <div class="space-y-5">
              <!-- Group 1: Interface & Appearance -->
              <div class="space-y-3.5">
                <div class="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
                  {workbench.t.settings.sectionAppearance}
                </div>

                <!-- Language Switch (Moved from Header) -->
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-foreground/95 font-medium">
                      {workbench.locale === 'zh' ? '界面语言' : 'Language'}
                    </div>
                    <div class="text-[11.5px] text-muted-foreground">
                      {workbench.locale === 'zh' ? '切换界面显示语言' : 'Switch display language'}
                    </div>
                  </div>
                  <div class="inline-flex h-8 items-center rounded-lg border border-border/80 bg-background/90 p-0.5 text-xs">
                    <button
                      type="button"
                      onclick={() =>
                        updateDisplaySetting(() => {
                          workbench.locale = 'zh';
                        })}
                      class={`h-6 rounded-md px-2.5 transition-colors cursor-pointer ${
                        workbench.locale === 'zh'
                          ? 'bg-primary text-primary-foreground font-semibold shadow-2xs'
                          : 'text-muted-foreground hover:text-foreground'
                      }`}
                    >
                      中文
                    </button>
                    <button
                      type="button"
                      onclick={() =>
                        updateDisplaySetting(() => {
                          workbench.locale = 'en';
                        })}
                      class={`h-6 rounded-md px-2.5 transition-colors cursor-pointer ${
                        workbench.locale === 'en'
                          ? 'bg-primary text-primary-foreground font-semibold shadow-2xs'
                          : 'text-muted-foreground hover:text-foreground'
                      }`}
                    >
                      English
                    </button>
                  </div>
                </div>

                <!-- Code Font Size -->
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-foreground/95 font-medium">{workbench.t.settings.fontSizeLabel}</div>
                    <div class="text-[11.5px] text-muted-foreground">{workbench.t.settings.fontSizeDesc}</div>
                  </div>
                  <NumberStepper
                    value={workbench.codeFontSize}
                    min={10}
                    max={28}
                    step={0.5}
                    suffix="px"
                    widthClass="w-11"
                    onchange={(v) =>
                      updateDisplaySetting(() => {
                        workbench.codeFontSize = v;
                      })}
                  />
                </div>

                <!-- Line Wrap -->
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-foreground/95 font-medium">{workbench.t.settings.wordWrapLabel}</div>
                    <div class="text-[11.5px] text-muted-foreground">{workbench.t.settings.wordWrapDesc}</div>
                  </div>
                  <Switch
                    checked={workbench.wordWrap}
                    title={workbench.t.settings.wordWrapLabel}
                    onchange={(next) =>
                      updateDisplaySetting(() => {
                        workbench.wordWrap = next;
                      })}
                  />
                </div>

                <!-- Row Density -->
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-foreground/95 font-medium">{workbench.t.settings.densityLabel}</div>
                    <div class="text-[11.5px] text-muted-foreground">{workbench.t.settings.densityDesc}</div>
                  </div>
                  <div class="inline-flex h-8 items-center rounded-lg border border-border/80 bg-background/90 p-0.5 text-xs">
                    <button
                      type="button"
                      onclick={() =>
                        updateDisplaySetting(() => {
                          workbench.resultDensity = 'compact';
                        })}
                      class={`h-6 rounded-md px-2.5 transition-colors cursor-pointer ${
                        workbench.resultDensity === 'compact'
                          ? 'bg-primary text-primary-foreground font-semibold shadow-2xs'
                          : 'text-muted-foreground hover:text-foreground'
                      }`}
                    >
                      {workbench.t.settings.densityCompact}
                    </button>
                    <button
                      type="button"
                      onclick={() =>
                        updateDisplaySetting(() => {
                          workbench.resultDensity = 'comfortable';
                        })}
                      class={`h-6 rounded-md px-2.5 transition-colors cursor-pointer ${
                        workbench.resultDensity === 'comfortable'
                          ? 'bg-primary text-primary-foreground font-semibold shadow-2xs'
                          : 'text-muted-foreground hover:text-foreground'
                      }`}
                    >
                      {workbench.t.settings.densityComfortable}
                    </button>
                  </div>
                </div>
              </div>

              <div class="border-t border-border/60"></div>

              <!-- Group 2: Search Engine & Client Limits -->
              <div class="space-y-3.5">
                <div class="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
                  {workbench.t.settings.sectionEngine}
                </div>

                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-foreground/95 font-medium">{workbench.t.settings.maxResultsLabel}</div>
                    <div class="text-[11.5px] text-muted-foreground">{workbench.t.settings.maxResultsDesc}</div>
                  </div>
                  <NumberStepper
                    value={workbench.maxResults}
                    min={1}
                    max={500000}
                    step={1000}
                    widthClass="w-16"
                    onchange={(v) =>
                      updateSearchSetting(() => {
                        workbench.maxResults = v;
                      })}
                  />
                </div>

                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-foreground/95 font-medium">{workbench.t.settings.contextLinesLabel}</div>
                    <div class="text-[11.5px] text-muted-foreground">{workbench.t.settings.contextLinesDesc}</div>
                  </div>
                  <NumberStepper
                    value={workbench.contextLines}
                    min={0}
                    max={10}
                    step={1}
                    prefix="±"
                    suffix="ln"
                    widthClass="w-11"
                    onchange={(v) =>
                      updateSearchSetting(() => {
                        workbench.contextLines = v;
                      })}
                  />
                </div>

                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-foreground/95 font-medium">{workbench.t.settings.debounceLabel}</div>
                    <div class="text-[11.5px] text-muted-foreground">{workbench.t.settings.debounceDesc}</div>
                  </div>
                  <NumberStepper
                    value={workbench.debounceMs}
                    min={0}
                    max={2000}
                    step={20}
                    suffix="ms"
                    widthClass="w-11"
                    onchange={(v) =>
                      updateDisplaySetting(() => {
                        workbench.debounceMs = v;
                      })}
                  />
                </div>

                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-foreground/95 font-medium">{workbench.t.settings.liveSearchLabel}</div>
                    <div class="text-[11.5px] text-muted-foreground">{workbench.t.settings.liveSearchDesc}</div>
                  </div>
                  <Switch
                    checked={workbench.liveSearch}
                    title={workbench.t.settings.liveSearchLabel}
                    onchange={(next) =>
                      updateDisplaySetting(() => {
                        workbench.liveSearch = next;
                      })}
                  />
                </div>
              </div>
            </div>
          {:else if workbench.settingsTab === 'sources'}
            <!-- Minimalist Data Sources List (Switch + Delete only) -->
            {#if workbench.sources.length === 0}
              <div class="flex h-full flex-col items-center justify-center py-14 text-center text-muted-foreground">
                <div class="text-xs">{workbench.locale === 'zh' ? '暂无数据源' : 'No data sources'}</div>
              </div>
            {:else}
              <div class="space-y-3.5">
                {#each workbench.sources as src (src.id)}
                  <div class="flex items-center justify-between gap-3">
                    <div class="min-w-0 flex-1">
                      <div class="text-foreground/95 font-medium truncate">{src.name}</div>
                      <div class="text-[11.5px] font-mono text-muted-foreground truncate" title={src.path}>
                        {src.path}
                      </div>
                    </div>

                    <div class="flex items-center gap-2 shrink-0">
                      <Switch
                        checked={src.enabled}
                        title={src.enabled ? '已启用' : '已停用'}
                        onchange={() => workbench.toggleSourceEnabled(src.id)}
                      />
                      <button
                        type="button"
                        onclick={() => workbench.removeSource(src.id)}
                        title={workbench.locale === 'zh' ? '删除' : 'Delete'}
                        class="rounded-lg p-1.5 text-muted-foreground/65 hover:bg-destructive/15 hover:text-destructive transition-colors cursor-pointer"
                      >
                        <Trash2 class="h-3.5 w-3.5" />
                      </button>
                    </div>
                  </div>
                {/each}
              </div>
            {/if}
          {:else if workbench.settingsTab === 'add-source'}
            <!-- Add Data Source Form -->
            <div class="space-y-4">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <div class="text-foreground/95 font-medium">
                    {workbench.locale === 'zh' ? '数据源类型' : 'Source Type'}
                  </div>
                  <div class="text-[11.5px] text-muted-foreground">
                    {kindInput === 'file'
                      ? workbench.locale === 'zh'
                        ? '挂载单个文件作为数据源'
                        : 'Single file'
                      : workbench.locale === 'zh'
                        ? '递归检索整个目录下的文件'
                        : 'Directory'}
                  </div>
                </div>
                <div class="inline-flex h-8 items-center rounded-lg border border-border/80 bg-background/90 p-0.5 text-xs">
                  <button
                    type="button"
                    onclick={() => selectKind('dir')}
                    class={`inline-flex h-6 items-center gap-1 rounded-md px-2.5 transition-colors cursor-pointer ${
                      kindInput === 'dir'
                        ? 'bg-primary text-primary-foreground font-semibold shadow-2xs'
                        : 'text-muted-foreground hover:text-foreground'
                    }`}
                  >
                    <Folder class="h-3 w-3 shrink-0" />
                    <span>{workbench.locale === 'zh' ? '目录' : 'Dir'}</span>
                  </button>
                  <button
                    type="button"
                    onclick={() => selectKind('file')}
                    class={`inline-flex h-6 items-center gap-1 rounded-md px-2.5 transition-colors cursor-pointer ${
                      kindInput === 'file'
                        ? 'bg-primary text-primary-foreground font-semibold shadow-2xs'
                        : 'text-muted-foreground hover:text-foreground'
                    }`}
                  >
                    <FileText class="h-3 w-3 shrink-0" />
                    <span>{workbench.locale === 'zh' ? '单文件' : 'File'}</span>
                  </button>
                </div>
              </div>

              <div class="space-y-1.5">
                <div class="text-foreground/95 font-medium">
                  {kindInput === 'file'
                    ? workbench.locale === 'zh'
                      ? '单文件路径'
                      : 'File Path'
                    : workbench.locale === 'zh'
                      ? '目录路径'
                      : 'Directory Path'}
                </div>
                <div class="relative">
                  {#if kindInput === 'file'}
                    <FileText class="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-sky-400/80" />
                  {:else}
                    <FolderOpen class="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-muted-foreground" />
                  {/if}
                  <input
                    bind:this={pathInputEl}
                    type="text"
                    value={pathInput}
                    oninput={(e) => {
                      pathInput = (e.currentTarget as HTMLInputElement).value;
                      triggerPathAutocomplete(pathInput);
                    }}
                    onfocus={() => triggerPathAutocomplete(pathInput)}
                    onkeydown={handlePathKeydown}
                    placeholder={kindInput === 'file'
                      ? workbench.locale === 'zh'
                        ? '/var/log/app.log 或 ~/data/events.jsonl'
                        : '/var/log/app.log'
                      : workbench.locale === 'zh'
                        ? '/Users/fun/code/webgrep 或 ~/code'
                        : '/var/log or ~/code'}
                    spellcheck="false"
                    autocomplete="off"
                    class="h-9 w-full rounded-lg border border-border/80 bg-background pl-8 pr-2.5 font-mono text-xs text-foreground placeholder:text-muted-foreground/60 focus:border-foreground/50 focus:outline-none"
                  />

                  {#if showDirSuggest && dirSuggestions.length > 0}
                    <div
                      onclick={(e) => e.stopPropagation()}
                      class="absolute left-0 right-0 top-full z-50 mt-1 max-h-48 overflow-y-auto rounded-xl border border-border bg-popover p-1 shadow-xl"
                    >
                      <div class="flex items-center justify-between px-2 py-1 text-[10px] text-muted-foreground border-b border-border/40 mb-0.5">
                        <span>{kindInput === 'file' ? '选择单文件' : '选择目录'}</span>
                        <span class="font-mono">↑↓ · Tab · Enter</span>
                      </div>
                      {#each dirSuggestions as entry, idx (entry.path)}
                        <button
                          type="button"
                          onmouseenter={() => (selectedDirIdx = idx)}
                          onclick={() => applySuggestion(entry, false)}
                          class={`flex w-full items-center justify-between gap-2 rounded-lg px-2 py-1.5 text-left text-xs transition-colors ${
                            idx === selectedDirIdx
                              ? 'bg-secondary text-foreground'
                              : 'text-muted-foreground hover:bg-secondary/50 hover:text-foreground'
                          }`}
                        >
                          <div class="flex items-center gap-1.5 min-w-0">
                            {#if entry.isDir === false}
                              <FileText class="h-3.5 w-3.5 shrink-0 text-sky-400/80" />
                              <span class="font-mono font-medium text-foreground truncate">{entry.name}</span>
                            {:else}
                              <Folder class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                              <span class="font-mono font-medium text-foreground truncate">
                                {entry.name}{kindInput === 'file' ? '/' : ''}
                              </span>
                            {/if}
                          </div>
                          <span class="font-mono text-[10.5px] text-muted-foreground truncate max-w-[55%]">
                            {entry.path}
                          </span>
                        </button>
                      {/each}
                    </div>
                  {/if}
                </div>
              </div>

              <div class="space-y-1.5">
                <div class="text-foreground/95 font-medium">
                  {workbench.locale === 'zh' ? '名称（可选）' : 'Name (Optional)'}
                </div>
                <input
                  type="text"
                  bind:value={nameInput}
                  onkeydown={(e) => {
                    if (e.key === 'Enter') {
                      e.preventDefault();
                      void handleAddSourceSubmit();
                    }
                  }}
                  placeholder={derivedDefaultName
                    ? `默认: ${derivedDefaultName}`
                    : kindInput === 'file'
                      ? '默认取文件名'
                      : '默认取目录名'}
                  spellcheck="false"
                  class="h-9 w-full rounded-lg border border-border/80 bg-background px-2.5 font-mono text-xs text-foreground placeholder:text-muted-foreground/60 focus:border-foreground/50 focus:outline-none"
                />
              </div>

              {#if submitError}
                <div class="flex items-center justify-between rounded-lg bg-destructive/10 px-2.5 py-1.5 text-xs text-destructive">
                  <div class="flex items-center gap-1.5">
                    <AlertTriangle class="h-3.5 w-3.5 shrink-0" />
                    <span>{submitError}</span>
                  </div>
                  <button
                    type="button"
                    onclick={() => (submitError = null)}
                    class="text-destructive/70 hover:text-destructive"
                  >
                    <X class="h-3 w-3" />
                  </button>
                </div>
              {/if}

              <button
                type="button"
                disabled={submitting || !pathInput.trim()}
                onclick={handleAddSourceSubmit}
                class="flex h-9 w-full items-center justify-center gap-1.5 rounded-lg bg-primary text-xs font-semibold text-primary-foreground hover:opacity-90 disabled:opacity-40 transition-opacity cursor-pointer"
              >
                {#if submitting}
                  <Loader2 class="h-3.5 w-3.5 animate-spin" />
                {:else}
                  <Plus class="h-3.5 w-3.5" />
                {/if}
                <span>{workbench.locale === 'zh' ? '添加数据源' : 'Add Source'}</span>
              </button>
            </div>
          {/if}
        </div>
      </section>
    </div>
  </div>
{/if}
