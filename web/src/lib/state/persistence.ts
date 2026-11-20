import type {
  DataSourceItem,
  QueryStep,
  SearchHistoryEntry,
  TimePreset,
  ViewModePreference,
} from '../types.ts';
import type { Locale } from '../i18n.ts';
import {
  DEFAULT_CONTEXT_AUTO_LOAD_PACE,
  DEFAULT_CONTEXT_STEP_LINES,
  DEFAULT_INITIAL_CONTEXT_LINES,
  clampContextLineSetting,
  normalizeContextAutoLoadPace,
  type ContextAutoLoadPace,
} from '../context-window.ts';
import { DEFAULT_MCP_MAX_LOGS, clampMcpMaxLogs } from '../mcp.ts';
import { createQueryStep } from '../query.ts';

export const HISTORY_STORAGE_KEY = 'webgrep.searchHistory.v2';
export const THEME_STORAGE_KEY = 'webgrep.theme.v1';
export const SETTINGS_STORAGE_KEY = 'webgrep.settings.v3';
export const LEGACY_SETTINGS_KEYS = ['webgrep.settings.v2'] as const;
export const SOURCES_CACHE_STORAGE_KEY = 'webgrep.sourcesCache.v1';
export const MAX_SEARCH_HISTORY = 20;

export interface StorageLike {
  getItem(key: string): string | null;
  setItem?(key: string, value: string): void;
  removeItem?(key: string): void;
}

export interface PersistedSettings {
  locale: Locale;
  tenant: string;
  respectIgnore: boolean;
  hidden: boolean;
  previewLines: number;
  contextInitialLines: number;
  contextStepLines: number;
  contextAutoLoadPace: ContextAutoLoadPace;
  mcpMaxLogs: number;
  maxResults: number;
  codeFontSize: number;
  wordWrap: boolean;
  resultDensity: 'compact' | 'comfortable';
  viewMode: ViewModePreference;
}

export const DEFAULT_PERSISTED_SETTINGS: Readonly<PersistedSettings> = {
  locale: 'zh',
  tenant: 'default',
  respectIgnore: false,
  hidden: false,
  previewLines: 3,
  contextInitialLines: DEFAULT_INITIAL_CONTEXT_LINES,
  contextStepLines: DEFAULT_CONTEXT_STEP_LINES,
  contextAutoLoadPace: DEFAULT_CONTEXT_AUTO_LOAD_PACE,
  mcpMaxLogs: DEFAULT_MCP_MAX_LOGS,
  maxResults: 20000,
  codeFontSize: 13.5,
  wordWrap: true,
  resultDensity: 'comfortable',
  viewMode: 'auto',
};

export function getBrowserLocalStorage(): StorageLike | null {
  try {
    return typeof window !== 'undefined' ? window.localStorage : null;
  } catch {
    return null;
  }
}

export function getBrowserSessionStorage(): StorageLike | null {
  try {
    return typeof window !== 'undefined' ? window.sessionStorage : null;
  } catch {
    return null;
  }
}

/** Reads the first non-empty key across primary and fallback storage backends. */
export function readStorageWithFallback(
  primary: StorageLike | undefined | null,
  fallback: StorageLike | undefined | null,
  keys: readonly string[]
): string | null {
  for (const k of keys) {
    try {
      const v = primary?.getItem(k);
      if (v) return v;
    } catch {
      // ignore storage errors
    }
  }
  for (const k of keys) {
    try {
      const v = fallback?.getItem(k);
      if (v) return v;
    } catch {
      // ignore storage errors
    }
  }
  return null;
}

/** Sanitizes a tenant identifier into safe ASCII characters with `'default'` fallback. */
export function sanitizeTenantId(nextTenant: string): string {
  return (
    nextTenant
      .trim()
      .replace(/[^a-zA-Z0-9._-]/g, '-')
      .slice(0, 64) || 'default'
  );
}

/** Normalizes a stored theme flag (`'light'` -> `false`, anything else -> `true`). */
export function normalizeThemeDarkMode(saved: string | null | undefined): boolean {
  return saved === 'light' ? false : true;
}

export function loadThemeFromStorage(
  primary: StorageLike | undefined | null,
  fallback: StorageLike | undefined | null
): boolean {
  try {
    const saved = readStorageWithFallback(primary, fallback, [THEME_STORAGE_KEY]);
    return normalizeThemeDarkMode(saved);
  } catch {
    return true;
  }
}

export function saveThemeToStorage(
  storage: StorageLike | undefined | null,
  darkMode: boolean
): void {
  try {
    storage?.setItem?.(THEME_STORAGE_KEY, darkMode ? 'dark' : 'light');
  } catch {
    // ignore storage errors
  }
}

/** Validates and clamps persisted settings JSON against defaults. */
export function normalizeSettings(
  raw: unknown,
  fallback: PersistedSettings = DEFAULT_PERSISTED_SETTINGS
): PersistedSettings {
  const base: PersistedSettings = { ...fallback };
  if (!raw || typeof raw !== 'object') return base;
  const s = raw as Record<string, unknown>;

  if (typeof s.respectIgnore === 'boolean') base.respectIgnore = s.respectIgnore;
  if (typeof s.hidden === 'boolean') base.hidden = s.hidden;
  if (typeof s.previewLines === 'number' && Number.isFinite(s.previewLines)) {
    base.previewLines = Math.max(1, Math.min(6, Math.round(s.previewLines)));
  }
  if (typeof s.contextInitialLines === 'number') {
    base.contextInitialLines = clampContextLineSetting(
      s.contextInitialLines,
      fallback.contextInitialLines
    );
  }
  if (typeof s.contextStepLines === 'number') {
    base.contextStepLines = clampContextLineSetting(
      s.contextStepLines,
      fallback.contextStepLines
    );
  }
  base.contextAutoLoadPace = normalizeContextAutoLoadPace(
    s.contextAutoLoadPace,
    DEFAULT_CONTEXT_AUTO_LOAD_PACE
  );
  if (typeof s.maxResults === 'number' && Number.isFinite(s.maxResults)) {
    base.maxResults = Math.max(1, Math.min(500000, Math.round(s.maxResults)));
  }
  if (typeof s.codeFontSize === 'number' && Number.isFinite(s.codeFontSize)) {
    base.codeFontSize = Math.max(10, Math.min(28, s.codeFontSize));
  }
  if (typeof s.wordWrap === 'boolean') base.wordWrap = s.wordWrap;
  if (s.resultDensity === 'compact' || s.resultDensity === 'comfortable') {
    base.resultDensity = s.resultDensity;
  }
  if (
    s.viewMode === 'auto' ||
    s.viewMode === 'log' ||
    s.viewMode === 'code' ||
    s.viewMode === 'plain'
  ) {
    base.viewMode = s.viewMode;
  }
  if (s.locale === 'zh' || s.locale === 'en') {
    base.locale = s.locale;
  }
  if (typeof s.mcpMaxLogs === 'number') {
    base.mcpMaxLogs = clampMcpMaxLogs(s.mcpMaxLogs, DEFAULT_MCP_MAX_LOGS);
  }
  if (typeof s.tenant === 'string' && s.tenant.trim().length > 0) {
    base.tenant = s.tenant.trim();
  }
  return base;
}

export function loadSettingsFromStorage(
  primary: StorageLike | undefined | null,
  fallback: StorageLike | undefined | null,
  defaults: PersistedSettings = DEFAULT_PERSISTED_SETTINGS
): PersistedSettings | null {
  try {
    const raw = readStorageWithFallback(primary, fallback, [
      SETTINGS_STORAGE_KEY,
      ...LEGACY_SETTINGS_KEYS,
    ]);
    if (!raw) return null;
    return normalizeSettings(JSON.parse(raw), defaults);
  } catch {
    return null;
  }
}

export function saveSettingsToStorage(
  storage: StorageLike | undefined | null,
  settings: PersistedSettings
): void {
  try {
    storage?.setItem?.(SETTINGS_STORAGE_KEY, JSON.stringify(settings));
  } catch {
    // ignore storage errors
  }
}

/** Validates and caps stored search history entries at `MAX_SEARCH_HISTORY`. */
export function normalizeHistoryEntries(raw: unknown): SearchHistoryEntry[] {
  if (!Array.isArray(raw)) return [];
  const valid: SearchHistoryEntry[] = [];
  for (const item of raw) {
    if (
      item &&
      typeof item === 'object' &&
      typeof (item as SearchHistoryEntry).id === 'string' &&
      typeof (item as SearchHistoryEntry).label === 'string' &&
      Array.isArray((item as SearchHistoryEntry).steps) &&
      (item as SearchHistoryEntry).scope &&
      typeof (item as SearchHistoryEntry).scope === 'object'
    ) {
      const rec = item as SearchHistoryEntry;
      valid.push({
        id: rec.id,
        steps: rec.steps.map((s: QueryStep) =>
          createQueryStep(String(s?.text ?? ''), s && typeof s === 'object' ? s : {})
        ),
        draft: rec.draft
          ? createQueryStep(
              String(rec.draft.text ?? ''),
              typeof rec.draft === 'object' ? rec.draft : {}
            )
          : null,
        scope: {
          sources: Array.isArray(rec.scope.sources) ? rec.scope.sources : [],
          excludedSources: Array.isArray(rec.scope.excludedSources)
            ? rec.scope.excludedSources
            : [],
          types: [],
          timePreset: (rec.scope.timePreset || '') as TimePreset,
        },
        label: rec.label,
        timestamp: typeof rec.timestamp === 'number' ? rec.timestamp : Date.now(),
      });
    }
    if (valid.length >= MAX_SEARCH_HISTORY) break;
  }
  return valid;
}

export function loadHistoryFromStorage(
  storage: StorageLike | undefined | null
): SearchHistoryEntry[] {
  try {
    const raw = storage?.getItem(HISTORY_STORAGE_KEY);
    if (!raw) return [];
    return normalizeHistoryEntries(JSON.parse(raw));
  } catch {
    return [];
  }
}

export function saveHistoryToStorage(
  storage: StorageLike | undefined | null,
  entries: readonly SearchHistoryEntry[]
): void {
  try {
    storage?.setItem?.(
      HISTORY_STORAGE_KEY,
      JSON.stringify(entries.slice(0, MAX_SEARCH_HISTORY))
    );
  } catch {
    // ignore storage errors
  }
}

export function clearHistoryFromStorage(storage: StorageLike | undefined | null): void {
  try {
    storage?.removeItem?.(HISTORY_STORAGE_KEY);
  } catch {
    // ignore storage errors
  }
}

export function upsertHistoryEntry(
  history: readonly SearchHistoryEntry[],
  entry: SearchHistoryEntry,
  maxEntries = MAX_SEARCH_HISTORY
): SearchHistoryEntry[] {
  const filtered = history.filter((h) => h.id !== entry.id);
  return [entry, ...filtered].slice(0, maxEntries);
}

/** Validates cached `DataSourceItem[]` parsed from localStorage. */
export function normalizeCachedSources(raw: unknown): DataSourceItem[] {
  if (!Array.isArray(raw)) return [];
  const valid: DataSourceItem[] = [];
  for (const item of raw) {
    if (
      item &&
      typeof item === 'object' &&
      typeof (item as DataSourceItem).id === 'string' &&
      typeof (item as DataSourceItem).name === 'string' &&
      typeof (item as DataSourceItem).enabled === 'boolean' &&
      typeof (item as DataSourceItem).exists === 'boolean'
    ) {
      valid.push(item as DataSourceItem);
    }
  }
  return valid;
}

export function loadCachedSourcesFromStorage(
  storage: StorageLike | undefined | null
): DataSourceItem[] {
  try {
    const raw = storage?.getItem(SOURCES_CACHE_STORAGE_KEY);
    if (!raw) return [];
    return normalizeCachedSources(JSON.parse(raw));
  } catch {
    return [];
  }
}

export function saveCachedSourcesToStorage(
  storage: StorageLike | undefined | null,
  sources: readonly DataSourceItem[]
): void {
  try {
    storage?.setItem?.(SOURCES_CACHE_STORAGE_KEY, JSON.stringify(sources));
  } catch {
    // ignore storage errors
  }
}
