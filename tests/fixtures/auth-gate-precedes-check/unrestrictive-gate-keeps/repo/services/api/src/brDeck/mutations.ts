export const someMutation = mutationWithClientMutationId({
  name: "SomeMutation",
  async mutateAndGetPayload(input, ctx) {
    // userCanAccessBrDeck returns true for account admins — non-restrictive
    ctx.ensureAuthorized(userCanAccessBrDeck);
    const result = await doSomething(input.id);
    return { result };
  },
});
