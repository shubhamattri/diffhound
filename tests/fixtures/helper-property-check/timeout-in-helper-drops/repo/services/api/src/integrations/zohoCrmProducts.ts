import axios from "axios";

const ZOHO_REQUEST_TIMEOUT_MS = 15_000;

export async function fetchCrmProductStartDate(
  productId: string,
  accessToken: string,
  baseUrl: string,
): Promise<string | null> {
  const { data } = await axios.get(`${baseUrl}/Products/${productId}`, {
    headers: { Authorization: `Zoho-oauthtoken ${accessToken}` },
    timeout: ZOHO_REQUEST_TIMEOUT_MS,
  });
  return data?.data?.[0]?.Start_Date ?? null;
}
