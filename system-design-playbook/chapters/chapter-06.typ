// ============================================================================
//  CHAPTER 6 — Designing a Top-K Leaderboard (Gaming)
//  Source: "17: Top K Leaderboard" — Systems Design Interview Questions With
//  Ex-Google SWE (channel: Jordan has no life)
//  Link: https://www.youtube.com/watch?v=nQpkRONzEQI
// ============================================================================

#import "../template.typ": *

= Designing a Top-K Leaderboard

#notebox([Problem source])[
  This chapter solves the problem posed in the talk _"17: Top K Leaderboard"_
  from the series _Systems Design Interview Questions With Ex-Google SWE_
  (channel: _Jordan has no life_). The task: design the leaderboard system of
  a hit online game — millions of players submit scores after every match,
  and the service answers "who are the top K?" and "what is *my* rank?" in
  milliseconds, on boards that reset daily, weekly, and run all-time. The
  challenge is not volume but a very specific primitive — *rank as a
  first-class query* over an ordered set that mutates 25,000 times a second.
  All terms are defined before use; all reference code is Rust with
  deterministic tests.
]

== The Problem Statement

The interviewer sketches a phone screen — a podium of three avatars, a
scrolling list below, and a highlighted row pinned at the bottom:
*"You: rank 1 247 003"* — and says:

_"Players finish matches and submit scores. Players can view the global top
100, page deeper, and always see their own rank and neighborhood even when
they are a million places down. Boards exist per season and all-time. Ties
go to whoever got the score first. Design it."_

This problem looks small next to Chapters 2–5 — and that is the trap, so
let's spring it deliberately and see what's inside. The arithmetic is gentle
(Section 6.5 will show the entire dataset fits in one machine's RAM); no
firehose, no petabytes, no exotic geography. But look at the phone screen
again, specifically at that pinned bottom row: *"You: rank 1 247 003."*
Somebody a million places from the podium opens the app and expects their
*exact* position — not an estimate, not a percentile band — in the time it
takes the screen to render. Now combine that with the other headline query,
top-100, and with the write side mutating the ordering 25,000 times a
second. The difficulty is that both queries are *positional* — they are
about where an entry sits inside a total order — and positional queries
over a hundred-million-entry order that never stops moving are exactly the
queries ordinary databases are worst at. Choose the wrong structure and
either the reads or the writes eat the system. Choose the right one and most
of the chapter becomes careful engineering around it: windows, ties,
sharding, and cheating.

#defterm([Leaderboard / rank / top-K])[
  A _leaderboard_ is an ordering of players by score within some scope (a
  game, a season, a region, a friend group). A player's _rank_ is their
  1-based position in that ordering. A _top-K_ query returns the first K
  entries in order. The pair {top-K, rank} is the complete query surface —
  every UI screen is one or the other.
]

That last claim is worth testing against the sketched screen, because it
collapses the product into two primitives. The podium and the scrolling
list: top-K with paging. The pinned "you are here" row: rank, plus a small
walk in both directions (the *neighborhood*, FR-4). Profile badges like "top
2.3%": rank divided by board size — a derived form of rank. There is no
third query. When a whole product surface reduces to two operations, your
entire design conversation can — and should — be about serving those two
operations well. Scope discipline starts with noticing how small the real
surface is.

#defterm([Best-score vs. every-run boards])[
  Two admission semantics. _Best-score_: a player occupies exactly one slot,
  holding their personal best; a worse new score changes nothing. _Every-run_
  (arcade-style): each match is its own entry and one player may hold many
  slots. We design best-score — the common default — and note where
  every-run differs (Section 6.10).
]

== Scope & Clarifying Questions

The prompt is short but leaves four genuinely load-bearing ambiguities —
score semantics, tie-breaking, freshness, and board lifecycles — and the
dialogue below closes each one. Watch for the tie-break answer especially:
"whoever got the score first" sounds like a footnote and will end up
*inside the ordering key* in Section 6.7.

#tbl(
  (auto, 1fr),
  header: (hcell[Candidate asks], hcell[Interviewer answers]),
  body: (
    [Score semantics?], [Personal best per player per board; ties broken by who achieved it first],
    [Which boards?], [Global all-time, plus daily and weekly; same game, one platform],
    [Rank granularity?], [Exact rank for the querying player; "top X%" displays for everyone are fine approximate],
    [Freshness?], [A submitted score should be reflected in rank/top-K within ~5 seconds],
    [Live updates?], [No push; clients poll or refresh. The list may change between pages — acceptable],
    [Anti-cheat?], [Hook it in; don't design it. Suspicious scores can be quarantined],
    [Scale?], [~20M daily players, ~200M matches/day, 200M registered accounts],
    [Friends boards?], [Yes — a player vs. their friends (≤ a few hundred)],
    [Score range?], [Non-negative integers, 0 to ~10⁹],
  ),
)

Three of these answers are quiet gifts. "Rank granularity: exact for the
querying player, approximate for displays" splits the rank query into a
*trusted* variant (yours, exact, screenshotted, argued about) and a
*glanced-at* variant (percentile badges nobody audits) — Section 6.11 will
turn that split into an enormous cost saving. "No push; polling is fine"
keeps Chapter 1's entire real-time machinery on the shelf, again. And "~5
seconds of freshness" is the permission slip for the asynchronous ingestion
pipeline of Section 6.9 — a score that must be visible *instantly* would
force synchronous coupling between match servers and rank storage; five
seconds buys you a queue, and with the queue comes burst absorption,
replayability, and an anti-cheat tap, all for free.

#notebox([Agreed scope])[
  + *Submit score* after each match; best-score semantics per player per
    board; ties to the earliest achiever.
  + *Top-K* with cursor paging (K ≤ 100 per page).
  + *My rank* — exact, fast, at any depth, plus a neighborhood view (the ±r
    players around me).
  + *Time-windowed boards* — daily/weekly boards rotate; all-time persists.
  + *Friends leaderboard* — my standing among my friend list.
  + *Anti-cheat quarantine* hook on the ingestion path.
  + Out: live push, team boards, tournaments, cross-game boards.
]

== Functional Requirements

One definition first — the query that makes this problem famous, and the one
that quietly demands the most of your data structure:

#defterm([Neighborhood query])[
  The ±r entries around a given player's rank — the "you are here" view. It
  is the query that makes the problem famous: it requires *rank* (to locate
  the player) and *ordered iteration* (to walk r places in both directions),
  at any depth in the ordering, in milliseconds.
]

Read that definition as a two-stage rocket, because each stage eliminates
different candidate structures. Stage one: locate the player — that needs a
by-key lookup *and* their position in the order, two different kinds of
access fused. Stage two: walk r places outward — that needs the order to be
*iterable* from an arbitrary interior point, not just from the top. A hash
map fails stage one's second half (it has no positions). A heap fails stage
two entirely (it can iterate only by destroying itself). Keep both stages in
mind when Section 6.6 walks the candidate structures — the neighborhood
query is the examiner.

+ *FR-1 — Submit score.* `(player_id, score, achieved_at, match_id)` per
  board scope; stored if it beats the player's current best; idempotent under
  retries and duplicate match reports.
+ *FR-2 — Top-K page.* Ordered entries `(rank, player, score)` from a cursor,
  per board.
+ *FR-3 — Player rank.* Exact rank and score for one player on one board.
+ *FR-4 — Neighborhood.* The ±r window around a player, ranks included.
+ *FR-5 — Windowed boards.* Daily/weekly/all-time boards of the same game,
  rotating automatically, old windows archived read-only.
+ *FR-6 — Friends board.* Top-K/rank restricted to a player's friend set.

Notice how FR-1 packs three guarantees into one line, and each will resurface
as machinery. "Stored if it beats the player's current best" is *best-score
admission* — Section 6.10 shows it makes the whole write path monotonic.
"Idempotent under retries" is Chapter 5's lesson arriving on schedule — but
with a twist: here the idempotency comes from the *semantics* (`max` is
naturally idempotent), not from a dedup table, and Section 6.10 will make
you appreciate the difference. And `match_id` riding along in the tuple is
the dedup hook for the one failure mode `max` cannot absorb: the *same
match* reported twice with the *same* score.

== Non-Functional Requirements

The NFRs for this problem hinge on a vocabulary word most candidates have
never needed — so define it before the table, because the table assumes it:

#defterm([Order-statistics query])[
  A query about *position* in an ordering — "rank of X", "the k-th element",
  "count of entries above Y" — as opposed to a lookup by key. Supporting
  order statistics efficiently under inserts/deletes requires an ordered
  structure augmented with subtree/span counts (Section 6.7); plain hash
  indexes cannot answer them at all, and plain sorted scans answer them at
  O(n).
]

This definition is the chapter in embryo. Hash indexes answer "what is X's
value?" — they are blind to position. Sorted arrays know position but charge
O(n) to mutate. The question the whole interview pivots on is whether you
know there exists a family of structures that tracks position *as an
invariant*, maintained incrementally on every insert and delete, so that
rank queries read out a precomputed answer instead of recomputing one.
Augmentation — storing extra derived data inside a structure's nodes and
repairing it locally on each mutation — is the technique, and Section 6.7's
skip list is its friendliest form.

#tbl(
  (auto, 1fr),
  header: (hcell[Requirement], hcell[Target & reasoning]),
  body: (
    [Score ingest throughput], [25k updates/s peak sustained; a launch event may 5× that briefly],
    [Top-K read latency], [p95 ≤ 50 ms (cached pages: ≤ 10 ms); it is a hot UI surface],
    [Rank / neighborhood latency], [p95 ≤ 100 ms at 10⁸-entry boards — this kills naive designs],
    [Freshness], [Score → visible in rank/top-K ≤ 5 s; rank need not be transactional with the match],
    [Durability], [A confirmed personal best must survive node loss (replication + journaling)],
    [Availability], [Reads ≥ 99.99% (stale board pages acceptable); writes ≥ 99.9%],
    [Integrity], [One slot per player per board; ties deterministic; quarantined scores never render],
  ),
)

The third row carries the phrase "kills naive designs" — take it seriously
as a filtering device. A hundred milliseconds at 10⁸ entries sounds generous
until you price the naive approach: computing rank by counting better
entries scans, on average, half the board — fifty million rows — per query,
thousands of times per second. You are not 10× off; you are *five orders of
magnitude* off. When an NFR misses feasibility by that margin, the fix is
never tuning — it is a different data structure. That is why this chapter's
architecture section is shorter than its data-structure section, inverting
the book's usual proportions.

#insight([Reads and writes are both modest — the *operation mix* is the design])[
  Nothing here rivals Chapter 4's firehose or Chapter 5's vote storm. What is
  unusual: the system must maintain a *total order* over 10⁸ entries, mutate
  it 25k times a second, and answer positional queries — top-K, rank,
  neighborhood — in milliseconds. Data structure choice *is* the
  architecture; everything else is distribution plumbing around one ordered
  set.
]

== Back-of-the-Envelope Estimation

Run the numbers anyway — gently, this time — because two of them will hand
you the central design license.

*Assumptions*: 20M daily players; 10 matches per player per day; every match
submits one score; each player opens leaderboard surfaces ~5×/day; a board
entry is ~100 B with index overhead.

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Quantity], hcell[Estimate], hcell[Derivation]),
  body: (
    [Score submissions], [200M/day ≈ 2.3k/s avg, ~25k/s peak], [20M players × 10 matches; evening × event multiplier ≈ ×10],
    [Leaderboard reads], [100M/day ≈ 1.2k/s avg, ~12k/s peak], [20M × 5 views; top-K pages + rank lookups],
    [Global all-time board], [~20 GB in RAM], [200M players × ~100 B (id, score, ts, structure overhead)],
    [Daily board], [~2 GB], [20M active × ~100 B; born and dies daily],
    [Top-100 page], [~5 KB JSON], [100 × (id, name ref, score, rank)],
    [Update cost], [~27 pointer hops], [log₂(2×10⁸) ≈ 27 — the ordered set makes writes cheap],
    [Snapshots], [~20 GB/board, minutes to write], [Sequential dump; recovery = snapshot + journal replay],
  ),
)

The update-cost row is worth a slow read: log₂(2×10⁸) ≈ 27 means that even
on the all-time board, applying a score change touches about twenty-seven
nodes — microseconds of work. Writes are not the problem. Reads of the
podium are not the problem either (5 KB from the top of an ordered
structure). The *only* expensive questions are the positional ones — which
is the estimation table independently confirming Section 6.4's warning from
a second direction. When your arithmetic and your NFR analysis point at the
same bottleneck, you have found the real problem.

#insight([The whole working set fits in RAM — spend it])[
  20 GB for the all-time board is one machine's RAM, or a few shards' worth.
  That licenses the chapter's central decision: keep boards *in memory* in a
  purpose-built ordered structure with O(log n) everything, replicate for
  reads and failover, journal for durability. A disk-first database would
  answer the same queries 10–100× slower for zero capacity benefit. Capacity
  is solved; latency and structure are the game. Say this sentence in the
  interview exactly as written — "the working set fits in RAM, so the design
  should be memory-native with durability bolted on, not disk-native with
  caching bolted on" — and watch the interviewer nod: it is the correct
  first move for a whole family of problems (session stores, real-time
  bidding, matchmaking) that candidates routinely over-persist.
]

The flow of the chapter: Section 6.6 isolates why rank is the crux; 6.7 picks
the data structure (with the skip-list mechanics drawn out); 6.8–6.9 design
APIs and architecture; 6.10–6.12 go deep on ingestion semantics, sharded
top-K, and windowed/friends boards; 6.13 implements it all in Rust; 6.14–6.20
scale, harden, and review.

== The Core Challenge: Rank Is Not a Lookup

Strip the product away and the service is one abstract data type with four
operations: `upsert(player, score)`, `top(k, cursor)`, `rank(player)`,
`neighborhood(player, r)` — under 25k mutations/s and 12k queries/s, on a
collection of 10⁸. Now do the exercise that this entire interview exists to
elicit: walk the candidate structures you already know, and *fail them in
order*, saying out loud why each one dies. The walk is the answer — the
destination is just the last structure standing:

#tbl(
  (1.15fr, 0.62fr, 0.85fr, 1.05fr, 1.6fr),
  header: (hcell[Structure], hcell[upsert], hcell[top-K], hcell[rank(player)], hcell[Verdict]),
  body: (
    [Hash map], [O(1)], [O(n log n)], [O(n log n)], [Rank does not exist; every query re-sorts 10⁸ entries],
    [Sorted array], [O(n)], [O(K)], [O(log n) by score], [Reads fine; O(n) write shifts ruin 25k updates/s],
    [B-tree index (DB)], [O(log n)], [O(log n + K)], [O(n) count scan], [The classic wrong answer — see below],
    [Heap], [O(log n)], [O(K log n)], [unsupported], [No rank, no paging; wrong shape entirely],
    [Skip list + hash map, spans], [*O(log n)*], [*O(log n + K)*], [*O(log n)*], [Ordered, rank-augmented, in-memory — Section 6.7],
  ),
)

Narrate the eliminations. The *hash map* fails not on speed but on
expressiveness: it has no concept of order, so every rank or top-K question
degenerates into "sort the universe, then look." The *sorted array* is the
mirror image — position is free (binary search!), but a single score update
can shift half the array's elements one slot over, and 25,000 such shifts
per second is an earthquake that never stops. The *heap* is the structure
people reach for when they hear "top-K" — and it answers exactly that one
query, at the cost of forgetting everything else: no interior access, no
rank, no neighborhood, no deletion of a quarantined cheater without a
rebuild. And the *B-tree* deserves its own pitfall, because it is the
answer that sounds most like production experience:

#pitfall([The `COUNT(*)` rank trap])[
  The most common wrong answer: store scores in a relational table, index the
  score column, and compute rank as `SELECT COUNT(*) WHERE score > :mine`.
  The index makes top-K fine, but rank-by-count touches *every entry above
  the player* — for rank 1.2M of 200M, that is a 198.8M-row index scan per
  query, thousands of times a second. Rank must be *maintained by the
  structure*, not computed by counting. This is the sentence the interviewer
  is listening for.
]

Do not just memorize the trap — understand why it is seductive, because the
same shape of mistake recurs everywhere. The database *feels* like it knows
the rank: it has a B-tree on score, and a B-tree is an ordered structure,
and ordered structures "know" positions. But a B-tree index maintains order
*locally* (each node sorted, children in ranges) without maintaining
*counts* — no node records how many keys live beneath it — so the only way
to compute "how many entries beat me" is to visit them all. Augmented
structures exist precisely to close this gap: store the subtree counts,
repair them on the rotation path, and rank becomes a root-to-leaf walk.
Chapter 8 will show you B-trees earning their keep where they belong; this
chapter is where you learn they are not positionally aware by default.

== Deep Dive: The Data Structure — Skip List with Spans

Here is the last structure standing from Section 6.6's walk, and it deserves
a proper introduction rather than a magic invocation, because "use a skip
list" is only an answer if you can explain *what makes rank O(log n)*.

#defterm([Skip list / span])[
  A _skip list_ is a probabilistically balanced ordered structure: a sorted
  linked list (level 0) with express lanes above it — each node is promoted
  to the next level with probability p (e.g. 1/4), so level i holds ~pⁱ of
  the nodes. Search starts on the top express lane and drops down, skipping
  ~1/p nodes per hop: O(log n) expected search, insert, delete. A _span_ is
  an integer on every forward pointer counting how many level-0 steps it
  covers; spans turn the skip list into an *order-statistics* structure:
  summing spans along a search path yields the rank directly, and rank +
  forward walks yield neighborhoods — still O(log n).
]

Build the intuition in two passes, because the two halves are independent
ideas that happen to compose perfectly. *Pass one — the skip list itself.*
A plain sorted linked list already has the property you need for reads from
the top (top-K is "walk K steps") but searching it is O(n): to find your
player you must visit every node before them. The skip list fixes this with
an almost childlike idea — add *express lanes*. Level 0 is the full list.
Each node, at birth, flips a weighted coin: with probability ¼ it also
appears at level 1; of those, a quarter also appear at level 2; and so on.
The result is a stack of ever-sparser copies of the list, each an express
lane that skips about three quarters of the nodes below it. Searching starts
at the top lane — giant strides — and drops a level whenever the next stride
would overshoot the target, until level 0 delivers the exact node. Each drop
halves-ish the remaining distance in expectation, hence O(log n). Nothing is
ever rotated or rebalanced; balance is *statistical*, maintained by the coin
flips at insert time, which is why concurrent and in-memory implementations
of skip lists are so much simpler than their tree cousins.

*Pass two — spans, the augmentation that creates rank.* On every forward
pointer, at every level, store one extra integer: how many level-0 steps
that pointer covers. A level-0 pointer always spans 1 (it goes to the next
node); a level-2 pointer might span 9 (it leaps nine real entries). Now
search for your player and *add up the spans of every pointer you traverse*:
each pointer you use is, by construction, a leap over entries that all rank
*ahead* of your player, and the sum of the leaps is exactly the count of
those entries — which is the rank minus one. Position falls out of the
search path itself. No counting scan, no per-query work proportional to
anything but the path length. *That* is what "maintained by the structure"
means concretely, and the diagram below makes it visible.

#v(0.3em)
#align(center)[
#canvas(h: 3.9cm)[
  // level labels
  #glabel(0.0cm, 2.95cm, [L2], fg: slate, size: 7pt)
  #glabel(0.0cm, 2.05cm, [L1], fg: slate, size: 7pt)
  #glabel(0.0cm, 1.15cm, [L0], fg: slate, size: 7pt)
  // head stack
  #node(0.9cm, 2.6cm, 1.2cm, 0.55cm, [head], fill: faint, edge: slate, size: 7pt)
  #node(0.9cm, 1.7cm, 1.2cm, 0.55cm, [head], fill: faint, edge: slate, size: 7pt)
  #node(0.9cm, 0.8cm, 1.2cm, 0.55cm, [head], fill: faint, edge: slate, size: 7pt)
  // n10 stack (L0,L1)
  #node(4.2cm, 1.7cm, 1.3cm, 0.55cm, [10], fill: white, edge: primary, size: 7.5pt)
  #node(4.2cm, 0.8cm, 1.3cm, 0.55cm, [10], fill: white, edge: primary, size: 7.5pt)
  // n20 (L0)
  #node(7.2cm, 0.8cm, 1.3cm, 0.55cm, [20], fill: white, edge: primary, size: 7.5pt)
  // n30 stack (L0,L1,L2)
  #node(10.2cm, 2.6cm, 1.3cm, 0.55cm, [30], fill: faint-teal, edge: teal.darken(10%), size: 7.5pt)
  #node(10.2cm, 1.7cm, 1.3cm, 0.55cm, [30], fill: faint-teal, edge: teal.darken(10%), size: 7.5pt)
  #node(10.2cm, 0.8cm, 1.3cm, 0.55cm, [30], fill: faint-teal, edge: teal.darken(10%), size: 7.5pt)
  // n40 (L0)
  #node(13.2cm, 0.8cm, 1.3cm, 0.55cm, [40], fill: faint-teal, edge: teal.darken(10%), size: 7.5pt)
  // L2 arrow head->30
  #arrow(2.15cm, 2.87cm, 10.15cm, 2.87cm, color: teal.darken(10%))
  #glabel(5.6cm, 3.1cm, [span 3], fg: teal.darken(10%), size: 6.6pt)
  // L1 arrows
  #arrow(2.15cm, 1.97cm, 4.15cm, 1.97cm, color: slate)
  #glabel(2.7cm, 2.2cm, [span 1], size: 6.4pt)
  #arrow(5.55cm, 1.97cm, 10.15cm, 1.97cm, color: slate)
  #glabel(7.3cm, 2.2cm, [span 2], size: 6.4pt)
  #arrow(11.55cm, 1.97cm, 13.15cm, 1.97cm, color: teal.darken(10%))
  #glabel(12.05cm, 2.2cm, [span 1], fg: teal.darken(10%), size: 6.4pt)
  // L0 arrows
  #arrow(2.15cm, 1.07cm, 4.15cm, 1.07cm, color: slate)
  #arrow(5.55cm, 1.07cm, 7.15cm, 1.07cm, color: slate)
  #arrow(8.55cm, 1.07cm, 10.15cm, 1.07cm, color: slate)
  #arrow(11.55cm, 1.07cm, 13.15cm, 1.07cm, color: slate)
  #glabel(2.7cm, 1.28cm, [1], size: 6.4pt)
  #glabel(6.1cm, 1.28cm, [1], size: 6.4pt)
  #glabel(9.1cm, 1.28cm, [1], size: 6.4pt)
  #glabel(12.1cm, 1.28cm, [1], size: 6.4pt)
  // caption
  #glabel(0.9cm, 3.5cm, [rank(40) = spans along the search path: 3 (L2, head→30) + 1 (L1, 30→40) = 4 — position without counting], size: 7pt)
]]
#v(0.2em)

Walk this picture the way the algorithm walks it, because the caption's
arithmetic only makes sense once you see the path. The drawing shows four
entries — 10, 20, 30, 40 — on level 0 (the bottom row of boxes, chained by
the gray arrows labeled "1": every level-0 step covers exactly one real
entry). Above them, fate has been uneven: node 10 was promoted to level 1,
node 30 all the way to level 2 (its three stacked boxes are shaded teal, the
tallest tower in the picture), and nodes 20 and 40 never got promoted at
all. The leftmost stack of three "head" boxes is the sentinel every search
starts from.

Now answer the caption's question: what is the rank of entry 40? Start at
the head's top box, L2. The only L2 arrow in the structure leaps from head
all the way to node 30 — a giant teal arrow spanning the top of the picture,
labeled "span 3" because it jumps over three level-0 entries (10, 20, and
lands *on* 30). You take it, and you record: 3 entries are now behind you.
From node 30 you would like to continue on L2, but 30's L2 pointer goes
nowhere useful (40 was never promoted), so you *drop a level* — the search
steps down inside node 30's tower, free of charge. On L1, node 30 has a
pointer to node 40, drawn in teal and labeled "span 1": one more real entry
traversed. Running total: 3 + 1 = 4 — and entry 40 is indeed the 4th in the
list. Rank computed from two pointer hops, without visiting nodes 10 or 20
at all. At 10⁸ entries the same computation takes about 27 hops instead of
2 — that is the entire claim of the structure, and you have just executed it
by hand.

Notice also what the spans buy *deletion* and *insertion*, since the
interviewer may ask: when a node enters or leaves, only the pointers on its
search path change, and each changed pointer's span is repaired by adding or
subtracting the new local step counts — constant work per level, no global
recount. The invariant "span = level-0 steps covered" is maintained locally,
edge by edge, which is exactly the augmentation discipline Section 6.4
described abstractly.

Why this over a balanced tree with subtree counts: same asymptotics, but
level-promotion makes inserts/deletes local (no rotations), concurrent
implementations are far simpler (only level 0 needs careful linking), and
span bookkeeping is an ~10-line addition. It is exactly the structure at the
core of the industry's canonical sorted-set implementations — a hash map
from player→node for O(1) "where is this player?" lookup, plus the skip list
for order and rank. Two structures, one object: the hash map answers
*identity*, the skip list answers *position*, and the pair of them is the
"ordered set" the rest of the chapter treats as a single component.

Ties slot in cleanly — and this is where the scope dialogue's footnote
("ties to whoever got it first") becomes structure. The ordering key is not
`score` but the triple `(score desc, achieved_at asc, player_id)`:
deterministic total order, no equal keys ever, and "first to achieve" falls
out of the comparison itself rather than being special-cased anywhere.
Design lesson worth saying aloud: when a product rule says "break ties by
X," the robust implementation is almost always to *fold X into the sort
key*, not to handle ties at query time — a total order cannot forget its
tie-break rule, because it does not have ties. Section 6.13 implements the
triple on Rust's ordered map (same complexity story; Rust's std ordered map
lacks spans, and the listing says so honestly).

== API Design

Six endpoints, and by now you can predict most of their shapes from the
FRs — which is the point of doing requirements first:

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Method], hcell[Path], hcell[Purpose]),
  body: (
    [`POST`], [`/v1/scores`], [Submit match score `{player_id, board, score, achieved_at, match_id}` — best-score + idempotent (FR-1)],
    [`GET`], [`/v1/leaderboards/{board}/top?cursor=&limit=`], [Top-K page (FR-2); cursor = last `(score, ts, id)` triple],
    [`GET`], [`/v1/leaderboards/{board}/players/{id}`], [Exact rank + score (FR-3)],
    [`GET`], [`/v1/leaderboards/{board}/players/{id}/around?r=`], [Neighborhood window (FR-4)],
    [`GET`], [`/v1/leaderboards/{board}/players/{id}/friends`], [Friends board (FR-6)],
    [`POST`], [`/v1/admin/quarantine`], [Anti-cheat hook: remove/hold entries (scope)],
  ),
)

Notes: `board` encodes window and scope (`global:alltime`, `global:2026-W36`,
`region:eu:daily:2026-09-05`) — Section 6.12 will show that making the
window *part of the key* is what turns board rotation from a migration into
a string change. Cursors are the rank triple, opaque and base64'd — Chapter
5's pagination lesson, and here the cursor *is* the ordering key, so paging
is a pure `range()` from the cursor position: no translation layer, no drift,
no ambiguity. Submission responses return `{accepted, improved,
current_best}` so clients can celebrate personal bests without a second call
— a small product flourish that costs you nothing because the best-score
check computed exactly those booleans on the way through.

== High-Level Architecture

You now have every ingredient: an ordering structure that fits in RAM
(Sections 6.5, 6.7), a write path that must absorb 10× event-day bursts
(Section 6.4), a podium that is read three orders of magnitude more often
than it changes, and an integrity requirement that says cheaters must
vanish from the board without the honest players noticing anything. Assemble
them and the architecture almost draws itself — the whole system is really
just *one in-memory data structure with a well-guarded front door and a
very wide read porch*:

#v(0.3em)
#align(center)[
#canvas(h: 7.9cm)[
  #glabel(0.1cm, 0.08cm, [Writes: validate → queue → in-memory ordered sets (replicated, journaled). Reads: cached pages for the top, live rank queries for everything else.], size: 7pt)
  // row 1: write path
  #node(0.2cm, 0.8cm, 2.7cm, 0.95cm, [Game servers \ match results], fill: faint, edge: slate, size: 7.2pt)
  #node(4.3cm, 0.8cm, 2.7cm, 0.95cm, [Score API \ validate · dedupe], fill: white, edge: primary, size: 7.2pt)
  #node(8.4cm, 0.8cm, 2.7cm, 0.95cm, [Ingestion queue \ smooth bursts], fill: white, edge: primary, size: 7.2pt)
  #node(12.5cm, 0.8cm, 2.7cm, 0.95cm, [Anti-cheat \ quarantine feed], fill: faint-red, edge: crimson, size: 7.2pt)
  #arrow(2.9cm, 1.27cm, 4.25cm, 1.27cm)
  #arrow(7.0cm, 1.27cm, 8.35cm, 1.27cm)
  #glabel(6.72cm, 0.98cm, [2.3k/s avg], size: 6.4pt)
  #arrow(11.15cm, 1.27cm, 12.45cm, 1.27cm)
  // row 2: the engine
  #node(4.3cm, 2.7cm, 3.4cm, 0.95cm, [Rank engine \ ordered sets in RAM], fill: faint-teal, edge: teal.darken(10%), size: 7.2pt)
  #node(8.9cm, 2.7cm, 2.6cm, 0.95cm, [Replicas \ read scale · failover], fill: white, edge: teal.darken(10%), size: 7.2pt)
  #arrow(9.75cm, 1.75cm, 6.65cm, 2.65cm)
  #glabel(8.8cm, 2.18cm, [25k/s peak], size: 6.4pt)
  #arrow(12.9cm, 1.75cm, 7.75cm, 2.9cm, color: crimson, dashed: true)
  #glabel(10.0cm, 2.12cm, [evict / hold], fg: crimson, size: 6.4pt)
  #arrow(7.75cm, 3.17cm, 8.85cm, 3.17cm, color: teal.darken(10%))
  // row 3: durability
  #node(0.2cm, 4.6cm, 3.4cm, 0.95cm, [Journal + snapshots \ durability], fill: faint, edge: slate, size: 7.2pt)
  #arrow(4.55cm, 3.65cm, 3.05cm, 4.55cm, color: slate)
  // row 4: read porch
  #node(0.2cm, 6.5cm, 2.7cm, 0.95cm, [Page cache \ top-100 windows], fill: faint-amber, edge: amber.darken(10%), size: 7.2pt)
  #node(4.3cm, 6.5cm, 2.7cm, 0.95cm, [Read API \ top-K · rank · around], fill: white, edge: primary, size: 7.2pt)
  #node(8.4cm, 6.5cm, 2.7cm, 0.95cm, [Friends service \ overlay filter], fill: white, edge: primary, size: 7.2pt)
  #node(12.5cm, 6.5cm, 2.7cm, 0.95cm, [Players \ web · mobile · in-game], fill: faint, edge: slate, size: 7.2pt)
  #arrow(9.3cm, 3.65cm, 1.6cm, 6.45cm, color: amber.darken(10%))
  #glabel(4.35cm, 4.95cm, [top-K pages], fg: amber.darken(10%), size: 6.4pt)
  #arrow(10.2cm, 3.65cm, 5.7cm, 6.45cm)
  #glabel(8.5cm, 4.55cm, [rank · around], size: 6.4pt)
  #arrow(11.0cm, 3.65cm, 9.8cm, 6.45cm)
  #arrow(2.95cm, 6.97cm, 4.25cm, 6.97cm)
  #arrow(7.05cm, 6.97cm, 8.35cm, 6.97cm)
  #arrow(11.15cm, 6.97cm, 12.45cm, 6.97cm)
]]
#v(0.2em)

The caption above the diagram is the entire architecture in one sentence;
now walk the picture slowly enough that every box earns its place. *The
write story* flows left to right along the top row. A match ends and the
game server — your only trusted caller, the gray box at top-left — submits
the result to the *Score API*. This box is deliberately narrow: it
authenticates the caller, validates the event's shape, and dedupes by
`match_id` so a retried submission cannot double-count. Everything that
will ever enter the system squeezes through this one auditable door, which
is exactly what you want when integrity is an NFR: one place to log, one
place to rate-limit, one place to change validation. From there the event
joins the *ingestion queue* — Chapter 4's shock absorber, recycled without
shame. The two rate labels tell its story: 2.3k/s flows on an average day,
but an event day (Section 6.5) multiplies that by ten, and the queue's job
is to make the 25k/s peak somebody else's problem — the rank engine
consumes at its own pace and the burst becomes *lag*, not loss.

The diagonal arrow from the queue down into the teal *rank engine* is where
the design's center of gravity sits. This box holds every board as an
in-memory ordered set — the skip-list-plus-hash-map pair from Section 6.7 —
and applies each update as a best-score `max`. Twenty gigabytes fits in RAM;
there is no database on the write path, no disk in the latency budget, no
cache-invalidation puzzle because the structure *is* the system of record.
Follow the arrows out of it. To the right, the engine streams every applied
update to its *replicas*: they exist for two reasons the diagram shows
honestly — reads fan out across them (12k rank-reads/s would rather not
share a process with 25k writes/s), and if the engine dies a replica is
already warm for promotion. Down and to the left, the gray *journal +
snapshots* box is the durability story: every update is appended to a log
before the caller is told it stuck, and periodic dumps of the whole board
bound recovery to "load latest snapshot, replay the tail." The board is
rebuildable and therefore never lost — and notice that because updates are
idempotent (next section), replaying the journal twice is *harmless*, which
makes recovery procedures blessedly un-subtle.

The dashed crimson arrow deserves its own paragraph, because it is the
integrity NFR drawn as plumbing. The *anti-cheat* service taps the same
ingestion stream (the short arrow from queue to its box — it is a consumer
like any other, no special coupling to the write path), runs whatever
detection heuristics the trust-and-safety team dreams up, and when it
convicts someone it issues an *evict / hold*: delete the player's entries
from every board and park their future submissions until cleared. Two
properties make this elegant rather than bolted-on. First, removal is just
another update — a delete flows through the same ordered set, the same
journal, the same replicas, so there is no second code path to keep
consistent. Second, because the leaderboard never renders a quarantined
score, the podium's integrity survives even a slow detection pipeline: the
worst case is a cheater visible for minutes, then gone everywhere at once,
including from cached pages at their next TTL tick.

*The read story* is the bottom row, and it is shaped by the asymmetry from
Section 6.4: the podium is read enormously more often than any individual
rank. So the two read paths are deliberately different. The amber arrow
carrying *top-K pages* from the replicas down to the *page cache* is the
hot path for the masses: the top-100 window of each popular board is
materialized as flat pages with a few-second TTL, so a million users
hammering the season leaderboard hit cheap cache reads, and the slight
staleness is invisible because — as Section 6.14 will quantify — the top
100 churns far slower than the board as a whole. The plain arrow carrying
*rank · around* is the personal path: when a player asks "where do *I*
stand," that query cannot be served from a cached podium (they are rank
1 247 003, remember), so it goes live to a replica, which answers in one
ordered-set lookup and one span-summing search. Both paths converge on the
*Read API*, which also consults the *friends service* — an overlay filter
that computes friends boards on the fly (Section 6.12 explains why they are
not materialized) — and the merged result flows right into *players* on
web, mobile, and in-game clients. Reads never touch the journal, never
touch the write door, and mostly never touch the engine itself; the porch
is wide precisely because the write room is small.

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Component], hcell[Responsibility], hcell[Why it is shaped this way]),
  body: (
    [*Score API*], [Authenticate game servers, validate, dedupe by `match_id`], [Writes enter through one narrow, auditable door],
    [*Ingestion queue*], [Buffer score events; absorb event-day bursts], [Chapter 4's shock absorber; ingestion lag becomes a metric, not an outage],
    [*Rank engine*], [Holds all boards as in-memory ordered sets; applies best-score updates; serves rank/top-K/around], [The structure of Section 6.7 is the system; 20 GB fits in RAM (Section 6.5)],
    [*Replicas*], [Read scale-out + hot standby], [Rank reads ×12k/s spread; promotion covers node loss],
    [*Journal + snapshots*], [Append-only update log; periodic board dumps], [Recovery = latest snapshot + replay; the board is rebuildable, never lost],
    [*Anti-cheat*], [Consumes the same stream; quarantines suspects], [A consumer like any other — removal is just a delete from the set],
    [*Page cache*], [Top-100 pages per board, few-second TTL], [The podium is read 10³× more often than it changes (top-100 churn is slow; Section 6.14)],
    [*Friends service*], [Intersection of friend list with board entries], [Small overlays computed on read; Section 6.12],
  ),
)

== Deep Dive: Score Ingestion Semantics

Before you shard anything or cache anything, it is worth pausing on the
single most convenient property this system has, because several later
decisions quietly depend on it. Best-score admission makes the write path
almost suspiciously simple:

#defterm([Monotonic (idempotent) update])[
  An update whose repeated application changes nothing after the first
  time. Best-score submission is monotonic: `board[player] = max(old, new)`
  absorbs retries, duplicates, and out-of-order redeliveries for free — no
  dedup tokens, no exactly-once machinery on the hot path. (Chapter 5's
  votes needed an upsert table; here the semantics do the work.) The one
  non-monotonic case — same player, same score, earlier timestamp stealing
  the tie-break — is excluded by rule: a player's slot keeps its first
  achieving timestamp.
]

Stop and appreciate what this buys you, because "idempotent" is easy to say
and rarely this complete. A client retries because the response was lost?
`max` shrugs. The queue redelivers after a consumer crash? `max` shrugs.
Two game servers somehow report the same match? The `match_id` dedupe at
the door catches the obvious case, and `max` catches everything else. The
journal replays a day of updates onto a stale snapshot? Every entry converges
to the same value it would have had anyway. You get at-least-once delivery —
the cheap, reliable kind — and the *semantics* upgrade it to exactly-once
effects. The single sharp edge is the tie-break: if the same score arrives
twice with different timestamps, blind `max` on the triple could let a later
redelivery steal the "earlier `achieved_at` wins" slot, which is why the rule
keeps the first timestamp and never rewrites it. One sentence of policy,
enforced in one comparison function, and the whole exactly-once debate
evaporates.

The ingestion contract, end to end:

+ Game server submits `(player, board, score, achieved_at, match_id)`; the
  Score API dedupes by `match_id` briefly (same match reported twice) and
  validates shape.
+ The queue buffers; the rank engine applies `max` updates in stream order.
  Bursts only stretch the freshness budget (≤ 5 s) — never correctness.
+ Anti-cheat consumes the same stream independently; a quarantine verdict
  deletes the player's entries from every board (a delete is just another
  update) and parks their submissions until cleared. The leaderboard never
  renders a quarantined score — integrity requirement, Section 6.4.
+ Every-run variant (arcade boards): entries keyed `(match_id)` instead of
  player; dedupe by match id is still free; top-K is unchanged; "my rank"
  becomes "my best run's rank." One sentence in the interview shows the
  abstraction holds.

That fourth step is worth dwelling on for a moment, because interviewers
love to poke it. If the product pivots from "your best score ever" to
"every run on the board" — arcade style, where one player can occupy five
slots of the top ten — notice how *little* of the design moves. The ordered
set does not care whether its members are keyed by player or by match; the
ingestion contract's dedupe-by-`match_id` becomes the primary key instead
of a guard; the podium, paging, and caching are untouched. The only real
casualty is "my rank," which must now be defined as "the rank of my best
run" — a product sentence, not an engineering one. When a one-line key
change absorbs a product pivot, you know the abstraction was drawn at the
right joint.

== Deep Dive: Sharding and the Global Top-K

One node holds 20 GB and applies 25k skip-list updates per second — a
single beefy rank engine covers the numbers from Section 6.5, with replicas.
Say that out loud in the interview, because "one machine is enough" is a
*finding*, not a cop-out, and it is backed by arithmetic you did in front of
them. But boards grow — new regions, new games, new seasons, and the
proud-but-terrifying day when 20 GB stops fitting — so the sharding answer
must be ready in your pocket even if you never deploy it. The design is
short and the correctness argument is the part worth rehearsing.

*Shard by `hash(player_id)`.* Each shard owns a complete ordered set of its
players — every board exists on every shard, holding exactly that shard's
players. Then:

- *Top-K, exact:* fetch the top K from *every* shard and k-way merge.
  Correctness: any member of the global top-K has at most K−1 players
  outranking it globally, hence at most K−1 on its own shard — so it must
  appear in its shard's top-K. Fetching K per shard is sufficient *and*
  necessary. Cost: shards × K entries per query — 8 shards × 100 = 800
  entries per page, trivial.
- *My rank, exact:* 1 + Σ~shards~ count(better than me) — a scatter-gather
  count across all shards, O(log n) per shard with spans, but fan-out per
  query. Fine at 1.2k rank-reads/s; painful at 10⁵/s.
- *"Top X%" displays, approximate:* each shard also maintains a
  fixed-boundary histogram of its scores. Histograms are *mergeable by
  addition* — sum the bucket counts and interpolate (Section 6.13) — so a
  global percentile is a cheap aggregate with no global ordering at all.
  This is how "top 0.4%" renders without ever computing 200M ranks.

The first bullet's argument repays a slow reading, because it is the kind of
proof interviewers lean on. Suppose some player *is* in the global top 100
but *not* in their own shard's top 100. Then 100 players on their shard
outrank them — and those 100 are also globally ahead of them — so at least
100 players outrank them globally, contradicting membership in the global
top 100. Therefore every global-top-100 member appears in its own shard's
top 100, the merge sees every candidate, and nothing is missed. Necessity
is the mirror image: an adversarial score distribution can put a global
top-K member at exactly rank K on its shard, so fetching fewer than K per
shard can miss one. Sufficient and necessary, one paragraph each — you will
reuse this exact argument in Chapter 7's candidate merging and Chapter 12's
nearby-driver scatter-gather.

#insight([Exact where it is read, approximate where it is glanced])[
  The podium (top-100) must be exact — it is the product. A player's own
  rank must be exact — they will screenshot it. The "top 2.3%" badge on a
  profile is glanced at, not audited — approximate it with mergeable
  histograms and save the global scatter-gather entirely. Precision is a
  budget; spend it only on surfaces where users check the math.
]

== Deep Dive: Windowed and Friends Boards

Two product features remain from the scope list — "this season," "today,"
and "my friends" — and both dissolve into key-naming decisions once the
core is right. That is not a coincidence; it is what a well-chosen core
abstraction does to feature requests.

*Time windows are just keys.* A board is identified by `(scope, period)` —
`global:alltime`, `global:weekly:2026-W36`, `global:daily:2026-09-05`.
Every score submission writes to *all live windows* for its scope (daily +
weekly + all-time = three ordered-set updates, still cheap at our write
rates). Rotation is a scheduler flipping the live key: yesterday's daily
board stops accepting writes, gets snapshotted to cold storage, and stays
readable as a frozen archive. No migration, no reindexing — the empty new
window is created lazily by the first write. Contrast this with the
alternative you might have sketched naively: one board with timestamps,
filtered at query time. That version pays a filter cost on *every read
forever* to support a rotation that happens *once a day*; the key-naming
version pays three writes instead of one (a constant, tiny) and makes
rotation a string flip. When a periodic event meets a hot read path, prefer
making the period part of the addressing over making it part of the query —
this is Chapter 4's roll-up lesson wearing a different hat.

*Friends boards are overlays, not boards.* A friend list is at most a few
hundred players. On read: fetch each friend's current `(score, ts)` by
direct player lookup (the hash-map side of the ordered set, O(1) each),
sort in memory, rank locally. Milliseconds, zero storage, and always
consistent with the main board because it *is* the main board's data,
viewed through a filter. The alternative — materializing a per-user friends
board at write time — multiplies every score update by the player's
appearance in friend lists: a Chapter 2-style fanout write amplification,
where one match result becomes hundreds of ordered-set updates, all to
answer a query Section 6.5 sized at a trickle compared to podium reads.
Compute-on-read wins decisively here — but notice *why* it wins, because
the general skill is the deciding, not the answer. The friend set is small
(bounded by a few hundred), the overlay query is rare relative to the
podium, and the underlying data already lives in a structure with O(1)
player lookup. If any of those three flipped — friend sets of millions,
friends boards as the primary surface, lookups that require a search —
the decision flips too, and you should say so in the room.

== Rust Reference Implementations

Time to make the design concrete. Three pieces, each with deterministic
tests you can run in your head as you read: the leaderboard itself (the
ordered-set-plus-index pair from Section 6.7), the sharded top-K merge
(whose correctness argument you rehearsed in Section 6.11), and the
mergeable percentile histogram that powers the "top X%" badges. As in every
chapter, the code is not a toy — it is the interview whiteboard answer made
executable, and the tests encode the exact claims the prose made.

*The leaderboard: ordered set + player index.* Read the doc comments
carefully — they carry an honesty the interview room rewards. Rust's
standard `BTreeMap` gives you the ordered set with the right interface and
the right big-O for everything *except* rank: it keeps no order statistics,
so `rank_of` below counts the better half in O(rank) rather than the span
skip list's O(log n). The code says so in a `NOTE:` rather than pretending
otherwise. That is the right trade for a reference implementation — the
skip list's span arithmetic is the *deployable* answer, the BTreeMap is the
*explainable* one, and the difference is confined to a single method body.
Notice too how the tie-break rule from Section 6.7 becomes literally one
type alias: `Key = (Reverse<u64>, u64, u64)` — score descending, timestamp
ascending, player id last. A total order, so entries never tie, and "first
to achieve" is free. The `submit` method is the monotonic-update contract
from Section 6.10 written in fifteen lines: strictly-better-scores-only
admission, old key removed before the new key is inserted, `false`
returned whenever nothing changed — which is precisely what makes retries
and duplicate submissions safe by construction.

```rust
use std::cmp::Reverse;
use std::collections::{BTreeMap, HashMap};

/// Ordering key: score desc, then earliest achieved_at, then player id —
/// a total order, so entries never tie and "first to achieve" is free.
type Key = (Reverse<u64>, u64, u64);

/// In-memory board. `entries` is the ordered set (a stand-in for the
/// span-augmented skip list of Section 6.7 — same interface and big-O,
/// except rank, noted below); `by_player` is the O(1) side index.
#[derive(Default)]
pub struct Leaderboard {
    entries: BTreeMap<Key, ()>,
    by_player: HashMap<u64, (u64 /*score*/, u64 /*achieved_at*/)>,
}

impl Leaderboard {
    /// Best-score admission: strictly better scores only. Monotonic, so
    /// retries and duplicate submissions are safe by construction.
    pub fn submit(&mut self, player: u64, score: u64, achieved_at: u64) -> bool {
        if let Some(&(old, _)) = self.by_player.get(&player) {
            if score <= old { return false; }
        }
        if let Some(&(old, old_ts)) = self.by_player.get(&player) {
            self.entries.remove(&(Reverse(old), old_ts, player));
        }
        self.entries.insert((Reverse(score), achieved_at, player), ());
        self.by_player.insert(player, (score, achieved_at));
        true
    }

    pub fn top_k(&self, k: usize) -> Vec<(u64, u64)> {
        self.entries
            .keys()
            .take(k)
            .map(|&(Reverse(s), _, id)| (id, s))
            .collect()
    }

    /// 1-based rank. NOTE: Rust's ordered map keeps no order statistics, so
    /// this counts the better half — O(rank). The span skip list answers the
    /// same call in O(log n); only the implementation changes.
    pub fn rank_of(&self, player: u64) -> Option<u64> {
        let &(s, ts) = self.by_player.get(&player)?;
        let better = self.entries.range(..(Reverse(s), ts, player)).count();
        Some(better as u64 + 1)
    }

    /// ±r window around a player: (rank, player, score), edges clamped.
    pub fn neighborhood(&self, player: u64, r: usize) -> Vec<(u64, u64, u64)> {
        let rank = match self.rank_of(player) {
            Some(r) => r as usize,
            None => return vec![],
        };
        let lo = rank.saturating_sub(r + 1); // 0-based start
        let hi = (rank + r).min(self.entries.len()); // exclusive end
        self.entries
            .keys()
            .enumerate()
            .skip(lo)
            .take(hi - lo)
            .map(|(i, &(Reverse(s), _, id))| (i as u64 + 1, id, s))
            .collect()
    }
}

#[cfg(test)]
mod board_tests {
    use super::*;

    #[test]
    fn best_score_ties_and_rank() {
        let mut lb = Leaderboard::default();
        assert!(lb.submit(1, 500, 100)); // alice
        assert!(lb.submit(2, 900, 100)); // carol
        assert!(lb.submit(3, 500, 200)); // bob: same score, later ts
        assert!(lb.submit(4, 100, 100)); // dave
        // board order: 2 (900), 1 (500@100), 3 (500@200), 4 (100)
        assert_eq!(lb.top_k(2), vec![(2, 900), (1, 500)]);
        assert_eq!(lb.rank_of(1), Some(2)); // tie broken by earlier ts
        assert_eq!(lb.rank_of(3), Some(3));
        assert_eq!(lb.rank_of(4), Some(4));
        assert_eq!(lb.rank_of(99), None);
        // monotonic admission: worse or equal scores change nothing
        assert!(!lb.submit(1, 400, 300));
        assert!(!lb.submit(1, 500, 50));
        assert_eq!(lb.rank_of(1), Some(2));
        // improvement repositions
        assert!(lb.submit(1, 950, 400));
        assert_eq!(lb.top_k(2), vec![(1, 950), (2, 900)]);
    }

    #[test]
    fn neighborhood_windows_clamp_at_edges() {
        let mut lb = Leaderboard::default();
        for i in 0..10u64 {
            lb.submit(i, 1000 - i * 10, 1); // id i -> rank i+1
        }
        let w = lb.neighborhood(4, 2); // rank 5 -> ranks 3..=7
        let ranks: Vec<u64> = w.iter().map(|e| e.0).collect();
        let ids: Vec<u64> = w.iter().map(|e| e.1).collect();
        assert_eq!(ranks, vec![3, 4, 5, 6, 7]);
        assert_eq!(ids, vec![2, 3, 4, 5, 6]);
        let w0 = lb.neighborhood(0, 2); // top edge
        assert_eq!(w0.iter().map(|e| e.0).collect::<Vec<_>>(), vec![1, 2, 3]);
        assert!(lb.neighborhood(99, 2).is_empty());
    }
}
```

Walk the first test the way you would trace it on the whiteboard, because
every assertion is a sentence from earlier sections made executable. Alice
(player 1) submits 500, Carol (2) submits 900, Bob (3) submits the *same*
500 but one hundred seconds later, Dave (4) submits 100. The board order
asserted by `top_k(2)` — Carol, then Alice — is the tie-break triple doing
its quiet work: Alice and Bob have equal scores, and Alice's earlier
timestamp ranks her ahead, which `rank_of(3) == Some(3)` confirms from the
other direction. Then the monotonicity block: Alice resubmits a *worse*
score and a *duplicate* of her best with an earlier timestamp, both return
`false`, and her rank is unmoved — that second case is the tie-break theft
from Section 6.10 being refused entry. Finally Alice legitimately improves
to 950 and leapfrogs Carol. If you can narrate this test in the room, you
have demonstrated best-score admission, total-order tie-breaking, and
idempotent writes without saying any of those phrases — and then you get to
say the phrases.

The second test guards a boundary that product demos always hit: the
neighborhood window near the edges. A player at rank 5 with radius 2 sees
ranks 3 through 7 — but the player at rank 1 has no ranks −1 and 0 to show,
so the window clamps to 1, 2, 3 instead of erroring or padding. Clamp, do
not crash: the podium's neighbors view is a UI surface, and UIs should
never learn about `saturating_sub` the hard way.

*The sharded top-K merge* implements Section 6.11's proof as a heap dance.
The classic k-way merge: seed a max-heap with each shard's current leader,
repeatedly pop the global leader, and push that shard's next entry in its
place. Two details carry the correctness. The heap orders by
`(score, Reverse(ts))` — the same tie-break rule as the board itself, so a
merge of ordered streams stays honest about "first to achieve." And the
function asks each shard for *its* top-k because of the sufficiency
argument you proved: any global top-k member has fewer than k entries
outranking it on its own shard, so it is always inside its shard's
contribution. The second test constructs the adversarial case on purpose —
*all three* global leaders stacked on one shard — and confirms that asking
k=3 per shard still recovers the exact global podium. When an interviewer
asks "how do you know K per shard is enough?", you point at that test and
retell the proof.

```rust
use std::cmp::Reverse;
use std::collections::BinaryHeap;

/// One shard's top entries, already in board order (score desc, ts asc).
pub type ShardTop = Vec<(u64 /*player*/, u64 /*score*/, u64 /*ts*/)>;

/// Global top-k by merging each shard's top-k. Sound because any global
/// top-k member has < k entries outranking it globally, hence < k on its own
/// shard — so it is always inside its shard's top-k contribution.
pub fn merge_top_k(shards: &[ShardTop], k: usize) -> Vec<(u64, u64, u64)> {
    // max-heap on (score, Reverse(ts)): highest score, earliest ts pops first
    let mut heap = BinaryHeap::new();
    for (s, shard) in shards.iter().enumerate() {
        if let Some(&(p, sc, ts)) = shard.first() {
            heap.push((sc, Reverse(ts), p, s, 0usize));
        }
    }
    let mut out = Vec::with_capacity(k);
    while let Some((sc, Reverse(ts), p, s, i)) = heap.pop() {
        out.push((p, sc, ts));
        if out.len() == k { break; }
        if let Some(&(p2, sc2, ts2)) = shards[s].get(i + 1) {
            heap.push((sc2, Reverse(ts2), p2, s, i + 1));
        }
    }
    out
}

#[cfg(test)]
mod merge_tests {
    use super::*;

    #[test]
    fn merge_matches_brute_force_global_sort() {
        let shards: Vec<ShardTop> = vec![
            vec![(1, 900, 5), (4, 300, 5)],
            vec![(2, 950, 5), (5, 250, 5)],
            vec![(6, 500, 1), (3, 500, 5)], // tie at 500: earlier ts first
        ];
        let merged = merge_top_k(&shards, 4);
        let ids: Vec<u64> = merged.iter().map(|e| e.0).collect();
        assert_eq!(ids, vec![2, 1, 6, 3]);

        let mut all: Vec<(u64, u64, u64)> = shards.concat();
        all.sort_by(|a, b| b.1.cmp(&a.1).then(a.2.cmp(&b.2)));
        let oracle: Vec<u64> = all.into_iter().take(4).map(|e| e.0).collect();
        assert_eq!(ids, oracle);
    }

    #[test]
    fn k_per_shard_is_sufficient() {
        // all three global leaders live on one shard; asking only k=3
        // per shard still recovers the exact global top-3
        let shards: Vec<ShardTop> = vec![
            vec![(1, 100, 1), (2, 90, 1), (3, 80, 1), (4, 70, 1)],
            vec![(5, 60, 1)],
        ];
        let per_shard: Vec<ShardTop> =
            shards.iter().map(|s| s.iter().take(3).cloned().collect()).collect();
        let ids: Vec<u64> =
            merge_top_k(&per_shard, 3).iter().map(|e| e.0).collect();
        assert_eq!(ids, vec![1, 2, 3]);
    }
}
```

The first test deserves a nod for its technique: it checks the heap merge
against a *brute-force oracle* — concatenate every shard, sort globally,
take four — and demands identical output, tie-breaks included. When the
clever algorithm and the dumb algorithm agree, you can trust the clever
one. That pattern (fast path + oracle in tests) is worth stealing for any
system where you replace an obvious implementation with a subtle one.

*The mergeable percentile histogram* is the piece that makes "top 0.4%"
badges cheap. The design constraint comes straight from Section 6.11's
insight: the aggregate must be *mergeable by addition*, which forces fixed
bucket boundaries chosen up front (log-scaled here — score distributions in
games are heavy-tailed, so the buckets stretch the same way). `add` is a
`partition_point` binary search into the bounds; `merge` asserts the bounds
match and adds bucket-by-bucket; `percentile_of` accumulates whole buckets
below the query score and interpolates linearly inside the straddling one.
The approximation's error lives entirely inside that one bucket — which is
why log-scaled bounds give you fine resolution at the elite end, where
players actually care, and coarse resolution among the masses, where nobody
checks.

```rust
/// Fixed-boundary histogram for approximate "top X%" displays.
/// counts[i] = scores in [bounds[i-1], bounds[i]); the last bucket catches
/// everything >= the final bound. Histograms merge by adding counts —
/// that is what makes global percentiles cheap across shards.
pub struct ScoreHistogram {
    bounds: Vec<u64>,
    counts: Vec<u64>,
    total: u64,
}

impl ScoreHistogram {
    pub fn new(bounds: Vec<u64>) -> Self {
        assert!(!bounds.is_empty());
        let m = bounds.len();
        ScoreHistogram { bounds, counts: vec![0; m + 1], total: 0 }
    }

    pub fn add(&mut self, score: u64) {
        let i = self.bounds.partition_point(|&b| score >= b);
        self.counts[i] += 1;
        self.total += 1;
    }

    /// Merge another shard's histogram (identical bounds) by addition.
    pub fn merge(&mut self, other: &ScoreHistogram) {
        assert_eq!(self.bounds, other.bounds);
        for (a, b) in self.counts.iter_mut().zip(&other.counts) {
            *a += b;
        }
        self.total += other.total;
    }

    /// Estimated fraction of players scoring below `score`, with linear
    /// interpolation inside the straddling bucket.
    pub fn percentile_of(&self, score: u64) -> f64 {
        if self.total == 0 { return 0.0; }
        let (mut below, mut lower) = (0.0f64, 0u64);
        for (i, &upper) in self.bounds.iter().enumerate() {
            if score >= upper {
                below += self.counts[i] as f64;
                lower = upper;
            } else {
                if score > lower {
                    let frac = (score - lower) as f64 / (upper - lower) as f64;
                    below += frac * self.counts[i] as f64;
                }
                return below / self.total as f64;
            }
        }
        // strictly below `score` (bucket contents are >= the last bound)
        if score > *self.bounds.last().unwrap() {
            below += self.counts[self.bounds.len()] as f64;
        }
        below / self.total as f64
    }
}

#[cfg(test)]
mod hist_tests {
    use super::*;

    #[test]
    fn percentile_tracks_uniform_distribution() {
        let mut h =
            ScoreHistogram::new(vec![100, 1_000, 10_000, 100_000, 1_000_000]);
        for i in 0..1000u64 { h.add(i * 1_000); } // 0, 1000, ..., 999_000
        assert_eq!(h.total, 1000);
        assert_eq!(h.percentile_of(0), 0.0);
        let p50 = h.percentile_of(500_000); // interpolates in [100k, 1M)
        assert!((p50 - 0.5).abs() < 0.05, "p50 = {p50}");
        assert_eq!(h.percentile_of(2_000_000), 1.0);
        // "top X%" badge: the 999_500 score is elite
        assert!((1.0 - h.percentile_of(999_500)) * 100.0 < 1.0);
    }

    #[test]
    fn histograms_merge_by_addition() {
        let bounds = vec![100, 1_000];
        let (mut a, mut b) =
            (ScoreHistogram::new(bounds.clone()), ScoreHistogram::new(bounds));
        for s in [0, 50, 500] { a.add(s); }
        for s in [5_000, 9_999] { b.add(s); }
        a.merge(&b);
        assert_eq!(a.total, 5);
        assert!((a.percentile_of(1_000) - 0.6).abs() < 1e-9); // 3 of 5 below
    }
}
```

The tests pin the two properties the architecture actually relies on.
`percentile_tracks_uniform_distribution` feeds a perfectly uniform spread
of scores and demands the median land within five points of 0.5 — the
interpolation doing its job — and then checks the badge math directly: a
score of 999 500 must render as "top < 1%," which is the literal product
feature from Section 6.11 expressed as an assertion.
`histograms_merge_by_addition` is the sharding enabler: two independent
shards, merged by addition, produce the same percentile as if the data had
never been split — 3 of 5 below 1 000, exact to 10⁻⁹. That assertion is
why the global scatter-gather can be skipped for badges: the merge is not
approximately associative, it *is* associative, and the only approximation
is the interpolation you already accepted.

== Scaling the Platform

The scaling story here is refreshingly undramatic, and you should present
it that way: each layer scales on its own axis, and no layer's mechanism
leaks into another's. Read the table top to bottom and notice that every
"mechanism" cell is something you have already justified — the table is a
summary of decisions, not a list of new ones.

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Layer], hcell[Scale axis], hcell[Mechanism]),
  body: (
    [*Score API*], [Submission rate], [Stateless; horizontal],
    [*Ingestion queue*], [25k/s avg→peak bursts], [Partitioned by board+shard key; lag is a metric, not an outage (Chapter 4 pattern)],
    [*Rank engine*], [Board entries × update rate], [One node per board-group until RAM or write QPS demands sharding by `hash(player)`; O(log n) updates mean a single core does 10⁶ ops/s — 40× headroom over peak],
    [*Read path*], [Rank/top-K reads], [Replicas + the page cache; the podium page is shared by everyone and changes slowly — a few-second TTL absorbs the viral majority],
    [*Storage*], [200M-entry all-time board], [20 GB RAM per replica; snapshots to object storage; journal retention days],
    [*Windows*], [Board count = scopes × live windows], [Lazy creation; frozen archives are read-only snapshots — zero live cost],
  ),
)

The rank-engine row contains the chapter's most quietly important number:
*40× headroom over peak*. O(log n) updates mean a single core sustains
roughly a million ordered-set operations per second, and the event-day peak
is 25 000. This is why "one beefy node with replicas" is an engineering
conclusion rather than a laziness — and it is also your cue to say the
grown-up sentence: *we shard when the RAM or the write rate forces us to,
not because sharding is what scalable architectures do.* Premature
distribution is still premature.

#insight([Top-100 churn is glacial compared to mid-table churn])[
  The millionth-best player changes rank with every match; the podium
  changes a few times an hour. So cache top pages aggressively (they barely
  move), serve rank/neighborhood live from the ordered set (they move
  constantly and are queried rarely per position), and never cache
  mid-table pages — they are wrong the moment they are written. The cache
  policy mirrors the physics of the data.
]

That insight is really a *cache-validity* argument, and it generalizes far
beyond leaderboards: a cache is only as good as the ratio of read rate to
change rate at the exact slice being cached. The podium slice has reads in
the millions and changes per hour — cache it. A personal rank has one
reader and changes per match — computing it live costs less than
invalidating it. Mid-table pages have the worst of both worlds — many
potential readers, constant change — which is why the API from Section 6.8
offers `top` and `around` but pointedly no `page 12 470` endpoint. The
architecture does not merely tolerate the physics; it *declines to build*
the surface the physics would punish.

== Failure Modes & Degradation

The failure table follows the book's discipline — walk the diagram,
kill each box, and ask what the user sees and what the system does about
it. Two rows deserve special attention: the journal row, because it is
where durability claims go to be tested, and the anti-cheat row, because it
is where the chapter's *integrity beats availability* stance stops being a
slogan.

#tbl(
  (1.2fr, 1fr, 1.4fr),
  header: (hcell[Failure], hcell[Symptom], hcell[Response]),
  body: (
    [Rank engine node loss], [Board reads fail over, writes pause seconds], [Promote a replica; it is already warm. Recovery to a fresh node = snapshot + journal replay],
    [Journal gap / corruption], [Replay inconsistency on recovery], [Checksummed journal frames; on gap, rebuild the board from match-history re-ingest (slow but total) — the board is *derived state* over score facts],
    [Queue backlog on event day], [Freshness degrades past 5 s], [Degrade freshness, never integrity: clients show "updating…" affordance; Chapter 3's limiter sheds anonymous poll traffic first],
    [Replica lag], [Stale ranks on some reads], [Version the board (update count); reads report the version so clients never go backwards within a session],
    [Hot shard], [One shard's players dominate writes], [Reshard by splitting the hash range; top-K merge is shard-count-agnostic, so reads need no coordination],
    [Anti-cheat pipeline down], [Suspect scores render], [Fail toward quarantine for new suspicious velocity; previously cleared scores unaffected. Integrity beats availability here — Section 6.4],
    [Clock skew in `achieved_at`], [Wrong tie-breaks], [Ties are rare and low-stakes; still, trust server receipt time over client clocks, accept `achieved_at` only within a tolerance window],
  ),
)

The journal row hides the deepest idea in this table: *the board is derived
state*. The ordered sets in RAM, the snapshots, even the journal itself are
all reconstructions of one ground truth — the score facts that game servers
submitted. As long as match history exists somewhere (and it does, in the
game's own records), the worst-case recovery is re-ingesting it through the
same monotonic pipeline, which converges to exactly the same board. This is
the same philosophical move Chapter 4 made with metrics and Chapter 5 with
vote tallies, and it is worth internalizing as a pattern: when your hot
state is a *function* of an append-only fact stream, no failure of the hot
state is permanent. Expensive, slow, embarrassing — yes. Permanent — no.

The clock-skew row is the table's honest confession. The tie-break rule
trusts `achieved_at`, and client clocks lie. The mitigation is deliberately
boring — prefer server receipt time, accept client timestamps only within a
tolerance window — and the *reason it is acceptable* is the rarity
argument: ties require equal scores, equal scores at decision-relevant
positions are uncommon, and the cost of a wrong tie-break is one podium
slot's ordering between two equally-scored players. Spend engineering in
proportion to blast radius; a fairness edge case affecting one tie in a
million gets a tolerance window, not a distributed clock protocol.

== Trade-offs & Alternatives

Every decision this chapter made has a respectable alternative, and the
table's "why not" column is written from this workload's specific physics —
re-read it as a set of *conditional* statements, not universal laws. The
same alternatives win in other buildings; Chapter 11 will happily choose a
disk-first database, because its workload's working set does not fit in RAM
and its correctness bar is higher.

#tbl(
  (auto, 1fr, 1.4fr),
  header: (hcell[Decision], hcell[Chosen], hcell[Alternative & why not (here)]),
  body: (
    [Storage of boards], [In-memory ordered sets + journal], [Disk-first DB: 10–100× slower rank ops for zero capacity gain — the working set fits in RAM],
    [Rank computation], [Structure-maintained (spans)], [Rank-by-count SQL: O(better-entries) per query — melts (Section 6.6)],
    [Score semantics], [Best-score, monotonic], [Every-run: right for arcade boards; same machinery, different key (`match_id`)],
    [Global top-K], [Per-shard top-K + k-way merge], [One global sorted set across shards: distributed ordering is a consensus problem nobody needs for a leaderboard],
    [Global percentile], [Mergeable histograms], [Exact scatter-gather counts: fine at 10³/s, wrong tool for every profile badge],
    [Friends board], [Computed on read from the friend list], [Materialized per-user boards: write fanout per score — Chapters 2/5's fanout lesson],
    [Freshness], [≤5 s via async apply], [Synchronous end-to-end: turns every match-end into a distributed transaction],
    [Live push], [Out of scope; polling + short TTL], [WebSocket fanout of rank changes: a fine Chapter 1-style add-on, but rank updates at 25k/s make push storms the default state],
  ),
)

Two rows repay discussion. *Global top-K* — the rejected alternative, one
giant globally-ordered set spanning shards, sounds clean until you notice
that maintaining a total order across machines means every insert must
coordinate with every machine that might hold a neighbor: you have
reinvented distributed consensus to answer a question (who is 47th?) that a
800-entry merge answers in microseconds without any coordination at all.
The chapter's recurring pattern shows up again here: *keep the hot shared
thing small and local; reconstruct the global view at read time from
provably sufficient parts.* And *live push* — the rejected WebSocket fanout
— fails on arithmetic, not taste: 25k score updates per second each reorder
thousands of mid-table ranks, so a truthful push stream is a 10⁸-events/s
firehose of ranks nobody is looking at. Polling with a short TTL shows the
user the same podium a few seconds later at a ten-thousandth of the cost.
When a feature request fails the physics, the polite word is "add-on."

== Observability & SLOs

#tbl(
  (auto, 1fr, auto),
  header: (hcell[Indicator], hcell[Definition], hcell[Target]),
  body: (
    [*Ingest freshness*], [Score accepted → reflected in rank engine, p95], [≤ 5 s],
    [*Top-K latency*], [Page read, cached / live, p95], [≤ 10 ms / ≤ 50 ms],
    [*Rank latency*], [`rank` + `neighborhood`, p95], [≤ 100 ms],
    [*Board integrity*], [Sampled players whose stored slot ≠ submitted best], [≈ 0 (journal-rebuildable)],
    [*Quarantine latency*], [Verdict → entries removed from all boards], [≤ 60 s],
    [*Availability*], [Reads / writes], [99.99% / 99.9%],
  ),
)

Read the availability row's asymmetry: four nines for reads, three for
writes. That is the chapter's priority order rendered as an SLO — a
leaderboard that renders slightly stale is a leaderboard; one that cannot
be viewed is a blank screen in a product whose entire job is being viewed.
Writes pausing for seconds during an engine failover (Section 6.15's first
row) is priced into the three nines and covered by the queue; reads have no
such buffer, hence replicas plus the page cache absorbing the viral
majority.

Chapter 4's platform carries all of it: ingestion lag as a consumer-lag
metric, freshness as a histogram, an alert with a `for` duration on replica
version drift. The reconciliation sampler — comparing stored slots against
recomputed bests from the journal — is this chapter's version of Chapter
5's tally audit, and the *board integrity* SLO row is its output: a sampled
disagreement rate that should sit at approximately zero forever, with the
journal guaranteeing that any nonzero reading is repairable by replay. This
is the observability pattern worth naming in the room: for every derived
structure you operate, run a permanent, sampled comparison against the
facts it was derived from. Dashboards tell you the system is busy; the
reconciler tells you it is *right*.

== Interview Wrap-Up

Likely follow-ups, and the shape of strong answers:

+ *"Push live rank changes to clients."* This is a fan-out problem in
  disguise: 25k updates per second each reorder thousands of ranks — and
  nobody's *visible* rank actually moved. Push only material changes:
  podium swaps, personal bests, crossing a friend. Everything else is noise
  dressed as real-time. The answer demonstrates that you evaluate features
  with the workload's physics, not with enthusiasm.
+ *"Team leaderboards."* Team score = aggregate of members (sum, or an
  ELO-style rating); the ordered set is identical, keyed by team. The
  interesting part is member-change handling and anti-stack incentives, not
  the structure — say so, then discuss those.
+ *"Regional boards at 50 regions × 3 windows?"* Boards are cheap keys —
  150 extra ordered sets, each small. Writes fan out per applicable board
  (a player's score lands on their region's set + global); reads unchanged.
  Section 6.12's windows-as-keys insight pays off verbatim.
+ *"How do you catch cheaters?"* Server-side authority (the game server
  signs match results; clients never self-report), statistical anomaly
  detection on score distributions per level (a Chapter 4 alert on
  percentile outliers), velocity checks (Chapter 3's limiter: matches/hour
  per player), and quarantine-not-delete so false positives recover.
  Notice the shape: three earlier chapters each donate one mechanism.
+ *"10⁹ players — what breaks first?"* Single-node RAM (100 GB is still one
  node, but uncomfortable) and the top-K merge fan-out staying flat — the
  design already shards; the rank scatter-gather for exact global rank is
  what you would approximate next (histograms), keeping exact rank only
  within a player's region shard. A strong answer names the *first* casualty
  and the *ordered* list of fallbacks, not a vague "shard more."

== Summary & Further Reading

#notebox([Chapter summary])[
  A leaderboard is one primitive — rank over a mutating total order — and
  the chapter is the engineering that protects it. The structure is an
  ordered set: hash map for player lookup, skip list with spans for
  O(log n) rank, top-K, and neighborhoods; ties are a total ordering key
  `(score, achieved_at, id)`. Writes are monotonic best-score updates —
  idempotent by construction, journaled for durability, replicated for
  reads. Reads split by physics: the podium is cached (it barely moves),
  personal rank is live (it always moves), percentiles are approximated
  with mergeable histograms (they are glanced at, not audited). Sharding by
  player hash keeps top-K exact through a k-way merge — any global top-K
  member is provably inside its shard's top-K. Windows are keys; friends
  boards are overlays; cheating is a stream consumer with the power to
  delete. The lesson that transfers: *when the query is positional, the
  data structure is the architecture.*
]

Further reading.

- The source video: "17: Top K Leaderboard — Systems Design Interview
  Questions With Ex-Google SWE" (Jordan has no life):
  https://www.youtube.com/watch?v=nQpkRONzEQI
- William Pugh — "Skip Lists: A Probabilistic Alternative to Balanced
  Trees" (1990) — the structure of Section 6.7, including span-based ranks.
- Redis sorted sets documentation (`ZADD` / `ZRANK` / `ZRANGE`) — the
  canonical production embodiment of this chapter's ordered set.
- Cormen et al., _Introduction to Algorithms_ — the order-statistics tree
  chapter (subtree sizes) for the balanced-tree equivalent of spans.
- "Elo rating system" and TrueSkill papers — for the follow-up where the
  board ranks skill rather than scores.

== Chapter Glossary

#tbl(
  (auto, 1fr),
  header: (hcell[Term], hcell[Meaning]),
  body: (
    [Best-score semantics], [One slot per player per board holding their personal best; worse scores are no-ops],
    [Cursor], [Opaque paging token; here literally the ordering key triple `(score, achieved_at, id)` of the last entry],
    [Every-run semantics], [Arcade-style admission where each match is a separate entry and a player may hold many slots],
    [Exact rank], [A player's precise 1-based position; required for self-queries, wasteful for global percentiles],
    [Friends board], [A leaderboard restricted to a player's friend set; computed as a read-time overlay, not stored],
    [Histogram (mergeable)], [Fixed-bucket score distribution; bucket counts add across shards, giving cheap approximate percentiles],
    [Idempotent / monotonic update], [An update whose repetition changes nothing; best-score `max` admission has this property for free],
    [Journal (write-ahead)], [Append-only record of updates enabling replay after snapshot restore],
    [K-way merge], [Merging k-sorted shard outputs with a heap; sound for top-K because K entries per shard always suffice],
    [Leaderboard], [An ordering of players by score within a scope (window, region, friends)],
    [Neighborhood query], [The ±r window around a player's rank — needs both rank and ordered iteration],
    [Order-statistics query], [A positional query (rank, k-th, count-above); needs an augmented ordered structure, not a plain index],
    [Ordered set], [The abstract data type: map from member to score plus rank-ordered iteration; hash map + skip list in practice],
    [Percentile / "top X%"], [Approximate positional display computed from merged histograms instead of exact ranks],
    [Quarantine], [Anti-cheat state: scores held out of all boards pending verdict; deletable, recoverable],
    [Rank], [1-based position in a leaderboard's ordering],
    [Shard sufficiency (top-K)], [The theorem that global top-K needs only K entries per shard, since a global top-K member is outranked by \< K entries anywhere],
    [Skip list], [Probabilistically balanced ordered list with express lanes; O(log n) search/insert/delete without rotations],
    [Span], [Count on a skip-list forward pointer of level-0 steps covered; summing spans along a search path yields rank],
    [Tie-break], [Deterministic total order extension: (score desc, `achieved_at` asc, id) — first to achieve wins],
    [Top-K], [The first K entries of a board in order; the podium query],
    [Windowed board], [A board scoped to a time period (daily/weekly); rotation is a key change, archives are frozen snapshots],
  ),
)

#v(1em)
#align(center)[_— End of Chapter 6 · Next: Chapter 7, Designing a Recommendation Engine —_]
