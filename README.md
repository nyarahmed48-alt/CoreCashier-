# CoreCashier

A till for a shop counter in Iraq. Arabic, Kurdish (Sorani) and English, right
to left where it should be, on the cheap Android tablets these shops actually
own — a HONOR Pad X7 with 4GB of memory, a Galaxy Tab A9+.

It works with the internet off. That is not a feature, it is the premise: the
connection and the power both go out here, and a till that stops when the wifi
does is worse than no till at all. Everything is kept on the tablet, in
IndexedDB, one record per sale.

Built by [CoreOS](https://coreosai.netlify.app), Baghdad.

## What is in here

| Build | Command | What it is |
|---|---|---|
| **Till** | `npm run build:pos` | `CoreCashier.html` — the till a shop buys outright. One file, runs off a USB stick. |
| **Demo** | `npm run build:demo` | The one to put in front of a shopkeeper. Sample shelf, no licence, every receipt stamped so it can never quietly become somebody's real till. |
| **Loaner** | `npm run build:loaner` | The tablet handed to a shop while theirs is repaired. A real till, no licence, counts the days it has been out. |
| **Cloud** | `npm run build:cloud` | The subscription. Signs in to a CoreOS account and syncs. |
| **Installable** | `npm run build:app` | `dist-app/` — drop on any https host and a tablet can install it. |
| **Device Check** | `npm run build:check` | Tells you whether a tablet is fit to run the till before a shop pays for it. |
| **Key Maker** | `npm run build:keys` | Makes the signing keypairs. Stays on one machine. |
| **Code Generator** | `npm run build:gen` | Turns a shop's screen code into a signed licence. |
| **Owner Console** | `npm run build:ceo` | CoreOS's own console. One phone, not a web server. |

`npm run build:all` makes all the portable files at once.

## Working on it

```
npm install
npm test          # the arithmetic money passes through, and the migrations
npm run lint      # tsc --noEmit
npm run build:pos
```

Open the built `.html` file in a browser. There is no dev server and no
backend to run: the till is the whole thing.

## Rules this codebase keeps

**The sale never waits.** Nothing — not a sync, not a licence check, not a
report — sits between a cashier pressing *Charge* and the receipt coming out.

**Money is whole dinars.** Integers everywhere. Fils have not been in
circulation for decades and a rounding error in a day's takings is a shop that
stops trusting the till.

**Digits stay Latin.** In all three languages. A cashier reads a screen against
a shelf label, and ٧٥٠ against 750 is a mistake waiting to happen.

**A till that has been stopped can still read its own books.** Read-only means
no new sales; it never means a shop cannot see or export what it already has.

**No private key, ever.** Not in the app, not in this repository, not on a
server. Licences and technician keys are signed on one machine, by hand.
