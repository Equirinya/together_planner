# Money splitting — design and implementation

The `money` feature tab: shared expenses, Splitwise-style split modes, and a
settle-up screen that asks for the fewest possible payments.

No AI anywhere, and no new Cloud Functions — everything here is Firestore reads
plus integer arithmetic on the client.

**Status: implemented.** This document describes what is in the tree, and the
reasoning behind the parts that are not obvious. The last section is the
receipt-scanning step that comes next.

---

## 0. The decisions everything else follows from

| | |
|---|---|
| **Currency** | One per group (`groups/{id}.currency`, admin-writable, absent == `EUR`). Every amount is an **integer number of minor units** — cents — never a double |
| **Expenses and payments** | **One collection**, `money_entries`, with `type: "expense" \| "settlement"`. They are the same arithmetic, so they get the same storage, the same rules and the same balance code |
| **Simplification** | Never rewrites the ledger. The minimal payment set is computed on the fly and shown only on the settle-up screen; the per-expense shares stay the single source of truth |
| **Balances** | Computed on the client, from the entries. No functions, no denormalised balance document |
| **Placeholder people** | Self-claim ("which of these are you?"), admins can re-assign or unlink |

---

## 1. Why the app integration was nearly free

The `money` key was already wired end to end as a "coming soon" stub, so
enabling the feature took two edits:

| Place | Before | Now |
|---|---|---|
| `main.dart` `_allFeatures` / `_featureMeta` | already had `money` | unchanged |
| `main.dart` `_buildPage` | `_PlaceholderPage` | `MoneyPage(groupId: …)` |
| `onboarding_page.dart` `kOnboardingFeatures` | `implemented: false` | `implemented: true` |
| `group_settings_page.dart` | renders the registry, greys out unimplemented | unchanged — the checkbox works now |
| `functions/src/userManagement.ts` `VALID_FEATURES` | already had `"money"` | unchanged |

Onboarding selection, the group-settings toggle, "set as default page", the nav
bar and the OS home-screen shortcuts all came along for free.

One rules detail worth stating because it looks alarming: the
`match /{other=**} { allow read, write: if false }` catch-all inside
`/groups/{groupId}` does **not** block the new subcollections. Firestore ORs all
matching `allow`s together; a deny never overrides an allow.

---

## 2. Data model

### 2.1 `groups/{groupId}` — one new field

```
currency: string    // ISO 4217, e.g. "EUR". Admin-writable, absent == "EUR".
                    // Changing it re-labels past amounts; it never converts them.
```

### 2.2 `money_people/{personId}` — placeholders only

Real members are deliberately **not** stored here. The ledger's set of
identities is `active member uids` ∪ `placeholder ids`, so there is nothing to
keep in sync when somebody joins or leaves — no mirror collection, no trigger,
no drift.

```
name: string                    // typed by whoever added them
createdAt: timestamp
createdBy: string (uid)
claimedBy: string (uid) | null  // set when the real person joins and picks themselves
claimedAt: timestamp | null
archived: bool                  // hidden from new-expense pickers; history kept
```

**Claiming never rewrites history.** Entries keep referencing the placeholder id
forever; balances are computed over *resolved* identities:

```dart
String resolve(String personId) => people[personId]?.claimedBy ?? personId;
```

That makes claiming a single-document, idempotent, **reversible** write. It also
means one member can absorb several placeholders (somebody typed "Lisa" twice)
just by both pointing at them.

Resolution is always exactly one hop: the rules only ever allow `claimedBy` to
name an active full member, so a placeholder can never point at another
placeholder.

### 2.3 `money_entries/{entryId}` — expenses and payments together

```
type: "expense" | "settlement"
description: string             // "" for settlements
amount: number (int)            // minor units, > 0
currency: string                // copy of the group currency at entry time
date: timestamp                 // when it happened; user-editable
category: string                // optional: groceries|eatingOut|home|utilities|
                                //   transport|travel|fun|health|gifts|other
note: string                    // optional free text
image: string                   // optional; Storage path of the attached photo
paidBy: map<personId, int>      // who put money in; sums to amount
splitMode: string               // equal|shares|percent|exact|adjustment|settlement
splitInput: map<personId, num>  // the RAW user input for that mode
owes: map<personId, int>        // the COMPUTED shares; sums to amount
createdAt, createdBy, updatedAt, updatedBy
```

A settlement is simply `paidBy: {from: amount}`, `owes: {to: amount}` — one
person put the money in, exactly one consumed it. That is why it needs no
separate collection, no separate rules and no separate balance arithmetic.

Storing **both** the intent (`splitMode` + `splitInput`) and the result (`owes`)
is deliberate:

- `owes` makes balance computation a plain sum — the split logic is never re-run
  per expense, so two app versions can never disagree about an old share.
- `splitInput` lets the edit screen reopen in the same mode with the user's
  original numbers, and lets the detail screen say "2 shares" or "+€3.00 on top".
- `Σ paidBy == amount == Σ owes` is the invariant that makes balances sum to
  zero. See §3.3 for where it is enforced.

Receipt photos live at
`groups/{groupId}/money_entries/{entryId}/{millis}.jpg`, which is why the entry
id is reserved (`entriesRef.doc().id`) before the document is written.

### 2.4 Indexes

Both reads are `orderBy('date', descending: true)` with no inequality filter, so
single-field indexes suffice. `firestore.indexes.json` is unchanged.

---

## 3. Security rules

`firestore.rules` gains `currency` in the group's admin allowlist, two helpers,
and two `match` blocks.

### 3.1 Placeholders

Any full member may create one — whoever enters an expense may need to name
somebody outside the group. Claiming is the guarded part:

- you may only ever point a placeholder at **yourself**, and only while nobody
  has claimed it;
- admins may re-assign or clear a claim (the fix for a mis-claim);
- `claimedBy` must always name an **active full member**, which is what keeps
  resolution one hop deep;
- deleting is admin-only, because a placeholder with history would leave
  orphaned references. Everybody else gets "archive".

### 3.2 Entries

Members read and create; edits and deletes are limited to the author or an
admin. `createdAt` / `createdBy` are immutable, since they are exactly what
those permissions are based on. `validMoneyEntry()` checks types, ranges, key
counts and the `splitMode` / `type` enums.

### 3.3 The one thing rules cannot check

The rules language has no fold over a map's values, so
`Σ paidBy == amount == Σ owes` **cannot be expressed** without a Cloud Function.
Three things cover that gap:

1. **The threat model.** Everyone who can write here is already a full member
   who could just as easily delete the entire shopping list. A malformed
   document is not the interesting attack.
2. **It is enforced on read.** `MoneyEntry.isValid` re-checks the sums as each
   entry is parsed. Anything that fails is excluded from every balance and shown
   in the UI as a broken row with a link to fix it — so the *displayed* ledger is
   always consistent regardless of what is *stored*.
3. **It can be hardened later.** An `onDocumentWritten` function that recomputes
   the sums and stamps `invalid: true` is about two dozen lines and needs no
   client change.

### 3.4 Storage

`storage.rules` gains one line under the existing
`groups/{groupId}/{collection}/{itemId}/{photoId}` block:

```javascript
allow read, write: if isFullGroupMember() && collection == 'money_entries';
```

Full members only in **both** directions — unlike recipes, there is no reason
for a recipe viewer or an invite preview to see what the group spent.

---

## 4. Split modes and rounding

| Mode | Input | Meaning |
|---|---|---|
| `equal` | `{pid: 1}` | Split evenly among the people ticked |
| `shares` | `{pid: 2, …}` | Integer weights — "the couple counts double" |
| `percent` | `{pid: 3333}` | Basis points. Must total exactly `10000` |
| `exact` | `{pid: 1250}` | Minor units. Must total exactly `amount` |
| `adjustment` | `{pid: 300}` | Fixed extras; the remainder is split evenly |

`equal`, `shares` and `percent` are the same computation with different weights;
`adjustment` is `exact` after one preprocessing step. So exactly **one**
function ever turns money into shares:

```dart
Map<String, int> splitByWeights(int amount, Map<String, int> weights, {String seed});
```

### Largest-remainder method

```
W       = Σ wᵢ
baseᵢ   = (amount × wᵢ) ~/ W
remᵢ    = (amount × wᵢ) %  W
R       = amount − Σ baseᵢ
```

The `R` leftover units go one each to the largest remainders, tie-broken on
`fnv1a(seed|personId)`. The expense id is the seed, so the split is
deterministic across devices but the extra cent **moves between expenses**
instead of always landing on whoever sorts first:

```
€10.00 / 3, expense "e1"  →  334, 333, 333
€10.00 / 3, expense "e2"  →  333, 334, 333
€25.00, shares 2:1:1      →  1250, 625, 625
€100.00, 33.33/33.33/33.34 →  3333, 3333, 3334
```

The hash is hand-rolled (32-bit FNV-1a, ~8 lines) on purpose: a package upgrade
must never be able to change how an old expense splits.

Somebody with weight `0` can never receive a leftover unit — their remainder is
0, and `R` is always strictly smaller than the number of non-zero remainders,
since each `remᵢ < W` and `Σ remᵢ = R × W`.

---

## 5. Balance engine

```
net[resolve(p)] += paidBy[p]
net[resolve(p)] -= owes[p]
```

Positive means they are owed. `Σ net == 0` by construction.

Alongside the net figures, `buildLedger` decomposes each entry into concrete
debtor → creditor edges and records which entry produced each one. That
provenance is what the settle-up screen's "what does this cover?" expander
reads. Opposite directions of a pair are then cancelled, so "you owe Anna
€12, Anna owes you €5" becomes "you owe Anna €7".

The client keeps one snapshot listener on `money_entries`. Firestore persistence
is already on with an unlimited cache, so a cold start reads from disk and only
deltas come over the wire.

---

## 6. Settle up — the fewest possible payments

### The problem

If the `n` people with a non-zero balance can be partitioned into `k` disjoint
zero-sum subsets, the minimum number of payments is exactly **`n − k`**: a
zero-sum subset of size `m` always settles internally in `m − 1` payments.
Maximising `k` is NP-hard (it reduces from subset-sum). That is also why the
"biggest debtor pays biggest creditor" greedy in most tutorials is **not**
optimal — it never notices that `{+50, −20, −30}` settles as a group.

### Three tiers, each checked by the next-simpler one

**Tier 0 — cancel exact opposite pairs.** A zero-sum *pair* can always be part
of some optimal partition, so this never costs optimality; it usually empties
the problem entirely for a two-person household. (Verified by exhaustive
comparison against the exact optimum over 20 000 random small-value cases.)

**Tier 1 — exact optimum**, for the remaining `n ≤ 14`. Bitmask DP:

```
dp[mask] = max over submasks S of mask containing the lowest set bit,
           where sum[S] == 0, of  1 + dp[mask ^ S]
answer   = n − dp[full]
```

Fixing the lowest set bit halves the enumeration. `3¹⁴ ≈ 4.8M` cheap integer
operations — comfortably inside a frame budget even in a debug build, and after
Tier 0 real groups are almost always far below that. The plan is computed once
per screen, not per build.

**Tier 2 — greedy fallback**, above 14 or if the DP cannot partition. Yields at
most `n − 1` payments and, across 4 000 randomised trials, was never more than
**one** payment worse than the optimum. The screen says "N payments clear
everything" instead of "…the fewest possible" when this path was used.

### The self-check

Before the plan is returned, applying it must zero every balance and every
payment must be positive and between two different people. If that fails, the
greedy plan is returned instead — the clever path is always validated by the
obvious one, so a wrong plan cannot reach the screen.

Every sort has an explicit tie-break on person id, so all devices render
byte-identical plans regardless of map iteration order.

### The honesty problem, and the expander

Splitwise's own three rules for simplification are: everyone owes the same net
amount at the end; nobody owes a person they didn't owe before; nobody owes more
in total than before. **Minimising transactions is incompatible with the second
one** — consolidating necessarily creates payments between people who never
transacted.

Since the settle-up screen shows only the simplified plan, every payment is
expandable into the payer's actual, un-simplified position:

```
You pay Ben                                    €8.00
  ▸ What does this cover?
      You owe Anna                            €12.00
        Groceries · €8.00
        Cinema · €4.00
      Chris owes you                         − €4.00
        Pizza · €4.00
```

That single expander removes the biggest source of "why does the app say I owe
someone I've never bought anything with".

---

## 7. Placeholders and claiming

**Creating.** The person picker on the add-expense screen lists everyone
selectable; the People screen has "Add person".

**Claiming.** When a member opens the Money tab and the group has an unclaimed,
non-archived placeholder they have not dismissed, a non-blocking banner appears:
*"Are you one of these people?"* with a chip per name and a "None of these".
Tapping a name writes `claimedBy`, and every expense that referenced the
placeholder is instantly attributed to them — no migration, no batch write.
"None of these" sets a per-group flag in `SharedPreferences`.

A banner rather than a modal on join, deliberately: no new navigation plumbing
in `main.dart` or `join_group_page.dart`, it survives being dismissed by
accident, and it comes back when a *new* placeholder is added.

**Admin override.** The People screen lets an admin link a placeholder to any
member, unlink it, rename or archive it. Unlink is a plain `claimedBy: null`
write — reversible precisely because claiming never rewrote anything.

| Edge case | Behaviour |
|---|---|
| Two placeholders claimed by one member | Both resolve to that uid, balances merge — correct, the same person was entered twice |
| Claimer later leaves the group | Still resolves to their uid; they appear in balances as a former member. The rule only validates membership *at claim time* |
| Member leaves owing money | Still in balances and in the settle-up plan, marked "no longer in the group" |
| Placeholder deleted despite history | Blocked in the UI (archive instead). If forced, `resolve` falls through to the raw id and they render as "Someone" — never a corrupted sum |
| Archived person on an old expense | The edit form still renders their row: the participant list is `selectable ∪ everyone the entry already touches` |

---

## 8. Screens

| Screen | What it does |
|---|---|
| **Money tab** | Headline net ("You are owed €42.10"), balances list, activity feed grouped by month, claim banner, invalid-entry banner, FAB |
| **Add / edit expense** | Description, amount, date, category, paid-by (single chip row or several payers with a live remaining counter), split mode + per-person inputs with a live per-person preview in real money, note, photo |
| **Entry detail** | Who paid, the full split with the raw input behind each share, note, photo, edit and delete |
| **Settle up** | The minimal plan, each payment expandable into its derivation, "Mark as paid", plus a manual "Record a payment" |
| **Person detail** | One person's net and every entry they appear in |
| **People** | Members and placeholders, add / rename / archive / link / unlink |
| **Money settings** | Group currency (admin only, with the "does not convert" warning) |

Stock Material widgets throughout — `ListTile`, `CheckboxListTile`,
`ChoiceChip`, `ExpansionTile`, `showDatePicker`, `showModalBottomSheet`. The
Save button stays disabled while a mode's constraint is unmet, and says why in
real money: *"€3.40 left to assign"*, *"2.5% still to assign"*.

---

## 9. Files

```
lib/features/money/
  money_context.dart             // the bundle handed to every screen
  models/
    split_mode.dart              // the five modes + the settlement shape
    money_person.dart            // placeholders + MoneyDirectory (identity resolution)
    money_entry.dart             // one ledger row; isValid holds the invariant
    money_category.dart
  services/
    split_calculator.dart        // splitByWeights + per-mode preprocessing + validation
    balance_engine.dart          // entries → net balances, pairwise debts, provenance
    settlement_solver.dart       // tiers 0-2 + the self-check
    money_format.dart            // minor units ⇄ display, and parsing back
    money_repository.dart        // the only file that knows about Firestore
  pages/
    money_page.dart  add_expense_page.dart  entry_detail_page.dart
    settle_up_page.dart  person_detail_page.dart  money_people_page.dart
    money_settings_page.dart

test/
  money_split_calculator_test.dart
  money_balance_engine_test.dart
  money_settlement_solver_test.dart
```

Touched: `lib/main.dart`, `lib/features/auth/pages/onboarding_page.dart`,
`firebase/firestore.rules`, `firebase/storage.rules`.

Everything except `money_repository.dart` and the pages is plain Dart with no
Firebase types, which is what makes the tests possible.

No new package dependencies. `money_format.dart` is hand-rolled rather than
pulling in `intl` — decimals, symbol, prefix/suffix convention and both decimal
separators, in about 120 lines.

---

## 10. Tests

`flutter test test/money_*.dart`

- **Split**: the four golden cases; a 20 000-case property test (sums exactly,
  never negative, weight 0 → share 0); determinism per seed and rotation across
  seeds; every validation rejection.
- **Balances**: `Σ net == 0`; opposite pair debts cancel; provenance is
  recorded; multi-payer entries balance; broken entries are excluded *and*
  reported; claiming merges history and unclaiming splits it back; two
  placeholders claimed by one member merge.
- **Settle up**: a 3 000-ledger property test asserting the plan settles
  everyone, nobody overpays, and **the length equals a brute-force optimum**
  computed independently in the test; the `{+50, −20, −30}` case greedy gets
  wrong; the greedy fallback path; determinism against map ordering.

---

## 11. Deploy

```bash
firebase deploy --only firestore:rules,storage
```

Both rule files changed; no functions and no indexes did.

---

## 12. Next step — receipt scanning

The natural follow-on, and the model already fits it.

**The shape.** A sixth `splitMode: "items"` whose `splitInput` is a line-item
list — `[{label, amount, people: [personId]}]` — plus tax and tip apportioned
across the items. `resolveShares` gains one preprocessing branch that folds the
items into exact per-person amounts; everything downstream (`owes`, balances,
settle-up, the detail screen) is unchanged because it only ever reads `owes`.

**The pipeline.** The photo already reaches Storage today. Add a callable, e.g.
`money-scanRecipt`, following the exact pattern of `generateRecipeStaged`:
`onCall` in `europe-west1`, the image passed as base64 (downscaled client-side —
`recipe_photos.dart` already has `_downscaleToJpeg` and the payload helper),
structured output against a JSON schema like `recipes/schema.ts`, cost booked
through `lib/aiUsage.ts` with its own operation label, entitlement checked
through `lib/aiAccess.ts` so it lands inside the existing tier system rather
than beside it.

**What it returns**: `{merchant, date, currency, total, tax, tip, items: [{label, amount}]}`.

**The UI.** Scan runs from the add-expense screen's photo button ("Scan
receipt"), fills description / amount / date, and opens an item list where each
line is assigned to people with the same chip picker the split editor already
uses. Anything unassigned falls back to the current split mode, so a half-tagged
receipt is still a valid expense.

**Worth deciding before starting**: whether a mis-read total should be
correctable without re-scanning (yes — treat the scan as *prefill*, never as
authority), and whether the scan result is stored on the entry for re-editing
(probably `scan: {…}` alongside `image`, so re-opening the item assignment does
not need a second model call).

---

## Sources

- [Debts Made Simple — the Splitwise blog](https://blog.splitwise.com/2012/09/14/debts-made-simple/) — the three rules their simplification obeys, and their own warnings about it
- [LeetCode 465 "Optimal Account Balancing"](https://algo.monster/liteproblems/465) — the bitmask-DP formulation used in Tier 1
- [Settling Debts Efficiently: Zero-Sum Set Packing (Yao, Harvard senior thesis, 2017)](https://dash.harvard.edu/bitstream/handle/1/38811480/YAO-SENIORTHESIS-2017.pdf?sequence=3) — the NP-hardness result and the `n − k` characterisation
- [Algorithm Behind Splitwise's Debt Simplification Feature](https://medium.com/@mithunmk93/algorithm-behind-splitwises-debt-simplification-feature-8ac485e97688) — the graph framing and why naive greedy under-performs
