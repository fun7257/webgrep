/**
 * O(log n) binary search helper for variable-height virtual scroll offset tables.
 * Assumes `offsets` has length >= `count + 1` and is monotonically non-decreasing.
 * Returns the largest index `i` in `0 .. count - 1` such that `offsets[i] <= y`.
 */
export function indexAtY(offsets: Float64Array, count: number, y: number): number {
  if (count <= 1) return 0;
  let lo = 0;
  let hi = count - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (offsets[mid] <= y) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}
