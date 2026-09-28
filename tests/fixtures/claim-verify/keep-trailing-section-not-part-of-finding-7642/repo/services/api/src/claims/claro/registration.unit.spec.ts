// NB: jest hoists jest.mock() factories, so anything referenced inside one must be `mock`-prefixed.

const mockCommandsImpl = {
  preview: jest.fn(),
  find: jest.fn(),
  getPreview: jest.fn(),
  register: jest.fn(),
  reject: jest.fn(),
};
const mockHandler = {
  prepareClaimCreation: jest.fn(),
  updateClaimUserContact: jest.fn(),
  persistPreparedClaim: jest.fn(),
};
const mockGate = jest.fn();
const mockPrepareForMember = jest.fn();
const mockLoadPolicies = jest.fn();

// The shared setup opens a transaction against common/db.
jest.mock("../../common/db", () => {
  const fn: any = () => fn;
  fn.transaction = jest.fn(() => Promise.resolve({ rollback: async () => undefined, commit: async () => undefined }));
  return { __esModule: true, default: fn };
});
jest.mock("./commands", () => {
  const actual = jest.requireActual("./commands");
  return { ...actual, ClaimCommands: jest.fn(() => mockCommandsImpl) };
});
jest.mock("./employerGate", () => ({ requireClaimEmployerEnabled: (...a: any[]) => mockGate(...a) }));
jest.mock("./queries", () => ({
  prepareForMember: (...a: any[]) => mockPrepareForMember(...a),
  loadPolicies: (...a: any[]) => mockLoadPolicies(...a),
}));
// Each method is wrapped so the factory does not read mockHandler before it exists.
jest.mock("../handler", () => ({
  __esModule: true,
  default: {
    prepareClaimCreation: (...a: any[]) => mockHandler.prepareClaimCreation(...a),
    updateClaimUserContact: (...a: any[]) => mockHandler.updateClaimUserContact(...a),
    persistPreparedClaim: (...a: any[]) => mockHandler.persistPreparedClaim(...a),
  },
}));

import { ClaimDocument } from "../tsTypes/enums/claimDocument";
import { ClaimCommandConflict, ClaimReviewConflict } from "./commands";
import { prepareClaimReview, registerReviewedClaim } from "./registration";

const MEMBER = { id: "u1", org_id: "o1", org_entity_id: "e1" } as any;
const POLICY_GID = Buffer.from("Benefit:b1").toString("base64");
const PATIENT_GID = Buffer.from("User:u1").toString("base64");
const FUTURE = "2030-01-01";

function facts(over: Record<string, any> = {}) {
  return { policyId: POLICY_GID, patientId: PATIENT_GID, contact: "9999999999", ...over } as any;
}

function prepared(over: Record<string, any> = {}) {
  return {
    readyForReview: true,
    revision: "rev-1",
    normalized: facts(),
    patients: [{ id: PATIENT_GID }],
    policies: [{ id: POLICY_GID }],
    missingDocuments: [],
    ...over,
  };
}

/** BX-4053: a proven validation conflict is sealed as a durable rejection, not thrown. */
const REJECTION = {
  id: "c1",
  resource_id: null,
  receipt: { status: "rejected", reason: "review_changed", followupStatus: "not_started" },
};

// Status and resource_id are echoed from the REJECTION mock; the load-bearing checks are
// that no claim was persisted and that reject() received this reason.
async function expectSealedRejection(reason = "review_changed") {
  const result: any = await registerReviewedClaim(MEMBER, "c1", "p1");
  expect(result.receipt.status).toBe("rejected");
  expect(result.resource_id).toBeNull();
  expect(mockHandler.persistPreparedClaim).not.toHaveBeenCalled();
  expect(mockCommandsImpl.reject).toHaveBeenCalledWith({ userId: "u1", orgId: "o1" }, "c1", "p1", reason);
}

const ACTIVE_MEMBER_ROW = { id: "u1", org_id: "o1", org_entity_id: "e1" };

function fakeTrx(userRow: any): any {
  const trx: any = () => {
    const b: any = {};
    for (const m of ["where", "whereNotIn", "forShare"]) b[m] = () => b;
    b.first = () => Promise.resolve(userRow);
    return b;
  };
  return trx;
}

/** Drive the callback registration.ts hands to ClaimCommands.register. */
function captureRegistration(userRow: any = ACTIVE_MEMBER_ROW) {
  mockCommandsImpl.register.mockImplementation(async (_actor, _cmd, _prev, cb) => cb(fakeTrx(userRow)));
}

beforeEach(() => {
  jest.clearAllMocks();
  mockGate.mockResolvedValue(undefined);
  mockPrepareForMember.mockResolvedValue(prepared());
  mockLoadPolicies.mockResolvedValue([{ id: POLICY_GID, endDate: FUTURE, patients: [{ id: PATIENT_GID }] }]);
  mockCommandsImpl.find.mockResolvedValue(undefined);
  mockCommandsImpl.getPreview.mockResolvedValue({ facts: facts(), validation_revision: "rev-1" });
  mockCommandsImpl.reject.mockResolvedValue(REJECTION);
  mockHandler.prepareClaimCreation.mockResolvedValue({ newClaimObj: {} });
  mockHandler.updateClaimUserContact.mockResolvedValue({ id: "contact-1" });
  mockHandler.persistPreparedClaim.mockResolvedValue({
    id: "claim-1",
    nb_number: 4242,
    meta: { crm: { claimStage: "Registered" } },
  });
  captureRegistration();
});

describe("prepareClaimReview", () => {
  it("returns no preview while the claim is not ready for review", async () => {
    mockPrepareForMember.mockResolvedValue(prepared({ readyForReview: false }));

    const result = await prepareClaimReview(MEMBER, facts());

    expect(result.preview).toBeNull();
    expect(mockCommandsImpl.preview).not.toHaveBeenCalled();
  });

  it("checks the employer gate before preparing anything", async () => {
    mockGate.mockRejectedValue(new Error("employer has not enabled claims"));

    await expect(prepareClaimReview(MEMBER, facts())).rejects.toThrow("employer has not enabled claims");
    expect(mockPrepareForMember).not.toHaveBeenCalled();
  });

  it("stores a summary that never claims insurer acceptance", async () => {
    mockCommandsImpl.preview.mockResolvedValue({ id: "p1" });

    await prepareClaimReview(MEMBER, facts());

    const summary = mockCommandsImpl.preview.mock.calls[0][3];
    expect(summary.insurerSubmission).toBe(false);
    expect(summary.action).toContain("Register a reimbursement claim");
    expect(summary.patient).toEqual({ id: PATIENT_GID });
    expect(summary.policy).toEqual({ id: POLICY_GID });
  });
});

describe("registerReviewedClaim", () => {
  it("returns the existing command when the same confirmation is replayed", async () => {
    mockCommandsImpl.find.mockResolvedValue({ id: "c1", preview_id: "p1" });

    expect(await registerReviewedClaim(MEMBER, "c1", "p1")).toEqual({ id: "c1", preview_id: "p1" });
    expect(mockCommandsImpl.register).not.toHaveBeenCalled();
  });

  it("refuses a replay whose preview changed without sealing anything", async () => {
    mockCommandsImpl.find.mockResolvedValue({ id: "c1", preview_id: "other" });

    await expect(registerReviewedClaim(MEMBER, "c1", "p1")).rejects.toThrow("Command details changed");
    expect(mockCommandsImpl.reject).not.toHaveBeenCalled();
  });

  it("seals an expired review under its own reason", async () => {
    mockCommandsImpl.register.mockRejectedValue(
      new ClaimReviewConflict("Review expired; prepare again", "review_expired"),
    );

    await expectSealedRejection("review_expired");
  });

  it("does not seal a command identity conflict raised by the command layer", async () => {
    mockCommandsImpl.register.mockRejectedValue(new ClaimCommandConflict("Command identity is already in use"));

    await expect(registerReviewedClaim(MEMBER, "c1", "p1")).rejects.toThrow("already in use");
    expect(mockCommandsImpl.reject).not.toHaveBeenCalled();
  });

  it.each([
    ["eligibility is no longer ready", { readyForReview: false }],
    ["the validation revision moved", { revision: "rev-2" }],
  ])("refuses when %s", async (_label, over) => {
    mockPrepareForMember.mockResolvedValue(prepared(over));

    await expectSealedRejection();
  });

  it.each([
    ["the policy is not a benefit id", { policyId: Buffer.from("Org:x").toString("base64") }],
    ["the patient is neither user nor dependent", { patientId: Buffer.from("Org:x").toString("base64") }],
  ])("refuses when %s", async (_label, over) => {
    mockPrepareForMember.mockResolvedValue(prepared({ normalized: facts(over) }));

    await expectSealedRejection();
  });

  it("registers the claim and returns a receipt that does not imply insurer acceptance", async () => {
    const result: any = await registerReviewedClaim(MEMBER, "c1", "p1");

    expect(result.resourceId).toBe("claim-1");
    expect(result.receipt.reference).toBe("NB4242");
    expect(result.receipt.status).toBe("registered");
    expect(result.receipt.insurerSubmission).toBe("not_confirmed");
    expect(result.receipt.followupStatus).toBe("pending");
  });

  it("raises the ticket, notification and internal follow-ups, ordering notifications after the ticket", async () => {
    const result: any = await registerReviewedClaim(MEMBER, "c1", "p1");

    expect(result.followups.map((f: any) => f.kind)).toEqual([
      "claim.ticket",
      "claim.notifications",
      "claim.internal_notification",
    ]);
    expect(result.followups[1].after).toBe("claim.ticket");
    expect(result.followups[0].payload).toEqual({ claimId: "claim-1", userId: "u1" });
  });

  it("adds a priority alert only for a high priority claim", async () => {
    mockHandler.persistPreparedClaim.mockResolvedValue({
      id: "claim-1",
      nb_number: 4242,
      meta: { crm: { claimStage: "Registered" }, highPriority: true },
    });

    const result: any = await registerReviewedClaim(MEMBER, "c1", "p1");

    expect(result.followups.map((f: any) => f.kind)).toContain("claim.priority_alert");
  });

  // Nothing dispatches inline here, so auto-attached documents only get extracted if the
  // follow-up carries their types. Without it the rows land and MagicFill never runs.
  it("raises one claim.auto_extract follow-up per auto-attached extractable document type", async () => {
    mockHandler.prepareClaimCreation.mockResolvedValue({
      newClaimObj: {},
      shouldAutoAttach: true,
      ff: { meta: { ENABLE_CLAIM_FORM_A_GENERATION: true } },
      newDocs: [
        { doc_type: ClaimDocument.PAN_PRIMARY },
        { doc_type: ClaimDocument.PAN_PRIMARY },
        { doc_type: ClaimDocument.DISCHARGE_SUMMARY },
        { doc_type: ClaimDocument.AADHAAR_PATIENT },
      ],
    });

    const result: any = await registerReviewedClaim(MEMBER, "c1", "p1");

    for (const docType of [ClaimDocument.PAN_PRIMARY, ClaimDocument.AADHAAR_PATIENT])
      expect(result.followups).toContainEqual({
        kind: `claim.auto_extract:${docType}`,
        payload: { claimId: "claim-1", userId: MEMBER.id, docType },
      });
    expect(result.followups.filter((f: any) => f.kind.startsWith("claim.auto_extract:"))).toHaveLength(2);
  });

  it.each([
    ["the documents were not auto-attached", { shouldAutoAttach: false }],
    ["form generation is off", { ff: { meta: { ENABLE_CLAIM_FORM_A_GENERATION: false } } }],
    ["nothing auto-attached is extractable", { newDocs: [{ doc_type: ClaimDocument.DISCHARGE_SUMMARY }] }],
  ])("raises no document follow-up when %s", async (_label, over) => {
    mockHandler.prepareClaimCreation.mockResolvedValue({
      newClaimObj: {},
      shouldAutoAttach: true,
      ff: { meta: { ENABLE_CLAIM_FORM_A_GENERATION: true } },
      newDocs: [{ doc_type: ClaimDocument.PAN_PRIMARY }],
      ...over,
    });

    const result: any = await registerReviewedClaim(MEMBER, "c1", "p1");

    expect(result.followups.filter((f: any) => f.kind.startsWith("claim.auto_extract:"))).toEqual([]);
  });

  it("raises a contact.changed follow-up when the contact handler reports one", async () => {
    mockHandler.updateClaimUserContact.mockImplementation(async (_id, _c, _u, _trx, onEvent: any) => {
      onEvent({ changed: true });
      return { id: "contact-1" };
    });

    const result: any = await registerReviewedClaim(MEMBER, "c1", "p1");

    expect(result.followups[0]).toEqual({
      kind: "contact.changed",
      payload: { userId: "u1", event: { changed: true } },
    });
  });

  it("refuses a member who is no longer active", async () => {
    captureRegistration(null);

    await expectSealedRejection("member_ineligible");
  });

  it("re-checks the employer gate inside the transaction, against the locked row", async () => {
    await registerReviewedClaim(MEMBER, "c1", "p1");

    expect(mockGate).toHaveBeenCalledTimes(1);
    const [orgId, entityId, trx] = mockGate.mock.calls[0];
    expect(orgId).toBe("o1");
    expect(entityId).toBe("e1");
    expect(trx).toBeDefined();
  });

  it.each([
    ["the policy disappeared", []],
    ["cover has lapsed", [{ id: POLICY_GID, endDate: "2020-01-01", patients: [{ id: PATIENT_GID }] }]],
    ["the patient is no longer covered", [{ id: POLICY_GID, endDate: FUTURE, patients: [{ id: "someone-else" }] }]],
  ])("refuses when %s", async (_label, policies) => {
    mockLoadPolicies.mockResolvedValue(policies);

    await expectSealedRejection("coverage_changed");
  });

  it("refuses when the contact could not be saved", async () => {
    mockHandler.updateClaimUserContact.mockResolvedValue(undefined);

    await expectSealedRejection("contact_not_saved");
  });

  it.each([
    ["no id", { id: undefined, nb_number: 1, meta: { crm: {} } }],
    ["no reference number", { id: "claim-1", nb_number: undefined, meta: { crm: {} } }],
  ])("refuses an incomplete receipt with %s", async (_label, claim) => {
    mockHandler.persistPreparedClaim.mockResolvedValue(claim);

    await expect(registerReviewedClaim(MEMBER, "c1", "p1")).rejects.toThrow("Claim receipt is incomplete");
  });

  it("links the saved contact onto the claim before persisting it", async () => {
    const plan = { newClaimObj: {} as any };
    mockHandler.prepareClaimCreation.mockResolvedValue(plan);

    await registerReviewedClaim(MEMBER, "c1", "p1");

    expect(plan.newClaimObj.user_contact_id).toBe("contact-1");
    expect(mockHandler.persistPreparedClaim).toHaveBeenCalledWith(plan, expect.anything());
  });
});
