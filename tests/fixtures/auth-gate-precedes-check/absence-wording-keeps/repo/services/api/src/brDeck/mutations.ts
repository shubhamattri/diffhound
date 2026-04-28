export const deleteBrDeckJobMutation = mutationWithClientMutationId({
  async mutateAndGetPayload(input, ctx) {
    ctx.ensureAuthorized((user) => user.isAdmin || user.isBatman);
  },
});
