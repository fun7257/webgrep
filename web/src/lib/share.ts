import type { QueryStep, TimePreset } from './types.ts';
import { formatHms, formatYmd } from './time-range.ts';

export const SHARE_QUERY_PARAM = 'share';

export interface ShareReplayState {
  steps: QueryStep[];
  draft: QueryStep | null;
  sources: string[];
  excludedSources: string[];
  timePreset: TimePreset;
  timeStartMs: number;
  timeEndMs: number;
  hidden: boolean;
  respectIgnore: boolean;
  maxResults: number;
  contextPath: string | null;
  contextAnchorLine: number;
  contextAnchorByte: number | null;
  contextPretty: boolean;
  inspectorRaw: boolean;
  openContext: boolean;
}

interface WireStep {
  t: string;
  f?: number;
}

interface WireSharePayloadV1 {
  v: 1;
  st?: WireStep[];
  dr?: WireStep | null;
  src?: string[];
  ex?: string[];
  tp?: string;
  ts?: number;
  te?: number;
  hd?: 0 | 1;
  ri?: 0 | 1;
  mr?: number;
  cp?: string | null;
  cl?: number;
  cb?: number | null;
  pm?: 0 | 1;
  ir?: 0 | 1;
  oc?: 0 | 1;
}

const FLAG_EXCLUDE = 1;
const FLAG_CASE = 2;
const FLAG_WORD = 4;
const FLAG_REGEX = 8;

const FLOATING_TIME_RE = /^(?:today|yesterday|\d+(?:\.\d+)?\s*(?:s|sec|m|min|h|hr|d|day|w))$/i;

function encodeStep(step: QueryStep): WireStep {
  const f =
    (step.exclude ? FLAG_EXCLUDE : 0) |
    (step.caseSensitive ? FLAG_CASE : 0) |
    (step.wholeWord ? FLAG_WORD : 0) |
    (step.isRegex ? FLAG_REGEX : 0);
  return f > 0 ? { t: step.text, f } : { t: step.text };
}

function decodeStep(raw: unknown): QueryStep | null {
  if (!raw || typeof raw !== 'object') return null;
  const obj = raw as Partial<WireStep>;
  if (typeof obj.t !== 'string') return null;
  const f = typeof obj.f === 'number' && Number.isFinite(obj.f) ? obj.f : 0;
  return {
    text: obj.t,
    exclude: Boolean(f & FLAG_EXCLUDE),
    caseSensitive: Boolean(f & FLAG_CASE),
    wholeWord: Boolean(f & FLAG_WORD),
    isRegex: Boolean(f & FLAG_REGEX),
  };
}

function encodeUtf8Base64Url(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function decodeUtf8Base64Url(token: string): string | null {
  const clean = token.trim().replace(/-/g, '+').replace(/_/g, '/');
  if (!clean || /[^A-Za-z0-9+/]/.test(clean)) return null;
  const padded = clean + '='.repeat((4 - (clean.length % 4)) % 4);
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

function clampMaxResults(raw: unknown): number {
  const n = typeof raw === 'number' && Number.isFinite(raw) ? Math.round(raw) : 20000;
  return Math.max(50, Math.min(100000, n));
}

function toLocalDateTimeLabel(ms: number): string {
  const d = new Date(ms);
  return `${formatYmd(d)} ${formatHms(d)}`;
}

/**
 * Freezes relative/floating time presets (e.g. `15m`, `1h`, `today`, `yesterday`)
 * to the exact execution window so opening a share link later replays the same dataset.
 */
export function resolvePinnedShareTime(
  rawPreset: string,
  timeStartMs: number,
  timeEndMs: number,
  executedAtMs: number,
  hasMtimeSource: boolean
): { timePreset: TimePreset; timeStartMs: number; timeEndMs: number } {
  const clean = rawPreset.trim();
  const safeStart = Number.isFinite(timeStartMs) && timeStartMs > 0 ? Math.floor(timeStartMs) : 0;
  const safeEnd = Number.isFinite(timeEndMs) && timeEndMs > 0 ? Math.floor(timeEndMs) : 0;

  if (!clean && safeStart === 0 && safeEnd === 0) {
    return { timePreset: '', timeStartMs: 0, timeEndMs: 0 };
  }

  if (!FLOATING_TIME_RE.test(clean)) {
    return {
      timePreset: clean as TimePreset,
      timeStartMs: safeStart,
      timeEndMs: safeEnd,
    };
  }

  if (safeStart === 0 && safeEnd === 0) {
    return {
      timePreset: clean as TimePreset,
      timeStartMs: 0,
      timeEndMs: 0,
    };
  }

  const startLabel = safeStart > 0 ? toLocalDateTimeLabel(safeStart) : '';
  if (safeEnd > 0) {
    const endLabel = toLocalDateTimeLabel(safeEnd);
    return {
      timePreset: `${startLabel}..${endLabel}`,
      timeStartMs: safeStart,
      timeEndMs: safeEnd,
    };
  }

  if (!hasMtimeSource && executedAtMs >= safeStart) {
    const pinnedEndMs = Math.floor(executedAtMs);
    const endLabel = toLocalDateTimeLabel(pinnedEndMs);
    return {
      timePreset: `${startLabel}..${endLabel}`,
      timeStartMs: safeStart,
      timeEndMs: pinnedEndMs,
    };
  }

  return {
    timePreset: `${startLabel}..`,
    timeStartMs: safeStart,
    timeEndMs: 0,
  };
}

export function encodeShareReplay(state: ShareReplayState): string {
  const payload: WireSharePayloadV1 = {
    v: 1,
    ...(state.steps.length > 0 ? { st: state.steps.map(encodeStep) } : {}),
    ...(state.draft && state.draft.text.length > 0 ? { dr: encodeStep(state.draft) } : {}),
    ...(state.sources.length > 0 ? { src: [...state.sources] } : {}),
    ...(state.excludedSources.length > 0 ? { ex: [...state.excludedSources] } : {}),
    ...(state.timePreset ? { tp: state.timePreset } : {}),
    ...(state.timeStartMs > 0 ? { ts: Math.floor(state.timeStartMs) } : {}),
    ...(state.timeEndMs > 0 ? { te: Math.floor(state.timeEndMs) } : {}),
    ...(state.hidden ? { hd: 1 as const } : {}),
    ...(state.respectIgnore ? { ri: 1 as const } : {}),
    ...(state.maxResults !== 20000 ? { mr: clampMaxResults(state.maxResults) } : {}),
    ...(state.contextPath ? { cp: state.contextPath, cl: Math.max(1, Math.floor(state.contextAnchorLine)) } : {}),
    ...(state.contextPath &&
    typeof state.contextAnchorByte === 'number' &&
    Number.isFinite(state.contextAnchorByte) &&
    state.contextAnchorByte >= 0
      ? { cb: Math.floor(state.contextAnchorByte) }
      : {}),
    ...(state.contextPretty ? { pm: 1 as const } : {}),
    ...(state.inspectorRaw ? { ir: 1 as const } : {}),
    ...(state.openContext ? { oc: 1 as const } : {}),
  };

  return encodeUtf8Base64Url(JSON.stringify(payload));
}

export function decodeShareReplay(token: string): ShareReplayState | null {
  const jsonText = decodeUtf8Base64Url(token);
  if (!jsonText) return null;

  let raw: unknown;
  try {
    raw = JSON.parse(jsonText);
  } catch {
    return null;
  }

  if (!raw || typeof raw !== 'object') return null;
  const obj = raw as Partial<WireSharePayloadV1>;
  if (obj.v !== 1) return null;

  const steps: QueryStep[] = [];
  if (Array.isArray(obj.st)) {
    for (const item of obj.st) {
      const dec = decodeStep(item);
      if (dec && dec.text.trim().length > 0) steps.push(dec);
    }
  }

  const draft = obj.dr ? decodeStep(obj.dr) : null;
  const sources = Array.isArray(obj.src)
    ? obj.src.filter((s): s is string => typeof s === 'string' && s.length > 0)
    : [];
  const excludedSources = Array.isArray(obj.ex)
    ? obj.ex.filter((s): s is string => typeof s === 'string' && s.length > 0)
    : [];

  const timePreset = (typeof obj.tp === 'string' ? obj.tp : '') as TimePreset;
  const timeStartMs = typeof obj.ts === 'number' && Number.isFinite(obj.ts) && obj.ts > 0 ? Math.floor(obj.ts) : 0;
  const timeEndMs = typeof obj.te === 'number' && Number.isFinite(obj.te) && obj.te > 0 ? Math.floor(obj.te) : 0;

  const contextPath =
    typeof obj.cp === 'string' && obj.cp.trim().length > 0 ? obj.cp : null;
  const contextAnchorLine =
    typeof obj.cl === 'number' && Number.isFinite(obj.cl) && obj.cl >= 1
      ? Math.floor(obj.cl)
      : 1;
  const contextAnchorByte =
    contextPath && typeof obj.cb === 'number' && Number.isFinite(obj.cb) && obj.cb >= 0
      ? Math.floor(obj.cb)
      : null;

  return {
    steps,
    draft,
    sources,
    excludedSources,
    timePreset,
    timeStartMs,
    timeEndMs,
    hidden: obj.hd === 1,
    respectIgnore: obj.ri === 1,
    maxResults: clampMaxResults(obj.mr),
    contextPath,
    contextAnchorLine,
    contextAnchorByte,
    contextPretty: obj.pm === 1,
    inspectorRaw: obj.ir === 1,
    openContext: obj.oc === 1,
  };
}

export function buildShareReplayUrl(baseHref: string, state: ShareReplayState): string {
  const url = new URL(baseHref, 'http://127.0.0.1:8787');
  url.search = '';
  url.searchParams.set(SHARE_QUERY_PARAM, encodeShareReplay(state));
  url.hash = '';
  return url.toString();
}

export function extractShareReplayFromUrl(href: string): ShareReplayState | null {
  try {
    const url = new URL(href, 'http://127.0.0.1:8787');
    const token = url.searchParams.get(SHARE_QUERY_PARAM);
    if (!token) return null;
    return decodeShareReplay(token);
  } catch {
    return null;
  }
}

export function stripShareParamFromUrl(href: string): string {
  const url = new URL(href, 'http://127.0.0.1:8787');
  url.searchParams.delete(SHARE_QUERY_PARAM);
  return `${url.pathname}${url.search}${url.hash}`;
}
