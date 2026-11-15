<script lang="ts">
  import { workbench } from '$lib/state.svelte';

  const groups = $derived([
    { id: 'syntax', title: workbench.t.settings.groupSyntax },
    { id: 'nav', title: workbench.t.settings.groupNav },
    { id: 'panel', title: workbench.t.settings.groupPanel },
  ] as const);
</script>

<div class="space-y-4">
  {#each groups as grp (grp.id)}
    <div>
      <div class="mb-1.5 px-0.5 text-[11.5px] font-medium text-muted-foreground">
        {grp.title}
      </div>
      <div class="rounded-xl border border-border/55 bg-card/55 dark:bg-card/50 divide-y divide-border/40 px-3.5">
        {#each workbench.t.shortcuts.items.filter((it) => it.group === grp.id) as it (it.key)}
          <div class="flex min-h-10 items-center justify-between gap-3 py-1.5">
            <span class="text-[13px] text-foreground/90">{it.desc}</span>
            <kbd
              class="inline-flex min-h-[22px] min-w-[24px] shrink-0 items-center justify-center rounded-md border border-border/75 bg-background px-1.5 py-0.5 font-mono text-[11px] font-medium text-foreground/85 shadow-[0_1px_0_hsl(var(--border))]"
            >
              {it.key}
            </kbd>
          </div>
        {/each}
      </div>
    </div>
  {/each}
</div>
