/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * What this till has done and the office has not been told about yet.
 *
 * The one rule that makes offline-first work, and the one the old version of
 * this got wrong twice:
 *
 * **An entry is written in the same database transaction as the thing it
 * describes.** A sale and the note saying "this sale needs pushing" land
 * together or neither lands. The previous outbox lived in localStorage and
 * was written after the sale, which leaves a window — tiny, but a tablet
 * that gets unplugged mid-queue finds it — where a shop has a sale the
 * office will never hear about, and no way to know.
 *
 * **And it is never thrown away to save room.** The old one emptied itself
 * past five thousand entries, which a busy shop reaches in three days
 * offline — exactly the case the whole feature exists for. Here, entries
 * leave only when the server has confirmed it has them.
 *
 * Each entry is an event, not a row to overwrite: *this sale happened*,
 * *two of these left the shelf*, *this price changed at this time*. That is
 * what lets two tills sell the same thing offline and both be right. See
 * supabase/schema.sql, which is the other half of the same idea.
 */

import { newId } from "./ids";
import type { Change } from "./db";

/** Which table in the office an event becomes a row in. */
export type EventKind =
  | "sale"
  | "void"
  | "stock"
  | "product"
  | "customer"
  | "debt"
  | "close";

export interface OutEvent {
  /** `sale:s-3f8a…`. Unique across kinds, and the key in IndexedDB. */
  id: string;
  kind: EventKind;
  /**
   * The id the row will carry in the office's table — made on this tablet,
   * which is what makes pushing twice free. For a sale it is the sale's own
   * id, so the receipt a customer holds and the row in the office are the
   * same thing.
   */
  rowId: string;
  /** When it happened, by this tablet's clock. */
  at: string;
  /** The row itself, without `shop_id` — the sync worker adds that, because
      the till may be signed into a different shop by the time this goes. */
  body: Record<string, unknown>;
  /** How many times we have tried and failed. Kept so a single poisonous
      entry can be found rather than silently blocking everything behind it. */
  tries: number;
  lastError?: string;
}

export const OUTBOX_STORE = "outbox" as const;

/* Held in memory as well as on disk: the status dot reads the number of
   waiting items on every render, and a count that needed a database read
   would either block the counter or lie. */
let waiting: OutEvent[] = [];
const listeners = new Set<() => void>();

function notify() {
  for (const listener of listeners) listener();
}

export function subscribeOutbox(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** Filled by the store once the database is open. */
export function loadOutbox(entries: OutEvent[]) {
  waiting = [...entries].sort((a, b) => a.at.localeCompare(b.at));
  notify();
}

export function outboxCount(): number {
  return waiting.length;
}

/** The whole queue, oldest first. The worker takes from the front. */
export function outboxAll(): OutEvent[] {
  return waiting;
}

/** The oldest entry still waiting, which is how long the office has been
    behind — what the "not backed up for 3 days" warning is measured from. */
export function oldestWaiting(): string | null {
  return waiting.length > 0 ? waiting[0].at : null;
}

/**
 * An event, ready to be written.
 *
 * Returns the record rather than writing it: the caller folds it into the
 * same `write()` as the sale itself. That is the whole point — see above.
 */
export function event(
  kind: EventKind,
  rowId: string,
  body: Record<string, unknown>,
  at = new Date().toISOString(),
): OutEvent {
  return { id: `${kind}:${rowId}`, kind, rowId, at, body, tries: 0 };
}

/** A stock movement. Its own id, because one sale moves several products and
    each movement is its own fact. */
export function stockEvent(
  productId: string,
  delta: number,
  reason: "sold" | "void" | "received" | "counted" | "opening",
  tillId: string,
  saleId?: string,
  at = new Date().toISOString(),
): OutEvent {
  return event("stock", newId("m"), {
    till_id: tillId,
    product_id: productId,
    delta,
    reason,
    sale_id: saleId ?? null,
    at,
  }, at);
}

/**
 * Put events in the queue.
 *
 * Updates the in-memory copy at once, so the screen is right immediately,
 * and hands back the write for the caller's transaction. If that transaction
 * fails the store reloads from disk and the two agree again.
 */
export function enqueue(events: OutEvent[]): Change | null {
  if (events.length === 0) return null;
  /* A re-enqueued id replaces rather than duplicates: saving the same
     product twice before a sync should push one edit, not two. */
  const byId = new Map(waiting.map((one) => [one.id, one]));
  for (const one of events) byId.set(one.id, one);
  waiting = [...byId.values()].sort((a, b) => a.at.localeCompare(b.at));
  notify();
  return { store: OUTBOX_STORE, put: events };
}

/**
 * The office has it.
 *
 * Called only after a 2xx. Until then the entry stays, however many times we
 * have tried — a till that deletes an entry it merely *hopes* arrived is a
 * till that loses a day's trade to one bad connection.
 */
export function confirmed(ids: string[]): Change | null {
  if (ids.length === 0) return null;
  const gone = new Set(ids);
  waiting = waiting.filter((one) => !gone.has(one.id));
  notify();
  return { store: OUTBOX_STORE, remove: ids };
}

/** A failed attempt, remembered. Nothing leaves the queue. */
export function tried(ids: string[], why: string): Change | null {
  if (ids.length === 0) return null;
  const marked = new Set(ids);
  const put: OutEvent[] = [];
  waiting = waiting.map((one) => {
    if (!marked.has(one.id)) return one;
    const next = { ...one, tries: one.tries + 1, lastError: why.slice(0, 120) };
    put.push(next);
    return next;
  });
  notify();
  return put.length > 0 ? { store: OUTBOX_STORE, put } : null;
}

/** For the support report: is one entry stuck while the rest go through? */
export function stuck(): OutEvent[] {
  return waiting.filter((one) => one.tries >= 5);
}
