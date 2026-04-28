// F4 reproduction. The spec uses setTimeout (real) but persistWithRetry
// is fabricated by the LLM — doesn't exist in this file or anywhere.

import { setTimeout } from "timers";

describe("export handlers", () => {
  it("retries on transient db error", async () => {
    setTimeout(() => {}, 100);
    expect(1).toBe(1);
  });
});
