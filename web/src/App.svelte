<script lang="ts">
  import { onMount, tick } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import { copyTextToClipboard } from '$lib/utils';
  import Header from '$lib/components/Header.svelte';
  import LoginView from '$lib/components/LoginView.svelte';
  import LeftScopeSidebar from '$lib/components/LeftScopeSidebar.svelte';
  import SearchBar from '$lib/components/SearchBar.svelte';
  import TelemetryBar from '$lib/components/TelemetryBar.svelte';
  import ResultList from '$lib/components/ResultList.svelte';
  import InspectorPane from '$lib/components/InspectorPane.svelte';
  import RightDrawer from '$lib/components/RightDrawer.svelte';
  import CommandPalette from '$lib/components/CommandPalette.svelte';

  let searchInputEl = $state<HTMLInputElement | null>(null);
  let resizingInspector = $state(false);
  let prevAuthState: typeof workbench.authState = 'checking';

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

    return () => mq.removeEventListener('change', onMq);
  });

  $effect(() => {
    const curAuth = workbench.authState;
    const becameAuthenticated = curAuth === 'authenticated' && prevAuthState !== 'authenticated';
    prevAuthState = curAuth;
    if (becameAuthenticated && !workbench.isCompact && !workbench.isTouch) {
      void tick().then(() => {
        searchInputEl?.focus();
      });
    }
  });

  // Stacked navigation: opening the detail view pushes a history entry so the
  // system back button / edge-swipe returns to the list instead of leaving the app.
  let detailPushed = false;

  $effect(() => {
    const open = workbench.isCompact && workbench.detailOpen && !!workbench.inspectedPath;
    if (open && !detailPushed) {
      history.pushState({ detail: true }, '');
      detailPushed = true;
      // Drop focus from the search box so its attached dropdown / symbol bar and the soft keyboard close.
      const active = document.activeElement;
      if (active instanceof HTMLElement && isTypingInInput(active)) active.blur();
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

  function navigateFile(delta: 1 | -1, rapid = false) {
    const hits = workbench.flatHits;
    const cur = workbench.activeHitIndex;
    if (cur < 0 || cur >= hits.length) return;
    const pred = workbench.visibleHitPredicate;
    const file = hits[cur].file;
    let i = cur + delta;
    while (
      i >= 0 &&
      i < hits.length &&
      (hits[i].file === file || (pred && !pred(hits[i])))
    ) {
      i += delta;
    }
    if (i < 0 || i >= hits.length) return;
    if (delta < 0) {
      // jump to the first visible hit of the previous file
      const prevFile = hits[i].file;
      let firstVisible = i;
      while (i > 0 && hits[i - 1].file === prevFile) {
        i--;
        if (!pred || pred(hits[i])) {
          firstVisible = i;
        }
      }
      i = firstVisible;
    }
    workbench.selectHitByIndex(i, false, rapid);
    workbench.scrollToActiveTick += 1;
  }

  function handleGlobalKeydown(e: KeyboardEvent) {
    if (workbench.authState !== 'authenticated') return;

    // Alt + letter toggles (use e.code: on macOS Alt+letter yields special chars in e.key)
    if (e.altKey && !e.metaKey && !e.ctrlKey) {
      if (e.code === 'KeyC') {
        e.preventDefault();
        workbench.toggleCaseSensitive();
        searchInputEl?.focus();
        return;
      }
      if (e.code === 'KeyW') {
        e.preventDefault();
        workbench.toggleWholeWord();
        searchInputEl?.focus();
        return;
      }
      if (e.code === 'KeyR') {
        e.preventDefault();
        workbench.toggleRegexMode();
        searchInputEl?.focus();
        return;
      }
    }

    if ((e.metaKey || e.ctrlKey) && e.code === 'KeyK') {
      e.preventDefault();
      workbench.closeScopeOverlays();
      workbench.closeRightDrawer();
      workbench.paletteOpen = !workbench.paletteOpen;
      return;
    }

    if ((e.metaKey || e.ctrlKey) && e.key === ',') {
      e.preventDefault();
      workbench.paletteOpen = false;
      workbench.closeScopeOverlays();
      if (workbench.settingsOpen) {
        workbench.closeRightDrawer();
      } else {
        workbench.openSettingsDrawer();
      }
      return;
    }

    if (e.key === 'Escape') {
      // Step back one layer at a time: palette → rail flyout → mobile scope drawer → right drawer → detail → cancel search
      if (workbench.paletteOpen) {
        workbench.paletteOpen = false;
        return;
      }
      if (!workbench.isCompact && workbench.railFlyout !== null) {
        workbench.closeRailFlyout();
        searchInputEl?.focus();
        return;
      }
      if (workbench.isCompact && workbench.mobileScopeOpen) {
        workbench.closeMobileScope();
        return;
      }
      if (workbench.rightDrawerOpen) {
        workbench.closeRightDrawer();
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

    if (!e.metaKey && !e.ctrlKey && !e.altKey && e.key === '?') {
      e.preventDefault();
      workbench.closeScopeOverlays();
      if (workbench.shortcutsDrawerOpen) {
        workbench.closeRightDrawer();
      } else {
        workbench.openShortcutsDrawer();
      }
      return;
    }

    if (
      workbench.paletteOpen ||
      workbench.rightDrawerOpen ||
      (!workbench.isCompact && workbench.railFlyout !== null) ||
      (workbench.isCompact && workbench.mobileScopeOpen)
    ) {
      return;
    }

    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'c') {
      const sel = window.getSelection()?.toString() ?? '';
      const hit = workbench.activeHit;
      if (sel.length === 0 && hit) {
        e.preventDefault();
        copyTextToClipboard(hit.text);
      }
      return;
    }
    if (e.metaKey || e.ctrlKey || e.altKey) return;

    if (e.key === '/') {
      e.preventDefault();
      searchInputEl?.focus();
      searchInputEl?.select();
    } else if (e.key === 'Tab' && !e.shiftKey && e.target === document.body) {
      e.preventDefault();
      searchInputEl?.focus();
    } else if (e.key === 'Enter' && e.target === document.body) {
      if (workbench.activeHitIndex >= 0) {
        e.preventDefault();
        workbench.selectHitByIndex(workbench.activeHitIndex, true);
      }
    } else if (e.key === '[') {
      navigateFile(-1, e.repeat);
    } else if (e.key === ']') {
      navigateFile(1, e.repeat);
    } else if (e.key === 'ArrowDown' || e.key === 'j') {
      if (workbench.flatHits.length > 0) {
        e.preventDefault();
        workbench.navigateHits(1, e.repeat);
      }
    } else if (e.key === 'ArrowUp' || e.key === 'k') {
      if (workbench.flatHits.length > 0) {
        e.preventDefault();
        workbench.navigateHits(-1, e.repeat);
      }
    }
  }

  let resizeRaf: number | null = null;
  let pendingResizeX = 0;

  function applyInspectorResizeWidth(clientX: number) {
    const fromRight = window.innerWidth - clientX;
    workbench.rightInspectorWidth = Math.max(300, Math.min(720, fromRight));
  }

  function startResizeInspector(e: PointerEvent) {
    e.preventDefault();
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    pendingResizeX = e.clientX;
    resizingInspector = true;
  }

  function handlePointerMove(e: PointerEvent) {
    if (!resizingInspector) return;
    pendingResizeX = e.clientX;
    if (resizeRaf !== null) return;
    resizeRaf = requestAnimationFrame(() => {
      resizeRaf = null;
      applyInspectorResizeWidth(pendingResizeX);
    });
  }

  function stopResize() {
    const wasResizing = resizingInspector;
    resizingInspector = false;
    if (resizeRaf !== null) {
      cancelAnimationFrame(resizeRaf);
      resizeRaf = null;
      if (wasResizing) {
        applyInspectorResizeWidth(pendingResizeX);
      }
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
  class={`relative flex h-app w-screen flex-col overflow-clip bg-background text-foreground ${
    resizingInspector ? 'select-none cursor-col-resize' : ''
  }`}
>
  {#if workbench.authState === 'checking'}
    <div class="flex flex-1 bg-background" aria-hidden="true"></div>
  {:else if workbench.authState === 'locked' || workbench.authState === 'unlocking'}
    <LoginView />
  {:else}
    <div
      onanimationend={() => {
        if (workbench.workspaceEnteredFromLogin) {
          workbench.workspaceEnteredFromLogin = false;
        }
      }}
      class={`flex flex-1 min-h-0 flex-col overflow-clip ${
        workbench.workspaceEnteredFromLogin ? 'workspace-unlock-enter' : ''
      }`}
    >
      {#if workbench.isCompact}
        <Header />
      {/if}

      <div class="relative flex flex-1 min-h-0 overflow-clip">
        <LeftScopeSidebar onFocusMainInput={() => searchInputEl?.focus()} />

        <main class="flex flex-1 flex-col min-w-0 min-h-0 overflow-clip">
          <SearchBar bind:inputEl={searchInputEl} hero={isHomeView} />
          {#if !isHomeView}
            <TelemetryBar />
            <ResultList />
          {/if}
        </main>

        {#if !isHomeView && workbench.inspectedPath}
          {#if workbench.isCompact}
            {#if workbench.detailOpen}
              <div class="detail-enter fixed inset-0 z-[45] bg-background">
                <InspectorPane />
              </div>
            {/if}
          {:else if workbench.rightInspectorOpen}
            <!-- svelte-ignore a11y_no_static_element_interactions -->
            <div
              onpointerdown={startResizeInspector}
              style="touch-action: none"
              class="relative w-[3px] -mr-[1px] shrink-0 cursor-col-resize bg-transparent hover:bg-primary/40 active:bg-primary/70 z-20 before:absolute before:inset-y-0 before:-inset-x-1.5 [@media(any-pointer:coarse)]:before:-inset-x-3"
              title={workbench.t.header.dragResizeInspector}
            ></div>
            <InspectorPane />
          {/if}
        {/if}

        <RightDrawer />
      </div>

      <CommandPalette />
    </div>
  {/if}
</div>
