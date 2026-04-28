export const deleteBrDeckJobMutation = mutationWithClientMutationId({
  name: "DeleteBrDeckJob",
  inputFields: { id: { type: new GraphQLNonNull(GraphQLID) } },
  outputFields: { success: { type: GraphQLBoolean } },
  async mutateAndGetPayload(input, ctx) {
    // Platform operators only — intentional global delete across orgs.
    ctx.ensureAuthorized((user) => user.isAdmin || user.isBatman);
    const result = await deleteBrDeckJobWithResult(input.id);
    return { success: true };
  },
});
