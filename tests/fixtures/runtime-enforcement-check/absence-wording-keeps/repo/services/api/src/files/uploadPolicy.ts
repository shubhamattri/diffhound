// Same shape as pr7297 case — no callers in claims dir. Absence-wording
// exemption should keep the finding anyway because it describes a regression.
interface UploadPolicy { extensions: string[]; mimeTypes: string[]; }
const UPLOAD_POLICIES: Partial<Record<string, UploadPolicy>> = {
  ClaimDocument: { extensions: ["pdf"], mimeTypes: ["application/pdf"] },
};
export function assertUploadAllowed(action: string | undefined, filename: string): void {
  if (!action || !(action in UPLOAD_POLICIES)) return;
}
