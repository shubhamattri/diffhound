import axios from "axios";

// Helper currently lacks a timeout (the absence-wording finding correctly
// describes a regression — keeper despite no timeout in body).
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
