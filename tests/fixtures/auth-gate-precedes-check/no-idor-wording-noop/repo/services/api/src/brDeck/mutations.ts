export const someFunction = (ctx) => {
  ctx.ensureAuthorized((user) => user.isAdmin || user.isBatman);
};
