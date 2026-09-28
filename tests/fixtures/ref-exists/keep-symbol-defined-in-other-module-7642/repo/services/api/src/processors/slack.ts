import { WebClient } from "@slack/web-api";
import { Job } from "bull";
import { toGlobalId } from "graphql-relay";
import { postEventToPosthog } from "nova-common/utils/posthog.js";
import { Context } from "../common/context";
import logger from "../common/logger";
import { PosthogEvent } from "../tsTypes/enums";
import { userByIdDataLoader } from "../user/handlers/users";

// How long an identical alert stays suppressed. A broken record stays broken until a human
// fixes it, so the useful cadence is one reminder a day, not one per Bull retry.
const DEDUP_TTL_SECONDS = 24 * 60 * 60;

// SET NX EX is atomic, so concurrent processor instances cannot both win the key and
// double-post. Redis being unreachable must never swallow an alert, hence the fail-open.
async function claimDedupKey(redis: any, dedupKey: string): Promise<boolean> {
  try {
    const result = await redis.set(dedupKey, "1", "EX", DEDUP_TTL_SECONDS, "NX");
    return result === "OK";
  } catch (error) {
    logger
      .event("SlackQueue")
      .data({ dedupKey, error: (error as Error)?.message })
      .warn("Dedup check failed, posting anyway");
    return true;
  }
}

async function releaseDedupKey(redis: any, dedupKey: string): Promise<void> {
  try {
    await redis.del(dedupKey);
  } catch (error) {
    logger
      .event("SlackQueue")
      .data({ dedupKey, error: (error as Error)?.message })
      .warn("Dedup key release failed; the retry may be suppressed");
  }
}

// Routing an alert at a channel that does not exist yet makes Slack answer channel_not_found,
// which the catch below swallows. The alert then disappears entirely, which is worse than
// landing somewhere nobody reads. Fall back to the default channel so a missing channel
// degrades to today's behaviour instead of silent loss.
async function postWithFallback(slack: WebClient, channel: string | undefined, text: string) {
  try {
    await slack.chat.postMessage({ channel, text, link_names: true });
  } catch (error: any) {
    const fallback = process.env.NOVA_BOT_CHANNEL;
    if (error?.data?.error !== "channel_not_found" || !fallback || channel === fallback) throw error;
    logger
      .event("SlackQueue")
      .data({ channel, fallback })
      .warn("Channel not found, falling back to the default channel");
    await slack.chat.postMessage({
      channel: fallback,
      text: `[routed here because '${channel}' does not exist]\n${text}`,
      link_names: true,
    });
  }
}

export function registerProcessors(q) {
  const slack = new WebClient(process.env.SLACK_TOKEN);

  // Delivery is separated from analytics so a retry can only ever re-send an undelivered
  // message. strictDelivery callers opt into Bull retries instead of a swallowed failure.
  q.slackQueue.process(async (job: Job) => {
    let claimedKey = false;
    try {
      if (job.data.dedupKey) {
        if (!(await claimDedupKey(q.slackQueue.client, job.data.dedupKey))) return;
        claimedKey = true;
      }
      await postWithFallback(slack, job.data.channel || process.env.NOVA_BOT_CHANNEL, job.data.message);
    } catch (error) {
      // Release first: the retry would otherwise find its own key claimed and skip the post.
      if (job.data.strictDelivery && claimedKey) await releaseDedupKey(q.slackQueue.client, job.data.dedupKey);
      await postEventToPosthog(PosthogEvent.SlackMessageError, job.id, {
        channel: job.data.channel,
        message: job.data.message,
        error: error,
      });
      // An undelivered alert is invisible unless this is queryable; a previous alerting
      // gap went unnoticed for months for exactly this reason.
      logger
        .event("SlackQueue")
        .data({ channel: job.data.channel, error: (error as Error)?.message })
        .error("Failed to deliver Slack message");
      if (job.data.strictDelivery) throw error;
      return;
    }
    if (!job.data.claim) return;
    try {
      const ctx = new Context();
      const claim = job.data.claim;
      const user = await userByIdDataLoader(ctx).load(claim.user_id);
      await postEventToPosthog(PosthogEvent.ClaimIntimatedSlack, toGlobalId("User", user.id), {
        email: user.email,
        employeeId: user.meta.employeeId,
        orgName: user.org,
        claim: claim,
      });
    } catch (error) {
      logger
        .event("SlackQueue")
        .data({ channel: job.data.channel, error: (error as Error)?.message })
        .error("Claim intimation analytics failed after the message was delivered");
    }
  });
}
