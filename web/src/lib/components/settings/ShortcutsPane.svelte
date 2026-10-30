<script lang="ts">
  import { workbench } from '$lib/state.svelte';

  const groups = $derived([
    { id: 'syntax', title: workbench.t.settings.groupSyntax },
    { id: 'nav', title: workbench.t.settings.groupNav },
    { id: 'panel', title: workbench.t.settings.groupPanel },
  ] as const);
</script>

<div class="space-y-5">
  {#each groups as grp (grp.id)}
    <div>
      <div class="mb-1 text-[11px] font-medium text-muted-foreground">{grp.title}</div>
      <div class="divide-y divide-border/50">
        {#each workbench.t.shortcuts.items.filter((it) => it.group === grp.id) as it (it.key)}
          <div class="flex min-h-10 items-center justify-between gap-3 py-1.5">
            <span class="text-foreground/90">{it.desc}</span>
            <kbd
              class="shrink-0 rounded border border-border bg-secondary px-1.5 py-0.5 font-mono text-[11px] text-foreground"
              >{it.key}</kbd
            >
          </div>
        {/each}
      </div>
    </div>
  {/each}
</div>
