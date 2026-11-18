<script lang="ts">
  import { flushSync } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { DEFAULT_PLUGIN_PRESET, type NormalizedPluginOverrides } from '$lib/prefilter';
  import type { DirSuggestEntry, PluginPreset } from '$lib/types';
  import Segmented from '../ui/Segmented.svelte';
  import SourcePrefilterEditor from './SourcePrefilterEditor.svelte';
  import {
    AlertTriangle,
    ChevronRight,
    Container,
    FileText,
    Folder,
    FolderOpen,
    Loader2,
    Plus,
    X,
  } from 'lucide-svelte';

  interface Props {
    /** Called after a source was added successfully. */
    ondone: () => void;
  }

  let { ondone }: Props = $props();

  const t = $derived(workbench.t.ui);

  let kind = $state<'dir' | 'file' | 'docker'>('dir');
  let pathInput = $state('');
  let nameInput = $state('');
  let timeFormatInput = $state('');
  let timeFormatTouched = $state(false);
  let timeFormatValid = $state(true);
  let pluginPresetInput = $state<PluginPreset>(DEFAULT_PLUGIN_PRESET);
  let pluginOverridesInput = $state<NormalizedPluginOverrides>({ enable: [], disable: [] });
  let submitting = $state(false);
  let submitError = $state<string | null>(null);

  let suggestions = $state.raw<DirSuggestEntry[]>([]);
  let showSuggest = $state(false);
  let selectedIdx = $state(0);
  let suggestTimer: ReturnType<typeof setTimeout> | null = null;
  let pathEl = $state<HTMLInputElement | null>(null);

  const derivedName = $derived.by(() => {
    const clean = pathInput.trim().replace(/\/+$/, '');
    if (kind === 'docker') {
      const sep = clean.indexOf('::');
      if (sep !== -1) {
        const target = clean.slice(sep + 2).trim();
        if (target) return target;
      }
      return 'docker';
    }
    if (!clean) return '';
    const parts = clean.split('/');
    return parts[parts.length - 1] || '';
  });

  function queueSuggest(val: string) {
    if (suggestTimer) clearTimeout(suggestTimer);
    const reqKind = kind;
    suggestTimer = setTimeout(async () => {
      const list = await workbench.fetchDirSuggestions(val, reqKind);
      if (kind !== reqKind) return;
      suggestions = list;
      selectedIdx = 0;
      showSuggest = list.length > 0;
    }, 60);
  }

  function selectKind(next: 'dir' | 'file' | 'docker') {
    if (kind === next) return;
    const prev = kind;
    kind = next;
    submitError = null;
    if (next === 'docker') {
      if (!timeFormatTouched && !timeFormatInput) {
        timeFormatInput = 'auto';
      }
      const cur = pathInput.trim();
      const isDockerEndpoint =
        cur === 'auto' ||
        cur.includes('::') ||
        cur.startsWith('unix://') ||
        cur.startsWith('tcp://') ||
        cur.startsWith('http://') ||
        cur.endsWith('.sock') ||
        cur.includes('/containers');
      if (cur && !isDockerEndpoint) {
        pathInput = '';
      }
    } else if (prev === 'docker') {
      if (!timeFormatTouched && timeFormatInput === 'auto') {
        timeFormatInput = '';
      }
      const cur = pathInput.trim();
      if (
        cur === 'auto' ||
        cur.includes('::') ||
        cur.startsWith('unix://') ||
        cur.startsWith('tcp://') ||
        cur.startsWith('http://') ||
        cur.endsWith('.sock')
      ) {
        pathInput = '';
      }
    }
    flushSync();
    queueSuggest(pathInput);
    pathEl?.focus({ preventScroll: true });
  }

  function apply(entry: DirSuggestEntry, drill: boolean) {
    const isDirectory = entry.isDir === true;
    const shouldDrill = isDirectory && (drill || kind === 'file');
    const next = shouldDrill ? (entry.path.endsWith('/') ? entry.path : `${entry.path}/`) : entry.path;
    flushSync(() => {
      pathInput = next;
    });
    if (shouldDrill) {
      queueSuggest(next);
      pathEl?.focus({ preventScroll: true });
    } else {
      showSuggest = false;
    }
  }

  function onPathKeydown(e: KeyboardEvent) {
    if (showSuggest && suggestions.length > 0) {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        selectedIdx = (selectedIdx + 1) % suggestions.length;
        return;
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        selectedIdx = (selectedIdx - 1 + suggestions.length) % suggestions.length;
        return;
      }
      if (e.key === 'Tab') {
        e.preventDefault();
        const chosen = suggestions[selectedIdx] ?? suggestions[0];
        if (chosen) apply(chosen, true);
        return;
      }
      if (e.key === 'Enter') {
        const chosen = suggestions[selectedIdx];
        if (chosen && chosen.path !== pathInput.trim()) {
          e.preventDefault();
          apply(chosen, false);
          return;
        }
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        showSuggest = false;
        return;
      }
    }
    if (e.key === 'Enter') {
      e.preventDefault();
      void submit();
    }
  }

  async function submit() {
    const rawTrimmed = pathInput.trim();
    const cleanPath = kind === 'docker' ? rawTrimmed || 'auto' : rawTrimmed;
    if (!cleanPath) {
      submitError = kind === 'file' ? t.pathRequiredFile : t.pathRequiredDir;
      return;
    }
    if (!timeFormatValid) {
      submitError = t.sourceTimeCustomRequired;
      return;
    }
    const finalName = (nameInput.trim() || derivedName || (kind === 'docker' ? 'docker' : 'project')).trim();
    submitting = true;
    submitError = null;
    try {
      await workbench.upsertDirectorySource({
        kind,
        name: finalName,
        path: cleanPath,
        config: { path: cleanPath },
        enabled: true,
        timeFormat: timeFormatInput.trim(),
        pluginPreset: pluginPresetInput,
        plugins: pluginOverridesInput,
      });
      pathInput = '';
      nameInput = '';
      timeFormatTouched = false;
      timeFormatInput = kind === 'docker' ? 'auto' : '';
      timeFormatValid = true;
      pluginPresetInput = DEFAULT_PLUGIN_PRESET;
      pluginOverridesInput = { enable: [], disable: [] };
      showSuggest = false;
      ondone();
    } catch (err) {
      submitError = err instanceof Error ? err.message : t.addFailed;
    } finally {
      submitting = false;
    }
  }

  const inputCls =
    'h-9 w-full rounded-lg border border-border/70 bg-background font-mono text-xs text-foreground placeholder:text-muted-foreground/60 focus:border-primary/60 focus:outline-none [@media(any-pointer:coarse)]:text-[16px]';
</script>

<div class="space-y-2.5 rounded-xl border border-border/65 bg-card/65 dark:bg-card/60 p-3.5">
  <div class="flex items-center">
    <Segmented
      value={kind}
      options={[
        { value: 'dir', label: t.dir, icon: Folder, title: t.kindDirDesc },
        { value: 'file', label: t.file, icon: FileText, title: t.kindFileDesc },
        { value: 'docker', label: t.docker, icon: Container, title: t.kindDockerDesc },
      ]}
      onchange={selectKind}
    />
  </div>

  <div class="relative">
      {#if kind === 'docker'}
        <Container class="pointer-events-none absolute left-3 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
      {:else if kind === 'file'}
        <FileText class="pointer-events-none absolute left-3 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
      {:else}
        <FolderOpen class="pointer-events-none absolute left-3 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
      {/if}
      <input
        bind:this={pathEl}
        type="text"
        value={pathInput}
        oninput={(e) => {
          pathInput = (e.currentTarget as HTMLInputElement).value;
          queueSuggest(pathInput);
        }}
        onfocus={() => queueSuggest(pathInput)}
        onkeydown={onPathKeydown}
        title={kind === 'docker' ? t.dockerEndpoint : kind === 'file' ? t.filePath : t.dirPath}
        placeholder={kind === 'docker'
          ? t.dockerPlaceholder
          : kind === 'file'
            ? t.filePlaceholder
            : t.dirPlaceholder}
        spellcheck="false"
        autocomplete="off"
        class={`${inputCls} pl-9 pr-3`}
      />

      {#if showSuggest && suggestions.length > 0}
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <div
          onclick={(e) => e.stopPropagation()}
          onkeydown={() => {}}
          class="absolute left-0 right-0 top-full z-50 mt-1 max-h-52 overflow-y-auto rounded-xl border border-border bg-popover p-1 shadow-xl"
        >
          {#each suggestions as entry, idx (entry.path)}
            {@const isDir = entry.isDir === true}
            <div
              class={`flex items-center rounded-lg ${
                idx === selectedIdx ? 'bg-secondary' : 'hover:bg-secondary/50'
              }`}
            >
              <button
                type="button"
                onmouseenter={() => (selectedIdx = idx)}
                onclick={() => apply(entry, false)}
                class="flex min-h-10 min-w-0 flex-1 items-center gap-2 px-2 text-left text-xs"
              >
                {#if kind === 'docker' && !isDir}
                  <Container class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                {:else if isDir}
                  <Folder class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                {:else}
                  <FileText class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                {/if}
                <span class="truncate font-mono font-medium text-foreground">{entry.name}</span>
                <span class="ml-auto max-w-[45%] truncate font-mono text-[10.5px] text-muted-foreground">{entry.path}</span>
              </button>
              {#if isDir}
                <button
                  type="button"
                  onclick={() => apply(entry, true)}
                  aria-label={t.pickDrill}
                  title={t.pickDrill}
                  class="touch-target flex h-10 w-9 shrink-0 items-center justify-center text-muted-foreground hover:text-foreground"
                >
                  <ChevronRight class="h-4 w-4" />
                </button>
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>

    <input
      type="text"
      bind:value={nameInput}
      onkeydown={(e) => {
        if (e.key === 'Enter') {
          e.preventDefault();
          void submit();
        }
      }}
      title={t.nameOptional}
      placeholder={derivedName
        ? `${t.defaultNamePrefix}${derivedName}`
        : kind === 'docker'
          ? t.defaultDockerName
          : kind === 'file'
            ? t.defaultFileName
            : t.defaultDirName}
      spellcheck="false"
      class={`${inputCls} px-3`}
    />

    <SourcePrefilterEditor
      preset={pluginPresetInput}
      overrides={pluginOverridesInput}
      timeFormat={timeFormatInput}
      defaultAutoTimeFormat={kind === 'docker' ? 'auto' : ''}
      onchange={(nextPreset, nextOverrides) => {
        pluginPresetInput = nextPreset;
        pluginOverridesInput = nextOverrides;
      }}
      ontimeformatchange={(fmt, valid) => {
        timeFormatTouched = true;
        timeFormatInput = fmt;
        timeFormatValid = valid;
      }}
      onsubmit={() => void submit()}
    />

  {#if submitError}
    <div class="flex items-center justify-between gap-2 rounded-lg bg-status/10 px-2.5 py-2 text-xs text-status">
      <div class="flex min-w-0 items-center gap-1.5">
        <AlertTriangle class="h-3.5 w-3.5 shrink-0" />
        <span class="truncate">{submitError}</span>
      </div>
      <button type="button" onclick={() => (submitError = null)} class="shrink-0 text-status/70 hover:text-status" aria-label={workbench.t.settings.closeTitle}>
        <X class="h-3 w-3" />
      </button>
    </div>
  {/if}

  <button
    type="button"
    disabled={submitting || (kind !== 'docker' && !pathInput.trim()) || !timeFormatValid}
    onclick={submit}
    title={t.addSource}
    aria-label={t.addSource}
    class="flex h-10 w-full items-center justify-center gap-1.5 rounded-lg bg-primary text-xs font-medium text-primary-foreground hover:opacity-90 active:opacity-80 disabled:opacity-40 cursor-pointer"
  >
    {#if submitting}
      <Loader2 class="h-4 w-4 animate-spin" />
    {:else}
      <Plus class="h-4 w-4" />
    {/if}
    <span>{t.addSource}</span>
  </button>
</div>
