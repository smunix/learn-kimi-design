// ============================================================================
//  CHAPTER 9 — Designing Conflict-Free Replication: How CRDTs Work
//  Source: "CRDTs - Stop Worrying About Write Conflicts | Systems Design
//  0 to 1 with Ex-Google SWE" (channel: Jordan has no life)
//  Link: https://www.youtube.com/watch?v=FG5Varj1Ows
// ============================================================================

#import "../template.typ": *

= Designing Conflict-Free Replication: How CRDTs Work

#notebox([Problem source])[
  This chapter solves the problem posed in the talk _"CRDTs — Stop Worrying
  About Write Conflicts"_ from the series _Systems Design 0 to 1 with
  Ex-Google SWE_ (channel: _Jordan has no life_). Like Chapter 8, it is a
  *fundamentals* deep dive rather than a product design: the interviewer
  asks you to design the data layer of a distributed system in which every
  replica accepts writes at all times — no leader, no locking, no global
  ordering — and yet every replica provably converges to the same state. It
  is also the promised second half of Chapter 1: there we chose Operational
  Transformation behind a per-document sequencer for the collaborative
  editor; this chapter walks the road we did not take, and discovers it is
  paved with some of the most elegant mathematics in distributed systems.
  All terms are defined before use; all reference code is Rust with
  deterministic tests.
]

== The Problem Statement

The interviewer sketches three data centers on three continents and says:

_"Every region accepts reads and writes at all times — even when the
network link between regions is down for an hour. No region ever waits for
another. When the link heals, all regions converge to the same data
automatically: no manual conflict resolution, no lost updates, no
duplicates. Design the data layer that makes this true."_

This prompt outlaws every familiar trick, one by one. A single *leader*
that serializes all writes violates "no region waits for another" — and
dies as a single point of failure. Distributed *locking* violates it
harder: a lock held across a partition is either unavailable or unsafe.
"Just take the latest write" loses data silently. The interviewer is not
asking for a weaker version of a normal database; they are asking for a
*different mathematics of agreement*. That mathematics is the CRDT.

#defterm([Replica])[
  An independent copy of some shared state, living on a different machine
  (here: in a different region), that accepts reads and writes on its own.
  A system is _replicated_ when several replicas of the same logical data
  exist at once. Replication buys fault tolerance and read locality — and
  immediately raises the question this chapter answers: how do the copies
  stay in agreement?
]

#defterm([Network partition])[
  A failure in which two groups of replicas cannot communicate for some
  period, while each group keeps running. Partitions are not exotic: any
  severed fiber, misconfigured router, or overloaded link between regions
  is one. A design that is correct only when the network is perfect is
  correct zero percent of the time at planet scale.
]

#defterm([Coordination])[
  Any protocol in which a replica must communicate with others *before* it
  may complete a write: leader election, two-phase commit, distributed
  locks, consensus rounds. Coordination is the price of imposing a global
  order — and under a partition, the side that cannot reach the others
  must stop accepting writes. Coordination and availability are the two
  ends of a seesaw.
]

#defterm([Write conflict])[
  The situation in which two replicas accept writes to the same logical
  datum while unable to see each other — _concurrent_ writes. Neither
  write is "wrong"; the system simply owes the user a single, deterministic
  merged outcome. A conflict is not an error to be prevented but a fact of
  physics to be absorbed.
]

#defterm([Convergence])[
  The property that replicas which have received the same set of updates
  are in the same observable state, no matter the order, duplication, or
  timing with which those updates arrived. Convergence is the entire
  contract of this chapter: not "never diverge" (impossible without
  coordination) but "divergence is temporary and self-healing".
]

== Scope & Clarifying Questions

#tbl(
  (auto, 1fr),
  header: (hcell[Candidate asks], hcell[Interviewer answers]),
  body: (
    [Data model?], [A key-space of replicated values: counters, registers, sets, maps, and one sequence (text). Small, independently mutable values — not bulk blobs],
    [Topology?], [Three regions, active-active (every region serves real writes). The design must not preclude offline-capable edge clients later],
    [Consistency?], [Strong eventual consistency within the store (defined below). No cross-key invariants required — that door stays shut on purpose],
    [Partition behavior?], [Writes must never block on a partition: full AP. Reconciliation happens after healing, automatically],
    [Network assumptions?], [Messages may be delayed, reordered, duplicated. At-least-once delivery at best],
    [Durability?], [A write must survive the loss of any single region once it has been gossiped; locally it is durable on ack],
    [The hard part?], [_"Stop worrying about write conflicts"_ — the merge must be automatic, deterministic, and provably correct],
  ),
)

#notebox([Agreed scope])[
  + Design an *active-active replicated data layer*: every replica accepts
    reads and writes with zero cross-replica coordination on the write path.
  + Guarantee *strong eventual consistency*: replicas that have seen the
    same updates are provably in the same state.
  + Cover *both CRDT families* — state-based and operation-based — and the
    canonical catalog: counters, registers, sets, and the sequence type
    that would power Chapter 1's editor.
  + Design the *synchronization layer* (gossip / anti-entropy, delta
    propagation) and the *metadata lifecycle* (tags, tombstones, garbage
    collection) that make the theory shippable.
  + Quantify everything: metadata per element, tombstone growth, sync
    bandwidth, and the bound on convergence time.
  + Out of scope: Byzantine (malicious) replicas, and cross-key global
    invariants — Section 9.17 explains why CRDTs cannot enforce those and
    what to reach for instead.
]

== Functional Requirements

+ *Independent writes.* Every replica accepts reads and writes at all
  times, with no leader, lock, lease, or quorum on the write path.
+ *Automatic merge.* Concurrent writes to the same datum are merged by the
  data structure itself — deterministically, identically on every replica,
  with no application-level conflict handler required.
+ *Convergence.* Any two replicas that have exchanged their updates are in
  equivalent observable states, regardless of network order, duplication,
  or delay.
+ *Partition healing.* When a partition heals, the two sides reconcile by
  exchanging state (or deltas) — never by rolling back acknowledged writes.
+ *A usable type catalog.* The layer must provide the types real
  applications need: a counter that can go up *and* down, a value register,
  a set with add *and* remove, maps, and an ordered sequence for text.
+ *Bounded metadata.* Deletes must be real (elements disappear), and the
  metadata that makes convergence possible must be garbage-collectible
  without ever blocking writes.

== Non-Functional Requirements

- *Availability first (AP).* Every request — read or write — receives a
  response from the local replica even during a partition. In CAP terms we
  choose availability and partition tolerance, and recover consistency
  continuously rather than atomically.
- *Bounded convergence.* After the network heals, replicas converge within
  a small multiple of the gossip interval — seconds, not minutes.
- *Bounded overhead.* CRDT metadata per element must stay a small constant
  multiple of the payload after compaction; unbounded growth is a defect.
- *Protocol robustness.* The synchronization layer must tolerate
  duplicated, reordered, and delayed messages as a matter of routine.

#defterm([Eventual consistency])[
  The guarantee that, if updates stop arriving, all replicas *eventually*
  reach the same state. By itself this is weak — it says nothing about
  what happens *while* updates flow, and it allows replicas to disagree
  arbitrarily in the meantime. It is a liveness property ("the system gets
  there"), not a safety property ("the states are right").
]

#defterm([Strong eventual consistency (SEC)])[
  Eventual consistency plus a *safety* guarantee: any two replicas that
  have applied the same set of updates are in *equivalent states right
  now*, with no further communication needed. SEC is what turns
  "eventually the same" from a hope into a theorem, and it is exactly what
  CRDTs provide: convergence is a property of the data structure, not of
  the schedule.
]

#defterm([Linearizability])[
  The strongest common consistency model: every operation appears to take
  effect atomically at some instant between its start and its completion,
  as if there were exactly one copy of the data. Linearizability requires
  coordination, so it is exactly what an AP system gives up. This chapter's
  honesty rule: CRDTs provide SEC per object, *never* linearizability —
  and Section 9.17 shows which application needs genuinely require the
  stronger model.
]

== Back-of-the-Envelope: Metadata, Tombstones, and Gossip

The design stands or falls on three numbers: how much metadata convergence
costs per element, how fast tombstones accumulate, and how much bandwidth
synchronization burns. Fix a concrete scenario — the canonical CRDT
showcase: a *shopping-cart service* in three regions.

*Assumptions.* Three regions in full mesh; 10⁸ active carts; an average of
20 items per cart; item payload 24 B (SKU + quantity); one add-tag of 16 B
(replica id 8 B + counter 8 B) per add; churn such that each live item has,
on average, two historically removed siblings.

#tbl(
  (auto, 1fr),
  header: (hcell[Quantity], hcell[Estimate (with assumptions)]),
  body: (
    [Regions / replicas], [3, pairwise full mesh (one gossip hop between any two)],
    [Live cart state], [10⁸ carts × 20 items × (24 B + 16 B) = *80 GB per replica*],
    [Tombstones], [10⁸ × 40 removed items × 16 B = *64 GB per replica* — nearly half the state is ghosts; GC is not optional],
    [Peak cart writes], [10⁵ ops/s fleet-wide (add, remove, change-quantity)],
    [Delta sync traffic], [10⁵ ops/s × ~100 B/op (payload + tag + context) ≈ *10 MB/s fleet-wide*, ~3.3 MB/s per region — trivial for inter-region links],
    [Full-state sync], [144 GB per exchange — *impossible as a routine mechanism*; this number is why delta-state CRDTs exist (Section 9.10)],
    [Convergence bound], [1 s gossip interval × 2 rounds ≈ *2 s worst case* on a full mesh; a ring of N replicas would cost ⌈N/2⌉ rounds — topology is a convergence budget],
    [Text metadata], [~40 B per character (sequence id + parent reference + flags) before compression — Section 9.11's tax on Chapter 1],
  ),
)

#insight([The number that shapes the architecture])[
  Nothing in the table is frightening except the last three rows taken
  together: state is cheap, writes are cheap, but *moving whole states is
  not*. A naive "send your replica to your peer" anti-entropy design would
  need to stream 144 GB per exchange; the same convergence achieved by
  shipping only what changed costs single-digit MB/s. Every production
  CRDT system — Riak, Redis CR, Akka Distributed Data — converged on
  delta-state replication for exactly this arithmetic reason.
]

== The Core Challenge: Agreement Without a Coordinator

Every conflict-resolution strategy you already know is secretly a way of
*imposing an order* on writes and then obeying it. A leader imposes order
by fiat. A lock imposes order by exclusion. A consensus protocol imposes
order by majority vote. Last-writer-wins imposes order by wall clock. The
first three require coordination, which a partition forbids; the fourth is
coordination-free but *wrong often enough to matter*.

#pitfall([Last-writer-wins as the default])[
  LWW resolves a conflict by keeping the write with the largest timestamp
  and discarding the other. Two defects make it a footgun, not a strategy.
  First, it *throws data away by design*: two users updating the same
  profile field concurrently means one of them silently never happened.
  Second, the "winner" is chosen by clocks you do not control: with 100 ms
  of clock skew between regions — unremarkable in practice — the write
  that actually happened *later* can lose. LWW is a fine register policy
  for overwrite-able caches (Section 9.9); it is a terrible *default* for
  data you care about, and "the database will merge it" is not a design.
]

So the challenge is precise: *find data structures whose merge does not
need an order at all.* The breakthrough idea is to stop asking "which
write came first?" — a question that has no answer across a partition —
and ask instead "what is the *join* of these two states?": a combination
that absorbs both writes symmetrically, the way set union absorbs both
contributors without caring who contributed first.

#insight([Order is the enemy; merge is the friend])[
  A total order over all writes is unaffordable (coordination) and, under
  a partition, *undefinable* — concurrent writes genuinely have no
  fact-of-the-matter order. The escape is to demand only three properties
  of the merge function: *commutativity* (order of arrival irrelevant),
  *associativity* (grouping of arrivals irrelevant), and *idempotence*
  (duplication irrelevant). Any structure whose merge has these three
  properties converges under *any* network behavior — delays, reordering,
  duplication, pairwise gossip in any pattern — because every remaining
  degree of freedom in the delivery schedule has been declared irrelevant.
  The rest of the chapter is the craft of building useful data types whose
  merges obey these three laws.
]

== Deep Dive: The Mathematics of Convergence

This section gives the three laws above a body: the small amount of order
theory that turns "we merge somehow" into "convergence is a theorem".

#defterm([Partial order])[
  A relation ≤ on a set that is reflexive (x ≤ x), antisymmetric (x ≤ y
  and y ≤ x imply x = y), and transitive (x ≤ y and y ≤ z imply x ≤ z) —
  but *not* total: some pairs are simply incomparable, written x ‖ y.
  Replica states form a partial order by "knowledge": state B is ≥ state A
  if B has seen every update A has seen. Two replicas that have seen
  *different* concurrent updates are incomparable — and that incomparability
  is the faithful mathematical image of a partition.
]

#defterm([Join (least upper bound) and join-semilattice])[
  The _join_ of two states x and y, written x ∨ y, is the *smallest* state
  that is ≥ both: the cheapest way to know everything either of them
  knows. A set in which every pair has a join is a _join-semilattice_.
  Joins are automatically commutative (x ∨ y = y ∨ x), associative
  ((x ∨ y) ∨ z = x ∨ (y ∨ z)), and idempotent (x ∨ x = x) — the three
  laws of the insight box, now with names and a proof obligation: to build
  a state-based CRDT, define a state space, define ∨, and *prove* it is
  the least upper bound.
]

#defterm([Monotonicity / inflation])[
  An update is _inflationary_ (monotonic) if it only ever moves the state
  *up* the partial order: after any update, new-state ≥ old-state. No
  rollback, no overwrite, no removal from the *state's knowledge* — a
  remove operation, as we will see, is re-expressed as the *addition of a
  tombstone*, which is growth. Monotonicity is what makes convergence safe:
  since replicas only ever climb the lattice, every merge is progress and
  no progress is ever undone.
]

With the vocabulary in place, the central theorem of the field fits in one
sentence and one paragraph of proof sketch:

*Convergence theorem (state-based CRDTs).* _If the state space is a
join-semilattice, every update is inflationary, and merge computes the
join, then replicas that have exchanged the same set of updates are in
equal states — regardless of order, duplication, or gossip topology._

_Why it holds._ Each update moves its origin replica to a state ≥ the old
one (inflation). Gossip and merge replace a state by a join of states, and
joins only ever add knowledge, so every replica's state climbs the lattice
and never descends. When two replicas have both absorbed the same set of
updates, each one's state is the join of exactly that set — and the join
of a set does not depend on the order (commutativity), grouping
(associativity), or repetition (idempotence) of its members. Hence the two
states are equal. ∎

#notebox([The two CRDT families])[
  The theorem above describes *state-based* CRDTs (_CvRDTs_, "convergent"):
  replicas ship their states (or state deltas) and merge by join. There is
  a dual family, *operation-based* CRDTs (_CmRDTs_, "commutative"):
  replicas broadcast the *operations themselves* (e.g. "add tag t to
  element e"), and the requirement is that concurrent operations
  *commute* — applying them in either order yields the same state — and
  that the broadcast layer delivers each operation *exactly once, in causal
  order*. Op-based CRDTs send small messages but demand more of the
  transport; state-based CRDTs tolerate any transport but send larger
  messages. The two families are expressively equivalent — every design in
  one has a counterpart in the other — so the choice is pure engineering:
  message size versus delivery guarantees. Delta-state (Section 9.10)
  erases most of the size advantage, which is why state-based dominates
  production systems.
]

== Deep Dive: The CRDT Catalog

Every CRDT in the catalog is an answer to the same exam question: "define
a state and a join for this familiar data type." Seeing five answers in a
row is the fastest way to internalize the method.

=== G-Counter: the hello-world of convergence

A grow-only counter stores not one integer but a *vector* — one slot per
replica. Replica _i_ increments only slot _i_. The value is the sum of all
slots. Merge takes the *component-wise maximum*: for each slot, keep the
larger of the two values.

- _Commutative?_ max(a, b) = max(b, a). ✓
- _Associative?_ max(max(a, b), c) = max(a, max(b, c)). ✓
- _Idempotent?_ max(a, a) = a. ✓ — duplicates are absorbed for free.
- _Monotonic?_ Slots only grow; max only climbs. ✓

Each slot climbs because a replica's own count only grows, and merge
propagates the climb. A replica can never "un-see" an increment. That is
the whole design pattern: *partition the state so that each writer owns a
piece only it can change, then take per-piece maxima.*

=== PN-Counter: decrements without going backwards

A counter that can decrement cannot be one G-Counter (a decrement would
move a slot *down* — non-monotonic, theorem void). The trick: *two*
G-Counters, P for increments and N for decrements; value = sum(P) − sum(N).
Decrement increments N. Every physical slot still only grows; the
*derived* value may fall. This "two monotonic structures, one derived
reading" move recurs constantly in CRDT design.

=== G-Set and 2P-Set: union, then union twice

A grow-only set merges by union — the most obvious semilattice in the
chapter. To support removal, add a second grow-only set of *tombstones*;
an element is a member iff it is in the add-set and not in the remove-set.
That is the *2P-Set* (two-phase set), and its glaring limitation teaches
the next idea: once removed, an element can *never* be re-added, because
its tombstone outlives every future add. The remove is blind — it kills
adds it never even saw.

#defterm([Tombstone])[
  A marker recording that a specific element (or add) was removed, kept in
  the state so that the removal can be *merged* like any other fact. A
  tombstone turns deletion — locally a shrinkage — into knowledge growth,
  preserving monotonicity. Its price is space: tombstones accumulate until
  garbage collection (Section 9.10), and deleting one naively is the
  classic way to resurrect deleted data.
]

=== OR-Set: letting adds and removes coexist

The *observed-remove set* fixes the 2P-Set's blindness with one word:
_observed_. Every `add(e)` stamps `e` with a *globally unique tag* (a
replica id plus a counter). `remove(e)` tombstones exactly the tags the
removing replica *has seen*. An element is live iff it has a tag with no
tombstone. Now watch a concurrent add and remove collide: the remove
tombstones the tags it observed; the concurrent add carries a *new* tag
the remover could not have seen, so that tag survives and the element
lives. This is *add-wins* semantics — the re-add beats the concurrent
remove — and it is almost always what users mean: the shopper who re-adds
milk while another device removes the stale entry expects milk.

Merge is union of add-tags and union of tombstones — both grow-only, both
semilattices, so the composite is a semilattice. The OR-Set is the
workhorse of the catalog: shopping carts, friend lists, and collaborative
outlines are all OR-Sets in production clothing.

=== Registers: LWW and multi-value

A *register* holds one value. The LWW register pairs the value with a
timestamp and merges by keeping the larger timestamp — the cautionary tale
of Section 9.6 in data-type form. The *multi-value register* (MV-register)
is the honest version: merge keeps *all* concurrently written values
(returning them as a set of "siblings") and collapses to one only when one
write causally supersedes the others. LWW chooses for you and sometimes
chooses wrong; MV refuses to choose and hands the choice to the
application — with a causal context (Section 9.9) so the app's
"last word" can be recorded as superseding rather than concurrent.

#tbl(
  (0.9fr, 1.35fr, 1.1fr, 1.5fr),
  header: (hcell[Type], hcell[State], hcell[Merge rule], hcell[Cost / gotcha]),
  body: (
    [G-Counter], [One slot per replica], [Per-slot max], [Cannot decrement; O(R) space, R = replicas],
    [PN-Counter], [Two G-Counters (P, N)], [Per-slot max in both], [Value is eventual; no invariant like ≥ 0],
    [G-Set], [One set], [Union], [No removal — ever],
    [2P-Set], [Add-set + remove-set], [Union both], [No re-add after remove],
    [OR-Set], [Set of (element, tag) + tag tombstones], [Union both], [Tag + tombstone metadata per element],
    [LWW-Register], [(value, timestamp)], [Keep max timestamp], [Drops concurrent writes; clock skew picks the loser],
    [MV-Register], [Set of concurrent (value, dot)], [Keep causally-maximal values], [App must resolve siblings],
    [Sequence (RGA)], [Atoms with unique ids + parent links + tombstones], [Union by id, order by (parent, id)], [Metadata per character; interleaving (§9.11)],
  ),
)

#tip([The catalog is a party trick — use it])[
  Interviewers love watching a candidate *derive* a CRDT on the spot. The
  method is always the same four steps: (1) partition the state so each
  replica owns a piece; (2) express every mutation as growth in some
  component; (3) define merge as a per-component union or max; (4) prove
  commutativity, associativity, idempotence in one line each. Asked for a
  replicated "max temperature" reading? Slots per sensor, merge by max —
  ten seconds. Asked for a leaderboard score per player? That is a
  per-player max-register — and Chapter 6's best-score monotonicity was a
  CRDT in spirit before this chapter named it.
]

== Deep Dive: Causality — Vector Clocks and Dots

"Observed", "concurrent", "supersedes" — the catalog leans on causal
vocabulary, so we now give it machinery. The goal: a compact summary of
*which updates a replica has seen*, comparable in O(number of replicas).

#defterm([Happens-before (→)])[
  Lamport's relation over events in a distributed system: event a → b if a
  can *influence* b — same-replica program order, or a is the sending of a
  message and b its receipt, extended transitively. If neither a → b nor
  b → a, the events are *concurrent* (a ‖ b): no message path connects
  them, so there is no fact of the matter about which "really" happened
  first. Concurrency is not a tie to break; it is a structure to record.
]

#defterm([Vector clock])[
  A map from replica id to a logical counter, one entry per replica that
  has ever written. A replica increments its own entry on each local
  event; on receiving a message it merges by component-wise maximum and
  then ticks. Clock A *dominates* clock B (A ≥ B) iff every component of A
  is ≥ the matching component of B; A → B causally iff A ≤ B and A ≠ B;
  two clocks with neither A ≤ B nor B ≤ A are *concurrent*. The vector
  clock is the happens-before relation, compressed into one comparable
  value.
]

#defterm([Dot (event id) and dotted version vectors])[
  A _dot_ is a single (replica, counter) pair identifying one specific
  event — exactly the OR-Set's add-tag. Production systems (Riak KV being
  the canonical example) carry state as *dots plus a version vector*: the
  vector summarizes the causal history compactly, while the dots identify
  the freshest events precisely. The combination answers both questions an
  OR-Set merge asks — "what have you seen in general?" and "which exact
  adds do you mean?" — without storing a full event log.
]

*Worked example.* Replicas EU and US both start with vector clock { }.
EU increments a shared counter twice: EU's clock is {EU: 2}. It gossips to
US; US merges — US is also {EU: 2} — and performs its own increment:
{EU: 2, US: 1}. Meanwhile EU, having seen nothing from US, increments
again: {EU: 3}. Compare the two: EU has 3 \> 2 in its own slot, US has
1 \> 0 in its slot — neither dominates: *concurrent*. After one gossip in
each direction, both hold {EU: 3, US: 1}, the component-wise max — equal,
and causally after both divergent states. The merge rule for clocks is the
G-Counter's rule, because a vector clock *is* a G-Counter whose value we
read component-wise instead of summed. The catalog nests inside itself.

== Deep Dive: Tombstones, Deltas, and Anti-Entropy

Three engineering mechanisms carry the mathematics to production. Each
neutralizes one row of the estimation table.

=== Why tombstones cannot just be deleted

Suppose region EU removes "milk" from a cart, tombstoning its tag, and —
eager to reclaim space — *deletes the tombstone* immediately. Region APAC
was partitioned the whole time; it still holds the live add-tag. When the
link heals, APAC gossips its state. EU's merge unions in the add-tag, and
there is no tombstone to cover it: *milk rises from the dead*, on every
replica, forever. The tombstone was not garbage; it was the *only* record
that the remove ever happened.

The safe rule: a tombstone may be collected only when *every* replica has
acknowledged a state that includes it — established with a per-replica
ack vector exchanged during gossip. Collection is coordination, but it is
*off the write path*: asynchronous, batched, retried lazily, and free to
be slow, so it costs the system none of its AP guarantees. Note the
pattern, because it recurs in LSM compaction (Chapter 8) and log retention
(Chapter 4): *deletion is only ever garbage collection of facts everyone
already knows.*

=== Delta-state: shipping the difference

Full-state gossip of 144 GB per exchange is a non-starter; op-based
broadcast is small but demands exactly-once causal delivery. *Delta-state
CRDTs* take the middle path: after each update, the replica forms a
*delta* — the smallest join-semilattice element that, when merged into the
old state, yields the new one (for an OR-Set add: just the new tag; for a
G-Counter: the one bumped slot) — ships deltas to peers, and merges
received deltas by the same join as full states. Deltas are themselves
states, so merging them is commutative, associative, and idempotent
*automatically*; a delta-buffer per peer, re-sent until acknowledged,
gives at-least-once delivery with exactly-once effect via idempotence.
Deltas can also be *grouped* — merged into bigger deltas — when a peer
falls behind, degrading gracefully toward a full-state transfer. This is
the mechanism that turns the estimation table's 10 MB/s from theory into
routine.

=== Anti-entropy and gossip: the sync fabric

#defterm([Anti-entropy / gossip protocol])[
  A background process in which each replica periodically picks a peer
  (randomly, or by topology) and exchanges state — pushes its deltas,
  pulls the peer's, or both (push-pull) — until the pair agrees.
  Repetition makes the epidemic complete: with random pairing every
  *interval*, an update infects the full mesh of R replicas in O(log R)
  rounds, with no coordinator, no membership ceremony, and graceful
  degradation to any topology that stays connected. "Gossip" names the
  peer selection; "anti-entropy" names the goal: driving the divergence
  between replicas toward zero.
]

For *repair* of long-diverged replicas (a region down for a day), pairwise
delta exchange is joined by *Merkle-tree* comparison — a hash tree over
the key space lets two replicas find the keys that differ in O(log n)
hashes instead of shipping everything — the same trick Chapter 4's segment
compaction uses to prove two segments identical. Production CRDT stores
layer all three: deltas for the hot path, gossip for dissemination,
Merkle repair for the cold path.

== Deep Dive: Sequence CRDTs — Back to Chapter 1

Chapter 1's collaborative editor faced the same enemy in miniature: two
users typing into the "same" position at once. There we solved it with
Operational Transformation behind a per-document sequencer — a single
point of ordering, chosen deliberately, with CRDTs named as the road not
taken. This section walks that road: how do you make *text* — where order
of characters is the entire content — converge without any sequencer?

The obstacle is addressing. Integer positions are *unstable under
concurrency*: "insert X at position 5" means different things on two
replicas whose texts have already drifted — that instability is precisely
what OT's transform matrix compensates for. The CRDT answer is to stop
using positions as identities:

#defterm([Stable identity addressing (RGA-style)])[
  Give every inserted atom (character) a *globally unique, immutable id* —
  a (counter, replica) pair — and record each insertion as "insert atom c
  *after* atom p", where p is the id of its left neighbor *at the
  inserting replica*. Position is now expressed relative to a landmark
  that never moves (atoms are never renumbered), so a concurrent insert
  elsewhere cannot shift the reference. The document is a linked
  structure; the visible text is a deterministic walk of it.
]

Two concurrent inserts after the *same* parent still need a deterministic
order among themselves — "Alice typed `!` after `hi`" and "Bob typed `?`
after `hi`" must interleave identically everywhere. The rule: among atoms
sharing a parent, sort by *descending id*; a newly arriving atom slides in
after every same-parent atom whose id is higher, before all whose ids are
lower. Both replicas then place Alice's (3, EU) and Bob's (1, US) in the
same order regardless of which insert arrives first — the Rust listing in
Section 9.14 demonstrates exactly this collision, and its test asserts the
converged string.

Deletion is the by-now-familiar move: a tombstone on the atom. The atom
stays in the structure — concurrent inserts referencing it as a parent
must still find their landmark — but the text walk skips it.

#defterm([Interleaving anomaly])[
  A known cosmetic defect of first-generation sequence CRDTs: if Alice
  types "Hello" while Bob types "World" at the same spot, some schemes may
  merge into "HWeolrllod" — character-level interleaving of the two runs —
  because the sibling ordering rule compares ids atom by atom. Newer
  schemes (LSEQ/Logoot's dense identifiers with tie-breaking bit
  strategies, and Fugue's maximal-non-interleaving rule) keep concurrent
  runs contiguous. Every scheme still converges; the anomaly is about
  *readability* of merged concurrent runs, not correctness — and in
  practice two humans rarely type sustained runs into the same word at
  once.
]

#defterm([Dense / fractional identifiers (LSEQ, Logoot)])[
  The alternative addressing scheme: instead of linking to a parent,
  assign each atom an identifier from a *dense order* — one that always
  has another value between any two (like fractions: between 1/2 and 1/3
  there is 5/12). Inserting between atoms p and q allocates an identifier
  strictly between theirs, so the document order is simply identifier
  order and no parent link is needed. The cost is identifier growth: every
  split lengthens the identifier, so documents edited mostly at the end
  accumulate long ids — the mirror image of RGA's tombstone problem, and
  the reason production libraries (Yjs, Automerge) run length-aware
  allocation strategies and periodic compaction.
]

#notebox([OT vs CRDT — the callback settled])[
  Chapter 1's comparison table now has its missing column filled in. OT
  keeps text lean (no per-character metadata) and history clean, at the
  price of a sequencer per document and a transform matrix that must be
  exactly right. Sequence CRDTs need no sequencer — offline editing,
  peer-to-peer sync, and end-to-end encryption all fall out for free,
  because no replica is special and no ciphertext needs transforming — at
  the price of ~40 B of metadata per character before compression and
  tombstone GC forever after. Figma and the Google Docs lineage chose
  sequencer + transforms; Automerge, Yjs, and most local-first software
  chose CRDTs. Neither is "the answer"; both are the trade-off, made with
  open eyes.
]

== API Design

The store presents a small key-value surface, one family per CRDT type.
Two conventions carry the causal machinery: every read returns an opaque
*context* (the version vector the replica used to answer), and every
conditional write passes the context back — that is how "I read it, now
I'm overwriting what I read" is distinguished from "I'm writing blind",
which is the difference between superseding and merely concurrent.

#tbl(
  (1.35fr, 0.75fr, 2.2fr),
  header: (hcell[Endpoint], hcell[Type], hcell[Semantics]),
  body: (
    [`POST /counter/{k}/incr {n}`], [PN-Counter], [Increment by n (negative n decrements); local, immediate ack; merges by per-slot max],
    [`GET /counter/{k}`], [PN-Counter], [Returns sum(P) − sum(N) as of this replica's knowledge],
    [`PUT /register/{k} {v, ctx}`], [MV / LWW], [Write v; with ctx, supersedes exactly the values ctx saw; without ctx, writes blind],
    [`GET /register/{k}`], [MV / LWW], [Returns value + ctx; MV returns *siblings* (all concurrent values) for the app to resolve],
    [`POST /set/{k}/add {e}`], [OR-Set], [Add element with a fresh unique tag (replica id + counter)],
    [`POST /set/{k}/remove {e}`], [OR-Set], [Tombstones every tag for e this replica has observed — add-wins against concurrent adds],
    [`GET /set/{k}`], [OR-Set], [Returns elements with ≥ 1 live tag],
    [`POST /doc/{k}/edit`], [Sequence (RGA)], [Batch of (after-id, char) inserts and tombstones; positions are ids, never integers],
    [`GET /doc/{k}?since={ctx}`], [Sequence], [Returns the delta since ctx — the same mechanism gossip uses, exposed to clients],
    [`POST /sync/{peer}`], [internal], [Anti-entropy: push-pull delta exchange with one peer; the write path never calls this],
  ),
)

#insight([The context parameter is the whole safety story])[
  Every dangerous write in an AP system is a *blind* write — one made
  without knowing what it overwrites. The opaque context closes that hole
  without coordination: read-then-write with ctx means "replace exactly
  what I saw", which the MV-register can honor causally, keeping siblings
  only for writes that were *genuinely* concurrent. Riak KV built its
  entire client protocol on this pattern. If the interviewer asks "how do
  you stop CRDTs from losing user intent?", the answer is this parameter.
]

== High-Level Architecture

The architecture is almost offensively simple, and that is the point:
there is *no box whose failure stops writes*. Each region is a complete,
self-sufficient stack; the only cross-region component is the gossip
fabric, which is allowed to be late.

#canvas(h: 4.75cm)[
  // clients
  #node(0.4cm, 0cm, 3.5cm, 0.85cm, [Clients (EU)], fill: faint, edge: slate)
  #node(6.5cm, 0cm, 3.5cm, 0.85cm, [Clients (US)], fill: faint, edge: slate)
  #node(12.6cm, 0cm, 3.5cm, 0.85cm, [Clients (APAC)], fill: faint, edge: slate)
  #glabel(2.4cm, 1.18cm)[reads & writes, ack'd locally]
  #arrow(2.15cm, 0.85cm, 2.15cm, 1.95cm, color: slate)
  #arrow(8.25cm, 0.85cm, 8.25cm, 1.95cm, color: slate)
  #arrow(14.35cm, 0.85cm, 14.35cm, 1.95cm, color: slate)

  // replicas
  #node(0.4cm, 1.95cm, 3.5cm, 0.95cm, [Replica EU \ CRDT store], edge: primary, fill: faint-blue)
  #node(6.5cm, 1.95cm, 3.5cm, 0.95cm, [Replica US \ CRDT store], edge: primary, fill: faint-blue)
  #node(12.6cm, 1.95cm, 3.5cm, 0.95cm, [Replica APAC \ CRDT store], edge: primary, fill: faint-blue)

  // gossip, both directions per pair
  #arrow(3.9cm, 2.2cm, 6.5cm, 2.2cm, color: teal, dashed: true)
  #arrow(6.5cm, 2.65cm, 3.9cm, 2.65cm, color: teal, dashed: true)
  #arrow(10.0cm, 2.2cm, 12.6cm, 2.2cm, color: teal, dashed: true)
  #arrow(12.6cm, 2.65cm, 10.0cm, 2.65cm, color: teal, dashed: true)
  #glabel(4.15cm, 1.98cm, fg: teal)[gossip]
  #glabel(10.25cm, 1.98cm, fg: teal)[gossip]
  #glabel(2.9cm, 3.22cm)[anti-entropy: every pair exchanges deltas until states converge (full mesh drawn once)]

  // local durable state
  #arrow(2.15cm, 2.9cm, 2.15cm, 3.75cm, color: slate)
  #arrow(8.25cm, 2.9cm, 8.25cm, 3.75cm, color: slate)
  #arrow(14.35cm, 2.9cm, 14.35cm, 3.75cm, color: slate)
  #node(0.4cm, 3.75cm, 3.5cm, 0.85cm, [Local durable state \ CRDTs + tombstones], fill: faint-teal, edge: teal)
  #node(6.5cm, 3.75cm, 3.5cm, 0.85cm, [Local durable state \ CRDTs + tombstones], fill: faint-teal, edge: teal)
  #node(12.6cm, 3.75cm, 3.5cm, 0.85cm, [Local durable state \ CRDTs + tombstones], fill: faint-teal, edge: teal)
]

#notebox([Reading the diagram])[
  The write path is the *short* path: client → local replica → local disk,
  acknowledged. Nothing crosses an ocean synchronously; the gossip arrows
  carry deltas *after* the ack, every ~1 s, peer to peer, in both
  directions. Lose a region and the other two keep serving; lose two links
  and the isolated region keeps serving; heal the link and anti-entropy
  merges the diverged states with zero operator action. The architecture
  diagram of a CRDT system is a list of things that are *absent*: no
  leader, no lock service, no consensus ring, no conflict-resolution
  queue.
]

== Rust Reference Implementations

Four pieces with deterministic tests: the two counters, the vector clock,
the OR-Set, and a sequence CRDT for text. Each implements exactly the merge
rule its section derived, and each test demonstrates convergence under
concurrency, duplication, or both. In a real deployment these states ride
inside the sync fabric of Section 9.13; here they run in memory so every
property is directly assertable.

=== Counters: G-Counter and PN-Counter

```rust
use std::collections::BTreeMap;

/// Grow-only counter (state-based). Each replica owns one slot and only
/// ever increments its own slot; merge takes the per-slot maximum.
/// max is commutative, associative, idempotent — the semilattice join.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GCounter {
    /// replica id -> count observed at that replica
    counts: BTreeMap<u64, u64>,
}

impl GCounter {
    pub fn increment(&mut self, replica: u64) {
        *self.counts.entry(replica).or_insert(0) += 1;
    }

    /// The counter's value: the sum over all per-replica slots.
    pub fn value(&self) -> u64 {
        self.counts.values().sum()
    }

    /// Join: component-wise maximum. A slot can only climb.
    pub fn merge(&mut self, other: &GCounter) {
        for (&replica, &count) in &other.counts {
            let slot = self.counts.entry(replica).or_insert(0);
            *slot = (*slot).max(count);
        }
    }
}

/// PN-Counter = two G-Counters: P for increments, N for decrements.
/// Every physical slot still only grows; the *derived* value may fall.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PNCounter {
    inc: GCounter,
    dec: GCounter,
}

impl PNCounter {
    pub fn increment(&mut self, replica: u64) { self.inc.increment(replica); }
    pub fn decrement(&mut self, replica: u64) { self.dec.increment(replica); }
    pub fn value(&self) -> i64 { self.inc.value() as i64 - self.dec.value() as i64 }
    pub fn merge(&mut self, other: &PNCounter) {
        self.inc.merge(&other.inc);
        self.dec.merge(&other.dec);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn concurrent_increments_converge() {
        // Two replicas start identical, drift apart, then sync both ways.
        let mut a = GCounter::default();
        let mut b = a.clone();

        a.increment(1);
        a.increment(1);
        b.increment(2);

        let mut a2 = a.clone();
        a2.merge(&b);
        let mut b2 = b.clone();
        b2.merge(&a);
        assert_eq!(a2, b2);            // same updates seen => same state
        assert_eq!(a2.value(), 3);     // no increment lost, none counted twice

        // Idempotence: re-merging an old state changes nothing.
        let snapshot = a2.clone();
        a2.merge(&b);
        assert_eq!(a2, snapshot);
    }

    #[test]
    fn pn_counter_supports_decrements() {
        let mut a = PNCounter::default();
        let mut b = a.clone();
        a.increment(1);
        a.increment(1);
        a.decrement(1);
        b.decrement(2);
        b.decrement(2);

        a.merge(&b);
        b.merge(&a);
        assert_eq!(a, b);
        assert_eq!(a.value(), 2 - 3);  // two increments minus three decrements
    }
}
```

Note what the tests *cannot* express: a PN-Counter never enforces
`value() >= 0`. Two replicas may both decrement the last unit of stock and
converge happily to −1. Per-object convergence is free; *invariants* are
not — Section 9.17 prices that boundary honestly.

=== Vector Clocks: Tracking Causality

```rust
use std::collections::BTreeMap;

/// Vector clock: replica id -> logical counter. The happens-before
/// relation, compressed into one comparable value. (Mechanically this is
/// a G-Counter read component-wise instead of summed.)
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct VectorClock {
    clocks: BTreeMap<u64, u64>,
}

/// The three-way comparison of two causal positions.
#[derive(Debug, PartialEq, Eq)]
pub enum CausalOrder { Equal, Before, After, Concurrent }

impl VectorClock {
    /// Record a local event at `replica`.
    pub fn tick(&mut self, replica: u64) {
        *self.clocks.entry(replica).or_insert(0) += 1;
    }

    pub fn get(&self, replica: u64) -> u64 {
        *self.clocks.get(&replica).unwrap_or(&0)
    }

    /// Component-wise maximum — the join of both causal histories.
    pub fn merge(&mut self, other: &VectorClock) {
        for (&replica, &count) in &other.clocks {
            let slot = self.clocks.entry(replica).or_insert(0);
            *slot = (*slot).max(count);
        }
    }

    pub fn compare(&self, other: &VectorClock) -> CausalOrder {
        let mut le = true; // self <= other on every component?
        let mut ge = true; // self >= other on every component?
        // union of both key sets (a replica may appear on only one side)
        for (&r, _) in self.clocks.iter().chain(other.clocks.iter()) {
            let a = self.get(r);
            let b = other.get(r);
            if a < b { ge = false; }
            if a > b { le = false; }
        }
        match (le, ge) {
            (true, true)   => CausalOrder::Equal,
            (true, false)  => CausalOrder::Before, // self happened-before other
            (false, true)  => CausalOrder::After,  // self happened-after other
            (false, false) => CausalOrder::Concurrent, // neither saw the other
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_happens_before_and_concurrency() {
        let mut a = VectorClock::default();
        a.tick(1);
        a.tick(1);              // a  = {1: 2}

        let mut b = a.clone();
        b.tick(2);              // b  = {1: 2, 2: 1} — causally after a

        assert_eq!(a.compare(&b), CausalOrder::Before);
        assert_eq!(b.compare(&a), CausalOrder::After);

        // A concurrent branch: a2 moves on without having seen b.
        let mut a2 = a.clone();
        a2.tick(1);             // a2 = {1: 3}
        assert_eq!(a2.compare(&b), CausalOrder::Concurrent);

        // The join dominates both; a clock equals itself.
        let mut m = a2.clone();
        m.merge(&b);            // m  = {1: 3, 2: 1}
        assert_eq!(m.compare(&a2), CausalOrder::After);
        assert_eq!(m.compare(&b), CausalOrder::After);
        assert_eq!(m.compare(&m.clone()), CausalOrder::Equal);
    }
}
```

`compare` is why Rust's `PartialOrd` trait is *not* implemented here: the
fourth outcome, `Concurrent`, is the entire point of the data structure,
and squeezing it into `None` would invite callers to ignore exactly the
case that matters. Make concurrency an explicit variant and the compiler
forces every caller to decide what it means.

=== The OR-Set: Add-Wins with Tombstones

```rust
use std::collections::{BTreeMap, BTreeSet};

/// Unique stamp for one add operation: (replica id, per-replica counter).
type Tag = (u64, u64);

/// Observed-Remove Set, add-wins flavour (state-based).
///
/// Per element we keep the tags of every add ever seen and the tags of
/// every remove ever seen (tombstones). An element is live iff it has an
/// add-tag with no matching tombstone. `remove` tombstones exactly the
/// tags *this replica has observed* — so a concurrent add elsewhere,
/// carrying an unseen tag, survives: add wins.
#[derive(Debug, Clone, Default)]
pub struct ORSet {
    adds: BTreeMap<String, BTreeSet<Tag>>,
    removals: BTreeMap<String, BTreeSet<Tag>>,
    replica: u64,
    next: u64,
}

impl ORSet {
    pub fn new(replica: u64) -> Self {
        ORSet { adds: BTreeMap::new(), removals: BTreeMap::new(), replica, next: 0 }
    }

    pub fn add(&mut self, elem: &str) {
        self.next += 1;
        self.adds
            .entry(elem.to_string())
            .or_default()
            .insert((self.replica, self.next));
    }

    pub fn remove(&mut self, elem: &str) {
        // Tombstone every tag we have observed for this element.
        if let Some(tags) = self.adds.get(elem) {
            let observed: Vec<Tag> = tags.iter().copied().collect();
            let gone = self.removals.entry(elem.to_string()).or_default();
            for tag in observed {
                gone.insert(tag);
            }
        }
    }

    fn live_tags(&self, elem: &str) -> usize {
        let empty = BTreeSet::new();
        let added = self.adds.get(elem).unwrap_or(&empty);
        let removed = self.removals.get(elem).unwrap_or(&empty);
        added.difference(removed).count()
    }

    pub fn contains(&self, elem: &str) -> bool {
        self.live_tags(elem) > 0
    }

    pub fn elements(&self) -> Vec<&str> {
        self.adds
            .keys()
            .filter(|e| self.contains(e))
            .map(String::as_str)
            .collect()
    }

    /// Join: component-wise union of both maps. Union is commutative,
    /// associative, idempotent — both components only ever grow.
    pub fn merge(&mut self, other: &ORSet) {
        for (elem, tags) in &other.adds {
            self.adds
                .entry(elem.clone())
                .or_default()
                .extend(tags.iter().copied());
        }
        for (elem, tags) in &other.removals {
            self.removals
                .entry(elem.clone())
                .or_default()
                .extend(tags.iter().copied());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Full bidirectional sync: both replicas end in the join state.
    fn sync(a: &mut ORSet, b: &mut ORSet) {
        let (sa, sb) = (a.clone(), b.clone());
        a.merge(&sb);
        b.merge(&sa);
    }

    #[test]
    fn concurrent_add_and_remove_add_wins() {
        let mut a = ORSet::new(1);
        let mut b = ORSet::new(2);
        a.add("milk");                 // tag (1,1)
        sync(&mut a, &mut b);          // both replicas have seen the add

        a.remove("milk");              // tombstones the tag it observed: (1,1)
        b.add("milk");                 // concurrently: a fresh, unseen tag (2,1)

        sync(&mut a, &mut b);
        assert!(a.contains("milk"));   // the concurrent add survives on both
        assert!(b.contains("milk"));
        assert_eq!(a.elements(), vec!["milk"]);
    }

    #[test]
    fn remove_of_observed_add_sticks() {
        let mut a = ORSet::new(1);
        let mut b = ORSet::new(2);
        a.add("milk");
        sync(&mut a, &mut b);          // b has observed the add

        b.remove("milk");              // tombstones the observed tag
        sync(&mut a, &mut b);
        assert!(!a.contains("milk"));  // a non-concurrent remove wins, as it must
        assert!(!b.contains("milk"));
    }

    #[test]
    fn merge_is_commutative_and_idempotent() {
        let mut a = ORSet::new(1);
        let mut b = ORSet::new(2);
        a.add("eggs");
        a.add("sugar");
        b.add("flour");
        b.remove("flour");             // b tombstones its own observed add

        let mut ab = a.clone();
        ab.merge(&b);
        let mut ba = b.clone();
        ba.merge(&a);
        assert_eq!(ab.elements(), ba.elements());       // commutative
        assert_eq!(ab.elements(), vec!["eggs", "sugar"]);

        let snapshot = ab.elements();
        let mut again = ab.clone();
        again.merge(&b);
        assert_eq!(again.elements(), snapshot);         // idempotent
    }
}
```

The first test is the entire chapter in miniature: two replicas, one
partition, conflicting intentions, deterministic reunion — and the user's
re-added milk survives because the remove was only allowed to kill what it
had *seen*.

=== RGA: A Sequence CRDT for Text

```rust
/// Globally unique character id: (per-replica counter, replica id).
/// Tuple order makes "later" ids sort higher — the sibling tie-break.
type Id = (u64, u64);

#[derive(Debug, Clone)]
struct Atom {
    id: Id,
    after: Option<Id>, // id of the atom this one was inserted after (None = start)
    ch: char,
    tombstone: bool,
}

/// Replicated Growable Array: characters are addressed by stable ids,
/// never by integer positions, so concurrent inserts cannot shift each
/// other's meaning. Deletes are tombstones on the atom.
#[derive(Clone)]
pub struct Rga {
    atoms: Vec<Atom>,
    replica: u64,
    next: u64,
}

impl Rga {
    pub fn new(replica: u64) -> Self {
        Rga { atoms: vec![], replica, next: 0 }
    }

    fn alloc(&mut self) -> Id {
        self.next += 1;
        (self.next, self.replica)
    }

    /// Id of the visible character immediately left of visible position
    /// `pos` (0 = before the first character). Tombstones are invisible.
    fn visible_before(&self, pos: usize) -> Option<Id> {
        let mut seen = 0;
        let mut last = None;
        for atom in &self.atoms {
            if atom.tombstone { continue; }
            if seen == pos { break; }
            seen += 1;
            last = Some(atom.id);
        }
        last
    }

    /// Insert `ch` at visible position `pos`.
    pub fn insert(&mut self, pos: usize, ch: char) {
        let after = self.visible_before(pos);
        let id = self.alloc();
        self.integrate(Atom { id, after, ch, tombstone: false });
    }

    /// Place an atom directly after its parent, but *before* any existing
    /// same-parent atom with a higher id. That single tie-break makes the
    /// placement of concurrent inserts deterministic on every replica.
    fn integrate(&mut self, atom: Atom) {
        let mut i = match atom.after {
            None => 0,
            // Atoms arrive in causal order (a child always sits behind its
            // parent in a replica's array), so the parent is present.
            Some(parent) => self.atoms.iter().position(|a| a.id == parent).unwrap() + 1,
        };
        while i < self.atoms.len()
            && self.atoms[i].after == atom.after
            && self.atoms[i].id > atom.id
        {
            i += 1;
        }
        self.atoms.insert(i, atom);
    }

    /// Delete the visible character at position `pos` (a tombstone, so the
    /// atom survives as a landmark for concurrent inserts).
    pub fn delete(&mut self, pos: usize) {
        if let Some(atom) = self.atoms.iter_mut().filter(|a| !a.tombstone).nth(pos) {
            atom.tombstone = true;
        }
    }

    /// The visible document: the atom walk, skipping tombstones.
    pub fn text(&self) -> String {
        self.atoms.iter().filter(|a| !a.tombstone).map(|a| a.ch).collect()
    }

    /// Join: union by atom id, plus tombstone propagation. Integrating in
    /// the other replica's array order respects causality; re-merging the
    /// same state is a no-op (idempotence).
    pub fn merge(&mut self, other: &Rga) {
        for atom in &other.atoms {
            if !self.atoms.iter().any(|a| a.id == atom.id) {
                self.integrate(atom.clone());
            }
        }
        for atom in &other.atoms {
            if atom.tombstone {
                if let Some(mine) = self.atoms.iter_mut().find(|a| a.id == atom.id) {
                    mine.tombstone = true;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn concurrent_inserts_converge() {
        let mut a = Rga::new(1);
        let mut b = Rga::new(2);
        a.insert(0, 'h');
        a.insert(1, 'i');
        b.merge(&a);                       // both replicas show "hi"
        assert_eq!(b.text(), "hi");

        // Partition: both type a different character at the end.
        a.insert(2, '!');                  // id (3,1), after "i"
        b.insert(2, '?');                  // id (1,2), after "i"

        // Heal: sync both ways.
        let (sa, sb) = (a.clone(), b.clone());
        a.merge(&sb);
        b.merge(&sa);
        assert_eq!(a.text(), b.text());    // identical documents
        assert_eq!(a.text(), "hi!?");      // higher id first: (3,1) > (1,2)
    }

    #[test]
    fn delete_is_a_tombstone_and_propagates() {
        let mut a = Rga::new(1);
        a.insert(0, 'h');
        a.insert(1, 'i');
        let mut b = Rga::new(2);
        b.merge(&a);

        a.delete(0);                       // tombstone 'h'
        b.merge(&a);                       // the delete travels
        assert_eq!(a.text(), "i");
        assert_eq!(b.text(), "i");

        // The tombstoned atom is still a valid landmark for new inserts.
        b.insert(0, 'H');                  // before 'i', after the ghost 'h'
        a.merge(&b);
        assert_eq!(a.text(), "Hi");
        assert_eq!(b.text(), "Hi");
    }

    #[test]
    fn merge_is_idempotent() {
        let mut a = Rga::new(1);
        a.insert(0, 'x');
        a.insert(1, 'y');
        let mut b = Rga::new(2);
        b.merge(&a);
        let (text_before, len_before) = (b.text(), b.atoms.len());
        b.merge(&a);                       // same state again
        assert_eq!(b.text(), text_before);
        assert_eq!(b.atoms.len(), len_before);
    }
}
```

The second test quietly demonstrates why tombstones in sequence CRDTs are
non-negotiable: Bob inserts `H` *after the deleted `h`* — a landmark only
the tombstone still provides — and Alice's replica, which deleted `h`
before ever seeing Bob's `H`, still integrates it in the right place.
Delete the atom outright and that insert has no anchor; Chapter 1's
tombstone line item ("heavier storage and GC") is now fully priced.

#tip([What to say when asked "so which is better, OT or CRDTs?"])[
  Refuse the framing, then answer precisely: OT centralizes order (a
  sequencer), pays with a single point of ordering, and gets lean text and
  clean history; sequence CRDTs decentralize order (stable ids), pay with
  per-character metadata and GC, and get offline editing, peer-to-peer
  sync, and end-to-end encryption for free. Then name the boundary
  condition that actually decides: if the product needs a server that can
  *read* the document (search, suggestions, AI features), a sequencer and
  plaintext-friendly transforms fit; if the product promises that no
  server ever can, CRDTs are close to forced. Figma and Google Docs on one
  side, Automerge and Yjs on the other — same problem, different promise.
]

== Scaling the Design

CRDT systems scale along three independent axes, and it is worth naming
each because they fail differently.

*Sharding by key.* Independent keys converge independently, so the
key-space shards exactly like Chapter 5's comment store: consistent-hash
keys across node groups within a region, and let each shard gossip its own
deltas. A hot *key* is only read-hot — writes land in the local replica's
slot or tags, which is the entire point — but a hot *structure* is real:
one OR-Set with 10⁹ members is a 40 GB state whose every delta exchange is
painful. The fix is to shard the structure itself: hash elements into 1 024
sub-sets, each an independent OR-Set with independent deltas, unioned at
read time. (A counter, pleasantly, is pre-sharded by construction: each
replica already owns a private slot.)

*Sync economics.* Delta groups amortize headers; ack matrices (a per-peer
vector clock of delivered deltas) bound retransmission; and when a peer's
lag exceeds a threshold, the system falls back to a full-state or
Merkle-repair exchange rather than replaying a million deltas one by one.
With more than a handful of regions, full-mesh gossip wastes bandwidth, so
deployments switch to hierarchical gossip: dense mesh inside a region,
designated spokes between regions, convergence bound now O(depth ×
interval) — the estimation table's "topology is a convergence budget" made
operational.

*Metadata lifecycle.* Tombstone GC runs continuously: a low-priority
sweeper that collects any tombstone whose ack vector shows every live
replica has merged it. Compaction rewrites sequence-CRDT runs (Yjs and
Automerge both collapse adjacent same-replica atoms into run-length
records, recovering most of the 40 B/char overhead). Both are background
work; neither ever blocks a write, because blocking a write would break
the one promise this chapter exists to keep.

== Failure Modes & Degradation

#tbl(
  (0.95fr, 1.45fr, 1.75fr),
  header: (hcell[Failure], hcell[Symptom], hcell[Handling]),
  body: (
    [Duplicated delivery], [Same delta arrives twice], [Idempotent join absorbs it — the three laws are the retry policy],
    [Reordered deltas], [Child atom arrives before parent], [State-based: harmless (joins commute). Op-based: causal broadcast buffers until predecessors arrive],
    [Replica loss], [Un-gossiped local writes vanish], [Local ack = local durability. Critical keys ack only after k-of-n gossip — a durability dial, not a consistency one],
    [Long partition], [Deep divergence on heal], [Anti-entropy still converges; Merkle repair finds differing keys in O(log n) hashes instead of full transfer],
    [Premature tombstone GC], [Deleted elements resurrect when a lagging replica rejoins], [Ack-gated GC only: never collect on a timer (Section 9.10)],
    [Clock skew (LWW)], [Truly-later write loses silently], [Prefer MV-register + context, or hybrid logical clocks; monitor skew as a first-class metric],
    [Split-brain clients], [User edits on two devices concurrently], [Not a failure — the design's home turf; add-wins / sibling semantics apply],
  ),
)

#pitfall([The resurrection bug is a rite of passage])[
  Nearly every team that ships a CRDT store re-discovers the deleted-data
  resurrection of Section 9.10 in production: someone "optimizes" tombstone
  retention from "until all replicas ack" to "keep for 30 days", a replica
  comes back after 31, and customer data un-deletes itself. Timer-based GC
  of convergence metadata is never safe; only knowledge-based GC is. If the
  interviewer asks for war stories, this is the canonical one — Redis CR,
  Riak, and Cassandra's `gc_grace_seconds` all have scars here, and
  Cassandra documents the foot-gun by name.
]

== Trade-offs & Alternatives

#tbl(
  (1.15fr, 0.95fr, 0.95fr, 0.9fr, 1.25fr),
  header: (hcell[Approach], hcell[Writes under partition], hcell[Metadata], hcell[Invariants], hcell[Complexity lives in]),
  body: (
    [Single-leader replication], [Minority side stalls], [None], [Full (leader orders all)], [Failover & split-brain fences],
    [Consensus (Raft/Paxos)], [Minority side stalls], [None], [Full], [Protocol correctness; WAN RTT per write],
    [OT + sequencer (Ch. 1)], [Sequencer failover stall], [Tiny], [Per-document order], [Transform-matrix correctness],
    [CRDTs (this chapter)], [Never blocked], [Tags, tombstones, clocks; GC forever], [Per-object only], [Merge proofs; metadata lifecycle],
    [App-level siblings], [Never blocked], [None in the store], [None], [Every client's merge code],
  ),
)

Three finer-grained choices recur inside the CRDT camp itself.

- *Add-wins vs remove-wins.* Our OR-Set lets a concurrent add survive a
  remove; the remove-wins variant tombstones the element so aggressively
  that even concurrent adds die. Add-wins matches user intent for carts
  and editors ("I put it back!"); remove-wins matches moderation and
  revocation ("this must be gone, whoever touched it"). Pick per field,
  not per system.
- *LWW vs MV registers.* LWW is one line of merge logic and silently
  discards concurrent writes; MV preserves them as siblings and bills the
  application. Rule of thumb: LWW for overwrite-able derived state
  (caches, presence, "last seen"), MV for anything a user would be angry
  to lose.
- *State-based vs op-based.* State tolerates any transport but moves more
  bytes; op-based moves few bytes but needs exactly-once causal broadcast.
  Delta-state closes most of the byte gap, which is why the production
  mainstream is state-based with deltas.

#insight([The boundary CRDTs cannot cross])[
  CRDTs make *convergence* free; they make *invariants* impossible without
  coordination. "Balance must never go negative", "a username is taken
  exactly once", "one winner per auction" — each requires the replicas to
  agree on a fact *before* acting, which is coordination, which is what we
  gave up. This is not a limitation of cleverness but CAP itself, wearing
  a name tag. The production answer is hybrid: CRDTs for the 95% of state
  that is mergeable, consensus or escrow (pre-reserving a quota of the
  invariant, e.g. each region may sell 100 of the 300 seats) for the rest.
  Saying this sentence in the interview is worth more than deriving any
  merge rule.
]

== Observability & SLOs

An AP system's vital signs are different from a CP system's: nothing ever
blocks, so "is it up?" is uninteresting, and the interesting question is
"how far apart are the replicas right now?".

#tbl(
  (0.9fr, 1.6fr, 1.15fr),
  header: (hcell[Signal], hcell[What it measures], hcell[Alert when]),
  body: (
    [Convergence lag], [Age of the oldest local write not yet ack'd by all peers], [p99 \> 10 s: partition or slow peer],
    [Delta backlog], [Undelivered deltas per peer], [Growing for \> 60 s: link down or peer wedged],
    [Tombstone ratio], [Tombstones ÷ live entries], [\> 3× after GC window: sweeper broken or acks missing],
    [Sibling rate], [MV-register reads returning multiple values], [Sustained rise: clients writing blind (missing contexts)],
    [Merge throughput], [Deltas merged per second], [Sudden drop: gossip stalled; sudden spike: repair storm],
    [Metadata overhead], [CRDT bytes ÷ payload bytes], [\> 2× post-compaction: allocation strategy regressing],
  ),
)

*SLOs.* Write availability 99.99% per region (writes never coordinate, so
this is mostly "is the local process alive"). Convergence: p99 ≤ 2 s within
the mesh, ≤ 30 s during a degraded topology. Durability: default keys ack
locally; billing-class keys ack after 2-of-3 regions have merged the delta
— still coordination-free, just patient. Metadata: ≤ 2× payload after each
compaction window.

== Interview Wrap-Up

*Likely follow-ups, with the shape of a strong answer.*

- _"Enforce 'balance ≥ 0' across regions."_ You cannot, not with CRDTs
  alone — say so instantly, it is the highest-signal sentence available.
  Then offer escrow (pre-partition the spendable budget per region) or a
  CP island (consensus on that one key) and note that the rest of the
  system stays AP.
- _"Unique username registration?"_ Same boundary: consensus for the
  registry key, CRDTs for the profile data. Hybrid designs are the senior
  answer.
- _"Why not just Cassandra's LWW everywhere?"_ Clock skew chooses your
  losers, and concurrent writes are silently destroyed. Fine for caches,
  negligent for user data.
- _"How do Redis / Riak / DynamoDB-style stores do multi-region?"_ Redis
  CR is delta-state CRDTs; Riak is OR-Sets and MV-registers with dotted
  version vectors; Dynamo-style stores push sibling resolution to the
  client — the "app-level siblings" row of the trade-off table.
- _"Two users type into the same word — what do they see?"_ RGA: both
  strings converge; possible interleaving of the two runs, prevented by
  LSEQ/Fugue-style allocation; in practice, cursors and presence (Chapter
  1's awareness channel) keep humans out of each other's words anyway.
- _"When would you refuse CRDTs?"_ Strong global invariants, very large
  per-object state (a CRDT wrapping a 1 GB blob merges terribly), and
  teams without the appetite to own merge semantics. A boring CP database
  is a fine choice when the product can afford it.

*Checklist for the whiteboard.* (1) Define replica, partition,
convergence. (2) State CAP and pick AP explicitly. (3) Derive one CRDT
from the three laws — a G-Counter takes sixty seconds. (4) Show one
concurrent-conflict merge end to end. (5) Name tombstones and the
ack-gated GC. (6) Draw the sync fabric: deltas, gossip, repair. (7)
Volunteer the invariant boundary before the interviewer finds it.

== Summary & Further Reading

CRDTs answer the chapter's prompt by changing the question. Instead of
ordering concurrent writes — impossible without coordination, undefined
across a partition — they build data types whose states form a
join-semilattice and whose merge is the join, so that commutativity,
associativity, and idempotence make order, grouping, and duplication
irrelevant. On that foundation: counters as per-replica slots merged by
max; sets as union, then union-twice with tombstones, then observed-remove
with unique tags for add-wins; registers as timestamps (dangerous) or
sibling sets (honest); text as stable-identity atoms ordered by
(parent, id). Causality is tracked with vector clocks and dots; sync is
deltas over gossip with Merkle repair; tombstones are collected only when
every replica has ack'd them. The price is metadata and the loss of global
invariants; the reward is that the write path never, ever waits — Chapter
1's road not taken, now fully mapped.

*Further reading.*

- The source video: _"CRDTs — Stop Worrying About Write Conflicts —
  Systems Design 0 to 1 with Ex-Google SWE"_ (Jordan has no life):
  `https://www.youtube.com/watch?v=FG5Varj1Ows`
- Shapiro, Preguiça, Baquero, Zawirski — _"Conflict-free Replicated Data
  Types"_ (2011) and _"A Comprehensive Study of Convergent and Commutative
  Replicated Data Types"_ (2011) — the founding papers; the second is the
  catalog this chapter compressed.
- Almeida, Shoker, Baquero — _"Delta State Replicated Data Types"_ (2018)
  — the sync-economics fix, formally.
- Lamport — _"Time, Clocks, and the Ordering of Events in a Distributed
  System"_ (1978) — happens-before, in its original eight pages.
- Riak KV's documentation on dotted version vectors, and Redis CR's
  active-active whitepapers — production CRDT stores, warts included.
- The Ink & Switch _local-first software_ essay, and the Yjs and Automerge
  codebases — sequence CRDTs doing Chapter 1's job in the wild.

== Chapter Glossary

#tbl(
  (auto, 1fr),
  header: (hcell[Term], hcell[Meaning]),
  body: (
    [Add-wins semantics], [A concurrent add survives a concurrent remove; the OR-Set default],
    [Anti-entropy], [Background replica-pair reconciliation that drives divergence toward zero],
    [Associativity], [Grouping of merges is irrelevant: (a ∨ b) ∨ c = a ∨ (b ∨ c)],
    [CAP], [Under partition, choose consistency (CP: stall writes) or availability (AP: merge later); you cannot have both],
    [Causal context], [Opaque version vector handed to a reader and echoed on overwrite, separating "supersedes" from "concurrent"],
    [Commutativity], [Order of merges is irrelevant: a ∨ b = b ∨ a],
    [Concurrent events], [Events with no happens-before path between them; no fact-of-the-matter order exists],
    [Convergence], [Replicas that saw the same updates are in the same observable state],
    [Coordination], [Pre-write communication (leader, lock, quorum) — the thing partitions disable],
    [CvRDT / CmRDT], [State-based (merge states by join) vs op-based (broadcast commuting operations) CRDT families],
    [Delta-state], [Shipping the minimal state change instead of full state; deltas merge by the same join],
    [Dot], [A (replica, counter) pair naming one event; the OR-Set tag and the version vector's precise companion],
    [Escrow], [Pre-allocating shares of an invariant (e.g. quota of seats) so regions can act without coordinating],
    [Eventual consistency], ["If updates stop, replicas end up equal" — liveness only, no safety during updates],
    [G-Counter / PN-Counter], [Per-replica slots merged by max; PN adds a second counter so the derived value can fall],
    [Gossip], [Randomized peer-to-peer exchange; O(log R) rounds to infect R replicas],
    [Happens-before (→)], [Lamport causality: program order plus message passing, transitively closed],
    [Idempotence], [Duplication is irrelevant: a ∨ a = a — the property that makes retries free],
    [Inflation / monotonicity], [Updates only move state up the lattice; nothing is ever un-known],
    [Interleaving anomaly], [Concurrent text runs merged character-by-character; cosmetic, fixed by newer allocators],
    [Join-semilattice], [A partial order where every pair has a least upper bound; merge = that bound],
    [LWW register], [Keep the value with the max timestamp; discards concurrent writes, trusts clocks],
    [Merkle repair], [Hash-tree comparison of key-spaces to find divergence in O(log n) hashes],
    [MV register], [Keeps all concurrent values as siblings; the application resolves with context],
    [OR-Set], [Observed-remove set: tagged adds, tombstone-the-observed removes; add-wins],
    [RGA], [Replicated Growable Array: sequence CRDT with stable atom ids and parent links],
    [Strong eventual consistency], [Eventual consistency plus same-updates ⇒ same-state safety; what CRDTs prove],
    [Tombstone], [A mergeable record of deletion; collectible only when all replicas ack it],
    [Vector clock], [Replica→counter map encoding causal history; dominates iff ≥ in every component],
  ),
)

#v(0.8em)
#align(center)[
  #text(size: 8.5pt, fill: slate)[
    — End of Chapter 9 · Next: Chapter 10 —
  ]
]
