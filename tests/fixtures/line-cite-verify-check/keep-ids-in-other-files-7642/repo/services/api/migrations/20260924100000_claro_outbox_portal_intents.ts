import { Knex } from "knex";

/** Portal claim writes have no Claro command, so their queue hand-off intents carry no command. */
export async function up(db: Knex): Promise<void> {
  await db.schema.alterTable("claro_claim_outbox", (table) => table.uuid("command_id").nullable().alter());
}

export async function down(db: Knex): Promise<void> {
  const pending = await db("claro_claim_outbox").whereNull("command_id").first("id");
  if (pending) throw new Error("Preserve portal hand-off intents; disable the dispatcher instead of dropping them");
  await db.schema.alterTable("claro_claim_outbox", (table) => table.uuid("command_id").notNullable().alter());
}
