import { Code2, FileText, ScrollText } from 'lucide-svelte';
import {
  codeAdapter,
  logAdapter,
  plainAdapter,
  type ViewAdapterId,
} from '$lib/adapters/index.ts';
import LogResultsView from './log/LogResultsView.svelte';
import LogInspectorView from './log/LogInspectorView.svelte';
import CodeResultsView from './code/CodeResultsView.svelte';
import CodeInspectorView from './code/CodeInspectorView.svelte';
import PlainResultsView from './plain/PlainResultsView.svelte';
import PlainInspectorView from './plain/PlainInspectorView.svelte';
import type { PresentationAdapter } from './types.ts';

export const logPresentationAdapter: PresentationAdapter = {
  ...logAdapter,
  meta: {
    icon: ScrollText as unknown as PresentationAdapter['meta']['icon'],
    label: (t) => t.settings.viewModeLog,
    title: (t) => t.logView.modeLogTitle,
  },
  ResultsView: LogResultsView,
  InspectorView: LogInspectorView,
};

export const codePresentationAdapter: PresentationAdapter = {
  ...codeAdapter,
  meta: {
    icon: Code2 as unknown as PresentationAdapter['meta']['icon'],
    label: (t) => t.settings.viewModeCode,
    title: (t) => t.logView.modeCodeTitle,
  },
  ResultsView: CodeResultsView,
  InspectorView: CodeInspectorView,
};

export const plainPresentationAdapter: PresentationAdapter = {
  ...plainAdapter,
  meta: {
    icon: FileText as unknown as PresentationAdapter['meta']['icon'],
    label: (t) => t.settings.viewModePlain,
    title: (t) => t.logView.modePlainTitle,
  },
  ResultsView: PlainResultsView,
  InspectorView: PlainInspectorView,
};

export const PRESENTATION_ADAPTERS: readonly PresentationAdapter[] = [
  logPresentationAdapter,
  codePresentationAdapter,
  plainPresentationAdapter,
];

const PRESENTATION_BY_ID = new Map<ViewAdapterId, PresentationAdapter>(
  PRESENTATION_ADAPTERS.map((a) => [a.id, a])
);

export function getPresentationAdapter(id: ViewAdapterId): PresentationAdapter {
  return PRESENTATION_BY_ID.get(id) ?? plainPresentationAdapter;
}
