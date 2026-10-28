<script lang="ts">
  import { onMount } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import Header from '$lib/components/Header.svelte';
  import SearchBar from '$lib/components/SearchBar.svelte';
  import TelemetryBar from '$lib/components/TelemetryBar.svelte';
  import ResultList from '$lib/components/ResultList.svelte';
  import InspectorPane from '$lib/components/InspectorPane.svelte';
  import ShortcutsModal from '$lib/components/ShortcutsModal.svelte';
  import SettingsPopover from '$lib/components/SettingsPopover.svelte';

  let searchInputEl = $state<HTMLInputElement | null>(null);
  let resizingInspector = $state(false);

  const isHomeView = $derived(
    !workbench.hasSearchedOnce &&
      workbench.fileGroups.length === 0 &&
      !workbench.isSearching
  );

  onMount(() => {
    workbench.init();
    searchInputEl?.focus();
  });

  function isTypingInInput(target: EventTarget | null): boolean {
    if (!(target instanceof HTMLElement)) return false;
    const tag = target.tagName.toLowerCase();
    return tag === 'input' || tag === 'textarea' || target.isContentEditable;
  }

  function handleGlobalKeydown(e: KeyboardEvent) {
    if (e.AltKey || e.altKey) {
      if (e.key.toLowerCase() === 'c') {
        e.preventDefault();
        workbench.cycleCaseMode();
        return;
      }
      if (e.key.toLowerCase() === 'w') {
        e.preventDefault();
        workbench.toggleFlag('w');
        return;
      }
      if (e.key.toLowerCase() === 'r') {
        e.preventDefault();
        workbench.cycleSearchMode();
        return;
      }
    }

    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'd') {
      e.preventDefault();
      if (workbench.settingsOpen && workbench.settingsTab === 'sources') {
        workbench.settingsOpen = false;
      } else {
        workbench.openSettings('sources');
      }
      return;
    }

    if ((e.metaKey || e.ctrlKey) && e.key === ',') {
      e.preventDefault();
      if (workbench.settingsOpen && workbench.settingsTab === 'general') {
        workbench.settingsOpen = false;
      } else {
        workbench.openSettings('general');
      }
      return;
    }

    if (e.key === 'Escape') {
      if (workbench.settingsOpen) {
        workbench.settingsOpen = false;
        return;
      }
      if (workbench.shortcutsModalOpen) {
        workbench.shortcutsModalOpen = false;
        return;
      }
      if (workbench.isSearching) {
        workbench.cancelSearch();
        return;
      }
    }

    if (isTypingInInput(e.target)) return;

    if (e.key === '/') {
      e.preventDefault();
      searchInputEl?.focus();
      searchInputEl?.select();
    } else if (e.key === '?') {
      e.preventDefault();
      workbench.settingsOpen = false;
      workbench.shortcutsModalOpen = !workbench.shortcutsModalOpen;
    } else if (e.key === 'ArrowDown' || e.key === 'j') {
      if (workbench.flatHits.length > 0) {
        e.preventDefault();
        workbench.navigateHits(1);
      }
    } else if (e.key === 'ArrowUp' || e.key === 'k') {
      if (workbench.flatHits.length > 0) {
        e.preventDefault();
        workbench.navigateHits(-1);
      }
    }
  }

  let resizeRaf: number | null = null;

  function startResizeInspector(e: MouseEvent) {
    e.preventDefault();
    resizingInspector = true;
  }

  function handleMouseMove(e: MouseEvent) {
    if (!resizingInspector) return;
    const clientX = e.clientX;
    if (resizeRaf !== null) return;
    resizeRaf = requestAnimationFrame(() => {
      resizeRaf = null;
      const fromRight = window.innerWidth - clientX;
      workbench.rightInspectorWidth = Math.max(300, Math.min(720, fromRight));
    });
  }

  function stopResize() {
    resizingInspector = false;
    if (resizeRaf !== null) {
      cancelAnimationFrame(resizeRaf);
      resizeRaf = null;
    }
  }
</script>

<svelte:window
  onkeydown={handleGlobalKeydown}
  onmousemove={handleMouseMove}
  onmouseup={stopResize}
/>

<div
  class={`relative flex h-screen w-screen flex-col overflow-hidden bg-background text-foreground ${
    resizingInspector ? 'select-none cursor-col-resize' : ''
  }`}
>
  <Header />

  <div class="flex flex-1 min-h-0 overflow-hidden">
    <main class="flex flex-1 flex-col min-w-0 min-h-0 overflow-hidden">
      <SearchBar bind:inputEl={searchInputEl} hero={isHomeView} />
      {#if !isHomeView}
        <TelemetryBar />
        <ResultList />
      {/if}
    </main>

    {#if !isHomeView && workbench.rightInspectorOpen && workbench.inspectedPath}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        onmousedown={startResizeInspector}
        class="w-[3px] -mr-[1px] shrink-0 cursor-col-resize bg-transparent hover:bg-primary/40 active:bg-primary/70 transition-colors z-20"
        title={workbench.t.header.dragResizeInspector}
      ></div>
      <InspectorPane />
    {/if}
  </div>

  <ShortcutsModal />
  <SettingsPopover />
</div>
