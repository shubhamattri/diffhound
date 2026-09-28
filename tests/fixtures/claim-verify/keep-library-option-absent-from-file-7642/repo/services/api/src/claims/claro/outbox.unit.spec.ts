// The shared setup opens a transaction against common/db; ClaimOutbox takes its
// own Knex through the constructor, so this stub only has to satisfy setup.ts.
jest.mock("../../common/db", () => {
  const fn: any = () => fn;
  fn.transaction = jest.fn(() => Promise.resolve({ rollback: async () => undefined, commit: async () => undefined }));
  return { __esModule: true, default: fn };
});
jest.mock("../../common/logger", () => {
  const chain: any = { data: () => chain, warn: () => undefined, error: () => undefined, info: () => undefined };
  return { __esModule: true, default: { event: () => chain } };
});

import { ClaimOutbox } from "./outbox";

const NOW = new Date("2026-09-17T10:00:00.000Z");

/**
 * Minimal Knex stand-in. Equality `where`, `whereIn` and `<=` comparisons are
 * applied (NULL never satisfies `<=`, as in Postgres) and any other operator throws.
 * A grouped `where(fn)`/`andWhere(fn)` narrows the same filter; `orWhere`, `orWhereExists` and
 * `whereNull` are ignored, so tests stage exactly the rows a real query would have returned.
 */
function fakeKnex(seed: Record<string, any[]> = {}) {
  const tables: Record<string, any[]> = {};
  for (const [name, rows] of Object.entries(seed)) tables[name] = rows.map((r) => ({ ...r }));
  const updates: { table: string; where: any; values: any }[] = [];

  const build = (table: string) => {
    const b: any = { _eq: {}, _in: null as null | { col: string; values: any[] }, _lte: [] as [string, any][] };
    for (const noop of ["forUpdate", "skipLocked", "orderBy", "limit", "select", "whereNull", "returning"]) {
      b[noop] = () => b;
    }
    b.where = (a: any, op?: any, val?: any) => {
      if (typeof a === "function") a(b);
      else if (typeof a === "object") Object.assign(b._eq, a);
      else if (op === "<=") b._lte.push([a, val]);
      else if (val === undefined) b._eq[a] = op;
      else if (op === "=") b._eq[a] = val;
      else throw new Error(`fakeKnex does not evaluate operator ${op}`);
      return b;
    };
    b.andWhere = (a: any, op?: any, val?: any) => b.where(a, op, val);
    // An OR branch must not narrow the main filter, so run it against a throwaway.
    b.orWhere = (a: any) => {
      if (typeof a === "function") a(build(table));
      return b;
    };
    b.orWhereExists = () => b;
    b.whereIn = (col: string, values: any[]) => {
      b._in = { col, values };
      return b;
    };
    b._rows = () =>
      (tables[table] ?? []).filter(
        (row) =>
          Object.entries(b._eq).every(([k, v]) => row[k] === v) &&
          (!b._in || b._in.values.includes(row[b._in.col])) &&
          b._lte.every(([col, val]) => row[col] != null && new Date(row[col]).getTime() <= new Date(val).getTime()),
      );
    b.first = () => Promise.resolve(b._rows()[0]);
    b.update = (values: any) => {
      const matched = b._rows();
      updates.push({ table, where: { ...b._eq }, values });
      for (const row of matched) Object.assign(row, values);
      const done: any = {
        returning: () => Promise.resolve(matched),
        then: (ok: any, err: any) => Promise.resolve(matched.length).then(ok, err),
      };
      return done;
    };
    b.then = (ok: any, err: any) => Promise.resolve(b._rows()).then(ok, err);
    return b;
  };

  const knex: any = (table: string) => build(table);
  knex.transaction = (cb: any) => cb(knex);
  knex.ref = (col: string) => col;
  knex._tables = tables;
  knex._updates = updates;
  return knex;
}

function event(over: Record<string, any> = {}) {
  return {
    id: "e1",
    command_id: "c1",
    kind: "claim.created",
    payload: {},
    state: "pending",
    attempts: 0,
    lease_token: null,
    lease_until: null,
    available_at: new Date(NOW.getTime() - 1000),
    created_at: new Date(NOW.getTime() - 5000),
    depends_on_kind: null,
    result: null,
    ...over,
  };
}

function command(over: Record<string, any> = {}) {
  return { id: "c1", receipt: { status: "registered" }, receipt_version: 1, ...over };
}

function outboxWith(rows: any[], commands: any[] = [command()]) {
  const db = fakeKnex({ claro_claim_outbox: rows, claro_claim_commands: commands });
  return { db, outbox: new ClaimOutbox(db, () => NOW) };
}

describe("ClaimOutbox", () => {
  describe("batch size", () => {
    it.each([[0], [101], [1.5], [-1]])("refuses a batch size of %s", async (limit) => {
      const { outbox } = outboxWith([event()]);

      await expect(outbox.publish(async () => undefined, limit)).rejects.toThrow("Invalid dispatch batch size");
    });
  });

  describe("publish", () => {
    it("leases a pending event and marks it queued once the queue accepts it", async () => {
      const { db, outbox } = outboxWith([event()]);

      const count = await outbox.publish(async () => undefined);

      expect(count).toBe(1);
      const row = db._tables.claro_claim_outbox[0];
      expect(row.state).toBe("queued");
      expect(row.attempts).toBe(1);
      expect(row.lease_until).toEqual(new Date(NOW.getTime() + 600000));
    });

    it("hands the queue the event id so it can deduplicate", async () => {
      const { outbox } = outboxWith([event()]);
      const enqueue = jest.fn(async () => undefined);

      await outbox.publish(enqueue);

      expect(enqueue).toHaveBeenCalledWith("e1");
    });

    it("returns an unacknowledged event to pending rather than dropping it", async () => {
      const { db, outbox } = outboxWith([event()]);

      await outbox.publish(async () => {
        throw new Error("queue down");
      });

      const row = db._tables.claro_claim_outbox[0];
      expect(row.state).toBe("pending");
      expect(row.last_error_code).toBe("queue_ack_unknown");
      expect(row.lease_token).toBeNull();
    });

    it("backs off further on each failed attempt", async () => {
      const { db, outbox } = outboxWith([event({ attempts: 2 })]);

      await outbox.publish(async () => {
        throw new Error("queue down");
      });

      // attempts becomes 3 on lease, so the delay is 3 minutes.
      const row = db._tables.claro_claim_outbox[0];
      expect(new Date(row.available_at).getTime() - NOW.getTime()).toBe(180000);
    });

    it("caps the backoff at an hour", async () => {
      const { db, outbox } = outboxWith([event({ attempts: 500 })]);

      await outbox.publish(async () => {
        throw new Error("queue down");
      });

      expect(new Date(db._tables.claro_claim_outbox[0].available_at).getTime() - NOW.getTime()).toBe(3600000);
    });
  });

  describe("execute", () => {
    it("does nothing when the event is not in a claimable state", async () => {
      const { outbox } = outboxWith([event({ state: "succeeded" })]);
      const effect = jest.fn();

      await outbox.execute("e1", effect as any);

      expect(effect).not.toHaveBeenCalled();
    });

    it("records the provider result on success", async () => {
      const { db, outbox } = outboxWith([event({ state: "queued" })]);

      await outbox.execute("e1", async () => ({ ticket: "T-1" }));

      const row = db._tables.claro_claim_outbox[0];
      expect(row.state).toBe("succeeded");
      expect(row.result).toEqual({ ticket: "T-1" });
      expect(row.last_error_code).toBeNull();
    });

    it("parks an uncertain outcome as unknown instead of retrying it", async () => {
      const { db, outbox } = outboxWith([event({ state: "queued" })]);

      await expect(
        outbox.execute("e1", async () => {
          throw new Error("provider timeout");
        }),
      ).rejects.toThrow("Follow-up outcome unknown");

      const row = db._tables.claro_claim_outbox[0];
      expect(row.state).toBe("unknown");
      expect(row.last_error_code).toBe("provider_outcome_unknown");
    });
  });

  describe("reconcileUnknown", () => {
    it("confirms an uncertain follow-up only from evidence", async () => {
      const { db, outbox } = outboxWith([event({ state: "unknown" })]);

      const confirmed = await outbox.reconcileUnknown(async () => ({ ticket: "T-9" }));

      expect(confirmed).toBe(1);
      expect(db._tables.claro_claim_outbox[0].state).toBe("succeeded");
      expect(db._tables.claro_claim_outbox[0].result).toEqual({ ticket: "T-9" });
    });

    it("leaves the record uncertain when there is no evidence", async () => {
      const { db, outbox } = outboxWith([event({ state: "unknown" })]);

      const confirmed = await outbox.reconcileUnknown(async () => null);

      expect(confirmed).toBe(0);
      expect(db._tables.claro_claim_outbox[0].state).toBe("unknown");
    });

    it("never resends when the evidence lookup itself fails", async () => {
      const { db, outbox } = outboxWith([event({ state: "unknown" })]);

      const confirmed = await outbox.reconcileUnknown(async () => {
        throw new Error("provider unreachable");
      });

      expect(confirmed).toBe(0);
      expect(db._tables.claro_claim_outbox[0].state).toBe("unknown");
    });

    it("rotates an unresolved record so one batch cannot starve later claims", async () => {
      const { db, outbox } = outboxWith([event({ state: "unknown" })]);

      await outbox.reconcileUnknown(async () => null);

      expect(new Date(db._tables.claro_claim_outbox[0].available_at).getTime() - NOW.getTime()).toBe(60000);
    });
  });

  describe("recoverInterrupted", () => {
    it("treats a crashed execution as uncertain, never as replayable", async () => {
      const expired = event({ state: "executing", lease_until: new Date(NOW.getTime() - 1) });
      const { db, outbox } = outboxWith([expired]);

      const recovered = await outbox.recoverInterrupted();

      expect(recovered).toBe(1);
      const row = db._tables.claro_claim_outbox[0];
      expect(row.state).toBe("unknown");
      expect(row.last_error_code).toBe("worker_interrupted");
    });

    it("leaves a live lease alone", async () => {
      const live = event({ state: "executing", lease_until: new Date(NOW.getTime() + 60000) });
      const { db, outbox } = outboxWith([live]);

      expect(await outbox.recoverInterrupted()).toBe(0);
      expect(db._tables.claro_claim_outbox[0].state).toBe("executing");
    });
  });

  describe("command progress", () => {
    it("reports handed_off once every follow-up has succeeded", async () => {
      const { db, outbox } = outboxWith([event({ state: "queued" })]);

      await outbox.execute("e1", async () => ({}));

      const receipt = db._tables.claro_claim_commands[0].receipt;
      expect(receipt.followupStatus).toBe("handed_off");
      expect(receipt.status).toBe("registered");
    });

    it("reports needs_review while any follow-up is uncertain", async () => {
      const { db, outbox } = outboxWith([event({ state: "queued" })]);

      await expect(
        outbox.execute("e1", async () => {
          throw new Error("provider timeout");
        }),
      ).rejects.toThrow();

      expect(db._tables.claro_claim_commands[0].receipt.followupStatus).toBe("needs_review");
    });

    it("reports pending while work is still in flight", async () => {
      const { db, outbox } = outboxWith([event()]);

      await outbox.publish(async () => undefined);

      expect(db._tables.claro_claim_commands[0].receipt.followupStatus).toBe("pending");
    });

    it("advances the receipt version so a stale read is detectable", async () => {
      const { db, outbox } = outboxWith([event()]);

      await outbox.publish(async () => undefined);

      expect(db._tables.claro_claim_commands[0].receipt_version).toBeGreaterThan(1);
    });
  });
});
