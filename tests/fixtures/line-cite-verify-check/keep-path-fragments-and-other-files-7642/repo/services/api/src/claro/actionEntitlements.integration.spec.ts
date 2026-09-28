import { graphql, GraphQLObjectType, GraphQLSchema } from "graphql";
import { toGlobalId } from "graphql-relay";
import { INACTIVE_MEMBER_STATUSES } from "../claims/claro/access";
import db from "../common/db";
import { UserStatus } from "../tsTypes/enums";
import { claroActionEntitlements } from "./actionEntitlements";

jest.mock("../common/db", () => ({
  __esModule: true,
  default: require("knex")({
    client: "pg",
    connection: process.env.ACTION_TEST_POSTGRES_URL,
    searchPath: ["capabilities_" + require("crypto").randomBytes(8).toString("hex")],
  }),
}));
jest.mock("../orgProperty/handler", () => ({
  getOrgPropertyByNameAndOrgId: async () => ({ meta: {} }),
  getOrgPropertyRowByNameAndOrgId: async (_name, org) => ({
    meta: { CLAIMS_PORTAL_EXPERIENCE: true, CHECKUP_BOOKING: org !== "disabled-org" },
  }),
}));

const schema = new GraphQLSchema({
  query: new GraphQLObjectType({ name: "Query", fields: { claroActionEntitlements } }),
});
const suite = process.env.ACTION_TEST_POSTGRES_URL ? describe : describe.skip;
const user = (org = "org", id = "member", role = true) => ({
  user: { id, org_id: org, isOrgMember: role },
  ensureAuthorized(check) {
    if (!check(this.user)) throw new Error("Unauthorized");
  },
});
const query = () => "{ claroActionEntitlements }";

suite("member-scoped action entitlement read", () => {
  const namespace = db.client.config.searchPath[0];
  beforeAll(async () => {
    await db.schema.createSchema(namespace);
    for (const [table, columns] of Object.entries({
      users: ["id", "org_id", "org_entity_id", "status"],
      benefits: ["id", "name", "type", "status"],
      dependents: ["id", "name", "user_id", "status"],
      dependent_benefits: ["dependent_id", "benefit_id", "status"],
      org_benefits: ["org_id", "benefit_id", "status"],
      user_benefits: ["user_id", "benefit_id", "status"],
      checkup_appointments: ["id", "user_id", "status"],
    }))
      await db.schema.createTable(table, (t) => {
        columns.forEach((column) => t.text(column));
        t.jsonb("meta");
        if (table === "user_benefits") t.timestamp("updated_at").defaultTo(db.fn.now());
        if (table === "benefits") t.boolean("is_policy");
        if (table === "dependents") {
          t.boolean("is_retail");
          t.timestamp("deleted_at");
        }
      });
    await db("users").insert([
      { id: "member", org_id: "org", status: UserStatus.ACTIVE },
      { id: "other", org_id: "other-org", status: UserStatus.ACTIVE },
      { id: "disabled-member", org_id: "disabled-org", status: UserStatus.ACTIVE },
    ]);
  });
  beforeEach(async () => {
    for (const table of ["benefits", "org_benefits", "user_benefits", "checkup_appointments"]) await db(table).delete();
  });
  afterAll(async () => {
    await db.schema.dropSchema(namespace, true);
    await db.destroy();
  });

  async function benefit(type, meta = {}, orgMeta = {}, status = "created", id = "benefit") {
    await db("benefits").insert({
      id,
      name: "Synthetic benefit",
      type,
      status,
      meta,
      is_policy: type === "gmc",
    });
    await db("org_benefits").insert({ org_id: "org", benefit_id: id, status: "created", meta: orgMeta });
    await db("user_benefits").insert({ user_id: "member", benefit_id: id, status: "created" });
  }
  async function read(context = user()) {
    const result = await graphql({ schema, source: query(), contextValue: context });
    expect(result.errors).toBeUndefined();
    return result.data?.claroActionEntitlements;
  }

  it("separates two employers and binds global IDs to the authenticated member", async () => {
    await benefit("checkup-partners");
    const own = await read();
    expect(own.user_id).toBe(toGlobalId("User", "member"));
    expect(own.org_id).toBe(toGlobalId("Org", "org"));
    expect(own.actions["checkup.create"]).toBe("needs_details");
    expect((await read(user("other-org", "other"))).actions["checkup.create"]).toBe("absent");
    expect((await read(user("disabled-org", "disabled-member"))).actions["checkup.create"]).toBe("disabled");
  });
  it.each(["expired", "created"])("explains expiry from status or date: %s", async (status) => {
    await benefit("checkup-partners", {}, { endDate: "2000-01-01" }, status);
    expect((await read()).actions["checkup.create"]).toBe("expired");
  });
  it("reports a suspended benefit as disabled", async () => {
    await benefit("checkup-partners", {}, {}, "suspended");
    expect((await read()).actions["checkup.create"]).toBe("disabled");
  });
  it("lets an active benefit outrank an expired one for the same member", async () => {
    await benefit("checkup-partners", {}, { endDate: "2000-01-01" }, "created", "expired-benefit");
    expect((await read()).actions["checkup.create"]).toBe("expired");
    await benefit("checkup-partners", {}, {}, "created", "active-benefit");
    expect((await read()).actions["checkup.create"]).toBe("needs_details");
  });
  it("uses exact Cult.fit metadata and employer access before individual enrollment", async () => {
    await benefit("partner-signup", { integration: "cultfit" }, { cultfit: { bundlePlans: [{ id: "plan" }] } });
    await db("user_benefits").delete();
    expect((await read()).actions["cultfit.request"]).toBe("needs_details");
    expect((await read(user("other-org", "other"))).actions["cultfit.request"]).toBe("absent");
  });
  it("does not infer Cult.fit from an unrelated wellness benefit", async () => {
    await benefit("partner-signup", { integration: "other" });
    expect((await read()).actions["cultfit.request"]).toBe("absent");
  });
  it("reuses real claim preparation for active coverage and expiry", async () => {
    await benefit("gmc");
    expect((await read()).actions["claim.register"]).toBe("eligible");
    await db("benefits").update({ meta: { endDate: "2000-01-01" } });
    expect((await read()).actions["claim.register"]).toBe("expired");
  });
  it("does not offer a Cult.fit request without a configured plan", async () => {
    await benefit("partner-signup", { integration: "cultfit" });
    expect((await read()).actions["cultfit.request"]).toBe("unverified");
  });
  it("keeps future and malformed benefit dates unverified", async () => {
    await benefit("checkup-partners", {}, { startDate: "2099-01-01" });
    expect((await read()).actions["checkup.create"]).toBe("unverified");
    await db("org_benefits").update({ meta: { endDate: "not-a-date" } });
    expect((await read()).actions["checkup.create"]).toBe("unverified");
  });

  it("keeps an existing Cult.fit request visible after employer access expires or is removed", async () => {
    await benefit("partner-signup", { integration: "cultfit" }, { endDate: "2000-01-01" });
    await db("user_benefits").update({ meta: { cultfit: { enrolmentStatus: "PENDING_APPROVAL" } } });
    expect((await read()).actions["cultfit.request"]).toBe("expired");
    expect((await read()).actions["cultfit.status"]).toBe("needs_details");
    await db("org_benefits").delete();
    expect((await read()).actions["cultfit.request"]).toBe("absent");
    expect((await read()).actions["cultfit.status"]).toBe("needs_details");
    expect((await read(user("other-org", "other"))).actions["cultfit.status"]).toBe("absent");
  });

  it("offers existing appointment management independently of new-booking eligibility", async () => {
    await benefit("checkup-partners", {}, { endDate: "2000-01-01" });
    await db("checkup_appointments").insert({ id: "appointment", user_id: "member", status: "confirmed" });
    const actions = (await read()).actions;
    expect(actions["checkup.create"]).toBe("expired");
    for (const action of ["checkup.status", "checkup.cancel", "checkup.reschedule"])
      expect(actions[action]).toBe("needs_details");
    const other = (await read(user("other-org", "other"))).actions;
    expect(other["checkup.status"]).toBe("absent");
    expect(other["checkup.cancel"]).toBe("absent");
  });

  it.each(["completed", "cancelled"])("keeps %s appointments readable without offering changes", async (status) => {
    await benefit("checkup-partners");
    await db("checkup_appointments").insert({ id: "appointment", user_id: "member", status });
    const actions = (await read()).actions;
    expect(actions["checkup.status"]).toBe("needs_details");
    expect(actions["checkup.cancel"]).toBe("absent");
    expect(actions["checkup.reschedule"]).toBe("absent");
  });

  it.each(INACTIVE_MEMBER_STATUSES)("denies a member whose account is now %s", async (status) => {
    await db("users").insert({ id: `inactive-${status}`, org_id: "org", status });
    await benefit("checkup-partners");
    const result = await graphql({ schema, source: query(), contextValue: user("org", `inactive-${status}`) });
    expect(result.errors?.[0].message).toBe("Member access is no longer active");
    expect(result.data?.claroActionEntitlements ?? null).toBeNull();
  });

  it("rejects admin-only callers, foreign member/org pairs and caller-supplied actor arguments", async () => {
    for (const [context, message] of [
      [user("org", "member", false), "Unauthorized"],
      [user("other-org", "member"), "Member access is no longer active"],
    ] as const) {
      const result = await graphql({ schema, source: query(), contextValue: context });
      expect(result.errors).toHaveLength(1);
      expect(result.errors?.[0].message).toBe(message);
    }
    const result = await graphql({
      schema,
      source: '{ claroActionEntitlements(userId: "other") }',
      contextValue: user(),
    });
    expect(result.errors).toHaveLength(1);
  });
});
