import { Code2, ScrollText } from 'lucide-svelte';
import {
  codeAdapter,
  logAdapter,
  type ViewAdapterId,
} from '$lib/adapters/index.ts';
import LogResultsView from './log/LogResultsView.svelte';
import LogInspectorView from './log/LogInspectorView.svelte';
import CodeResultsView from './code/CodeResultsView.svelte';
import CodeInspectorView from './code/CodeInspectorView.svelte';
import type { PresentationAdapter } from './types.ts';

export const logPresentationAdapter: PresentationAdapter = {
  ...logAdapter,
  meta: {
    icon: ScrollText as unknown as PresentationAdapter['meta']['icon'],
    label: (t) => t.ui.sourcePrefilterPresets.timeseries.label,
    title: (t) => t.logView.modeLogTitle,
  },
  ResultsView: LogResultsView,
  InspectorView: LogInspectorView,
};

export const codePresentationAdapter: PresentationAdapter = {
  ...codeAdapter,
  meta: {
    icon: Code2 as unknown as PresentationAdapter['meta']['icon'],
    label: (t) => t.ui.sourcePrefilterPresets.code.label,
    title: (t) => t.logView.modeCodeTitle,
  },
  ResultsView: CodeResultsView,
  InspectorView: CodeInspectorView,
};

export const PRESENTATION_ADAPTERS: readonly PresentationAdapter[] = [
  logPresentationAdapter,
  codePresentationAdapter,
];

const PRESENTATION_BY_ID = new Map<ViewAdapterId, PresentationAdapter>(
  PRESENTATION_ADAPTERS.map((a) => [a.id, a])
);

export function getPresentationAdapter(id: ViewAdapterId): PresentationAdapter {
  return PRESENTATION_BY_ID.get(id) ?? logPresentationAdapter;
}
