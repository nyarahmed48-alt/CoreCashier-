/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * The queue that must not lose anything.
 *
 * These go at the outbox directly, past every screen. The promises being
 * checked are the ones a shop's money depends on: nothing leaves without a
 * confirmation, a failed attempt changes nothing but a counter, and a till
 * restarted mid-sync comes back with exactly what it had.
 */

import "fake-indexeddb/auto";
import { beforeEach, describe, expect, it } from "vitest";
import {
  confirmed,
  enqueue,
  event,
  loadOutbox,
  oldestWaiting,
  outboxAll,
  outboxCount,
  stockEvent,
  stuck,
  tried,
  type OutEvent,
} from "./outbox";

const sale = (id: string, at = "2026-11-15T10:00:00.000Z") =>
  event("sale", id, { total: 1000, at }, at);

beforeEach(() => loadOutbox([]));

describe("the outbox", () => {
  it("hands back a write rather than doing one", () => {
    /* The whole point: the caller folds this into the same transaction as
       the sale, so the two can never disagree. */
    const change = enqueue([sale("s-1")]);
    expect(change).toEqual({ store: "outbox", put: [expect.objectContaining({ id: "sale:s-1" })] });
    expect(outboxCount()).toBe(1);
  });

  it("keeps the oldest first, whatever order they were added", () => {
    enqueue([sale("s-3", "2026-11-15T12:00:00.000Z")]);
    enqueue([sale("s-1", "2026-11-15T08:00:00.000Z")]);
    enqueue([sale("s-2", "2026-11-15T10:00:00.000Z")]);
    expect(outboxAll().map((one) => one.rowId)).toEqual(["s-1", "s-2", "s-3"]);
    expect(oldestWaiting()).toBe("2026-11-15T08:00:00.000Z");
  });

  it("replaces rather than duplicates an entry for the same thing", () => {
    /* Saving a product twice before a sync should push one edit. */
    enqueue([event("product", "p-1", { price: 1000 })]);
    enqueue([event("product", "p-1", { price: 1500 })]);
    expect(outboxCount()).toBe(1);
    expect(outboxAll()[0].body.price).toBe(1500);
  });

  it("gives every stock movement its own identity", () => {
    /* One sale moves several products and each movement is its own fact —
       they must not collapse into one another. */
    const a = stockEvent("p-1", -2, "sold", "T1", "s-1");
    const b = stockEvent("p-1", -1, "sold", "T1", "s-2");
    enqueue([a, b]);
    expect(outboxCount()).toBe(2);
    expect(a.id).not.toBe(b.id);
  });

  it("removes nothing until the office has confirmed it", () => {
    enqueue([sale("s-1"), sale("s-2")]);
    const change = tried(["sale:s-1", "sale:s-2"], "offline");
    expect(outboxCount()).toBe(2);
    expect(change?.remove).toBeUndefined();
    expect(outboxAll().every((one) => one.tries === 1)).toBe(true);

    confirmed(["sale:s-1"]);
    expect(outboxAll().map((one) => one.rowId)).toEqual(["s-2"]);
  });

  it("survives three days offline without throwing anything away", () => {
    /* The old outbox emptied itself past five thousand entries, which a
       busy shop reaches in three days — exactly the case the feature is
       for. Nine hundred sales is a long weekend. */
    const many: OutEvent[] = [];
    for (let i = 0; i < 900; i++) {
      many.push(sale(`s-${i}`, new Date(Date.UTC(2026, 10, 12, 8, 0, i)).toISOString()));
    }
    enqueue(many);
    expect(outboxCount()).toBe(900);
    expect(oldestWaiting()).toBe("2026-11-12T08:00:00.000Z");
  });

  it("comes back exactly as it was after a restart", () => {
    enqueue([sale("s-1"), sale("s-2")]);
    const onDisk = outboxAll();
    /* A new tab, a killed browser, a tablet pulled off the charger. */
    loadOutbox([]);
    expect(outboxCount()).toBe(0);
    loadOutbox(onDisk);
    expect(outboxAll().map((one) => one.rowId)).toEqual(["s-1", "s-2"]);
  });

  it("can point at the one entry that is stuck", () => {
    enqueue([sale("s-1"), sale("s-2")]);
    for (let i = 0; i < 6; i++) tried(["sale:s-1"], "server");
    expect(stuck().map((one) => one.rowId)).toEqual(["s-1"]);
  });
});
