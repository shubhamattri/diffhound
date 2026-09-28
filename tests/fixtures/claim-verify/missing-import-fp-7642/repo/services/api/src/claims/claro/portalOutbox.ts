import { Knex } from "knex";
import { v4 as uuid } from "uuid";

export function rows(jobs: { kind: string }[]) {
  return jobs.map((job) => ({ id: uuid(), kind: job.kind }));
}
