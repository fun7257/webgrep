/**
 * Adaptive display refresh-rate profiler (60Hz–240Hz+).
 *
 * Aligns streaming result flush windows, VSync lead compensation, overscan
 * buffers, inspector deferral thresholds, and CSS motion tokens to the actual
 * physical display refresh cadence with zero ongoing idle rAF overhead.
 */

export type FrameTier = 'standard' | 'high';

export interface FrameProfile {
  /** Snapped display refresh rate in Hz (e.g., 60, 75, 90, 120, 144, 165, 240). */
  hz: number;
  /** Physical VSync frame duration in milliseconds (`1000 / hz`). */
  frameMs: number;
  /** Standard (`<= 75Hz`) vs high-refresh (`> 75Hz`) tier. */
  tier: FrameTier;
  /** Integer frame count for initial result aggregation window (~50ms target). */
  firstFlushFrames: number;
  /** Integer frame count for steady-state streaming flushes (~67ms / 15fps target). */
  steadyFlushFrames: number;
  /**
   * Wakeup lead delay (ms) for first flush: fires 0.5 frame before target
   * VSync boundary so `requestAnimationFrame` hits that VSync instead of slipping +1 frame.
   */
  firstFlushLeadMs: number;
  /** Wakeup lead delay (ms) for steady-state streaming flushes. */
  steadyFlushLeadMs: number;
  /**
   * Character length threshold above which InspectorPane defers by 1 VSync.
   * 60Hz has 2x CPU budget per frame (16.67ms) while paying 2x penalty on defer (+16.7ms).
   */
  deferInspectorThresholdChars: number;
  /** Virtual list overscan buffer in px; wider on 60Hz due to larger per-frame wheel/drag deltas. */
  overscanPx: number;
  /** Integer-frame aligned duration (ms) for Switch thumb/track transitions. */
  switchMotionMs: number;
  /** Integer-frame aligned duration (ms) for mobile bottom/detail sheet slides. */
  sheetMotionMs: number;
  /** Integer-frame aligned duration (ms) for right drawer slide-in transitions. */
  drawerEnterMs: number;
}

export const STANDARD_REFRESH_RATES = [60, 75, 90, 100, 120, 144, 165, 240] as const;

const MIN_SAMPLE_DELTA_MS = 2.5;
const MAX_SAMPLE_DELTA_MS = 40;
const PROBE_FRAME_COUNT = 10;

/**
 * Snaps a median frame delta (ms) to the nearest standard display refresh rate
 * within ±12%, or clamped integer Hz for non-standard/VRR panels.
 */
export function snapRefreshRateHz(medianDeltaMs: number): number {
  if (
    !Number.isFinite(medianDeltaMs) ||
    medianDeltaMs < MIN_SAMPLE_DELTA_MS ||
    medianDeltaMs > MAX_SAMPLE_DELTA_MS
  ) {
    return 60;
  }

  const rawHz = 1000 / medianDeltaMs;
  let closestRate: number = STANDARD_REFRESH_RATES[0];
  let bestRelErr = Infinity;
  for (const rate of STANDARD_REFRESH_RATES) {
    const relErr = Math.abs(rawHz - rate) / rate;
    if (relErr < bestRelErr) {
      bestRelErr = relErr;
      closestRate = rate;
    }
  }
  if (bestRelErr <= 0.12) {
    return closestRate;
  }
  return Math.max(30, Math.min(360, Math.round(rawHz)));
}

/**
 * Builds an integer-frame-aligned `FrameProfile` for a given refresh rate in Hz.
 */
export function buildFrameProfileForHz(hzInput: number): FrameProfile {
  const hz = Number.isFinite(hzInput)
    ? Math.max(30, Math.min(360, Math.round(hzInput)))
    : 60;
  const frameMs = 1000 / hz;
  const tier: FrameTier = hz <= 75 ? 'standard' : 'high';

  const firstFlushFrames = Math.max(2, Math.round(50 / frameMs));
  const steadyFlushFrames = Math.max(4, Math.round(66.67 / frameMs));

  const firstFlushLeadMs = Math.max(8, Math.floor((firstFlushFrames - 0.5) * frameMs));
  const steadyFlushLeadMs = Math.max(16, Math.floor((steadyFlushFrames - 0.5) * frameMs));

  const deferInspectorThresholdChars = tier === 'standard' ? 12_288 : 4_096;
  const overscanPx = tier === 'standard' ? 560 : 420;

  const switchMotionMs = Math.round((tier === 'standard' ? 4 : 8) * frameMs);
  const sheetMotionMs = Math.round((tier === 'standard' ? 9 : 18) * frameMs);
  const drawerEnterMs = Math.round((tier === 'standard' ? 11 : 22) * frameMs);

  return {
    hz,
    frameMs,
    tier,
    firstFlushFrames,
    steadyFlushFrames,
    firstFlushLeadMs,
    steadyFlushLeadMs,
    deferInspectorThresholdChars,
    overscanPx,
    switchMotionMs,
    sheetMotionMs,
    drawerEnterMs,
  };
}

/**
 * Computes a `FrameProfile` from raw inter-frame `requestAnimationFrame` deltas,
 * filtering backgrounded/stalled outliers and falling back to 60Hz if sparse.
 */
export function computeFrameProfile(deltasMs: readonly number[]): FrameProfile {
  const valid: number[] = [];
  for (let i = 0; i < deltasMs.length; i++) {
    const d = deltasMs[i];
    if (Number.isFinite(d) && d >= MIN_SAMPLE_DELTA_MS && d <= MAX_SAMPLE_DELTA_MS) {
      valid.push(d);
    }
  }
  if (valid.length < 4) {
    return buildFrameProfileForHz(60);
  }
  valid.sort((a, b) => a - b);
  const mid = valid.length >>> 1;
  const median =
    valid.length % 2 === 1 ? valid[mid] : (valid[mid - 1] + valid[mid]) / 2;
  return buildFrameProfileForHz(snapRefreshRateHz(median));
}

/**
 * Applies frame-aligned motion timing CSS variables onto `:root` (or `root`).
 */
export function applyFrameProfileCssVars(
  profile: FrameProfile,
  root?: HTMLElement | null
): void {
  const target =
    root ?? (typeof document !== 'undefined' ? document.documentElement : null);
  if (!target) return;
  target.style.setProperty('--frame-ms', `${profile.frameMs.toFixed(2)}ms`);
  target.style.setProperty('--motion-switch', `${profile.switchMotionMs}ms`);
  target.style.setProperty('--motion-sheet', `${profile.sheetMotionMs}ms`);
  target.style.setProperty('--motion-drawer-in', `${profile.drawerEnterMs}ms`);
}

/**
 * Probes the live display refresh rate using a short 10-frame `requestAnimationFrame`
 * burst and automatically stops so idle CPU/GPU cost stays at 0%.
 * Re-probes when tab visibility returns or the window moves across monitors (`dppx` change).
 */
export function startAdaptiveFrameProbe(
  onUpdate: (profile: FrameProfile) => void
): () => void {
  if (typeof window === 'undefined' || typeof requestAnimationFrame === 'undefined') {
    return () => {};
  }

  let disposed = false;
  let activeRaf: number | null = null;
  let lastAppliedHz = -1;
  let dprQuery: MediaQueryList | null = null;
  let removeDprListener: (() => void) | null = null;

  const cancelProbe = () => {
    if (activeRaf !== null && typeof cancelAnimationFrame !== 'undefined') {
      cancelAnimationFrame(activeRaf);
      activeRaf = null;
    }
  };

  const runBurst = () => {
    if (disposed) return;
    if (typeof document !== 'undefined' && document.visibilityState === 'hidden') {
      return;
    }
    cancelProbe();

    const deltas: number[] = [];
    let prevTs = 0;
    let ticks = 0;

    const step = (ts: number) => {
      activeRaf = null;
      if (disposed) return;
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') {
        return;
      }
      if (prevTs > 0) {
        deltas.push(ts - prevTs);
      }
      prevTs = ts;
      ticks += 1;

      if (ticks < PROBE_FRAME_COUNT) {
        activeRaf = requestAnimationFrame(step);
        return;
      }

      const profile = computeFrameProfile(deltas);
      if (profile.hz !== lastAppliedHz) {
        lastAppliedHz = profile.hz;
        applyFrameProfileCssVars(profile);
        onUpdate(profile);
      } else {
        applyFrameProfileCssVars(profile);
      }
    };

    activeRaf = requestAnimationFrame(step);
  };

  const bindDprWatcher = () => {
    removeDprListener?.();
    removeDprListener = null;
    dprQuery = null;
    if (typeof window.matchMedia !== 'function') return;

    const mq = window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`);
    const onDprChange = () => {
      bindDprWatcher();
      runBurst();
    };
    mq.addEventListener('change', onDprChange);
    dprQuery = mq;
    removeDprListener = () => mq.removeEventListener('change', onDprChange);
  };

  const onVisibilityChange = () => {
    if (document.visibilityState === 'hidden') {
      cancelProbe();
    } else {
      runBurst();
    }
  };

  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', onVisibilityChange);
  }
  bindDprWatcher();
  runBurst();

  return () => {
    disposed = true;
    cancelProbe();
    if (typeof document !== 'undefined') {
      document.removeEventListener('visibilitychange', onVisibilityChange);
    }
    removeDprListener?.();
    removeDprListener = null;
    dprQuery = null;
  };
}
