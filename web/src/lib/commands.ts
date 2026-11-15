import type { Component } from 'svelte';
import {
  Clock,
  Database,
  FolderPlus,
  Keyboard,
  Languages,
  PanelRight,
  SlidersHorizontal,
  SunMoon,
} from 'lucide-svelte';
import { workbench } from './state.svelte';

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
  ];
}
