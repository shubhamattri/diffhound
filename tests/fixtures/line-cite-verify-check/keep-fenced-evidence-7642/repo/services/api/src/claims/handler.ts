import { toGlobalId } from "graphql-relay";
import { Knex } from "knex";
import { defaultsDeep, get, isEmpty, isEqual, isObject, startCase, toNumber, transform, upperFirst } from "lodash";
import moment from "moment-timezone";
import { ValidationError } from "objection";
import * as uuid from "uuid";
import { Context } from "../common/context";
import db from "../common/db";
import { CustomError } from "../common/errors";
import logger from "../common/logger";
import { claimTicketUpdateQueue, mailerQueue, slackQueue } from "../common/queues";
import { strictSlackDelivery } from "../common/slackDelivery";
import { CXPodMemberModel, CXPodMemberRoles } from "../CXEntities/CXPodMemberModel";
import { getAccountOwners, getPodMembers, updateCXPodMemberWithAgentId } from "../CXEntities/handler";
import { DependentModel } from "../dependent/model";
import { OrgModel } from "../models/org";
import { ClaimsNotification } from "../notifications/ClaimsNotification";
import { withClientSnapshot } from "../orgClient/handler";
import { getOrgPropertyByNameAndOrgId } from "../orgProperty/handler";
import { Optional } from "../tsTypes/common";
import { UserPriority } from "../tsTypes/enums";
import { ValidateType } from "../tsTypes/enums/misc";
import { OrgProperties } from "../tsTypes/enums/orgProperties";
import { UserPriority as ZohodeskUserPriority } from "../tsTypes/enums/zohodesk";
import { ICreateZohoTicket, IZohoClaimFields } from "../tsTypes/interfaces/zohoDesk";
import { INotificationHelperFields } from "../types/notification";
import { getUserById, userByIdDataLoader } from "../user/handlers/users";
import { UserModel } from "../user/model";
import * as UserContactsHandler from "../userContacts/handler";
import { claimContentByStatus, getClaimActionUrl, getClaimUpdateChannels, invalidateBalanceSiCache } from "../utils";
import {
  buildMessageForPriorityClaims,
  getClaimDocUpdateMessage,
  getClaimOwnerSlackId,
  getSlackIdsFromCXPodMember,
} from "../utils/claim";
import zohoDesk from "../utils/zohodesk";
import { fetchZohoDeskAgentIdByEmail } from "../zohoDesk/handler";
import { extractableAutoAttachedDocs } from "./autoAttachedDocs";
import { stripCompressionMeta } from "./claimDocumentUtils";
import { ClaimFilesHandler } from "./claimFiles/handler";
import { ClaimFilesModel } from "./claimFiles/model";
import { ClaimFileStatus } from "./claimFiles/tsTypes";
import { isBackfilledClaim, isClaimUnderQuery, setClaimSettledInNovaIfDelayed } from "./helpers";
import { missingMandatoryDocuments } from "./mandatoryDocuments";
import { ClaimModel, ClaimPreAuthModel } from "./models";
import {
  getAttemptCount,
  hasCsat,
  isEmailCsatEnabledForUser,
  MAX_EMAIL_ATTEMPTS,
  sendEmailCsat,
} from "./processors/emailCsatCollection";
import { isWhatsappCsatEnabledForUser, trackWhatsappCsatAttempt } from "./processors/whatsappCsatCollection";
import ClaimsQueryHandler from "./queries/handler";
import { TpaIntegrationType } from "./tpaIntegrations/base";
import {
  IBalanceSiHistory,
  ICalculateBalanceSiAndHistoryResponse,
  IClaim,
  IClaimMeta,
  IClaimNotificationConfig,
  IClaimPreAuth,
  MessageType,
} from "./tsTypes/claim";
import stagesToUpdateLastDocReceivedDate from "./tsTypes/constants/stagesToUpdateLastDocReceivedDate";
import { ClaimCategory } from "./tsTypes/enums/claimCategory";
import { ClaimDocument } from "./tsTypes/enums/claimDocument";
import { ClaimFormType } from "./tsTypes/enums/claimFormType";
import { ClaimSlackChannels } from "./tsTypes/enums/claimSlackChannels";
import { ClaimSource } from "./tsTypes/enums/claimSource";
import { ClaimReminderStage, ClaimStage } from "./tsTypes/enums/claimStage";
import { ClaimStatus } from "./tsTypes/enums/claimStatus";
import { ClaimTicketActions } from "./tsTypes/enums/claimTicketActions";
import { ClaimType } from "./tsTypes/enums/claimType";
import { FlowType } from "./tsTypes/enums/flowType";
import { Status } from "./tsTypes/enums/status";
import { slackChannelMappings } from "./tsTypes/maps/slackChannelToFlowType";
import { claimStageToClaimStatus } from "./tsTypes/maps/stageToClaimStatus";
import { claimStageToStatus } from "./tsTypes/maps/stageToStatus";

export default class ClaimsHandler {
  /** `inTransaction` runs in the insert's transaction, so intent recorded there commits or fails with the claim. */
  static async createClaim(
    claimObj: IClaim,
    ctx?: Context,
    inTransaction?: (trx: Knex.Transaction, claim: IClaim) => Promise<void>,
  ): Promise<IClaim> {
    try {
      const prepared = await ClaimsHandler.prepareClaimCreation(claimObj, ctx);
      const newClaim = inTransaction
        ? await db.transaction(async (trx) => {
            const inserted = await ClaimsHandler.persistPreparedClaim(prepared, trx);
            await inTransaction(trx, inserted);
            return inserted;
          })
        : await ClaimsHandler.persistPreparedClaim(prepared);
      ClaimsHandler.dispatchPreparedClaimEffects(prepared, newClaim, ctx);
      return newClaim;
    } catch (err) {
      if (err instanceof ValidationError) {
        const invalidProperties = Object.keys(err.data);
        if (invalidProperties.length) {
          throw new CustomError(`${startCase(invalidProperties[0])} is Invalid!`);
        }
        // A ValidationError carrying no field names still means the claim was
        // not written. Falling through here resolved `undefined`, and the caller
        // went on as though it had a claim. Now that an inTransaction callback's
        // error also surfaces as this, that path is reachable from more callers.
        throw new CustomError("This claim could not be saved. Please check the details and try again.");
      }
      throw err;
    }
  }

  /** Prepare existing domain defaults and document reuse without writing a claim. */
  static async prepareClaimCreation(claimObj: IClaim, ctx?: Context) {
    const newId = uuid.v4();
    const filteredPolicies = await db
      .table("user_benefits")
      .where({ user_id: claimObj.user_id, benefit_id: claimObj.policy_id });

    if (filteredPolicies.length === 0) {
      throw new CustomError("Sorry! That Policy is not linked with the account");
    }

    // Ensure meta and crm exist before reading/writing nested properties.
    // Validation should normally guarantee this, but guard defensively for minimal payloads.
    claimObj.meta = claimObj.meta || ({} as IClaimMeta);
    claimObj.meta.crm = claimObj.meta.crm || {};

    const claimNumber = claimObj.meta.claimNumber;
    if (claimNumber && (await this.claimWithClaimNumberExists(claimNumber))) {
      const duplicateClaim = await this.getClaimByClaimNumber(claimNumber);
      throw new CustomError(`Duplicate claim number, present in NB${duplicateClaim.nb_number}`);
    }

    // Check for getOrAddDataLoader method to ensure ctx is a valid Context instance
    // (not a stripped-down object from Bull queue serialization)
    const user = ctx?.getOrAddDataLoader
      ? await userByIdDataLoader(ctx).load(claimObj.user_id)
      : await getUserById(claimObj.user_id);
    if (user?.meta?.priority === UserPriority.HIGH) {
      claimObj.meta.highPriority = true;
    }
    claimObj.meta = withClientSnapshot(claimObj.meta, user?.meta, "AtIntimation") as IClaimMeta;
    const ff = await getOrgPropertyByNameAndOrgId("FEATURE_FLAGS", user.org_id, user?.org_entity_id);
    const userSources = [ClaimSource.PORTAL_USER, ClaimSource.PORTAL_SUPER_ADMIN];
    const shouldCheckForMandatoryDocs =
      ff?.meta?.MANDATORY_CLAIM_DOCS_FLOW &&
      claimObj.type === ClaimType.REIMBURSEMENT &&
      userSources.includes(claimObj.create_source);
    const isOpdClaim = claimObj?.meta?.formType === ClaimFormType.OPD;
    if (
      shouldCheckForMandatoryDocs &&
      (!claimObj.files ||
        (claimObj.files &&
          ClaimsHandler.checkMissingMandatoryDocs(claimObj.files, { incomingClaim: claimObj }, ff?.meta).length))
    ) {
      claimObj.meta.crm.claimStage = ClaimStage.MANDATORY_DOCUMENTS_PENDING;
      claimObj.meta.crm.claimStatus = claimStageToClaimStatus.get(
        ClaimStage.MANDATORY_DOCUMENTS_PENDING,
      ) as ClaimStatus;
      claimObj.status = claimStageToStatus.get(ClaimStage.MANDATORY_DOCUMENTS_PENDING) as Status;
    }

    const claimStage = claimObj.meta?.crm?.claimStage || ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE;
    const claimStatus = claimStageToClaimStatus.get(claimStage) as ClaimStatus;

    // Ensure claimIntimationByEmployee is stamped whenever stage is CLAIM_INTIMATION_BY_EMPLOYEE.
    // Do not overwrite an explicit value coming from the client.
    if (claimStage === ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE) {
      if (!claimObj.meta.crm.timeline) {
        claimObj.meta.crm.timeline = {};
      }

      if (!claimObj.meta.crm.timeline.claimIntimationByEmployee) {
        claimObj.meta.crm.timeline.claimIntimationByEmployee = moment().tz("UTC").format();
      }
    }

    if (claimObj.files) delete claimObj.files;
    delete claimObj?.meta?.notesAttachment;

    const userId = claimObj.user_id;

    const shouldAutoAttach = ff?.meta?.ENABLE_AUTO_ATTACHING_PREVIOUS_CLAIM_DOCS;
    const { newDocs, claim_form_a } = shouldAutoAttach
      ? await ClaimsHandler.getDocsForAutoAttaching(userId, newId, claimObj?.dependent_id)
      : { newDocs: [], claim_form_a: {} };

    // Map split hospitalization expenses from meta → claim_form_a for Form A autofill
    ClaimsHandler.mapMetaExpensesToFormA(claimObj.meta as IClaimMeta, claim_form_a);

    // Set claimSettledInNova if claim is being created directly as settled (e.g., via TPA dump)
    // Pass null as existingClaim since this is a new claim
    setClaimSettledInNovaIfDelayed(null, claimObj as IClaim);

    if (claimStage === ClaimStage.CLAIM_SETTLED || claimStage === ClaimStage.APPROVED) {
      logger
        .event("NEW_CLAIM_CREATED_AS_SETTLED")
        .data({ claimId: newId, claimStage, claimType: claimObj.type })
        .info("New claim created directly in settled/approved state");
    }

    const newClaimObj = {
      id: newId,
      ...claimObj,
      status: claimObj.status || claimStageToStatus.get(claimStage) || Status.CLAIM_INTIMATED,
      meta: {
        ...claimObj.meta,
        lastDraftReminderDate: claimObj.status === Status.DRAFT ? moment().format() : null,
        crm: {
          ...claimObj.meta?.crm,
          claimStatus,
          claimStage,
        },
      },
      claim_form_a,
    };

    return { newId, newClaimObj, newDocs, shouldAutoAttach, ff };
  }

  /** Claim and reused document rows use the caller's transaction when supplied. */
  static async persistPreparedClaim(
    prepared: Awaited<ReturnType<typeof ClaimsHandler.prepareClaimCreation>>,
    trx?: Knex.Transaction,
  ): Promise<IClaim> {
    const newClaim = await ClaimModel.query(trx).insert(prepared.newClaimObj).returning("*");
    if (prepared.shouldAutoAttach && prepared.newDocs.length > 0)
      await ClaimFilesModel.query(trx).insert(prepared.newDocs).returning("*");
    return newClaim;
  }

  /** Legacy callers dispatch immediately; Claro records durable follow-ups instead. */
  static dispatchPreparedClaimEffects(
    prepared: Awaited<ReturnType<typeof ClaimsHandler.prepareClaimCreation>>,
    newClaim: IClaim,
    ctx?: Context,
  ): void {
    const { newId } = prepared;
    // Trigger MagicFill extraction for auto-attached docs if data is missing
    const extractionJobs = extractableAutoAttachedDocs(prepared).map((docType) =>
      ClaimFilesHandler.smartExtractAndStore(newId, docType)
        .then(() => {
          logger
            .event("autoAttach_magicFillTriggered")
            .data({ claimId: newId, docType })
            .info("Triggered MagicFill for auto-attached document");
        })
        .catch((error: any) => {
          logger
            .event("autoAttach_magicFillError")
            .data({ claimId: newId, docType, error: error.message })
            .error("MagicFill extraction failed for auto-attached document");
        }),
    );

    if (extractionJobs.length > 0) {
      Promise.allSettled(extractionJobs).then(() => {
        logger
          .event("autoAttach_magicFillBackgroundComplete")
          .data({ claimId: newId })
          .info("Background MagicFill for auto-attached docs finished");
      });
    }

    if (newClaim.meta?.highPriority) {
      ClaimsHandler.sendHighPriorityClaimSlackAlert(newClaim, ctx);
    }
  }

  static async getExistingDocsForDependent(userId: string, dependentId: string, docTypes: ClaimDocument[]) {
    try {
      // Find the most recent settled/approved claim for this specific dependent
      const settledClaimQuery = ClaimModel.query()
        .where("user_id", userId)
        .where("dependent_id", dependentId)
        .whereNot("status", ClaimStatus.INVALID)
        .whereRaw(
          `meta->'crm'->>'claimStage' in ('${ClaimStage.CLAIM_SETTLED}', '${ClaimStage.CLAIM_APPROVED_BY_TPA}')`,
        )
        .orderBy("created_at", "desc")
        .select(["id"])
        .limit(1)
        .then((res) => res[0]);

      const anyClaimQuery = ClaimModel.query()
        .where("user_id", userId)
        .where("dependent_id", dependentId)
        .whereNotIn("status", [ClaimStatus.INVALID, ClaimStatus.DRAFT])
        .andWhere("type", ClaimType.REIMBURSEMENT)
        .orderBy("updated_at", "desc")
        .select(["id"])
        .limit(1)
        .then((res) => res[0]);

      const [settledClaim, anyClaim] = await Promise.all([settledClaimQuery, anyClaimQuery]);
      const claimToFetchDocsFrom = settledClaim || anyClaim;

      if (!claimToFetchDocsFrom) {
        logger.event("getExistingDocsForDependent").info(`No suitable claim found for dependent ${dependentId}`);
        return [];
      }

      // Reuse only ACTIVE files — the processed PDF that supersedes the original upload once
      // image-merge/compression runs. An inactive original points at an archived (moved) S3 key.
      const existingDocs = await ClaimFilesModel.query()
        .where("claim_id", claimToFetchDocsFrom.id)
        .where("status", ClaimFileStatus.ACTIVE)
        .whereIn("doc_type", docTypes)
        .orderBy("created_at", "desc")
        .select("*");

      return ClaimsHandler.dedupeByDocType(existingDocs);
    } catch (error) {
      logger
        .event("getExistingDocsForDependent")
        .error(`Error occurred while getting existing docs for dependent ${dependentId}`);
      logger.event("getExistingDocsForDependent").error(error);
      return [];
    }
  }

  static async updateClaim(
    claimObj: IClaim,
    ctx?: Context,
    source?: string,
    trx?: Knex.Transaction,
  ): Promise<IClaim> {
    // Capture caller intent before defaultsDeep can fill update_source from the DB record.
    const effectiveSource = source ?? claimObj.update_source;

    // Read on the caller's transaction, not a pooled connection: outside it this
    // cannot see the transaction's own uncommitted writes, and defaultsDeep then
    // fills the update from a stale row.
    const claim: IClaim = await ClaimModel.query(trx).findById(claimObj.id!).select("*");

    if (!claim) {
      throw new CustomError(`Cannot find the claim # ${claimObj.id}.`);
    }

    delete claim.meta?.contact;
    delete claimObj.meta?.contact;
    if (claimObj.files) delete claimObj.files;
    delete claimObj?.meta?.notesAttachment;

    if (claimObj.meta?.crm?.claimStatus === ClaimStatus.INVALID) {
      claimObj.meta.claimNumber = "";
    }

    // Check for getOrAddDataLoader method to ensure ctx is a valid Context instance
    // (not a stripped-down object from Bull queue serialization)
    const user = ctx?.getOrAddDataLoader
      ? await userByIdDataLoader(ctx).load(claimObj.user_id)
      : await getUserById(claimObj.user_id);
    if (user?.meta?.priority === UserPriority.HIGH) {
      claimObj.meta.highPriority = true;
    }

    const claimNumber = claimObj.meta?.claimNumber;
    if (claimNumber && (await this.claimWithClaimNumberExists(claimNumber, claim.id))) {
      const duplicateClaim = await this.getClaimByClaimNumber(claimNumber, claim.id!);
      throw new CustomError(`Duplicate claim number, present in NB${duplicateClaim.nb_number}`);
    }

    if (claimObj.meta && claimObj.meta.crm) {
      /** Only an admin/cli job can update claim status.
       * !ctx = internal automated caller (processor/tool/queue — no HTTP context)
       * ctx.isAutomatedChange = explicit automated flag set by callers that have a ctx but no user (e.g. CLI bulk upload)
       * ctx.user?.isAdmin = authenticated admin via HTTP
       */
      if ((ctx && ctx.user?.isAdmin) || !ctx || ctx?.isAutomatedChange) {
        claimObj.status = claimStageToStatus.get(claimObj.meta.crm.claimStage) as Status;
      } else {
        claimObj.status = claim.status;
        claimObj.meta.crm.claimStage = claim.meta.crm.claimStage;
        claimObj.meta.crm.claimStatus = claim.meta.crm.claimStatus;
      }
    }
    if (ctx && !ctx.user?.isAdmin) {
      claimObj.claim_owner = claim.claim_owner;
    }

    /** Need to reset files to incoming claim object bec we can't really merge file array.
     * If we merge, the deleted files from FE will get reset since they'll be present in the old claim obj.
     * Ref: https://playcode.io/1635467
     */
    claimObj = defaultsDeep({}, claimObj, claim);
    claimObj.meta = withClientSnapshot(claimObj.meta || {}, user?.meta, "AtIntimation") as IClaimMeta;

    // Ensure claimIntimationByEmployee is set whenever the final stage is CLAIM_INTIMATION_BY_EMPLOYEE.
    // Three cases: payload has value → defaultsDeep already preserved it (skip);
    // payload cleared it (null) → restore DB value via existingIntimation;
    // neither has a value → backfill with "now".
    const finalStage = claimObj.meta?.crm?.claimStage;
    if (finalStage === ClaimStage.CLAIM_INTIMATION_BY_EMPLOYEE) {
      const existingIntimation = claim.meta?.crm?.timeline?.claimIntimationByEmployee;

      if (!claimObj.meta.crm.timeline) {
        claimObj.meta.crm.timeline = {};
      }

      if (!claimObj.meta.crm.timeline.claimIntimationByEmployee) {
        claimObj.meta.crm.timeline.claimIntimationByEmployee = existingIntimation || moment().tz("UTC").format();
      }
    }

    // Set claimSettledInNova if there's a delay in receiving the status update from TPA
    setClaimSettledInNovaIfDelayed(claim, claimObj);

    // Do not update the claim if anything new isn't provided
    let hasNewUpdates = false;
    let updateFields = [
      "meta",
      "status",
      "dependent_id",
      "type",
      "csat",
      "claim_owner",
      "user_contact_id",
      "update_source",
    ];

    /** A portal user can only update meta or user_contact_id.
     * A super admin editing/uploading docs as portal user should also be limited to do the same.
     *
     * Third branch covers all headless callers (automated or not) processing a portal-sourced
     * claim. isAutomatedChange only unlocks status updates (guard above); it must not bypass
     * field restrictions — portal source means restricted fields regardless of automation flag.
     */
    if (
      (ctx && ctx.user && !ctx.user.isAdmin) ||
      (ctx?.user?.isAdmin && effectiveSource === ClaimSource.PORTAL_USER) ||
      (ctx && !ctx.user && effectiveSource === ClaimSource.PORTAL_USER)
    ) {
      updateFields = ["meta", "user_contact_id"];
    }

    for (const field of updateFields) {
      const original = claim[field];
      const incoming = claimObj[field];

      // Normalize undefined to null to avoid JSON.parse(undefined) throwing
      const originalNormalized = original === undefined ? null : JSON.parse(JSON.stringify(original));
      const incomingNormalized = incoming === undefined ? null : JSON.parse(JSON.stringify(incoming));

      if (!isEqual(originalNormalized, incomingNormalized)) {
        hasNewUpdates = true;
      }
    }
    if (!claimObj.meta.claimFilesUpdated && !hasNewUpdates) {
      /** Discussion with Ira: Shouldn't show an error message to portal user saying nothing new to update.
       * Should give positive feedback.
       *
       * Silent return only applies to authenticated portal contexts (ctx.user must be present).
       * Headless callers (ctx.user null) intentionally fall through to the throw — they are
       * automated tools that should surface errors, not silently succeed.
       */
      if (ctx && ctx.user && (!ctx.user.isAdmin || effectiveSource === ClaimSource.PORTAL_USER)) {
        logger.info("Nothing new provided by portal user for claim: ", claim.id);
        return claim;
      } else {
        throw new CustomError(`Nothing new provided to update claim`);
      }
    }

    /** If a claim stage is not under query, it should be safe to assume that all queries have been resolved. */
    try {
      const claimStage = claimObj.meta?.crm?.claimStage;
      if (!isClaimUnderQuery(claimStage) && this.canCloseQueryForClaimStage(claimStage)) {
        await ClaimsQueryHandler.closeAllQueriesByClaimId(claim.id);
        logger.info(`Closed all queries for claim: ${claim.id} with stage: ${claimObj.meta?.crm?.claimStage}`);
      }
    } catch (err) {
      logger.error("Error while closing all claim queries", err);
    }

    const { id, ...historyObject } = claim;
    historyObject.claim_id = id;
    delete historyObject.claim_form_a;
    const newId = uuid.v4();
    await (trx ?? db).table("claims_history").insert({
      id: newId,
      ...historyObject,
    });

    let updatedClaim;
    try {
      if (claimObj.meta.files) delete claimObj.meta.files;
      if (claimObj.files) delete claimObj.files;
      // we don't want to save this
      delete claimObj?.meta?.claimFilesUpdated;
      delete claimObj?.meta?.reSubmittedAt;

      // Sync split hospitalization expenses from meta → claim_form_a for Form A autofill
      if (claimObj.meta) {
        claimObj.claim_form_a = claimObj.claim_form_a || {};
        ClaimsHandler.mapMetaExpensesToFormA(claimObj.meta as IClaimMeta, claimObj.claim_form_a);
      }

      updatedClaim = await ClaimModel.query(trx)
        .findById(id)
        .patch({ ...claimObj })
        .returning("*");
    } catch (err) {
      if (err instanceof ValidationError) {
        const invalidProperties = Object.keys(err.data);
        if (invalidProperties.length) {
          throw new CustomError(`${startCase(invalidProperties[0])} is Invalid!`);
        }
      }
      throw err;
    }
    // Inside a caller's transaction the cache may only be cleared once the write is
    // visible. A failure here leaves a stale balance / sum insured behind, which
    // surfaces later as a member being quoted the wrong number - so it is logged
    // rather than swallowed. Still non-fatal: the write itself has committed.
    const invalidate = () =>
      invalidateBalanceSiCache(claimObj.user_id, claimObj.policy_id).catch((error: Error) =>
        logger.error(
          `Balance/SI cache invalidation failed for claim ${claimObj.id}: ${error?.name || "Error"}`,
        ),
      );
    if (trx) void trx.executionPromise.then(invalidate).catch(() => invalidate());
    else await invalidate();
    return updatedClaim;
  }

  static async claimWithClaimNumberExists(claimNumber: string, exludeId?: string): Promise<boolean> {
    const query = ClaimModel.query().whereRaw("meta->>'claimNumber' =?", claimNumber);
    if (exludeId) {
      query.whereNot("id", exludeId);
    }
    const claim = await query.select("id").first();
    return !!claim;
  }

  static async getClaimByNbNumber(nbNumber: string): Promise<IClaim> {
    const claim = await ClaimModel.query().where("nb_number", nbNumber).select("*").first();
    return claim;
  }

  static async getClaimByClaimNumber(claimNumber: string, excludeId?: string): Promise<IClaim> {
    const query = db("claims").select("*").whereRaw("meta->>'claimNumber' = ?", [claimNumber]);
    if (excludeId) {
      query.andWhere("id", "!=", excludeId);
    }
    return await query.first();
  }

  /**
   * Resolve an existing claim by its ICICI per-event family key (BX-3681). Matches a row that
   * either already stores this rootClaimNumber, or whose claimNumber IS the root (the base
   * cashless member persisted before the family key was introduced) — so every sibling of one
   * hospitalization event converges on a single claim row instead of inserting duplicates.
   */
  static async getClaimByRootClaimNumber(rootClaimNumber: string): Promise<IClaim> {
    return await db("claims")
      .select("*")
      .whereRaw("meta->>'rootClaimNumber' = ? OR meta->>'claimNumber' = ?", [rootClaimNumber, rootClaimNumber])
      .first();
  }

  /**
   * Resolve the parent (main) claim for a pre/post child by its master claim number.
   *
   * `masterClaimNumber` stores the parent's FULL, exact `claimNumber` (the TPA-assigned
   * number, including any trailing `.{slno}` / `/{slno}` extension). Because `claimNumber`
   * is globally unique (idx_unique_claim_number), an exact match resolves exactly one row:
   * the parent. A pre/post child carries its own distinct `claimNumber` (e.g. parent
   * `…124.1`, child `…124.9`), so it can never collide with its parent here. The suffix is
   * stripped only at TPA boundaries that require the base CCN — never at storage or lookup.
   *
   * Scoped to `userId` so a parent that belongs to another claimant is not resolved.
   *
   * @param masterClaimNumber the parent's full `claimNumber`
   * @param userId claimant the parent must belong to
   */
  static async getParentClaimByMasterClaimNumber(masterClaimNumber: string, userId: string): Promise<IClaim> {
    return ClaimModel.query()
      .where("user_id", userId)
      .whereRaw("meta->>'claimNumber' = ?", [masterClaimNumber])
      .first() as unknown as IClaim;
  }

  static async updateDocsUpdatedAfterDormantStatus(claim: any) {
    if (claim.meta?.claimFilesUpdated && claim.status === Status.DORMANT) {
      return ClaimModel.query().patch({ "meta:claimUpdatedAfterDormant": true }).where({ id: claim.id });
    } else if (claim.meta.claimUpdatedAfterDormant) {
      return ClaimModel.query().patch({ "meta:claimUpdatedAfterDormant": false }).where({ id: claim.id });
    }
  }

  static async updateLastDocReceivedAtIfUnderQuery(claim: IClaim) {
    // skip update if docs are uploaded when stage is one of the above and finalDocReceivedByTpa is already set by tpa
    if (
      !(
        stagesToUpdateLastDocReceivedDate.includes(claim.meta.crm?.claimStage) &&
        claim.meta.crm?.timeline?.finalDocReceivedByTpa
      )
    )
      return;
    this.updateMetaByKeyString(claim.id, "crm.timeline.finalDocReceivedByTpa", moment().toISOString());
  }

  /** TODO: @sanath - this has potential to be a common util. */
  static async updateMetaByKeyString(claimId: string, keyString: string, value: any): Promise<ClaimModel> {
    const metaPath = `meta:${keyString}`;
    return ClaimModel.query().patchAndFetchById(claimId, { [metaPath]: value });
  }

  static async updateMetaByKeyMap(claimId: string, keyValueMap: Record<string, any>): Promise<ClaimModel> {
    const patchData: Record<string, any> = {};
    Object.entries(keyValueMap).forEach(([key, value]) => {
      patchData[`meta:${key}`] = value;
    });
    return ClaimModel.query().patchAndFetchById(claimId, patchData);
  }

  static async syncQueryCountMeta(claimId: string, tatExtensionDaysPerQuery: number): Promise<void> {
    await ClaimModel.query()
      .patch({
        meta: ClaimModel.raw(
          `COALESCE(meta, '{}'::jsonb) || jsonb_build_object(
            'queryCount', (SELECT count(*) FROM queries WHERE claim_id = ?),
            'tatExtensionDays', (SELECT count(*) FROM queries WHERE claim_id = ?) * ?
          )`,
          [claimId, claimId, tatExtensionDaysPerQuery],
        ),
      })
      .where("id", claimId);
  }

  /** TODO: @sanath - move pre-auth to it's own entity. */
  static async createClaimPreAuth(data: Partial<IClaimPreAuth>): Promise<ClaimPreAuthModel> {
    try {
      const newId = uuid.v4();
      const claimPreAuth: ClaimPreAuthModel = await ClaimPreAuthModel.query()
        .insert({ id: newId, ...data })
        .returning("*");
      return claimPreAuth;
    } catch (error) {
      throw new CustomError(`Error while creating a new pre auth claim:  ${error}`);
    }
  }

  static async updateClaimPreAuth(id: string, data: Partial<IClaimPreAuth>): Promise<ClaimPreAuthModel> {
    try {
      const claimPreAuth = await ClaimPreAuthModel.query()
        .findById(id)
        .patch({ ...data })
        .returning("*");
      return claimPreAuth[0];
    } catch (error) {
      throw new CustomError(`Error while updating exisiting pre auth claim:  ${error}`);
    }
  }

  static async upsertClaimPreAuth(id: string | null, data: Partial<IClaimPreAuth>): Promise<ClaimPreAuthModel> {
    let claimPreAuth: ClaimPreAuthModel;
    const ctx = new Context();
    const result = await ClaimPreAuthModel.validate(ctx, id ? ValidateType.Update : ValidateType.Create, data);
    if (id && Object.keys(result).length) {
      claimPreAuth = await this.updateClaimPreAuth(id, result);
    } else {
      claimPreAuth = await this.createClaimPreAuth(result);
    }
    return claimPreAuth;
  }

  static async sendNotifications(
    config: IClaimNotificationConfig,
    claim: any,
    updatedFields?: string[],
    helperFields?: INotificationHelperFields,
    ctx?: Context,
    strictDelivery = false,
  ) {
    // Suppress all notifications (not just stage-change) for backfilled claims — if the claim
    // settled 30+ days ago, no notification about it is relevant to the user anymore
    if (isBackfilledClaim(claim)) {
      logger
        .event("BACKFILL_NOTIFICATION_SUPPRESSED")
        .data({ claimId: claim.id, claimStage: claim.meta?.crm?.claimStage })
        .info(`Suppressed notifications for backfilled claim`);
      return;
    }

    const channels = getClaimUpdateChannels(config);
    let notification;
    if (channels.length > 0) {
      logger.info(`Sending claim notifications for claim id: ${claim.id}, with identified channels ${channels}`);
      try {
        const claimNotification = new ClaimsNotification(
          claim, channels, updatedFields, helperFields?.reminder, ctx, strictDelivery,
        );
        notification = await claimNotification.setup();
      } catch (e) {
        logger.error(`Error setting up claim notification: ${e}`);
        if (strictDelivery) throw e;
      }
    } else {
      logger.info(`No claim notification channels found for claim id: ${claim.id}`);
    }

    // Send immediate email CSAT if claim is settled
    if (updatedFields?.includes("meta.crm.claimStage") && claim.meta?.crm?.claimStage === ClaimStage.CLAIM_SETTLED) {
      await this.sendEmailCsatIfNeeded(claim, ctx);
    }

    // Track instant WhatsApp CSAT if claim is settled or approved and WhatsApp notification was sent
    if (
      updatedFields?.includes("meta.crm.claimStage") &&
      (claim.meta?.crm?.claimStage === ClaimStage.CLAIM_SETTLED || claim.meta?.crm?.claimStage === ClaimStage.APPROVED)
    ) {
      await this.trackInstantWhatsappCsat(claim, config, ctx);
    }
    return notification;
  }

  /**
   * Track instant WhatsApp CSAT when claim is settled or approved
   * This happens when WhatsApp notification includes CSAT template
   */
  static async trackInstantWhatsappCsat(
    claim: ClaimModel,
    config: IClaimNotificationConfig,
    ctx?: Context,
  ): Promise<void> {
    try {
      // Only track if WhatsApp notifications are enabled
      if (!config.shouldSendWhatsAppUpdate) {
        return;
      }

      // Check for getOrAddDataLoader method to ensure ctx is a valid Context instance
      const user =
        claim.user ||
        (ctx?.getOrAddDataLoader
          ? await userByIdDataLoader(ctx).load(claim.user_id)
          : await UserModel.query().findById(claim.user_id));
      if (!user?.org_id) {
        return;
      }

      // Check if WhatsApp CSAT is enabled for this org
      const isEnabled = await isWhatsappCsatEnabledForUser(user);
      if (!isEnabled) {
        logger
          .event("WHATSAPP_CSAT_COLLECTION")
          .info(`Skipping WhatsApp CSAT tracking for claim ${claim.id}: Feature disabled for org ${user.org_id}`);
        return;
      }

      // Get the instant template name (csatTemplateTitle)
      const orgProperty = await getOrgPropertyByNameAndOrgId(
        "CLAIMS_WHATSAPP_CSAT_TEMPLATE",
        user.org_id,
        user?.org_entity_id,
      );
      const instantTemplate = orgProperty?.meta?.csatTemplateTitle || "claims_csat_form_link_v1";

      const whatsappAttempts = claim.csat?.meta?.whatsappCsatAttempts;
      const hasExistingInstantAttempt = Array.isArray(whatsappAttempts)
        ? whatsappAttempts.some((attempt: any) => {
            const isCurrentInstant = attempt?.attemptNumber === 0;
            const isLegacyInstant =
              attempt?.attemptNumber === 1 &&
              typeof attempt?.templateUsed === "string" &&
              attempt.templateUsed.includes("claims_csat_form_link");
            // Gate on status: a failed attempt should not block a retry.
            // Legacy records with no status field are treated as sent.
            const isSent = attempt?.status === "sent" || attempt?.status === undefined;
            return (isCurrentInstant || isLegacyInstant) && isSent;
          })
        : false;

      if (hasExistingInstantAttempt) {
        logger
          .event("WHATSAPP_CSAT_COLLECTION")
          .info(`Skipping instant WhatsApp CSAT tracking for claim ${claim.id}: instant attempt already present`);
        return;
      }

      // Track instant CSAT as attempt 0. Reminder eligibility has a compat shim for legacy attemptNumber=1 records.
      await trackWhatsappCsatAttempt(claim.id, 0, instantTemplate, "sent");

      logger
        .event("WHATSAPP_CSAT_COLLECTION")
        .info(`Instant WhatsApp CSAT tracked for claim ${claim.id} with template ${instantTemplate}`);
    } catch (error) {
      logger
        .event("WHATSAPP_CSAT_COLLECTION")
        .data({ claimId: claim.id, error })
        .error(`Failed to track instant WhatsApp CSAT for claim ${claim.id}`, error);
    }
  }

  /**
   * Send immediate email CSAT when claim is settled
   * Checks if CSAT already exists or if Tally response was received before 10 AM
   */
  static async sendEmailCsatIfNeeded(claim: ClaimModel, ctx?: Context): Promise<void> {
    try {
      // Check if CSAT already exists
      if (hasCsat(claim)) {
        logger.event("EMAIL_CSAT_COLLECTION").info(`Skipping email CSAT for claim ${claim.id}: CSAT already exists`);
        return;
      }

      // Check if email CSAT was already stopped
      if (claim.csat?.meta?.emailCsatStoppedAt) {
        logger
          .event("EMAIL_CSAT_COLLECTION")
          .info(`Skipping email CSAT for claim ${claim.id}: Email sequence already stopped`);
        return;
      }

      // Check if csat response was received before 10 AM today
      const now = moment().tz("Asia/Kolkata");
      const today10AM = now.clone().startOf("day").hour(10).minute(0).second(0);
      const csatDate = claim.csat?.date ? moment(claim.csat.date).tz("Asia/Kolkata") : null;

      // If CSAT was received today before 10 AM, skip email
      if (csatDate && csatDate.isBefore(today10AM) && csatDate.isSame(now, "day")) {
        logger
          .event("EMAIL_CSAT_COLLECTION")
          .info(`Skipping email CSAT for claim ${claim.id}: CSAT response received before 10 AM today`);
        return;
      }

      // Check attempt count
      const attemptCount = getAttemptCount(claim);

      if (attemptCount >= MAX_EMAIL_ATTEMPTS) {
        logger
          .event("EMAIL_CSAT_COLLECTION")
          .info(`Skipping email CSAT for claim ${claim.id}: Max attempts (${MAX_EMAIL_ATTEMPTS}) reached`);
        return;
      }

      // Check if scheduled email CSAT is enabled
      // If enabled, skip immediate emails (use scheduled system instead)
      const user =
        claim.user ||
        (ctx ? await userByIdDataLoader(ctx).load(claim.user_id) : await UserModel.query().findById(claim.user_id));
      if (!user?.org_id) {
        logger.event("EMAIL_CSAT_COLLECTION").info(`Skipping email CSAT for claim ${claim.id}: User has no org_id`);
        return;
      }

      const isScheduledEmailEnabled = await isEmailCsatEnabledForUser(user);
      if (isScheduledEmailEnabled) {
        logger
          .event("EMAIL_CSAT_COLLECTION")
          .info(
            `Skipping immediate email CSAT for claim ${claim.id}: Scheduled email CSAT enabled (using new scheduled system)`,
          );
        return;
      }

      // Call the email CSAT processor function
      const freshClaim = await ClaimModel.query().findById(claim.id);
      if (!freshClaim) {
        logger.event("EMAIL_CSAT_COLLECTION").warn(`Skipping email CSAT for claim ${claim.id}: Claim not found`);
        return;
      }
      // For immediate emails (fallback)
      await sendEmailCsat(freshClaim);

      logger.event("EMAIL_CSAT_COLLECTION").info(`Immediate email CSAT sent for claim ${claim.id}`);
    } catch (error) {
      logger
        .event("EMAIL_CSAT_COLLECTION")
        .data({ claimId: claim.id, error })
        .error(`Failed to send immediate email CSAT for claim ${claim.id}`, error);

      // Send error notification to Slack
      try {
        const timestampIST = moment().tz("Asia/Kolkata").format("YYYY-MM-DD HH:mm:ss");
        const errorMessage = error instanceof Error ? error.message : String(error);
        const errorStack = error instanceof Error ? error.stack : undefined;

        const slackMessage =
          `@here 🚨 **Immediate Email CSAT Sending Failed**\n\n` +
          `**Timestamp (IST):** ${timestampIST}\n` +
          `**Claim ID:** ${claim.id}\n` +
          `**NB Number:** ${claim.nb_number || "N/A"}\n` +
          `**Error:**\n\`\`\`${errorMessage}\`\`\`\n` +
          (errorStack ? `**Stack Trace:**\n\`\`\`${errorStack}\`\`\`\n` : "");

        const slackChannel = process.env.EMAIL_CSAT_ERROR_CHANNEL;
        await slackQueue.add({
          message: slackMessage,
          channel: slackChannel,
        });

        logger
          .event("EMAIL_CSAT_COLLECTION")
          .info(`Slack error notification sent for immediate email CSAT error on claim ${claim.id}`);
      } catch (slackError) {
        logger
          .event("EMAIL_CSAT_COLLECTION")
          .data({ claimId: claim.id, slackError })
          .error(`Failed to send Slack notification for immediate email CSAT error on claim ${claim.id}`, slackError);
      }
    }
  }

  static async sendStatusUpdatesToMail(claim: any, ctx?: Context) {
    const context = ctx || new Context();
    const globalClaimId = toGlobalId("Claim", claim.id);
    const user = await userByIdDataLoader(context).load(claim.user_id);
    const detailsUrl = `${process.env.APP_ORIGIN}/user/claims/claim-details/${globalClaimId}`;
    const claimContent = claimContentByStatus(claim.status);
    const template = "confirmAction.pug";
    const topText = `Hi ${user.name},`;
    const middleText = claimContent.subheading
      ? `${claimContent.subheading}<br /><br />${claimContent.content}`
      : `${claimContent.content}`;
    const bottomText = `The Nova Benefits Team`;
    const mailContext = {
      user,
      claim,
    };

    await mailerQueue.add({
      toEmail: user.email,
      mailContext,
      topText,
      bottomText,
      buttonUrl: detailsUrl,
      buttonText: "View Claim Details",
      subject: claimContent.heading,
      middleTextRaw2: middleText,
      textBody: `${topText}\n\n${detailsUrl}\n\n${bottomText}`,
      template,
    });
  }

  static async sendDocumentUpdates(claim: IClaim, files: any, ctx?: Context) {
    const message = await getClaimDocUpdateMessage(files, claim);
    // Check for getOrAddDataLoader method to ensure ctx is a valid Context instance
    const user = ctx?.getOrAddDataLoader
      ? await userByIdDataLoader(ctx).load(claim.user_id)
      : await UserModel.query().findById(claim.user_id);
    const userPriority = user.meta.priority;
    await this.updateLastDocReceivedAtIfUnderQuery(claim);
    await this.sendDocumentUpdatesToSlack(message, userPriority!);
    return true;
  }

  static async sendDocumentUpdatesToSlack(message: string, priority: string) {
    if (priority === UserPriority.HIGH) {
      await slackQueue.add({ message, channel: ClaimSlackChannels.VIP_NOTIFICATIONS });
    } else {
      await slackQueue.add({ message, channel: ClaimSlackChannels.GENERAL_NOTIFICATIONS });
    }
  }

  static async getNotificationConfigForClaimByUserId(
    userId: string,
    claim: any,
    ctx?: Context,
  ): Promise<IClaimNotificationConfig> {
    // Check for getOrAddDataLoader method to ensure ctx is a valid Context instance
    const user = ctx?.getOrAddDataLoader
      ? await userByIdDataLoader(ctx).load(userId)
      : await UserModel.query().findById(userId);
    const claimantOrgId = user?.org_id;
    const claimantOrgProperty = await getOrgPropertyByNameAndOrgId("FEATURE_FLAGS", claimantOrgId, user?.org_entity_id);
    const globalOrgProperty = await getOrgPropertyByNameAndOrgId("FEATURE_FLAGS", null);
    let userContact = null;
    if (claim.user_contact_id) {
      userContact = await UserContactsHandler.getUserContactById(claim.user_contact_id);
    }

    const shouldSendWhatsAppUpdate = globalOrgProperty.meta?.CLAIMS_WHATSAPP && userContact?.consent?.whatsappConsent;
    const shouldSendClaimsNotification = !claimantOrgProperty.meta?.DISABLE_CLAIM_NOTIFICATIONS;
    const shouldUseZohoDeskEmail = !!globalOrgProperty.meta?.CLAIMS_ZOHO_DESK;

    const notificationConfig: IClaimNotificationConfig = {
      shouldSendWhatsAppUpdate: shouldSendClaimsNotification ? shouldSendWhatsAppUpdate : false,
      shouldUseZohoDeskEmail: shouldSendClaimsNotification ? shouldUseZohoDeskEmail : false,
    };

    return notificationConfig;
  }

  static async updateClaimUserContact(
    userId: string,
    contactNumber: string,
    consent?: Record<string, unknown>,
    trx?: Knex.Transaction,
    onContactChanged?: (event: Record<string, unknown>) => void,
  ) {
    let matchingContact = await UserContactsHandler.getUserContactByUserIdAndPhoneNumber(userId, contactNumber, trx);

    if (matchingContact) {
      if (consent) {
        matchingContact = await UserContactsHandler.updateConsentById(matchingContact.id, consent, trx);
      }

      return matchingContact;
    } else {
      const [isSomeoneElsesPrimary, usersPrimaryContact] = await Promise.all([
        UserContactsHandler.getContactByNumberAndPrimary(contactNumber, true, userId, trx),
        UserContactsHandler.getPrimaryUserContactByUserId(userId, trx),
      ]);
      const isPrimary = !isSomeoneElsesPrimary && !usersPrimaryContact;
      const newUserContact = await UserContactsHandler.createOrUpdateContact(
        {
          userId: userId,
          phoneNumber: contactNumber,
          primary: isPrimary, // if there is no primary contact, then this contact will be primary
          createSource: "claims",
          consent: consent || {},
        },
        trx,
        onContactChanged,
      );

      return newUserContact;
    }
  }

  static canCloseQueryForClaimStage(stage: ClaimStage) {
    return ![
      ClaimStage.QUERY_RESPONDED_BY_EMPLOYEE,
      ClaimStage.QUERY_DOCS_UNDER_VERIFICATION,
      ClaimStage.QUERY_DOCS_UNDER_VERIFICATION_2,
    ].includes(stage);
  }

  static async createZohoTicket(claim: ClaimModel, user: UserModel, assigneeId?: string): Promise<string> {
    const [dependent, org, zohodeskConfig] = await Promise.all([
      claim.dependent_id ? DependentModel.query().findById(claim.dependent_id) : null,
      user.org_id ? OrgModel.query().findById(user.org_id) : null,
      user.org_id
        ? getOrgPropertyByNameAndOrgId(OrgProperties.ZOHODESK_CONFIG, user.org_id, user?.org_entity_id)
        : null,
    ]);

    const patientName = isEmpty(dependent) ? user.name : dependent.name;
    const subject = `${claim.type ? upperFirst(claim.type) : ""} Claim created for ${patientName} | NB:${
      claim.nb_number
    }`;
    let description = `
      UserName: ${user.name}\n
      UserEmail: ${user.email}\n
      UserContactNumber: ${user.meta.contactNumber}\n
      ClaimType: ${claim.type ? upperFirst(claim.type) : "Unknown"}\n
      PortalClaimUrl: ${process.env.APP_ORIGIN}/admin/claimsV2/${toGlobalId("Claim", claim.id)}\n
    `;
    description += `PatientName: ${patientName}`;
    try {
      const claimFields: IZohoClaimFields = {
        cf_user_id: user.id,
        // cf_org_id contract: this platform-org UUID is a RESOLUTION SEED. The Zoho Desk stamp
        // function resolves it via CRM Account.Portal_ID and replaces it with the numeric CRM
        // account id; consumers treat a non-numeric value as "unresolved". Do NOT remove this
        // write — it is the only deterministic CRM-resolution key for portal tickets (BX-3829).
        cf_org_id: org?.id as string,
        cf_employee_id: user.meta.employeeId as string,
        cf_claim_number: claim.meta.claimNumber || "",
        cf_org_name: org?.name as string,
        cf_primary_insured: user.name,
        // Auto-created claim notifications must not climb the One Queue escalation ladder: the
        // Desk-side SLA scanner freezes tickets flagged "Action not required" (BX-3829). Agents
        // clear the flag if a real conversation starts on the ticket.
        cf_flagged: "Action not required",
      };
      const payload: ICreateZohoTicket<IZohoClaimFields> = {
        subject,
        contact: {
          lastName: user.name,
          email: user.email,
        },
        description,
        departmentId: zohodeskConfig?.meta?.departmentId || process.env.ZOHO_DESK_CLAIMS_DEPARTMENT_ID,
        channel: claim.create_source,
        priority: user.meta.priority === UserPriority.HIGH ? ZohodeskUserPriority.HIGH : ZohodeskUserPriority.MEDIUM,
        cf: claimFields,
        assigneeId,
      };
      const response = await zohoDesk.createZohoDeskTicket(payload);
      const zohoTicket = response.data.id;
      // update meta field in claim with key zohoDeskTicketId
      await ClaimModel.query().patchAndFetchById(claim.id, {
        "meta:zohoDeskTicketId": zohoTicket,
      });

      return zohoTicket;
    } catch (err) {
      throw new CustomError(err);
    }
  }

  static async updateZohoTicket(claim: ClaimModel): Promise<void> {
    try {
      const payload = {
        cf: {
          cf_claim_number: claim.meta.claimNumber,
        },
      };
      await zohoDesk.updateZohoDeskTicket(claim.meta.zohoDeskTicketId, payload);
    } catch (err) {
      throw new CustomError(err);
    }
  }

  static async getClaimantContact(userContactId: string): Promise<Optional<string>> {
    if (!userContactId) throw "Unable to fetch claimant's phone number, UserContactId cannot be empty!";
    const userContact = await UserContactsHandler.getUserContactById(userContactId);
    return userContact?.phoneNumber;
  }

  static async fetchStakeholdersForPriorityClaim(
    orgId: string,
    accountOwnersRoles: CXPodMemberRoles[],
    claimLeadsRoles: CXPodMemberRoles[],
  ): Promise<CXPodMemberModel[]> {
    try {
      const [accountOwners, claimLeads] = await Promise.all([
        getAccountOwners(orgId, accountOwnersRoles),
        getPodMembers("Claims Team Leads", claimLeadsRoles),
      ]);

      return [...accountOwners, ...claimLeads];
    } catch (err) {
      logger.error("Error while fetching stakeholders for priority claim", err);
    }
  }

  static async sendHighPriorityClaimSlackAlert(
    claim: IClaim | ClaimModel,
    ctx?: Context,
    strictDelivery = false,
    jobId?: string,
  ) {
    const accountOwnersToFetch = [CXPodMemberRoles.CA, CXPodMemberRoles.RM, CXPodMemberRoles.KAM];
    const leadershipRolesToFetch = [CXPodMemberRoles.CXHead];

    try {
      /** TODO: @sanath - stop using singleton context class. */
      // Check for getOrAddDataLoader method to ensure ctx is a valid Context instance
      // (not a stripped-down object from Bull queue serialization)
      const context = ctx?.getOrAddDataLoader ? ctx : new Context();
      const user = await userByIdDataLoader(context).load(claim.user_id);
      const orgName = (await OrgModel.query().findById(user.org_id))?.name;
      const claimantContact = await this.getClaimantContact(claim.user_contact_id);
      if (!user.org_id) {
        throw new Error("Constraint error: org_id not found for user in claimModel.afterInsert");
      }

      const stakeholdersForPriorityClaim = await this.fetchStakeholdersForPriorityClaim(
        user.org_id,
        accountOwnersToFetch,
        leadershipRolesToFetch,
      );
      const slackIds: { [role: string]: string } = getSlackIdsFromCXPodMember(stakeholdersForPriorityClaim);
      logger.info(`Fetched Slack IDs of all stakeHolders for claim(nb_number: ${claim.nb_number}):`, slackIds);
      const patient = claim.dependent_id ? await context.dependentByIdWithDeleted.load(claim.dependent_id) : user;
      const messageParams = {
        claimId: claim.id,
        slackIds,
        typeOfClaim: claim.type,
        nbNumber: claim.nb_number,
        claimantName: patient.name,
        relation: patient?.relation ? patient?.relation : "Self",
        claimantContact,
        primaryInsured: {
          name: user.name,
          email: user.email,
          orgName,
        },
      };
      const message = buildMessageForPriorityClaims(messageParams);
      logger.info(`Sending following high priority claim message(nb_number: ${claim.nb_number}) to slack:`, message);
      const payload = { message, channel: ClaimSlackChannels.HIGH_PRIORITY_CLAIMS };
      if (jobId) await slackQueue.add({ ...payload, strictDelivery: true }, strictSlackDelivery(jobId));
      else await slackQueue.add(payload);
    } catch (err) {
      logger.error(`Error while sending the priority claim message(nb_number: ${claim.nb_number})`, err);
      if (strictDelivery) throw err;
    }
  }

  /**
   * returns claims by tpaId and claimStatuses
   * @param tpaId
   * @param select
   * @default claimStatuses [ClaimStatus.ONGOING, ClaimStatus.REOPENED]
   * @returns claims
   */
  static async getClaimsByTpaIdAndClaimStatus(
    tpaId: string,
    claimStatuses: ClaimStatus[] = [ClaimStatus.ONGOING, ClaimStatus.REOPENED],
    select: string | string[] = "*",
  ): Promise<ClaimModel[] | Record<string, any>> {
    const statusString = `${claimStatuses.join("','")}`; // this is fine because claimStatus is not user input
    const query = ClaimModel.query()
      .innerJoin("benefits", "benefits.id", "=", "claims.policy_id")
      .innerJoin("tpas", "tpas.id", "=", "benefits.tpa_id")
      .andWhereRaw(db.raw("tpas.id in (?)", [tpaId]))
      .andWhereRaw(db.raw(`claims.meta->'crm'->>'claimStatus' in ('${statusString}')`))
      .select(select);
    return query;
  }

  static getSlackEmoji(type: MessageType): string {
    return type === "success" ? ":white_check_mark:" : ":x:";
  }

  static addMessagesToSlackQueue = async (errors: any, channel: any): Promise<void> => {
    try {
      await slackQueue.add({ message: errors, channel });
    } catch (err) {
      console.log("err", err);
    }
  };

  static async formatSlackMessages(type: MessageType, messages: any) {
    return messages[type].map((msg: string) => this.getSlackEmoji(type) + msg + "\n").join("\n");
  }

  static async getSlackMessageHeaders(tpa: TpaIntegrationType, claim: any, hasDocUploadApi: boolean) {
    const claimUrl = getClaimActionUrl(claim.id, true);
    const nBNumberHyperlink = `<${claimUrl}|NB#${claim.nb_number}>`;
    return {
      [FlowType.Intimation]: {
        [MessageType.Success]: `[${tpa}] Claim ${nBNumberHyperlink} intimated successfully! at ${moment()
          .tz("Asia/Kolkata")
          .format("h:mm A, Do MMM, YYYY")} :white_check_mark: \n${
          claim.meta.claimIntimationNumber ? `Claim Reference Number: ${claim.meta.claimIntimationNumber} \n` : ""
        }`,
        [MessageType.Error]: `[${tpa}] Claim Intimation ${
          !hasDocUploadApi ? "and Doc Upload" : ""
        } failed for ${nBNumberHyperlink} :x: \nErrors:\n`,
      },
      [FlowType.DocUpload]: {
        [MessageType.Success]: `[${tpa}] Docs Uploaded for Claim ${nBNumberHyperlink} successfully! :white_check_mark:\n`,
        [MessageType.Error]: `[${tpa}] Doc Upload failed for ${nBNumberHyperlink} :x: \nErrors:\n`,
      },
      [FlowType.QueryReceived]: {
        [MessageType.Success]: `[${tpa}] Query Docs fetched from TPA for ${nBNumberHyperlink} :question:\n`,
      },
      [FlowType.QueryRespondedClaimant]: {
        [MessageType.Success]: `Claimant responded against query raised by TPA for ${nBNumberHyperlink}\n`,
      },
      [FlowType.QueryRespondedCA]: {
        [MessageType.Success]: `[${tpa}] Claims Owner responded successfully to query raised by TPA for ${nBNumberHyperlink}\n`,
        [MessageType.Error]: `[${tpa}] Claims Owner’s response to query raised by TPA failed for ${nBNumberHyperlink}\n`,
      },
    };
  }
  static async sendMessagesToSlack(
    type: MessageType,
    flowType: FlowType,
    tpa: any,
    claim: any,
    messages: { success: string[]; error: string[] },
    hasDocUploadApi?: boolean,
  ) {
    try {
      let message = ``;
      const claimOwnerSlackId = claim.claim_owner ? await getClaimOwnerSlackId(claim.claim_owner) : null;
      message = claimOwnerSlackId ? `<@${claimOwnerSlackId}> ` : `No CA/slackId assigned to this claim\n`;
      const messageHeaders = await this.getSlackMessageHeaders(tpa, claim, hasDocUploadApi);

      //Adds the header to the message based 'type'
      message += messageHeaders[flowType][type];

      //Adds the error/success messages
      const successMessages = await this.formatSlackMessages(MessageType.Success, messages);
      const errorMessages = await this.formatSlackMessages(MessageType.Error, messages);

      // In case of Error Messages, Order messages by error then success
      message += (type === MessageType.Error ? errorMessages : "") + successMessages;
      const channel = slackChannelMappings.get(flowType);
      logger.info("Sending following message to Slack.\n", message);
      await this.addMessagesToSlackQueue(message, channel);
      return { success: [], error: [] };
    } catch (e) {
      logger.log(e);
    }
  }
  static async getClaimById(id: string): Promise<IClaim> {
    try {
      return await ClaimModel.query().findById(id).returning("*");
    } catch (err) {
      logger.data({ err }).error(`Error fetching claims data in getClaimById()! ${err}`);
      throw err;
    }
  }

  static async getClaimByUserOrDependentId(userId: string, dependentId: string): Promise<ClaimModel> {
    let claim: ClaimModel | null = null;
    const commonQuery = ClaimModel.query()
      .whereRaw("claims.meta->'crm'->>'claimStatus' = ?", ClaimStatus.COMPLETED)
      .orderBy("created_at", "desc");
    claim = await commonQuery.where("dependent_id", dependentId).first();
    if (!claim) {
      claim = await commonQuery.where("user_id", userId).first();
    }
    return claim || null;
  }
  static checkMissingMandatoryDocs(
    files: any[],
    claimObjs: {
      incomingClaim: IClaim;
      existingClaim?: IClaim;
    },
    featureFlags: Record<string, any>,
  ): ClaimDocument[] {
    return missingMandatoryDocuments(files, claimObjs.incomingClaim, claimObjs.existingClaim, featureFlags);
  }

  static async getClaimsForDraftReminder(): Promise<ClaimModel[]> {
    return ClaimModel.query()
      .whereRaw("claims.meta->'crm'->>'claimStage' = ?", ClaimStage.MANDATORY_DOCUMENTS_PENDING)
      .andWhere("created_at", ">", moment().subtract(30, "days").format())
      .andWhereRaw("(claims.meta->>'lastDraftReminderDate')::TIMESTAMP < ?", moment().subtract(3, "days").format())
      .orderBy("created_at", "desc")
      .returning("*");
  }

  static async updateLastDraftReminderDate(): Promise<void> {
    const claims = await this.getClaimsForDraftReminder();
    const claimIds = claims.map((claim) => claim.id);
    const currentDateTime = moment().format();
    if (claimIds.length) {
      try {
        await ClaimModel.query()
          .whereIn("id", claimIds)
          .patch({
            meta: ClaimModel.raw(`jsonb_set(meta, '{lastDraftReminderDate}', to_jsonb(?::text))`, [currentDateTime]),
          });
      } catch (err) {
        console.log(err);
      }
    }
  }

  static async sendDraftReminder(claim: ClaimModel, ctx?: Context): Promise<void> {
    logger.event("sendDraftReminder");
    const notificationConfig = await this.getNotificationConfigForClaimByUserId(claim.user_id, claim, ctx);
    const shouldNotify = ClaimsHandler.shouldNotifyViaNotificationConfig(notificationConfig);
    if (shouldNotify) {
      await claimTicketUpdateQueue.add({
        claim,
        userId: claim.user_id,
        notificationConfig,
        action: ClaimTicketActions.UPDATE_TICKET_AND_NOTIFY,
        updatedFields: [],
        helperFields: {
          reminder: { stage: ClaimReminderStage.DRAFT_REMINDER_1 },
        },
      });
    }
  }

  static async getClaimsForBalanceSI(userId: string, policyId: string) {
    return ClaimModel.query()
      .where({ user_id: userId, policy_id: policyId })
      .andWhereRaw("claims.meta->'crm'->>'claimStatus' = ?", ClaimStatus.COMPLETED)
      .orderByRaw(
        `CASE WHEN claims.type = '${ClaimType.CASHLESS}' THEN claims.meta->>'dod' ELSE claims.meta->'crm'->'timeline'->>'claimSettled' END DESC`,
      );
  }

  static calculateBalanceSiAndHistory(
    claims: ClaimModel[],
    totalSi: number,
    withHistory: boolean,
  ): ICalculateBalanceSiAndHistoryResponse {
    let balanceSi = totalSi;
    const history: IBalanceSiHistory[] = [];

    for (const claim of claims) {
      const claimAmount = toNumber(claim.meta?.approvedAmount || 0);
      balanceSi -= claimAmount;

      if (withHistory) {
        const dateOfCompletion =
          claim.type === ClaimType.CASHLESS ? claim.meta?.dod : claim.meta?.crm?.timeline?.claimSettled;
        history.push({
          nbNumber: claim.nb_number,
          dateOfCompletion: moment(dateOfCompletion).format("DD/MM/YYYY"),
          approvedAmount: claimAmount,
          balance: balanceSi,
        });
      }
    }

    return { totalSi, balanceSi, history };
  }

  /**
   * Map split hospitalization expenses from claim meta to claim_form_a structure
   * used for generating Form A.
   *
   * Rules:
   * - Always prefer explicit split fields: preHospitalizationExpense, hospitalizationExpense, postHospitalizationExpense.
   * - Only treat estimatedClaimAmount as "main hospitalization" fallback for pure main claims
   *   (no pre/post selected or main=true with pre/post not selected).
   */
  private static mapMetaExpensesToFormA(meta: IClaimMeta, formA: any): void {
    if (!meta || !formA) return;

    const preHosp = typeof meta.preHospitalizationExpense === "number" ? meta.preHospitalizationExpense : null;
    const mainHosp = typeof meta.hospitalizationExpense === "number" ? meta.hospitalizationExpense : null;
    const postHosp = typeof meta.postHospitalizationExpense === "number" ? meta.postHospitalizationExpense : null;
    const selection = meta.prePostSelection || {};

    const isPureMainClaim =
      (selection.pre === undefined && selection.post === undefined && selection.main === undefined) ||
      (selection.main === true && selection.pre !== true && selection.post !== true);

    if (preHosp != null && !Number.isNaN(preHosp) && formA.preHospitalizationExpense == null) {
      formA.preHospitalizationExpense = preHosp;
    }
    if (mainHosp != null && !Number.isNaN(mainHosp) && formA.hospitalizationExpense == null) {
      formA.hospitalizationExpense = mainHosp;
    }
    if (postHosp != null && !Number.isNaN(postHosp) && formA.postHospitalizationExpense == null) {
      formA.postHospitalizationExpense = postHosp;
    }

    // Fallback: only for pure main claims, when explicit main hospitalization is missing
    if (
      isPureMainClaim &&
      (mainHosp == null || Number.isNaN(mainHosp)) &&
      formA.hospitalizationExpense == null &&
      typeof meta.estimatedClaimAmount === "number"
    ) {
      formA.hospitalizationExpense = meta.estimatedClaimAmount;
    }
  }
  static async fetchAndStoreZohoDeskAgentId(email: string, accountOwner: CXPodMemberModel): Promise<string> {
    let agentInfo;
    const exceptionEmails = ["raunak@nova-benefits.com", "rajan@nova-benefits.com"];
    const updatedEmail = exceptionEmails.includes(email) ? email.replace("@", "-zoho@") : email;
    try {
      if (!email) {
        throw new CustomError("Claim Owner's Email not found: ", updatedEmail);
      }
      agentInfo = await fetchZohoDeskAgentIdByEmail(updatedEmail);
      if (!agentInfo.isSuccess) {
        logger.info(`AgentId for email(${updatedEmail}) not found\nAgentId: '${agentInfo.agentId}'`);
        return "";
      }
      logger.info(`AgentId Received for email(${updatedEmail}):`, agentInfo);
    } catch (err) {
      throw new CustomError(`Something went wrong while fetching agentId for email: ${updatedEmail}`, err);
    }

    await updateCXPodMemberWithAgentId(accountOwner, agentInfo.agentId);
    return agentInfo.agentId;
  }

  static async getAgentIdFromDbOrFetchIt(claimOwnerUserId: string): Promise<string> {
    try {
      const claimOwnerPodMember = await CXPodMemberModel.getByUserId(claimOwnerUserId, CXPodMemberRoles.CA);

      if (!claimOwnerPodMember) {
        logger.info(`Account owner (CA) for id(${claimOwnerUserId}) not found.`);
        return undefined;
      }

      if (claimOwnerPodMember.meta?.zohoDeskAgentId) {
        logger.info(`ZohoDeskAgentId already present in DB: ${claimOwnerPodMember?.meta?.zohoDeskAgentId}`);
        return claimOwnerPodMember?.meta?.zohoDeskAgentId;
      }
      logger.info(`ZohoDeskAgentId not present in DB, fetching...`);
      const claimOwner = await UserModel.query().findById(claimOwnerPodMember.userId).select("email");

      if (!claimOwner.email) {
        throw new CustomError("Claim Owner's email not found!");
      }
      const agentId = await this.fetchAndStoreZohoDeskAgentId(claimOwner.email, claimOwnerPodMember);
      return agentId;
    } catch (err) {
      logger.error(err);
      throw new CustomError(err);
    }
  }
  static getUpdatedFields(obj1: Object, obj2: Object) {
    return transform(obj1, (result, value, key) => {
      if (!isEqual(value, obj2[key])) {
        result[key] = isObject(value) && isObject(obj2[key]) ? this.getUpdatedFields(value, obj2[key]) : value;
      }
    });
  }
  static checkUpdatedFields(changedFields: any) {
    const checkFields = ["meta.note", "meta.crm.claimStage", "meta.claimNumber"];
    const matchingFields = [];
    for (const field of checkFields) {
      if (get(changedFields, field)) {
        matchingFields.push(field);
      }
    }
    return matchingFields;
  }
  static async handleClaimTicketUpdates(
    action: ClaimTicketActions,
    claim: ClaimModel,
    notificationConfig: any,
    updatedFields: string[],
    helperFields: INotificationHelperFields,
    user: any,
    agentId?: any,
    ctx?: Context,
    strictDelivery = false,
  ): Promise<void> {
    try {
      let zohoTicket;
      switch (action) {
        case ClaimTicketActions.CREATE_TICKET:
          zohoTicket = await this.createZohoTicket(claim, user, agentId);
          logger
            .event(ClaimTicketActions.CREATE_TICKET)
            .info(`Ticket doesn't exist for claim id: ${claim.id}, created a new one: ${zohoTicket}`);
          logger
            .event(ClaimTicketActions.CREATE_TICKET)
            .info(
              `Decided to NOT send notification for claim id: ${claim.id}, claim stage: ${claim.meta?.crm?.claimStage}, action: ${action}`,
            );
          break;

        case ClaimTicketActions.CREATE_TICKET_AND_NOTIFY:
          zohoTicket = await ClaimsHandler.createZohoTicket(claim, user, agentId);
          claim.meta.zohoDeskTicketId = zohoTicket;
          logger
            .event(ClaimTicketActions.CREATE_TICKET_AND_NOTIFY)
            .info(`Ticket doesn't exist for claim id: ${claim.id}, created a new one: ${zohoTicket}`);
          await this.sendNotifications(notificationConfig, claim, updatedFields, helperFields, ctx, strictDelivery);
          logger
            .event(ClaimTicketActions.CREATE_TICKET_AND_NOTIFY)
            .info(`Decided to send notification for claim id: ${claim.id}`);
          break;

        case ClaimTicketActions.UPDATE_TICKET:
          if (!claim.meta.zohoDeskTicketId) {
            zohoTicket = await ClaimsHandler.createZohoTicket(claim, user, agentId);
            claim.meta.zohoDeskTicketId = zohoTicket;
            logger
              .event(ClaimTicketActions.UPDATE_TICKET)
              .info(`Ticket doesn't exist for claim id: ${claim.id}, created a new one: ${zohoTicket}`);
          }
          logger.event(ClaimTicketActions.UPDATE_TICKET).info(`Running updateZohoTicket for claim id: ${claim.id}`);
          if (updatedFields.includes("meta.claimNumber")) {
            await this.updateZohoTicket(claim);
          }
          logger
            .event(ClaimTicketActions.UPDATE_TICKET)
            .info(
              `Decided to NOT send notification for claim id: ${claim.id}, claim stage: ${claim.meta?.crm?.claimStage}, action: ${action}`,
            );
          break;

        case ClaimTicketActions.UPDATE_TICKET_AND_NOTIFY: {
          let deskError: unknown;
          try {
            if (!claim.meta.zohoDeskTicketId) {
              zohoTicket = await ClaimsHandler.createZohoTicket(claim, user, agentId);
              claim.meta.zohoDeskTicketId = zohoTicket;
              logger
                .event(ClaimTicketActions.UPDATE_TICKET_AND_NOTIFY)
                .info(`Ticket doesn't exist for claim id: ${claim.id}, created a new one: ${zohoTicket}`);
            }
            logger
              .event(ClaimTicketActions.UPDATE_TICKET_AND_NOTIFY)
              .info(`Running updateZohoTicket for claim id: ${claim.id}`);
            if (updatedFields.includes("meta.claimNumber")) {
              await this.updateZohoTicket(claim);
            }
          } catch (zohoError: any) {
            deskError = zohoError;
            logger
              .event(ClaimTicketActions.UPDATE_TICKET_AND_NOTIFY)
              .error(
                `Zoho Desk error for claim id: ${claim.id}, continuing with notifications: ${
                  zohoError?.message || zohoError
                }`,
              );
          }
          await this.sendNotifications(notificationConfig, claim, updatedFields, helperFields, ctx, strictDelivery);
          logger
            .event(ClaimTicketActions.UPDATE_TICKET_AND_NOTIFY)
            .info(`Decided to send notification for claim id: ${claim.id}`);
          // The member is still notified; a strict job then fails so the missing ticket is visible.
          if (strictDelivery && deskError) throw deskError;
          break;
        }

        default:
          throw new Error(`Unknown action type: ${action}`);
      }
    } catch (error) {
      logger.event("handleClaimTicketUpdates").error(`An error occurred: ${error}`);
      if (strictDelivery) throw error;
    }
  }
  static shouldNotifyViaNotificationConfig(notificationConfig: IClaimNotificationConfig) {
    return notificationConfig.shouldSendWhatsAppUpdate || notificationConfig.shouldUseZohoDeskEmail;
  }

  // Keep only the first (newest, when the query is ordered created_at desc) file per doc type.
  // Callers auto-attach one document per type; a type appearing twice would attach it twice.
  private static dedupeByDocType<T extends { docType: string }>(docs: T[]): T[] {
    const seen = new Set<string>();
    return docs.filter((doc) => {
      if (seen.has(doc.docType)) return false;
      seen.add(doc.docType);
      return true;
    });
  }

  static async getExistingDocs(userId: string, docTypes: ClaimDocument[], parentClaimNumber?: string) {
    try {
      let claimToFetchDocsFrom;

      // If parentClaimNumber is provided, look up that specific claim
      if (parentClaimNumber) {
        claimToFetchDocsFrom = await ClaimModel.query()
          .where("user_id", userId)
          .whereRaw("meta->>'claimNumber' = ?", [parentClaimNumber])
          .select(["claim_form_a", "id"])
          .first();

        if (!claimToFetchDocsFrom) {
          throw new Error(`Parent claim with claimNumber ${parentClaimNumber} not found`);
        }
      } else {
        // Existing logic: find most recent settled claim
        const settledClaimQuery = ClaimModel.query()
          .where("user_id", userId)
          .whereNot("status", ClaimStatus.INVALID)
          .whereRaw(
            `meta->'crm'->>'claimStage' in ('${ClaimStage.CLAIM_SETTLED}', '${ClaimStage.CLAIM_APPROVED_BY_TPA}')`,
          )
          .orderBy("created_at", "desc")
          .select(["claim_form_a", "id"])
          .limit(1)
          .then((res) => res[0]);

        const anyClaimQuery = ClaimModel.query()
          .where("user_id", userId)
          .whereNotIn("status", [ClaimStatus.INVALID, ClaimStatus.DRAFT])
          .andWhere("type", ClaimType.REIMBURSEMENT)
          .orderBy("updated_at", "desc")
          .select(["id", "claim_form_a"])
          .limit(1)
          .then((res) => res[0]);
        const [settledClaim, anyClaim] = await Promise.all([settledClaimQuery, anyClaimQuery]);

        claimToFetchDocsFrom = settledClaim || anyClaim;
        if (!claimToFetchDocsFrom) throw new Error("No suitable claim found for autoattaching docs");
      }

      // If docTypes is null/empty and parentClaimNumber is provided, fetch all documents.
      // Only reuse ACTIVE claim files: image-merge/compression supersede the original upload by
      // marking it inactive and leaving the processed PDF active. Reusing an inactive original would
      // point the new claim at an S3 object that archiving has already moved out from under that key.
      const existingDocsQuery = ClaimFilesModel.query()
        .where("claim_id", claimToFetchDocsFrom.id)
        .where("status", ClaimFileStatus.ACTIVE)
        .orderBy("created_at", "desc");

      if (docTypes && docTypes.length > 0) {
        existingDocsQuery.whereIn("doc_type", docTypes);
      }

      const existingDocs = ClaimsHandler.dedupeByDocType(await existingDocsQuery.select("*"));

      return {
        existingClaimFormA: claimToFetchDocsFrom.claim_form_a,
        existingDocs,
      };
    } catch (error) {
      logger.event("getExistingDocs").error(`Error occurred while getting existing docs for userId ${userId}`);
      logger.event("getExistingDocs").error(error);
      return {
        existingClaimFormA: {},
        existingDocs: [],
      };
    }
  }
  static async getDocsForAutoAttaching(
    userId: string,
    newClaimId: string,
    dependentId?: string,
    parentClaimNumber?: string,
  ) {
    // Always use the default primary doc types (auto-attach only copies basic KYC docs)
    const primaryDocTypes = [ClaimDocument.AADHAAR_PRIMARY, ClaimDocument.PAN_PRIMARY, ClaimDocument.CANCELLED_CHEQUE];

    const { existingDocs, existingClaimFormA } =
      (await this.getExistingDocs(userId, primaryDocTypes, parentClaimNumber)) || [];
    const claim_form_a = {};
    let newDocs = [];
    let primaryAadhaarFileId = null;

    newDocs = existingDocs.map((doc) => {
      if (doc.docType === ClaimDocument.PAN_PRIMARY) {
        claim_form_a.panNumber = existingClaimFormA.panNumber;
      } else if (doc.docType === ClaimDocument.CANCELLED_CHEQUE) {
        claim_form_a.accountNumber = existingClaimFormA.accountNumber;
        claim_form_a.ifscCode = existingClaimFormA.ifscCode;
        claim_form_a.bankNameAndBranch = existingClaimFormA.bankNameAndBranch;
      } else if (doc.docType === ClaimDocument.AADHAAR_PRIMARY) {
        // Store the primary Aadhaar file ID for potential reuse
        primaryAadhaarFileId = doc.fileId;
        claim_form_a.primaryInsuredAddress1 = existingClaimFormA.primaryInsuredAddress1;
        claim_form_a.primaryInsuredAddress2 = existingClaimFormA.primaryInsuredAddress2;
        claim_form_a.primaryInsuredCity = existingClaimFormA.primaryInsuredCity;
        claim_form_a.primaryInsuredState = existingClaimFormA.primaryInsuredState;
        claim_form_a.primaryInsuredPincode = existingClaimFormA.primaryInsuredPincode;
      }
      return {
        file_id: doc.fileId,
        doc_type: doc.docType,
        is_uploaded: false,
        meta: stripCompressionMeta(doc.meta),
        create_source: ClaimSource.AUTO_ATTACH,
        status: ClaimFileStatus.ACTIVE,
        claim_id: newClaimId,
      };
    });

    // Handle AADHAAR_PATIENT based on whether patient is employee or dependent
    if (dependentId) {
      // Patient is a dependent - fetch dependent's Aadhar from previous claims
      const dependentDocs = await this.getExistingDocsForDependent(userId, dependentId, [
        ClaimDocument.AADHAAR_PATIENT,
      ]);

      let dependentClaimFormA = {};
      if (dependentDocs.length > 0) {
        const dependentClaimId = dependentDocs[0].claimId;
        const dependentClaim = await ClaimModel.query().findById(dependentClaimId).select("claim_form_a");
        dependentClaimFormA = dependentClaim?.claim_form_a || {};
      }

      const dependentNewDocs = dependentDocs.map((doc) => {
        if (doc.docType === ClaimDocument.AADHAAR_PATIENT) {
          claim_form_a.patientAddress1 = dependentClaimFormA.patientAddress1;
          claim_form_a.patientAddress2 = dependentClaimFormA.patientAddress2;
          claim_form_a.patientCity = dependentClaimFormA.patientCity;
          claim_form_a.patientState = dependentClaimFormA.patientState;
          claim_form_a.patientPincode = dependentClaimFormA.patientPincode;
        }

        return {
          file_id: doc.fileId,
          doc_type: doc.docType,
          is_uploaded: false,
          meta: stripCompressionMeta(doc.meta),
          create_source: ClaimSource.AUTO_ATTACH,
          status: ClaimFileStatus.ACTIVE,
          claim_id: newClaimId,
        };
      });

      newDocs = [...newDocs, ...dependentNewDocs];

      if (dependentNewDocs.length > 0) {
        logger
          .event("getDocsForAutoAttaching")
          .info(`Auto-attached ${dependentNewDocs.length} dependent document(s) for dependent ${dependentId}`);
      }
    } else if (!dependentId && primaryAadhaarFileId) {
      // Patient is the employee (self) - use primary Aadhaar as patient Aadhaar
      newDocs.push({
        file_id: primaryAadhaarFileId,
        doc_type: ClaimDocument.AADHAAR_PATIENT,
        is_uploaded: false,
        meta: {},
        create_source: ClaimSource.AUTO_ATTACH,
        status: ClaimFileStatus.ACTIVE,
        claim_id: newClaimId,
      });
      logger.event("getDocsForAutoAttaching").info(`Auto-attached primary Aadhaar as patient Aadhaar for self claim`);
    }

    return { newDocs, claim_form_a };
  }

  static async isUsersClaim(claimId: string, userId: string) {
    const userClaim = await ClaimModel.query()
      .where({
        user_id: userId,
        id: claimId,
      })
      .first();
    return Boolean(userClaim);
  }

  static isDisallowClaimsPast30days(data: ClaimModel, isDisallowClaimsPast30DEnabled: boolean): boolean {
    if (!isDisallowClaimsPast30DEnabled) {
      return false;
    }

    const meta: any = data.meta || {};

    // For pure pre/post hospitalization claims (no main hospitalization selected),
    // we should *not* apply the generic "30 days from discharge" intimation rule.
    // Instead, these claims are governed by the configurable pre/post window
    // validated in `validatePrePostHospitalizationWindow`, which already reads
    // the PRE_POST_HOSPITALIZATION_WINDOW_DAYS org property (defaults 30/60/90).
    const selection = meta.prePostSelection || {};
    const isPurePrePost = (selection.pre || selection.post) && !selection.main;

    if (isPurePrePost) {
      return false;
    }

    const isReimbursementClaim = data.type === ClaimType.REIMBURSEMENT;
    const isOpd = meta.formType === ClaimFormType.OPD;
    const dod = isOpd ? moment(meta.hospitalization?.endDate) : moment(meta.dod);
    const isDodOlderThan30Days = dod && moment().diff(dod, "days") > 30;

    return (isReimbursementClaim || isOpd) && isDodOlderThan30Days;
  }

  /**
   * Validate pre/post hospitalization windows against parent claim's hospitalization dates.
   *
   * Anchor on parent claim's DOA/DOD (main hospitalization), not settlement date.
   *
   * Business rules (for pre/post without main):
   * - Pre: hospitalization start date should be within N days BEFORE parent DOA
   *        (i.e. startDate ∈ [DOA - N days, DOA)), where N defaults to 30 days.
   * - Post: hospitalization end date should be within M days AFTER parent DOD
   *         (i.e. endDate ∈ [DOD, DOD + M days]), where M defaults to 60 days.
   */
  static async validatePrePostHospitalizationWindow(
    incomingClaim: IClaim,
    parentClaim: ClaimModel,
    orgId?: string | null,
    orgEntityId?: string | null,
  ): Promise<void> {
    const meta: any = incomingClaim.meta as any;
    const selection = meta?.prePostSelection;
    if (!selection || (!selection.pre && !selection.post)) {
      return;
    }

    const parentDoaStr = (parentClaim.meta as any)?.doa as string | undefined;
    const parentDodStr = (parentClaim.meta as any)?.dod as string | undefined;

    if (!parentDoaStr || !parentDodStr) {
      throw new CustomError(
        "Unable to validate pre/post hospitalization: parent claim does not have hospitalization dates configured",
      );
    }

    const parentDoa = moment(parentDoaStr);
    const parentDod = moment(parentDodStr);

    if (!parentDoa.isValid() || !parentDod.isValid()) {
      throw new CustomError(
        "Unable to validate pre/post hospitalization: parent claim has invalid hospitalization dates",
      );
    }

    // Fetch org property for pre/post hospitalization window days, with defaults
    const DEFAULT_PRE_WINDOW_DAYS = 30;
    const DEFAULT_POST_WINDOW_DAYS = 60;

    let preWindowDays = DEFAULT_PRE_WINDOW_DAYS;
    let postWindowDays = DEFAULT_POST_WINDOW_DAYS;

    if (orgId) {
      try {
        const windowDaysProperty = await getOrgPropertyByNameAndOrgId(
          OrgProperties.PRE_POST_HOSPITALIZATION_WINDOW_DAYS,
          orgId,
          orgEntityId,
        );

        if (windowDaysProperty?.meta) {
          if (windowDaysProperty.meta.preDays !== undefined && typeof windowDaysProperty.meta.preDays === "number") {
            if (windowDaysProperty.meta.preDays < 0) {
              logger.warn(
                `Invalid preWindowDays value: ${windowDaysProperty.meta.preDays}, using default ${DEFAULT_PRE_WINDOW_DAYS} days`,
                { orgId, orgEntityId },
              );
            } else {
              preWindowDays = windowDaysProperty.meta.preDays;
            }
          }
          if (windowDaysProperty.meta.postDays !== undefined && typeof windowDaysProperty.meta.postDays === "number") {
            if (windowDaysProperty.meta.postDays < 0) {
              logger.warn(
                `Invalid postWindowDays value: ${windowDaysProperty.meta.postDays}, using default ${DEFAULT_POST_WINDOW_DAYS} days`,
                { orgId, orgEntityId },
              );
            } else {
              postWindowDays = windowDaysProperty.meta.postDays;
            }
          }
        }
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : String(error);
        logger.warn(`Failed to fetch org property for pre/post hospitalization window days, using defaults`, {
          error: errorMessage,
          orgId,
          orgEntityId,
        });
      }
    }

    const hospitalization = meta?.hospitalization || {};

    // For pure pre/post claims (no main), use dedicated bill date fields to avoid
    // overloading main hospitalization DOA/DOD.
    const isPurePrePost = selection && (selection.pre || selection.post) && !selection.main;

    const startDateStr = isPurePrePost ? meta.preHospitalizationBillDate : hospitalization.startDate || meta.doa;

    const endDateStr = isPurePrePost ? meta.postHospitalizationBillDate : hospitalization.endDate || meta.dod;

    if (selection.pre) {
      if (!startDateStr) {
        throw new CustomError("Please provide hospitalization start date for pre-hospitalization claims");
      }
      const startDate = moment(startDateStr as string);
      if (!startDate.isValid()) {
        throw new CustomError("Invalid hospitalization start date for pre-hospitalization claim");
      }

      const earliestPre = parentDoa.clone().subtract(preWindowDays, "days");
      // startDate must be within [DOA - preWindowDays days, DOA)
      if (startDate.isBefore(earliestPre) || !startDate.isBefore(parentDoa)) {
        throw new CustomError(
          `For pre-hospitalization claims, the hospitalization start date must be within ${preWindowDays} days before the master claim's admission date`,
        );
      }
    }

    if (selection.post) {
      if (!endDateStr) {
        throw new CustomError("Please provide hospitalization end date for post-hospitalization claims");
      }
      const endDate = moment(endDateStr as string);
      if (!endDate.isValid()) {
        throw new CustomError("Invalid hospitalization end date for post-hospitalization claim");
      }

      const latestPost = parentDod.clone().add(postWindowDays, "days");
      // endDate must be within [DOD, DOD + postWindowDays days]
      if (endDate.isBefore(parentDod) || endDate.isAfter(latestPost)) {
        throw new CustomError(
          `For post-hospitalization claims, the hospitalization end date must be within ${postWindowDays} days after the master claim's discharge date`,
        );
      }
    }
  }
}
