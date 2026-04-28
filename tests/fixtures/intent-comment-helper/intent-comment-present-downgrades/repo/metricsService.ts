function tatPerMonth(months: Array<{ avgTat: number }>) {
  // Average TAT always over 3 months; no-endorsement months count as 0 (zero-padded).
  const overallAvgTat = Math.round(months.reduce((s, m) => s + m.avgTat, 0) / months.length);
  return overallAvgTat;
}
