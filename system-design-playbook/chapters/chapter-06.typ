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

This problem looks small next to Chapters 2–5 — and that is the trap. The
arithmetic is gentle (Section 6.5); the difficulty is that the two headline
queries, *top-K* and *rank-of-player*, must stay O(log n)-ish over an ordered
collection of 10⁸ entries while that collection is being updated at storm
rates. Choose the wrong structure and either the reads or the writes eat the
system. Choose the right one and most of the chapter is careful engineering
around it: windows, ties, sharding, and cheating.

#defterm([Leaderboard / rank / top-K])[
  A _leaderboard_ is an ordering of players by score within some scope (a
  game, a season, a region, a friend group). A player's _rank_ is their
  1-based position in that ordering. A _top-K_ query returns the first K
  entries in order. The pair {top-K, rank} is the complete query surface —
  every UI screen is one or the other.
]

#defterm([Best-score vs. every-run boards])[
  Two admission semantics. _Best-score_: a player occupies exactly one slot,
  holding their personal best; a worse new score changes nothing. _Every-run_
  (arcade-style): each match is its own entry and one player may hold many
  slots. We design best-score — the common default — and note where
  every-run differs (Section 6.10).
]

== Scope & Clarifying Questions

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

#defterm([Neighborhood query])[
  The ±r entries around a given player's rank — the "you are here" view. It
  is the query that makes the problem famous: it requires *rank* (to locate
  the player) and *ordered iteration* (to walk r places in both directions),
  at any depth in the ordering, in milliseconds.
]

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

== Non-Functional Requirements

#defterm([Order-statistics query])[
  A query about *position* in an ordering — "rank of X", "the k-th element",
  "count of entries above Y" — as opposed to a lookup by key. Supporting
  order statistics efficiently under inserts/deletes requires an ordered
  structure augmented with subtree/span counts (Section 6.7); plain hash
  indexes cannot answer them at all, and plain sorted scans answer them at
  O(n).
]

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

#insight([Reads and writes are both modest — the *operation mix* is the design])[
  Nothing here rivals Chapter 4's firehose or Chapter 5's vote storm. What is
  unusual: the system must maintain a *total order* over 10⁸ entries, mutate
  it 25k times a second, and answer positional queries — top-K, rank,
  neighborhood — in milliseconds. Data structure choice *is* the
  architecture; everything else is distribution plumbing around one ordered
  set.
]

== Back-of-the-Envelope Estimation

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

#insight([The whole working set fits in RAM — spend it])[
  20 GB for the all-time board is one machine's RAM, or a few shards' worth.
  That licenses the chapter's central decision: keep boards *in memory* in a
  purpose-built ordered structure with O(log n) everything, replicate for
  reads and failover, journal for durability. A disk-first database would
  answer the same queries 10–100× slower for zero capacity benefit. Capacity
  is solved; latency and structure are the game.
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
collection of 10⁸. Walk the candidate structures:

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

#pitfall([The `COUNT(*)` rank trap])[
  The most common wrong answer: store scores in a relational table, index the
  score column, and compute rank as `SELECT COUNT(*) WHERE score > :mine`.
  The index makes top-K fine, but rank-by-count touches *every entry above
  the player* — for rank 1.2M of 200M, that is a 198.8M-row index scan per
  query, thousands of times a second. Rank must be *maintained by the
  structure*, not computed by counting. This is the sentence the interviewer
  is listening for.
]

== Deep Dive: The Data Structure — Skip List with Spans

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

Why this over a balanced tree: same asymptotics, but level-promotion makes
inserts/deletes local (no rotations), concurrent implementations are far
simpler (only level 0 needs careful linking), and span bookkeeping is an
~10-line addition. It is exactly the structure at the core of the industry's
canonical sorted-set implementations — `hash map player→node` for O(1)
lookup, skip list for order and rank.

Ties slot in cleanly: the ordering key is not `score` but the triple
`(score desc, achieved_at asc, player_id)` — deterministic total order, no
equal keys, "first to achieve" falls out of the comparison itself. Section
6.13 implements it on an ordered map (same complexity story; Rust's std
ordered map lacks spans, and the listing says so honestly).

== API Design

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
`region:eu:daily:2026-09-05`). Cursors are the rank triple, opaque and
base64'd — Chapter 5's pagination lesson, and here the cursor *is* the
ordering key, so paging is a pure `range()` from the cursor position.
Submission responses return `{accepted, improved, current_best}` so clients
can celebrate personal bests without a second call.

== High-Level Architecture

#v(0.3em)
#align(center)[
#canvas(h: 6.6cm)[
  // top row
  #node(0.2cm, 0.1cm, 3.2cm, 1.0cm, [Game servers \ match results], fill: faint, edge: slate, size: 7.4pt)
  #node(4.4cm, 0.1cm, 3.2cm, 1.0cm, [Score API \ validate · dedupe], fill: white, edge: primary, size: 7.4pt)
  #node(8.6cm, 0.1cm, 3.4cm, 1.0cm, [Ingestion queue \ smooth bursts], fill: white, edge: teal, size: 7.4pt)
  #node(13.2cm, 0.1cm, 3.3cm, 1.0cm, [Anti-cheat \ quarantine feed], fill: faint-red, edge: crimson, size: 7.4pt)
  // middle
  #node(4.4cm, 2.3cm, 3.6cm, 1.0cm, [Rank engine \ ordered sets in RAM], fill: white, edge: primary, size: 7.4pt)
  #node(9.4cm, 2.3cm, 3.2cm, 1.0cm, [Replicas \ read scale · failover], fill: faint-blue, edge: primary, size: 7.4pt)
  #node(13.2cm, 2.3cm, 3.3cm, 1.0cm, [Journal + snapshots \ durability], fill: faint-blue, edge: primary, size: 7.4pt)
  // bottom
  #node(0.2cm, 4.6cm, 3.2cm, 1.0cm, [Read API \ top-K · rank · around], fill: white, edge: primary, size: 7.4pt)
  #node(4.4cm, 4.6cm, 3.2cm, 1.0cm, [Page cache \ top-100 windows], fill: white, edge: teal, size: 7.4pt)
  #node(8.6cm, 4.6cm, 3.4cm, 1.0cm, [Friends service \ overlay filter], fill: white, edge: slate, size: 7.4pt)
  #node(13.2cm, 4.6cm, 3.3cm, 1.0cm, [Players \ web · mobile · in-game], fill: faint, edge: slate, size: 7.4pt)
  // arrows top
  #arrow(3.45cm, 0.6cm, 4.35cm, 0.6cm)
  #arrow(7.65cm, 0.6cm, 8.55cm, 0.6cm)
  #glabel(7.0cm, 0.85cm, [2.3k/s avg], size: 6.6pt)
  // queue to engine
  #arrow(10.3cm, 1.13cm, 6.6cm, 2.25cm, color: teal)
  #glabel(8.0cm, 1.75cm, [25k/s peak], fg: teal.darken(12%), size: 6.6pt)
  // anti-cheat to engine
  #arrow(14.6cm, 1.13cm, 8.1cm, 2.5cm, color: crimson, dashed: true)
  #glabel(12.6cm, 1.75cm, [evict / hold], fg: crimson, size: 6.6pt)
  // engine to replicas and journal
  #arrow(8.05cm, 2.8cm, 9.35cm, 2.8cm)
  #arrow(8.05cm, 3.0cm, 13.15cm, 2.9cm, color: slate)
  // read path
  #arrow(11.0cm, 3.33cm, 3.2cm, 4.55cm, color: slate)
  #glabel(7.7cm, 4.05cm, [rank · around], size: 6.6pt)
  #arrow(3.45cm, 5.1cm, 4.35cm, 5.1cm)
  #arrow(7.65cm, 5.1cm, 8.55cm, 5.1cm)
  #arrow(12.05cm, 5.1cm, 13.15cm, 5.1cm)
  #glabel(1.6cm, 3.85cm, [top-K pages], size: 6.6pt)
  #arrow(5.9cm, 4.55cm, 5.9cm, 3.33cm, color: teal, dashed: true)
  #glabel(0.2cm, 6.05cm, [Writes: validate → queue → in-memory ordered sets (replicated, journaled). Reads: cached pages for the top, live rank queries for everything else.], size: 7pt)
]]
#v(0.2em)

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Component], hcell[Responsibility], hcell[Why it is shaped this way]),
  body: (
    [Score API], [Authenticate game servers, validate, dedupe by `match_id`], [Writes enter through one narrow, auditable door],
    [Ingestion queue], [Buffer score events; absorb event-day bursts], [Chapter 4's shock absorber; ingestion lag becomes a metric, not an outage],
    [Rank engine], [Holds all boards as in-memory ordered sets; applies best-score updates; serves rank/top-K/around], [The structure of Section 6.7 *is* the system; 20 GB fits in RAM (Section 6.5)],
    [Replicas], [Read scale-out + hot standby], [Rank reads ×12k/s spread; promotion covers node loss],
    [Journal + snapshots], [Append-only update log; periodic board dumps], [Recovery = latest snapshot + replay; the board is rebuildable, never lost],
    [Anti-cheat], [Consumes the same stream; quarantines suspects], [A consumer like any other — removal is just a delete from the set],
    [Page cache], [Top-100 pages per board, few-second TTL], [The podium is read ~10³× more often than it changes (top-100 churn is slow; Section 6.14)],
    [Friends service], [Intersection of friend list with board entries], [Small overlays computed on read; Section 6.12],
  ),
)

== Deep Dive: Score Ingestion Semantics

Best-score admission makes the write path almost suspiciously simple:

#defterm([Monotonic (idempotent) update])[
  An update whose repeated application changes nothing after the first time.
  Best-score submission is monotonic: `board[player] = max(old, new)` absorbs
  retries, duplicates, and out-of-order redeliveries for free — no dedup
  tokens, no exactly-once machinery on the hot path. (Chapter 5's votes
  needed an upsert table; here the *semantics* do the work.) The one
  non-monotonic case — same player, same score, *earlier* timestamp stealing
  the tie-break — is excluded by rule: a player's slot keeps its first
  achieving timestamp.
]

The ingestion contract, end to end:

+ Game server submits `(player, board, score, achieved_at, match_id)`; the
  Score API dedupes by `match_id` briefly (same match reported twice) and
  validates shape.
+ The queue buffers; the rank engine applies `max` updates in stream order.
  Bursts only stretch the freshness budget (≤5 s) — never correctness.
+ Anti-cheat consumes the same stream independently; a quarantine verdict
  deletes the player's entries from every board (a delete is just another
  update) and parks their submissions until cleared. The leaderboard never
  renders a quarantined score — integrity requirement, Section 6.4.
+ *Every-run variant* (arcade boards): entries keyed `(match_id)` instead of
  player; dedupe by match id is still free; top-K is unchanged; "my rank"
  becomes "my best run's rank". One sentence in the interview shows the
  abstraction holds.

== Deep Dive: Sharding and the Global Top-K

One node holds 20 GB and applies ~25k skip-list updates/s — a single beefy
rank engine covers our numbers with replicas. But boards grow (new regions,
games, seasons), so the sharding answer must be ready:

*Shard by `hash(player_id)`.* Each shard owns a complete ordered set of its
players. Then:

- *Top-K, exact*: fetch the top K from *every* shard and k-way merge.
  Correctness: any member of the global top-K has at most K−1 players
  outranking it globally, hence at most K−1 on its own shard — so it must
  appear in its shard's top-K. Fetching K per shard is sufficient and
  necessary. Cost: `shards × K` entries per query — 8 shards × 100 = 800
  entries per page, trivial.
- *My rank, exact*: `1 + Σ_shards count(better than me)` — a scatter-gather
  count across all shards, O(log n) per shard with spans, but fan-out per
  query. Fine at 1.2k rank-reads/s; painful at 10⁵/s.
- *"Top X%" displays, approximate*: each shard also maintains a fixed-boundary
  *histogram* of its scores. Histograms are *mergeable by addition* — sum the
  bucket counts and interpolate (Section 6.13) — so a global percentile is a
  cheap aggregate with no global ordering at all. This is how "top 0.4%"
  renders without ever computing 200M ranks.

#insight([Exact where it is read, approximate where it is glanced])[
  The podium (top-100) must be exact — it is the product. A player's own
  rank must be exact — they will screenshot it. The "top 2.3%" badge on a
  profile is *glanced at*, not audited — approximate it with mergeable
  histograms and save the global scatter-gather entirely. Precision is a
  budget; spend it only on surfaces where users check the math.
]

== Deep Dive: Windowed and Friends Boards

*Time windows are just keys.* A board is identified by `(scope, period)` —
`global:alltime`, `global:weekly:2026-W36`, `global:daily:2026-09-05`.
Every score submission writes to *all live windows* for its scope (daily +
weekly + all-time = three ordered-set updates, still cheap). Rotation is a
scheduler flipping the live key: yesterday's daily board stops accepting
writes, gets snapshotted to cold storage, and stays readable as a frozen
archive. No migration, no reindexing — the empty new window is created lazily
by the first write.

*Friends boards are overlays, not boards.* A friend list is ≤ a few hundred
players. On read: fetch each friend's current `(score, ts)` by direct player
lookup (the hash-map side of the ordered set, O(1) each), sort in memory,
rank locally. Milliseconds, zero storage. The alternative — materializing a
per-user friends board at write time — multiplies every score update by the
player's appearance in friend lists (a Chapter 2-style fanout write
amplification) to answer a rare query. Compute on read wins decisively here.

== Rust Reference Implementations

Three pieces with deterministic tests: the leaderboard itself, the sharded
top-K merge, and the mergeable percentile histogram.

=== The Leaderboard: Ordered Set + Player Index

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

=== Sharded Top-K: The K-Way Merge

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

=== Mergeable Percentile Histograms

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
        // score at/past the final bound: overflow bucket counts only when
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

== Scaling the Platform

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Layer], hcell[Scale axis], hcell[Mechanism]),
  body: (
    [Score API], [Submission rate], [Stateless; horizontal],
    [Ingestion queue], [25k/s avg→peak bursts], [Partitioned by board+shard key; lag is a metric, not an outage (Chapter 4 pattern)],
    [Rank engine], [Board entries × update rate], [One node per board-group until RAM or write QPS demands sharding by `hash(player)`; O(log n) updates mean a single core does ~10⁶ ops/s — 40× headroom over peak],
    [Read path], [Rank/top-K reads], [Replicas + the page cache; the podium page is shared by everyone and changes slowly — a few-second TTL absorbs the viral majority],
    [Storage], [200M-entry all-time board], [~20 GB RAM per replica; snapshots to object storage; journal retention days],
    [Windows], [Board count = scopes × live windows], [Lazy creation; frozen archives are read-only snapshots — zero live cost],
  ),
)

#insight([Top-100 churn is glacial compared to mid-table churn])[
  The millionth-best player changes rank with every match; the podium changes
  a few times an hour. So cache *top pages* aggressively (they barely move),
  serve *rank/neighborhood* live from the ordered set (they move constantly
  and are queried rarely per position), and never cache mid-table pages —
  they are wrong the moment they are written. The cache policy mirrors the
  physics of the data.
]

== Failure Modes & Degradation

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Failure], hcell[Symptom], hcell[Response]),
  body: (
    [Rank engine node loss], [Board reads fail over, writes pause seconds], [Promote a replica; it is already warm. Recovery to a fresh node = snapshot + journal replay],
    [Journal gap / corruption], [Replay inconsistency on recovery], [Checksummed journal frames; on gap, rebuild the board from match-history re-ingest (slow but total) — the board is derived state over score facts],
    [Queue backlog on event day], [Freshness degrades past 5 s], [Degrade *freshness*, never integrity: clients show "updating…" affordance; Chapter 3's limiter sheds anonymous poll traffic first],
    [Replica lag], [Stale ranks on some reads], [Version the board (update count); reads report the version so clients never go backwards within a session],
    [Hot shard], [One shard's players dominate writes], [Reshard by splitting the hash range; top-K merge is shard-count-agnostic, so reads need no coordination],
    [Anti-cheat pipeline down], [Suspect scores render], [Fail toward quarantine for *new* suspicious velocity; previously cleared scores unaffected. Integrity beats availability here — Section 6.4],
    [Clock skew in `achieved_at`], [Wrong tie-breaks], [Ties are rare and low-stakes; still, trust server receipt time over client clocks, accept `achieved_at` only within a tolerance window],
  ),
)

== Trade-offs & Alternatives

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Decision], hcell[Chosen], hcell[Alternative & why not (here)]),
  body: (
    [Storage of boards], [In-memory ordered sets + journal], [Disk-first DB: 10–100× slower rank ops for zero capacity gain — the working set fits in RAM],
    [Rank computation], [Structure-maintained (spans)], [Rank-by-count SQL: O(better-entries) per query — melts (Section 6.6)],
    [Score semantics], [Best-score, monotonic], [Every-run: right for arcade boards; same machinery, different key (match_id)],
    [Global top-K], [Per-shard top-K + k-way merge], [One global sorted set across shards: distributed ordering is a consensus problem nobody needs for a leaderboard],
    [Global percentile], [Mergeable histograms], [Exact scatter-gather counts: fine at 10³/s, wrong tool for every profile badge],
    [Friends board], [Computed on read from the friend list], [Materialized per-user boards: write fanout per score — Chapters 2/5's fanout lesson],
    [Freshness], [≤5 s via async apply], [Synchronous end-to-end: turns every match-end into a distributed transaction],
    [Live push], [Out of scope; polling + short TTL], [WebSocket fanout of rank changes: a fine Chapter 1-style add-on, but rank updates at 25k/s make push storms the default state],
  ),
)

== Observability & SLOs

#tbl(
  (auto, 1fr, auto),
  header: (hcell[Indicator], hcell[Definition], hcell[Target]),
  body: (
    [Ingest freshness], [Score accepted → reflected in rank engine, p95], [≤ 5 s],
    [Top-K latency], [Page read, cached / live, p95], [≤ 10 ms / ≤ 50 ms],
    [Rank latency], [rank + neighborhood, p95], [≤ 100 ms],
    [Board integrity], [Sampled players whose stored slot ≠ submitted best], [≈ 0 (journal-rebuildable)],
    [Quarantine latency], [Verdict → entries removed from all boards], [≤ 60 s],
    [Availability], [Reads / writes], [99.99% / 99.9%],
  ),
)

Chapter 4's platform carries all of it: ingestion lag as a consumer-lag
metric, freshness as a histogram, an alert with a `for` duration on replica
version drift. The reconciliation sampler — comparing stored slots against
recomputed bests from the journal — is this chapter's version of Chapter 5's
tally audit.

== Interview Wrap-Up

Likely follow-ups and the shape of strong answers:

+ *"Push live rank changes to clients."* Fan-out problem: 25k updates/s each
  reorder thousands of ranks — nobody's visible rank actually moved. Push
  only *material* changes: podium swaps, personal bests, crossing friends.
  Everything else is noise dressed as real-time.
+ *"Team leaderboards."* Team score = aggregate of members (sum, or ELO-style
  rating); the ordered set is identical, keyed by team. The interesting part
  is member-change handling and anti-stack incentives, not the structure.
+ *"Regional boards at 50 regions × 3 windows?"* Boards are cheap keys — 150
  extra ordered sets, each small. Writes fan out per applicable board (a
  player's score lands on their region's set + global); reads unchanged.
+ *"How do you catch cheaters?"* Server-side authority (the game server
  signs match results, clients never self-report), statistical anomaly
  detection on score distributions per level (a Chapter 4 alert on
  percentile outliers), velocity checks (Chapter 3's limiter: matches/hour
  per player), and quarantine-not-delete so false positives recover.
+ *"10⁹ players — what breaks first?"* Single-node RAM (100 GB is still one
  node, but uncomfortable) and the top-K merge fan-out staying flat — the
  design already shards; the rank scatter-gather for exact global rank is
  what you would approximate next (histograms), keeping exact rank only
  within a player's region shard.

== Summary & Further Reading

#notebox([Chapter summary])[
  A leaderboard is one primitive — *rank over a mutating total order* — and
  the chapter is the engineering that protects it. The structure is an
  ordered set: hash map for player lookup, skip list with spans for O(log n)
  rank, top-K, and neighborhoods; ties are a total ordering key `(score,
  achieved_at, id)`. Writes are monotonic best-score updates — idempotent by
  construction, journaled for durability, replicated for reads. Reads split
  by physics: the podium is cached (it barely moves), personal rank is live
  (it always moves), percentiles are approximated with mergeable histograms
  (they are glanced at, not audited). Sharding by player hash keeps top-K
  exact through a k-way merge — any global top-K member is provably inside
  its shard's top-K. Windows are keys; friends boards are overlays; cheating
  is a stream consumer with the power to delete. The lesson that transfers:
  *when the query is positional, the data structure is the architecture.*
]

*Further reading.*

- The source video: _"17: Top K Leaderboard — Systems Design Interview
  Questions With Ex-Google SWE"_ (Jordan has no life):
  `https://www.youtube.com/watch?v=nQpkRONzEQI`
- William Pugh — _"Skip Lists: A Probabilistic Alternative to Balanced
  Trees"_ (1990) — the structure of Section 6.7, including span-based ranks.
- Redis sorted sets documentation (`ZADD`/`ZRANK`/`ZRANGE`) — the canonical
  production embodiment of this chapter's ordered set.
- Cormen et al., _Introduction to Algorithms_ — the order-statistics tree
  chapter (subtree sizes) for the balanced-tree equivalent of spans.
- _"Elo rating system"_ and TrueSkill papers — for the follow-up where the
  board ranks *skill* rather than scores.

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
    [Shard sufficiency (top-K)], [The theorem that global top-K needs only K entries per shard, since a global top-K member is outranked by < K entries anywhere],
    [Skip list], [Probabilistically balanced ordered list with express lanes; O(log n) search/insert/delete without rotations],
    [Span], [Count on a skip-list forward pointer of level-0 steps covered; summing spans along a search path yields rank],
    [Tie-break], [Deterministic total order extension: `(score desc, achieved_at asc, id)` — first to achieve wins],
    [Top-K], [The first K entries of a board in order; the podium query],
    [Windowed board], [A board scoped to a time period (daily/weekly); rotation is a key change, archives are frozen snapshots],
  ),
)

#v(0.8em)
#align(center)[
  #text(size: 8.5pt, fill: slate)[
    — End of Chapter 6 · Next: Chapter 7 —
  ]
]
