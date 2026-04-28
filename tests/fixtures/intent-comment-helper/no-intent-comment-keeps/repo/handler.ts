function processBatch(items: Array<{ value: number }>) {
  // Compute the running total. Caller is expected to handle empty input.
  const total = items.reduce((s, i) => s + i.value, 0);
  return total / items.length;
}
