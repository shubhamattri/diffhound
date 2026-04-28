import { db } from './db';
import { JobModel } from './JobModel';

async function processJob(jobId: number) {
  return await db.transaction(async (trx) => {
    const job = await JobModel.query(trx).findById(jobId).forUpdate();
    if (!job) return null;
    await JobModel.query(trx).patchAndFetchById(jobId, { status: 'processing' });
    return job.id;
  });
}
