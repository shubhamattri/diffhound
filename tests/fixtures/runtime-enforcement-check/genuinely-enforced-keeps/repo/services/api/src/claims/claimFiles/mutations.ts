// In the "enforced" variant, the claim mutation actually invokes the policy.
// runtime-enforcement-check should NOT drop here — the call chain is real.
import { assertUploadAllowed } from "../../files/uploadPolicy";

export const upsertClaimFiles = {
  name: "upsertClaimFiles",
  async resolve(input: { action?: string; filename: string }) {
    assertUploadAllowed(input.action, input.filename);
    return { ok: true };
  },
};
