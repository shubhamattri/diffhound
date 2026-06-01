// existing test file but it covers an unrelated symbol — `quxHandler` is genuinely absent
import { otherFn } from "../otherModule";

describe("otherFn", () => {
  it("does the other thing", () => {
    expect(otherFn()).toBe(true);
  });
});
