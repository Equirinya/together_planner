# Swipe-to-Plan deck curation — redesign plan

No AI anywhere. Everything below is deterministic Firestore reads + arithmetic,
same as today.

Target file: `firebase/functions/src/recipes/swipeSession.ts`.
Client (`swipe_session_service.dart`) needs no change except an optional new
`usageHint` wording.

---

## 1. The problem being fixed

The current mix step computes `wantPublic = deckSize - own.length`. A group with
more own recipes than the deck size (12–40) therefore never calls
`publicCandidates` at all, and the 60/40 own/public quota is dead code for every
group except brand-new ones. Public recipes are effectively absent from the pool.

Secondarily, own recipes are ranked on a single axis (recency of last cook), so
"the staples we love" and "the thing we cooked once in March and forgot" compete
in one list and the top of that list is dominated by whichever is older. There is
no explicit notion of *favourite*.

---

## 2. Target composition

Three buckets, each with its own quota, filled independently, then merged and
shuffled.

| Bucket | Meaning | Target share |
|---|---|---|
| **A — Loved staples** | Own recipes cooked repeatedly, but not in the cooldown window and not planned ahead | **55 %** |
| **B — Rare / rediscovery** | Own recipes never cooked, or cooked once, or last cooked long ago | **20 %** |
| **C — Public discovery** | Fitting public recipes, `category == "mainDish"` only | **25 %** |

Rounding: compute A and C with `Math.round`, give B the remainder, so the three
always sum to exactly `deckSize`.

### Hard exclusions (all buckets, unchanged in spirit)

- Blank/still-generating names.
- Own recipes with a `cooking_plan` entry for a future date (already committed).
- **New:** own recipes cooked within `HARD_COOLDOWN_DAYS = 7` are excluded
  outright rather than merely down-ranked. "Not cooked in the last few days" is
  the explicit requirement; a soft penalty lets them resurface when the
  collection is thin, which is exactly when the user notices it.
- Name-level dedup across buckets (lowercase, trimmed), public loses to own.

---

## 3. Signals

Read once, from the existing 120-day `cooking_plan` query (widen to 365 days so
`cookCount` is meaningful — it is a small collection and already one query):

For each own recipe id:

- `cookCount` — completed (past-dated) plan entries.
- `daysSince` — days since the most recent past-dated entry, `Infinity` if never.
- `futurePlanned` — boolean, excludes.
- `ageDays` — days since `createdAt`, for the new-recipe nudge.

There is no favourite/rating field on recipes today, so **"likes to cook" is
inferred from `cookCount`**. If a `favourite` boolean is added to the recipe doc
later, it slots in as `+2` on `loveScore` and nothing else changes.

### Bucket assignment

```
if (futurePlanned || daysSince < HARD_COOLDOWN_DAYS) -> excluded
else if (cookCount >= 2 && daysSince <= STALE_DAYS)  -> A (loved staple)
else                                                 -> B (rare / rediscovery)
```

with `STALE_DAYS = 120`: something cooked four times but not in four months is
a rediscovery, not a staple.

### Within-bucket ranking

**A — loveScore**, favour genuinely repeated recipes that have had time to
breathe:

```
loveScore = 2 * log(1 + cookCount)
          + min(daysSince, 60) / 60      // rested longer = riper, capped
```

**B — rareScore**, favour never-cooked and newly-added, so the bucket reads as
"you never gave this a chance" rather than "you rejected this":

```
rareScore = (cookCount === 0 ? 1.5 : 0)
          + min(daysSince, 365) / 365
          + (ageDays < 30 ? 0.5 : 0)     // recently added, never tried
```

**C** — hard-restricted to `category == "mainDish"`, since a swipe card fills a
dinner slot and a sauce or dessert is never a valid answer to it. The filter goes
in the *query*, not after the read, so pool sizing stays honest — anything
dropped afterwards is a document paid for and thrown away. Consequence: public
recipes predating the category field (`category: null`) never appear until the
admin category backfill has run over them.

Ranking within the bucket keeps the existing
`log(1 + popularity) + 4 if in season`, with two additions:

- exclude any public recipe whose name matches an own recipe (already done) *or*
  that the group has swiped **disliked** in the last 30 days (see §6);
- add `+1` if `time` is under the group's typical weekday cooking time — skip for
  now, flagged as a later refinement.

---

## 4. Adaptive rebalancing

The quotas are targets, not guarantees. Fill in this order and let each shortfall
cascade:

1. Fill **A** up to `quotaA`. Shortfall `sA = quotaA - |A taken|`.
2. Fill **B** up to `quotaB + sA`. Shortfall `sB`.
3. Fill **C** up to `quotaC + sB`. Shortfall `sC`.
4. If `sC > 0` (public corpus too thin), go back and top up A then B with
   whatever is left over.
5. If the deck is *still* short of `MIN_DECK`, relax in this order, each step only
   as far as needed:
   a. drop the `HARD_COOLDOWN_DAYS` exclusion to 3 days;
   b. re-admit future-planned recipes;
   c. relax the public dietary hard filter (existing behaviour).

This is the "adapt to needed vs. available" requirement: a group with 4 recipes
gets a mostly-public deck, a group with 200 gets the full 55/20/25, and neither
path is special-cased — it falls out of the cascade.

### The public switch is absolute

`includePublic: false` means bucket C is empty, full stop — the quota folds back
into A and B and, if the group's own recipes can't cover it, **the deck is simply
shorter**. There is no thin-collection padding: silently mixing the corpus back
in to hit a target size would make the switch a suggestion rather than a setting.

The setup page compensates by warning *before* the session starts, comparing the
group's recipe count (a count aggregation, not a read of every doc) against
`swipeDeckSize(days)`. The threshold uses the total count even though the server
also drops recently-cooked and already-planned recipes, so the warning
under-fires rather than crying wolf.

### Sizing the fetch

`publicCandidates(dietary, want)` must be called with
`want = quotaC + expected shortfall`, **never** `deckSize - own.length`. Concretely:

```ts
const wantPublic = includePublic ? quotaC + Math.ceil(deckSize * 0.15) : 0;
```

The 15 % head-room absorbs dedup losses. Keep the existing
"pad with public even when the toggle is off if `own.length < THIN_COLLECTION`"
rule as a floor.

---

## 5. Constants

```ts
const HARD_COOLDOWN_DAYS = 7;   // not cooked in the last few days
const STALE_DAYS         = 120; // beyond this a staple counts as rediscovery
const HISTORY_DAYS       = 365; // widened from 120
const SHARE_LOVED        = 0.55;
const SHARE_PUBLIC       = 0.25;
// B gets the remainder
```

All exported for the unit tests in §7.

---

## 6. Randomness in the public bucket

Today there is **none** that affects *membership*. `publicCandidates` sorts by
`log(1 + popularity) + 4 if in season` and the mix step takes the head of that
list; the seeded Fisher-Yates shuffle only randomises the *order cards are shown
in*, not which cards are in the deck. The no-dietary fallback is worse — it is
`orderBy("createdAt", "desc")`, so it returns literally the same newest slice of
the corpus every single time. Two sessions a week apart see an identical set of
public recipes.

Fix: **weighted sampling without replacement**, seeded from the session seed so
the deck stays a reproducible pure function of `deckSeed`.

1. Widen the fetch: `limit = max(120, want * 8)`. Reads are cheap and this is the
   pool we sample from.
2. On the no-dietary path, replace `orderBy("createdAt", "desc")` with a
   random-cursor read over the existing `random` field (0..1, already written at
   creation by `publicRecipes.ts` and `generatePublicRecipeStaged.ts` — no
   backfill needed):

   ```ts
   const r = next();                       // from rng(seed), not Math.random()
   let snap = await col.where("random", ">=", r).orderBy("random").limit(n).get();
   if (snap.size < n) {                    // wrap around the end of the corpus
     const more = await col.where("random", "<", r).orderBy("random")
       .limit(n - snap.size).get();
     docs = [...snap.docs, ...more.docs];
   }
   ```

   Without this, step 1 still only ever sees the same newest N documents.
   On the **dietary** path keep `array-contains-any searchTokens` and do the
   sampling in step 3 over the widened result — adding `orderBy("random")` there
   would need a composite index (`searchTokens` array + `random`) and would bias
   toward whichever tokens sort first. Only add that index if the widened fetch
   proves too narrow in practice.
3. Sample `quotaC` cards using Efraimidis–Spirakis: for each candidate compute
   `key = rand() ** (1 / weight)` with `weight = exp(rank)`, take the top
   `quotaC` by key. Popular and in-season recipes stay likelier, but nothing is
   guaranteed a slot and the long tail is reachable.
4. `rand()` comes from `rng(deckSeed)`, not `Math.random()`, so the deck remains
   reproducible from the stored seed.

Bucket **B** (rare/rediscovery) gets the same treatment for the same reason — it
otherwise offers the same forgotten recipes every week until one is cooked.
Buckets **A** and the exclusions stay strictly deterministic.

---

## 7. Dislike memory

Every finished session already stores per-user `dislikes` against `cardId`.
Read the group's **last 5** non-open sessions (committed, cancelled or expired),
collect the card ids disliked by *every* participant who voted in that session,
and suppress them.

- Suppression window: 30 days, or until the card has been skipped in 5 sessions —
  whichever comes first, so nothing is banished permanently.
- Applies to public cards as a hard filter, and to own cards as a rank penalty
  only (`-1.5`) — the group owns those recipes deliberately, so a bad night
  shouldn't erase one from their own deck.
- A card disliked by only *some* participants is not suppressed; that is a
  disagreement for the vote to resolve, not a signal about the recipe.
- Cost: 5 session doc reads plus their `votes` subcollections. Fetch in parallel
  with `ownCandidates`/`publicCandidates` so it adds no wall-clock latency.
- Store the resulting set on the session doc as `suppressed: string[]`, purely so
  the behaviour is debuggable after the fact.

---

## 8. Verification

Extract the pure parts so they are testable without Firestore:

- `classifyOwnRecipe(signals) -> "A" | "B" | "excluded"`
- `loveScore(signals)`, `rareScore(signals)`
- `composeDeck({a, b, c, deckSize}) -> DeckCard[]` — the cascade in §4

Node tests to add under `firebase/functions/test/`:

1. 200 own recipes, healthy public corpus → deck is ~55/20/25, ±1 card.
2. 3 own recipes → deck is mostly public, still reaches `MIN_DECK`.
3. Empty public corpus → deck is 100 % own, no crash, quotas absorbed.
4. Every own recipe cooked yesterday → cooldown relaxation kicks in, deck is not
   empty.
5. A recipe planned for next Tuesday never appears.
6. Same seed → identical deck (determinism is load-bearing for the ranking).
7. Different seeds over 20 runs → the public bucket's membership varies, and a
   low-popularity recipe appears at least once.
8. A public recipe disliked by everyone in the last 5 sessions never appears; an
   own recipe in the same position still can, just lower.

---

## 9. Changes outside this file

The `random` field §6.2 relies on already exists on `public_recipes` and is
populated on every write path — no backfill. But the `category == "mainDish"`
filter turns both public queries into composite ones, so
`firestore.indexes.json` gains two entries:

| Collection | Fields |
|---|---|
| `public_recipes` | `category` ASC, `random` ASC |
| `public_recipes` | `category` ASC, `searchTokens` CONTAINS |

Deploy these **before** the function (`firebase deploy --only firestore:indexes`).
Until they exist the public query throws; `createSwipeSession` catches it, logs
at error level and falls back to an own-only deck, so the feature degrades
rather than breaking.

`usageHint` already carries "Never cooked" / "Cooked Nx"; consider
adding "A while ago" for bucket B so the card explains why it is being offered.
