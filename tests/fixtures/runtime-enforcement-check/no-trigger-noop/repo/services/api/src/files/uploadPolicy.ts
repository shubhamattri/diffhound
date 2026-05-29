interface UploadPolicy { extensions: string[]; mimeTypes: string[]; }
const UPLOAD_POLICIES: Partial<Record<string, UploadPolicy>> = {
  ClaimDocument: { extensions: ["pdf"], mimeTypes: ["application/pdf"] },
};
export function assertUploadAllowed(action: string | undefined, filename: string): void {
  if (!action || !(action in UPLOAD_POLICIES)) return;
}
