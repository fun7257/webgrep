import type {
  DataSourceItem,
  MetaResponse,
  PluginMetadata,
  PluginOverrides,
  PluginPreset,
  PrefilterStage,
} from './types.ts';
import { formatBytes } from './utils.ts';

export const PLUGIN_PRESETS: readonly PluginPreset[] = ['auto', 'timeseries', 'code', 'raw'];
export const DEFAULT_PLUGIN_PRESET: PluginPreset = 'auto';

const PLUGIN_PRESET_SET = new Set<string>(PLUGIN_PRESETS);
const PREFILTER_STAGE_SET = new Set<string>([
  'source_plan',
  'file_prune',
  'window_narrow',
  'line_filter',
]);

export interface NormalizedPluginOverrides {
  enable: string[];
  disable: string[];
}

export interface NormalizedPresetMetadata {
  id: PluginPreset;
  nameKey: string;
  description: string;
}

export interface NormalizedPluginMetadata {
  id: string;
  nameKey: string;
  description: string;
  stages: PrefilterStage[];
  defaultPresets: PluginPreset[];
  costHint: string;
}

export interface PrefilterCatalog {
  presets: NormalizedPresetMetadata[];
  plugins: NormalizedPluginMetadata[];
}

export const DEFAULT_PRESET_CATALOG: readonly NormalizedPresetMetadata[] = [
  {
    id: 'auto',
    nameKey: 'prefilter.preset.auto',
    description: 'Safe timestamp probing, filename/sketch pruning; never drops active daily logs',
  },
  {
    id: 'timeseries',
    nameKey: 'prefilter.preset.timeseries',
    description: 'Append logs & time-series (time bisect + filename date + sketch, no mtime upper bound)',
  },
  {
    id: 'code',
    nameKey: 'prefilter.preset.code',
    description: 'Source code & docs (mtime window + path scope + sketch)',
  },
  {
    id: 'raw',
    nameKey: 'prefilter.preset.raw',
    description: 'Bypass heuristic prefilters for full raw scan',
  },
];

export const DEFAULT_PLUGIN_CATALOG: readonly NormalizedPluginMetadata[] = [
  {
    id: 'path_scope',
    nameKey: 'plugins.path_scope',
    description: 'Zero-alloc path, extension, and glob pruning before scanning',
    stages: ['source_plan', 'file_prune'],
    defaultPresets: ['auto', 'timeseries', 'code', 'raw'],
    costHint: 'O(1) path',
  },
  {
    id: 'mtime_guard',
    nameKey: 'plugins.mtime_guard',
    description: 'Lower-bound mtime guard (mtime < timeStart)',
    stages: ['file_prune'],
    defaultPresets: ['auto', 'timeseries', 'code'],
    costHint: 'O(1) stat',
  },
  {
    id: 'mtime_window',
    nameKey: 'plugins.mtime_window',
    description: 'Upper-bound mtime window (active in code; fallback for timestamp-less files in auto)',
    stages: ['file_prune'],
    defaultPresets: ['code'],
    costHint: 'O(1) stat',
  },
  {
    id: 'filename_date',
    nameKey: 'plugins.filename_date',
    description: 'Extract rotated filename dates/hours before decompression',
    stages: ['file_prune'],
    defaultPresets: ['auto', 'timeseries'],
    costHint: 'O(1) name',
  },
  {
    id: 'sidecar_sketch',
    nameKey: 'plugins.sidecar_sketch',
    description: 'Observed timestamp bounds & ASCII trigram Bloom sketch in data_dir',
    stages: ['file_prune'],
    defaultPresets: ['auto', 'timeseries', 'code'],
    costHint: 'O(1) bloom',
  },
  {
    id: 'time_bisect',
    nameKey: 'plugins.time_bisect',
    description: 'Binary-search byte windows by parsed line timestamps',
    stages: ['window_narrow'],
    defaultPresets: ['auto', 'timeseries'],
    costHint: 'O(log N) pread',
  },
  {
    id: 'line_time',
    nameKey: 'plugins.line_time',
    description: 'Line timestamp filter, stack-trace continuation binding, and KV pushdown',
    stages: ['source_plan', 'line_filter'],
    defaultPresets: ['auto', 'timeseries', 'raw'],
    costHint: 'O(1) sticky',
  },
];

const DEFAULT_PRESET_MAP = new Map<PluginPreset, NormalizedPresetMetadata>(
  DEFAULT_PRESET_CATALOG.map((p) => [p.id, p])
);

const DEFAULT_PLUGIN_MAP = new Map<string, NormalizedPluginMetadata>(
  DEFAULT_PLUGIN_CATALOG.map((p) => [p.id, p])
);

export function normalizePluginPreset(
  raw: unknown,
  fallback: PluginPreset = DEFAULT_PLUGIN_PRESET
): PluginPreset {
  if (typeof raw !== 'string') return fallback;
  const clean = raw.trim().toLowerCase();
  return PLUGIN_PRESET_SET.has(clean) ? (clean as PluginPreset) : fallback;
}

function normalizePluginIdList(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (typeof item !== 'string') continue;
    const clean = item.trim();
    if (clean.length > 0) seen.add(clean);
  }
  return Array.from(seen).sort();
}

/**
 * Normalizes per-source plugin overrides (`enable` / `disable`):
 * trims, deduplicates, sorts deterministically, and resolves conflicts conservatively
 * (`disable` wins so Monotone Superset safety is preserved).
 */
export function normalizePluginOverrides(
  raw: PluginOverrides | unknown
): NormalizedPluginOverrides {
  if (!raw || typeof raw !== 'object') {
    return { enable: [], disable: [] };
  }
  const obj = raw as { enable?: unknown; disable?: unknown };
  const disable = normalizePluginIdList(obj.disable);
  const disableSet = new Set(disable);
  const enable = normalizePluginIdList(obj.enable).filter((id) => !disableSet.has(id));
  return { enable, disable };
}

export function hasPluginOverrides(overrides: PluginOverrides | null | undefined): boolean {
  const norm = normalizePluginOverrides(overrides);
  return norm.enable.length > 0 || norm.disable.length > 0;
}

function normalizeStages(raw: unknown, fallback: PrefilterStage[]): PrefilterStage[] {
  if (!Array.isArray(raw)) return [...fallback];
  const seen = new Set<PrefilterStage>();
  for (const s of raw) {
    if (typeof s !== 'string') continue;
    const clean = s.trim();
    if (PREFILTER_STAGE_SET.has(clean)) {
      seen.add(clean as PrefilterStage);
    }
  }
  return seen.size > 0 ? Array.from(seen) : [...fallback];
}

function normalizeDefaultPresets(raw: unknown, fallback: PluginPreset[]): PluginPreset[] {
  if (!Array.isArray(raw)) return [...fallback];
  const seen = new Set<PluginPreset>();
  for (const p of raw) {
    if (typeof p !== 'string') continue;
    const clean = p.trim().toLowerCase();
    if (PLUGIN_PRESET_SET.has(clean)) {
      seen.add(clean as PluginPreset);
    }
  }
  // Empty array from server is valid (e.g. a plugin disabled in all default presets).
  return Array.from(seen);
}

export function normalizeMetaPrefilterCatalog(
  meta: Pick<MetaResponse, 'presets' | 'plugins'> | null | undefined
): PrefilterCatalog {
  const presets: NormalizedPresetMetadata[] = [];
  const seenPresets = new Set<PluginPreset>();
  if (Array.isArray(meta?.presets)) {
    for (const rawItem of meta.presets) {
      const obj =
        rawItem && typeof rawItem === 'object'
          ? (rawItem as {
              id?: unknown;
              id_str?: unknown;
              nameKey?: unknown;
              name_key?: unknown;
              description?: unknown;
            })
          : null;
      const idRaw =
        typeof rawItem === 'string'
          ? rawItem
          : obj
            ? typeof obj.id === 'string' && obj.id.trim()
              ? obj.id
              : obj.id_str
            : null;
      if (typeof idRaw !== 'string') continue;
      const cleanId = idRaw.trim().toLowerCase();
      if (!PLUGIN_PRESET_SET.has(cleanId)) continue;
      const id = cleanId as PluginPreset;
      if (seenPresets.has(id)) continue;
      seenPresets.add(id);

      const fallback = DEFAULT_PRESET_MAP.get(id)!;
      const nameKey =
        typeof obj?.nameKey === 'string' && obj.nameKey.trim()
          ? obj.nameKey.trim()
          : typeof obj?.name_key === 'string' && obj.name_key.trim()
            ? obj.name_key.trim()
            : fallback.nameKey;
      const description =
        typeof obj?.description === 'string' && obj.description.trim()
          ? obj.description.trim()
          : fallback.description;
      presets.push({ id, nameKey, description });
    }
  }
  if (presets.length === 0) {
    for (const p of DEFAULT_PRESET_CATALOG) {
      presets.push({ ...p });
    }
  }

  const plugins: NormalizedPluginMetadata[] = [];
  const seenPlugins = new Set<string>();
  if (Array.isArray(meta?.plugins)) {
    for (const rawPlugin of meta.plugins) {
      if (!rawPlugin || typeof rawPlugin !== 'object') continue;
      const p = rawPlugin as PluginMetadata;
      const rawId =
        typeof p.id === 'string' && p.id.trim()
          ? p.id
          : typeof p.id_str === 'string'
            ? p.id_str
            : '';
      const id = rawId.trim();
      if (!id || seenPlugins.has(id)) continue;
      seenPlugins.add(id);

      const fallback = DEFAULT_PLUGIN_MAP.get(id);
      const nameKey =
        typeof p.nameKey === 'string' && p.nameKey.trim()
          ? p.nameKey.trim()
          : typeof p.name_key === 'string' && p.name_key.trim()
            ? p.name_key.trim()
            : fallback?.nameKey ?? `prefilter.plugin.${id}`;
      const description =
        typeof p.description === 'string' && p.description.trim()
          ? p.description.trim()
          : fallback?.description ?? id;
      const stages = normalizeStages(p.stages, fallback?.stages ?? ['file_prune']);
      const rawDefaultPresets = p.defaultPresets ?? p.default_presets;
      const defaultPresets =
        rawDefaultPresets !== undefined
          ? normalizeDefaultPresets(rawDefaultPresets, fallback?.defaultPresets ?? [])
          : [...(fallback?.defaultPresets ?? [])];
      const costHint =
        typeof p.costHint === 'string' && p.costHint.trim()
          ? p.costHint.trim()
          : typeof p.cost_hint === 'string' && p.cost_hint.trim()
            ? p.cost_hint.trim()
            : fallback?.costHint ?? '';

      plugins.push({
        id,
        nameKey,
        description,
        stages,
        defaultPresets,
        costHint,
      });
    }
  }
  if (plugins.length === 0) {
    for (const p of DEFAULT_PLUGIN_CATALOG) {
      plugins.push({
        ...p,
        stages: [...p.stages],
        defaultPresets: [...p.defaultPresets],
      });
    }
  }

  return { presets, plugins };
}

export function resolveSourcePluginPreset(
  src: Pick<DataSourceItem, 'pluginPreset' | 'config'> | null | undefined
): PluginPreset {
  const raw = src?.pluginPreset ?? src?.config?.pluginPreset;
  return normalizePluginPreset(raw, DEFAULT_PLUGIN_PRESET);
}

export function resolveSourcePluginOverrides(
  src: Pick<DataSourceItem, 'plugins' | 'config'> | null | undefined
): NormalizedPluginOverrides {
  const raw = src?.plugins ?? src?.config?.plugins;
  return normalizePluginOverrides(raw);
}

export function isPluginDefaultEnabledForPreset(
  plugin: Pick<NormalizedPluginMetadata, 'defaultPresets'>,
  preset: PluginPreset
): boolean {
  return plugin.defaultPresets.includes(preset);
}

export function isPluginEffectiveEnabled(
  plugin: Pick<NormalizedPluginMetadata, 'id' | 'defaultPresets'>,
  preset: PluginPreset,
  overrides: PluginOverrides | null | undefined
): boolean {
  const norm = normalizePluginOverrides(overrides);
  if (norm.disable.includes(plugin.id)) return false;
  if (norm.enable.includes(plugin.id)) return true;
  return isPluginDefaultEnabledForPreset(plugin, preset);
}

export function togglePluginOverride(
  plugin: Pick<NormalizedPluginMetadata, 'id' | 'defaultPresets'>,
  preset: PluginPreset,
  overrides: PluginOverrides | null | undefined,
  nextEnabled: boolean
): NormalizedPluginOverrides {
  const norm = normalizePluginOverrides(overrides);
  const enable = norm.enable.filter((id) => id !== plugin.id);
  const disable = norm.disable.filter((id) => id !== plugin.id);
  const defaultOn = isPluginDefaultEnabledForPreset(plugin, preset);
  if (nextEnabled !== defaultOn) {
    if (nextEnabled) enable.push(plugin.id);
    else disable.push(plugin.id);
  }
  return {
    enable: enable.sort(),
    disable: disable.sort(),
  };
}

export function formatSourcePluginSpec(
  src: Pick<DataSourceItem, 'id' | 'pluginPreset' | 'plugins' | 'config'>
): string {
  const preset = resolveSourcePluginPreset(src);
  const overrides = resolveSourcePluginOverrides(src);
  let spec = `${src.id}=${preset}`;
  if (overrides.enable.length > 0) {
    spec += `+${overrides.enable.join(',')}`;
  }
  if (overrides.disable.length > 0) {
    spec += `-${overrides.disable.join(',')}`;
  }
  return spec;
}

/**
 * Produces a stable, order-independent cache signature for active sources' prefilter presets
 * and per-source plugin overrides. Changing any source's preset or plugin toggle alters this signature.
 */
export function computeSourcePluginsSig(
  sources: readonly Pick<DataSourceItem, 'id' | 'pluginPreset' | 'plugins' | 'config'>[]
): string {
  if (sources.length === 0) return '';
  return sources.map(formatSourcePluginSpec).sort().join('|');
}

/**
 * Produces a stable sync signature over enabled sources' time formats and prefilter plugin configs
 * so any server-side or cross-session source config update immediately invalidates client L0/file caches.
 */
export function computeEnabledSourcesSyncSig(
  sources: readonly Pick<DataSourceItem, 'id' | 'enabled' | 'pluginPreset' | 'plugins' | 'config'>[]
): string {
  return sources
    .filter((s) => s.enabled)
    .map((s) => `${s.id}:${s.config?.timeFormat ?? ''}:${formatSourcePluginSpec(s)}`)
    .sort()
    .join(',');
}

export interface PrunedTelemetryView {
  visible: boolean;
  filesPruned: number;
  bytesSaved: number;
  compactText: string;
  filesText: string;
  savedText: string;
}

export function formatPrunedTelemetry(
  filesPruned: number,
  bytesSaved: number
): PrunedTelemetryView {
  const safeFiles =
    typeof filesPruned === 'number' && Number.isFinite(filesPruned) && filesPruned > 0
      ? Math.round(filesPruned)
      : 0;
  if (safeFiles <= 0) {
    return {
      visible: false,
      filesPruned: 0,
      bytesSaved: 0,
      compactText: '',
      filesText: '',
      savedText: '',
    };
  }
  const safeBytes =
    typeof bytesSaved === 'number' && Number.isFinite(bytesSaved) && bytesSaved > 0
      ? Math.round(bytesSaved)
      : 0;
  const filesText = safeFiles.toLocaleString();
  const savedText = safeBytes > 0 ? formatBytes(safeBytes) : '';
  const compactText = savedText ? `-${filesText} · ${savedText}` : `-${filesText}`;
  return {
    visible: true,
    filesPruned: safeFiles,
    bytesSaved: safeBytes,
    compactText,
    filesText,
    savedText,
  };
}
