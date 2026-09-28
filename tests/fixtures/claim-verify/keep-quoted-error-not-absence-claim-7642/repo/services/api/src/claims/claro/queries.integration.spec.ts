import { graphql, GraphQLObjectType, GraphQLSchema } from "graphql";
import { toGlobalId } from "graphql-relay";

jest.mock("../../common/db", () => {
  const knex = require("knex");
  const schema = "claro_test_" + require("crypto").randomBytes(8).toString("hex");
  return {
    __esModule: true,
    default: knex({
      client: "pg",
      connection: process.env.ACTION_TEST_POSTGRES_URL,
      searchPath: [schema],
      userParams: { schema },
    }),
  };
});
jest.mock("../../orgProperty/handler", () => ({
  ...jest.requireActual("../../orgProperty/handler"),
  getOrgPropertyByNameAndOrgId: async () => ({ meta: { MANDATORY_CLAIM_DOCS_FLOW: true } }),
}));

import db from "../../common/db";
import { claroClaimPreparation } from "./queries";

const schema = new GraphQLSchema({
  query: new GraphQLObjectType({
    name: "Query",
    fields: { claroClaimPreparation },
  }),
});
const query = `query Prepare($input: ClaroClaimPreparationInput) {
  claroClaimPreparation(input: $input) {
    revision
    fieldErrors
    missingFields
    missingDocuments
    readyForReview
    normalized { policyId patientId category estimatedClaimAmount }
    policies { id name }
    patients { id name }
    capabilities { canExecute canGenerateFormA canAutoAttachPreviousDocuments }
  }
}`;
const suite = process.env.ACTION_TEST_POSTGRES_URL ? describe : describe.skip;

suite("authorized read-only claim preparation", () => {
  const previousFlag = process.env.CLARO_CLAIM_REGISTRATION_ENABLED;
  beforeAll(async () => {
    process.env.CLARO_CLAIM_REGISTRATION_ENABLED = "true";
    await db.schema.createSchema(db.userParams.schema);
    await db.schema.createTable("users", (t) => {
      t.string("id").primary();
      t.string("org_id");
      t.string("status");
    });
    await db("users").insert([
      { id: "u", org_id: "o", status: "created" },
      { id: "gone", org_id: "o", status: "suspended" },
      { id: "other", org_id: "other-org", status: "created" },
    ]);
    await db.schema.createTable("benefits", (t) => {
      t.string("id").primary();
      t.string("name");
      t.string("type");
      t.string("status");
      t.boolean("is_policy");
      t.jsonb("meta");
    });
    await db.schema.createTable("org_benefits", (t) => {
      t.string("org_id");
      t.string("benefit_id");
      t.string("status");
    });
    await db.schema.createTable("user_benefits", (t) => {
      t.string("user_id");
      t.string("benefit_id");
      t.string("status");
      t.jsonb("meta");
    });
    await db.schema.createTable("dependents", (t) => {
      t.string("id").primary();
      t.string("name");
      t.string("user_id");
      t.string("status");
      t.boolean("is_retail");
      t.timestamp("deleted_at");
    });
    await db.schema.createTable("dependent_benefits", (t) => {
      t.string("dependent_id");
      t.string("benefit_id");
      t.string("status");
    });
    await db("benefits").insert({
      id: "p",
      name: "Synthetic cover",
      type: "gmc",
      status: "created",
      is_policy: true,
      meta: {},
    });
    await db("org_benefits").insert({ org_id: "o", benefit_id: "p", status: "created" });
    await db("user_benefits").insert({ user_id: "u", benefit_id: "p", status: "created", meta: {} });
    await db("dependents").insert([
      { id: "d", user_id: "u", name: "Synthetic spouse", status: "created", is_retail: false },
      { id: "foreign", user_id: "other", name: "Foreign member", status: "created", is_retail: false },
      { id: "pending", user_id: "u", name: "Pending member", status: "enrollment-pending", is_retail: false },
    ]);
    await db("dependent_benefits").insert(
      ["d", "foreign", "pending"].map((id) => ({ dependent_id: id, benefit_id: "p", status: "created" })),
    );
  });
  afterAll(async () => {
    if (previousFlag === undefined) delete process.env.CLARO_CLAIM_REGISTRATION_ENABLED;
    else process.env.CLARO_CLAIM_REGISTRATION_ENABLED = previousFlag;
    await db.schema.dropSchema(db.userParams.schema, true);
    await db.destroy();
  });

  function context(id = "u", org = "o", isOrgMember = true) {
    const user = { id, org_id: org, isOrgMember };
    return {
      user,
      ensureAuthorized(check: (actor: typeof user) => boolean) {
        if (!check(user)) throw new Error("Unauthorized");
      },
    };
  }
  it("derives identity from context and excludes foreign and pending dependents", async () => {
    const before = await db("user_benefits").count("*").first();
    const result = await graphql({
      schema,
      source: query,
      contextValue: context(),
      variableValues: { input: { policyId: toGlobalId("Benefit", "p") } },
    });
    expect(result.errors).toBeUndefined();
    const prepared = result.data?.claroClaimPreparation as { patients: { id: string }[] };
    expect(prepared.patients.map((p) => p.id)).toEqual([toGlobalId("User", "u"), toGlobalId("Dependent", "d")]);
    expect(await db("user_benefits").count("*").first()).toEqual(before);
  });
  it("returns the typed preparation contract", async () => {
    const result = await graphql({
      schema,
      source: query,
      contextValue: context(),
      variableValues: { input: { policyId: toGlobalId("Benefit", "p"), category: "daycare", doa: "2026-01-05" } },
    });
    expect(result.errors).toBeUndefined();
    const prepared = result.data?.claroClaimPreparation as {
      revision: string;
      normalized: { category: string };
      policies: { id: string; name: string }[];
      missingFields: string[];
      missingDocuments: string[];
      capabilities: { canExecute: boolean };
    };
    expect(prepared.revision).toMatch(/^[0-9a-f]{64}$/);
    expect(prepared.normalized.category).toBe("daycare");
    expect(prepared.policies).toEqual([{ id: toGlobalId("Benefit", "p"), name: "Synthetic cover" }]);
    expect(prepared.missingFields).toContain("contact");
    expect(prepared.missingDocuments.length).toBeGreaterThan(0);
    expect(prepared.capabilities.canExecute).toBe(false);
  });
  it("lists exactly the policies getPoliciesByUserId treats as live (status created)", async () => {
    const statuses = ["deleted", "expired", "suspended"];
    for (const status of statuses) {
      await db("benefits").insert({
        id: "s-" + status,
        name: status,
        type: "gmc",
        status: "created",
        is_policy: true,
        meta: {},
      });
      await db("org_benefits").insert({ org_id: "o", benefit_id: "s-" + status, status: "created" });
      await db("user_benefits").insert({ user_id: "u", benefit_id: "s-" + status, status, meta: {} });
    }
    const result = await graphql({ schema, source: query, contextValue: context() });
    expect(result.errors).toBeUndefined();
    const prepared = result.data?.claroClaimPreparation as { policies: { id: string }[] };
    expect(prepared.policies.map((p) => p.id)).toEqual([toGlobalId("Benefit", "p")]);
  });
  it("does not expose employer mappings to another org or member", async () => {
    // A real member of another employer gets only their own (empty) coverage, never org o's.
    const foreign = await graphql({ schema, source: query, contextValue: context("other", "other-org") });
    expect(foreign.errors).toBeUndefined();
    const prepared = foreign.data?.claroClaimPreparation as { policies: unknown[]; patients: unknown[] };
    expect(prepared.policies).toEqual([]);
    expect(prepared.patients).toEqual([]);
    expect(JSON.stringify(foreign.data)).not.toContain(toGlobalId("Benefit", "p"));
    // Claiming another employer's member ID, or their own ID under the wrong org, is refused outright.
    for (const ctx of [context("other", "o"), context("u", "other-org")]) {
      const result = await graphql({ schema, source: query, contextValue: ctx });
      expect(result.errors?.[0].message).toBe("Member access is no longer active");
      expect(result.data).toBeNull();
    }
  });
  it("refuses a suspended member and a disabled feature flag like the mutations do", async () => {
    const suspended = await graphql({ schema, source: query, contextValue: context("gone") });
    expect(suspended.errors?.[0].message).toBe("Member access is no longer active");
    process.env.CLARO_CLAIM_REGISTRATION_ENABLED = "false";
    try {
      const disabled = await graphql({ schema, source: query, contextValue: context() });
      expect(disabled.errors?.[0].message).toBe("Claim registration through Claro is not enabled");
    } finally {
      process.env.CLARO_CLAIM_REGISTRATION_ENABLED = "true";
    }
  });
  it("rejects anonymous/admin-only callers and client actor overrides", async () => {
    const denied = await graphql({ schema, source: query, contextValue: context("u", "o", false) });
    expect(denied.errors?.map((error) => error.message)).toEqual(["Unauthorized"]);
    const override = await graphql({
      schema,
      source: query,
      contextValue: context(),
      variableValues: { input: { userId: "other" } },
    });
    expect(override.errors).toHaveLength(1);
    expect(override.errors?.[0].message).toContain(
      'Field "userId" is not defined by type "ClaroClaimPreparationInput"',
    );
  });
});
