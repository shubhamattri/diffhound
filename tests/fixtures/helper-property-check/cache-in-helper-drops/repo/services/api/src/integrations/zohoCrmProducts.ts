import { createZohoTokenCache } from "./zohoTokenCache";

const tokenCache = createZohoTokenCache(async () => "stub-token", {
  ttlMs: 50 * 60 * 1000,
  safetyMs: 60 * 1000,
});

export const getZohoCrmAccessToken = tokenCache.getAccessToken;
