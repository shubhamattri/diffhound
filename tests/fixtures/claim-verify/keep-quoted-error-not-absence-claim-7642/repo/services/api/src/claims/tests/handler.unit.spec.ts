import moment from "moment-timezone";
import { QueryBuilder, ValidationError } from "objection";
import { v4 } from "uuid";
import {
  clearDatabaseUsingResource,
  IMockDBResource,
  populateDatabaseUsingResource,
} from "../../../tests/utils/apiTest";
import * as context from "../../common/context";
import db from "../../common/db";
import logger from "../../common/logger";
import { slackQueue } from "../../common/queues";
import { OrgModel } from "../../models/org";
import { UserPriority } from "../../tsTypes/enums";
import * as utils from "../../utils";
import { UserModel } from "../../user/model";
import * as userHandlers from "../../user/handlers/users";
import * as claimUtils from "../../utils/claim";
import * as whatsappCsatModule from "../processors/whatsappCsatCollection";
import * as orgPropertyHandler from "../../orgProperty/handler";
import * as rootUtils from "../../utils";
import ClaimsQueryHandler from "../queries/handler";
import { findMatchingClaim, findMatchingDependent } from "../cliTools/handler";
import { TpaIntegrationType } from "../tpaIntegrations/base";
import ClaimsHandler from "../handler";
import { ClaimModel } from "../models";
import { MessageType } from "../tsTypes/claim";
import { mandatoryClaimDocuments, mandatoryOpdClaimDocuments } from "../tsTypes/constants/mandatoryClaimDocuments";
import { ClaimDocument } from "../tsTypes/enums/claimDocument";
import { ClaimFormType } from "../tsTypes/enums/claimFormType";
import { ClaimSlackChannels } from "../tsTypes/enums/claimSlackChannels";
import { ClaimSource } from "../tsTypes/enums/claimSource";
import { ClaimStage } from "../tsTypes/enums/claimStage";
import { ClaimTicketActions } from "../tsTypes/enums/claimTicketActions";
import { ClaimType } from "../tsTypes/enums/claimType";
import { FlowType } from "../tsTypes/enums/flowType";
import { Status } from "../tsTypes/enums/status";
import mockDbData from "./mockDbData";

describe("Claims Handler", () => {
  beforeAll(async () => {
    await populateDatabaseUsingResource(mockDbData?.data || []);
  });

  afterAll(async () => {
    await clearDatabaseUsingResource(mockDbData?.data || []);
    jest.restoreAllMocks();
  });

  describe("updateDocsUpdatedAfterDormantStatus", () => {
    it("should set meta->>claimUpdatedAfterDormant to true if docs are added to dormant claim", async () => {
      const patchFnMock = jest.fn().mockReturnValue({
        where: jest.fn(),
      });
      const mock = jest.spyOn(ClaimModel, "query").mockImplementation(() => {
        return {
          patch: patchFnMock,
        };
      });
      const claim = {
        id: v4(),
        user_id: v4(),
        meta: { claimFilesUpdated: true },
        status: Status.DORMANT,
      };
      const oldClaim = {
        ...claim,
        meta: {},
      };
      await ClaimsHandler.updateDocsUpdatedAfterDormantStatus(claim, oldClaim);
      expect(patchFnMock).toHaveBeenCalledWith({
        "meta:claimUpdatedAfterDormant": true,
      });
    });
    it("should not set meta->>claimUpdatedAfterDormant to true if docs are added to non-dormant claim", async () => {
      const patchFnMock = jest.fn().mockReturnValue({
        where: jest.fn(),
      });
      const mock = jest.spyOn(ClaimModel, "query").mockImplementation(() => {
        return {
          patch: patchFnMock,
        };
      });
      const file1 = {
        id: "1",
        name: "file1",
        docType: "Claim form: Part A",
        type: "pdf",
        url: "https://www.google.com",
        timestamp: "2021-07-11T18:08:20.201Z",
      };
      const claim = {
        id: v4(),
        user_id: v4(),
        meta: { files: [file1] },
        status: Status.CLAIM_INTIMATED,
      };
      const oldClaim = {
        ...claim,
        meta: { files: [] },
      };
      await ClaimsHandler.updateDocsUpdatedAfterDormantStatus(claim, oldClaim);
      expect(patchFnMock).not.toHaveBeenCalled();
    });
    it("should set meta->>claimUpdatedAfterDormant to false if status is not dormant andmeta->>claimUpdatedAfterDormant=true", async () => {
      const patchFnMock = jest.fn().mockReturnValue({
        where: jest.fn(),
      });
      const mock = jest.spyOn(ClaimModel, "query").mockImplementation(() => {
        return {
          patch: patchFnMock,
        };
      });
      const file1 = {
        id: "1",
        name: "file1",
        docType: "Claim form: Part A",
        type: "pdf",
        url: "https://www.google.com",
        timestamp: "2021-07-11T18:08:20.201Z",
      };
      const claim = {
        id: v4(),
        user_id: v4(),
        meta: { files: [file1], claimUpdatedAfterDormant: true },
        status: Status.CLAIM_INTIMATED,
      };

      await ClaimsHandler.updateDocsUpdatedAfterDormantStatus(claim, claim);
      expect(patchFnMock).toHaveBeenCalledWith({
        "meta:claimUpdatedAfterDormant": false,
      });
    });
  });

  describe("sendDocumentUpdates", () => {
    // afterAll(() => {
    //   jest.restoreAllMocks();
    // });
    it("calls sendDocumentUpdatesToSlack if there are file differences and returns true", async () => {
      const userModelSpy = jest.spyOn(UserModel, "query").mockImplementation(() => {
        return QueryBuilder.forClass(UserModel).resolve({
          id: v4(),
          meta: { priority: UserPriority.STANDARD },
        });
      });
      jest.spyOn(claimUtils, "getClaimDocUpdateMessage").mockResolvedValue("test");

      const addMock = jest.fn();
      slackQueue.add = addMock;
      const file1 = {
        id: "1",
        name: "file1",
        docType: "Claim form: Part A",
        type: "pdf",
        url: "https://www.google.com",
        timestamp: "2021-07-11T18:08:20.201Z",
      };
      const prevClaim = {
        id: v4(),
        user_id: v4(),
        meta: { files: [] },
      };
      const currClaim = {
        id: v4(),
        user_id: v4(),
        meta: { files: [file1] },
      };
      const spy = jest.spyOn(ClaimsHandler, "sendDocumentUpdatesToSlack");
      const res = await ClaimsHandler.sendDocumentUpdates(prevClaim, currClaim);
      expect(res).toBeTruthy();
      expect(spy).toHaveBeenCalled();
      expect(userModelSpy).toHaveBeenCalled();
    });
  });

  describe("sendDocumentUpdatesToSlack", () => {
    it("adds message to queue depending on priority", async () => {
      const addMock = jest.fn();
      slackQueue.add = addMock;
      const spy = jest.spyOn(slackQueue, "add");

      await ClaimsHandler.sendDocumentUpdatesToSlack("message for high priority", UserPriority.HIGH);
      expect(spy).toHaveBeenCalledWith({
        message: "message for high priority",
        channel: ClaimSlackChannels.VIP_NOTIFICATIONS,
      });
      await ClaimsHandler.sendDocumentUpdatesToSlack("message for low priority", UserPriority.STANDARD);
      expect(spy).toHaveBeenCalledWith({
        message: "message for low priority",
        channel: ClaimSlackChannels.GENERAL_NOTIFICATIONS,
      });
    });
  });

  describe("canCloseQueryForClaimStage", () => {
    it("returns false when stage passed to it is not eligible for closing queries", () => {
      const listOfClaimStagesEligible = [
        ClaimStage.QUERY_RESPONDED_BY_EMPLOYEE,
        ClaimStage.QUERY_DOCS_UNDER_VERIFICATION,
        ClaimStage.QUERY_DOCS_UNDER_VERIFICATION_2,
      ];

      listOfClaimStagesEligible.forEach((stage) => {
        expect(ClaimsHandler.canCloseQueryForClaimStage(stage)).toBeFalsy();
      });
    });

    it("returns true when stage passed to it is eligible for closing queries", () => {
      const listOfClaimStagesEligible = [
        ClaimStage.CLAIM_APPROVED_BY_TPA,
        ClaimStage.CLAIM_SETTLED,
        ClaimStage.CLAIM_UNDER_INVESTIGATION,
      ];

      listOfClaimStagesEligible.forEach((stage) => {
        expect(ClaimsHandler.canCloseQueryForClaimStage(stage)).toBeTruthy();
      });
    });
  });

  describe("findMatchingDependent", () => {
    it("should return a dependent when there is an exact name match found", async () => {
      const INPUT_PATIENT = {
        userId: "77d4b7ac-b6ad-4328-bef6-d6fcbf96b87d",
        patientName: "Martha Wayne",
        relation: "spouse",
        gender: "female",
      };

      const matchedDependent = await findMatchingDependent(
        INPUT_PATIENT.userId,
        INPUT_PATIENT.patientName,
        INPUT_PATIENT.relation,
        INPUT_PATIENT.gender,
        null,
        true,
      );
      expect(matchedDependent.name).toEqual(INPUT_PATIENT.patientName);
    });

    it("should return a dependent when there is an exact name match found ignoring case", async () => {
      const INPUT_PATIENT = {
        userId: "77d4b7ac-b6ad-4328-bef6-d6fcbf96b87d",
        patientName: "martha wayne",
        relation: "spouse",
        gender: "female",
      };

      const matchedDependent = await findMatchingDependent(
        INPUT_PATIENT.userId,
        INPUT_PATIENT.patientName,
        INPUT_PATIENT.relation,
        INPUT_PATIENT.gender,
        null,
        true,
      );
      expect(matchedDependent.name).toEqual("Martha Wayne");
    });

    it("should return a male child dependent when there is not an exact name match found, but only 1 male child is present anyway", async () => {
      const INPUT_PATIENT = {
        userId: "77d4b7ac-b6ad-4328-bef6-d6fcbf96b87d",
        patientName: "Bruceee Wayne",
        actualName: "Bruce Wayne",
        relation: "child",
        gender: "male",
      };

      const matchedDependent = await findMatchingDependent(
        INPUT_PATIENT.userId,
        INPUT_PATIENT.patientName,
        INPUT_PATIENT.relation,
        INPUT_PATIENT.gender,
        null,
        true,
      );
      expect(matchedDependent.name).toEqual(INPUT_PATIENT.actualName);
    });

    it("should return a male child dependent when there are 2 male childs present by fuzzy logic", async () => {
      const INPUT_PATIENT = {
        userId: "b61ca5d9-a01e-469f-9c11-23371bcb3c96",
        patientName: "Bruceee Wayne",
        actualName: "Bruce Wayne",
        relation: "child",
        gender: "male",
      };

      const matchedDependent = await findMatchingDependent(
        INPUT_PATIENT.userId,
        INPUT_PATIENT.patientName,
        INPUT_PATIENT.relation,
        INPUT_PATIENT.gender,
        null,
        true,
      );
      expect(matchedDependent.name).toEqual(INPUT_PATIENT.actualName);
    });

    it("should return a male child dependent when there are 2 male childs (1 deleted, 1 created) present by fuzzy logic, should prioritize created status", async () => {
      const INPUT_PATIENT = {
        userId: "2049df8d-af1a-440f-ab95-18a1aae81b0c",
        patientName: "Walterr  White Jr.",
        actualName: "Walter White Jr.",
        relation: "child",
        gender: "male",
      };

      const matchedDependent = await findMatchingDependent(
        INPUT_PATIENT.userId,
        INPUT_PATIENT.patientName,
        INPUT_PATIENT.relation,
        INPUT_PATIENT.gender,
        null,
        true,
      );
      expect(matchedDependent.name).toEqual(INPUT_PATIENT.actualName);
      expect(matchedDependent.status).toEqual("created");
    });

    it("should return only dependent ID if whole object is not requested", async () => {
      const INPUT_PATIENT = {
        userId: "2049df8d-af1a-440f-ab95-18a1aae81b0c",
        patientName: "Walterr  White Jr.",
        actualName: "Walter White Jr.",
        actualDependentId: "69d4b7ac-b6ad-4328-bef6-d6fcbf96b8ff",
        relation: "child",
        gender: "male",
      };

      const matchedDependentId = await findMatchingDependent(
        INPUT_PATIENT.userId,
        INPUT_PATIENT.patientName,
        INPUT_PATIENT.relation,
        INPUT_PATIENT.gender,
        null,
        false,
      );
      expect(matchedDependentId).toEqual(INPUT_PATIENT.actualDependentId);
    });

    it("should throw when the fuzzy match threshold is not met", async () => {
      const INPUT_PATIENT = {
        userId: "0c87c67d-c68c-4ce5-9f89-959c18b23d3d",
        patientName: "Walterr  White Jr.",
        actualName: "Walter White Jr.",
        relation: "child",
        gender: "male",
      };

      await expect(
        findMatchingDependent(
          INPUT_PATIENT.userId,
          INPUT_PATIENT.patientName,
          INPUT_PATIENT.relation,
          INPUT_PATIENT.gender,
          null,
          true,
        ),
      ).rejects.toThrow("No matching dependent found");
    });
  });

  describe("sendHighPriorityClaimSlackAlert", () => {
    let mockPodMemberRolesWithSlackId = null;
    let mockClaimantUser = null;
    let mockClaimantOrg = null;
    let mockClaimantContact = null;
    let slackQueueSpy = null;
    beforeEach(() => {
      mockPodMemberRolesWithSlackId = {
        CA: "U12345678",
        RM: "U98765432",
        KAM: "U55555555",
        CxPgM: "U11111111",
      };

      mockClaimantUser = {
        id: "test-uuid-user",
        org_id: "test-uuid-org",
        name: "Jester Bennington",
        email: "jester@linkinpark.com",
      };

      mockClaimantOrg = {
        id: "test-uuid-org",
        name: "Linkin Park",
      };

      mockClaimantContact = "7871819487";

      UserModel.query = jest.fn().mockReturnValue({
        where: jest.fn().mockReturnThis(),
        andWhereRaw: jest.fn().mockReturnThis(),
        select: jest.fn().mockReturnThis(),
        first: jest.fn().mockReturnThis(),
        findById: jest.fn().mockResolvedValue(mockClaimantUser),
      });
      OrgModel.query = jest.fn().mockReturnValue({
        where: jest.fn().mockReturnThis(),
        andWhereRaw: jest.fn().mockReturnThis(),
        select: jest.fn().mockReturnThis(),
        first: jest.fn().mockReturnThis(),
        findById: jest.fn().mockResolvedValue(mockClaimantOrg),
      });

      jest.spyOn(context, "Context").mockImplementation(() => ({
        dependentByIdWithDeleted: {
          load: () => {
            return Promise.resolve({ id: "test-uuid-dep", name: "Some Kid", relation: "child" });
          },
        },
        getOrAddDataLoader: jest.fn(),
      }));

      // Mock userByIdDataLoader to return the mock user
      jest.spyOn(userHandlers, "userByIdDataLoader").mockReturnValue({
        load: jest.fn().mockResolvedValue(mockClaimantUser),
      });

      slackQueue.add = jest.fn();
      slackQueueSpy = jest.spyOn(slackQueue, "add");
    });

    afterAll(async () => {
      jest.restoreAllMocks();
    });

    it("should trigger slack alert for the claim if the claim is for self", async () => {
      const claimObj = {
        id: "2b2a3422-66da-4669-9eb8-0efaba65da6c",
        user_id: "test-uuid-user",
        meta: {
          highPriority: true,
        },
        type: ClaimType.REIMBURSEMENT,
        nb_number: 69696969,
      };
      jest.spyOn(ClaimsHandler, "getClaimantContact").mockResolvedValue(mockClaimantContact);
      jest.spyOn(ClaimsHandler, "fetchStakeholdersForPriorityClaim").mockResolvedValue([]);
      jest
        .spyOn(claimUtils, "getSlackIdsFromCXPodMember")
        .mockReturnValue(Object.values(mockPodMemberRolesWithSlackId));

      const buildMessageForPriorityClaimsSpy = jest.spyOn(claimUtils, "buildMessageForPriorityClaims");
      buildMessageForPriorityClaimsSpy.mockReturnValue("test-message");

      await ClaimsHandler.sendHighPriorityClaimSlackAlert(claimObj);

      expect(buildMessageForPriorityClaimsSpy).toHaveBeenCalledWith({
        claimId: claimObj.id,
        slackIds: Object.values(mockPodMemberRolesWithSlackId),
        typeOfClaim: claimObj.type,
        nbNumber: claimObj.nb_number,
        claimantName: mockClaimantUser.name,
        relation: "Self",
        claimantContact: mockClaimantContact,
        primaryInsured: {
          name: mockClaimantUser.name,
          email: mockClaimantUser.email,
          orgName: mockClaimantOrg.name,
        },
      });
      expect(slackQueueSpy).toHaveBeenCalledWith({
        message: "test-message",
        channel: ClaimSlackChannels.HIGH_PRIORITY_CLAIMS,
      });
    });

    it("should trigger slack alert for the claim if the claim is for dependent", async () => {
      const claimObj = {
        id: "2b2a3422-66da-4669-9eb8-0efaba65da6c",
        user_id: "test-uuid-user",
        dependent_id: "test-uuid-dep",
        meta: {
          highPriority: true,
        },
        type: ClaimType.REIMBURSEMENT,
        nb_number: 69696969,
      };

      slackQueue.add = jest.fn();
      const slackQueueSpy = jest.spyOn(slackQueue, "add");
      jest.spyOn(ClaimsHandler, "getClaimantContact").mockResolvedValue(mockClaimantContact);
      jest.spyOn(ClaimsHandler, "fetchStakeholdersForPriorityClaim").mockResolvedValue([]);
      jest
        .spyOn(claimUtils, "getSlackIdsFromCXPodMember")
        .mockReturnValue(Object.values(mockPodMemberRolesWithSlackId));

      const buildMessageForPriorityClaimsSpy = jest.spyOn(claimUtils, "buildMessageForPriorityClaims");
      buildMessageForPriorityClaimsSpy.mockReturnValue("test-message");

      await ClaimsHandler.sendHighPriorityClaimSlackAlert(claimObj);

      expect(buildMessageForPriorityClaimsSpy).toHaveBeenCalledWith({
        claimId: claimObj.id,
        slackIds: Object.values(mockPodMemberRolesWithSlackId),
        typeOfClaim: claimObj.type,
        nbNumber: claimObj.nb_number,
        claimantName: "Some Kid",
        relation: "child",
        claimantContact: mockClaimantContact,
        primaryInsured: {
          name: mockClaimantUser.name,
          email: mockClaimantUser.email,
          orgName: mockClaimantOrg.name,
        },
      });
      expect(slackQueueSpy).toHaveBeenCalledWith({
        message: "test-message",
        channel: ClaimSlackChannels.HIGH_PRIORITY_CLAIMS,
      });
    });
  });

  describe("sendMessagesToSlack", () => {
    const claim = {
      claim_owner: "claim_owner_id",
    };
    const tpa = {};
    const messages = {
      success: ["Success message"],
      error: ["Error message"],
    };
    const hasDocUploadApi = true;

    it("should send success messages to Slack", async () => {
      const validSlackId = "valid_slack_id";

      jest.spyOn(ClaimsHandler, "getSlackMessageHeaders").mockResolvedValue({
        [FlowType.ExampleFlowType]: {
          [MessageType.Success]: "Mock success message header",
        },
      });

      jest.spyOn(ClaimsHandler, "formatSlackMessages").mockResolvedValue("Mock success formatted message");

      jest.spyOn(ClaimsHandler, "addMessagesToSlackQueue").mockResolvedValue();

      jest.spyOn(claimUtils, "getClaimOwnerSlackId").mockResolvedValue(validSlackId);

      const result = await ClaimsHandler.sendMessagesToSlack(
        MessageType.Success,
        FlowType.ExampleFlowType,
        tpa,
        claim,
        messages,
        hasDocUploadApi,
      );

      expect(claimUtils.getClaimOwnerSlackId).toHaveBeenCalledWith(claim.claim_owner);
      expect(result).toEqual({ success: [], error: [] });
    });

    it("should send error messages to Slack", async () => {
      const validSlackId = "valid_slack_id";

      jest.spyOn(ClaimsHandler, "getSlackMessageHeaders").mockResolvedValue({
        [FlowType.ExampleFlowType]: {
          [MessageType.Error]: "Mock error message header",
        },
      });

      jest.spyOn(ClaimsHandler, "formatSlackMessages").mockResolvedValue("Mock error formatted message");

      jest.spyOn(ClaimsHandler, "addMessagesToSlackQueue").mockResolvedValue();

      jest.spyOn(claimUtils, "getClaimOwnerSlackId").mockResolvedValue(validSlackId);

      const result = await ClaimsHandler.sendMessagesToSlack(
        MessageType.Error,
        FlowType.ExampleFlowType,
        tpa,
        claim,
        messages,
        hasDocUploadApi,
      );

      expect(claimUtils.getClaimOwnerSlackId).toHaveBeenCalledWith(claim.claim_owner);
      expect(result).toEqual({ success: [], error: [] });
    });
  });

  describe("addMessagesToSlackQueue", () => {
    // A sibling describe spies on addMessagesToSlackQueue; restore it and reset the queue mock.
    beforeEach(() => {
      jest.restoreAllMocks();
      slackQueue.add = jest.fn();
    });

    it("should add messages to Slack queue", async () => {
      const errors = ["Error 1", "Error 2"];
      const channel = "test_channel";

      await ClaimsHandler.addMessagesToSlackQueue(errors, channel);

      expect(slackQueue.add).toHaveBeenCalledWith({ message: errors, channel });
    });

    it("should handle errors and log to console", async () => {
      const errors = ["Error 1", "Error 2"];
      const channel = "test_channel";

      slackQueue.add.mockRejectedValueOnce("Failed to add messages");

      await ClaimsHandler.addMessagesToSlackQueue(errors, channel);
    });
  });

  describe("getSlackEmoji", () => {
    it("should return correct emoji for success message", () => {
      const type = MessageType.Success;
      const emoji = ClaimsHandler.getSlackEmoji(type);
      expect(emoji).toBe(":white_check_mark:");
    });

    it("should return correct emoji for error message", () => {
      const type = MessageType.Error;
      const emoji = ClaimsHandler.getSlackEmoji(type);
      expect(emoji).toBe(":x:");
    });
  });

  describe("formatSlackMessages", () => {
    // A sibling describe spies on formatSlackMessages; restore so we exercise the real one.
    beforeEach(() => {
      jest.restoreAllMocks();
    });

    it("should format Slack messages correctly", async () => {
      const type = MessageType.Success;
      const messages = {
        success: ["Success message 1", "Success message 2"],
        error: ["Error message 1", "Error message 2"],
      };

      const formattedMessages = await ClaimsHandler.formatSlackMessages(type, messages);
      const expectedFormattedMessage = ":white_check_mark:Success message 1\n\n:white_check_mark:Success message 2\n";
      expect(formattedMessages).toBe(expectedFormattedMessage);
    });
  });

  describe("checkMissingMandatoryDocs", () => {
    describe("checkMissingMandatoryDocs", () => {
      const mockFiles = [
        { id: 1, docType: ClaimDocument.AADHAAR_PRIMARY },
        { id: 2, docType: ClaimDocument.CLAIM_FORM_PART_A },
        { id: 3, docType: ClaimDocument.CLAIM_FORM_PART_B },
      ];

      const mockOpdClaim = {
        incomingClaim: {
          meta: {
            formType: ClaimFormType.OPD,
            estimatedClaimAmount: 50_000,
          },
        },
        existingClaim: null,
      };

      const mockPlannedClaim = {
        incomingClaim: {
          meta: {
            formType: ClaimFormType.PLANNED,
            estimatedClaimAmount: 1_50_000,
          },
        },
        existingClaim: null,
      };

      it("should return missing mandatory docs for OPD claim", () => {
        const missingDocs = ClaimsHandler.checkMissingMandatoryDocs(mockFiles, mockOpdClaim, {});
        const expectedMissingDocs = mandatoryOpdClaimDocuments.filter(
          (doc) => !mockFiles.map((file) => file.docType).includes(doc),
        );
        expect(missingDocs).toEqual(expectedMissingDocs);
      });

      it("should return missing mandatory docs for PLANNED claim", () => {
        const copyClaimWithAmountLessThan1Lakh = {
          ...mockPlannedClaim,
          incomingClaim: {
            ...mockPlannedClaim.incomingClaim,
            meta: { ...mockPlannedClaim.incomingClaim.meta, estimatedClaimAmount: 50_000 },
          },
        };
        const missingDocs = ClaimsHandler.checkMissingMandatoryDocs(mockFiles, copyClaimWithAmountLessThan1Lakh, {});
        const expectedMissingDocs = mandatoryClaimDocuments.filter(
          (doc) => !mockFiles.map((file) => file.docType).includes(doc),
        );
        expect(missingDocs).toEqual(expectedMissingDocs);
      });

      it("should exclude CLAIM_FORM_PART_B if ENABLE_CLAIM_FORM_A_GENERATION is true", () => {
        const missingDocs = ClaimsHandler.checkMissingMandatoryDocs(mockFiles, mockPlannedClaim, {
          ENABLE_CLAIM_FORM_A_GENERATION: true,
        });
        expect(missingDocs).not.toContain(ClaimDocument.CLAIM_FORM_PART_B);
      });

      it("should include CKYC_FORM if estimated claim amount is greater than 1,00,000", () => {
        const missingDocs = ClaimsHandler.checkMissingMandatoryDocs(
          mockFiles,
          {
            incomingClaim: {
              meta: {
                formType: ClaimFormType.PLANNED,
                estimatedClaimAmount: 2_00_000,
              },
            },
            existingClaim: null,
          },
          {},
        );
        expect(missingDocs).toContain(ClaimDocument.CKYC_FORM);
      });
    });
  });

  describe("isDisallowClaimsPast30days", () => {
    it("should return false if isDisallowClaimsPast30DEnabled is false", () => {
      const claim = {
        type: ClaimType.REIMBURSEMENT,
        meta: {
          formType: ClaimFormType.OPD,
          hospitalization: {
            endDate: moment().subtract(31, "days").toISOString(),
          },
        },
      };

      const result = ClaimsHandler.isDisallowClaimsPast30days(claim, false);
      expect(result).toBe(false);
    });

    it("should return false if claim is not a reimbursement or OPD claim", () => {
      const claim = {
        type: ClaimType.CASHLESS,
        meta: {
          formType: ClaimFormType.HOSPITALIZATION,
          dod: moment().subtract(31, "days").toISOString(),
        },
      };

      const result = ClaimsHandler.isDisallowClaimsPast30days(claim, true);
      expect(result).toBe(false);
    });

    it("should return false if DOD is within 30 days", () => {
      const claim = {
        type: ClaimType.REIMBURSEMENT,
        meta: {
          formType: ClaimFormType.OPD,
          hospitalization: {
            endDate: moment().subtract(29, "days").toISOString(),
          },
        },
      };

      const result = ClaimsHandler.isDisallowClaimsPast30days(claim, true);
      expect(result).toBe(false);
    });

    it("should return true if DOD is older than 30 days for reimbursement claim", () => {
      const claim = {
        type: ClaimType.REIMBURSEMENT,
        meta: {
          formType: ClaimFormType.HOSPITALIZATION,
          dod: moment().subtract(31, "days").toISOString(),
        },
      };

      const result = ClaimsHandler.isDisallowClaimsPast30days(claim, true);
      expect(result).toBe(true);
    });

    it("should return true if DOD is older than 30 days for OPD claim", () => {
      const claim = {
        type: ClaimType.REIMBURSEMENT,
        meta: {
          formType: ClaimFormType.OPD,
          hospitalization: {
            endDate: moment().subtract(31, "days").toISOString(),
          },
        },
      };

      const result = ClaimsHandler.isDisallowClaimsPast30days(claim, true);
      expect(result).toBe(true);
    });

    it("should return true if hospitalization end date is older than 30 days for OPD claim", () => {
      const claim = {
        type: ClaimType.REIMBURSEMENT,
        meta: {
          formType: ClaimFormType.OPD,
          hospitalization: {
            endDate: moment().subtract(31, "days").toISOString(),
          },
        },
      };

      const result = ClaimsHandler.isDisallowClaimsPast30days(claim, true);
      expect(result).toBe(true);
    });

    it("should allow pure pre-hospitalization reimbursement claims beyond 30 days when flag is enabled", () => {
      const claim = {
        type: ClaimType.REIMBURSEMENT,
        meta: {
          formType: ClaimFormType.HOSPITALIZATION,
          prePostSelection: { pre: true, post: false, main: false },
          dod: moment().subtract(45, "days").toISOString(),
        },
      };

      const result = ClaimsHandler.isDisallowClaimsPast30days(claim, true);
      expect(result).toBe(false); // pure pre should NOT be disallowed here
    });

    it("should allow pure post-hospitalization reimbursement claims beyond 30 days when flag is enabled", () => {
      const claim = {
        type: ClaimType.REIMBURSEMENT,
        meta: {
          formType: ClaimFormType.HOSPITALIZATION,
          prePostSelection: { pre: false, post: true, main: false },
          dod: moment().subtract(45, "days").toISOString(),
        },
      };

      const result = ClaimsHandler.isDisallowClaimsPast30days(claim, true);
      expect(result).toBe(false); // pure post should NOT be disallowed here
    });

    it("should disallow reimbursement claims with main hospitalization selected beyond 30 days even when pre/post is selected", () => {
      const claim = {
        type: ClaimType.REIMBURSEMENT,
        meta: {
          formType: ClaimFormType.HOSPITALIZATION,
          prePostSelection: { pre: true, post: false, main: true },
          dod: moment().subtract(45, "days").toISOString(),
        },
      };

      const result = ClaimsHandler.isDisallowClaimsPast30days(claim, true);
      expect(result).toBe(true); // main hospitalization selected → still disallowed
    });

    it("should disallow OPD claims beyond 30 days when no pre/post selection is present", () => {
      const claim = {
        type: ClaimType.REIMBURSEMENT,
        meta: {
          formType: ClaimFormType.OPD,
          hospitalization: {
            endDate: moment().subtract(45, "days").toISOString(),
          },
        },
      };

      const result = ClaimsHandler.isDisallowClaimsPast30days(claim, true);
      expect(result).toBe(true);
    });
  });

  describe("trackInstantWhatsappCsat", () => {
    let trackAttemptSpy: jest.SpyInstance;
    let isEnabledSpy: jest.SpyInstance;
    let getOrgPropertySpy: jest.SpyInstance;

    const makeClaimWithInstantAttempt = (status: "sent" | "failed" | undefined) => ({
      id: "claim-instant-1",
      user_id: "user-1",
      user: {
        id: "user-1",
        org_id: "org-1",
        org_entity_id: null,
        meta: { whatsappUserConsent: true },
      },
      csat: {
        meta: {
          whatsappCsatAttempts: [
            { attemptNumber: 0, status, sentAt: "2024-01-01", templateUsed: "claims_csat_form_link_v1" },
          ],
        },
      },
    });

    beforeEach(() => {
      trackAttemptSpy = jest.spyOn(whatsappCsatModule, "trackWhatsappCsatAttempt").mockResolvedValue(undefined);
      // isWhatsappCsatEnabledForUser checks org feature flags — mock it enabled so tests aren't
      // blocked by pg-mem returning no FEATURE_FLAGS row for the test org.
      isEnabledSpy = jest.spyOn(whatsappCsatModule, "isWhatsappCsatEnabledForUser").mockResolvedValue(true);
      getOrgPropertySpy = jest
        .spyOn(orgPropertyHandler, "getOrgPropertyByNameAndOrgId")
        .mockResolvedValue({ meta: { csatTemplateTitle: "claims_csat_form_link_v1" } } as any);
    });

    afterEach(() => {
      trackAttemptSpy.mockRestore();
      isEnabledSpy.mockRestore();
      getOrgPropertySpy.mockRestore();
    });

    it("should skip tracking when instant attempt already exists with status 'sent'", async () => {
      const claim = makeClaimWithInstantAttempt("sent");
      await ClaimsHandler.trackInstantWhatsappCsat(claim as any, { shouldSendWhatsAppUpdate: true } as any);
      expect(trackAttemptSpy).not.toHaveBeenCalled();
    });

    it("should retry tracking when instant attempt exists with status 'failed'", async () => {
      const claim = makeClaimWithInstantAttempt("failed");
      await ClaimsHandler.trackInstantWhatsappCsat(claim as any, { shouldSendWhatsAppUpdate: true } as any);
      expect(trackAttemptSpy).toHaveBeenCalledWith("claim-instant-1", 0, expect.any(String), "sent");
    });

    it("should skip tracking when config.shouldSendWhatsAppUpdate is false", async () => {
      const claim = { id: "claim-instant-1", user_id: "user-1", csat: {} };
      await ClaimsHandler.trackInstantWhatsappCsat(claim as any, { shouldSendWhatsAppUpdate: false } as any);
      expect(trackAttemptSpy).not.toHaveBeenCalled();
    });

    it("should track when no prior instant attempt exists", async () => {
      const claim = {
        id: "claim-instant-1",
        user_id: "user-1",
        user: { id: "user-1", org_id: "org-1", org_entity_id: null, meta: { whatsappUserConsent: true } },
        csat: { meta: { whatsappCsatAttempts: [] } },
      };
      await ClaimsHandler.trackInstantWhatsappCsat(claim as any, { shouldSendWhatsAppUpdate: true } as any);
      expect(trackAttemptSpy).toHaveBeenCalledWith("claim-instant-1", 0, expect.any(String), "sent");
    });
  });

  describe("createClaim - meta/crm/timeline initialization", () => {
    const userId = v4();
    const policyId = v4();
    const orgId = v4();

    beforeEach(() => {
      jest.restoreAllMocks();
    });

    afterEach(() => {
      jest.restoreAllMocks();
    });

    it("initializes meta when it is undefined and stamps claimIntimationByEmployee", async () => {
      // Mock db.table for user_benefits
      const dbModule = require("../../common/db");
      const dbInstance = dbModule.default || dbModule;
      jest.spyOn(dbInstance, "table").mockReturnValue({
        where: jest.fn().mockResolvedValue([{ user_id: userId, benefit_id: policyId }]),
      });

      // Mock getUserById
      jest
        .spyOn(userHandlers, "getUserById")
        .mockResolvedValue({ id: userId, org_id: orgId, meta: { priority: UserPriority.STANDARD } } as any);

      // Mock getOrgPropertyByNameAndOrgId
      const orgPropertyMock = jest.fn().mockResolvedValue({ meta: {} });
      jest
        .spyOn(require("../../orgProperty/handler"), "getOrgPropertyByNameAndOrgId")
        .mockImplementation(orgPropertyMock);

      // Mock ClaimModel.query().insert()
      let insertedClaim: any = null;
      const queryMock: any = {
        insert: jest.fn().mockImplementation((payload: any) => {
          insertedClaim = payload;
          return {
            returning: jest.fn().mockResolvedValue({ ...payload }),
          };
        }),
      };
      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const claimObj: any = {
        user_id: userId,
        policy_id: policyId,
        // meta is undefined - should be initialized
      };

      await ClaimsHandler.createClaim(claimObj);

      // Verify meta was initialized
      expect(insertedClaim.meta).toBeDefined();
      expect(insertedClaim.meta.crm).toBeDefined();
      expect(insertedClaim.meta.crm.claimStage).toBe(ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE);
      expect(insertedClaim.meta.crm.timeline).toBeDefined();
      expect(insertedClaim.meta.crm.timeline.claimIntimationByEmployee).toBeDefined();
      expect(moment(insertedClaim.meta.crm.timeline.claimIntimationByEmployee).isValid()).toBe(true);
    });

    it("initializes crm and timeline when meta exists but crm is missing", async () => {
      const dbModule = require("../../common/db");
      const dbInstance = dbModule.default || dbModule;
      jest.spyOn(dbInstance, "table").mockReturnValue({
        where: jest.fn().mockResolvedValue([{ user_id: userId, benefit_id: policyId }]),
      });

      jest
        .spyOn(userHandlers, "getUserById")
        .mockResolvedValue({ id: userId, org_id: orgId, meta: { priority: UserPriority.STANDARD } } as any);

      jest.spyOn(require("../../orgProperty/handler"), "getOrgPropertyByNameAndOrgId").mockResolvedValue({ meta: {} });

      let insertedClaim: any = null;
      const queryMock: any = {
        insert: jest.fn().mockImplementation((payload: any) => {
          insertedClaim = payload;
          return {
            returning: jest.fn().mockResolvedValue({ ...payload }),
          };
        }),
      };
      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const claimObj: any = {
        user_id: userId,
        policy_id: policyId,
        meta: {
          someField: "value",
          // no crm - should be initialized
        },
      };

      await ClaimsHandler.createClaim(claimObj);

      expect(insertedClaim.meta.crm).toBeDefined();
      expect(insertedClaim.meta.crm.claimStage).toBe(ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE);
      expect(insertedClaim.meta.crm.timeline).toBeDefined();
      expect(insertedClaim.meta.crm.timeline.claimIntimationByEmployee).toBeDefined();
    });

    it("initializes timeline when crm exists but timeline is missing", async () => {
      const dbModule = require("../../common/db");
      const dbInstance = dbModule.default || dbModule;
      jest.spyOn(dbInstance, "table").mockReturnValue({
        where: jest.fn().mockResolvedValue([{ user_id: userId, benefit_id: policyId }]),
      });

      jest
        .spyOn(userHandlers, "getUserById")
        .mockResolvedValue({ id: userId, org_id: orgId, meta: { priority: UserPriority.STANDARD } } as any);

      jest.spyOn(require("../../orgProperty/handler"), "getOrgPropertyByNameAndOrgId").mockResolvedValue({ meta: {} });

      let insertedClaim: any = null;
      const queryMock: any = {
        insert: jest.fn().mockImplementation((payload: any) => {
          insertedClaim = payload;
          return {
            returning: jest.fn().mockResolvedValue({ ...payload }),
          };
        }),
      };
      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const claimObj: any = {
        user_id: userId,
        policy_id: policyId,
        meta: {
          crm: {
            // no timeline - should be initialized
          },
        },
      };

      await ClaimsHandler.createClaim(claimObj);

      expect(insertedClaim.meta.crm.timeline).toBeDefined();
      expect(insertedClaim.meta.crm.timeline.claimIntimationByEmployee).toBeDefined();
      expect(moment(insertedClaim.meta.crm.timeline.claimIntimationByEmployee).isValid()).toBe(true);
    });

    it("does not overwrite existing claimIntimationByEmployee timestamp", async () => {
      const existingTimestamp = "2024-01-15T10:00:00.000Z";

      const dbModule = require("../../common/db");
      const dbInstance = dbModule.default || dbModule;
      jest.spyOn(dbInstance, "table").mockReturnValue({
        where: jest.fn().mockResolvedValue([{ user_id: userId, benefit_id: policyId }]),
      });

      jest
        .spyOn(userHandlers, "getUserById")
        .mockResolvedValue({ id: userId, org_id: orgId, meta: { priority: UserPriority.STANDARD } } as any);

      jest.spyOn(require("../../orgProperty/handler"), "getOrgPropertyByNameAndOrgId").mockResolvedValue({ meta: {} });

      let insertedClaim: any = null;
      const queryMock: any = {
        insert: jest.fn().mockImplementation((payload: any) => {
          insertedClaim = payload;
          return {
            returning: jest.fn().mockResolvedValue({ ...payload }),
          };
        }),
      };
      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const claimObj: any = {
        user_id: userId,
        policy_id: policyId,
        meta: {
          crm: {
            timeline: {
              claimIntimationByEmployee: existingTimestamp,
            },
          },
        },
      };

      await ClaimsHandler.createClaim(claimObj);

      expect(insertedClaim.meta.crm.timeline.claimIntimationByEmployee).toBe(existingTimestamp);
    });
  });

  describe("updateClaim - claimIntimationByEmployee timestamp preservation/backfill", () => {
    const baseClaimId = v4();
    const userId = v4();
    const policyId = v4();

    const ctx: any = {
      user: { isAdmin: true },
    };

    beforeEach(() => {
      jest.spyOn(utils, "delCacheByKey").mockResolvedValue(undefined as any);
      jest.spyOn(ClaimsQueryHandler, "closeAllQueriesByClaimId").mockResolvedValue(undefined as any);
      jest
        .spyOn(userHandlers, "getUserById")
        .mockResolvedValue({ id: userId, meta: { priority: UserPriority.STANDARD } } as any);
      const dbModule = require("../../common/db");
      const dbInstance = dbModule.default || dbModule;
      jest.spyOn(dbInstance, "table").mockReturnValue({
        insert: jest.fn().mockResolvedValue({}),
      });
    });

    afterEach(() => {
      jest.restoreAllMocks();
    });

    it("preserves existing claimIntimationByEmployee when payload does not override it", async () => {
      const existingIntimation = "2024-01-01T00:00:00.000Z";

      const existingClaim: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        status: Status.CLAIM_INTIMATED,
        meta: {
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "ONGOING",
            timeline: {
              claimIntimationByEmployee: existingIntimation,
            },
          },
        },
      };

      let patchedPayload: any = null;

      const queryMock: any = {
        findById: jest.fn().mockReturnThis(),
        select: jest.fn().mockResolvedValue(existingClaim),
        patch: jest.fn().mockImplementation((payload: any) => {
          patchedPayload = payload;
          return queryMock;
        }),
        returning: jest.fn().mockResolvedValue(existingClaim),
      };

      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const incoming: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        meta: {
          note: "Updated note to trigger hasNewUpdates",
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            // no timeline → should preserve DB value
          },
        },
      };

      await ClaimsHandler.updateClaim(incoming, ctx);

      expect(patchedPayload.meta.crm.timeline.claimIntimationByEmployee).toBe(existingIntimation);
    });

    it("preserves intimation-time client snapshot when the employee client changes later", async () => {
      jest
        .spyOn(userHandlers, "getUserById")
        .mockResolvedValue({ id: userId, meta: { clientId: "TL-002", clientName: "Client Two" } } as any);

      const existingClaim: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        status: Status.CLAIM_INTIMATED,
        meta: {
          clientIdAtIntimation: "TL-001",
          clientNameAtIntimation: "Client One",
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "ONGOING",
            timeline: {
              claimIntimationByEmployee: "2024-01-01T00:00:00.000Z",
            },
          },
        },
      };

      let patchedPayload: any = null;

      const queryMock: any = {
        findById: jest.fn().mockReturnThis(),
        select: jest.fn().mockResolvedValue(existingClaim),
        patch: jest.fn().mockImplementation((payload: any) => {
          patchedPayload = payload;
          return queryMock;
        }),
        returning: jest.fn().mockResolvedValue(existingClaim),
      };

      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const incoming: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        meta: {
          note: "Updated note to trigger hasNewUpdates",
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
          },
        },
      };

      await ClaimsHandler.updateClaim(incoming, ctx);

      expect(patchedPayload.meta.clientIdAtIntimation).toBe("TL-001");
      expect(patchedPayload.meta.clientNameAtIntimation).toBe("Client One");
    });

    it("backfills claimIntimationByEmployee when neither DB nor payload has a value", async () => {
      const existingClaim: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        status: Status.CLAIM_INTIMATED,
        meta: {
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "ONGOING",
            timeline: {},
          },
        },
      };

      let patchedPayload: any = null;

      const queryMock: any = {
        findById: jest.fn().mockReturnThis(),
        select: jest.fn().mockResolvedValue(existingClaim),
        patch: jest.fn().mockImplementation((payload: any) => {
          patchedPayload = payload;
          return queryMock;
        }),
        returning: jest.fn().mockResolvedValue(existingClaim),
      };

      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const incoming: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        meta: {
          note: "Updated note to trigger hasNewUpdates",
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
          },
        },
      };

      await ClaimsHandler.updateClaim(incoming, ctx);

      const stamped = patchedPayload.meta.crm.timeline.claimIntimationByEmployee;
      expect(stamped).toBeDefined();
      const stampedMoment = moment(stamped);
      expect(stampedMoment.isValid()).toBe(true);
      // Verify it's a recent timestamp (within last minute)
      expect(moment().diff(stampedMoment, "seconds")).toBeLessThan(60);
    });

    it("restores DB claimIntimationByEmployee when payload explicitly clears it with null", async () => {
      const existingIntimation = "2024-01-01T00:00:00.000Z";

      const existingClaim: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        status: Status.CLAIM_INTIMATED,
        meta: {
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "ONGOING",
            timeline: {
              claimIntimationByEmployee: existingIntimation,
            },
          },
        },
      };

      let patchedPayload: any = null;

      const queryMock: any = {
        findById: jest.fn().mockReturnThis(),
        select: jest.fn().mockResolvedValue(existingClaim),
        patch: jest.fn().mockImplementation((payload: any) => {
          patchedPayload = payload;
          return queryMock;
        }),
        returning: jest.fn().mockResolvedValue(existingClaim),
      };

      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const incoming: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        meta: {
          note: "Updated note to trigger hasNewUpdates",
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            timeline: {
              claimIntimationByEmployee: null, // explicitly cleared by caller
            },
          },
        },
      };

      await ClaimsHandler.updateClaim(incoming, ctx);

      // null from payload should be treated as "missing" — DB value must be restored
      expect(patchedPayload.meta.crm.timeline.claimIntimationByEmployee).toBe(existingIntimation);
    });

    it("does not overwrite claimIntimationByEmployee when payload explicitly provides it", async () => {
      const existingIntimation = "2024-01-01T00:00:00.000Z";
      const payloadIntimation = "2024-06-15T12:00:00.000Z";

      const existingClaim: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        status: Status.CLAIM_INTIMATED,
        meta: {
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "ONGOING",
            timeline: {
              claimIntimationByEmployee: existingIntimation,
            },
          },
        },
      };

      let patchedPayload: any = null;

      const queryMock: any = {
        findById: jest.fn().mockReturnThis(),
        select: jest.fn().mockResolvedValue(existingClaim),
        patch: jest.fn().mockImplementation((payload: any) => {
          patchedPayload = payload;
          return queryMock;
        }),
        returning: jest.fn().mockResolvedValue(existingClaim),
      };

      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const incoming: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        meta: {
          note: "Updated note to trigger hasNewUpdates",
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            timeline: {
              claimIntimationByEmployee: payloadIntimation,
            },
          },
        },
      };

      await ClaimsHandler.updateClaim(incoming, ctx);

      expect(patchedPayload.meta.crm.timeline.claimIntimationByEmployee).toBe(payloadIntimation);
    });

    it("initializes timeline when meta and crm exist in payload but timeline is absent and DB meta is null", async () => {
      const existingClaim: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        status: Status.CLAIM_INTIMATED,
        meta: null, // no meta at all in DB
      };

      let patchedPayload: any = null;

      const queryMock: any = {
        findById: jest.fn().mockReturnThis(),
        select: jest.fn().mockResolvedValue(existingClaim),
        patch: jest.fn().mockImplementation((payload: any) => {
          patchedPayload = payload;
          return queryMock;
        }),
        returning: jest.fn().mockResolvedValue(existingClaim),
      };

      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const incoming: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        meta: {
          note: "New note",
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
          },
        },
      };

      await ClaimsHandler.updateClaim(incoming, ctx);

      expect(patchedPayload.meta).toBeDefined();
      expect(patchedPayload.meta.crm).toBeDefined();
      expect(patchedPayload.meta.crm.timeline).toBeDefined();
      const stamped = patchedPayload.meta.crm.timeline.claimIntimationByEmployee;
      expect(stamped).toBeDefined();
      expect(moment(stamped).isValid()).toBe(true);
    });

    it("initializes crm when meta exists but crm is missing", async () => {
      const existingClaim: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        status: Status.CLAIM_INTIMATED,
        meta: {
          someField: "value",
          // no crm
        },
      };

      let patchedPayload: any = null;

      const queryMock: any = {
        findById: jest.fn().mockReturnThis(),
        select: jest.fn().mockResolvedValue(existingClaim),
        patch: jest.fn().mockImplementation((payload: any) => {
          patchedPayload = payload;
          return queryMock;
        }),
        returning: jest.fn().mockResolvedValue(existingClaim),
      };

      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const incoming: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        meta: {
          note: "New note",
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
          },
        },
      };

      await ClaimsHandler.updateClaim(incoming, ctx);

      expect(patchedPayload.meta.crm).toBeDefined();
      expect(patchedPayload.meta.crm.timeline).toBeDefined();
      expect(patchedPayload.meta.crm.timeline.claimIntimationByEmployee).toBeDefined();
    });

    it("initializes timeline when meta.crm exists but timeline is missing", async () => {
      const existingClaim: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        status: Status.CLAIM_INTIMATED,
        meta: {
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "ONGOING",
            // no timeline
          },
        },
      };

      let patchedPayload: any = null;

      const queryMock: any = {
        findById: jest.fn().mockReturnThis(),
        select: jest.fn().mockResolvedValue(existingClaim),
        patch: jest.fn().mockImplementation((payload: any) => {
          patchedPayload = payload;
          return queryMock;
        }),
        returning: jest.fn().mockResolvedValue(existingClaim),
      };

      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const incoming: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        meta: {
          note: "New note",
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
          },
        },
      };

      await ClaimsHandler.updateClaim(incoming, ctx);

      expect(patchedPayload.meta.crm.timeline).toBeDefined();
      const stamped = patchedPayload.meta.crm.timeline.claimIntimationByEmployee;
      expect(stamped).toBeDefined();
      expect(moment(stamped).isValid()).toBe(true);
    });

    it("does not stamp claimIntimationByEmployee when stage is not CLAIM_INTIMATION_BY_EMPLOYEE", async () => {
      const existingClaim: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        status: Status.CLAIM_INTIMATED,
        meta: {
          crm: {
            claimStage: ClaimStage.MANDATORY_DOCUMENTS_PENDING,
            claimStatus: "ONGOING",
            timeline: {},
          },
        },
      };

      let patchedPayload: any = null;

      const queryMock: any = {
        findById: jest.fn().mockReturnThis(),
        select: jest.fn().mockResolvedValue(existingClaim),
        patch: jest.fn().mockImplementation((payload: any) => {
          patchedPayload = payload;
          return queryMock;
        }),
        returning: jest.fn().mockResolvedValue(existingClaim),
      };

      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const incoming: any = {
        id: baseClaimId,
        user_id: userId,
        policy_id: policyId,
        meta: {
          note: "Updated note",
          crm: {
            claimStage: ClaimStage.MANDATORY_DOCUMENTS_PENDING,
          },
        },
      };

      await ClaimsHandler.updateClaim(incoming, ctx);

      expect(patchedPayload.meta.crm.timeline?.claimIntimationByEmployee).toBeUndefined();
    });
  });

  describe("createClaim - stage guard negative coverage", () => {
    const userId = v4();
    const policyId = v4();
    const orgId = v4();

    beforeEach(() => {
      jest.restoreAllMocks();
    });

    afterEach(() => {
      jest.restoreAllMocks();
    });

    it("does not stamp claimIntimationByEmployee when stage is not CLAIM_INTIMATION_BY_EMPLOYEE", async () => {
      const dbModule = require("../../common/db");
      const dbInstance = dbModule.default || dbModule;
      jest.spyOn(dbInstance, "table").mockReturnValue({
        where: jest.fn().mockResolvedValue([{ user_id: userId, benefit_id: policyId }]),
      });

      jest
        .spyOn(userHandlers, "getUserById")
        .mockResolvedValue({ id: userId, org_id: orgId, meta: { priority: UserPriority.STANDARD } } as any);

      jest.spyOn(require("../../orgProperty/handler"), "getOrgPropertyByNameAndOrgId").mockResolvedValue({ meta: {} });

      let insertedClaim: any = null;
      const queryMock: any = {
        insert: jest.fn().mockImplementation((payload: any) => {
          insertedClaim = payload;
          return {
            returning: jest.fn().mockResolvedValue({ ...payload }),
          };
        }),
      };
      jest.spyOn(ClaimModel, "query").mockImplementation(() => queryMock);

      const claimObj: any = {
        user_id: userId,
        policy_id: policyId,
        meta: {
          crm: {
            claimStage: ClaimStage.MANDATORY_DOCUMENTS_PENDING,
            timeline: {},
          },
        },
      };

      await ClaimsHandler.createClaim(claimObj);

      expect(insertedClaim.meta.crm.timeline?.claimIntimationByEmployee).toBeUndefined();
    });
  });

  describe("updateClaim — headless context (ctx.user null)", () => {
    /**
     * Regression: bulk CLI upload creates a Context with no req, so ctx.user returns null.
     * Guards at lines 303, 331, and 344 must not throw TypeError in this scenario.
     */
    const claimId = v4();
    const userId = v4();

    const existingClaim = {
      id: claimId,
      user_id: userId,
      policy_id: "policy-id",
      status: Status.CLAIM_INTIMATED,
      claim_owner: "owner-id",
      meta: {
        crm: {
          claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
          claimStatus: "Intimated",
          timeline: { claimIntimationByEmployee: "2024-01-01T00:00:00.000Z" },
        },
      },
    };

    let patchMock: jest.Mock;

    beforeEach(() => {
      const returningMock = jest.fn().mockResolvedValue({ ...existingClaim, status: Status.CLAIM_SETTLED });
      patchMock = jest.fn().mockReturnValue({ returning: returningMock });

      jest
        .spyOn(ClaimModel, "query")
        .mockReturnValueOnce({
          findById: jest.fn().mockReturnValue({ select: jest.fn().mockResolvedValue(existingClaim) }),
        } as any)
        .mockReturnValueOnce({
          findById: jest.fn().mockReturnValue({ patch: patchMock }),
        } as any);

      jest.spyOn(userHandlers, "userByIdDataLoader").mockReturnValue({
        load: jest.fn().mockResolvedValue({ meta: { priority: UserPriority.STANDARD } }),
      } as any);

      jest.spyOn(ClaimsQueryHandler, "closeAllQueriesByClaimId").mockResolvedValue(undefined as any);
      jest.spyOn(db, "table").mockReturnValue({ insert: jest.fn().mockResolvedValue([]) } as any);
      jest.spyOn(utils, "delCacheByKey").mockResolvedValue(undefined as any);
    });

    afterEach(() => {
      jest.restoreAllMocks();
    });

    it("does not throw and updates status via guard 303 when ctx.isAutomatedChange is true", async () => {
      const ctx = new context.Context(); // no req → ctx.user returns null
      ctx.isAutomatedChange = true; // CLI bulk upload sets this to allow status updates
      const incomingClaim = {
        id: claimId,
        user_id: userId,
        policy_id: "policy-id",
        claim_owner: "owner-id",
        status: Status.CLAIM_INTIMATED,
        meta: {
          crm: {
            // Different stage → hasNewUpdates=true, bypassing the early-return at guard 344
            claimStage: ClaimStage.CLAIM_SETTLED,
            claimStatus: "Settled",
          },
        },
      };

      // Should resolve without TypeError despite ctx.user being null
      const result = await ClaimsHandler.updateClaim(incomingClaim as any, ctx);

      // Guard 303: ctx.isAutomatedChange=true → status-update branch taken; patch receives updated status
      expect(patchMock).toHaveBeenCalledWith(expect.objectContaining({ status: Status.CLAIM_SETTLED }));

      // Guard 331: headless ctx (user null) → updateFields not narrowed to portal-user subset
      // Verified implicitly: patch is called (not skipped by narrow updateFields logic)

      // Guard 344: hasNewUpdates=true (claimStage changed) → no premature return/throw
      expect(result).toBeDefined();
    });

    it.each([
      ["commits", true, 1],
      ["rolls back", false, 0],
    ])("clears the balance cache only after the caller's transaction %s", async (_label, commits, calls) => {
      const invalidate = jest.spyOn(utils, "invalidateBalanceSiCache").mockResolvedValue(undefined);
      let settle!: () => void;
      const executionPromise = new Promise<void>((resolve, reject) => {
        settle = commits ? resolve : () => reject(new Error("rolled back"));
      });
      const ctx = new context.Context();
      ctx.isAutomatedChange = true;
      const incomingClaim = {
        id: claimId,
        user_id: userId,
        policy_id: "policy-id",
        claim_owner: "owner-id",
        status: Status.CLAIM_INTIMATED,
        meta: { crm: { claimStage: ClaimStage.CLAIM_SETTLED, claimStatus: "Settled" } },
      };

      await ClaimsHandler.updateClaim(incomingClaim as any, ctx, undefined, { executionPromise, table: db.table } as any);
      expect(invalidate).not.toHaveBeenCalled();
      settle();
      await new Promise((resolve) => setImmediate(resolve));

      expect(invalidate).toHaveBeenCalledTimes(calls);
    });

    it("updates claim when only update_source differs", async () => {
      const ctx = new context.Context();
      const incomingClaim = {
        id: claimId,
        user_id: userId,
        policy_id: "policy-id",
        claim_owner: "owner-id",
        status: Status.CLAIM_INTIMATED,
        meta: {
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "Intimated",
            timeline: { claimIntimationByEmployee: "2024-01-01T00:00:00.000Z" },
          },
        },
        update_source: ClaimSource.CARE_API,
      };

      const result = await ClaimsHandler.updateClaim(incomingClaim as any, ctx);

      expect(patchMock).toHaveBeenCalledWith(expect.objectContaining({ update_source: ClaimSource.CARE_API }));
      expect(result).toBeDefined();
    });

    /**
     * Regression for the isAutomatedChange + PORTAL_USER field-restriction gap.
     *
     * claimsBulkUpload sets isAutomatedChange=true on a headless ctx (no user). If the DB
     * claim's update_source is PORTAL_USER, effectiveSource becomes PORTAL_USER. Previously,
     * the third condition in the field-restriction guard had !ctx.isAutomatedChange, meaning
     * automated headless callers bypassed the narrowing and could write claim_owner / csat /
     * dependent_id / type in addition to meta & user_contact_id.
     *
     * After the fix, the guard drops !ctx.isAutomatedChange: portal source means restricted
     * fields regardless of the automation flag. isAutomatedChange only unlocks status updates.
     * Observable: csat ("HIGH") is outside ["meta", "user_contact_id"], so it is invisible to
     * hasNewUpdates → throws instead of patching with unrestricted fields.
     */
    it("applies portal-user field restrictions even when isAutomatedChange=true (bulk upload gap)", async () => {
      jest.restoreAllMocks();

      const existingPortalClaim = { ...existingClaim, csat: null };
      const returningMock = jest.fn().mockResolvedValue(existingPortalClaim);
      const patchMockBulk = jest.fn().mockReturnValue({ returning: returningMock });

      jest
        .spyOn(ClaimModel, "query")
        .mockReturnValueOnce({
          findById: jest.fn().mockReturnValue({ select: jest.fn().mockResolvedValue(existingPortalClaim) }),
        } as any)
        .mockReturnValueOnce({
          findById: jest.fn().mockReturnValue({ patch: patchMockBulk }),
        } as any);

      jest.spyOn(userHandlers, "userByIdDataLoader").mockReturnValue({
        load: jest.fn().mockResolvedValue({ meta: { priority: UserPriority.STANDARD } }),
      } as any);
      jest.spyOn(ClaimsQueryHandler, "closeAllQueriesByClaimId").mockResolvedValue(undefined as any);
      jest.spyOn(db, "table").mockReturnValue({ insert: jest.fn().mockResolvedValue([]) } as any);
      jest.spyOn(utils, "delCacheByKey").mockResolvedValue(undefined as any);

      const ctx = new context.Context(); // no req → ctx.user is null
      ctx.isAutomatedChange = true; // bulk upload path — was previously bypassing field restriction

      const incomingClaim = {
        id: claimId,
        user_id: userId,
        policy_id: "policy-id",
        claim_owner: "owner-id",
        status: Status.CLAIM_INTIMATED,
        update_source: ClaimSource.PORTAL_USER, // effectiveSource resolves to PORTAL_USER
        csat: "HIGH", // non-portal field; must not be writable
        meta: {
          crm: {
            // Same stage → status guard reverts it; only csat differs
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "Intimated",
          },
        },
      };

      // updateFields narrowed to ["meta", "user_contact_id"] despite isAutomatedChange=true
      // → csat diff invisible → hasNewUpdates=false → throws (headless ctx, no silent-return)
      await expect(ClaimsHandler.updateClaim(incomingClaim as any, ctx)).rejects.toThrow(
        "Nothing new provided to update claim",
      );
      expect(patchMockBulk).not.toHaveBeenCalled();
    });

    it("throws when ctx.user is null, isAutomatedChange is false, and nothing new to update", async () => {
      const ctx = new context.Context(); // no req → ctx.user returns null
      // isAutomatedChange stays false — simulates a ctx that exists but has no user and no automation flag

      const incomingClaim = {
        id: claimId,
        user_id: userId,
        policy_id: "policy-id",
        claim_owner: "owner-id",
        status: Status.CLAIM_INTIMATED,
        meta: {
          crm: {
            // Same stage as existingClaim → guard 303 reverts status → hasNewUpdates=false → guard 344 fires
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "Intimated",
          },
        },
      };

      // Guard 303: isAutomatedChange=false, user=null, !ctx=false → status reverted to existing
      // Guard 344: ctx.user is null → portal-user silent-return branch not taken → throws
      await expect(ClaimsHandler.updateClaim(incomingClaim as any, ctx)).rejects.toThrow(
        "Nothing new provided to update claim",
      );
    });

    /**
     * Internal callers such as TPA processors (careClaimProcessor, ICICIClaimProcessor,
     * tpaClaimsSync) and background mutations omit ctx entirely. Omitting ctx is the
     * established signal for a trusted internal caller and must continue to allow status updates.
     * This test locks that behaviour so it cannot be removed silently during a future refactor.
     */
    it("allows status update when ctx is omitted entirely — trusted internal caller path", async () => {
      jest.spyOn(userHandlers, "getUserById").mockResolvedValue({ meta: { priority: UserPriority.STANDARD } } as any);

      const incomingClaim = {
        id: claimId,
        user_id: userId,
        policy_id: "policy-id",
        claim_owner: "owner-id",
        status: Status.CLAIM_INTIMATED,
        meta: { crm: { claimStage: ClaimStage.CLAIM_SETTLED, claimStatus: "Settled" } },
      };

      // No ctx → !ctx at line 307 is truthy → status-update branch taken without admin or isAutomatedChange flag
      const result = await ClaimsHandler.updateClaim(incomingClaim as any);
      expect(patchMock).toHaveBeenCalledWith(expect.objectContaining({ status: Status.CLAIM_SETTLED }));
      expect(result).toBeDefined();
    });

    /**
     * Regression for headless-ctx + portal-source field restriction (isAutomatedChange=false).
     *
     * Covers the path where a headless caller without the automation flag processes a
     * portal-sourced claim. updateFields must be narrowed to ["meta", "user_contact_id"].
     *
     * Observable: csat ("HIGH") is not in the narrowed field list, so the csat-only diff is
     * invisible to hasNewUpdates → throws "Nothing new provided to update claim" rather than
     * patching.
     */
    it("applies portal-user field restrictions when ctx.user is null and update_source is PORTAL_USER", async () => {
      // Re-mock with csat: null on the existing claim so csat is JSON-serialisable for the
      // isEqual loop at line 340 (JSON.stringify(undefined) is not parseable).
      jest.restoreAllMocks();

      const existingPortalClaim = { ...existingClaim, csat: null };
      const returningMock2 = jest.fn().mockResolvedValue(existingPortalClaim);
      const patchMock2 = jest.fn().mockReturnValue({ returning: returningMock2 });

      jest
        .spyOn(ClaimModel, "query")
        .mockReturnValueOnce({
          findById: jest.fn().mockReturnValue({ select: jest.fn().mockResolvedValue(existingPortalClaim) }),
        } as any)
        .mockReturnValueOnce({
          findById: jest.fn().mockReturnValue({ patch: patchMock2 }),
        } as any);

      jest.spyOn(userHandlers, "userByIdDataLoader").mockReturnValue({
        load: jest.fn().mockResolvedValue({ meta: { priority: UserPriority.STANDARD } }),
      } as any);
      jest.spyOn(ClaimsQueryHandler, "closeAllQueriesByClaimId").mockResolvedValue(undefined as any);
      jest.spyOn(db, "table").mockReturnValue({ insert: jest.fn().mockResolvedValue([]) } as any);
      jest.spyOn(utils, "delCacheByKey").mockResolvedValue(undefined as any);

      const ctx = new context.Context(); // ctx.user is null, isAutomatedChange stays false
      const incomingClaim = {
        id: claimId,
        user_id: userId,
        policy_id: "policy-id",
        claim_owner: "owner-id",
        status: Status.CLAIM_INTIMATED,
        update_source: ClaimSource.PORTAL_USER,
        csat: "HIGH", // non-portal field; not in ["meta", "user_contact_id"]
        meta: {
          crm: {
            // Same stage → status reverts at line 307 so only csat differs
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "Intimated",
          },
        },
      };

      // updateFields narrowed to ["meta", "user_contact_id"] → csat not compared → hasNewUpdates=false
      // ctx.user is null so portal-user silent-return branch (line 348) is not taken → throws
      await expect(ClaimsHandler.updateClaim(incomingClaim as any, ctx)).rejects.toThrow(
        "Nothing new provided to update claim",
      );
      expect(patchMock2).not.toHaveBeenCalled();
    });
  });

  describe("updateClaim — source parameter as authoritative signal", () => {
    /**
     * After normalizing both guards to use effectiveSource = source ?? claimObj.update_source,
     * the source function parameter must be the authoritative caller-intent signal for both:
     *   Guard A (field restriction) — only ["meta", "user_contact_id"] writable for portal flows
     *   Guard B (empty-update behavior) — silent return instead of error for portal flows
     */
    const claimId = v4();
    const userId = v4();

    const existingClaim = {
      id: claimId,
      user_id: userId,
      policy_id: "policy-id",
      status: Status.CLAIM_INTIMATED,
      claim_owner: "owner-id",
      meta: {
        crm: {
          claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
          claimStatus: "Intimated",
          timeline: { claimIntimationByEmployee: "2024-01-01T00:00:00.000Z" },
        },
      },
    };

    beforeEach(() => {
      jest.spyOn(ClaimModel, "query").mockReturnValue({
        findById: jest.fn().mockReturnValue({ select: jest.fn().mockResolvedValue(existingClaim) }),
      } as any);

      jest.spyOn(userHandlers, "userByIdDataLoader").mockReturnValue({
        load: jest.fn().mockResolvedValue({ meta: { priority: UserPriority.STANDARD } }),
      } as any);
    });

    afterEach(() => {
      jest.restoreAllMocks();
    });

    it("restricts updateFields to meta/user_contact_id when admin passes source=PORTAL_USER without claimObj.update_source", async () => {
      /**
       * Scenario: admin calls updateClaim with source=PORTAL_USER but claimObj.update_source is unset.
       * Guard A must fire based on source (effectiveSource), not claimObj.update_source.
       * The incoming claim changes only status — a field outside the restricted set.
       * With field restriction applied: hasNewUpdates=false → Guard B fires → silent return.
       * Without field restriction: hasNewUpdates=true → would proceed to patch.
       */
      const adminCtx = new context.Context({ user: { isAdmin: true, id: userId } } as any);

      const incomingClaim = {
        id: claimId,
        user_id: userId,
        policy_id: "policy-id",
        claim_owner: "owner-id",
        // Different status — would be a new update if updateFields were unrestricted
        status: Status.CLAIM_SETTLED,
        meta: {
          crm: {
            // Same stage and status as existingClaim → no change in restricted fields
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "Intimated",
          },
        },
        // update_source deliberately not set — source param is the only signal
      };

      // Should silently return (not patch, not throw) because field restriction via source
      // leaves hasNewUpdates=false, and Guard B recognises PORTAL_USER and returns quietly.
      const result = await ClaimsHandler.updateClaim(incomingClaim as any, adminCtx, ClaimSource.PORTAL_USER);
      expect(result).toBeDefined();
      expect(result.id).toBe(claimId);
    });

    it("silently returns (does not throw) when admin passes source=PORTAL_USER and nothing is new", async () => {
      /**
       * Guard B must use effectiveSource, not the raw source param, to detect portal flow.
       * When nothing has changed and source=PORTAL_USER, the correct behaviour is a quiet
       * return — not the CustomError thrown for non-portal callers.
       */
      const adminCtx = new context.Context({ user: { isAdmin: true, id: userId } } as any);

      const incomingClaim = {
        id: claimId,
        user_id: userId,
        policy_id: "policy-id",
        claim_owner: "owner-id",
        status: Status.CLAIM_INTIMATED,
        meta: {
          crm: {
            claimStage: ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE,
            claimStatus: "Intimated",
          },
        },
      };

      await expect(
        ClaimsHandler.updateClaim(incomingClaim as any, adminCtx, ClaimSource.PORTAL_USER),
      ).resolves.toBeDefined();
    });
  });

  describe("ICICI claim-number family matching (BX-3681)", () => {
    // claim c9ed2cd5 (mockDbData, claimNumber "ins-123") gets a rootClaimNumber stamped so a later
    // family sibling resolves to it instead of inserting a duplicate.
    const rootedClaimId = "c9ed2cd5-bd24-47e8-aaab-fcb997b445d3";
    beforeAll(async () => {
      // pg-mem needs meta typed as JSONB for the `meta->>'…'` lookups used by these matchers.
      await db.raw(`ALTER TABLE claims ALTER COLUMN meta TYPE JSONB`);
      await db.raw(`ALTER TABLE users ALTER COLUMN meta TYPE JSONB`);
      const existing = await db("claims").where("id", rootedClaimId).first();
      await db("claims")
        .where("id", rootedClaimId)
        .update({ meta: JSON.stringify({ ...existing.meta, rootClaimNumber: "110202443844" }) });
    });

    // Guards the write path (BX-3739): the collapse fix stamps meta.rootClaimNumber, but ClaimModel's
    // meta jsonSchema is additionalProperties:false. If rootClaimNumber is not declared there,
    // ClaimModel.fromJson / createClaim / updateClaim throw a ValidationError and the collapsed claim
    // is silently dropped on every real sync. (The DB-update setup above bypasses model validation, so
    // it does not exercise this — hence a dedicated schema-level assertion.)
    describe("ClaimModel meta jsonSchema", () => {
      it("permits meta.rootClaimNumber (declared despite additionalProperties:false)", () => {
        expect(() =>
          ClaimModel.fromJson({
            meta: { claimNumber: "110202443844", rootClaimNumber: "110202443844" },
          } as any),
        ).not.toThrow();
      });

      it("still rejects an undeclared meta property (additionalProperties:false is intact)", () => {
        expect(() => ClaimModel.fromJson({ meta: { someUnknownField: "x" } } as any)).toThrow(
          /must NOT have additional properties/,
        );
      });
    });

    describe("getClaimByRootClaimNumber", () => {
      it("resolves a claim by its stored rootClaimNumber", async () => {
        const claim = await ClaimsHandler.getClaimByRootClaimNumber("110202443844");
        expect(claim?.id).toBe(rootedClaimId);
      });

      it("resolves a claim whose claimNumber IS the root (pre-family-key base member)", async () => {
        const claim = await ClaimsHandler.getClaimByRootClaimNumber("ins-456");
        expect(claim?.id).toBe("6cd84e1e-33e6-4985-96a4-3f6b0256e625");
      });

      it("returns undefined when no family member matches", async () => {
        const claim = await ClaimsHandler.getClaimByRootClaimNumber("does-not-exist");
        expect(claim).toBeUndefined();
      });
    });

    describe("findMatchingClaim", () => {
      it("links a settlement to its cashless family via rootClaimNumber when the claim number differs", async () => {
        const matched = await findMatchingClaim(
          {
            claimNumber: "220204993750", // settlement number — not present in DB
            rootClaimNumber: "110202443844", // resolves to the rooted claim above
            claimIntimationNumber: null,
            employeeId: null,
            policyNumber: null,
            gender: null,
            relation: null,
            typeOfClaim: ClaimType.REIMBURSEMENT,
            patientName: null,
            dateOfAdmission: null,
            orgName: null,
            employeeName: null,
          },
          undefined,
          TpaIntegrationType.ICICI_API,
        );
        expect(matched?.id).toBe(rootedClaimId);
      });

      it("does not use the root lookup for non-ICICI TPAs", async () => {
        const matched = await findMatchingClaim(
          {
            claimNumber: "does-not-exist-xyz",
            rootClaimNumber: "110202443844",
            claimIntimationNumber: null,
            employeeId: null,
            policyNumber: null,
            gender: null,
            relation: null,
            typeOfClaim: ClaimType.REIMBURSEMENT,
            patientName: null,
            dateOfAdmission: null,
            orgName: null,
            employeeName: null,
          },
          undefined,
          TpaIntegrationType.MEDIASSIST_API,
        ).catch(() => null);
        // Mediassist skips the root branch, so it never resolves to the ICICI-rooted claim.
        expect(matched?.id).not.toBe(rootedClaimId);
      });
    });
  });
});

describe("handleClaimTicketUpdates failure handling (BX-4053)", () => {
  const run = (strictDelivery?: boolean) =>
    ClaimsHandler.handleClaimTicketUpdates(
      "NOT_AN_ACTION" as never,
      { id: "claim", meta: {} } as never,
      {},
      [],
      {} as never,
      { id: "member" },
      undefined,
      undefined,
      strictDelivery,
    );

  it("logs and resolves a failure for direct callers, as before", async () => {
    const event = jest.spyOn(logger, "event");
    const error = jest.spyOn(logger, "error").mockImplementation(() => undefined);
    try {
      await expect(run()).resolves.toBeUndefined();
      expect(event).toHaveBeenCalledWith("handleClaimTicketUpdates");
      expect(error).toHaveBeenCalledWith(expect.stringContaining("Unknown action type: NOT_AN_ACTION"));
    } finally {
      event.mockRestore();
      error.mockRestore();
    }
  });

  it("rethrows the failure for outbox-driven callers", async () => {
    await expect(run(true)).rejects.toThrow("Unknown action type");
  });

  describe("strict delivery through the notify actions", () => {
    const notify = (action: ClaimTicketActions, strictDelivery: boolean) =>
      ClaimsHandler.handleClaimTicketUpdates(
        action,
        { id: "claim", meta: {} } as never,
        {},
        [],
        {} as never,
        { id: "member" },
        undefined,
        undefined,
        strictDelivery,
      );

    afterEach(() => jest.restoreAllMocks());

    it.each([ClaimTicketActions.CREATE_TICKET_AND_NOTIFY, ClaimTicketActions.UPDATE_TICKET_AND_NOTIFY])(
      "%s hands strict delivery to the notification step",
      async (action) => {
        jest.spyOn(ClaimsHandler, "createZohoTicket").mockResolvedValue("ticket");
        const send = jest.spyOn(ClaimsHandler, "sendNotifications").mockResolvedValue(undefined);
        await notify(action, true);
        expect(send.mock.calls[0][5]).toBe(true);
      },
    );

    it("still notifies the member when Desk fails, then fails a strict job", async () => {
      jest.spyOn(ClaimsHandler, "createZohoTicket").mockRejectedValue(new Error("desk down"));
      const send = jest.spyOn(ClaimsHandler, "sendNotifications").mockResolvedValue(undefined);
      await expect(notify(ClaimTicketActions.UPDATE_TICKET_AND_NOTIFY, true)).rejects.toThrow("desk down");
      expect(send).toHaveBeenCalledTimes(1);
    });

    it("keeps the legacy swallow of a Desk failure for direct callers", async () => {
      jest.spyOn(ClaimsHandler, "createZohoTicket").mockRejectedValue(new Error("desk down"));
      const send = jest.spyOn(ClaimsHandler, "sendNotifications").mockResolvedValue(undefined);
      await expect(notify(ClaimTicketActions.UPDATE_TICKET_AND_NOTIFY, false)).resolves.toBeUndefined();
      expect(send.mock.calls[0][5]).toBe(false);
    });
  });
});

describe("BX-4050 review follow-ups", () => {
  afterEach(() => jest.restoreAllMocks());

  describe("createClaim never resolves without a claim", () => {
    // A ValidationError with no field names took neither branch of the catch and
    // fell off the end, so the promise resolved `undefined` and the caller went
    // on as though a claim existed. inTransaction callback errors now surface
    // here too, so more callers can reach it.
    it("throws rather than resolving undefined when the error names no fields", async () => {
      const bare = new ValidationError({ type: "ModelValidation", message: "invalid", data: {} } as any);
      jest.spyOn(ClaimsHandler, "prepareClaimCreation").mockRejectedValue(bare);
      await expect(ClaimsHandler.createClaim({ id: "c1" } as any)).rejects.toThrow(/could not be saved/i);
    });

    it("still names the offending field when the error carries one", async () => {
      const withField = new ValidationError({
        type: "ModelValidation",
        message: "invalid",
        data: { policyId: [{ message: "bad" }] },
      } as any);
      jest.spyOn(ClaimsHandler, "prepareClaimCreation").mockRejectedValue(withField);
      await expect(ClaimsHandler.createClaim({ id: "c1" } as any)).rejects.toThrow(/Policy Id is Invalid/i);
    });

    it("re-throws anything that is not a validation failure untouched", async () => {
      jest.spyOn(ClaimsHandler, "prepareClaimCreation").mockRejectedValue(new Error("connection reset"));
      await expect(ClaimsHandler.createClaim({ id: "c1" } as any)).rejects.toThrow("connection reset");
    });
  });
});
