import { v4 as uuid } from "uuid";

export function requireEnabled() {
  if (process.env.CLARO !== "true") throw new Error("off");
}

export const makeId = () => uuid();
