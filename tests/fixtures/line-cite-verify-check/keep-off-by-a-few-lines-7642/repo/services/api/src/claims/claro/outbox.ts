import { Knex } from "knex";
import { v4 as uuid } from "uuid";
import logger from "../../common/logger";

export interface ClaimFollowup {
  id: string;
  command_id: string | null;
  kind: string;
  payload: Record<string, unknown>;
  state: string;
  attempts: number;
  lease_token: string | null;
  lease_until: Date | null;
}

const QUEUED_RECHECK_MS = 600000;

/** Queue acknowledgement can be retried by ID; an external write cannot. */
export class ClaimOutbox {
  constructor(private readonly db: Knex, private readonly now: () => Date = () => new Date()) {}

  private dependencyReady(query: Knex.QueryBuilder): void {
    query.whereNull("depends_on_kind").orWhereExists((dependency) => {
      dependency
        .select("prerequisite.id")
        .from("claro_claim_outbox as prerequisite")
        .where("prerequisite.command_id", this.db.ref("claro_claim_outbox.command_id"))
        .where("prerequisite.kind", this.db.ref("claro_claim_outbox.depends_on_kind"))
        .where("prerequisite.state", "succeeded");
    });
  }

  /** Portal hand-off rows have no command receipt to keep in step. */
  private commandIds(rows: ClaimFollowup[]): string[] {
    return [...new Set(rows.flatMap((row) => (row.command_id ? [row.command_id] : [])))].sort();
  }

  private async updateProgress(trx: Knex.Transaction, commandId: string): Promise<void> {
    const command = await trx("claro_claim_commands").where({ id: commandId }).forUpdate().first();
    const steps: { kind: string; state: string; result: Record<string, unknown> | null }[] = await trx(
      "claro_claim_outbox",
    )
      .where({ command_id: commandId })
      .select("kind", "state", "result")
      .orderBy("kind");
    const followupStatus = steps.some((step) => step.state === "unknown")
      ? "needs_review"
      : steps.every((step) => step.state === "succeeded")
      ? "handed_off"
      : "pending";
    await trx("claro_claim_commands")
      .where({ id: commandId })
      .update({
        receipt: { ...command.receipt, followupStatus, followups: steps },
        receipt_version: command.receipt_version + 1,
        updated_at: this.now(),
      });
  }

  private async lease(limit: number): Promise<ClaimFollowup[]> {
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new Error("Invalid dispatch batch size");
    return this.db.transaction(async (trx) => {
      const rows = await trx<ClaimFollowup>("claro_claim_outbox")
        .andWhere((query) => this.dependencyReady(query))
        .where("available_at", "<=", this.now())
        .andWhere((query) =>
          query
            .where("state", "pending")
            .orWhere((expired) => expired.where("state", "dispatching").andWhere("lease_until", "<=", this.now()))
            // A queued row that never started may have lost its job; republishing reuses the same job ID.
            .orWhere((stale) => stale.where("state", "queued").andWhere("lease_until", "<=", this.now())),
        )
        .orderBy("created_at")
        .limit(limit)
        .forUpdate()
        .skipLocked();
      const leased: ClaimFollowup[] = [];
      for (const row of rows) {
        const [updated] = await trx<ClaimFollowup>("claro_claim_outbox")
          .where({ id: row.id })
          .update({
            state: "dispatching",
            lease_token: uuid(),
            attempts: row.attempts + 1,
            lease_until: new Date(this.now().getTime() + 60000),
          })
          .returning("*");
        leased.push(updated);
      }
      for (const commandId of this.commandIds(rows)) await this.updateProgress(trx, commandId);
      return leased;
    });
  }

  private async change(event: ClaimFollowup, states: string[], values: Record<string, unknown>): Promise<void> {
    await this.db.transaction(async (trx) => {
      const changed = await trx("claro_claim_outbox")
        .where({ id: event.id, lease_token: event.lease_token })
        .whereIn("state", states)
        .update(values);
      if (changed && event.command_id) await this.updateProgress(trx, event.command_id);
    });
  }

  /** enqueue must deduplicate by the supplied event ID and retain its job record. */
  async publish(enqueue: (eventId: string) => Promise<unknown>, limit = 20): Promise<number> {
    const events = await this.lease(limit);
    for (const event of events) {
      try {
        await enqueue(event.id);
        await this.change(event, ["dispatching"], {
          state: "queued",
          lease_until: new Date(this.now().getTime() + QUEUED_RECHECK_MS),
        });
      } catch (error) {
        logger
          .event("claroFollowupQueueUnavailable")
          .data({ eventId: event.id, category: (error as Error).name })
          .warn("Follow-up queue acknowledgement unavailable");
        await this.change(event, ["dispatching"], {
          state: "pending",
          lease_token: null,
          lease_until: null,
          last_error_code: "queue_ack_unknown",
          available_at: new Date(this.now().getTime() + Math.min(60000 * event.attempts, 3600000)),
        });
      }
    }
    return events.length;
  }

  /** Claim execution durably before calling a provider. Duplicate jobs cannot rerun it. */
  async execute(eventId: string, effect: (event: ClaimFollowup) => Promise<Record<string, unknown>>): Promise<void> {
    const event = await this.db.transaction(async (trx) => {
      const [row] = await trx<ClaimFollowup>("claro_claim_outbox")
        .where({ id: eventId })
        .whereIn("state", ["pending", "dispatching", "queued"])
        .andWhere((query) => this.dependencyReady(query))
        .update({ state: "executing", lease_token: uuid(), lease_until: new Date(this.now().getTime() + 600000) })
        .returning("*");
      if (row?.command_id) await this.updateProgress(trx, row.command_id);
      return row;
    });
    if (!event) return;
    try {
      const result = await effect(event);
      await this.change(event, ["executing", "unknown"], {
        state: "succeeded",
        result,
        completed_at: this.now(),
        lease_until: null,
        last_error_code: null,
      });
    } catch (error) {
      logger
        .event("claroFollowupOutcomeUnknown")
        .data({ eventId: event.id, kind: event.kind, category: (error as Error).name })
        .error("Follow-up requires reconciliation; it will not be replayed");
      await this.change(event, ["executing"], {
        state: "unknown",
        lease_until: null,
        last_error_code: "provider_outcome_unknown",
      });
      throw new Error("Follow-up outcome unknown");
    }
  }

  /** Resolve uncertain work only from evidence; absence never authorizes a resend. */
  async reconcileUnknown(evidence: (event: ClaimFollowup) => Promise<Record<string, unknown> | null>): Promise<number> {
    const events = await this.db<ClaimFollowup>("claro_claim_outbox")
      .where("state", "unknown")
      .where("available_at", "<=", this.now())
      .orderBy("available_at")
      .limit(100);
    let confirmed = 0;
    for (const event of events) {
      try {
        const result = await evidence(event);
        if (!result) continue;
        await this.change(event, ["unknown"], {
          state: "succeeded",
          result,
          completed_at: this.now(),
          lease_until: null,
          last_error_code: null,
        });
        confirmed++;
      } catch (error) {
        logger
          .event("claroFollowupEvidenceUnavailable")
          .data({ eventId: event.id, category: (error as Error).name })
          .warn("Follow-up remains uncertain; no resend attempted");
      } finally {
        // Rotate unresolved records so one old batch cannot starve later claims.
        await this.db("claro_claim_outbox")
          .where({ id: event.id, state: "unknown", lease_token: event.lease_token })
          .update({ available_at: new Date(this.now().getTime() + 60000) });
      }
    }
    return confirmed;
  }

  /** Work an operator must see when no dispatcher is running or an outcome is uncertain. */
  async backlog(): Promise<Record<string, number>> {
    const rows: { state: string; count: string }[] = await this.db("claro_claim_outbox")
      .whereIn("state", ["pending", "dispatching", "queued", "unknown"])
      .groupBy("state")
      .select("state")
      .count({ count: "*" });
    return Object.fromEntries(rows.map((row) => [row.state, Number(row.count)]));
  }

  /** Steps an operator must act on: uncertain outcomes, or work still waiting after `staleAfterMs`. */
  async needingReview(staleAfterMs = 3600000, limit = 100): Promise<Record<string, unknown>[]> {
    const staleBefore = new Date(this.now().getTime() - staleAfterMs);
    return this.db("claro_claim_outbox as step")
      .leftJoin("claro_claim_commands as command", "command.id", "step.command_id")
      .where("step.state", "unknown")
      .orWhere((waiting) =>
        waiting
          .whereIn("step.state", ["pending", "dispatching", "queued"])
          .andWhere("step.created_at", "<=", staleBefore),
      )
      .orderBy("step.created_at")
      .limit(limit)
      .select(
        "step.id",
        "step.command_id",
        "command.command_id as client_command_id",
        "command.resource_id as claim_id",
        "step.kind",
        "step.state",
        "step.attempts",
        "step.last_error_code",
        "step.created_at",
      );
  }

  /** A crashed execution is ambiguous, never a pending job eligible for replay. */
  async recoverInterrupted(): Promise<number> {
    return this.db.transaction(async (trx) => {
      const rows = await trx<ClaimFollowup>("claro_claim_outbox")
        .where("state", "executing")
        .andWhere("lease_until", "<=", this.now())
        .forUpdate()
        .skipLocked()
        .limit(100);
      for (const row of rows) {
        await trx("claro_claim_outbox")
          .where({ id: row.id })
          .update({ state: "unknown", last_error_code: "worker_interrupted" });
      }
      for (const commandId of this.commandIds(rows)) await this.updateProgress(trx, commandId);
      return rows.length;
    });
  }
}
