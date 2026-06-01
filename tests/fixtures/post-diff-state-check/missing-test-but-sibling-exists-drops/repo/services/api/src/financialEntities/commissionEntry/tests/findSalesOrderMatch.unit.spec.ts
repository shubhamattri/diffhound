// new sibling test file added in the same diff — bot missed this
import { findSalesOrderMatch } from "../policyNormalizers/specMap";

describe("findSalesOrderMatch", () => {
  it("returns null for endorsement CEs (entryType guard)", () => {
    expect(findSalesOrderMatch({ entryType: "Endorsement" }, { spec: {} })).toBeNull();
  });
  it("requires the spec param", () => {
    expect(() => findSalesOrderMatch({ entryType: "Inception" })).toThrow();
  });
});
