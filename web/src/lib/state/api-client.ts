import type {
  AuthStatusResponse,
  DirSuggestEntry,
  DirSuggestResponse,
  FileResponse,
  McpStateResponse,
  MetaResponse,
  PluginOverrides,
  PluginPreset,
  SourceConfig,
  SourceKind,
  SourcesResponse,
  TimePreviewResponse,
} from '../types.ts';
import { normalizePluginOverrides, normalizePluginPreset } from '../prefilter.ts';

export type ApiFetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export type AuthLoginResult =
  | { ok: true; data: Partial<AuthStatusResponse> }
  | { ok: false; invalidPassword: boolean };

export interface UpsertSourcePayload {
  id?: string;
  kind?: SourceKind;
  name: string;
  path?: string;
  config?: SourceConfig;
  enabled?: boolean;
  timeFormat?: string;
  pluginPreset?: PluginPreset;
  plugins?: PluginOverrides;
}

export interface FileWindowRequestParams {
  tenant: string;
  filePath: string;
  line: number;
  context: number;
  startLine?: number;
  endLine?: number;
  anchorLine?: number;
  anchorByte?: number | null;
  signal?: AbortSignal;
}

async function getJsonOrNull<T>(
  fetcher: ApiFetcher,
  url: string,
  init?: RequestInit
): Promise<T | null> {
  try {
    const res = await fetcher(url, init);
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

async function postJsonOrNull<T>(
  fetcher: ApiFetcher,
  url: string,
  body?: unknown
): Promise<T | null> {
  try {
    const res = await fetcher(url, {
      method: 'POST',
      ...(body !== undefined
        ? {
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
          }
        : {}),
    });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

export async function fetchAuthStatus(
  fetcher: ApiFetcher
): Promise<Partial<AuthStatusResponse> | null> {
  return getJsonOrNull<Partial<AuthStatusResponse>>(fetcher, '/api/auth/status', {
    credentials: 'same-origin',
    cache: 'no-store',
  });
}

export async function postAuthLogin(
  fetcher: ApiFetcher,
  password: string
): Promise<AuthLoginResult> {
  try {
    const res = await fetcher('/api/auth/login', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password }),
    });
    if (res.status === 401 || !res.ok) {
      return { ok: false, invalidPassword: res.status === 401 };
    }
    const data = (await res.json().catch(() => ({}))) as Partial<AuthStatusResponse>;
    return { ok: true, data };
  } catch {
    return { ok: false, invalidPassword: false };
  }
}

export async function postAuthLogout(fetcher: ApiFetcher): Promise<void> {
  try {
    await fetcher('/api/auth/logout', {
      method: 'POST',
      credentials: 'same-origin',
    });
  } catch {
    // ignore network failure on logout
  }
}

export async function requestMeta(fetcher: ApiFetcher): Promise<MetaResponse | null> {
  const data = await getJsonOrNull<Partial<MetaResponse>>(fetcher, '/api/meta');
  if (!data) return null;
  return {
    rootLabel: data.rootLabel || 'webgrep',
    root: data.root || '.',
    engine: data.engine || 'libwebgrep 0.5.0 · SIMD',
    types: Array.isArray(data.types) ? data.types : [],
    scopes: Array.isArray(data.scopes) ? data.scopes : [],
    plugins: Array.isArray(data.plugins) ? data.plugins : undefined,
    presets: Array.isArray(data.presets) ? data.presets : undefined,
  };
}

export async function requestSources(fetcher: ApiFetcher): Promise<SourcesResponse | null> {
  return getJsonOrNull<SourcesResponse>(fetcher, '/api/sources');
}

export async function postUpsertSource(
  fetcher: ApiFetcher,
  payload: UpsertSourcePayload
): Promise<SourcesResponse> {
  const cleanPath = (payload.config?.path ?? payload.path ?? '').trim();
  const resolvedTimeFormat =
    payload.timeFormat !== undefined ? payload.timeFormat.trim() : payload.config?.timeFormat;
  const resolvedPluginPreset =
    payload.pluginPreset !== undefined
      ? normalizePluginPreset(payload.pluginPreset)
      : payload.config?.pluginPreset !== undefined
        ? normalizePluginPreset(payload.config.pluginPreset)
        : undefined;
  const rawPlugins =
    payload.plugins !== undefined ? payload.plugins : payload.config?.plugins;
  const resolvedPlugins =
    rawPlugins !== undefined && rawPlugins !== null
      ? normalizePluginOverrides(rawPlugins)
      : undefined;

  const res = await fetcher('/api/sources', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      id: payload.id ?? null,
      kind: payload.kind ?? 'dir',
      name: payload.name.trim(),
      path: cleanPath,
      config: {
        path: cleanPath,
        ...(resolvedTimeFormat !== undefined ? { timeFormat: resolvedTimeFormat } : {}),
        ...(resolvedPluginPreset !== undefined ? { pluginPreset: resolvedPluginPreset } : {}),
        ...(resolvedPlugins !== undefined ? { plugins: resolvedPlugins } : {}),
      },
      ...(resolvedPluginPreset !== undefined ? { pluginPreset: resolvedPluginPreset } : {}),
      ...(resolvedPlugins !== undefined ? { plugins: resolvedPlugins } : {}),
      enabled: payload.enabled ?? true,
    }),
  });
  if (!res.ok) {
    const errData = (await res.json().catch(() => ({ error: `HTTP ${res.status}` }))) as {
      error?: string;
    };
    throw new Error(errData.error || `HTTP ${res.status}`);
  }
  return (await res.json()) as SourcesResponse;
}

export async function postToggleSource(
  fetcher: ApiFetcher,
  id: string
): Promise<SourcesResponse | null> {
  return postJsonOrNull<SourcesResponse>(fetcher, '/api/sources/toggle', { id });
}

export async function postToggleAllSources(
  fetcher: ApiFetcher,
  enabled: boolean
): Promise<SourcesResponse | null> {
  return postJsonOrNull<SourcesResponse>(fetcher, '/api/sources/toggle', { enabled });
}

export async function postDeleteSource(
  fetcher: ApiFetcher,
  id: string
): Promise<SourcesResponse | null> {
  return postJsonOrNull<SourcesResponse>(fetcher, '/api/sources/delete', { id });
}

export async function requestDirSuggestions(
  fetcher: ApiFetcher,
  queryPath: string,
  kind: SourceKind = 'dir'
): Promise<DirSuggestEntry[]> {
  const params = new URLSearchParams({ kind, q: queryPath });
  const data = await getJsonOrNull<DirSuggestResponse>(
    fetcher,
    `/api/sources/complete?${params.toString()}`
  );
  return data && Array.isArray(data.entries) ? data.entries : [];
}

export async function requestMcpState(fetcher: ApiFetcher): Promise<McpStateResponse | null> {
  return getJsonOrNull<McpStateResponse>(fetcher, '/api/mcp');
}

export async function postMcpConfig(
  fetcher: ApiFetcher,
  patch: { enabled?: boolean; maxLogs?: number }
): Promise<McpStateResponse | null> {
  return postJsonOrNull<McpStateResponse>(fetcher, '/api/mcp/config', patch);
}

export async function postClearMcpLogs(
  fetcher: ApiFetcher
): Promise<McpStateResponse | null> {
  return postJsonOrNull<McpStateResponse>(fetcher, '/api/mcp/logs/clear');
}

export async function postTimePreview(
  fetcher: ApiFetcher,
  format: string,
  sample: string,
  tzOffsetMin = -new Date().getTimezoneOffset()
): Promise<TimePreviewResponse> {
  try {
    const res = await fetcher('/api/time/preview', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        format: format.trim(),
        sample,
        tzOffsetMin,
      }),
    });
    if (!res.ok) {
      const errData = (await res.json().catch(() => ({ error: `HTTP ${res.status}` }))) as {
        errorMessage?: string;
        error?: string;
      };
      const msg =
        typeof errData.errorMessage === 'string'
          ? errData.errorMessage
          : typeof errData.error === 'string'
            ? errData.error
            : `HTTP ${res.status}`;
      return {
        validFormat: false,
        matched: false,
        errorMessage: msg,
      };
    }
    return (await res.json()) as TimePreviewResponse;
  } catch (err) {
    return {
      validFormat: false,
      matched: false,
      errorMessage: err instanceof Error ? err.message : 'Preview request failed',
    };
  }
}

export async function requestFileWindow(
  fetcher: ApiFetcher,
  params: FileWindowRequestParams
): Promise<FileResponse> {
  const query = new URLSearchParams({
    tenant: params.tenant,
    path: params.filePath,
    line: String(params.line),
    context: String(params.context),
  });
  if (params.startLine !== undefined) query.set('startLine', String(params.startLine));
  if (params.endLine !== undefined) query.set('endLine', String(params.endLine));
  if (params.anchorLine !== undefined) query.set('anchorLine', String(params.anchorLine));
  if (
    typeof params.anchorByte === 'number' &&
    Number.isFinite(params.anchorByte) &&
    params.anchorByte >= 0
  ) {
    query.set('anchorByte', String(Math.floor(params.anchorByte)));
  }
  const res = await fetcher(`/api/file?${query.toString()}`, { signal: params.signal });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status}`);
  }
  return (await res.json()) as FileResponse;
}
