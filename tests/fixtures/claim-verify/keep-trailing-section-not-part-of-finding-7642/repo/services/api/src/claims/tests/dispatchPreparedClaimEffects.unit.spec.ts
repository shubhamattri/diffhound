import logger from "../../common/logger";
import { ClaimFilesHandler } from "../claimFiles/handler";
import ClaimsHandler from "../handler";
import { ClaimDocument } from "../tsTypes/enums/claimDocument";

const CLAIM_ID = "claim-1";

function prepared(over: Record<string, any> = {}): any {
  return {
    newId: CLAIM_ID,
    newDocs: [{ doc_type: ClaimDocument.PAN_PRIMARY }],
    shouldAutoAttach: true,
    ff: { meta: { ENABLE_CLAIM_FORM_A_GENERATION: true } },
    ...over,
  };
}

function claim(over: Record<string, any> = {}): any {
  return { id: CLAIM_ID, meta: {}, ...over };
}

/** The extraction jobs are fire-and-forget, so let the microtask queue drain. */
const flush = () => new Promise((resolve) => setImmediate(resolve));

let extract: jest.SpyInstance;
let slackAlert: jest.SpyInstance;
let event: jest.SpyInstance;

/** Log event names seen so far; the catch block is only observable through these. */
const events = () => event.mock.calls.map(([name]) => name);

beforeEach(() => {
  extract = jest.spyOn(ClaimFilesHandler, "smartExtractAndStore").mockResolvedValue(undefined as never);
  slackAlert = jest.spyOn(ClaimsHandler, "sendHighPriorityClaimSlackAlert").mockResolvedValue(undefined as never);
  event = jest.spyOn(logger, "event");
});

afterEach(() => jest.restoreAllMocks());

describe("dispatchPreparedClaimEffects", () => {
  describe("auto-attached document extraction", () => {
    it("triggers extraction for an auto-attached extractable document", async () => {
      ClaimsHandler.dispatchPreparedClaimEffects(prepared(), claim());
      await flush();

      expect(extract).toHaveBeenCalledWith(CLAIM_ID, ClaimDocument.PAN_PRIMARY);
    });

    it("covers every document type the flow can auto-attach", async () => {
      const types = [
        ClaimDocument.PAN_PRIMARY,
        ClaimDocument.CANCELLED_CHEQUE,
        ClaimDocument.AADHAAR_PRIMARY,
        ClaimDocument.AADHAAR_PATIENT,
      ];
      ClaimsHandler.dispatchPreparedClaimEffects(prepared({ newDocs: types.map((t) => ({ doc_type: t })) }), claim());
      await flush();

      expect(extract).toHaveBeenCalledTimes(types.length);
      expect(extract.mock.calls.map((c) => c[1])).toEqual(types);
    });

    it("ignores document types that carry nothing to extract", async () => {
      ClaimsHandler.dispatchPreparedClaimEffects(
        prepared({ newDocs: [{ doc_type: ClaimDocument.DISCHARGE_SUMMARY }] }),
        claim(),
      );
      await flush();

      expect(extract).not.toHaveBeenCalled();
    });

    it.each([
      ["the documents were not auto-attached", { shouldAutoAttach: false }],
      ["there are no new documents", { newDocs: [] }],
      ["the form-generation flag is off", { ff: { meta: { ENABLE_CLAIM_FORM_A_GENERATION: false } } }],
      ["there are no feature flags at all", { ff: undefined }],
    ])("does not extract when %s", async (_label, over) => {
      ClaimsHandler.dispatchPreparedClaimEffects(prepared(over), claim());
      await flush();

      expect(extract).not.toHaveBeenCalled();
    });

    // `.not.toThrow()` alone proves nothing here: Promise.allSettled already attaches a handler
    // to every job, so an uncaught fire-and-forget rejection would pass that assertion too.
    // What the catch block is actually for is recording the failure, so assert that instead.
    it("records an extraction failure and still finishes the batch", async () => {
      extract.mockRejectedValue(new Error("magicfill unavailable"));

      expect(() => ClaimsHandler.dispatchPreparedClaimEffects(prepared(), claim())).not.toThrow();
      await flush();
      await flush();

      expect(extract).toHaveBeenCalled();
      expect(events()).toContain("autoAttach_magicFillError");
      expect(events()).not.toContain("autoAttach_magicFillTriggered");
      expect(events()).toContain("autoAttach_magicFillBackgroundComplete");
    });

    it("records a successful extraction rather than the failure path", async () => {
      ClaimsHandler.dispatchPreparedClaimEffects(prepared(), claim());
      await flush();
      await flush();

      expect(events()).toContain("autoAttach_magicFillTriggered");
      expect(events()).not.toContain("autoAttach_magicFillError");
    });

    it("keeps extracting the remaining documents after one of them fails", async () => {
      extract.mockRejectedValueOnce(new Error("magicfill unavailable")).mockResolvedValueOnce(undefined as never);
      const types = [ClaimDocument.PAN_PRIMARY, ClaimDocument.CANCELLED_CHEQUE];

      ClaimsHandler.dispatchPreparedClaimEffects(prepared({ newDocs: types.map((t) => ({ doc_type: t })) }), claim());
      await flush();
      await flush();

      expect(extract.mock.calls.map((c) => c[1])).toEqual(types);
    });
  });

  describe("high priority alert", () => {
    // The default fixture also starts extraction; let it settle before afterEach restores mocks.
    it("raises a Slack alert for a high priority claim", async () => {
      ClaimsHandler.dispatchPreparedClaimEffects(prepared(), claim({ meta: { highPriority: true } }));
      await flush();

      expect(slackAlert).toHaveBeenCalledWith(expect.objectContaining({ id: CLAIM_ID }), undefined);
    });

    it("passes the request context through to the alert", async () => {
      const ctx = { user: { id: "u1" } } as any;

      ClaimsHandler.dispatchPreparedClaimEffects(prepared(), claim({ meta: { highPriority: true } }), ctx);
      await flush();

      expect(slackAlert).toHaveBeenCalledWith(expect.anything(), ctx);
    });

    it.each([
      ["the claim is not high priority", {}],
      ["the claim has no meta", { meta: undefined }],
    ])("stays quiet when %s", async (_label, over) => {
      ClaimsHandler.dispatchPreparedClaimEffects(prepared(), claim(over));
      await flush();

      expect(slackAlert).not.toHaveBeenCalled();
    });
  });
});
