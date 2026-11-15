/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * The conversation with the office, which the cashier never sees.
 *
 * Three promises, and everything here exists to keep one of them.
 *
 * **It is never on the path of a sale.** Nothing in this file is awaited
 * between a cashier pressing Charge and the receipt. A sale is written to
 * the tablet and this finds out afterwards. If the whole office were on
 * fire the counter would not notice.
 *
 * **Pushing twice is free.** Every row carries an id made on the tablet and
 * goes up with `resolution=ignore-duplicates`, so the database's primary key
 * does the deduplicating. A request that dies after the server committed it
 * but before we heard back — the normal failure on a bad connection — costs
 * one wasted retry and nothing else.
 *
 * **Nothing leaves the queue unconfirmed.** An entry is removed only after a
 * 2xx for the batch it was in. Not after a hopeful retry, not to free room.
 * A till three days offline keeps all three days.
 *
 * Written with plain `fetch` against PostgREST rather than supabase-js, for
 * the reason given at the top of cloud.ts: the library brings a websocket
 * stack and a storage client this never touches, and the till ships as one
 * file onto a 4GB tablet.
 */

import { CloudError, knownShop, rest } from "./cloud";
import {
  confirmed,
  outboxAll,
  outboxCount,
  tried,
  type EventKind,
  type OutEvent,
} from "./outbox";
import { scoped } from "./edition";
import { reportError } from "./reportIssue";
import { write } from "./db";
import { applyFromCloud, exportSnapshot, flushed, type FromCloud } from "./store";

/** Which table each kind of event becomes a row in. */
const TABLE: Record<EventKind, string> = {
  sale: "cc_sale",
  void: "cc_void",
  stock: "cc_stock_move",
  product: "cc_product_edit",
  customer: "cc_customer_edit",
  debt: "cc_debt",
  close: "cc_close",
};

/**
 * Rows per request.
 *
 * Two hundred is about 60 kB of sales, which goes up in a few seconds on a
 * bad connection. One request with four thousand sales in it times out and
 * has to start again from nothing, which is how a till that has been offline
 * for a week never manages to catch up at all.
 */
const BATCH = 200;

/* ----------------------------------------------------------- the pushing */

/**
 * Send what is waiting.
 *
 * Grouped by kind because each kind is a different table, and sales go
 * first: if the connection dies halfway through, the thing the shop most
 * needs the office to have is the money.
 */
export async function pushOutbox(): Promise<number> {
  const shop = knownShop();
  if (!shop) throw new CloudError("noShop");

  const order: EventKind[] = ["sale", "void", "stock", "debt", "product", "customer", "close"];
  let sent = 0;

  for (const kind of order) {
    const mine = outboxAll().filter((one) => one.kind === kind);
    for (let at = 0; at < mine.length; at += BATCH) {
      const batch = mine.slice(at, at + BATCH);
      const rows = batch.map((one) => ({
        shop_id: shop.id,
        id: one.rowId,
        ...one.body,
      }));

      try {
        await rest(`/rest/v1/${TABLE[kind]}`, {
          method: "POST",
          /* The database has already decided what happens on a clash: for
             every table here, nothing. Saying so explicitly means a resend
             is a no-op rather than an error we would have to read. */
          headers: { Prefer: "resolution=ignore-duplicates,return=minimal" },
          body: rows,
        });
      } catch (problem) {
        /* The batch stays in the queue, with the reason, and the next round
           starts from the same place. Nothing after this kind is attempted:
           on a connection that just refused two hundred rows, the next two
           hundred will not go either. */
        await remember(tried(batch.map((one) => one.id), describe(problem)));
        throw problem;
      }

      await remember(confirmed(batch.map((one) => one.id)));
      sent += batch.length;
    }
  }

  return sent;
}

/* ----------------------------------------------------------- the pulling */

/**
 * Where we had got to in each of the office's tables.
 *
 * The cursor is the *server's* clock, not the tablet's. Tablet clocks in
 * these shops are wrong often enough — a factory reset, a flat battery, a
 * cashier fixing the time by eye — that a cursor trusting them would skip a
 * day of another till's trade and never come back for it.
 */
const CURSOR_KEY = scoped("coreos.pos.sync.cursor.v1");

type Cursors = Record<string, string>;

function cursors(): Cursors {
  try {
    return JSON.parse(localStorage.getItem(CURSOR_KEY) ?? "{}") as Cursors;
  } catch {
    return {};
  }
}

function rememberCursor(table: string, to: string) {
  try {
    localStorage.setItem(CURSOR_KEY, JSON.stringify({ ...cursors(), [table]: to }));
  } catch {
    /* A till that cannot remember where it got to re-reads from the
       beginning next time. Slow, never wrong: every merge is by id. */
  }
}

/**
 * How far back to look past the cursor, in milliseconds.
 *
 * Two transactions can be stamped in the order they started and commit in
 * the other order, so a strict "newer than the cursor" read can step over a
 * row that was still in flight. Overlapping by a minute catches it. Reading
 * the same row twice is free — every merge below is keyed by id, and the one
 * thing that would not survive being applied twice, a stock movement, is
 * deduplicated by its own id before it is applied.
 */
const OVERLAP_MS = 60_000;

/** Rows per pull. A new till joining a shop with four years of trade walks
    through it a page at a time instead of asking for all of it at once. */
const PAGE = 500;

async function pullTable(table: string, select = "*"): Promise<Record<string, unknown>[]> {
  const since = cursors()[table];
  const from = since
    ? new Date(Date.parse(since) - OVERLAP_MS).toISOString()
    : "1970-01-01T00:00:00Z";

  const rows = (await rest(
    `/rest/v1/${table}?select=${select}&server_at=gt.${encodeURIComponent(from)}` +
      `&order=server_at.asc&limit=${PAGE}`,
  )) as Record<string, unknown>[] | null;

  const got = rows ?? [];
  if (got.length > 0) {
    const last = got[got.length - 1].server_at;
    if (typeof last === "string") rememberCursor(table, last);
  }
  return got;
}

/**
 * Bring down what the shop's other tills have done.
 *
 * Only the things a second till needs to show the same shop: the sales, the
 * stock that moved, the shelf and the debt book. Not the audit log, not
 * shifts, not staff — those are each tablet's own.
 *
 * Returns true while there may be more, so the caller can go round again
 * rather than leaving a till half caught-up.
 */
export async function pullChanges(): Promise<{ applied: number; more: boolean }> {
  const [sales, voids, moves, products, customers, debts] = await Promise.all([
    pullTable("cc_sale"),
    pullTable("cc_void"),
    pullTable("cc_stock_move"),
    pullTable("cc_product_edit"),
    pullTable("cc_customer_edit"),
    pullTable("cc_debt"),
  ]);

  const batch: FromCloud = { sales, voids, moves, products, customers, debts };
  const applied = await applyFromCloud(batch);
  const biggest = Math.max(
    sales.length, voids.length, moves.length,
    products.length, customers.length, debts.length,
  );
  return { applied, more: biggest >= PAGE };
}

/* -------------------------------------------------------------- the round */

export interface Round {
  pushed: number;
  pulled: number;
}

/**
 * One trip: everything waiting goes up, then whatever is new comes down.
 *
 * Push before pull, always. If the two crossed, this till could pull a
 * stock movement, apply it, and then push its own count — which would be
 * the count before the movement.
 */
export async function syncRound(): Promise<Round> {
  /* Sales still in the write queue are sales the office should have.
     Waiting for the disk costs milliseconds and saves a whole round. */
  await flushed();

  const pushed = await pushOutbox();

  let pulled = 0;
  for (let page = 0; page < 20; page++) {
    const { applied, more } = await pullChanges();
    pulled += applied;
    if (!more) break;
  }

  return { pushed, pulled };
}

/* --------------------------------------------------------------- the loop */

/**
 * How long to wait after a failure, doubling, capped.
 *
 * Capped at five minutes rather than growing for ever: the usual reason a
 * push fails here is that the shop's connection is out, and it comes back
 * without warning. A till backing off to an hour would still be sitting
 * quiet twenty minutes after the wifi returned.
 */
export function backoffMs(failures: number): number {
  return Math.min(5 * 60_000, 2_000 * 2 ** Math.min(failures, 8));
}

/** Days before the shop is told its books have not reached us. Three, as
    the brief sets — long enough that an ordinary bad week says nothing. */
export const WARN_AFTER_DAYS = 3;

export interface SyncState {
  /** `idle` and nothing waiting is the green dot. */
  phase: "idle" | "syncing" | "offline";
  waiting: number;
  lastOk: number | null;
  failures: number;
}

let state: SyncState = { phase: "idle", waiting: 0, lastOk: lastOkAt(), failures: 0 };
const watchers = new Set<() => void>();

const OK_KEY = scoped("coreos.pos.sync.lastok.v1");

function lastOkAt(): number | null {
  try {
    const raw = localStorage.getItem(OK_KEY);
    return raw ? Number(raw) : null;
  } catch {
    return null;
  }
}

function publish(next: Partial<SyncState>) {
  state = { ...state, ...next, waiting: outboxCount() };
  for (const watcher of watchers) watcher();
}

export function subscribeSync(listener: () => void): () => void {
  watchers.add(listener);
  return () => {
    watchers.delete(listener);
  };
}

export function syncState(): SyncState {
  return state;
}

/** True once the shop has been out of touch long enough to be told. Only
    counts if something is actually waiting — a shop that has sold nothing
    for three days is not a shop with a backup problem. */
export function longUnsynced(now = Date.now()): boolean {
  if (outboxCount() === 0) return false;
  const since = state.lastOk;
  if (since === null) return false;
  return now - since > WARN_AFTER_DAYS * 86_400_000;
}

let running = false;

/**
 * Do a round now, unless one is already going.
 *
 * Never throws. Everything it can run into is something the shop carries on
 * through, and being offline is not an error here — it is most of the day.
 */
export async function syncNow(): Promise<Round | null> {
  if (running) return null;
  running = true;
  publish({ phase: "syncing" });
  try {
    const round = await syncRound();
    try {
      localStorage.setItem(OK_KEY, String(Date.now()));
    } catch {
      // See rememberCursor.
    }
    publish({ phase: "idle", lastOk: Date.now(), failures: 0 });
    return round;
  } catch (problem) {
    const fault = problem instanceof CloudError ? problem.fault : "server";
    const failures = state.failures + 1;
    publish({ phase: fault === "offline" ? "offline" : "idle", failures });

    /* Offline is the normal state in these shops and is logged quietly, once,
       so a gap in the office's books can be explained later without a card
       going up over the counter. Anything else is DT-02 — still quiet, still
       retried, but a support desk can see it. */
    if (fault === "offline") {
      reportError("DT-02", "sync: no connection", { quiet: true, once: "offline" });
    } else if (failures >= 3) {
      reportError("DT-02", `sync failed ${failures} times: ${fault}`, { quiet: true });
    }
    return null;
  } finally {
    running = false;
  }
}

/**
 * Keep it going while the till is open.
 *
 * Wakes on: opening, the network coming back, the tablet being picked up
 * again, every thirty seconds, and after each sale — the last of those
 * through `nudge()`, called by the store.
 */
export function watchSync(): () => void {
  let stopped = false;
  let timer = 0;

  const tick = async () => {
    if (stopped) return;
    await syncNow();
    if (stopped) return;
    const wait = state.failures > 0 ? backoffMs(state.failures) : 30_000;
    timer = window.setTimeout(() => void tick(), wait);
  };

  /* The network coming back is the one event worth reacting to instantly:
     the shop has been piling up sales and the owner wants them safe. */
  const onBack = () => {
    publish({ failures: 0 });
    window.clearTimeout(timer);
    void tick();
  };

  void tick();
  window.addEventListener("online", onBack);
  document.addEventListener("visibilitychange", onBack);

  return () => {
    stopped = true;
    window.clearTimeout(timer);
    window.removeEventListener("online", onBack);
    document.removeEventListener("visibilitychange", onBack);
  };
}

/** After a sale. Debounced, because a queue of customers is a lot of sales
    and each one does not need its own round trip. */
let soon = 0;
export function nudge() {
  if (!navigator.onLine) return;
  window.clearTimeout(soon);
  soon = window.setTimeout(() => void syncNow(), 3_000);
}

/* -------------------------------------------------------------- odds and ends */

function describe(problem: unknown): string {
  if (problem instanceof CloudError) return problem.fault;
  return problem instanceof Error ? problem.message : String(problem);
}

/** The outbox's own writes. Separate from the store's queue: this is
    bookkeeping about the sync, and must never be able to hold up a sale. */
async function remember(change: ReturnType<typeof confirmed>) {
  if (!change) return;
  try {
    await write([change]);
  } catch (cause) {
    reportError("DT-01", `outbox write failed: ${describe(cause)}`, { quiet: true });
  }
}

/** For the first upload of a shop moving from Offline to Cloud. Walks the
    whole book into the outbox so the ordinary push can take it from there,
    in batches, with somewhere to report progress to. */
export function backlog(): number {
  return exportSnapshot().sales.length;
}
