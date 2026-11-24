<script lang="ts">
  import { flushSync, onDestroy } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { copyTextToClipboard } from '$lib/utils';
  import {
    ArrowLeft,
    Braces,
    Check,
    Copy,
    Link2,
    Search,
    UnfoldVertical,
    X,
  } from 'lucide-svelte';

  interface Props {
    inspectedProject: string;
    inspectedSubPath: string;
    targetLine: number;
    anchorByteHint?: number | null;
    selectedText: string;
    activeLineText: string;
    showStructuredToggle?: boolean;
    structuredFormattedText?: string;
    onAppendSelection: () => void;
    onExcludeSelection: () => void;
    onSearchSelection: () => void;
    onClearSelection?: () => void;
    onClose: () => void;
  }

  let {
    inspectedProject,
    inspectedSubPath,
    targetLine,
    anchorByteHint = null,
    selectedText,
    activeLineText,
    showStructuredToggle = true,
    structuredFormattedText = '',
    onAppendSelection,
    onExcludeSelection,
    onSearchSelection,
    onClearSelection,
    onClose,
  }: Props = $props();

  let copiedPathLine = $state<boolean>(false);
  let copiedLine = $state<boolean>(false);
  let copiedShare = $state<boolean>(false);
  let copiedPathLineTimer: ReturnType<typeof setTimeout> | null = null;
  let copiedLineTimer: ReturnType<typeof setTimeout> | null = null;
  let copiedShareTimer: ReturnType<typeof setTimeout> | null = null;
  let tabToggledOnDown = false;

  onDestroy(() => {
    if (copiedPathLineTimer !== null) clearTimeout(copiedPathLineTimer);
    if (copiedLineTimer !== null) clearTimeout(copiedLineTimer);
    if (copiedShareTimer !== null) clearTimeout(copiedShareTimer);
  });

  async function copyPathWithLine() {
    const path = workbench.inspectedPath;
    if (!path) return;
    const text = targetLine > 0 ? `${path}:${targetLine}` : path;
    const ok = await copyTextToClipboard(text);
    if (!ok) return;
    copiedPathLine = true;
    if (copiedPathLineTimer !== null) clearTimeout(copiedPathLineTimer);
    copiedPathLineTimer = setTimeout(() => {
      copiedPathLine = false;
      copiedPathLineTimer = null;
    }, 1500);
  }

  function toggleInspectorTab() {
    workbench.inspectorTab = workbench.inspectorTab === 'raw' ? 'structured' : 'raw';
  }

  async function copyCurrentContent() {
    if (!activeLineText) return;
    const textToCopy =
      workbench.inspectorTab === 'structured'
        ? structuredFormattedText || activeLineText
        : activeLineText;
    const ok = await copyTextToClipboard(textToCopy);
    if (!ok) return;
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
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={() => void copyPathWithLine()}
        title={copiedPathLine
          ? workbench.t.codeView.copiedPathLine
          : `${workbench.t.codeView.copyPathLine} · ${inspectedSubPath}:${targetLine}`}
        aria-label={workbench.t.codeView.copyPathLine}
        class="touch-target inline-flex min-w-0 items-center gap-1 rounded px-1 py-0.5 text-muted-foreground/80 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
      >
        <span class="truncate">{inspectedSubPath}:{targetLine}</span>
        {#if copiedPathLine}
          <Check class="h-3 w-3 shrink-0 text-primary" />
        {/if}
      </button>
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
          aria-label={workbench.t.inspector.includeTitle(selectedText)}
          class="touch-target inline-flex h-7 min-w-7 items-center justify-center rounded-md bg-secondary/80 px-2 text-xs font-semibold text-foreground hover:bg-secondary active:bg-secondary cursor-pointer"
        >
          +
        </button>
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={onExcludeSelection}
          title={workbench.t.inspector.excludeTitle(selectedText)}
          aria-label={workbench.t.inspector.excludeTitle(selectedText)}
          class="touch-target inline-flex h-7 min-w-7 items-center justify-center rounded-md bg-secondary/60 px-2 text-xs font-semibold text-muted-foreground hover:bg-secondary hover:text-foreground active:bg-secondary cursor-pointer"
        >
          -
        </button>
      {/if}
      <button
        type="button"
        onmousedown={(e) => e.preventDefault()}
        onclick={onSearchSelection}
        title={workbench.t.inspector.searchSelectionTitle(selectedText)}
        aria-label={workbench.t.inspector.searchSelectionTitle(selectedText)}
        class="touch-target inline-flex h-7 items-center gap-1 rounded-md bg-secondary/80 px-2 text-xs font-medium text-foreground hover:bg-secondary active:bg-secondary cursor-pointer"
      >
        <Search class="h-3 w-3 shrink-0" />
        <span class="truncate max-w-[72px] sm:max-w-[96px]">{selectedText}</span>
      </button>
      {#if onClearSelection}
        <button
          type="button"
          onmousedown={(e) => e.preventDefault()}
          onclick={onClearSelection}
          title={workbench.t.searchBar.clearDraftTitle}
          aria-label={workbench.t.searchBar.clearDraftTitle}
          class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
        >
          <X class="h-3.5 w-3.5" />
        </button>
      {/if}
    {:else}
      {#if workbench.inspectedPath && targetLine > 0}
        <button
          type="button"
          data-inspector-context-btn
          aria-pressed={workbench.contextDrawerOpen}
          title={workbench.t.inspector.openContextTitle}
          aria-label={workbench.t.inspector.openContextTitle}
          onmousedown={(e) => e.preventDefault()}
          onclick={() => {
            const byteHint =
              anchorByteHint ??
              (workbench.inspectedHit?.file === workbench.inspectedPath &&
              workbench.inspectedHit?.line === targetLine
                ? workbench.inspectedHit.byteOffset
                : null);
            flushSync(() => {
              void workbench.openContextDrawer(workbench.inspectedPath!, targetLine, byteHint);
            });
          }}
          class={`touch-target flex h-7 w-7 items-center justify-center rounded-md cursor-pointer ${
            workbench.contextDrawerOpen
              ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35'
              : 'text-muted-foreground/80 hover:bg-secondary/60 hover:text-foreground active:bg-secondary'
          }`}
        >
          <UnfoldVertical class="h-3.5 w-3.5" />
        </button>
      {/if}

      {#if showStructuredToggle}
        {@const isStructured = workbench.inspectorTab === 'structured'}
        <!-- Formatted / Raw toggle (single icon button) -->
        <button
          type="button"
          aria-pressed={isStructured}
          onpointerdown={(e) => {
            if (e.pointerType === 'mouse' && e.button === 0 && !e.altKey && !e.ctrlKey && !e.metaKey) {
              tabToggledOnDown = true;
              flushSync(() => toggleInspectorTab());
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
          title={isStructured
            ? workbench.t.inspector.rawBtn
            : workbench.t.inspector.formattedBtn}
          aria-label={isStructured
            ? workbench.t.inspector.rawBtn
            : workbench.t.inspector.formattedBtn}
          class={`touch-target flex h-7 w-7 items-center justify-center rounded-md cursor-pointer ${
            isStructured
              ? 'bg-primary/15 text-primary ring-1 ring-inset ring-primary/35'
              : 'text-muted-foreground/80 hover:bg-secondary/60 hover:text-foreground active:bg-secondary'
          }`}
        >
          <Braces class="h-3.5 w-3.5" />
        </button>
      {/if}

      {#if activeLineText}
        <button
          type="button"
          title={workbench.t.inspector.copyTitle}
          aria-label={workbench.t.inspector.copyTitle}
          onclick={() => void copyCurrentContent()}
          class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
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
          class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
        >
          {#if copiedShare}
            <Check class="h-3.5 w-3.5 text-primary" />
          {:else}
            <Link2 class="h-3.5 w-3.5" />
          {/if}
        </button>
      {/if}

      {#if !workbench.isCompact}
        <button
          type="button"
          title={workbench.t.inspector.closeTitle}
          aria-label={workbench.t.inspector.closeTitle}
          onclick={onClose}
          class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/60 hover:text-foreground active:bg-secondary cursor-pointer"
        >
          <X class="h-3.5 w-3.5" />
        </button>
      {/if}
    {/if}
  </div>
</div>
