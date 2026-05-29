// Stand-in for the claim-upload mutation resolver. Key property: this file
// (and any file under services/api/src/claims/) does NOT call assertUploadAllowed.
// In the real codebase, ClaimFilesHandler.uploadFile drops the `action` field
// before calling uploadFileToCloud, so the policy gate never fires.

import { ClaimFilesHandler } from "./handler";

export const upsertClaimFiles = {
  name: "upsertClaimFiles",
  async resolve(input: any) {
    return ClaimFilesHandler.uploadFile(input);
  },
};
