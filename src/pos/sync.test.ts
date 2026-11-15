/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * The worker, against an office that behaves like a bad Iraqi connection.
 *
 * Twenty sales rung up with the network off, then a refund, two debts and a
 * delivery — and then the network comes back, dies halfway, comes back
 * again. Everything must reach the office exactly once, and nothing may
 * leave the queue that the office has not confirmed.
 *
 * The office here is a stub that speaks PostgREST's insert-with-
 * ignore-duplicates and keeps rows in a Map, so the counting is real even
 * though the database is not. What it cannot test is Supabase's own
 * behaviour; supabase/rls-test.sql does that, against a real Postgres.
 */

import "fake-indexeddb/auto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/* ---------------------------------------------------------- a fake tablet */

class Memory {
  private kept = new Map<string, string>();
  getItem(key: string) { return this.kept.get(key) ?? null; }
  setItem(key: string, value: string) { this.kept.set(key, String(value)); }
  removeItem(key: string) { this.kept.delete(key); }
  clear() { this.kept.clear(); }
}
const store_ = new Memory();
vi.stubGlobal("localStorage", store_);
vi.stubGlobal("window", {
  addEventListener() {}, removeEventListener() {},
  setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout,
});
vi.stubGlobal("document", { addEventListener() {}, removeEventListener() {} });

/* ---------------------------------------------------------- a fake office */

interface Office {
  /** table → id → row. A Map, so a second insert of the same id is visible
      as an overwrite if we ever got that wrong. */
  rows: Map<string, Map<string, unknown>>;
  /** Insert attempts, including the ones we refused. */
  attempts: number;
  /** Refuse the next N requests, as a dropped connection would. */
  refuse: number;
  /** Accept the write and then drop the connection, so the till never hears
      that it worked. The nastiest real failure there is. */
  silentlySucceed: number;
}

let office: Office;

function freshOffice() {
  office = { rows: new Map(), attempts: 0, refuse: 0, silentlySucceed: 0 };
}

function count(table: string): number {
  return office.rows.get(table)?.size ?? 0;
}

function fakeFetch(url: string, init: RequestInit = {}): Promise<Response> {
  const path = String(url);

  if (path.includes("/auth/v1/token")) {
    return Promise.resolve(new Response(
      JSON.stringify({ access_token: "tok", refresh_token: "ref", expires_in: 3600, user: { email: "a@b.c" } }),
      { status: 200, headers: { "content-type": "application/json" } },
    ));
  }

  const table = /\/rest\/v1\/([a-z_]+)/.exec(path)?.[1] ?? "";

  if ((init.method ?? "GET") === "GET") {
    return Promise.resolve(new Response("[]", { status: 200 }));
  }

  office.attempts += 1;
  if (office.refuse > 0) {
    office.refuse -= 1;
    return Promise.reject(new TypeError("Failed to fetch"));
  }

  const body = JSON.parse(String(init.body)) as { id: string }[];
  const kept = office.rows.get(table) ?? new Map<string, unknown>();
  for (const row of body) {
    // resolution=ignore-duplicates: the primary key wins, the newcomer loses.
    if (!kept.has(row.id)) kept.set(row.id, row);
  }
  office.rows.set(table, kept);

  if (office.silentlySucceed > 0) {
    office.silentlySucceed -= 1;
    /* Saved, and then the connection died before the answer arrived. The
       till must retry, and the retry must not double anything. */
    return Promise.reject(new TypeError("Failed to fetch"));
  }
  return Promise.resolve(new Response(null, { status: 204 }));
}

vi.stubGlobal("fetch", fakeFetch as unknown as typeof fetch);
vi.stubGlobal("navigator", { onLine: true, userAgent: "test" });

/* The edition is decided at build time; the Cloud plan is the only one that
   fills an outbox at all. */
vi.mock("./edition", async (real) => ({
  ...(await real<typeof import("./edition")>()),
  EDITION: "cloud",
  isCloud: true,
  isOffline: false,
  /* `scoped` keys storage by edition, and cloud.ts reads its session
     through it at import time — so the mock has to agree with the keys
     signIn() writes below, or the till looks signed out. */
  scoped: (key: string) => `${key}.cloud`,
  databaseName: () => "corecashier-cloud",
}));

const {
  completeSale, priceCart, addToCart, clearCart, exportSnapshot, flushed,
  receiveStock, recordPayment, saveCustomer, theCart, voidSale, whenReady,
} = await import("./store");
const { outboxAll, outboxCount, loadOutbox } = await import("./outbox");
const { pushOutbox } = await import("./sync");
const { knownShop } = await import("./cloud");

function signIn() {
  store_.setItem("coreos.pos.cloud.session.v1.cloud", JSON.stringify({
    access: "tok", refresh: "ref", expires: Date.now() + 3_600_000, email: "shop@test",
  }));
  store_.setItem("coreos.pos.cloud.shop.v1.cloud", JSON.stringify({
    id: "00000000-0000-0000-0000-0000000000aa", name: "Test Shop",
    frozen: false, frozenMessage: "", until: null, graceDays: 14,
  }));
}

/** A day's trade on a tablet with no internet. */
async function aDayOffline() {
  const shelf = exportSnapshot().products.filter((p) => !p.archived);
  /* Held on to rather than looked up afterwards: these tests share one
     module and one database, so "the oldest sale in the book" is a sale
     from the previous test, which has already been voided. */
  let first = "";
  for (let i = 0; i < 20; i++) {
    clearCart();
    addToCart(shelf[i % shelf.length].id, 1 + (i % 3));
    const totals = priceCart(exportSnapshot(), theCart(), 0);
    const sale = completeSale({ totals, discount: 0, method: "cash", tendered: totals.total });
    if (i === 0) first = sale.id;
  }
  voidSale(first, "wrong item", "Owner");

  const abu = saveCustomer({ name: "Abu Omar", phone: "07701234567" });
  clearCart();
  addToCart(shelf[0].id, 1);
  const owed = priceCart(exportSnapshot(), theCart(), 0);
  completeSale({ totals: owed, discount: 0, method: "later", tendered: 0, customer: abu });
  recordPayment(abu.id, 2000, "part");

  receiveStock(shelf[3].id, 24);
  await flushed();
}

beforeEach(async () => {
  freshOffice();
  await whenReady();
  loadOutbox([]);
  signIn();
});

afterEach(() => clearCart());

describe("a day offline, then the network comes back", () => {
  it("queues every kind of thing that happened", async () => {
    await aDayOffline();

    const kinds = outboxAll().reduce<Record<string, number>>((count_, one) => {
      count_[one.kind] = (count_[one.kind] ?? 0) + 1;
      return count_;
    }, {});

    expect(kinds.sale).toBe(21);      // 20 for cash, 1 on the book
    expect(kinds.void).toBe(1);
    expect(kinds.debt).toBe(2);       // the sale on the book, and the payment
    expect(kinds.customer).toBe(1);
    expect(kinds.product ?? 0).toBe(0); // nothing was renamed or repriced
    expect(kinds.stock).toBeGreaterThanOrEqual(23); // 21 sold, 1 put back, 1 received
  });

  it("gets all of it to the office exactly once", async () => {
    await aDayOffline();
    const queued = outboxCount();

    const sent = await pushOutbox();

    expect(sent).toBe(queued);
    expect(outboxCount()).toBe(0);
    expect(count("cc_sale")).toBe(21);
    expect(count("cc_void")).toBe(1);
    expect(count("cc_debt")).toBe(2);
    expect(count("cc_customer_edit")).toBe(1);

    /* And pushing again sends nothing, because nothing is waiting. */
    const attempts = office.attempts;
    expect(await pushOutbox()).toBe(0);
    expect(office.attempts).toBe(attempts);
  });

  it("keeps everything when the connection dies mid-push", async () => {
    await aDayOffline();
    const queued = outboxCount();

    office.refuse = 1;
    await expect(pushOutbox()).rejects.toThrow();

    /* Not one entry may have been dropped: the office has not confirmed
       anything. */
    expect(outboxCount()).toBe(queued);
    expect(outboxAll().some((one) => one.tries === 1)).toBe(true);

    await pushOutbox();
    expect(outboxCount()).toBe(0);
    expect(count("cc_sale")).toBe(21);
  });

  it("does not duplicate when the office saved it but we never heard", async () => {
    await aDayOffline();

    /* The worst real failure: committed on their side, lost on the wire.
       The till is right to retry and the ids are what save it. */
    office.silentlySucceed = 1;
    await expect(pushOutbox()).rejects.toThrow();
    expect(outboxCount()).toBeGreaterThan(0);

    await pushOutbox();

    expect(outboxCount()).toBe(0);
    expect(count("cc_sale")).toBe(21);
    expect(count("cc_stock_move")).toBeGreaterThanOrEqual(23);
  });

  it("survives the network flapping ten times while selling", async () => {
    const shelf = exportSnapshot().products.filter((p) => !p.archived);

    for (let round = 0; round < 10; round++) {
      clearCart();
      addToCart(shelf[round % shelf.length].id, 1);
      const totals = priceCart(exportSnapshot(), theCart(), 0);
      completeSale({ totals, discount: 0, method: "cash", tendered: totals.total });
      await flushed();

      // Off, then on.
      office.refuse = 1;
      await pushOutbox().catch(() => {});
      await pushOutbox().catch(() => {});
    }

    await pushOutbox();
    expect(outboxCount()).toBe(0);
    expect(count("cc_sale")).toBe(10);
  });

  it("refuses to push with no shop rather than dropping the queue", async () => {
    await aDayOffline();
    store_.removeItem("coreos.pos.cloud.shop.v1.cloud");
    expect(knownShop()).toBeNull();
    await expect(pushOutbox()).rejects.toThrow();
    expect(outboxCount()).toBeGreaterThan(0);
  });
});
