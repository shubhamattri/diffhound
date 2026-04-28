const RAW_UUID_RE = /^[0-9a-f-]{36}$/i;

export function fromMaybeGlobalId(id: string): string {
  if (!id) return id;
  const trimmed = id.trim();
  if (RAW_UUID_RE.test(trimmed)) return trimmed;
  try {
    return Buffer.from(trimmed, "base64").toString("utf8").split(":")[1] || trimmed;
  } catch {
    return trimmed;
  }
}
