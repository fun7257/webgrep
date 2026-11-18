import { type ClassValue, clsx } from 'clsx';
import { twMerge } from 'tailwind-merge';

/**
 * Merges conditional class names with Tailwind conflict resolution.
 */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/**
 * Universal clipboard helper that works both in Secure Contexts (`https://`, `localhost`)
 * AND over remote LAN/WAN HTTP (`http://<ip>:8787`) where `navigator.clipboard` is disabled by browsers.
 */
export function copyTextToClipboard(text: string): boolean {
  if (!text || typeof document === 'undefined') return false;

  const fallbackCopy = (): boolean => {
    try {
      const prevActive = document.activeElement as HTMLElement | null;
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.top = '-9999px';
      ta.style.left = '-9999px';
      ta.style.opacity = '0';
      ta.style.pointerEvents = 'none';
      document.body.appendChild(ta);
      ta.focus({ preventScroll: true });
      ta.select();
      ta.setSelectionRange(0, text.length);
      const ok = document.execCommand('copy');
      document.body.removeChild(ta);
      prevActive?.focus?.({ preventScroll: true });
      return ok;
    } catch {
      return false;
    }
  };

  if (
    typeof window !== 'undefined' &&
    window.isSecureContext &&
    typeof navigator !== 'undefined' &&
    navigator.clipboard?.writeText
  ) {
    navigator.clipboard.writeText(text).catch(() => {
      fallbackCopy();
    });
    return true;
  }

  return fallbackCopy();
}

/**
 * Formats a byte count into human-readable B / KB / MB / GB units.
 */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${kb.toFixed(1)} KB`;
  const mb = kb / 1024;
  if (mb < 1024) return `${mb.toFixed(2)} MB`;
  const gb = mb / 1024;
  return `${gb.toFixed(2)} GB`;
}

/**
 * Formats a millisecond duration into `ms` or `s` with two decimal places.
 */
export function formatMs(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return '0.00 ms';
  if (ms < 1000) return `${ms.toFixed(2)} ms`;
  return `${(ms / 1000).toFixed(2)} s`;
}

/**
 * Formats scan throughput in MB/s or GB/s from byte count and elapsed milliseconds.
 */
export function formatThroughput(bytes: number, elapsedMs: number): string {
  if (!bytes || !elapsedMs || elapsedMs <= 0) return '';
  const bytesPerSec = (bytes / elapsedMs) * 1000;
  const mbPerSec = bytesPerSec / (1024 * 1024);
  if (mbPerSec >= 1024) {
    return `${(mbPerSec / 1024).toFixed(2)} GB/s`;
  }
  return `${mbPerSec.toFixed(0)} MB/s`;
}

const filePathCache = new Map<string, { dir: string; name: string; ext: string }>();

/**
 * Splits a file path (including `archive::entry` virtual paths) into directory,
 * base file name, and lowercase extension, backed by a 4096-entry cache.
 */
export function splitFilePath(filePath: string): {
  dir: string;
  name: string;
  ext: string;
} {
  const cached = filePathCache.get(filePath);
  if (cached) return cached;

  const normalized = filePath.includes('\\') ? filePath.replace(/\\/g, '/') : filePath;
  const slashIdx = normalized.lastIndexOf('/');
  const sepIdx = normalized.indexOf('::');
  const splitPos = Math.max(slashIdx >= 0 ? slashIdx + 1 : 0, sepIdx >= 0 ? sepIdx + 2 : 0);
  const dir = splitPos > 0 ? normalized.slice(0, splitPos) : '';
  const name = splitPos > 0 ? normalized.slice(splitPos) : normalized;
  const dotIdx = name.lastIndexOf('.');
  const ext = dotIdx > 0 ? name.slice(dotIdx + 1).toLowerCase() : '';
  const result = { dir, name, ext };

  if (filePathCache.size > 4096) {
    filePathCache.clear();
  }
  filePathCache.set(filePath, result);
  return result;
}

export interface NanoTimestampInfo {
  nsStr: string;
  formattedTime: string;
  fullFormattedTime: string;
  restText: string;
  prefixLen: number;
}

// Valid epoch millisecond bounds: 2000-01-01 to 2100-01-01
const EPOCH_MIN_MS = 946684800000;
const EPOCH_MAX_MS = 4102444800000;

function formatEpochParts(ms: number): { short: string; full: string } {
  const d = new Date(ms);
  const pad2 = (n: number) => (n < 10 ? `0${n}` : `${n}`);
  const pad3 = (n: number) => (n < 10 ? `00${n}` : n < 100 ? `0${n}` : `${n}`);
  const short = `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}.${pad3(d.getMilliseconds())}`;
  return {
    short,
    full: `${d.getFullYear()}-${short}`,
  };
}

/**
 * Zero-allocation check for a leading 19-digit Unix nanosecond timestamp (`<19-digit-ns> <payload>`).
 * Returns the byte/UTF-16 offset where `<payload>` begins, or `0` if absent.
 */
export function skipLeadingNanoTimestampOffset(text: string): number {
  if (!text || text.length < 20) return 0;
  for (let i = 0; i < 19; i++) {
    const code = text.charCodeAt(i);
    if (code < 48 || code > 57) return 0;
  }
  const sep = text.charCodeAt(19);
  if (sep !== 32 && sep !== 9) return 0;

  let ms = 0;
  for (let i = 0; i < 13; i++) {
    ms = ms * 10 + (text.charCodeAt(i) - 48);
  }
  if (!Number.isFinite(ms) || ms < EPOCH_MIN_MS || ms > EPOCH_MAX_MS) {
    return 0;
  }

  let restStart = 20;
  while (
    restStart < text.length &&
    (text.charCodeAt(restStart) === 32 || text.charCodeAt(restStart) === 9)
  ) {
    restStart++;
  }
  return restStart;
}

/**
 * Detects a leading 19-digit Unix nanosecond timestamp (`<19-digit-ns> <payload>`)
 * in external log records and formats it into human-readable local time.
 */
export function extractLeadingNanoTimestamp(text: string): NanoTimestampInfo | null {
  const restStart = skipLeadingNanoTimestampOffset(text);
  if (restStart === 0) return null;

  const nsStr = text.slice(0, 19);
  const msNum = Number(nsStr.slice(0, 13));
  const { short: formattedTime, full: fullFormattedTime } = formatEpochParts(msNum);

  return {
    nsStr,
    formattedTime,
    fullFormattedTime,
    restText: text.slice(restStart),
    prefixLen: restStart,
  };
}

/**
 * Detects any Unix epoch timestamp (10s, 13ms, 16us, 19ns) in a line and formats it into local time.
 */
export function detectInlineEpochHint(text: string): string | null {
  const lead = extractLeadingNanoTimestamp(text);
  if (lead) return lead.fullFormattedTime;

  const m = /(?:^|[^0-9])(1[5-9]\d{8}(?:\d{3}|\d{6}|\d{9})?)(?:$|[^0-9])/.exec(text);
  if (!m) return null;
  const rawDigits = m[1];
  const ms =
    rawDigits.length === 10
      ? Number(rawDigits) * 1000
      : rawDigits.length >= 13
        ? Number(rawDigits.slice(0, 13))
        : 0;
  if (!Number.isFinite(ms) || ms < EPOCH_MIN_MS || ms > EPOCH_MAX_MS) return null;

  return formatEpochParts(ms).full;
}
