import { resolveSourcePluginPreset } from '../prefilter.ts';
import type { DataSourceItem, HitItem } from '../types.ts';
import { isCodeOnlyPath } from './code-adapter.ts';
import { getCachedLogProbe, parseLogLine, probeLogLineFast } from './log-parser.ts';
import { plainAdapter } from './plain-adapter.ts';
import type {
  FastLogProbe,
  LogVirtualItem,
  LogVirtualLayout,
  ParsedLogRecord,
  PlainRowProbe,
  RowLayoutMetrics,
  RowMeasureContext,
  ViewAdapter,
} from './types.ts';

export const LOG_DATE_DIVIDER_HEIGHT = 24;

export function buildFallbackParsedLog(item: HitItem): ParsedLogRecord {
  return {
    kind: 'log',
    format: 'text-log',
    timeShort: '',
    timeDate: '',
    timeFull: '',
    timeRaw: '',
    level: 'unknown',
    levelBadge: '',
    levelFilterToken: '',
    category: '',
    categoryFilterToken: '',
    summary: item.text,
    errorText: '',
    traceId: '',
    traceKey: '',
    traceFilterToken: '',
    keyFields: [],
    truncated: false,
    rawRestText: item.text,
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
  if (preset !== 'timeseries' && source?.kind !== 'docker' && isCodeOnlyPath(item.file)) {
    return 0;
  }
  if (!probe.isLog) {
    return 0;
  }
  if (source?.kind === 'docker' || preset === 'timeseries') {
    return 0.96;
  }
  const trimmed = item.text.trimStart();
  if (trimmed.startsWith('{') || trimmed.includes('{"')) {
    return 0.95;
  }
  return 0.85;
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
    return parseLogLine(item.text) ?? buildFallbackParsedLog(item);
  },

  getFormattedCopyText(lineText: string): string | null {
    const parsed = parseLogLine(lineText);
    if (!parsed?.structuredData) return null;
    try {
      return JSON.stringify(parsed.structuredData, null, 2);
    } catch {
      return null;
    }
  },

  measureRow(probe: FastLogProbe, _item: HitItem, ctx: RowMeasureContext): RowLayoutMetrics {
    const pad = ctx.density === 'compact' ? 10 : 14;
    if (ctx.density === 'compact' || ctx.maxPreviewLines === 1 || !ctx.wordWrap) {
      return {
        lines: 1,
        height: pad + Math.max(20, ctx.lineHeight),
      };
    }

    const maxLogLines = Math.min(3, ctx.maxPreviewLines);
    const lines = Math.min(
      maxLogLines,
      Math.max(1, Math.ceil(probe.estimatedSummaryCols / ctx.charsPerLine - 0.12))
    );
    return {
      lines,
      height: pad + lines * ctx.lineHeight,
    };
  },
};

function resolveSourcePrefix(
  file: string,
  sourceByName: ReadonlyMap<string, DataSourceItem>
): DataSourceItem | undefined {
  const slash = file.indexOf('/');
  if (slash <= 0) return undefined;
  return sourceByName.get(file.slice(0, slash).toLowerCase());
}

/**
 * Builds the flat virtual layout for `LogResultsView` in O(n) using `FastLogProbe`
 * (zero JSON.parse), inserting standalone date divider rows whenever the date changes.
 */
export function buildLogVirtualLayout(params: {
  hits: readonly HitItem[];
  sourceByName: ReadonlyMap<string, DataSourceItem>;
  forceLogSurface: boolean;
  ctx: RowMeasureContext;
  budget: number;
  getLogProbe: (item: HitItem) => FastLogProbe;
  getPlainProbe: (item: HitItem, budget: number) => PlainRowProbe;
}): LogVirtualLayout {
  const { hits, sourceByName, forceLogSurface, ctx, budget, getLogProbe, getPlainProbe } = params;
  const hLen = hits.length;
  const denseLogMode = ctx.density === 'compact' || ctx.maxPreviewLines === 1 || !ctx.wordWrap;
  const hitIdxToVirtualIdx = new Int32Array(hLen);
  hitIdxToVirtualIdx.fill(-1);

  if (hLen === 0) {
    return {
      items: [],
      offsets: new Float64Array(1),
      hitIdxToVirtualIdx,
      totalHeight: 0,
      denseLogMode,
    };
  }

  const items: LogVirtualItem[] = [];
  let lastFile = '';
  let lastSrc: DataSourceItem | undefined = undefined;
  let lastDateKey = '';

  for (let i = 0; i < hLen; i++) {
    const it = hits[i];
    if (it.file !== lastFile) {
      lastFile = it.file;
      lastSrc = resolveSourcePrefix(lastFile, sourceByName);
    }

    const probe = getLogProbe(it);
    const isNativeLog = forceLogSurface
      ? probe.isLog
      : scoreLogConfidenceWithProbe(it, probe, lastSrc) > 0;

    if (isNativeLog && probe.dateKey) {
      if (lastDateKey !== '' && probe.dateKey !== lastDateKey) {
        items.push({
          kind: 'date',
          key: `date:${i}:${probe.dateKey}`,
          dateKey: probe.dateKey,
          height: LOG_DATE_DIVIDER_HEIGHT,
        });
      }
      lastDateKey = probe.dateKey;
    }

    const metrics = isNativeLog
      ? logAdapter.measureRow(probe, it, ctx)
      : plainAdapter.measureRow(getPlainProbe(it, budget), it, ctx);

    const vIdx = items.length;
    hitIdxToVirtualIdx[i] = vIdx;
    items.push({
      kind: 'hit',
      key: `hit:${i}:${it.file}:${it.line}:${it.col}`,
      hitIdx: i,
      item: it,
      isNativeLog,
      lines: metrics.lines,
      height: metrics.height,
    });
  }

  const offsets = new Float64Array(items.length + 1);
  let acc = 0;
  for (let i = 0; i < items.length; i++) {
    offsets[i] = acc;
    acc += items[i].height;
  }
  offsets[items.length] = acc;

  return {
    items,
    offsets,
    hitIdxToVirtualIdx,
    totalHeight: acc,
    denseLogMode,
  };
}
