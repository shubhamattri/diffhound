import { validate as isUuid } from "uuid";
import { CustomError } from "../../common/errors";

export function requireEnabled() {
  if (process.env.CLARO_CLAIM_REGISTRATION_ENABLED !== "true")
    throw new CustomError("Claim registration through Claro is not enabled");
}

export function requireUuid(value: string) {
  if (!isUuid(value)) throw new CustomError("Invalid action identifier");
}
