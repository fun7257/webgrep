<script lang="ts">
  import { onDestroy } from 'svelte';
  import { workbench, type DrawerPanelId } from '$lib/state.svelte';
  import ContextDrawerPane from './ContextDrawerPane.svelte';
  import DrawerTemplate from './ui/DrawerTemplate.svelte';
  import GeneralPane from './settings/GeneralPane.svelte';
  import McpPane from './settings/McpPane.svelte';
  import ShortcutsPane from './settings/ShortcutsPane.svelte';
  import SourcesPane from './settings/SourcesPane.svelte';
  import { Blocks, Check, Database, Keyboard, Plus, RefreshCw, RotateCcw, SlidersHorizontal } from 'lucide-svelte';

  interface Props {
    mode: DrawerPanelId;
  }

  let { mode }: Props = $props();

  let resetArmed = $state(false);
  let resetDone = $state(false);
  let resetArmTimer: ReturnType<typeof setTimeout> | null = null;
  let resetDoneTimer: ReturnType<typeof setTimeout> | null = null;

  function clearResetTimers() {
    if (resetArmTimer !== null) {
      clearTimeout(resetArmTimer);
      resetArmTimer = null;
    }
    if (resetDoneTimer !== null) {
      clearTimeout(resetDoneTimer);
      resetDoneTimer = null;
    }
  }

  onDestroy(() => {
    clearResetTimers();
  });

  $effect(() => {
    if (mode !== 'settings') {
      resetArmed = false;
      resetDone = false;
      clearResetTimers();
    }
  });

  function onResetClick() {
    if (resetArmed) {
      if (resetArmTimer !== null) {
        clearTimeout(resetArmTimer);
        resetArmTimer = null;
      }
      resetArmed = false;
      workbench.resetSettings();
      resetDone = true;
      if (resetDoneTimer !== null) clearTimeout(resetDoneTimer);
      resetDoneTimer = setTimeout(() => {
        resetDone = false;
        resetDoneTimer = null;
      }, 1500);
      return;
    }
    resetDone = false;
    resetArmed = true;
    if (resetArmTimer !== null) clearTimeout(resetArmTimer);
    resetArmTimer = setTimeout(() => {
      resetArmed = false;
      resetArmTimer = null;
    }, 3000);
  }
</script>

{#if mode === 'context'}
  <ContextDrawerPane />
{:else if mode === 'sources'}
  <DrawerTemplate
    icon={Database}
    title={workbench.t.settings.panelSourcesTitle}
    badge={`${workbench.enabledSourceCount}/${workbench.sources.length}`}
    badgeTitle={workbench.t.ui.sourcesCount}
  >
    {#snippet headerActions()}
      {#if !workbench.sourceAddOpen}
        <button
          type="button"
          onclick={() => (workbench.sourceAddOpen = true)}
          title={workbench.t.ui.addSource}
          aria-label={workbench.t.ui.addSource}
          class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/70 hover:text-foreground active:bg-secondary cursor-pointer"
        >
          <Plus class="h-3.5 w-3.5 transition-transform duration-[var(--motion-switch,67ms)]" />
        </button>
      {/if}
    {/snippet}

    <SourcesPane />
  </DrawerTemplate>
{:else if mode === 'mcp'}
  <DrawerTemplate icon={Blocks} title={workbench.t.settings.panelMcpTitle}>
    {#snippet headerActions()}
      <button
        type="button"
        disabled={workbench.mcpLoading}
        title={workbench.t.mcp.refreshTitle}
        aria-label={workbench.t.mcp.refreshTitle}
        onclick={() => workbench.fetchMcpState()}
        class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/70 hover:text-foreground active:bg-secondary disabled:opacity-60 cursor-pointer"
      >
        <RefreshCw class={`h-3.5 w-3.5 ${workbench.mcpLoading ? 'animate-spin' : ''}`} />
      </button>
    {/snippet}

    <McpPane />
  </DrawerTemplate>
{:else if mode === 'shortcuts'}
  <DrawerTemplate icon={Keyboard} title={workbench.t.settings.panelShortcutsTitle}>
    <ShortcutsPane />
  </DrawerTemplate>
{:else}
  <DrawerTemplate icon={SlidersHorizontal} title={workbench.t.settings.panelSettingsTitle}>
    {#snippet headerActions()}
      <button
        type="button"
        title={resetArmed
          ? workbench.locale === 'zh'
            ? '再次点击确认恢复默认设置'
            : 'Click again to reset to defaults'
          : workbench.t.settings.resetTitle}
        aria-label={resetArmed
          ? workbench.locale === 'zh'
            ? '确认重置?'
            : 'Reset?'
          : workbench.t.settings.resetTitle}
        onclick={onResetClick}
        class={`touch-target inline-flex h-7 items-center justify-center rounded-md cursor-pointer ${
          resetArmed
            ? 'bg-status/15 px-2 text-[11px] font-medium text-status hover:bg-status/20 active:bg-status/25'
            : resetDone
              ? 'w-7 text-primary'
              : 'w-7 text-muted-foreground/75 hover:bg-secondary/70 hover:text-foreground active:bg-secondary'
        }`}
      >
        {#if resetArmed}
          <span>{workbench.locale === 'zh' ? '确认重置?' : 'Reset?'}</span>
        {:else if resetDone}
          <Check class="h-3.5 w-3.5" />
        {:else}
          <RotateCcw class="h-3.5 w-3.5" />
        {/if}
      </button>
    {/snippet}

    <GeneralPane />
  </DrawerTemplate>
{/if}
