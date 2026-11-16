/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * The only thing the sync ever says to a cashier.
 *
 * A dot. Not a banner, not a toast, and above all not a dialog: the
 * connection in these shops drops and returns a dozen times an hour, and a
 * till that announced each one would be unusable by ten in the morning. A
 * cashier mid-queue must be able to ignore this completely and be right to.
 *
 * Green is saved. Orange is "no internet, still working, it will go up
 * later" — which is information, not a problem, and is written that way in
 * all three languages. Blue is the second or two while it goes.
 *
 * The one time it says more is after three days with something still
 * waiting, because at that point the shop genuinely has one copy of its own
 * books and should know. Even then it is a line of text, and even then the
 * till keeps selling.
 */

import { useSyncExternalStore } from "react";
import { subscribeOutbox } from "./outbox";
import { longUnsynced, syncState, subscribeSync, WARN_AFTER_DAYS } from "./sync";
import { useT } from "./useT";

/** Both stores feed the same dot, so it subscribes to both and reads once. */
function useSync() {
  return useSyncExternalStore(
    (listener) => {
      const stopA = subscribeSync(listener);
      const stopB = subscribeOutbox(listener);
      return () => {
        stopA();
        stopB();
      };
    },
    syncState,
    syncState,
  );
}

export function SyncDot() {
  const { t } = useT();
  const state = useSync();

  const look =
    state.phase === "syncing"
      ? { colour: "bg-[#6c7bf0]", label: t("sync.syncing") }
      : state.phase === "offline" || state.waiting > 0
        ? {
            colour: "bg-[#f0c078]",
            label:
              state.waiting > 0
                ? `${t("sync.offline")} · ${t("sync.waiting", { n: state.waiting })}`
                : t("sync.offline"),
          }
        : { colour: "bg-[#8ee7bb]", label: t("sync.online") };

  return (
    <span
      className="flex shrink-0 items-center gap-1.5"
      /* The words are the accessible name and the tooltip; on a tablet the
         dot is all there is room for, and a cashier does not need the
         words — the colour is the whole message. */
      title={look.label}
      aria-label={look.label}
      role="status"
    >
      <span
        className={`inline-block h-2 w-2 rounded-full ${look.colour} ${
          state.phase === "syncing" ? "animate-pulse" : ""
        }`}
      />
      {state.waiting > 0 ? (
        <span className="text-[11px] font-semibold tabular-nums text-[#f0c078]">
          {state.waiting}
        </span>
      ) : null}
    </span>
  );
}

/**
 * The one sentence, after three days.
 *
 * Under the header rather than over the till, and it does not block
 * anything. A shop that has been without internet for three days has not
 * done anything wrong and is not being told off; it is being told that the
 * only copy of its books is the tablet in its hand.
 */
export function SyncBehind() {
  const { t } = useT();
  const state = useSync();
  if (!longUnsynced()) return null;

  const days = state.lastOk
    ? Math.floor((Date.now() - state.lastOk) / 86_400_000)
    : WARN_AFTER_DAYS;

  return (
    <p className="pos-noprint border-b border-[#3a3320] bg-[#1b1708] px-4 py-2 text-center text-[12.5px] text-[#f0c078]">
      {t("sync.behind", { n: days })}
    </p>
  );
}
