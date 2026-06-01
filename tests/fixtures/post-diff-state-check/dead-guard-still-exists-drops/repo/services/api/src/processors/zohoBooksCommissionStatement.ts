// post-diff state of the file: the guard is STILL HERE in this version.
export async function backfill(entries) {
  for (const entry of entries) {
    const matches = await findSalesOrderMatch(entry);
    if (matches.length === 1) {
      const matchedSalesOrder = matches[0];
      // line 117 below — this guard is what the bot called "dead"
      if (!matchedSalesOrder) {
        continue;
      }
      await updateCommissionEntryRecord(entry, matchedSalesOrder);
    }
  }
}
