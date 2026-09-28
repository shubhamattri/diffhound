// The shared test setup opens a transaction against common/db, so it is stubbed
// here even though these tests inject their own fake Knex into ClaimCommands.
jest.mock("../../common/db", () => {
  const fn: any = () => fn;
  fn.transaction = jest.fn(() => Promise.resolve({ rollback: async () => undefined, commit: async () => undefined }));
  return { __esModule: true, default: fn };
});

import { ClaimCommandConflict, ClaimCommandNotFound, ClaimCommands, claimRequestDigest } from "./commands";

const ACTOR = { userId: "u1", orgId: "o1" };
const PREVIEW_ID = "p1";
const COMMAND_ID = "c1";

interface FakeState {
  rows: Record<string, any[]>;
  inserts: { table: string; payload: any }[];
}

function fakeKnex(rows: Record<string, any[]> = {}): any {
  const state: FakeState = { rows, inserts: [] };
  const builder = (table: string) => {
    const b: any = { _where: {} };
    // Only the object form is filtered, so any other clause shape must fail loudly.
    b.where = (clause: unknown, ...rest: unknown[]) => {
      if (rest.length || typeof clause !== "object" || clause === null) throw new Error("unsupported where clause");
      Object.assign(b._where, clause);
      return b;
    };
    b.forUpdate = () => b;
    b.first = () =>
      Promise.resolve(
        (state.rows[table] ?? []).find((row) => Object.entries(b._where).every(([key, value]) => row[key] === value)),
      );
    b.insert = (payload: any) => {
      state.inserts.push({ table, payload });
      b._inserted = payload;
      return b;
    };
    b.returning = () => Promise.resolve(Array.isArray(b._inserted) ? b._inserted : [b._inserted]);
    b.then = (onOk: any, onErr: any) => Promise.resolve(b._inserted).then(onOk, onErr);
    return b;
  };
  const knex: any = (table: string) => builder(table);
  knex.transaction = (cb: any) => cb(knex);
  knex._state = state;
  return knex;
}

function preview(over: Record<string, any> = {}) {
  return {
    id: PREVIEW_ID,
    user_id: ACTOR.userId,
    org_id: ACTOR.orgId,
    schema_version: 1,
    validation_revision: "rev-1",
    facts: {} as any,
    summary: {},
    expires_at: new Date(Date.now() + 60_000),
    ...over,
  };
}

function command(over: Record<string, any> = {}) {
  return {
    id: "row-" + COMMAND_ID,
    command_id: COMMAND_ID,
    preview_id: PREVIEW_ID,
    user_id: ACTOR.userId,
    org_id: ACTOR.orgId,
    operation: "register",
    request_digest: claimRequestDigest(PREVIEW_ID, preview() as any),
    status: "registered",
    resource_id: "claim-1",
    receipt: { ok: true },
    receipt_version: 1,
    ...over,
  };
}

const registration = { resourceId: "claim-1", receipt: { ok: true }, followups: [] as any[] };

describe("ClaimCommands", () => {
  describe("member identity", () => {
    it.each([
      ["no user", { userId: "", orgId: "o1" }],
      ["no org", { userId: "u1", orgId: "" }],
    ])("refuses an actor with %s", async (_label, actor) => {
      const commands = new ClaimCommands(fakeKnex());

      await expect(commands.find(actor as any, COMMAND_ID)).rejects.toThrow(ClaimCommandNotFound);
    });
  });

  describe("preview", () => {
    it("stores a server-prepared summary scoped to the member", async () => {
      const db = fakeKnex();
      const commands = new ClaimCommands(db);

      const stored = await commands.preview(ACTOR, {} as any, "rev-9", { total: 100 });

      expect(stored.user_id).toBe("u1");
      expect(stored.org_id).toBe("o1");
      expect(stored.schema_version).toBe(1);
      expect(stored.validation_revision).toBe("rev-9");
      expect(stored.summary).toEqual({ total: 100 });
      expect(db._state.inserts[0].table).toBe("claro_claim_previews");
    });

    it("expires the review window five minutes out", async () => {
      const commands = new ClaimCommands(fakeKnex());

      const stored = await commands.preview(ACTOR, {} as any, "rev-1", {});

      const seconds = (new Date(stored.expires_at).getTime() - Date.now()) / 1000;
      expect(seconds).toBeGreaterThan(290);
      expect(seconds).toBeLessThanOrEqual(300);
    });
  });

  describe("status and lookup", () => {
    it("returns a command the member owns", async () => {
      const commands = new ClaimCommands(fakeKnex({ claro_claim_commands: [command()] }));

      expect((await commands.status(ACTOR, COMMAND_ID)).resource_id).toBe("claim-1");
    });

    it("treats another member's command as not found", async () => {
      const commands = new ClaimCommands(fakeKnex({ claro_claim_commands: [command({ user_id: "someone-else" })] }));

      await expect(commands.status(ACTOR, COMMAND_ID)).rejects.toThrow(ClaimCommandNotFound);
    });

    it("returns undefined from find when nothing matches", async () => {
      const commands = new ClaimCommands(fakeKnex());

      expect(await commands.find(ACTOR, COMMAND_ID)).toBeUndefined();
    });

    it("returns a preview the member owns", async () => {
      const commands = new ClaimCommands(fakeKnex({ claro_claim_previews: [preview()] }));

      expect((await commands.getPreview(ACTOR, PREVIEW_ID)).id).toBe(PREVIEW_ID);
    });

    it("rejects a preview belonging to another org", async () => {
      const commands = new ClaimCommands(fakeKnex({ claro_claim_previews: [preview({ org_id: "other" })] }));

      await expect(commands.getPreview(ACTOR, PREVIEW_ID)).rejects.toThrow(ClaimCommandNotFound);
    });
  });

  describe("register", () => {
    it("writes the claim, its receipt and its follow-ups together", async () => {
      const db = fakeKnex({ claro_claim_previews: [preview()] });
      const commands = new ClaimCommands(db);

      const result = await commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, async () => ({
        ...registration,
        followups: [{ kind: "notify", payload: { to: "member" } }],
      }));

      expect(result.id).toBe(COMMAND_ID);
      expect(result.resource_id).toBe("claim-1");
      expect(db._state.inserts.map((i: any) => i.table)).toEqual(["claro_claim_commands", "claro_claim_outbox"]);
      expect(db._state.inserts[1].payload[0].kind).toBe("notify");
    });

    it("skips the outbox when there are no follow-ups", async () => {
      const db = fakeKnex({ claro_claim_previews: [preview()] });
      const commands = new ClaimCommands(db);

      await commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, async () => registration);

      expect(db._state.inserts.map((i: any) => i.table)).toEqual(["claro_claim_commands"]);
    });

    it("is idempotent when the same command id is replayed", async () => {
      const db = fakeKnex({ claro_claim_commands: [command()], claro_claim_previews: [preview()] });
      const commands = new ClaimCommands(db);
      const register = jest.fn();

      const result = await commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, register as any);

      expect(result.id).toBe(COMMAND_ID);
      expect(result).not.toHaveProperty("command_id");
      expect(register).not.toHaveBeenCalled();
      expect(db._state.inserts).toHaveLength(0);
    });

    it("refuses a replay that points at a different preview", async () => {
      const db = fakeKnex({
        claro_claim_commands: [command({ preview_id: "other-preview" })],
        claro_claim_previews: [preview()],
      });
      const commands = new ClaimCommands(db);
      const attempt = commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, async () => registration);

      await expect(attempt).rejects.toThrow(ClaimCommandConflict);
      await expect(attempt).rejects.toThrow("Command identity is already in use");
    });

    it("ignores a command id owned by another member instead of conflicting or leaking it", async () => {
      const db = fakeKnex({
        claro_claim_commands: [
          command({ user_id: "someone-else", preview_id: "their-preview", resource_id: "their-claim" }),
        ],
        claro_claim_previews: [preview()],
      });
      const commands = new ClaimCommands(db);

      const result = await commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, async () => registration);

      expect(result.resource_id).toBe("claim-1");
      expect(result.id).toBe(COMMAND_ID);
      expect(db._state.inserts[0].payload).toMatchObject({ user_id: "u1", command_id: COMMAND_ID });
    });

    it("refuses a replay whose frozen review no longer matches the stored digest", async () => {
      const db = fakeKnex({
        claro_claim_commands: [command({ request_digest: "0".repeat(64) })],
        claro_claim_previews: [preview()],
      });
      const commands = new ClaimCommands(db);

      await expect(commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, async () => registration)).rejects.toThrow(
        "Command was already used for a different request",
      );
    });

    it("records the operation, status and digest on the command", async () => {
      const db = fakeKnex({ claro_claim_previews: [preview()] });
      const commands = new ClaimCommands(db);

      await commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, async () => registration);

      expect(db._state.inserts[0].payload).toMatchObject({
        operation: "register",
        status: "registered",
        request_digest: claimRequestDigest(PREVIEW_ID, preview() as any),
      });
    });

    it("reports a missing preview rather than registering", async () => {
      const commands = new ClaimCommands(fakeKnex());

      await expect(commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, async () => registration)).rejects.toThrow(
        ClaimCommandNotFound,
      );
    });

    it("refuses when a concurrent confirmation already claimed the preview", async () => {
      const db = fakeKnex({
        claro_claim_previews: [preview()],
        claro_claim_commands: [command({ command_id: "another-command" })],
      });
      const commands = new ClaimCommands(db);

      await expect(commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, async () => registration)).rejects.toThrow(
        "Preview already confirmed",
      );
    });

    it.each([
      ["an expired review window", { expires_at: new Date(Date.now() - 1000) }],
      ["an unknown schema version", { schema_version: 2 }],
    ])("refuses %s", async (_label, over) => {
      const db = fakeKnex({ claro_claim_previews: [preview(over)] });
      const commands = new ClaimCommands(db);

      await expect(commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, async () => registration)).rejects.toThrow(
        ClaimCommandConflict,
      );
    });

    it.each([
      ["claro_claim_commands_preview_id_unique", "Preview already confirmed"],
      ["claro_claim_commands_pkey", "Command identity is already in use"],
      ["claro_claim_commands_actor_command_unique", "Command identity is already in use"],
      ["claro_claim_outbox_command_id_kind_unique", "Conflicting follow-up identity"],
    ])("maps a %s violation to a distinct conflict", async (constraint, message) => {
      const db = fakeKnex({ claro_claim_previews: [preview()] });
      const commands = new ClaimCommands(db);

      const attempt = commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, async () => {
        throw Object.assign(new Error("duplicate key"), { code: "23505", constraint });
      });

      await expect(attempt).rejects.toThrow(ClaimCommandConflict);
      await expect(attempt).rejects.toThrow(message);
    });

    it("lets an unrelated failure surface unchanged", async () => {
      const db = fakeKnex({ claro_claim_previews: [preview()] });
      const commands = new ClaimCommands(db);

      await expect(
        commands.register(ACTOR, COMMAND_ID, PREVIEW_ID, async () => {
          throw new Error("nova unreachable");
        }),
      ).rejects.toThrow("nova unreachable");
    });
  });

  describe("reject", () => {
    it("seals a durable rejection carrying the reason", async () => {
      const db = fakeKnex({ claro_claim_previews: [preview()] });
      const commands = new ClaimCommands(db);

      const rejected: any = await commands.reject(ACTOR, COMMAND_ID, PREVIEW_ID, "review_changed");

      expect(rejected.receipt).toEqual({
        status: "rejected",
        reason: "review_changed",
        followupStatus: "not_started",
      });
      expect(rejected.resource_id).toBeNull();
      expect(rejected.id).toBe(COMMAND_ID);
      const { payload } = db._state.inserts[0];
      expect(db._state.inserts[0].table).toBe("claro_claim_commands");
      expect(payload).toMatchObject({
        command_id: COMMAND_ID,
        operation: "register",
        status: "rejected",
        request_digest: claimRequestDigest(PREVIEW_ID, preview() as any),
      });
      expect(payload.id).not.toBe(COMMAND_ID);
      expect(payload.updated_at).toBeInstanceOf(Date);
    });

    it("records a paused registration under its own reason", async () => {
      const commands = new ClaimCommands(fakeKnex({ claro_claim_previews: [preview()] }));

      const rejected: any = await commands.reject(ACTOR, COMMAND_ID, PREVIEW_ID, "registration_paused");

      expect(rejected.receipt.reason).toBe("registration_paused");
    });

    it("reports a missing preview rather than sealing anything", async () => {
      const commands = new ClaimCommands(fakeKnex());

      await expect(commands.reject(ACTOR, COMMAND_ID, PREVIEW_ID, "review_changed")).rejects.toThrow(
        ClaimCommandNotFound,
      );
    });

    it("returns a registered command unchanged rather than overwriting it with a rejection", async () => {
      const db = fakeKnex({ claro_claim_previews: [preview()], claro_claim_commands: [command()] });
      const commands = new ClaimCommands(db);

      const rejected: any = await commands.reject(ACTOR, COMMAND_ID, PREVIEW_ID, "review_changed");

      expect(rejected.id).toBe(COMMAND_ID);
      expect(rejected.resource_id).toBe("claim-1");
      expect(db._state.inserts).toHaveLength(0);
    });

    it("is idempotent when an already rejected command is replayed", async () => {
      const sealed = command({
        resource_id: null,
        receipt: { status: "rejected", reason: "review_changed", followupStatus: "not_started" },
      });
      const db = fakeKnex({ claro_claim_previews: [preview()], claro_claim_commands: [sealed] });
      const commands = new ClaimCommands(db);

      const rejected: any = await commands.reject(ACTOR, COMMAND_ID, PREVIEW_ID, "registration_paused");

      expect(rejected.resource_id).toBeNull();
      expect(rejected.receipt.reason).toBe("review_changed");
      expect(db._state.inserts).toHaveLength(0);
    });

    it("refuses a command id that belongs to another member", async () => {
      const db = fakeKnex({
        claro_claim_previews: [preview()],
        claro_claim_commands: [command({ user_id: "someone-else", org_id: "another-org" })],
      });
      const commands = new ClaimCommands(db);

      await expect(commands.reject(ACTOR, COMMAND_ID, PREVIEW_ID, "review_changed")).rejects.toThrow(
        ClaimCommandConflict,
      );
      expect(db._state.inserts).toHaveLength(0);
    });

    it("refuses to reuse a command id against a different preview", async () => {
      const db = fakeKnex({
        claro_claim_previews: [preview()],
        claro_claim_commands: [command({ preview_id: "a-different-preview" })],
      });
      const commands = new ClaimCommands(db);

      await expect(commands.reject(ACTOR, COMMAND_ID, PREVIEW_ID, "review_changed")).rejects.toThrow(
        ClaimCommandConflict,
      );
      expect(db._state.inserts).toHaveLength(0);
    });

    it("refuses to reject a preview that was already confirmed", async () => {
      const db = fakeKnex({
        claro_claim_previews: [preview()],
        claro_claim_commands: [command({ command_id: "another-command" })],
      });
      const commands = new ClaimCommands(db);

      await expect(commands.reject(ACTOR, COMMAND_ID, PREVIEW_ID, "review_changed")).rejects.toThrow(
        "Preview already confirmed",
      );
    });
  });
});
