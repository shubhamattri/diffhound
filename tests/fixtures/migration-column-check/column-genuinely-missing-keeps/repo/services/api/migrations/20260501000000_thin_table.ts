import { Knex } from "knex";

export async function up(knex: Knex): Promise<void> {
  await knex.schema.createTable("thin_table", (table) => {
    table.uuid("id").primary();
    table.string("name", 64).notNullable();
  });
}

export async function down(knex: Knex): Promise<void> {
  await knex.schema.dropTableIfExists("thin_table");
}
