import { Knex } from "knex";

// Per Gemini peer review: dropColumn references the literal "old_status"
// but in a removal context, not a definition. A.1 must NOT match this
// because no .text/.string/.uuid/etc. type-prefix wraps the literal.
export async function up(knex: Knex): Promise<void> {
  await knex.schema.alterTable("orders", (table) => {
    table.dropColumn("old_status");
  });
}

export async function down(knex: Knex): Promise<void> {
  await knex.schema.alterTable("orders", (table) => {
    table.string("old_status", 64).nullable();
  });
}
