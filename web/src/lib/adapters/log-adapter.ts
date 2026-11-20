import { splitFilePath } from '../format.ts';
import { resolveSourcePluginPreset } from '../prefilter.ts';
import type { DataSourceItem, HitItem } from '../types.ts';
import { isCodeOnlyPath } from './code-adapter.ts';
import { getCachedLogProbe, probeLogLineFast } from './log-parser.ts';
import { PLAIN_BREADCRUMB_H, estimatePlainColumns, plainAdapter } from './plain-adapter.ts';
import type {
  FastLogProbe,
  LogVirtualLayout,
  ParsedLogRecord,
  PlainRowProbe,
  RowLayoutMetrics,
  RowMeasureContext,
  ViewAdapter,
} from './types.ts';

const LOG_EXTS = new Set(['log', 'out', 'jsonl', 'ndjson']);

export function parseLineLogMeta(it: HitItem): ParsedLogRecord {
  const plainMeta = plainAdapter.parse(it);
  const probe = getCachedLogProbe(it);
  return {
    kind: 'log',
    srcName: plainMeta.srcName,
    dirLabel: plainMeta.dirLabel,
    fileName: plainMeta.fileName,
    timeLabel: probe.timeLabel || plainMeta.timeLabel,
    timeFull: probe.timeFull,
    timeRaw: probe.timeRaw || plainMeta.timeNs,
    dateKey: probe.dateKey,
    bodyText: it.text,
  };
}

export function scoreLogConfidenceWithProbe(
  item: HitItem,
  probe: FastLogProbe,
  source?: DataSourceItem
): number {
  const preset = source ? resolveSourcePluginPreset(source) : 'auto';
  if (source && (preset === 'code' || preset === 'raw')) {
    return 0;
  }
  if (source?.kind === 'docker' || preset === 'timeseries') {
    return 0.96;
  }
  if (isCodeOnlyPath(item.file)) {
    return 0;
  }
  if (probe.isJson) {
    return 0.95;
  }
  const { ext } = splitFilePath(item.file);
  if (probe.isLog || LOG_EXTS.has(ext)) {
    return 0.9;
  }
  return 0;
}

export const logAdapter: ViewAdapter<FastLogProbe, ParsedLogRecord> = {
  id: 'log',
  order: 0,
  inspectContextLines: 0,
  supportsStructuredToggle: true,

  classifyHit(item: HitItem, source?: DataSourceItem): number {
    return scoreLogConfidenceWithProbe(item, getCachedLogProbe(item), source);
  },

  detectConfidence(item: HitItem, source?: DataSourceItem): number {
    return scoreLogConfidenceWithProbe(item, getCachedLogProbe(item), source);
  },

  probeFast(item: HitItem): FastLogProbe {
    return probeLogLineFast(item.text);
  },

  parse(item: HitItem): ParsedLogRecord {
    return parseLineLogMeta(item);
  },

  measureRow(_probe: FastLogProbe, item: HitItem, ctx: RowMeasureContext): RowLayoutMetrics {
    const budget = Math.max(240, (ctx.wordWrap ? Math.max(1, Math.min(6, ctx.maxPreviewLines)) : 1) * 180);
    const cols = estimatePlainColumns(item.text, budget);
    const maxPreview = ctx.wordWrap ? Math.max(1, Math.min(6, ctx.maxPreviewLines)) : 1;
    let lines = 1;
    if (maxPreview > 1) {
      lines = Math.min(
        maxPreview,
        Math.max(1, Math.ceil(cols / ctx.charsPerLine - 0.12))
      );
    }
    return {
      lines,
      height: ctx.baseHitPad + PLAIN_BREADCRUMB_H + lines * ctx.lineHeight,
    };
  },
};

export function buildLogVirtualLayout(params: {
  hits: readonly HitItem[];
  ctx: RowMeasureContext;
  budget: number;
  getPlainProbe: (item: HitItem, budget: number) => PlainRowProbe;
}): LogVirtualLayout {
  const { hits, ctx, budget, getPlainProbe } = params;
  const hLen = hits.length;
  const offsets = new Float64Array(hLen + 1);
  const lines = new Uint8Array(hLen);
  let acc = 0;

  for (let i = 0; i < hLen; i++) {
    const it = hits[i];
    const probe = getPlainProbe(it, budget);
    const metrics = plainAdapter.measureRow(probe, it, ctx);
    lines[i] = metrics.lines;
    offsets[i] = acc;
    acc += metrics.height;
  }
  offsets[hLen] = acc;

  return {
    offsets,
    lines,
    totalHeight: acc,
  };
}
