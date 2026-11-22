import { extractLeadingNanoTimestamp, skipLeadingNanoTimestampOffset } from '../format.ts';
import type { HitItem } from '../types.ts';
import { getCachedLogProbe } from './log-parser.ts';
import type {
  HeadlessAdapter,
  LineRowProbe,
  LogVirtualLayout,
  ParsedLineMeta,
  ParsedLogRecord,
  RowLayoutMetrics,
  RowMeasureContext,
} from './types.ts';

export const LINE_BREADCRUMB_H = 22;

export function estimateLineColumns(raw: string, budget: number): number {
  const tsEnd = skipLeadingNanoTimestampOffset(raw);
  let start = tsEnd > 0 && tsEnd < raw.length ? tsEnd : 0;
  while (start < raw.length && (raw.charCodeAt(start) === 32 || raw.charCodeAt(start) === 9)) {
    start++;
  }
  const end = Math.min(raw.length, start + budget);
  let cols = 0;
  for (let i = start; i < end; i++) {
    // CJK / full-width glyphs render ~1em wide ≈ 1.67 monospace columns (0.6em each)
    cols += raw.charCodeAt(i) >= 0x2e80 ? 1.67 : 1;
  }
  return cols;
}

export function parseHitFileMeta(it: HitItem): ParsedLineMeta {
  const slash = it.file.indexOf('/');
  const srcName = slash > 0 ? it.file.slice(0, slash) : '';
  const lastSlash = it.file.lastIndexOf('/');
  const dirParts = it.file
    .slice(slash > 0 ? slash + 1 : 0, Math.max(0, lastSlash))
    .split('/')
    .filter(Boolean);
  const dirLabel =
    dirParts.length > 2
      ? `…/${dirParts.slice(-2).join('/')}/`
      : dirParts.length
        ? `${dirParts.join('/')}/`
        : '';
  const fileName = lastSlash >= 0 ? it.file.slice(lastSlash + 1) : it.file;
  const tsInfo = extractLeadingNanoTimestamp(it.text);
  return {
    srcName,
    dirLabel,
    fileName,
    timeLabel: tsInfo ? tsInfo.formattedTime : '',
    timeNs: tsInfo ? tsInfo.nsStr : '',
  };
}

export function parseLineLogMeta(it: HitItem): ParsedLogRecord {
  const meta = parseHitFileMeta(it);
  const probe = getCachedLogProbe(it);
  return {
    kind: 'log',
    srcName: meta.srcName,
    dirLabel: meta.dirLabel,
    fileName: meta.fileName,
    timeLabel: probe.timeLabel || meta.timeLabel,
    timeFull: probe.timeFull,
    timeRaw: probe.timeRaw || meta.timeNs,
    dateKey: probe.dateKey,
    bodyText: it.text,
  };
}

export function measureLineHitRow(probe: LineRowProbe, ctx: RowMeasureContext): RowLayoutMetrics {
  const maxPreview = ctx.wordWrap ? Math.max(1, Math.min(6, ctx.maxPreviewLines)) : 1;
  let lines = 1;
  if (maxPreview > 1) {
    lines = Math.min(
      maxPreview,
      Math.max(1, Math.ceil(probe.cols / ctx.charsPerLine - 0.12))
    );
  }
  return {
    lines,
    height: ctx.baseHitPad + LINE_BREADCRUMB_H + lines * ctx.lineHeight,
  };
}

export const logAdapter: HeadlessAdapter = {
  id: 'log',
  order: 0,
  inspectContextLines: 0,
  supportsStructuredToggle: true,
};

export function buildLogVirtualLayout(params: {
  hits: readonly HitItem[];
  ctx: RowMeasureContext;
  budget: number;
  getLineProbe: (item: HitItem, budget: number) => LineRowProbe;
}): LogVirtualLayout {
  const { hits, ctx, budget, getLineProbe } = params;
  const hLen = hits.length;
  const offsets = new Float64Array(hLen + 1);
  const lines = new Uint8Array(hLen);
  let acc = 0;

  for (let i = 0; i < hLen; i++) {
    const it = hits[i];
    const probe = getLineProbe(it, budget);
    const metrics = measureLineHitRow(probe, ctx);
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
