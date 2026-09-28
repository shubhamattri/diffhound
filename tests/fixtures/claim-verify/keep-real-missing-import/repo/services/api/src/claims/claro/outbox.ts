import { Knex } from "knex";

export async function lease(trx: Knex.Transaction) {
  return trx("claro_claim_outbox").update({ lease_id: randomUUID() });
}
