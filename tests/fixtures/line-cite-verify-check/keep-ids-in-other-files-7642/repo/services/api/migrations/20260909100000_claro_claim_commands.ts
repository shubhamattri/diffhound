import { Knex } from "knex";

export async function up(knex: Knex): Promise<void> {
  await knex.schema.createTable("claro_claim_previews", (t) => {
    t.uuid("id").primary();
    t.text("user_id").notNullable();
    t.text("org_id").notNullable();
    t.integer("schema_version").notNullable();
    t.text("validation_revision").notNullable();
    t.jsonb("facts").notNullable();
    t.jsonb("summary").notNullable();
    t.timestamp("expires_at", { useTz: true }).notNullable();
    t.timestamp("created_at", { useTz: true }).notNullable().defaultTo(knex.fn.now());
    t.index(["user_id", "org_id", "expires_at"]);
  });
  await knex.schema.createTable("claro_claim_commands", (t) => {
    t.uuid("id").primary();
    t.uuid("command_id").notNullable();
    t.uuid("preview_id").notNullable().references("id").inTable("claro_claim_previews");
    t.text("user_id").notNullable();
    t.text("org_id").notNullable();
    t.text("operation").notNullable();
    t.text("request_digest").notNullable();
    t.text("status").notNullable();
    t.text("resource_id").notNullable();
    t.jsonb("receipt").notNullable();
    t.integer("receipt_version").notNullable().defaultTo(1);
    t.timestamp("created_at", { useTz: true }).notNullable().defaultTo(knex.fn.now());
    t.timestamp("updated_at", { useTz: true }).notNullable().defaultTo(knex.fn.now());
    t.unique(["preview_id"], { indexName: "claro_claim_commands_preview_id_unique" });
    t.unique(["user_id", "org_id", "command_id"], { indexName: "claro_claim_commands_actor_command_unique" });
    t.index(["user_id", "org_id", "created_at"]);
  });
  await knex.schema.createTable("claro_claim_outbox", (t) => {
    t.uuid("id").primary();
    t.uuid("command_id").notNullable().references("id").inTable("claro_claim_commands");
    t.text("kind").notNullable();
    t.jsonb("payload").notNullable();
    t.text("state").notNullable().defaultTo("pending");
    t.integer("attempts").notNullable().defaultTo(0);
    t.timestamp("available_at", { useTz: true }).notNullable().defaultTo(knex.fn.now());
    t.timestamp("lease_until", { useTz: true });
    t.text("last_error_code");
    t.timestamp("created_at", { useTz: true }).notNullable().defaultTo(knex.fn.now());
    t.unique(["command_id", "kind"]);
    t.index(["state", "available_at"]);
  });
}

export async function down(knex: Knex): Promise<void> {
  await knex.schema.dropTable("claro_claim_outbox");
  await knex.schema.dropTable("claro_claim_commands");
  await knex.schema.dropTable("claro_claim_previews");
}
