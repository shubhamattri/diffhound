import axios from "axios";

// Helper genuinely lacks a timeout — finding should NOT be dropped.
export async function fetchCrmProductStartDate(
  productId: string,
  accessToken: string,
  baseUrl: string,
): Promise<string | null> {
  const { data } = await axios.get(`${baseUrl}/Products/${productId}`, {
    headers: { Authorization: `Zoho-oauthtoken ${accessToken}` },
  });
  return data?.data?.[0]?.Start_Date ?? null;
}
