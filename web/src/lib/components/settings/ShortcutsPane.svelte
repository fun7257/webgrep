<script lang="ts">
  import { workbench } from '$lib/state.svelte';

  const groups = $derived([
    { id: 'syntax', title: workbench.t.settings.groupSyntax },
    { id: 'nav', title: workbench.t.settings.groupNav },
    { id: 'panel', title: workbench.t.settings.groupPanel },
  ] as const);
</script>

<div>
  {#each groups as grp, idx (grp.id)}
    {#if idx > 0}
      <div class="my-2.5 border-t border-border/60"></div>
    {/if}
    <div class="mb-1 text-xs text-muted-foreground">{grp.title}</div>
    <div class="space-y-0.5">
      {#each workbench.t.shortcuts.items.filter((it) => it.group === grp.id) as it (it.key)}
        <div class="flex min-h-8 items-center justify-between gap-3 py-1">
          <span class="text-[13px] text-foreground">{it.desc}</span>
          <kbd
            class="shrink-0 rounded border border-border/80 bg-secondary/70 px-1.5 py-0.5 font-mono text-[11.5px] text-foreground"
            >{it.key}</kbd
          >
        </div>
      {/each}
    </div>
  {/each}
</div>
