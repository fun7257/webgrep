export function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

export function formatYmd(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

export function formatHms(d: Date): string {
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

export function isValidYmd(raw: string): boolean {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw.trim());
  if (!m) return false;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  if (y < 1970 || y > 2261 || mo < 1 || mo > 12 || d < 1 || d > 31) return false;
  const dt = new Date(y, mo - 1, d);
  return dt.getFullYear() === y && dt.getMonth() === mo - 1 && dt.getDate() === d;
}

export function normalizeTimeInput(raw: string, isEnd: boolean): string | null {
  const s = raw.trim();
  if (!s) return '';

  let hh = 0;
  let mm = 0;
  let ss = isEnd ? 59 : 0;

  const colonMatch = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(s);
  if (colonMatch) {
    hh = Number(colonMatch[1]);
    mm = Number(colonMatch[2]);
    if (colonMatch[3] !== undefined) ss = Number(colonMatch[3]);
  } else if (/^\d{4}$/.test(s)) {
    hh = Number(s.slice(0, 2));
    mm = Number(s.slice(2, 4));
  } else if (/^\d{6}$/.test(s)) {
    hh = Number(s.slice(0, 2));
    mm = Number(s.slice(2, 4));
    ss = Number(s.slice(4, 6));
  } else {
    return null;
  }

  if (hh < 0 || hh > 23 || mm < 0 || mm > 59 || ss < 0 || ss > 59) {
    return null;
  }
  return `${pad2(hh)}:${pad2(mm)}:${pad2(ss)}`;
}

const MONTH_ABBR: Record<string, string> = {
  jan: '01',
  feb: '02',
  mar: '03',
  apr: '04',
  may: '05',
  jun: '06',
  jul: '07',
  aug: '08',
  sep: '09',
  oct: '10',
  nov: '11',
  dec: '12',
};

function parseMonthToken(rawMon: string): string | null {
  if (rawMon.length < 3) return null;
  return MONTH_ABBR[rawMon.slice(0, 3).toLowerCase()] ?? null;
}

function applyAmPmHour(hh: number, ampm?: string): number {
  if (!ampm) return hh;
  if (hh < 1 || hh > 12) return -1;
  const up = ampm.toUpperCase();
  if (up === 'AM') return hh === 12 ? 0 : hh;
  return hh === 12 ? 12 : hh + 12;
}

function resolveParsedDateTime(
  datePart: string,
  hh: number,
  mm: number,
  ss: number,
  fracStr?: string,
  tz?: string
): { date: string; time: string } | null {
  if (!isValidYmd(datePart)) return null;
  if (hh < 0 || hh > 23 || mm > 59 || ss > 59) return null;

  if (tz) {
    const upperTz = tz.toUpperCase();
    const normTz =
      upperTz === 'Z' || upperTz === 'UTC' || upperTz === 'GMT'
        ? 'Z'
        : tz.includes(':')
          ? tz
          : `${tz.slice(0, 3)}:${tz.slice(3, 5)}`;
    const fracMs = fracStr ? `.${fracStr.slice(0, 3).padEnd(3, '0')}` : '';
    const iso = `${datePart}T${pad2(hh)}:${pad2(mm)}:${pad2(ss)}${fracMs}${normTz}`;
    const parsedMs = Date.parse(iso);
    if (!Number.isFinite(parsedMs)) return null;
    const d = new Date(parsedMs);
    return { date: formatYmd(d), time: formatHms(d) };
  }

  return { date: datePart, time: `${pad2(hh)}:${pad2(mm)}:${pad2(ss)}` };
}

export function parsePastedDateTime(raw: string): { date: string; time: string } | null {
  const s = raw.trim().replace(/^[[("']+|[)\]"',;]+$/g, '').trim();
  if (!s) return null;

  // Compact calendar YYYYMMDDHHmmss[.SSS][tz] or YYYYMMDDTHHmmssZ (checked before generic epoch)
  const compactMatch =
    /^(19\d{2}|20\d{2})(\d{2})(\d{2})(?:T)?(\d{2})(\d{2})(\d{2})?(?:[.,]?(\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (compactMatch) {
    const datePart = `${compactMatch[1]}-${compactMatch[2]}-${compactMatch[3]}`;
    const parsed = resolveParsedDateTime(
      datePart,
      Number(compactMatch[4]),
      Number(compactMatch[5]),
      compactMatch[6] !== undefined ? Number(compactMatch[6]) : 0,
      compactMatch[7],
      compactMatch[8]
    );
    if (parsed) return parsed;
  }

  // Compact date + separated time (YYYYMMDD HH:MM[:SS])
  const compactSpaceMatch =
    /^(19\d{2}|20\d{2})(\d{2})(\d{2})[T _]+(\d{1,2}):(\d{1,2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (compactSpaceMatch) {
    const datePart = `${compactSpaceMatch[1]}-${compactSpaceMatch[2]}-${compactSpaceMatch[3]}`;
    const parsed = resolveParsedDateTime(
      datePart,
      Number(compactSpaceMatch[4]),
      Number(compactSpaceMatch[5]),
      compactSpaceMatch[6] !== undefined ? Number(compactSpaceMatch[6]) : 0,
      compactSpaceMatch[7],
      compactSpaceMatch[8]
    );
    if (parsed) return parsed;
  }

  // Unix epoch integer or float (10s / 13ms / 16us / 19ns)
  const epochMatch = /^(\d{10,19})(?:\.\d+)?$/.exec(s);
  if (epochMatch) {
    const digits = epochMatch[1];
    let ms = 0;
    if (digits.length >= 16) {
      ms = Math.floor(Number(digits.slice(0, 13)));
    } else if (digits.length >= 13) {
      ms = Number(digits.slice(0, 13));
    } else {
      ms = Number(s) * 1000;
    }
    if (!Number.isFinite(ms) || ms <= 0) return null;
    const d = new Date(ms);
    if (Number.isNaN(d.getTime())) return null;
    return { date: formatYmd(d), time: formatHms(d) };
  }

  // ISO-8601 / Log4j / Slash / Dot / Underscore YMD (date-only or datetime)
  const ymdMatch =
    /^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[T _]+(\d{1,2}):(\d{1,2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(AM|PM)?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?)?$/i.exec(
      s
    );
  if (ymdMatch) {
    const datePart = `${ymdMatch[1]}-${pad2(Number(ymdMatch[2]))}-${pad2(Number(ymdMatch[3]))}`;
    if (ymdMatch[4] === undefined) {
      return isValidYmd(datePart) ? { date: datePart, time: '' } : null;
    }
    const hh = applyAmPmHour(Number(ymdMatch[4]), ymdMatch[8]);
    return resolveParsedDateTime(
      datePart,
      hh,
      Number(ymdMatch[5]),
      ymdMatch[6] !== undefined ? Number(ymdMatch[6]) : 0,
      ymdMatch[7],
      ymdMatch[9]
    );
  }

  // CJK YYYY年M月D日 [HH:MM[:SS] | H时m分s秒]
  const cjkMatch =
    /^(\d{4})年(\d{1,2})月(\d{1,2})日(?:\s*[T ]?\s*(\d{1,2})[:时](\d{1,2})(?:[:分](\d{1,2})秒?)?(?:[.,](\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?)?$/i.exec(
      s
    );
  if (cjkMatch) {
    const datePart = `${cjkMatch[1]}-${pad2(Number(cjkMatch[2]))}-${pad2(Number(cjkMatch[3]))}`;
    if (cjkMatch[4] === undefined) {
      return isValidYmd(datePart) ? { date: datePart, time: '' } : null;
    }
    return resolveParsedDateTime(
      datePart,
      Number(cjkMatch[4]),
      Number(cjkMatch[5]),
      cjkMatch[6] !== undefined ? Number(cjkMatch[6]) : 0,
      cjkMatch[7],
      cjkMatch[8]
    );
  }

  // Nginx / Apache CLF (14/Nov/2026:10:15:02 +0800) & DD-Mon-YYYY HH:mm:ss
  const clfMatch =
    /^(\d{1,2})[/-]([A-Za-z]{3,9})[/-](\d{4})[: T](\d{1,2}):(\d{2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (clfMatch) {
    const mmStr = parseMonthToken(clfMatch[2]);
    if (mmStr) {
      const datePart = `${clfMatch[3]}-${mmStr}-${pad2(Number(clfMatch[1]))}`;
      return resolveParsedDateTime(
        datePart,
        Number(clfMatch[4]),
        Number(clfMatch[5]),
        clfMatch[6] !== undefined ? Number(clfMatch[6]) : 0,
        clfMatch[7],
        clfMatch[8]
      );
    }
  }

  // RFC 2822 day-first ([Sat, ]14 Nov 2026 10:15:02 GMT)
  const rfcMatch =
    /^(?:[A-Za-z]{3,9},?\s+)?(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})[T ](\d{1,2}):(\d{2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (rfcMatch) {
    const mmStr = parseMonthToken(rfcMatch[2]);
    if (mmStr) {
      const datePart = `${rfcMatch[3]}-${mmStr}-${pad2(Number(rfcMatch[1]))}`;
      return resolveParsedDateTime(
        datePart,
        Number(rfcMatch[4]),
        Number(rfcMatch[5]),
        rfcMatch[6] !== undefined ? Number(rfcMatch[6]) : 0,
        rfcMatch[7],
        rfcMatch[8]
      );
    }
  }

  // Month-first (Nov 14, 2026 10:15:02 AM)
  const monthFirstMatch =
    /^(?:[A-Za-z]{3,9},?\s+)?([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(\d{4})[T ](\d{1,2}):(\d{2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(AM|PM)?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (monthFirstMatch) {
    const mmStr = parseMonthToken(monthFirstMatch[1]);
    if (mmStr) {
      const datePart = `${monthFirstMatch[3]}-${mmStr}-${pad2(Number(monthFirstMatch[2]))}`;
      const hh = applyAmPmHour(Number(monthFirstMatch[4]), monthFirstMatch[8]);
      return resolveParsedDateTime(
        datePart,
        hh,
        Number(monthFirstMatch[5]),
        monthFirstMatch[6] !== undefined ? Number(monthFirstMatch[6]) : 0,
        monthFirstMatch[7],
        monthFirstMatch[9]
      );
    }
  }

  // Apache ctime (Sat Nov 14 10:15:02.123456 2026)
  const ctimeMatch =
    /^(?:[A-Za-z]{3,9}\s+)([A-Za-z]{3,9})\s+(\d{1,2})\s+(\d{1,2}):(\d{2}):(\d{2})(?:[.,](\d{1,9}))?\s+(\d{4})\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (ctimeMatch) {
    const mmStr = parseMonthToken(ctimeMatch[1]);
    if (mmStr) {
      const datePart = `${ctimeMatch[7]}-${mmStr}-${pad2(Number(ctimeMatch[2]))}`;
      return resolveParsedDateTime(
        datePart,
        Number(ctimeMatch[3]),
        Number(ctimeMatch[4]),
        Number(ctimeMatch[5]),
        ctimeMatch[6],
        ctimeMatch[8]
      );
    }
  }

  // US MDY (11/14/2026 2:15:02 PM) & EU DMY (14.11.2026 10:15:02)
  const usEuMatch =
    /^(\d{1,2})([/.])(\d{1,2})\2(\d{4})[T ](\d{1,2}):(\d{2})(?::(\d{2}))?(?:[.,](\d{1,9}))?\s*(AM|PM)?\s*(Z|[+-]\d{2}:?\d{2}|UTC|GMT)?$/i.exec(
      s
    );
  if (usEuMatch) {
    const p1 = Number(usEuMatch[1]);
    const p2 = Number(usEuMatch[3]);
    let mon = p1;
    let day = p2;
    if (usEuMatch[2] === '.') {
      day = p1;
      mon = p2;
    } else if (p1 > 12) {
      day = p1;
      mon = p2;
    }
    const datePart = `${usEuMatch[4]}-${pad2(mon)}-${pad2(day)}`;
    const hh = applyAmPmHour(Number(usEuMatch[5]), usEuMatch[9]);
    return resolveParsedDateTime(
      datePart,
      hh,
      Number(usEuMatch[6]),
      usEuMatch[7] !== undefined ? Number(usEuMatch[7]) : 0,
      usEuMatch[8],
      usEuMatch[10]
    );
  }

  return null;
}

const EMBEDDED_TS_PATTERNS: readonly RegExp[] = [
  /(?:19|20)\d{2}[-/.]\d{1,2}[-/.]\d{1,2}(?:[T _]+\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d{1,9})?(?:\s*(?:AM|PM))?(?:\s*(?:Z|[+-]\d{2}:?\d{2}|UTC|GMT))?)?/i,
  /\d{1,2}[/-][A-Za-z]{3,9}[/-](?:19|20)\d{2}[: T]\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d{1,9})?(?:\s*(?:Z|[+-]\d{2}:?\d{2}|UTC|GMT))?/i,
  /(?:19|20)\d{2}年\d{1,2}月\d{1,2}日(?:\s*[T ]?\s*\d{1,2}[:时]\d{1,2}(?:[:分]\d{1,2}秒?)?(?:[.,]\d{1,9})?(?:\s*(?:Z|[+-]\d{2}:?\d{2}|UTC|GMT))?)?/i,
  /\d{1,2}([/.])\d{1,2}\1(?:19|20)\d{2}[T ]\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d{1,9})?(?:\s*(?:AM|PM))?(?:\s*(?:Z|[+-]\d{2}:?\d{2}|UTC|GMT))?/i,
  /\b(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?:T)?\d{6}(?:[.,]?\d{1,9})?(?:\s*(?:Z|[+-]\d{2}:?\d{2}|UTC|GMT))?\b/i,
  /^\s*[\[(]?(\d{10,19}(?:\.\d+)?)(?=[\])\s,;:]|$)/,
];

function candidateHasSeconds(candidate: string): boolean {
  if (/^\s*\d{10,19}(?:\.\d+)?\s*$/.test(candidate)) return true;
  if (/(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])T?\d{6}/.test(candidate)) return true;
  if (/\d{1,2}[:时]\d{2}[:分]\d{2}/.test(candidate)) return true;
  return false;
}

export interface ExtractedDateTime {
  date: string;
  time: string;
  hasSeconds: boolean;
  formatted: string;
}

export function extractPastedDateTime(
  raw: string,
  nowMs = Date.now(),
  isEnd = false
): ExtractedDateTime | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;

  const direct = parsePastedDateTime(trimmed);
  if (direct) {
    const hasSeconds = candidateHasSeconds(trimmed);
    const time =
      direct.time && !hasSeconds && isEnd ? `${direct.time.slice(0, 6)}59` : direct.time;
    return {
      date: direct.date,
      time,
      hasSeconds,
      formatted: time ? `${direct.date} ${time}` : direct.date,
    };
  }

  for (const re of EMBEDDED_TS_PATTERNS) {
    const m = re.exec(trimmed);
    if (!m) continue;
    const candidate = (m[1] && m[0].startsWith(trimmed[0] ?? '') ? m[1] : m[0]).trim();
    const parsed = parsePastedDateTime(candidate);
    if (!parsed) continue;
    const hasSeconds = candidateHasSeconds(candidate);
    const time =
      parsed.time && !hasSeconds && isEnd ? `${parsed.time.slice(0, 6)}59` : parsed.time;
    return {
      date: parsed.date,
      time,
      hasSeconds,
      formatted: time ? `${parsed.date} ${time}` : parsed.date,
    };
  }

  // Yearless syslog at start of line (e.g. "Nov 14 09:15:00 web01 ...")
  const syslogMatch =
    /^(?:[A-Za-z]{3,9}\s+)?([A-Za-z]{3})\s+(\d{1,2})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\b/.exec(
      trimmed
    );
  if (syslogMatch) {
    const mmStr = parseMonthToken(syslogMatch[1]);
    if (mmStr) {
      const yr = new Date(nowMs).getFullYear();
      const hasSeconds = syslogMatch[5] !== undefined;
      const ss = hasSeconds ? Number(syslogMatch[5]) : isEnd ? 59 : 0;
      const resolved = resolveParsedDateTime(
        `${yr}-${mmStr}-${pad2(Number(syslogMatch[2]))}`,
        Number(syslogMatch[3]),
        Number(syslogMatch[4]),
        ss
      );
      if (resolved) {
        return {
          date: resolved.date,
          time: resolved.time,
          hasSeconds,
          formatted: `${resolved.date} ${resolved.time}`,
        };
      }
    }
  }

  return null;
}
