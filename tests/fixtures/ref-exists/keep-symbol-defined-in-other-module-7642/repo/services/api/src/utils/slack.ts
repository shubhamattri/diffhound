import { createHash } from "crypto";
import moment from "moment-timezone";
import * as uuid from "uuid";
import logger from "../common/logger";
import { slackQueue } from "../common/queues";
import { crmProductDeepLink } from "../integrations/zohoCrmLinks";
import { WebhookAlertType, WebhookSlackChannels } from "../tsTypes/enums/webhook";

const webhookAlertResolver: Partial<Record<WebhookAlertType, (obj: any) => string>> = {
  [WebhookAlertType.EKINCARE]: ({ booking_id, appointment_id, type, status }: any) =>
    `Ekincare Request Type: ${type}\nBooking Id: ${booking_id}\nAppointment Id: ${appointment_id}\nAppointment Status: ${status}`,
  [WebhookAlertType.EKINCARE_NEW_TEST_COMPONENT]: ({ test_component_id, test_component_name, appointment_id }: any) =>
    `Test Component Id: ${test_component_id}\nTest Component Name: ${test_component_name}\nAppointment Id: ${appointment_id}`,
  [WebhookAlertType.RAZORPAY]: ({ payment }: any) => `Entity Id: ${payment?.entity?.id}`,
  [WebhookAlertType.RAZORPAY_WEBHOOK_JOB]: ({ payment }: any) => `Entity Id: ${payment?.entity?.id}`,
  // BX-3826 — a policy did NOT make it into Claro's corpus. `terminal` means the
  // document was permanently declined and will not be retried; the remedy line
  // says so explicitly because the org keeps answering from the OLD policy until
  // someone acts.
  [WebhookAlertType.CLARO_REINGEST]: ({ orgId, benefitId, policyName, reason, terminal }: any) =>
    `Org Id: ${orgId}\nBenefit Id: ${benefitId}\nPolicy: ${policyName}\nReason: ${reason}\n` +
    (terminal
      ? "Outcome: PERMANENTLY REJECTED — not retried. Claro still serves the previous policy version. " +
        "If a corrected file was re-uploaded to the same S3 key, clear org_benefits.meta.claroIngestRejected to allow a retry."
      : "Outcome: retries exhausted — Claro still serves the previous policy version."),
};

// Types that own their whole message rather than the generic field dump. A field dump makes
// the reader reassemble the meaning; these put the subject and the required action first.
const webhookAlertFormatter: Partial<Record<WebhookAlertType, (obj: any, errorDetail: string) => string>> = {
  [WebhookAlertType.ZOHO_CRM_PRODUCT_WEBHOOK]: (
    { productId, productName, productStage, accountName, ownerName, closingSlipFileName, isSetupDataError }: any,
    errorDetail: string,
  ) => {
    const subject = [accountName, productName].filter(Boolean).join(" — ") || `CRM Product ${productId}`;
    const headline = isSetupDataError
      ? `Closing slip needs a fix — ${subject}`
      : `CRM Product sync failed — ${subject}`;
    const lines = [headline];
    if (ownerName) lines.push(`Owner: ${ownerName}`);
    if (productStage) lines.push(`Product Stage: ${productStage}`);
    if (closingSlipFileName) lines.push(`File: ${closingSlipFileName}`);
    lines.push("", errorDetail, "");
    lines.push(
      isSetupDataError
        ? "Nova creates the policy on its own once this is corrected and the Product is saved again."
        : "This one is not a data-entry problem. It needs an engineer.",
    );
    lines.push(`<${crmProductDeepLink(productId)}|Open the CRM Product>`);
    return lines.join("\n");
  },
};

const webhookAlertChannelMap: Partial<Record<WebhookAlertType, string>> = {
  [WebhookAlertType.RAZORPAY]: WebhookSlackChannels.RAZORPAY,
  [WebhookAlertType.RAZORPAY_WEBHOOK_JOB]: WebhookSlackChannels.RAZORPAY,
  [WebhookAlertType.EKINCARE]: WebhookSlackChannels.EKINCARE,
  [WebhookAlertType.EKINCARE_NEW_TEST_COMPONENT]: WebhookSlackChannels.EKINCARE,
  [WebhookAlertType.CLARO_REINGEST]: WebhookSlackChannels.CLARO,
  [WebhookAlertType.ZOHO_CRM_PRODUCT_WEBHOOK]: WebhookSlackChannels.CRM_PRODUCT_SETUP,
};

// `@here` on a recurring alert teaches the room to mute the channel, so the one time it
// matters nobody looks. Kept only where it already was, so this change does not alter the
// notification behaviour of alerts other teams already rely on.
const webhookAlertBroadcast: Partial<Record<WebhookAlertType, boolean>> = {
  [WebhookAlertType.EKINCARE]: true,
  [WebhookAlertType.EKINCARE_NEW_TEST_COMPONENT]: true,
  [WebhookAlertType.RAZORPAY]: true,
  [WebhookAlertType.RAZORPAY_WEBHOOK_JOB]: true,
  [WebhookAlertType.TALLY_WEBHOOK_JOB]: true,
  [WebhookAlertType.ZOHO_BOOKS_COMMISSION_STATEMENT_WEBHOOK]: true,
  [WebhookAlertType.CLARO_REINGEST]: true,
};

// The thing the alert is about. Combined with the error text this is the dedup key, so a Bull
// retry of the same failure does not re-post. Without it the same broken Product alerted eight
// times in ten minutes.
const webhookAlertEntityId: Partial<Record<WebhookAlertType, (obj: any) => string | undefined>> = {
  [WebhookAlertType.ZOHO_CRM_PRODUCT_WEBHOOK]: ({ productId }: any) => productId,
  [WebhookAlertType.CLARO_REINGEST]: ({ benefitId }: any) => benefitId,
  [WebhookAlertType.RAZORPAY]: ({ payment }: any) => payment?.entity?.id,
  [WebhookAlertType.RAZORPAY_WEBHOOK_JOB]: ({ payment }: any) => payment?.entity?.id,
  [WebhookAlertType.EKINCARE]: ({ appointment_id }: any) => appointment_id,
  [WebhookAlertType.EKINCARE_NEW_TEST_COMPONENT]: ({ appointment_id }: any) => appointment_id,
};

// These channels exist in the production workspace but not in every non-prod one, where a
// missing channel turns the alert into a silent `channel_not_found`. An env override lets
// those environments point the alert somewhere that exists without shipping a code change.
const webhookAlertChannelEnvOverride: Partial<Record<WebhookAlertType, string>> = {
  [WebhookAlertType.CLARO_REINGEST]: "CLARO_ALERT_SLACK_CHANNEL",
  [WebhookAlertType.ZOHO_CRM_PRODUCT_WEBHOOK]: "CRM_PRODUCT_ALERT_SLACK_CHANNEL",
};

function resolveAlertChannel(webhookAlertType: WebhookAlertType): string | undefined {
  const envVar = webhookAlertChannelEnvOverride[webhookAlertType];
  return (envVar && process.env[envVar]) || webhookAlertChannelMap[webhookAlertType];
}

// `scrubAxiosError` and friends hand us a plain object to keep the OAuth bearer token out of
// Slack. Calling toString() on one yields "[object Object]", which is what every CRM Product
// alert carried until now.
export function describeError(err: any): string {
  if (err === null || err === undefined) return "No error detail was captured.";
  if (typeof err === "string") return err;
  const status = err.status ?? err.response?.status;
  const message = err.message || (typeof err.toString === "function" ? err.toString() : "");
  if (message && message !== "[object Object]") {
    return status ? `${message} (HTTP ${status})` : message;
  }
  try {
    return JSON.stringify(err);
  } catch {
    return "Error detail could not be serialised.";
  }
}

export function pushWebhookAlertToSlack(webhookAlertType: WebhookAlertType, obj: any, err: any) {
  const alertId = uuid.v4();
  logger.event("webhook alert").error(JSON.stringify({ alertId, webhookRequest: obj }));
  const errorDetail = describeError(err);
  const formatter = webhookAlertFormatter[webhookAlertType];

  let message: string;
  if (formatter) {
    message = formatter(obj, errorDetail);
  } else {
    const resolver = webhookAlertResolver[webhookAlertType];
    const alertMetaData = resolver ? resolver(obj) : JSON.stringify(obj);
    const timestampIST = `Timestamp (ist): ${moment().tz("Asia/Kolkata").format("YYYY-MM-DD HH:mm:ss")}\n`;
    message = `Alert Id: ${alertId}\nType: ${webhookAlertType}-failure-alert\n${timestampIST}${alertMetaData}\nError:\n\`\`\`${errorDetail}\`\`\``;
  }
  if (webhookAlertBroadcast[webhookAlertType]) message = `@here 🚨\n${message}`;

  const entityId = webhookAlertEntityId[webhookAlertType]?.(obj);
  const dedupKey = entityId
    ? `webhook-alert:${webhookAlertType}:${entityId}:${createHash("sha1").update(errorDetail).digest("hex")}`
    : undefined;

  slackQueue.add({ message, channel: resolveAlertChannel(webhookAlertType), dedupKey });
}
