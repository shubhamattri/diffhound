import { COMPLETED_JOB_RETENTION, FAILED_JOB_RETENTION } from "./jobRetention";

/** Bull only retries a processor that throws, so the payload must also carry `strictDelivery: true`. */
export function strictSlackDelivery(jobId: string) {
  return {
    jobId,
    attempts: 3,
    backoff: { type: "exponential", delay: 30000 },
    removeOnComplete: COMPLETED_JOB_RETENTION,
    removeOnFail: FAILED_JOB_RETENTION,
  };
}

/** Options for a strict claim-ticket job, which must never be retried by Bull.
 *
 * `handleClaimTicketUpdates` deliberately notifies the member first and only
 * then rethrows a Zoho Desk failure, so the missing ticket is visible without
 * costing the member their update. That ordering is only safe while the job does
 * not retry: `sendNotifications` has no reservation or dedupe key, so a second
 * attempt sends the member a second notification.
 *
 * `claimTicketUpdateQueue` defaults to `attempts: 3`, so a strict job that takes
 * the default is exactly the duplicate-notification case. Build the options here
 * rather than at each call site, so the two cannot drift apart.
 */
export function strictClaimTicketDelivery(jobId: string) {
  return {
    jobId,
    attempts: 1,
    removeOnComplete: COMPLETED_JOB_RETENTION,
    removeOnFail: FAILED_JOB_RETENTION,
  };
}
