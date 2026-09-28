import knex, { Knex } from "knex";
import { v4 as uuid } from "uuid";
import * as commandsMigration from "../../../migrations/20260909100000_claro_claim_commands";
import * as deliveryMigration from "../../../migrations/20260909101000_claro_outbox_delivery";
import * as rejectionMigration from "../../../migrations/20260909102000_claro_rejected_commands";
import * as portalMigration from "../../../migrations/20260924100000_claro_outbox_portal_intents";
import { ClaimCommandConflict, ClaimCommandNotFound, ClaimCommands, RegisterReviewedClaim } from "./commands";

// Every migration that alters these tables, in release order, so the suite runs on the production shape.
const migrations = [commandsMigration, deliveryMigration, rejectionMigration, portalMigration];
const suite = process.env.ACTION_TEST_POSTGRES_URL ? describe : describe.skip;

suite("durable claim confirmation on PostgreSQL", () => {
  let db: Knex;
  let commands: ClaimCommands;
  const actor = { userId: "member", orgId: "org" };
  const schema = "claro_command_test_" + uuid().replace(/-/g, "");
  const create: RegisterReviewedClaim = async (trx) => {
    const id = uuid();
    await trx("synthetic_claims").insert({ id });
    return {
      resourceId: id,
      receipt: { claimId: id, stage: "documents_pending" },
      followups: [{ kind: "claim.created", payload: { claimId: id } }],
    };
  };
  const tables = ["claro_claim_outbox", "claro_claim_commands", "claro_claim_previews"];
  // Column shape before each migration's up(), so every down() is checked against it, not only the last.
  const shapesBefore: Record<string, unknown>[] = [];
  const shape = async () => {
    const result: Record<string, unknown> = {};
    for (const table of tables) if (await db.schema.hasTable(table)) result[table] = await db(table).columnInfo();
    return result;
  };
  const preview = () => commands.preview(actor, { category: "hospitalization" }, "revision-1", { patient: "Self" });

  beforeAll(async () => {
    db = knex({ client: "pg", connection: process.env.ACTION_TEST_POSTGRES_URL, searchPath: [schema] });
    await db.schema.createSchema(schema);
    for (const migration of migrations) {
      shapesBefore.push(await shape());
      await migration.up(db);
    }
    await db.schema.createTable("synthetic_claims", (t) => t.uuid("id").primary());
    commands = new ClaimCommands(db);
  });
  beforeEach(async () => {
    for (const table of ["claro_claim_outbox", "claro_claim_commands", "claro_claim_previews", "synthetic_claims"])
      await db(table).delete();
  });
  // Cleanup runs even when down() leaves a table behind, so the real failure is the assertion
  // rather than a jest worker hanging on an open knex pool.
  afterAll(async () => {
    try {
      for (const table of ["claro_claim_outbox", "claro_claim_commands", "claro_claim_previews"])
        await db(table).delete();
      for (let index = migrations.length - 1; index >= 0; index--) {
        await migrations[index].down(db);
        expect(await shape()).toEqual(shapesBefore[index]);
      }
      for (const table of tables) expect(await db.schema.hasTable(table)).toBe(false);
    } finally {
      await db.schema.dropSchema(schema, true);
      await db.destroy();
    }
  });

  // 100 transactions queue behind the default pool of 10, so allow more than Jest's 5s default on a busy runner.
  it("creates one claim and follow-up under 100 concurrent deliveries, recoverable after restart", async () => {
    const review = await preview();
    const commandId = uuid();
    const receipts = await Promise.all(
      Array.from({ length: 100 }, () => commands.register(actor, commandId, review.id, create)),
    );
    expect(new Set(receipts.map((receipt) => receipt.resource_id)).size).toBe(1);
    for (const table of ["synthetic_claims", "claro_claim_commands", "claro_claim_outbox"])
      expect(await db(table).count("*").first()).toEqual({ count: "1" });
    expect((await new ClaimCommands(db).status(actor, commandId)).resource_id).toBe(receipts[0].resource_id);
  }, 30000);

  it("rolls back the claim when durable follow-up storage fails", async () => {
    const review = await preview();
    const invalid: RegisterReviewedClaim = async (trx, current) => {
      const result = await create(trx, current);
      return { ...result, followups: [...result.followups, ...result.followups] };
    };
    await expect(commands.register(actor, uuid(), review.id, invalid)).rejects.toBeInstanceOf(ClaimCommandConflict);
    for (const table of ["synthetic_claims", "claro_claim_commands", "claro_claim_outbox"])
      expect(await db(table).count("*").first()).toEqual({ count: "0" });
  });

  it("rejects changed details or another command for an already consumed preview", async () => {
    const review = await preview();
    const other = await preview();
    const commandId = uuid();
    await commands.register(actor, commandId, review.id, create);
    await expect(commands.register(actor, commandId, other.id, create)).rejects.toBeInstanceOf(ClaimCommandConflict);
    await expect(commands.register(actor, uuid(), review.id, create)).rejects.toBeInstanceOf(ClaimCommandConflict);
    expect(await db("synthetic_claims").count("*").first()).toEqual({ count: "1" });
  });

  it("rejects expired reviews, but recovers an accepted command after its review expires", async () => {
    const review = await preview();
    const commandId = uuid();
    const receipt = await commands.register(actor, commandId, review.id, create);
    await db("claro_claim_previews")
      .where({ id: review.id })
      .update({ expires_at: new Date(0) });
    expect((await commands.register(actor, commandId, review.id, create)).resource_id).toBe(receipt.resource_id);
    const expired = await preview();
    await db("claro_claim_previews")
      .where({ id: expired.id })
      .update({ expires_at: new Date(0) });
    await expect(commands.register(actor, uuid(), expired.id, create)).rejects.toBeInstanceOf(ClaimCommandConflict);
  });

  it("denies another member and another employer access to previews and receipts", async () => {
    const review = await preview();
    const commandId = uuid();
    await commands.register(actor, commandId, review.id, create);
    for (const foreign of [
      { ...actor, userId: "other" },
      { ...actor, orgId: "other" },
    ]) {
      await expect(commands.status(foreign, commandId)).rejects.toBeInstanceOf(ClaimCommandNotFound);
      await expect(commands.register(foreign, uuid(), review.id, create)).rejects.toBeInstanceOf(ClaimCommandNotFound);
      await expect(commands.find(foreign, commandId)).resolves.toBeUndefined();
    }
  });

  it("keeps only one claim when the same command ID races across different previews", async () => {
    const reviews = await Promise.all([preview(), preview()]);
    const commandId = uuid();
    const results = await Promise.allSettled(
      reviews.map((review) => commands.register(actor, commandId, review.id, create)),
    );
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter((result) => result.status === "rejected")).toHaveLength(1);
    expect(await db("synthetic_claims").count("*").first()).toEqual({ count: "1" });
  });

  it("lets two actors use the same command ID as independent commands", async () => {
    const commandId = uuid();
    const foreign = { ...actor, userId: "other" };
    const [mine, theirs] = [await preview(), await commands.preview(foreign, {}, "revision-1", {})];
    const first = await commands.register(actor, commandId, mine.id, create);
    const second = await commands.register(foreign, commandId, theirs.id, create);
    expect(first.id).toBe(commandId);
    expect(second.id).toBe(commandId);
    expect(second.resource_id).not.toBe(first.resource_id);
    expect(first).not.toHaveProperty("command_id");
    expect((await commands.status(actor, commandId)).resource_id).toBe(first.resource_id);
    expect((await commands.status(foreign, commandId)).resource_id).toBe(second.resource_id);
    expect(await db("synthetic_claims").count("*").first()).toEqual({ count: "2" });
    expect(await db("claro_claim_outbox").count("*").first()).toEqual({ count: "2" });
  });

  it("replays the same actor, command ID and digest without a second claim", async () => {
    const review = await preview();
    const commandId = uuid();
    const first = await commands.register(actor, commandId, review.id, create);
    expect((await commands.register(actor, commandId, review.id, create)).resource_id).toBe(first.resource_id);
    expect(await db("synthetic_claims").count("*").first()).toEqual({ count: "1" });
  });

  it("refuses a reused command ID when the stored request digest differs", async () => {
    const review = await preview();
    const commandId = uuid();
    await commands.register(actor, commandId, review.id, create);
    await db("claro_claim_commands")
      .where({ command_id: commandId })
      .update({ request_digest: "0".repeat(64) });
    await expect(commands.register(actor, commandId, review.id, create)).rejects.toThrow(
      "Command was already used for a different request",
    );
  });

  it("persists operation, digest, status and timestamps with the receipt", async () => {
    const review = await preview();
    const command = await commands.register(actor, uuid(), review.id, create);
    expect(command).toMatchObject({ operation: "register", status: "registered" });
    expect(command.request_digest).toMatch(/^[0-9a-f]{64}$/);
    expect(command.updated_at).toBeInstanceOf(Date);
  });

  it("names the preview uniqueness constraint", async () => {
    const review = await preview();
    await commands.register(actor, uuid(), review.id, create);
    const raced = commands.register(actor, uuid(), review.id, create);
    await expect(raced).rejects.toThrow("Preview already confirmed");
    const { rows } = await db.raw(
      "select 1 from pg_constraint c join pg_namespace n on n.oid = c.connamespace where c.conname = ? and n.nspname = current_schema()",
      ["claro_claim_commands_preview_id_unique"],
    );
    expect(rows).toHaveLength(1);
  });

  it("recovers the receipt after a crash between commit and response", async () => {
    const review = await preview();
    const commandId = uuid();
    const original = ClaimCommands.prototype.register;
    const spy = jest
      .spyOn(ClaimCommands.prototype, "register")
      .mockImplementationOnce(async function (this: ClaimCommands, ...args: Parameters<ClaimCommands["register"]>) {
        await original.apply(this, args);
        throw new Error("process died before responding");
      });
    await expect(commands.register(actor, commandId, review.id, create)).rejects.toThrow("process died");
    spy.mockRestore();

    const recovered = await new ClaimCommands(db).find(actor, commandId);
    expect(recovered?.receipt).toMatchObject({ stage: "documents_pending" });
    const retry = await commands.register(actor, commandId, review.id, create);
    expect(retry.resource_id).toBe(recovered?.resource_id);
    expect(await db("synthetic_claims").count("*").first()).toEqual({ count: "1" });
    expect(await db("claro_claim_outbox").where({ state: "pending" }).count("*").first()).toEqual({ count: "1" });
  });
});
