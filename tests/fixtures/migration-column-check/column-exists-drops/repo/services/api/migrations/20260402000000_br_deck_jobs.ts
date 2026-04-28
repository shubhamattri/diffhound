import { Knex } from "knex";

export async function up(knex: Knex): Promise<void> {
  await knex.schema.createTable("br_deck_job_files", (table) => {
    table.uuid("id").primary();
    table.uuid("job_id").notNullable();
    table.string("file_type", 64).notNullable();
    table.string("file_name", 255).notNullable();
    table.text("file_path").notNullable();
    table.string("status", 64).notNullable();
  });
}

export async function down(knex: Knex): Promise<void> {
  await knex.schema.dropTableIfExists("br_deck_job_files");
}
