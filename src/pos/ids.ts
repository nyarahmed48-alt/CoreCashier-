/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * A full UUID, never a slice of one.
 *
 * This used to keep the first eight characters, which is thirty-two bits:
 * two records of the same kind start colliding around seventy-seven thousand
 * of them, and a shop with fifty thousand sales was inside the range where
 * two could share an id. Once several tablets sync into one set of books, an
 * id collision stops being a curiosity and becomes one shop's sale
 * overwriting another's.
 *
 * It lives in its own file because the outbox needs it and the store needs
 * the outbox, and a cycle between those two is how a module ends up
 * half-initialised at the worst possible moment.
 */
export function newId(prefix: string): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return `${prefix}-${crypto.randomUUID()}`;
  }
  // Old WebViews: four blocks of randomness, same width, no uniqueness claim
  // beyond what the device's own Math.random can offer.
  let out = "";
  for (let i = 0; i < 4; i++) out += Math.random().toString(36).slice(2, 10);
  return `${prefix}-${out}`;
}
