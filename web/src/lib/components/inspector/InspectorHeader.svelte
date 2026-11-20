<script lang="ts">
  import { flushSync, onDestroy } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { copyTextToClipboard } from '$lib/utils';
  import {
    ArrowLeft,
    Braces,
    Check,
    Copy,
    FileText,
    Search,
    Share2,
    UnfoldVertical,
    X,
  } from 'lucide-svelte';

  interface Props {
    inspectedProject: string;
    inspectedSubPath: string;
    targetLine: number;
    selectedText: string;
    activeLineText: string;
    showStructuredToggle?: boolean;
    structuredFormattedText?: string;
    onAppendSelection: () => void;
    onExcludeSelection: () => void;
    onSearchSelection: () => void;
    onClose: () => void;
  }

  let {
    inspectedProject,
    inspectedSubPath,
    targetLine,
    selectedText,
    activeLineText,
    showStructuredToggle = true,
    structuredFormattedText = '',
    onAppendSelection,
    onExcludeSelection,
    onSearchSelection,
    onClose,
  }: Props = $props();

  let copiedLine = $state<boolean>(false);
  let copiedShare = $state<boolean>(false);
  let copiedLineTimer: ReturnType<typeof setTimeout> | null = null;
  let copiedShareTimer: ReturnType<typeof setTimeout> | null = null;
  let tabToggledOnDown = false;

  onDestroy(() => {
    if (copiedLineTimer !== null) clearTimeout(copiedLineTimer);
    if (copiedShareTimer !== null) clearTimeout(copiedShareTimer);
  });

  function toggleInspectorTab() {
    workbench.inspectorTab = workbench.inspectorTab === 'raw' ? 'structured' : 'raw';
  }

  function copyCurrentContent() {
    if (!activeLineText) return;
    const textToCopy =
      workbench.inspectorTab === 'structured'
        ? structuredFormattedText || activeLineText
        : activeLineText;
    void copyTextToClipboard(textToCopy);
    copiedLine = true;
    if (copiedLineTimer !== null) clearTimeout(copiedLineTimer);
    copiedLineTimer = setTimeout(() => {
      copiedLine = false;
      copiedLineTimer = null;
    }, 1500);
  }

  async function sharePreviewLink() {
    if (typeof window === 'undefined' || !workbench.inspectedPath) return;
    const url = workbench.buildPreviewShareUrl(window.location.href);
    const ok = await copyTextToClipboard(url);
    try {
      window.history.replaceState(window.history.state, '', url);
    } catch {
      // ignore history errors
    }
    if (!ok) return;
    copiedShare = true;
    if (copiedShareTimer !== null) clearTimeout(copiedShareTimer);
    copiedShareTimer = setTimeout(() => {
      copiedShare = false;
      copiedShareTimer = null;
    }, 1500);
  }
</script>

<!-- Minimalist Noise-Free Header -->
<div class="flex h-11 shrink-0 items-center justify-between gap-2 px-3 md:px-5 select-none">
  <div class="flex items-center gap-2 min-w-0 font-mono text-xs">
    {#if workbench.isCompact}
      <button
        type="button"
        onclick={onClose}
        aria-label={workbench.t.inspector.closeTitle}
        title={workbench.t.inspector.closeTitle}
        class="touch-target -ml-1 flex h-9 w-9 items-center justify-center rounded-md text-foreground hover:bg-secondary/60"
      >
        <ArrowLeft class="h-4 w-4" />
      </button>
    {/if}
    {#if inspectedProject}
      <span class="text-muted-foreground/75 shrink-0">
        @{inspectedProject}
      </span>
    {/if}
    {#if inspectedSubPath}
      <span class="truncate text-muted-foreground/60" title={`${inspectedSubPath}:${targetLine}`}>
        {inspectedSubPath}:{targetLine}
      </span>
    {/if}
  </div>

  <div class="flex items-center gap-1 shrink-0">
    {#if selectedText}
      {#if workbench.hasAnyQueryInput}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={onAppendSelection}
          title={workbench.t.inspector.includeTitle(selectedText)}
          class="touch-target flex items-center gap-1 rounded-md bg-secondary/80 px-2 py-1 text-xs font-medium text-foreground hover:bg-secondary active:bg-secondary cursor-pointer"
        >
          <span>+</span>
          <span class="truncate max-w-[64px]">{selectedText}</span>
        </button>
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={onExcludeSelection}
          title={workbench.t.inspector.excludeTitle(selectedText)}
          class="touch-target flex items-center gap-1 rounded-md bg-secondary/60 px-2 py-1 text-xs font-medium text-muted-foreground hover:bg-secondary hover:text-foreground active:bg-secondary cursor-pointer"
        >
          <span>-</span>
          <span class="truncate max-w-[64px]">{selectedText}</span>
        </button>
      {/if}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={onSearchSelection}
        title={workbench.t.inspector.searchSelectionTitle(selectedText)}
        class="touch-target flex items-center gap-1 rounded-md bg-secondary/80 px-2 py-1 text-xs font-medium text-foreground hover:bg-secondary active:bg-secondary cursor-pointer"
      >
        <Search class="h-3 w-3" />
        <span class="truncate max-w-[72px]">{selectedText}</span>
      </button>
    {/if}

    {#if workbench.inspectedPath && targetLine > 0}
      <button
        type="button"
        data-inspector-context-btn
        aria-pressed={workbench.contextDrawerOpen}
        title={workbench.t.inspector.openContextTitle}
        aria-label={workbench.t.inspector.openContextTitle}
        onmousedown={(e) => e.preventDefault()}
        onclick={() => {
          flushSync(() => {
            void workbench.openContextDrawer(workbench.inspectedPath!, targetLine);
          });
        }}
        class={`touch-target rounded-md p-1.5 cursor-pointer ${
          workbench.contextDrawerOpen
            ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35'
            : 'text-muted-foreground/80 hover:bg-secondary/60 hover:text-foreground active:bg-secondary'
        }`}
      >
        <UnfoldVertical class="h-3.5 w-3.5" />
      </button>
    {/if}

    {#if showStructuredToggle}
      <!-- Formatted / Raw toggle (single icon button) -->
      <button
        type="button"
        onpointerdown={(e) => {
          if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
            tabToggledOnDown = true;
            toggleInspectorTab();
          }
        }}
        onclick={(e) => {
          if (tabToggledOnDown && e.detail > 0) {
            tabToggledOnDown = false;
            return;
          }
          tabToggledOnDown = false;
          toggleInspectorTab();
        }}
        title={workbench.inspectorTab === 'raw'
          ? workbench.t.inspector.formattedBtn
          : workbench.t.inspector.rawBtn}
        aria-label={workbench.inspectorTab === 'raw'
          ? workbench.t.inspector.formattedBtn
          : workbench.t.inspector.rawBtn}
        class="touch-target rounded-md p-1.5 text-muted-foreground/80 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
      >
        {#if workbench.inspectorTab === 'raw'}
          <Braces class="h-3.5 w-3.5" />
        {:else}
          <FileText class="h-3.5 w-3.5" />
        {/if}
      </button>
    {/if}

    {#if activeLineText}
      <button
        type="button"
        title={workbench.t.inspector.copyTitle}
        aria-label={workbench.t.inspector.copyTitle}
        onclick={copyCurrentContent}
        class="touch-target rounded-md p-1.5 text-muted-foreground/70 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
      >
        {#if copiedLine}
          <Check class="h-3.5 w-3.5 text-primary" />
        {:else}
          <Copy class="h-3.5 w-3.5" />
        {/if}
      </button>
    {/if}

    {#if workbench.inspectedPath}
      <button
        type="button"
        title={copiedShare
          ? workbench.t.inspector.shareReplayCopied
          : workbench.t.inspector.shareReplayTitle}
        aria-label={workbench.t.inspector.shareReplayTitle}
        onmousedown={(e) => e.preventDefault()}
        onclick={() => void sharePreviewLink()}
        class="touch-target rounded-md p-1.5 text-muted-foreground/70 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
      >
        {#if copiedShare}
          <Check class="h-3.5 w-3.5 text-primary" />
        {:else}
          <Share2 class="h-3.5 w-3.5" />
        {/if}
      </button>
    {/if}

    <button
      type="button"
      title={workbench.t.inspector.closeTitle}
      aria-label={workbench.t.inspector.closeTitle}
      onclick={onClose}
      class="touch-target rounded-md p-1.5 text-muted-foreground/70 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
    >
      <X class="h-3.5 w-3.5" />
    </button>
  </div>
</div>
