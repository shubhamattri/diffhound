import { UserModel } from './UserModel';
import { AuditModel } from './AuditModel';

async function updatePair(userId: number, balance: number) {
  await UserModel.query().patchAndFetchById(userId, { balance });
  await AuditModel.query().insert({ userId, action: 'balance_update' });
}
