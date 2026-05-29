// Minimal stand-in: declares the policy + enforcement function.
// In the real repo this is the file the bot cited as REACHABLE_PATH.

interface UploadPolicy { extensions: string[]; mimeTypes: string[]; }

const UPLOAD_POLICIES: Partial<Record<string, UploadPolicy>> = {
  ClaimDocument: {
    extensions: ["pdf", "jpg", "jpeg", "png", "webp"],
    mimeTypes: ["application/pdf", "image/jpeg", "image/png", "image/webp"],
  },
};

export function assertUploadAllowed(action: string | undefined, filename: string): void {
  if (!action || !(action in UPLOAD_POLICIES)) return;
  const policy = UPLOAD_POLICIES[action]!;
  const ext = (filename.split(".").pop() || "").toLowerCase();
  if (!policy.extensions.includes(ext)) throw new Error("disallowed");
}
