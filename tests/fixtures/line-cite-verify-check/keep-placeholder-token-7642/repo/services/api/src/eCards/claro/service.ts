import { createHash } from "crypto";
import db from "../../common/db";
import logger from "../../common/logger";
import { NotificationModel } from "../../models/notification";
import { ECardNotification } from "../../notifications/ECardNotification";
import { ILoggedInUser } from "../../tsTypes/interfaces/user";
import { NotificationChannels, NotificationChannelStatus } from "../../types/notification";
import { EcardBlockedReason, EcardCommandConflict, EcardCommandNotFound, EcardCommands } from "./commands";
import { EcardEmailPreparation, EcardEmailSelection, prepareEcardEmail } from "./preparation";

type ReadyEcard = Extract<EcardEmailPreparation, { status: "ready" }>;
const actor = (member: ILoggedInUser) => ({ userId: member.id, orgId: member.org_id });
const enabled = () => process.env.CLARO_ECARD_EMAIL_ENABLED === "true";

type CurrentTarget = { ready: ReadyEcard } | { blocked: EcardBlockedReason };
async function currentTarget(member: ILoggedInUser, selection: EcardEmailSelection): Promise<CurrentTarget> {
  if (!enabled()) return { blocked: "email_action_paused" };
  const target = await prepareEcardEmail(member, selection);
  return target.status === "ready" ? { ready: target } : { blocked: target.reason };
}

/** Exclude expiring signed URLs: consent binds recipient and coverage, not URL TTL. */
export function ecardReviewRevision(target: ReadyEcard): string {
  return createHash("sha256")
    .update(
      JSON.stringify([
        1,
        target.userId,
        target.orgId,
        target.policyId,
        target.patientId,
        target.recipient,
        target.policyName,
        target.patientName,
      ]),
    )
    .digest("hex");
}

/** Produce a masked review; card URLs and full email addresses stay server-side. */
export async function prepareReviewedEcard(member: ILoggedInUser, selection: EcardEmailSelection) {
  if (!enabled()) return { status: "blocked", reason: "email_action_paused" };
  const target = await prepareEcardEmail(member, selection);
  if (target.status !== "ready") return target;
  const [local, domain] = target.recipient.split("@");
  const preview = await new EcardCommands(db).preview(actor(member), selection, ecardReviewRevision(target), {
    action: "Email this e-card to your registered email",
    patient: target.patientName,
    policy: target.policyName,
    recipient: `${local[0]}***@${domain}`,
  });
  return { status: "review", previewId: preview.id, summary: preview.summary, expiresAt: preview.expires_at };
}

/** Read-only recovery. A stored notification alone proves neither queueing nor delivery. */
export async function ecardEmailStatus(member: ILoggedInUser, commandId: string) {
  const command = await new EcardCommands(db).find(actor(member), commandId);
  if (!command) throw new EcardCommandNotFound("Command not found");
  if (["sending", "unknown", "queued"].includes(command.state)) {
    const notification = await NotificationModel.getNotificationById(command.notification_id);
    if (notification && notification.userId === member.id && notification.orgId === member.org_id) {
      const email = notification.channels.find((channel) => channel.name === NotificationChannels.Email);
      if (email?.status === NotificationChannelStatus.Sent)
        return { commandId, status: "sent", inboxDeliveryVerified: false };
      if (email?.status === NotificationChannelStatus.Failed) return { commandId, status: "failed" };
    }
  }
  return { commandId, status: command.state === "sending" ? "unknown" : command.state, receipt: command.receipt };
}

/** Repeated confirmation observes the original intent instead of creating another send. */
export async function confirmReviewedEcard(member: ILoggedInUser, commandId: string, previewId: string) {
  const commands = new EcardCommands(db);
  const existing = await commands.find(actor(member), commandId);
  if (existing) {
    if (existing.preview_id !== previewId) throw new EcardCommandConflict("Command details changed");
  } else {
    const preview = await commands.getPreview(actor(member), previewId);
    const current = await currentTarget(member, preview.selection);
    await commands.confirm(
      actor(member),
      commandId,
      previewId,
      "ready" in current ? ecardReviewRevision(current.ready) : null,
      "blocked" in current ? current.blocked : undefined,
    );
  }
  await deliverEcardEmail(member, commandId);
  return ecardEmailStatus(member, commandId);
}

/** Claim once, revalidate, then publish with the reserved ID. Never retries an uncertain send. */
export async function deliverEcardEmail(member: ILoggedInUser, commandId: string): Promise<void> {
  const commands = new EcardCommands(db);
  if (!(await commands.find(actor(member), commandId))) throw new EcardCommandNotFound("Command not found");
  const command = await commands.claimDelivery(commandId);
  if (!command) return;
  let publishing = false;
  try {
    const preview = await commands.getPreview(actor(member), command.preview_id);
    const current = await currentTarget(member, preview.selection);
    if ("blocked" in current) {
      await commands.finish(commandId, "blocked", { status: "blocked", reason: current.blocked });
      return;
    }
    const target = current.ready;
    if (ecardReviewRevision(target) !== preview.revision) {
      await commands.finish(commandId, "blocked", { status: "blocked", reason: "review_changed" });
      return;
    }
    publishing = true;
    const result = await new ECardNotification(
      {
        userId: target.userId,
        eCardUrl: target.ecardUrl,
        expectedRecipient: target.recipient,
        expectedOrgId: target.orgId,
      },
      [NotificationChannels.Email],
    ).queue(command.notification_id);
    await commands.finish(commandId, result.status, result);
  } catch (error) {
    logger.error(publishing ? "Claro e-card command outcome unknown" : "Claro e-card failed before publication", {
      commandId,
      errorType: error instanceof Error ? error.name : "unknown",
      errorMessage: error instanceof Error ? error.message : undefined,
    });
    // Nothing reached the broker before publication starts, so that failure is definite, not uncertain.
    if (publishing) await commands.finish(commandId, "unknown", { status: "unknown" });
    else await commands.finish(commandId, "blocked", { status: "blocked", reason: "preparation_failed" });
  }
}
