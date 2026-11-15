<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import DrawerTemplate from './ui/DrawerTemplate.svelte';
  import GeneralPane from './settings/GeneralPane.svelte';
  import ShortcutsPane from './settings/ShortcutsPane.svelte';
  import SourcesPane from './settings/SourcesPane.svelte';
  import { Database, Keyboard, Plus, RotateCcw, SlidersHorizontal } from 'lucide-svelte';

  interface Props {
    mode: 'sources' | 'shortcuts' | 'settings';
  }

  let { mode }: Props = $props();
</script>

{#if mode === 'sources'}
  <DrawerTemplate
    icon={Database}
    title={workbench.t.settings.panelSourcesTitle}
    badge={`${workbench.enabledSourceCount}/${workbench.sources.length}`}
  >
    {#snippet headerActions()}
      <button
        type="button"
        onclick={() => (workbench.sourceAddOpen = !workbench.sourceAddOpen)}
        title={workbench.t.ui.addSource}
        aria-label={workbench.t.ui.addSource}
        aria-pressed={workbench.sourceAddOpen}
        class={`touch-target inline-flex h-7 items-center gap-1 rounded-md border px-2 text-xs font-medium cursor-pointer ${
          workbench.sourceAddOpen
            ? 'border-border bg-secondary text-foreground'
            : 'border-border/65 bg-card/80 text-foreground hover:bg-secondary/75 active:bg-secondary'
        }`}
      >
        <Plus class={`h-3.5 w-3.5 transition-transform ${workbench.sourceAddOpen ? 'rotate-45' : ''}`} />
        <span>{workbench.t.ui.addSource}</span>
      </button>
    {/snippet}

    <SourcesPane />
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
        title={workbench.t.settings.resetTitle}
        aria-label={workbench.t.settings.resetTitle}
        onclick={() => workbench.resetSettings()}
        class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/70 hover:text-foreground active:bg-secondary cursor-pointer"
      >
        <RotateCcw class="h-3.5 w-3.5" />
      </button>
    {/snippet}

    <GeneralPane />
  </DrawerTemplate>
{/if}
