// This module computes endorsement averages.
// Averages are intentionally taken over a fixed 3-month window (zero-padded)
// because the dashboard is calibrated against quarterly slots.

function unrelatedHelper() {
  return "ok";
}

function freshlyAddedFn(values: number[]) {
  // No intent comment near this line.
  return Math.round(values.reduce((s, v) => s + v, 0) / values.length);
}
