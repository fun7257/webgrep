import type { Component, Snippet } from 'svelte';
import { workbench } from '$lib/state.svelte';
import type { LocaleMessages } from '$lib/i18n';
import type { HeadlessAdapter, ViewAdapterId } from '$lib/adapters/index.ts';
import type { DataSourceItem, FileResponse, HitItem } from '$lib/types';
import {
  copyTextToClipboard,
  type CodeHighlightSegment,
  type HighlightSegment,
  type StructuredAnalysis,
} from '$lib/utils';

export interface AdapterHost {
  readonly t: LocaleMessages;
  readonly hits: readonly HitItem[];
  readonly totalMatches: number;
  readonly activeHitIndex: number;
  readonly sourceByName: ReadonlyMap<string, DataSourceItem>;
  readonly collapsedFiles: ReadonlySet<string>;
  readonly currentSearchId: number;
  readonly scrollToActiveTick: number;
  readonly isSearching: boolean;
  readonly hasExecutableQuery: boolean;
  readonly isCompact: boolean;
  readonly isTouch: boolean;
  readonly rightInspectorOpen: boolean;
  readonly inspectedPath: string | null;
  readonly codeFontSize: number;
  readonly overscanPx: number;
  readonly wordWrap: boolean;
  readonly previewLines: number;
  readonly resultDensity: 'compact' | 'comfortable';
  readonly primaryPattern: string;
  readonly contains: readonly string[];
  readonly searchMode: 'literal' | 'multi' | 'regex';

  selectHitByIndex(index: number, forceOpenInspector?: boolean, deferInspector?: boolean): void;
  previewSelectHitByIndex(index: number): void;
  appendTerm(term: string): void;
  excludeTerm(term: string): void;
  replaceQuery(term: string): void;
  soloSource(name: string): void;
  excludeSource(name: string): void;
  toggleSource(name: string): void;
  scopeSourceFromMenu(name: string, exclude: boolean): void;
  toggleFileGroupCollapse(filePath: string): void;
  setAllGroupsCollapsed(collapsed: boolean): void;
  openContextDrawer(filePath?: string, line?: number, anchorByteHint?: number | null): void;
  refreshSearch(forceRefresh?: boolean): void;
  copyText(text: string): void;
}

export function createWorkbenchAdapterHost(): AdapterHost {
  return {
    get t() {
      return workbench.t;
    },
    get hits() {
      return workbench.flatHits;
    },
    get totalMatches() {
      return workbench.totalMatches;
    },
    get activeHitIndex() {
      return workbench.activeHitIndex;
    },
    get sourceByName() {
      return workbench.sourceByName;
    },
    get collapsedFiles() {
      return workbench.collapsedFilesSet;
    },
    get currentSearchId() {
      return workbench.currentSearchId;
    },
    get scrollToActiveTick() {
      return workbench.scrollToActiveTick;
    },
    get isSearching() {
      return workbench.isSearching;
    },
    get hasExecutableQuery() {
      return workbench.hasExecutableQuery;
    },
    get isCompact() {
      return workbench.isCompact;
    },
    get isTouch() {
      return workbench.isTouch;
    },
    get rightInspectorOpen() {
      return workbench.rightInspectorOpen;
    },
    get inspectedPath() {
      return workbench.inspectedPath;
    },
    get codeFontSize() {
      return workbench.codeFontSize;
    },
    get overscanPx() {
      return workbench.frameProfile.overscanPx;
    },
    get wordWrap() {
      return workbench.wordWrap;
    },
    get previewLines() {
      return workbench.previewLines;
    },
    get resultDensity() {
      return workbench.resultDensity;
    },
    get primaryPattern() {
      return workbench.primaryPattern;
    },
    get contains() {
      return workbench.contains;
    },
    get searchMode() {
      return workbench.mode;
    },

    selectHitByIndex(index, forceOpenInspector = false, deferInspector = false) {
      workbench.selectHitByIndex(index, forceOpenInspector, deferInspector);
    },
    previewSelectHitByIndex(index) {
      workbench.previewSelectHitByIndex(index);
    },
    appendTerm(term) {
      workbench.appendSearchTerm(term);
    },
    excludeTerm(term) {
      workbench.excludeSearchTerm(term);
    },
    replaceQuery(term) {
      workbench.replaceSearchWithLiteral(term);
    },
    soloSource(name) {
      workbench.selectSingleScopeSourceByName(name);
    },
    excludeSource(name) {
      workbench.toggleExcludeScopeSourceByName(name);
    },
    toggleSource(name) {
      workbench.toggleScopeSourceByName(name);
    },
    scopeSourceFromMenu(name, exclude) {
      workbench.scopeSourceFromMenu(name, exclude);
    },
    toggleFileGroupCollapse(filePath) {
      workbench.toggleFileGroupCollapse(filePath);
    },
    setAllGroupsCollapsed(collapsed) {
      workbench.setAllGroupsCollapsed(collapsed);
    },
    openContextDrawer(filePath, line, anchorByteHint) {
      void workbench.openContextDrawer(filePath, line, anchorByteHint);
    },
    refreshSearch(forceRefresh = true) {
      workbench.executeSearch({ forceRefresh });
    },
    copyText(text) {
      copyTextToClipboard(text);
    },
  };
}

export interface AdapterResultsProps {
  host: AdapterHost;
}

export interface AdapterInspectorProps {
  host: AdapterHost;
  activeHit: HitItem | null;
  activeLineText: string;
  targetLine: number;
  inspectedPath: string;
  fileData: FileResponse | null;
  loading: boolean;
  inspectorTab: 'structured' | 'raw';
  recordKey: string;
  structuredInfo: StructuredAnalysis;
  rawLineSegments: HighlightSegment[];
  highlightFormattedText: (text: string) => HighlightSegment[];
  renderCodeSegments: Snippet<[CodeHighlightSegment[]]>;
}

export interface PresentationAdapter extends HeadlessAdapter {
  readonly id: ViewAdapterId;
  readonly meta: {
    icon: Component<{ class?: string }>;
    label: (t: LocaleMessages) => string;
    title: (t: LocaleMessages) => string;
  };
  readonly ResultsView: Component<AdapterResultsProps>;
  readonly InspectorView: Component<AdapterInspectorProps>;
}
