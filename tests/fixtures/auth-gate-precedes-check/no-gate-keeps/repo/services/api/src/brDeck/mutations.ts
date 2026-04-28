export const unguardedMutation = mutationWithClientMutationId({
  name: "Unguarded",
  async mutateAndGetPayload(input, ctx) {
    const result = await doSomething(input.id);
    return { result };
  },
});
