import { db } from './db';
import { UserModel } from './UserModel';
import { AuditModel } from './AuditModel';

async function safeUpdate(userId: number, balance: number) {
  return await db.transaction(async (trx) => {
    const user = await UserModel.query(trx).findById(userId).forUpdate();
    await UserModel.query(trx).patchAndFetchById(userId, { balance });
    return user;
  });
}

// Padding so the unsafe function is well past the transaction's scope close.
// Line 14
// Line 15
// Line 16
// Line 17
// Line 18
// Line 19
// Line 20
// Line 21
// Line 22
// Line 23
// Line 24
// Line 25
// Line 26
// Line 27

async function unsafeUpdate(userId: number, balance: number) {
  await UserModel.query().patchAndFetchById(userId, { balance });
  await AuditModel.query().insert({ userId, action: 'unsafe_update' });
}
