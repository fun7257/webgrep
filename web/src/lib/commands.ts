import type { Component } from 'svelte';
import {
  Blocks,
  Clock,
  Database,
  FolderPlus,
  Keyboard,
  Languages,
  Layers,
  Lock,
  PanelRight,
  SlidersHorizontal,
  SunMoon,
  UnfoldVertical,
} from 'lucide-svelte';
import { workbench } from './state.svelte';
import { VIEW_MODE_CYCLE_ORDER } from './adapters/index.ts';

export interface Command {
  id: string;
  /** lucide icon component */
  icon: Component<{ class?: string }>;
  title: string;
  shortcut?: string;
  run: () => void;
}

/** Built lazily so titles follow the active locale. */
export function buildCommands(): Command[] {
  const p = workbench.t.palette;
  return [
    {
      id: 'settings',
      icon: SlidersHorizontal as unknown as Command['icon'],
      title: p.settings,
      shortcut: '⌘,',
      run: () => workbench.openSettingsDrawer(),
    },
    {
      id: 'pick-sources',
      icon: Database as unknown as Command['icon'],
      title: p.pickSources,
      run: () => workbench.openSourcePicker(),
    },
    {
      id: 'pick-time',
      icon: Clock as unknown as Command['icon'],
      title: p.pickTime,
      run: () => workbench.openTimePicker(),
    },
    {
      id: 'sources',
      icon: Database as unknown as Command['icon'],
      title: p.sources,
      run: () => workbench.openSourcesDrawer(false),
    },
    {
      id: 'add-source',
      icon: FolderPlus as unknown as Command['icon'],
      title: p.addSource,
      run: () => workbench.openSourcesDrawer(true),
    },
    {
      id: 'mcp',
      icon: Blocks as unknown as Command['icon'],
      title: p.mcp,
      run: () => workbench.openMcpDrawer(),
    },
    {
      id: 'theme',
      icon: SunMoon as unknown as Command['icon'],
      title: p.theme,
      run: () => workbench.toggleTheme(),
    },
    {
      id: 'language',
      icon: Languages as unknown as Command['icon'],
      title: p.language,
      run: () => workbench.toggleLocale(),
    },
    {
      id: 'shortcuts',
      icon: Keyboard as unknown as Command['icon'],
      title: p.shortcuts,
      shortcut: '?',
      run: () => workbench.openShortcutsDrawer(),
    },
    {
      id: 'inspector',
      icon: PanelRight as unknown as Command['icon'],
      title: p.inspector,
      run: () => workbench.toggleInspectorPane(),
    },
    {
      id: 'cycle-view-mode',
      icon: Layers as unknown as Command['icon'],
      title: p.cycleViewMode,
      run: () => {
        const order = VIEW_MODE_CYCLE_ORDER;
        const next = order[(order.indexOf(workbench.viewMode) + 1) % order.length];
        workbench.setViewMode(next);
      },
    },
    ...(workbench.inspectedPath
      ? [
          {
            id: 'context-drawer',
            icon: UnfoldVertical as unknown as Command['icon'],
            title: p.contextDrawer,
            run: () => workbench.openContextDrawer(),
          },
        ]
      : []),
    ...(workbench.authRequired
      ? [
          {
            id: 'lock-workspace',
            icon: Lock as unknown as Command['icon'],
            title: p.lock,
            run: () => void workbench.logout(),
          },
        ]
      : []),
  ];
}
