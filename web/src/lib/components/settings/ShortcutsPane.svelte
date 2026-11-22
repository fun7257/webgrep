<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import { Keyboard, Navigation, Search } from 'lucide-svelte';

  const groups = $derived([
    { id: 'syntax', icon: Search, title: workbench.t.settings.groupSyntax },
    { id: 'nav', icon: Navigation, title: workbench.t.settings.groupNav },
    { id: 'panel', icon: Keyboard, title: workbench.t.settings.groupPanel },
  ] as const);

  const groupedItems = $derived(
    groups.map((grp) => ({
      ...grp,
      items: workbench.t.shortcuts.items.filter((it) => it.group === grp.id),
    })),
  );
</script>

<div class="space-y-4">
  {#each groupedItems as grp (grp.id)}
    {@const GroupIcon = grp.icon}
    {#if grp.items.length > 0}
      <div>
        <div
          class="mb-1.5 flex items-center gap-1.5 px-0.5 text-[11.5px] font-medium text-muted-foreground"
          title={grp.title}
        >
          <GroupIcon class="h-3.5 w-3.5 shrink-0 text-muted-foreground/75" aria-hidden="true" />
          <span>{grp.title}</span>
        </div>
        <div class="rounded-xl border border-border/55 bg-card/55 dark:bg-card/50 divide-y divide-border/40 px-3.5">
          {#each grp.items as it (it.key)}
            <div class="flex min-h-10 items-center justify-between gap-3 py-1.5" title={it.desc}>
              <span class="min-w-0 flex-1 truncate text-[13px] text-foreground/90">{it.desc}</span>
              <kbd
                class="inline-flex h-[22px] min-w-[24px] shrink-0 items-center justify-center whitespace-nowrap rounded-md border border-border/75 bg-background px-1.5 font-mono text-[11px] font-medium text-foreground/85 shadow-[0_1px_0_hsl(var(--border))]"
              >
                {it.key}
              </kbd>
            </div>
          {/each}
        </div>
      </div>
    {/if}
  {/each}
</div>
