/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * What comes down from the office, and what it is allowed to change.
 *
 * The three conflict rules, checked against the cases they exist for: two
 * tills selling the same thing while both offline, an edit from Tuesday
 * arriving on Friday, and the same pull arriving twice because a connection
 * died after the server answered.
 */

import "fake-indexeddb/auto";
import { beforeEach, describe, expect, it } from "vitest";
import {
  applyFromCloud,
  exportSnapshot,
  flushed,
  receiveStock,
  saveProduct,
  whenReady,
  type FromCloud,
} from "./store";
import type { Product } from "./types";

const nothing: FromCloud = {
  sales: [], voids: [], moves: [], products: [], customers: [], debts: [],
};

const from = (part: Partial<FromCloud>): FromCloud => ({ ...nothing, ...part });

/** The books are read off the disk before anything works. Waiting on the
    seeded shelf is not enough — that is in memory from the first tick, and
    the merge needs the database open. */
async function ready() {
  await whenReady();
  await flushed();
}

function shelf(): Product[] {
  return exportSnapshot().products;
}

function find(name: string): Product | undefined {
  return shelf().find((one) => one.name === name);
}

beforeEach(ready);

describe("stock, when two tills are both offline", () => {
  it("counts both of them", async () => {
    const mine = shelf()[0];
    const before = mine.stock;

    /* This tablet sold two. The other tablet sold two at the same moment
       and we are only hearing about it now. If stock were a number each
       till pushed, one of these would have been wiped out. */
    saveProduct({ ...mine, stock: before - 2 });
    await flushed();

    await applyFromCloud(from({
      moves: [
        { id: "m-other-1", till_id: "T2", product_id: mine.id, delta: -2, reason: "sold", at: "2026-11-15T10:00:00Z" },
      ],
    }));

    expect(find(mine.name)?.stock).toBe(before - 4);
  });

  it("applies the same movement once, however many times it arrives", async () => {
    const mine = shelf()[1];
    const before = mine.stock;
    const move = {
      id: "m-twice", till_id: "T2", product_id: mine.id,
      delta: -3, reason: "sold", at: "2026-11-15T10:00:00Z",
    };

    /* A pull overlaps the last one by a minute on purpose, so rows do come
       down twice. A delta is the one thing that would not survive it. */
    await applyFromCloud(from({ moves: [move] }));
    await applyFromCloud(from({ moves: [move] }));
    await applyFromCloud(from({ moves: [move] }));

    expect(find(mine.name)?.stock).toBe(before - 3);
  });

  it("ignores its own movements coming back", async () => {
    const mine = shelf()[2];
    const before = mine.stock;
    receiveStock(mine.id, 24);
    await flushed();
    const till = exportSnapshot().settings.tillId;

    /* Our own push, read back by the next pull. The local number already
       has it; applying it again would double the delivery. */
    await applyFromCloud(from({
      moves: [
        { id: "m-ours", till_id: till, product_id: mine.id, delta: 24, reason: "received", at: "2026-11-15T10:00:00Z" },
      ],
    }));

    expect(find(mine.name)?.stock).toBe(before + 24);
  });

  it("does not lose stock for a product it has never heard of", async () => {
    /* The movement can arrive in the same pull as the edit that creates
       the product, or before it. Either way the shelf has to end up right. */
    await applyFromCloud(from({
      moves: [
        { id: "m-new", till_id: "T2", product_id: "p-new", delta: -5, reason: "sold", at: "2026-11-15T10:00:00Z" },
      ],
    }));
    await applyFromCloud(from({
      products: [
        { id: "pe-1", product_id: "p-new", name: "Dates 1kg", price: 3000, low_stock_at: -1, archived: false, edited_at: "2026-11-15T09:00:00Z" },
      ],
      moves: [
        { id: "m-open", till_id: "T2", product_id: "p-new", delta: 20, reason: "opening", at: "2026-11-15T08:00:00Z" },
      ],
    }));

    expect(find("Dates 1kg")?.stock).toBe(15);
  });
});

describe("a price edited on two tablets", () => {
  it("keeps the later edit when the earlier one arrives afterwards", async () => {
    const mine = shelf()[3];

    saveProduct({ ...mine, price: 9500 });
    await flushed();
    const thursday = find(mine.name)?.editedAt ?? "";
    expect(thursday).not.toBe("");

    /* The other till was offline on Tuesday and is only now pushing. Later
       in arrival, earlier in fact. It must not win. */
    await applyFromCloud(from({
      products: [
        { id: "pe-tue", product_id: mine.id, name: mine.name, price: 9000, low_stock_at: -1, archived: false, edited_at: "2026-11-10T10:00:00Z" },
      ],
    }));
    expect(find(mine.name)?.price).toBe(9500);

    /* And a genuinely newer one does. */
    await applyFromCloud(from({
      products: [
        { id: "pe-sat", product_id: mine.id, name: mine.name, price: 11000, low_stock_at: -1, archived: false, edited_at: "2099-01-01T00:00:00Z" },
      ],
    }));
    expect(find(mine.name)?.price).toBe(11000);
  });

  it("never touches the stock count while changing the description", async () => {
    const mine = shelf()[4];
    const before = mine.stock;
    await applyFromCloud(from({
      products: [
        { id: "pe-rename", product_id: mine.id, name: "Renamed", price: 123, low_stock_at: -1, archived: false, edited_at: "2099-01-01T00:00:00Z" },
      ],
    }));
    expect(find("Renamed")?.stock).toBe(before);
  });
});

describe("sales from another till", () => {
  const theirs = {
    id: "s-other", till_id: "T2", receipt_no: "T2-000001",
    at: "2026-11-15T11:00:00Z", lines: [{ id: "l1", productId: "p", name: "Tea", price: 1500, qty: 2 }],
    subtotal: 3000, discount: 0, rounding: 0, total: 3000, method: "cash",
    tendered: 3000, change_given: 0, staff_name: "Sara",
  };

  it("arrive once, and arriving again changes nothing", async () => {
    await applyFromCloud(from({ sales: [theirs] }));
    const after = exportSnapshot().sales.filter((one) => one.id === "s-other");
    expect(after).toHaveLength(1);
    expect(after[0].total).toBe(3000);
    expect(after[0].deviceId).toBe("T2");

    await applyFromCloud(from({ sales: [theirs] }));
    expect(exportSnapshot().sales.filter((one) => one.id === "s-other")).toHaveLength(1);
  });

  it("can be voided by the till that rang them up", async () => {
    await applyFromCloud(from({ sales: [theirs] }));
    await applyFromCloud(from({
      sales: [{ ...theirs, voided_at: "2026-11-15T11:05:00Z", voided_by: "Owner", void_reason: "wrong item" }],
    }));
    const one = exportSnapshot().sales.find((s) => s.id === "s-other");
    expect(one?.voidedAt).toBe("2026-11-15T11:05:00Z");
    expect(one?.voidReason).toBe("wrong item");
  });

  it("but a sale is never otherwise rewritten from the office", async () => {
    await applyFromCloud(from({ sales: [theirs] }));
    /* Whatever the office says the total was, the sale is a thing that
       happened and this one is already recorded. */
    await applyFromCloud(from({ sales: [{ ...theirs, total: 999999 }] }));
    expect(exportSnapshot().sales.find((s) => s.id === "s-other")?.total).toBe(3000);
  });
});

describe("the debt book", () => {
  it("takes another till's lines, once, with the right sign", async () => {
    await applyFromCloud(from({
      customers: [{ id: "ce-1", customer_id: "c-1", name: "Abu Omar", phone: "", edited_at: "2026-11-15T10:00:00Z" }],
      debts: [
        { id: "d-1", customer_id: "c-1", amount: 9000, at: "2026-11-15T10:00:00Z", note: "" },
        { id: "d-2", customer_id: "c-1", amount: -4000, at: "2026-11-15T12:00:00Z", note: "" },
      ],
    }));

    const book = exportSnapshot().debts.filter((one) => one.customerId === "c-1");
    expect(book).toHaveLength(2);
    expect(book.find((one) => one.id === "d-1")?.kind).toBe("owed");
    expect(book.find((one) => one.id === "d-2")?.kind).toBe("paid");
    expect(book.find((one) => one.id === "d-2")?.amount).toBe(4000);

    await applyFromCloud(from({ debts: [{ id: "d-1", customer_id: "c-1", amount: 9000, at: "2026-11-15T10:00:00Z" }] }));
    expect(exportSnapshot().debts.filter((one) => one.customerId === "c-1")).toHaveLength(2);
  });
});
