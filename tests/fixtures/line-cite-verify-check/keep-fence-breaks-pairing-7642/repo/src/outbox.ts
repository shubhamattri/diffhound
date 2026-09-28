export function lease(row) {
  let leaseRow = row;
  leaseRow = next(leaseRow);
  return leaseRow;
}
