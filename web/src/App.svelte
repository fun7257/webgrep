<script lang="ts">
  import { onMount } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import Header from '$lib/components/Header.svelte';
  import SearchBar from '$lib/components/SearchBar.svelte';
  import TelemetryBar from '$lib/components/TelemetryBar.svelte';
  import ResultList from '$lib/components/ResultList.svelte';
  import InspectorPane from '$lib/components/InspectorPane.svelte';
  import SettingsPopover from '$lib/components/SettingsPopover.svelte';
  import CommandPalette from '$lib/components/CommandPalette.svelte';

  let searchInputEl = $state<HTMLInputElement | null>(null);
  let resizingInspector = $state(false);

  const isHomeView = $derived(
    !workbench.hasSearchedOnce &&
      workbench.fileGroups.length === 0 &&
      !workbench.isSearching
  );

  onMount(() => {
    workbench.init();

    // Compact (mobile) layout breakpoint: < 768px
    const mq = window.matchMedia('(max-width: 767px)');
    workbench.isCompact = mq.matches;
    const onMq = (e: MediaQueryListEvent) => (workbench.isCompact = e.matches);
    mq.addEventListener('change', onMq);

    // Avoid popping the soft keyboard on touch devices at load.
    if (!mq.matches) searchInputEl?.focus();

    return () => mq.removeEventListener('change', onMq);
  });

  // Stacked navigation: opening the detail view pushes a history entry so the
  // system back button / edge-swipe returns to the list instead of leaving the app.
  let detailPushed = false;

  $effect(() => {
    const open = workbench.isCompact && workbench.detailOpen && !!workbench.inspectedPath;
    if (open && !detailPushed) {
      history.pushState({ detail: true }, '');
      detailPushed = true;
    } else if (!open && detailPushed) {
      detailPushed = false;
      if (history.state?.detail) history.back();
    }
  });

  function handlePopState() {
    if (detailPushed) {
      detailPushed = false;
      workbench.detailOpen = false;
    }
  }

  function isTypingInInput(target: EventTarget | null): boolean {
    if (!(target instanceof HTMLElement)) return false;
    const tag = target.tagName.toLowerCase();
    return tag === 'input' || tag === 'textarea' || target.isContentEditable;
  }

  function navigateFile(delta: 1 | -1) {
    const hits = workbench.flatHits;
    const cur = workbench.activeHitIndex;
    if (cur < 0 || cur >= hits.length) return;
    const file = hits[cur].file;
    let i = cur + delta;
    while (i >= 0 && i < hits.length && hits[i].file === file) i += delta;
    if (i < 0 || i >= hits.length) return;
    if (delta < 0) {
      // jump to the first hit of the previous file
      const prevFile = hits[i].file;
      while (i > 0 && hits[i - 1].file === prevFile) i--;
    }
    workbench.selectHitByIndex(i, false);
    workbench.scrollToActiveTick += 1;
  }

  function handleGlobalKeydown(e: KeyboardEvent) {
    // Alt + letter toggles (use e.code: on macOS Alt+letter yields special chars in e.key)
    if (e.altKey && !e.metaKey && !e.ctrlKey) {
      if (e.code === 'KeyC') {
        e.preventDefault();
        workbench.insertToken?.('$c()');
        return;
      }
      if (e.code === 'KeyW') {
        e.preventDefault();
        workbench.insertToken?.('$w()');
        return;
      }
      if (e.code === 'KeyR') {
        e.preventDefault();
        workbench.insertToken?.('$r()');
        return;
      }
    }

    if ((e.metaKey || e.ctrlKey) && e.code === 'KeyK') {
      e.preventDefault();
      workbench.settingsOpen = false;
      workbench.paletteOpen = !workbench.paletteOpen;
      return;
    }

    if ((e.metaKey || e.ctrlKey) && e.key === ',') {
      e.preventDefault();
      workbench.paletteOpen = false;
      if (workbench.settingsOpen) {
        workbench.settingsOpen = false;
      } else {
        workbench.openSettings('general');
      }
      return;
    }

    if (e.key === 'Escape') {
      // Step back one layer at a time: palette → settings → detail → cancel search
      if (workbench.paletteOpen) {
        workbench.paletteOpen = false;
        return;
      }
      if (workbench.settingsOpen) {
        workbench.settingsOpen = false;
        return;
      }
      if (workbench.isCompact && workbench.detailOpen) {
        workbench.detailOpen = false;
        return;
      }
      if (workbench.isSearching) {
        workbench.cancelSearch();
        return;
      }
    }

    if (isTypingInInput(e.target)) return;
    if (workbench.paletteOpen || workbench.settingsOpen) return;

    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'c') {
      const sel = window.getSelection()?.toString() ?? '';
      const hit = workbench.activeHit;
      if (sel.length === 0 && hit) {
        e.preventDefault();
        navigator.clipboard?.writeText(hit.text);
      }
      return;
    }
    if (e.metaKey || e.ctrlKey || e.altKey) return;

    if (e.key === '/') {
      e.preventDefault();
      searchInputEl?.focus();
      searchInputEl?.select();
    } else if (e.key === '?') {
      e.preventDefault();
      if (workbench.settingsOpen && workbench.settingsTab === 'shortcuts') {
        workbench.settingsOpen = false;
      } else {
        workbench.openSettings('shortcuts');
      }
    } else if (e.key === 'Tab' && !e.shiftKey && e.target === document.body) {
      e.preventDefault();
      searchInputEl?.focus();
    } else if (e.key === 'Enter' && e.target === document.body) {
      if (workbench.activeHitIndex >= 0) {
        e.preventDefault();
        workbench.selectHitByIndex(workbench.activeHitIndex, true);
      }
    } else if (e.key === '[') {
      navigateFile(-1);
    } else if (e.key === ']') {
      navigateFile(1);
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

  function startResizeInspector(e: PointerEvent) {
    e.preventDefault();
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    resizingInspector = true;
  }

  function handlePointerMove(e: PointerEvent) {
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
  onpointerdowncapture={(e) => (workbench.isTouch = e.pointerType === 'touch')}
  onpointermove={handlePointerMove}
  onpointerup={stopResize}
  onpointercancel={stopResize}
  onpopstate={handlePopState}
/>

<div
  class={`relative flex h-app w-screen flex-col overflow-hidden bg-background text-foreground ${
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

    {#if !isHomeView && workbench.inspectedPath}
      {#if workbench.isCompact}
        {#if workbench.detailOpen}
          <div class="detail-enter fixed inset-0 z-30 bg-background">
            <InspectorPane />
          </div>
        {/if}
      {:else if workbench.rightInspectorOpen}
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <div
          onpointerdown={startResizeInspector}
          style="touch-action: none"
          class="relative w-[3px] -mr-[1px] shrink-0 cursor-col-resize bg-transparent hover:bg-primary/40 active:bg-primary/70 transition-colors z-20 before:absolute before:inset-y-0 before:-inset-x-1.5 [@media(any-pointer:coarse)]:before:-inset-x-3"
          title={workbench.t.header.dragResizeInspector}
        ></div>
        <InspectorPane />
      {/if}
    {/if}
  </div>

  <SettingsPopover />
  <CommandPalette />
</div>
