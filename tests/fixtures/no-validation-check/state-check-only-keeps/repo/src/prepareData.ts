// Per Gemini peer review counterexample: this function has 2 weak tells
// (if-bang + throw new) but no real format validation. Validator should
// NOT drop a "no format validation" finding here. Tiered tells handle this:
// 0 strong + 2 weak = below the 3-weak threshold = no drop.

export function prepareData(input: { ready: boolean; payload: unknown }) {
  if (!input.ready) throw new Error("Not ready");
  return input.payload;
}
