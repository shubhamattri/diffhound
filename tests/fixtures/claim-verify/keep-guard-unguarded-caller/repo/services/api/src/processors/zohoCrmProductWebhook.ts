import { CustomError } from "../utils/errors";

// Account-manager problems go to the KAM channel; engineer-only ones go to tech.
function reportFailureToSlack(
  err: unknown,
  payload: ZohoCrmProductPayload,
  crmProduct: CrmProduct | null,
  closingSlipFileName: string | undefined,
): void {
  const subject = {
    productId: payload.productId,
    productName: crmProduct?.Product_Name || payload.productName,
    productStage: payload.productStage,
    closingSlipFileName,
  };
  pushWebhookAlertToSlack(WebhookAlertType.ZOHO_CRM_PRODUCT_WEBHOOK, subject, err);
}

export function registerProcessors(q) {
  q.zohoCrmProductWebhookQueue.process(async (job: BullQueue.Job): Promise<ProcessResult> => {
    const payload: ZohoCrmProductPayload | undefined = job.data?.payload;
    if (!payload?.productId) {
      throw new CustomError("Job payload missing productId — webhook route should have rejected");
    }
    job.log(`Processing Zoho CRM Product webhook for ${payload.productId} (${payload.productName})`);
    let crmProduct: CrmProduct | null = null;
    let closingSlip: { id: string; File_Name: string } | null = null;
    try {
      crmProduct = await fetchCrmProduct(payload.productId);
      return { status: "created", productId: payload.productId };
    } catch (err) {
      logger.error(`Error processing CRM Product webhook: ${(err as Error)?.message}`);
      reportFailureToSlack(err, payload, crmProduct, closingSlip?.File_Name);
      throw err;
    }
  });
  q.retryQueue.process(async (job) => {
    reportFailureToSlack(new Error("retry"), job.data?.payload, null, undefined);
  });
}
