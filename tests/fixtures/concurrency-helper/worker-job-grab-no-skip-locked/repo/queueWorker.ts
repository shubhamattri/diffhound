import { JobModel } from './JobModel';

async function pickNextJob() {
  const job = await JobModel.query().orderBy('id').first();
  if (!job) return null;
  await JobModel.query().patchAndFetchById(job.id, { picked_at: new Date() });
  return job;
}
