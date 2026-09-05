// ============================================================================
//  CHAPTER 5 — Designing a Hierarchical Comment System (Reddit Comments)
//  Source: "15: Reddit Comments" — Systems Design Interview Questions With
//  Ex-Google SWE (channel: Jordan has no life)
//  Link: https://www.youtube.com/watch?v=BO2gRisnBcA
// ============================================================================

#import "../template.typ": *

= Designing a Hierarchical Comment System

#notebox([Problem source])[
  This chapter solves the problem posed in the talk _"15: Reddit Comments"_
  from the series _Systems Design Interview Questions With Ex-Google SWE_
  (channel: _Jordan has no life_). The task: design the commenting system of a
  Reddit-scale discussion site — nested reply threads, up/down voting, and the
  several ways users can sort a thread. The interesting parts are the *data
  shape* (a forest of unbounded trees) and the *ranking mathematics* (votes
  plus time decay plus statistical confidence), not raw storage volume — a
  deliberate contrast with Chapter 4's firehose. All terms are defined before
  use; all reference code is Rust with deterministic tests.
]

== The Problem Statement

The interviewer draws a post with a familiar indented conversation underneath
it and says:

_"Users comment on posts and reply to each other, arbitrarily deep. They
upvote and downvote comments. A thread can be sorted by 'best', 'top', 'new',
or 'controversial'. Popular posts get tens of thousands of comments, so users
page through them and expand subtrees on demand. Design the system that
stores, ranks, and serves these comment threads."_

The previous chapters designed infrastructure; this one designs a
*user-facing product surface* whose entire value is ordering: the same fifty
thousand comments are useful or useless depending on which fifteen the reader
sees first. Two hard problems hide inside — representing arbitrarily deep
trees so that subtrees can be fetched and paged cheaply, and ranking votes in
a way that is *statistically honest* and *time-aware* at write rates of
thousands of votes per second.

#defterm([Comment thread / tree])[
  The replies under one post form a _tree_: the post is the root context,
  each comment has exactly one parent (the post or another comment), and
  replies fan out to arbitrary depth and breadth. The set of trees under all
  posts is a _forest_. "The thread" usually means one post's whole tree, or a
  rendered window into it.
]

#defterm([Score / vote tally])[
  A comment's _score_ is `upvotes − downvotes`, the single number users see.
  Votes serve two masters: they produce the visible score, and they feed the
  *ranking functions* (Section 5.8) that decide display order — and those two
  consumers want different things from the same data, which is where the
  design gets interesting.
]

== Scope & Clarifying Questions

#tbl(
  (auto, 1fr),
  header: (hcell[Candidate asks], hcell[Interviewer answers]),
  body: (
    [How deep can nesting go?], [Unbounded in principle; the UI collapses past ~10 levels with a "continue this thread" link],
    [Edit and delete?], [Edits allowed briefly (mark "edited"); deletes are soft — the comment becomes a tombstone but its replies survive],
    [Are votes final?], [No — users can change or retract votes; one vote per user per comment, enforced],
    [Real-time?], [New comments should appear within seconds on refresh; no live push needed. Counts can lag a little],
    [Moderation?], [Assume a separate moderation pipeline flags/removes; we must honor removals fast. Don't design moderation itself],
    [Sort orders?], [best, top, new, controversial — "best" is the default and the tricky one],
    [Scale?], [Reddit-scale: ~70M daily users, viral posts with 10⁵ comments],
    [Anonymous reading?], [Yes — most reads are logged-out; that population is cache-friendly],
    [Media in comments?], [Text plus links only; media uploads are the Maps chapter's CDN problem, already solved],
  ),
)

#notebox([Agreed scope])[
  + *Post and reply* to arbitrary depth; soft-delete with surviving replies.
  + *Vote* up/down/retract; exactly one vote per user per comment.
  + *Sort* a thread by best / top / new / controversial, with sound
    mathematics behind each.
  + *Page* through large threads: windowed top-level listing, expandable
    subtrees, collapsed deep chains.
  + *Counts*: post-level comment counts and comment scores may be seconds
    stale, never lost.
  + Out: live push updates, moderation tooling, rich media, recommendations.
]

== Functional Requirements

#defterm([Ranking mode])[
  One of the supported orderings of a thread's comments. _Top_: highest score.
  _New_: most recent first. _Best_: highest *statistical confidence* of being
  liked (Section 5.8's Wilson score — not the same as top!). _Controversial_:
  most balanced *and* voluminous disagreement. Each mode is a different pure
  function of the same vote data — an important honesty property.
]

+ *FR-1 — Create.* Post a top-level comment on a post, or a reply to any
  existing comment, recording parent, author, timestamp, and body.
+ *FR-2 — Vote.* Cast, change, or retract one up/down vote per user per
  comment; the score reflects the change within seconds.
+ *FR-3 — Read a thread window.* Given a post, a ranking mode, and a cursor,
  return the next page of the ranked tree — top-level comments each with the
  first few levels of their best children.
+ *FR-4 — Expand a subtree.* Given any comment, return the next window of its
  children ("more replies", "continue this thread").
+ *FR-5 — Soft-delete and removal.* Deleted comments render as a tombstone
  that preserves thread structure; moderator removals disappear entirely,
  quickly.
+ *FR-6 — Post-level counters.* Comment counts per post for listing pages,
  eventually consistent within seconds.

== Non-Functional Requirements

#defterm([Read-to-write ratio])[
  The proportion of read requests to write requests a system serves. It
  dictates architecture: high ratios justify aggressive caching and
  denormalization (precomputing for reads at write time), because every write
  is amortized across thousands of reads. Comment systems are extreme —
  Section 5.5 derives roughly *35:1* on requests, and far higher on bytes.
]

#tbl(
  (auto, 1fr),
  header: (hcell[Requirement], hcell[Target & reasoning]),
  body: (
    [Thread read latency], [p95 ≤ 200 ms for a cached window, ≤ 700 ms uncached; this is the product's main surface],
    [Write latency], [p95 ≤ 300 ms for comment and vote writes; users tolerate a beat before their own comment appears],
    [Availability], [Reads ≥ 99.99% (stale cache is acceptable degradation); writes ≥ 99.9%],
    [Durability], [A confirmed comment or vote is never lost — it is social content, not telemetry (contrast Chapter 4's metrics)],
    [Vote integrity], [One-vote-per-user enforced exactly; tallies reconcile to the true vote log eventually],
    [Consistency], [Read-your-own-write for the author; seconds of staleness acceptable for everyone else],
    [Ranking freshness], [A vote visibly affects ordering within ~1 minute on hot threads; scores tick visibly on refresh],
    [Cost], [Storage is cheap here (~11 TB/year); spend engineering on read shape and ranking, not capacity],
  ),
)

#insight([This is a *shape* problem, not a *size* problem])[
  Chapter 4 drowned in bytes (170 TB/day); this chapter stores ~30 GB/day —
  three orders of magnitude less. The difficulty is that the data is a forest
  of unbounded trees that must be *ranked four ways, paged stably, and
  re-ranked continuously* as votes arrive. Interviewers use this problem to
  test data modeling and algorithmic reasoning, not capacity arithmetic.
]

== Back-of-the-Envelope Estimation

*Assumptions* (stated, then derived from): 70M daily active users; 20% read
comment threads, averaging 10 thread views; 1 in 35 thread readers writes a
comment; every comment author and ~10 lurkers vote on comments per reader;
average comment body ~500 bytes.

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Quantity], hcell[Estimate], hcell[Derivation]),
  body: (
    [Thread views], [~700M/day ≈ 8k/s avg, 40k/s peak], [14M readers × 10 views; peak ×5 for a viral moment],
    [Comments written], [~20M/day ≈ 230/s avg, ~1.2k/s peak], [20M posts' worth of discussion; 1-in-35 readers comment],
    [Votes cast], [~200M/day ≈ 2.3k/s avg, ~12k/s peak], [~10 votes per active voter; the write-heavy path],
    [Comment storage], [~30 GB/day → ~11 TB/year], [20M × ~1.5 KB with ids, indexes, overhead],
    [Vote records], [~40 GB/day raw, compacted small], [200M × ~50 B (user, comment, value, time); idempotency needs them],
    [Hot cache], [~50 GB], [Top ~1M threads' first ranked windows × ~50 KB],
    [Read bandwidth], [~800 MB/s at avg load], [8k views/s × ~100 KB rendered window],
  ),
)

#insight([Votes, not comments, are the write storm])[
  Comments arrive at ~230/s; *votes* at ~2.3k/s average and 12k/s peak — and
  each vote is a read-modify-write on *at least four* things: the voter's
  idempotency record, the comment's up/down tallies, the cached score, and
  eventually the ranked order. Naively, that is a hot-row update per vote on
  viral comments. The vote pipeline (Section 5.11) exists to make the busiest
  path in the system also the cheapest.
]

The pipeline of the rest of the chapter: Section 5.6 isolates the two hard
problems; 5.7 models the trees; 5.8 does the ranking mathematics; 5.9–5.11
design APIs, architecture, and the vote pipeline; 5.12 serves threads; 5.13
implements all of it in Rust; 5.14–5.20 scale, harden, and review.

== The Core Challenge: Trees and Honest Ordering

Two problems carry this design, and neither is capacity.

*Problem one — represent a forest of unbounded trees so that windows of it are
cheap to read.* Every read asks a deceptively simple question: "give me
top-level comments 41–60 by best, each with its first two levels of best
children." A relational row per comment answers that badly unless the schema
is designed for it; Section 5.7 compares the three classical tree encodings
and picks a hybrid.

*Problem two — rank honestly.* "Best" cannot mean "highest score": a comment
at +1 (1 up, 0 down) would outrank none and a comment at +190 (200 up, 10
down) deserves to beat one at +2 (2 up, 0 down) — raw differences ignore
*sample size*. Ranking must be a statistical statement about votes, plus a
time statement (freshness), and it must be recomputed continuously as votes
stream in. Section 5.8 derives the three functions used in production
practice.

#pitfall([Score is not rank])[
  Sorting "best" by `up − down` is the most common wrong answer in this
  interview. It ranks a 1-up-0-down comment above a 200-up-10-down one
  (+1 vs +190 is fine, but +2 vs +190 is not — and +1, 0 down beats +190
  never, yet *percentage* sorting fails oppositely: 1/1 = 100% beats
  200/210 = 95%). Both naive orders are statistically illiterate; the fix is
  a confidence bound (Section 5.8). Say this early in the interview — it is
  the question the interviewer is waiting for.
]

== Data Model: Encoding Comment Trees

#defterm([Adjacency list / materialized path / nested sets])[
  The three classical ways to store trees in a relational store. _Adjacency
  list_: each row stores `parent_id` — trivial writes, but fetching a subtree
  needs recursive queries. _Materialized path_: each row stores its whole
  ancestor chain (`/a1/b7/c3`), so a subtree is one `WHERE path LIKE
  '/a1/b7/%'` prefix scan and depth is the path length — at the cost of
  longer keys and painful subtree *moves*. _Nested sets_: each row stores
  `lft`/`rgt` bounds from a depth-first numbering, making subtrees a range
  scan but every *insert* renumbers half the tree — catastrophic at comment
  write rates.
]

#tbl(
  (auto, 1fr, 1fr, 1fr),
  header: (hcell[Property], hcell[Adjacency list], hcell[Materialized path], hcell[Nested sets]),
  body: (
    [Insert a reply], [One row], [One row (path = parent's + own id)], [One row + mass renumbering],
    [Fetch a subtree], [Recursive], [One prefix/range scan], [One range scan],
    [Fetch top-level page], [Indexed `parent_id IS NULL` scan], [`depth = 1` or path prefix], [Range union],
    [Depth of a comment], [Unknown without walking], [Path segment count], [Stored or derived],
    [Move a subtree], [One update], [Rewrite all descendant paths], [Renumber the tree],
    [Fit for comments], [Good bones], [*Best fit* — subtrees are read, rarely moved], [Unacceptable writes],
  ),
)

The chosen schema — adjacency bones, path muscle, denormalized tallies:

```text
comments
  comment_id      bigint pk
  post_id         bigint           -- shard key (Section 5.14)
  parent_id       bigint null      -- adjacency: direct parent
  path            text             -- materialized: /c1/c7/c42 (segment per ancestor)
  depth           smallint         -- = segments in path; drives collapse rules
  author_id       bigint
  body            text             -- null when tombstoned
  created_utc     timestamp
  up / down       bigint           -- denormalized tallies (vote pipeline owns them)
  state           enum             -- live | tombstone | removed
  index (post_id, path)            -- serves every window query in Section 5.12
```

`votes` is a separate table keyed `(user_id, comment_id)` — the idempotency
backbone of Section 5.11. A post's `comment_count` lives denormalized on the
`posts` row, maintained asynchronously (FR-6).

#defterm([Tombstone (soft delete)])[
  A deletion that erases content but keeps structure: body and author are
  blanked, `state` becomes `tombstone`, and the row *stays* so its replies
  still have a parent. Rendering shows "[deleted]". Hard deletion would
  orphan entire subtrees; moderation removals (`removed`) are the exception —
  they may take the subtree with them per policy.
]

== Deep Dive: The Ranking Mathematics

Three pure functions over the same two integers (`up`, `down`) plus time.
Each answers a different question honestly.

=== "Top" and "New" — trivial orders

`top` sorts by score `up − down` descending (ties by age, newest first);
`new` sorts by `created_utc` descending. Both are indexable directly. Their
weakness is statistical, which is exactly why "best" exists.

=== "Best" — the Wilson lower confidence bound

#defterm([Wilson score interval (lower bound)])[
  Treat each comment's votes as `n = up + down` Bernoulli trials estimating
  the *true probability* `p` that a random viewer upvotes it. A confidence
  interval around the observed ratio `p̂ = up/n` narrows as `n` grows; the
  _lower bound_ of the Wilson interval (at z = 1.96, ≈95%) is a pessimistic
  estimate of `p` that fairly compares comments with *different sample
  sizes*. Small-sample comments are penalized toward 0; as `n` → ∞ the bound
  approaches `p̂`. It needs only `up` and `down`, is monotonic in both, and
  costs a few flops — computable at vote time and stored.
]

$ "wilson"(u, d) = (hat(p) + z^2/(2n) - z sqrt((hat(p)(1-hat(p)) + z^2/(4n))/n)) / (1 + z^2/n), quad n = u+d, hat(p) = u\/n $

The numbers that make the point: a comment with 1 up / 0 down scores ≈ 0.21;
with 10 / 0, ≈ 0.72; with 100 / 0, ≈ 0.96. And 100 up / 100 down (p̂ = 50%
but n = 200, ≈ 0.42) correctly beats 1 / 0 — volume of evidence matters more
than a lone perfect record. Section 5.13 implements and tests exactly these.

=== "Controversial" — balanced disagreement, weighted by volume

$ "controversial"(u, d) = cases(0 & "if" min(u,d) = 0, (u + d)^(min(u,d)\/max(u,d)) & "otherwise") $

A 50/50 split on 100 votes (`balance` = 1, magnitude 100) crushes a
105-vote comment with a 100/5 split (balance = 0.05 → magnitude ≈ 1.26):
near-even splits dominate, and among equal splits the *louder* argument wins.

=== "Hot" — score with time decay (for posts and fast threads)

#defterm([Time-decay ranking ("hot")])[
  Reddit's post ranking: `"hot" = log_10 max(|s|, 1) + "sign"(s) · (t -
  t_0) / 45000`, with `s = up − down`, `t` the comment's epoch seconds, and
  `t_0` an arbitrary fixed epoch. The log makes the first 10 votes worth as
  much as the next 100 (diminishing returns); dividing age by 45,000 s
  (12.5 h) means a post must be *10× more popular* to tie one 12.5 hours
  newer. Fresh content cycles through the front page; score advantages decay
  gracefully instead of cliffing.
]

#insight([Rank is a stored, recomputed column — not a query-time sort])[
  All four functions are pure over `(up, down, created_utc)`. So the vote
  pipeline recomputes a comment's rank keys *on every vote* and stores them;
  reads are then index scans, never sorts. "Best" order changes only when
  votes change — and votes arrive at 2.3k/s, exactly the pipeline built in
  Section 5.11. Sorting 50k comments per page-view would be malpractice.
]

== API Design

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Method], hcell[Path], hcell[Purpose]),
  body: (
    [`POST`], [`/v1/posts/{id}/comments`], [Top-level comment (FR-1); body, author],
    [`POST`], [`/v1/comments/{id}/replies`], [Reply to a comment (FR-1); server computes path, depth],
    [`PUT`], [`/v1/comments/{id}/vote`], [Cast/change/retract vote: `{value: 1|-1|0}` — idempotent (FR-2)],
    [`GET`], [`/v1/posts/{id}/comments?sort=&cursor=&limit=`], [Ranked thread window with shallow children (FR-3)],
    [`GET`], [`/v1/comments/{id}/children?cursor=&limit=`], [Expand a subtree window (FR-4)],
    [`DELETE`], [`/v1/comments/{id}`], [Soft-delete → tombstone (FR-5); author-only],
    [`GET`], [`/v1/posts/{id}/comments/count`], [Post-level counter (FR-6); cacheable, seconds-stale],
  ),
)

Two deliberate choices:

- *Opaque cursors, never offsets.* A cursor encodes the last seen rank key
  and comment id (`base64(wilson, id)`); offsets break the moment a new
  comment inserts above the reader's position — Chapter 1's cursor lesson
  applied to ranked lists. Ties are impossible: `(rank_key, comment_id)` is a
  total order.
- *Votes are `PUT`, not `POST`.* Repeating or flipping a vote is one
  idempotent operation on a `(user, comment)` resource, not an event stream
  the client can double-fire. Retries are free.

== High-Level Architecture

#v(0.3em)
#align(center)[
#canvas(h: 6.9cm)[
  // top: clients and API
  #node(0.2cm, 0.1cm, 3.1cm, 1.0cm, [Clients \ web · mobile · logged-out], fill: faint, edge: slate, size: 7.4pt)
  #node(4.3cm, 0.1cm, 3.3cm, 1.0cm, [API layer \ authz · validation], fill: white, edge: primary, size: 7.4pt)
  #node(8.6cm, 0.1cm, 3.4cm, 1.0cm, [Rate limiter \ per-user write caps], fill: white, edge: amber.darken(15%), size: 7.4pt)
  // middle: services
  #node(0.2cm, 2.2cm, 3.6cm, 1.0cm, [Comment service \ create · path · delete], fill: white, edge: primary, size: 7.2pt)
  #node(4.6cm, 2.2cm, 3.6cm, 1.0cm, [Vote service \ idempotent cast · tally], fill: white, edge: primary, size: 7.2pt)
  #node(9.0cm, 2.2cm, 3.6cm, 1.0cm, [Thread reader \ windows · expansion], fill: white, edge: primary, size: 7.2pt)
  // middle-low: queue + ranker
  #node(4.6cm, 4.15cm, 3.6cm, 0.95cm, [Event log \ vote & comment events], fill: white, edge: teal, size: 7.2pt)
  #node(9.0cm, 4.15cm, 3.6cm, 0.95cm, [Rank updater \ recompute rank keys], fill: white, edge: teal, size: 7.2pt)
  // bottom: stores
  #node(0.2cm, 5.7cm, 3.6cm, 1.0cm, [Comments DB \ sharded by post_id], fill: faint-blue, edge: primary, size: 7.2pt)
  #node(4.6cm, 5.7cm, 3.6cm, 1.0cm, [Votes DB \ (user, comment) → value], fill: faint-blue, edge: primary, size: 7.2pt)
  #node(9.0cm, 5.7cm, 3.6cm, 1.0cm, [Thread cache \ ranked windows per sort], fill: faint-blue, edge: primary, size: 7.2pt)
  #node(13.4cm, 2.2cm, 3.2cm, 1.0cm, [Moderation \ removals feed], fill: faint-red, edge: crimson, size: 7.4pt)
  // arrows
  #arrow(3.35cm, 0.6cm, 4.25cm, 0.6cm)
  #arrow(7.65cm, 0.6cm, 8.55cm, 0.6cm)
  #arrow(10.3cm, 1.13cm, 2.0cm, 2.15cm)
  #arrow(10.3cm, 1.13cm, 6.4cm, 2.15cm)
  #arrow(10.3cm, 1.13cm, 10.8cm, 2.15cm)
  #glabel(11.15cm, 1.5cm, [writes throttled], size: 6.6pt)
  // services to stores/queue
  #arrow(2.0cm, 3.23cm, 2.0cm, 5.65cm)
  #arrow(6.4cm, 3.23cm, 6.4cm, 4.1cm)
  #arrow(6.4cm, 5.13cm, 6.4cm, 5.65cm)
  #glabel(6.6cm, 5.42cm, [tallies], size: 6.6pt)
  #arrow(8.25cm, 4.6cm, 8.95cm, 4.6cm, color: teal)
  #arrow(10.8cm, 5.13cm, 10.8cm, 5.65cm)
  #arrow(10.8cm, 5.13cm, 3.9cm, 5.9cm, color: teal)
  #arrow(2.0cm, 5.9cm, 8.95cm, 5.9cm, color: slate)
  #arrow(10.8cm, 3.23cm, 10.8cm, 4.1cm, color: slate)
  #glabel(11.0cm, 3.6cm, [cache fill], size: 6.6pt)
  // moderation
  #arrow(14.2cm, 3.25cm, 1.4cm, 3.5cm, color: crimson, dashed: true)
  #glabel(12.55cm, 3.42cm, [removals], fg: crimson, size: 6.6pt)
  #glabel(0.2cm, 7.15cm, [Writes go through services to the DBs and the event log; rank keys are recomputed asynchronously; reads hit cached ranked windows.], size: 7pt)
]]
#v(0.2em)

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Component], hcell[Responsibility], hcell[Why it is shaped this way]),
  body: (
    [API layer], [Auth, validation, routing], [Stateless; scales horizontally behind a load balancer],
    [Rate limiter], [Per-user caps on comment & vote writes], [Chapter 3 verbatim: comments/hour, votes/minute — the first anti-brigading wall],
    [Comment service], [Create replies (computing `path`/`depth`), edits, tombstones], [Owns the tree invariants; the only writer of `comments` rows],
    [Vote service], [Idempotent cast/change/retract; owns `votes` table], [One writer per vote record; the idempotency enforcer (Section 5.11)],
    [Event log], [Durable stream of vote & comment events], [Decouples tally/rank recomputation from the write path — Chapter 4's buffer lesson],
    [Rank updater], [Recompute tallies, Wilson, hot, controversial; write rank keys; bump post counters], [Turns 2.3k votes/s into batched, coalesced rank updates],
    [Comments DB], [Tree rows, sharded by `post_id`], [One post's whole thread lives on one shard — window queries stay single-shard],
    [Votes DB], [`(user, comment) → value`], [Sharded by `comment_id`; the ground truth for reconciliation],
    [Thread cache], [Pre-rendered ranked windows per post × sort], [35:1 read ratio + logged-out majority = the tier that actually serves traffic],
    [Moderation feed], [Removals pushed to comment service], [Honored in seconds (agreed scope); separate pipeline, not designed here],
  ),
)

== Deep Dive: The Vote Pipeline

The busiest path in the system deserves the most engineering. Requirements:
one vote per user (exactly), changeable, never lost, score visible in
seconds, rank keys refreshed continuously.

#defterm([Idempotent write / natural idempotency key])[
  A write that can be applied any number of times with the same effect.
  Retries, double-clicks, and client bugs make *at-least-once* delivery the
  honest assumption, so the handler must deduplicate. Here the key is free:
  `(user_id, comment_id)` is the natural primary key of a vote — one row per
  pair, upserted, is the deduplication mechanism itself. No tokens, no
  expiry windows (contrast Chapter 3's idempotency keys on payment APIs).
]

The write path for `PUT /v1/comments/c42/vote {value: -1}`:

+ *Rate-limit* the user (Chapter 3: sliding window, votes/minute).
+ *Upsert* `votes[(u, c42)] = -1` in one statement returning the previous
  value — the atomic read-modify-write that Chapter 3's TOCTOU section warns
  about; the unique key makes it safe:
  ```text
  -- one atomic statement; all clauses share one snapshot, so `old`
  -- reads the pre-upsert value
  WITH old AS (
    SELECT value FROM votes WHERE user_id = $1 AND comment_id = $2
  )
  INSERT INTO votes (user_id, comment_id, value, updated_utc)
  VALUES ($1, $2, $3, now())
  ON CONFLICT (user_id, comment_id)
  DO UPDATE SET value = $3, updated_utc = now()
  RETURNING (SELECT value FROM old) AS prev_value;
  ```
+ *Emit* a `VoteChanged{user, comment, prev, new}` event to the log. The
  request returns here — the write path is *two* durable operations.
+ *Rank updater* consumes events, *coalesces* bursts per comment (200 votes
  in a second become one recompute), recomputes tallies
  `up += (new==1) − (prev==1)`, `down += (new==-1) − (prev==-1)`, re-derives
  Wilson/hot/controversial, writes them back, and *version-stamps* the thread
  cache so the next read repopulates.

#insight([Coalescing is the whole trick])[
  A viral comment can take thousands of votes per minute, but its *rank key*
  only needs recomputing a few times a minute — readers cannot perceive
  faster change, and sorting is stable between recomputes. Treating votes as
  a stream to be compacted (latest-wins per user; batch-sum per comment)
  turns the hottest write path into a trickle of rank updates. The score
  users see may lag the truth by seconds — the agreed scope allows exactly
  that, and spends the savings on reads.
]

*Reconciliation.* Tallies are derived state; `votes` is ground truth. A
nightly job (and a per-comment repair tool) recomputes tallies from `votes`
and fixes drift — the same discipline as Chapter 4's buffer replays: *derived
numbers must be rebuildable from the event record.*

== Deep Dive: Reading a Thread Window

A thread read assembles a *window* of the tree: a page of top-level comments,
each carrying its first levels of best children, with everything past the
depth cap collapsed behind an affordance. With the schema of Section 5.7 the
whole window is two queries:

+ *Top-level page*: `WHERE post_id = $1 AND depth = 1 ORDER BY rank_key DESC,
  comment_id DESC LIMIT $2` with the cursor supplying the rank-key boundary —
  a single index range scan on `(post_id, rank)` per sort mode.
+ *Children fill*: for the ≤20 parents in the page, one batched prefix scan
  `WHERE post_id = $1 AND path ~ ANY ('/c41/%', '/c87/%', ...) AND depth <= 4
  ORDER BY path` — materialized paths turn "first two levels of every parent
  on the page" into *one* query instead of N recursive ones (the N+1 that
  sinks the naive adjacency-list design).

Assembly is in memory: parents in rank order, children nested under them by
path prefix, tombstones rendered as "[deleted]" placeholders, subtrees beyond
depth 10 replaced by a `{continue_thread: comment_id}` token the client
expands through `/children` (FR-4).

#v(0.3em)
#align(center)[
#canvas(h: 4.6cm)[
  #node(6.2cm, 0.1cm, 3.4cm, 0.85cm, [Post \ comment_count: 51 203], fill: faint, edge: slate, size: 7.4pt)
  // window
  #node(0.6cm, 1.7cm, 3.2cm, 0.8cm, [c41 · best top-level \ wilson 0.96 · +2.1k], fill: white, edge: primary, size: 7pt)
  #node(1.5cm, 3.0cm, 3.0cm, 0.8cm, [c87 · reply \ wilson 0.91], fill: white, edge: primary, size: 7pt)
  #node(2.4cm, 4.15cm, 3.0cm, 0.75cm, [c102 · reply \ "[deleted]"], fill: faint, edge: slate, size: 7pt)
  #node(6.6cm, 1.7cm, 3.2cm, 0.8cm, [c55 · 2nd top-level \ wilson 0.94], fill: white, edge: primary, size: 7pt)
  #node(7.5cm, 3.0cm, 3.2cm, 0.8cm, [c90 · collapsed \ + 1 812 replies], fill: faint-amber, edge: amber.darken(15%), size: 7pt)
  #node(12.2cm, 1.7cm, 3.6cm, 0.8cm, [cursor → next page \ after (0.94, c55)], fill: white, edge: teal, size: 7pt)
  // edges
  #arrow(7.3cm, 0.98cm, 2.2cm, 1.65cm, color: slate)
  #arrow(7.9cm, 0.98cm, 8.2cm, 1.65cm, color: slate)
  #arrow(9.5cm, 1.25cm, 13.4cm, 1.65cm, color: teal, dashed: true)
  #arrow(2.4cm, 2.53cm, 2.9cm, 2.95cm, color: slate)
  #arrow(3.1cm, 3.83cm, 3.6cm, 4.1cm, color: slate)
  #arrow(8.4cm, 2.53cm, 8.9cm, 2.95cm, color: slate)
  #glabel(0.6cm, 5.35cm, [Window = ranked top-level page + shallow children. Depth 10+ collapses; the cursor resumes where the page ended.], size: 7pt)
]]
#v(0.2em)

*Caching.* The rendered window JSON is cached under `(post_id, sort, cursor)`
for logged-out readers — the majority (Section 5.2) — and the rank updater
*version-stamps* the post on every coalesced update, so stale windows age out
within seconds without any invalidation fanout. Logged-in readers get the
same window plus a per-user vote overlay (`SELECT comment_id, value FROM
votes WHERE user_id = $1 AND comment_id = ANY(...)`) merged at read time —
personalization over a shared cache, instead of a cache per user.

#tip([Window, don't tree])[
  The API never returns "the thread" — only windows: ranked top-level pages,
  shallow children, explicit expansions. A 50k-comment thread is 50k rows the
  user will never scroll; serving the *shape* of the conversation (best
  subthreads first, depth capped) is both the product-correct and the
  systems-correct answer. Candidates who serialize whole trees lose the room.
]

== Rust Reference Implementations

Four pieces with deterministic tests: the ranking trio, the tree model with
windowing, the idempotent vote service, and cursor pagination.

=== The Ranking Functions

```rust
/// z = 1.96 -> ~95% confidence. The lower Wilson bound of the true
/// upvote probability, from (up, down) alone. Pessimistic for small n.
pub fn wilson_lower(up: u64, down: u64) -> f64 {
    let n = (up + down) as f64;
    if n == 0.0 { return 0.0; }
    let z: f64 = 1.96;
    let phat = up as f64 / n;
    let denom = 1.0 + z * z / n;
    let centre = phat + z * z / (2.0 * n);
    let margin = z * ((phat * (1.0 - phat) + z * z / (4.0 * n)) / n).sqrt();
    (centre - margin) / denom
}

/// Reddit's "hot": log score + age bonus. 45_000s = 12.5h; a comment must
/// be 10x more popular to tie one 12.5h newer. t0 is a fixed epoch.
pub fn hot(up: u64, down: u64, epoch_secs: i64) -> f64 {
    const T0: i64 = 1_134_028_003; // Reddit's original launch epoch
    let s = up as i64 - down as i64;
    let order = s.unsigned_abs().max(1) as f64;
    let order = order.log10();
    let sign = (s > 0) as i8 as f64 - (s < 0) as i8 as f64;
    order + sign * (epoch_secs - T0) as f64 / 45_000.0
}

/// Balanced disagreement weighted by volume: (u+d)^(min/max).
pub fn controversial(up: u64, down: u64) -> f64 {
    let (lo, hi) = (up.min(down), up.max(down));
    if lo == 0 { return 0.0; }
    ((up + down) as f64).powf(lo as f64 / hi as f64)
}

#[cfg(test)]
mod ranking_tests {
    use super::*;

    #[test]
    fn wilson_grows_with_sample_size_at_same_ratio() {
        // all 100% approval, increasing n: 0.21 -> 0.72 -> 0.96
        let (w1, w10, w100) =
            (wilson_lower(1, 0), wilson_lower(10, 0), wilson_lower(100, 0));
        assert!((w1 - 0.2065).abs() < 1e-3, "w1 = {w1}");
        assert!((w10 - 0.7225).abs() < 1e-3, "w10 = {w10}");
        assert!((w100 - 0.9630).abs() < 1e-3, "w100 = {w100}");
        assert!(w1 < w10 && w10 < w100);
    }

    #[test]
    fn wilson_prefers_proven_mediocre_to_lucky_perfect() {
        // 100/100 (phat 50%, n 200) beats 1/0: evidence over luck.
        let proven = wilson_lower(100, 100);
        assert!((proven - 0.4307).abs() < 1e-3, "{proven}");
        assert!(proven > wilson_lower(1, 0));
        assert!(wilson_lower(0, 0) == 0.0);
        assert!(wilson_lower(0, 5) < wilson_lower(1, 5));
    }

    #[test]
    fn hot_decay_needs_10x_score_per_12h30m() {
        let t = 1_700_000_000;
        let older = hot(100, 0, t);
        let newer = hot(10, 0, t + 45_000);
        assert!((older - newer).abs() < 1e-9);
        assert!(hot(0, 10, t) < hot(0, 1, t)); // downvotes push below zero-side
    }

    #[test]
    fn controversial_needs_both_balance_and_volume() {
        let even_split = controversial(50, 50);      // 100^1.0
        let loud_blowout = controversial(100, 5);    // 105^0.05
        assert!((even_split - 100.0).abs() < 1e-9);
        assert!((loud_blowout - 1.2619).abs() < 1e-3, "{loud_blowout}");
        assert!(even_split > loud_blowout);
        assert_eq!(controversial(0, 100), 0.0);      // no disagreement
    }
}
```

=== The Tree Model: Paths, Depth, Tombstones

```rust
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State { Live, Tombstone }

#[derive(Debug, Clone)]
pub struct Comment {
    pub id: u64,
    pub parent_id: Option<u64>,
    pub created_ms: u64,
    pub up: u64,
    pub down: u64,
    pub state: State,
    pub body: String,
}

impl Comment {
    pub fn score(&self) -> i64 { self.up as i64 - self.down as i64 }

    /// Materialized path segment: parent path + own id.
    pub fn path(&self, parent_path: &str) -> String {
        format!("{}/{}", parent_path, self.id) // "" -> "/1" -> "/1/2" -> ...
    }

    pub fn render_body(&self) -> &str {
        match self.state {
            State::Live => &self.body,
            State::Tombstone => "[deleted]",
        }
    }
}

/// Depth-first flatten of a thread for rendering: parents before children,
/// siblings ranked by score (stand-in for "best" at read time). Tombstones
/// keep their position so replies are not orphaned.
pub fn flatten_thread(rows: &[Comment]) -> Vec<(usize, &Comment)> {
    let mut children: HashMap<Option<u64>, Vec<&Comment>> = HashMap::new();
    for c in rows {
        children.entry(c.parent_id).or_default().push(c);
    }
    for kids in children.values_mut() {
        kids.sort_by(|a, b| {
            b.score()
                .cmp(&a.score())
                .then(b.created_ms.cmp(&a.created_ms)) // newer wins ties
                .then(a.id.cmp(&b.id))                 // total order: no ambiguity
        });
    }
    let mut out = Vec::with_capacity(rows.len());
    let mut stack: Vec<(usize, &Comment)> = Vec::new();
    if let Some(roots) = children.get(&None) {
        for c in roots.iter().rev() {
            stack.push((1, *c)); // top-level comments have depth 1
        }
    }
    while let Some((depth, c)) = stack.pop() {
        out.push((depth, c));
        if let Some(kids) = children.get(&Some(c.id)) {
            for k in kids.iter().rev() {
                stack.push((depth + 1, *k));
            }
        }
    }
    out
}

#[cfg(test)]
mod tree_tests {
    use super::*;

    fn c(id: u64, parent: Option<u64>, up: u64, state: State) -> Comment {
        Comment { id, parent_id: parent, created_ms: id * 1000,
                  up, down: 0, state, body: format!("body {id}") }
    }

    #[test]
    fn window_is_dfs_with_ranked_siblings() {
        let rows = vec![
            c(1, None, 10, State::Live),
            c(2, Some(1), 5, State::Live),
            c(3, Some(1), 8, State::Live),
            c(4, Some(2), 1, State::Live),
            c(5, None, 20, State::Tombstone),
            c(6, Some(5), 3, State::Live),
        ];
        let flat = flatten_thread(&rows);
        let ids: Vec<u64> = flat.iter().map(|(_, c)| c.id).collect();
        // roots by score: 5 (20) then 1 (10); children of 1: 3 (8) then 2 (5)
        assert_eq!(ids, vec![5, 6, 1, 3, 2, 4]);
        // depth tracks nesting
        assert_eq!(flat.iter().find(|(_, c)| c.id == 4).unwrap().0, 3);
        assert_eq!(flat.iter().find(|(_, c)| c.id == 1).unwrap().0, 1);
    }

    #[test]
    fn tombstone_hides_body_but_keeps_subtree() {
        let rows = vec![c(5, None, 20, State::Tombstone),
                        c(6, Some(5), 3, State::Live)];
        let flat = flatten_thread(&rows);
        assert_eq!(flat[0].1.render_body(), "[deleted]");
        assert_eq!(flat[1].1.render_body(), "body 6");
    }

    #[test]
    fn materialized_paths_compose() {
        let (c1, c2, c4) = (c(1, None, 0, State::Live),
                            c(2, Some(1), 0, State::Live),
                            c(4, Some(2), 0, State::Live));
        let p1 = c1.path("");
        let p2 = c2.path(&p1);
        assert_eq!(c4.path(&p2), "/1/2/4");
        assert_eq!(p2.matches('/').count(), 2); // segment count == depth
    }
}
```

=== The Idempotent Vote Service

```rust
use std::collections::HashMap;

/// Natural idempotency key: (user, comment). One row per pair; upserts.
#[derive(Default)]
pub struct VoteService {
    votes: HashMap<(u64, u64), i8>, // value in {-1, 0, +1}; 0 == retracted
}

impl VoteService {
    /// Cast / change / retract a vote. Returns (delta_up, delta_down) for
    /// the rank updater to apply to the comment's tallies — the whole
    /// effect of the vote in two integers.
    pub fn cast(&mut self, user: u64, comment: u64, value: i8) -> (i64, i64) {
        assert!((-1..=1).contains(&value));
        let prev = self.votes.insert((user, comment), value).unwrap_or(0);
        let delta = |old: i8, new: i8, side: i8| {
            ((new == side) as i64) - ((old == side) as i64)
        };
        (delta(prev, value, 1), delta(prev, value, -1))
    }
}

#[cfg(test)]
mod vote_tests {
    use super::*;

    #[test]
    fn repeat_and_flip_and_retract() {
        let mut svc = VoteService::default();
        assert_eq!(svc.cast(7, 42, 1), (1, 0));   // new upvote
        assert_eq!(svc.cast(7, 42, 1), (0, 0));   // retry: no double count
        assert_eq!(svc.cast(7, 42, -1), (-1, 1)); // flip: score swings by 2
        assert_eq!(svc.cast(7, 42, 0), (0, -1));  // retract
        assert_eq!(svc.cast(8, 42, 1), (1, 0));   // another user unaffected
    }

    #[test]
    fn folding_deltas_reproduces_true_tallies() {
        let mut svc = VoteService::default();
        let deltas = [svc.cast(7, 42, 1), svc.cast(7, 42, -1),
                      svc.cast(8, 42, 1)];
        let (up, down) = deltas
            .iter()
            .fold((0i64, 0i64), |(u, d), &(du, dd)| (u + du, d + dd));
        assert_eq!((up, down), (1, 1)); // 7's flip + 8's upvote
    }
}
```

=== Cursor Pagination over a Ranked List

```rust
/// Map an f64 to bits whose unsigned order matches the float's order —
/// so rank keys can live in opaque cursors and database indexes.
pub fn ordered_bits(f: f64) -> u64 {
    let b = f.to_bits();
    if b & (1 << 63) == 0 { b | (1 << 63) } else { !b }
}

/// Total order per comment: (rank desc, id desc). No ties, ever.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct RankKey {
    pub wilson: u64, // ordered_bits(wilson_lower(up, down))
    pub id: u64,
}

pub type Cursor = RankKey; // the client treats it as opaque base64

/// Next page strictly after `after` from a list sorted descending.
pub fn page_after(
    sorted_desc: &[RankKey],
    after: Option<Cursor>,
    limit: usize,
) -> (Vec<RankKey>, Option<Cursor>) {
    let start = match after {
        None => 0,
        Some(c) => sorted_desc
            .iter()
            .position(|&k| k == c)
            .map(|i| i + 1)
            .unwrap_or(sorted_desc.len()),
    };
    let page: Vec<RankKey> =
        sorted_desc.iter().skip(start).take(limit).copied().collect();
    let next = match page.last() {
        Some(&last) if start + page.len() < sorted_desc.len() => Some(last),
        _ => None,
    };
    (page, next)
}

#[cfg(test)]
mod page_tests {
    use super::*;
    use crate::wilson_lower; // from the ranking listing (same crate)

    fn key(up: u64, down: u64, id: u64) -> RankKey {
        RankKey { wilson: ordered_bits(wilson_lower(up, down)), id }
    }

    #[test]
    fn ordered_bits_preserves_float_order() {
        assert!(ordered_bits(0.72) > ordered_bits(0.21));
        assert!(ordered_bits(-1.0) < ordered_bits(0.0));
    }

    #[test]
    fn pages_cover_everything_once_and_are_stable() {
        let mut keys = vec![
            key(100, 0, 1), // 0.963
            key(10, 0, 2),  // 0.722
            key(10, 0, 3),  // 0.722 — tie with id 2, broken by id desc
            key(1, 0, 4),   // 0.207
            key(0, 1, 5),   // 0.0
        ];
        keys.sort_by(|a, b| b.cmp(a)); // (wilson desc, id desc)

        let (p1, c1) = page_after(&keys, None, 2);
        let (p2, c2) = page_after(&keys, c1, 2);
        let (p3, c3) = page_after(&keys, c2, 2);
        let ids: Vec<u64> =
            [p1.as_slice(), &p2, &p3].concat().iter().map(|k| k.id).collect();
        assert_eq!(ids, vec![1, 3, 2, 4, 5]); // no skips, no duplicates
        assert_eq!(c1.unwrap().id, 3);        // cursor = last item of page
        assert!(c3.is_none());                // exhausted
    }
}
```

== Scaling the Platform

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Layer], hcell[Scale axis], hcell[Mechanism]),
  body: (
    [API / services], [Request rate], [Stateless; horizontal scaling behind load balancers],
    [Comments DB], [Posts × comments], [Shard by `post_id` — a whole thread on one shard, so every window query is single-shard; viral posts are one *hot* shard, handled by cache, not resharding],
    [Votes DB], [Users × votes], [Shard by `comment_id` — tallies per comment stay local; lookup by user is the rare path (vote overlay), served by a secondary index],
    [Event log / rank updater], [Vote rate 2.3k/s avg], [Partitioned by `comment_id`; coalescing collapses bursts — consumer count tracks partitions, not votes],
    [Thread cache], [Concurrent readers], [Window JSON is immutable between version stamps → any number of replicas; logged-out traffic is fully cacheable],
    [Read bandwidth], [800 MB/s avg], [Edge/CDN for logged-out windows; the origin only serves logged-in overlays and cache misses],
  ),
)

#insight([The viral-post problem is a cache problem, not a database problem])[
  A post that makes the front page concentrates a meaningful share of the
  *entire site's* read QPS onto one shard's rows. Sharding cannot help — one
  post has one home. What helps: the ranked-window cache (one fill serves
  millions of reads between version stamps), read replicas of the hot shard
  for cache misses, and coalesced rank updates so the vote storm does not
  translate into row-write storms. Measure success as *origin QPS during a
  viral event* staying flat.
]

== Failure Modes & Degradation

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Failure], hcell[Symptom], hcell[Response]),
  body: (
    [Tally drift], [Displayed score ≠ vote log sum], [Expected in small doses (coalescing, replays); nightly reconciliation recomputes tallies from `votes`; a repair endpoint fixes single comments],
    [Rank updater lag], [Scores update, order doesn't], [Visible as consumer lag (Chapter 4's meta-metrics); degraded mode = windows re-sorted by stored (stale) rank keys — the product blurs, never breaks],
    [Event log outage], [Writes accepted, ranks frozen], [Vote service buffers events locally (Chapter 4's agent pattern); on recovery the backlog replays and coalesces],
    [Thread cache loss], [Cache cold on hot posts], [Stampede protection: single-flight fill per window (one miss rebuilds, the rest wait), stale-while-revalidate serving],
    [Replica lag on reads], [User posts, refreshes, comment missing], [Read-your-own-write for authors: route their reads to the primary, or merge their pending writes client-visible via token],
    [Votes DB shard loss], [Votes on one slice of comments fail], [Fail *closed* for integrity (a queued vote is better than a lost vote); tallies already computed remain served],
    [Brigading wave], [Hundreds of votes/s on one thread from fresh accounts], [Chapter 3's rate limiter plus velocity anomaly detection (Chapter 4's metrics!); flagged threads shift to slower rank recompute while investigated],
  ),
)

== Trade-offs & Alternatives

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Decision], hcell[Chosen], hcell[Alternative & why not (here)]),
  body: (
    [Tree encoding], [Adjacency + materialized path hybrid], [Pure adjacency: recursive subtree reads; nested sets: write amplification on every insert],
    ["Best" ranking], [Wilson lower bound on up/(up+down)], [Raw score: statistically illiterate at small n; ratio: worse — 1/1 beats 200/210; Bayesian average: defensible, but needs a global prior and is harder to explain to users],
    [Rank computation], [Recompute on vote, store rank keys], [Sort at query time: 50k-row sorts per page view; scheduled recompute: stale beyond tolerance on fast threads],
    [Vote writes], [Synchronous upsert + async event], [Fully async queue-first: lowest latency, but integrity (one-vote-per-user) becomes eventual — not acceptable],
    [Tallies], [Denormalized, reconciled nightly], [Count from `votes` per read: honest but scans the largest table on the hottest path],
    [Thread caching], [Version-stamped windows, per-user overlay], [Per-user full windows: personalization cost multiplies cache by user count; no cache: origin melts on viral posts],
    [Deep nesting], [Depth cap + "continue this thread"], [Unbounded inline rendering: pathological subtrees (10⁴-deep chains) DoS the renderer and the reader],
    [Comment count on posts], [Async maintained counter], [Synchronous increment on the post row: every comment write contends on one hot row — the exact anti-pattern Section 5.5 warned about],
  ),
)

== Observability & SLOs

#tbl(
  (auto, 1fr, auto),
  header: (hcell[Indicator], hcell[Definition], hcell[Target]),
  body: (
    [Thread read latency], [Window fetch, cached / uncached, p95], [≤ 200 ms / ≤ 700 ms],
    [Comment write latency], [Create reply, p95], [≤ 300 ms],
    [Vote latency], [PUT vote, p95], [≤ 150 ms],
    [Rank freshness], [Vote → reflected in stored rank keys, p95], [≤ 60 s],
    [Read-your-own-write], [Author sees own comment after create, p99], [≤ 1 s],
    [Tally accuracy], [Comments whose tally ≠ vote-log sum, sampled], [≤ 0.1%, self-healing nightly],
    [Removal propagation], [Moderation removal → gone from all caches], [≤ 60 s],
    [Availability], [Thread reads / writes], [99.99% / 99.9%],
  ),
)

Every one of these is a metric with labels and an alert with a `for` duration
— Chapter 4's platform, pointed at this chapter's system. The reconciliation
job emits tally-drift as a metric; brigading detection is a velocity alert on
votes per thread. The book's chapters compose, and saying so in the interview
is a senior signal.

== Interview Wrap-Up

Likely follow-ups and the shape of strong answers:

+ *"Make it real-time — new comments appear without refresh."* Add a
  subscription tier: WebSocket/SSE gateways subscribed per post; the event
  log fans `CommentCreated` events to gateways. Key decision: live comments
  arrive *appended* (by time), not re-sorted — re-ranking a live view under
  the reader's eyes is a product bug; re-sort applies on next window load.
+ *"How do you detect vote manipulation?"* Signals: velocity anomalies on
  single threads, account-age and IP clustering of voters, vote-ring graph
  analysis (accounts that only vote each other). Enforcement: shadow-exclude
  flagged votes from *rank keys* while keeping them in the visible score —
  manipulation loses its feedback signal.
+ *"Users edit comments to bait-and-switch after they rank."* Keep edit
  history; reset or decay a comment's rank confidence on substantive edits
  (re-open the Wilson interval); show "edited" markers. Ranking trust is the
  product — this is an integrity issue, not a UX nicety.
+ *"Sharding: what about a post with 10⁶ comments?"* One shard holds it —
  10⁶ × 1.5 KB ≈ 1.5 GB, fine; reads are cached windows; votes partition by
  comment. The real ceiling is per-shard write QPS, and comment writes even
  on viral posts stay ~10²/s. If it ever breaks, sub-shard the thread by
  top-level comment id.
+ *"Design comment search."* Chapter 4's inverted index, fed from the same
  event log: tokenize bodies, index `(post_id, comment_id, tokens)`, rank
  results by stored Wilson score. Pipelines compose; nothing new is needed.

== Summary & Further Reading

#notebox([Chapter summary])[
  A comment system is a *shape* problem wearing a scale costume. The data is
  a forest of unbounded trees: store it as an adjacency list with
  materialized paths, so any subtree is one prefix scan and depth is a stored
  fact; delete with tombstones so replies are never orphaned. Ranking is
  statistics, not arithmetic: "best" is the Wilson lower confidence bound
  (evidence beats luck), "controversial" is balanced volume, "hot" is log
  score plus 12.5-hour decay — all pure functions of `(up, down, time)`,
  recomputed on every vote and *stored*, so reads are index scans. Votes are
  the write storm: idempotent upserts keyed by `(user, comment)`, coalesced
  rank recomputation, tallies reconciled against the vote log nightly. Reads
  are windows — ranked pages with shallow children — cached per sort mode and
  version-stamped. The thread is never serialized; the conversation's shape
  is what ships.
]

*Further reading.*

- The source video: _"15: Reddit Comments — Systems Design Interview
  Questions With Ex-Google SWE"_ (Jordan has no life):
  `https://www.youtube.com/watch?v=BO2gRisnBcA`
- Randall Munroe / Reddit — _"How Reddit ranking algorithms work"_
  (redditblog, 2009) — the original public write-up of hot/best/controversial.
- Evan Miller — _"How Not To Sort By Average Rating"_ — the Wilson score
  interval derivation Section 5.8 distills, with the canonical worked numbers.
- Joe Celko — _Trees and Hierarchies in SQL for Smarties_ — the encyclopedic
  treatment of adjacency lists, materialized paths, and nested sets.
- Amir Salihefendić — _"How Reddit ranking algorithms work"_ commentary and
  Hacker News ranking write-ups — production variations on time decay.

== Chapter Glossary

#tbl(
  (auto, 1fr),
  header: (hcell[Term], hcell[Meaning]),
  body: (
    [Adjacency list], [Tree encoding where each row stores its parent's id; cheap writes, recursive reads],
    [Coalescing], [Collapsing many updates to the same entity into one recomputation; how vote bursts become trickles of rank writes],
    [Comment count], [Denormalized per-post tally of comments, maintained asynchronously for listing pages],
    [Confidence interval], [A range estimating a true probability from samples; wider (more pessimistic) when data is scarce],
    [Controversial ranking], [$(u+d)^(min\/max)$ — balanced disagreement weighted by volume],
    [Cursor (pagination)], [Opaque token encoding the last seen sort key; stable under insertions, unlike offsets],
    [Denormalization], [Storing derived values (tallies, rank keys) to make reads cheap; the derived value must be rebuildable from truth],
    [Depth cap], [Maximum inline nesting rendered before collapsing behind "continue this thread"],
    [Forest], [The set of all comment trees, one rooted at each post],
    [Hot ranking], [$log_10 max(|s|,1) + "sign"(s)·(t - t_0)\/45000$ — log-score with 12.5-hour decay],
    [Idempotency key], [A deduplication token making retried writes safe; for votes it is the natural key (user, comment)],
    [Materialized path], [Tree encoding storing each row's full ancestor chain; subtrees become prefix scans],
    [Nested sets], [Tree encoding with depth-first lft/rgt bounds; range-scan reads, catastrophic insert renumbering],
    [N+1 query], [One query per parent to fetch children; the adjacency-list trap that batched path scans eliminate],
    [Rank key], [A stored, indexed, orderable encoding of a comment's rank per sort mode; recomputed on vote],
    [Read-to-write ratio], [Reads per write; extreme ratios justify aggressive caching and denormalization],
    [Read-your-own-write], [Guarantee that a writer immediately sees their own write; routed to primary or merged client-side],
    [Score], [`up − down`, the visible number; deliberately *not* the "best" ordering],
    [Single-flight fill], [One cache miss rebuilds a value while concurrent misses wait; stampede protection],
    [Soft delete / tombstone], [Content erased, structure kept, so replies stay threaded under a "[deleted]" placeholder],
    [Time decay], [Ranking term that ages content out, forcing continuous freshness],
    [Version stamp], [A per-post counter bumped by rank updates; cached windows keyed by it age out without invalidation fanout],
    [Vote overlay], [Per-user vote values merged over a shared cached window at read time],
    [Wilson score interval], [Binomial confidence interval on the true upvote probability; its lower bound ranks "best" honestly across sample sizes],
  ),
)

#v(0.8em)
#align(center)[
  #text(size: 8.5pt, fill: slate)[
    — End of Chapter 5 · Next: Chapter 6—
  ]
]
