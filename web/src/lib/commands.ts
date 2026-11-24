import type { Component } from 'svelte';
import {
  Blocks,
  Database,
  Eraser,
  Keyboard,
  Languages,
  Lock,
  PanelLeft,
  PanelRight,
  SlidersHorizontal,
  SunMoon,
  UnfoldVertical,
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
      id: 'sources',
      icon: Database as unknown as Command['icon'],
      title: p.sources,
      run: () => workbench.openSourcesDrawer(workbench.sources.length === 0),
    },
    {
      id: 'mcp',
      icon: Blocks as unknown as Command['icon'],
      title: p.mcp,
      run: () => workbench.openMcpDrawer(),
    },
    {
      id: 'shortcuts',
      icon: Keyboard as unknown as Command['icon'],
      title: p.shortcuts,
      shortcut: '?',
      run: () => workbench.openShortcutsDrawer(),
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
    ...(workbench.isCompact
      ? [
          {
            id: 'toggle-scope',
            icon: PanelLeft as unknown as Command['icon'],
            title: workbench.t.header.toggleSidebar,
            run: () => workbench.toggleScopeSidebar(),
          },
        ]
      : []),
    ...(workbench.hasActiveScope
      ? [
          {
            id: 'clear-scope',
            icon: Eraser as unknown as Command['icon'],
            title: workbench.t.scopeBar.clearAllScope,
            run: () => workbench.clearScopeAll(),
          },
        ]
      : []),
    ...(!workbench.isCompact && workbench.flatHits.length > 0
      ? [
          {
            id: 'inspector',
            icon: PanelRight as unknown as Command['icon'],
            title: p.inspector,
            run: () => workbench.toggleInspectorPane(),
          },
        ]
      : []),
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
