// ============================================================================
//  CHAPTER 11 — Designing for Correctness: How ACID Transactions Work
//  Source: "Intro to ACID Database Transactions | Systems Design Interview:
//  0 to 1 with Google Software Engineer" (channel: Jordan has no life)
//  Link: https://www.youtube.com/watch?v=oGmxzUBCYtY
// ============================================================================

#import "../template.typ": *

= Designing for Correctness: How ACID Transactions Work

#notebox([Problem source])[
  This chapter solves the problem posed in the talk _"Intro to ACID
  Database Transactions"_ from the series _Systems Design Interview: 0 to
  1 with Google Software Engineer_ (channel: _Jordan has no life_). It is
  the third fundamentals deep dive, and it completes a trilogy: Chapter 8
  built the storage engine's pages and indexes, this chapter builds the
  *correctness layer* that lets many statements act as one on top of those
  pages, and Chapter 9 showed what you must surrender — this chapter's
  guarantees — when you refuse coordination across regions. Read in that
  order, the three chapters are one argument: pages, then correctness,
  then the price of correctness. All terms are defined before use; all
  reference code is Rust with deterministic tests.
]

== The Problem Statement

The interviewer draws two bank accounts and says:

_"A transfer debits account A by \$100 and credits account B by \$100.
Design the transaction layer of a relational database: let users bundle
many reads and writes into one logical unit, keep that unit correct while
thousands of other units run concurrently, and keep it correct when the
machine crashes in the middle. Define 'correct' — precisely — and then
build the machinery that enforces it."_

The prompt's sting is in the last sentence. Every engineer can say
"ACID"; the interview is won by the candidate who can *define* each letter
as an enforceable contract, name the anomaly each isolation level admits,
and point at the exact mechanism — log record, lock, version — that
prevents it. This chapter builds that machinery from the crash upward.

#defterm([Transaction])[
  A bundle of reads and writes treated as one logical unit of work: it
  either happens completely or not at all, it never exposes half-applied
  state to others, and once confirmed it is permanent. The transfer above
  is the canonical example — debit and credit must live or die together,
  because money is not allowed to be created or destroyed by a power
  outage.
]

#defterm([A — Atomicity])[
  _All or nothing._ A transaction's writes are applied in full or not at
  all, even if the machine dies mid-transaction. Enforced by the log: on
  recovery, the engine *redoes* committed transactions and *undoes* (or
  discards) uncommitted ones (Section 11.7). Atomicity is a property of
  the write path, not of careful coding — "be careful not to crash" is
  not a mechanism.
]

#defterm([C — Consistency])[
  _Invariants hold._ Every transaction moves the database from one valid
  state to another: foreign keys resolve, balances stay non-negative,
  uniqueness holds. The honest detail most answers miss: consistency is
  largely the *application's* property — the database enforces declared
  constraints and provides A, I, and D, but "a transfer preserves total
  money" is logic the transaction author must write correctly. C is the
  letter the machine assists and the human owns.
]

#defterm([I — Isolation])[
  _Concurrent transactions do not see each other's intermediate state._
  Perfect isolation (serializability) means the outcome equals *some*
  serial execution of the transactions — nobody can prove they ran in
  parallel. Perfect isolation is expensive, so the standard sells it in
  graded levels, each defined by which *anomalies* it forbids (Section
  11.8): dirty reads, non-repeatable reads, phantoms, lost updates, write
  skew. Choosing a level is choosing which anomalies your application can
  survive.
]

#defterm([D — Durability])[
  _Once committed, never lost._ When the database acknowledges a commit,
  the transaction's effects survive process crashes, power loss, and disk
  failure up to the replication factor. The mechanism is the write-ahead
  log flushed to stable storage *before* the ack — Chapter 8's WAL,
  promoted from page insurance to contractual guarantee. Durability is a
  statement about the log, not about the data pages — those may still be
  dirty in the buffer pool when we ack, and that is fine.
]

== Scope & Clarifying Questions

#tbl(
  (auto, 1fr),
  header: (hcell[Candidate asks], hcell[Interviewer answers]),
  body: (
    [Single node or distributed?], [Single node first (Chapter 8's engine); sketch 2PC and sagas as the distributed answer],
    [Workload?], [OLTP: 10⁴ txn/s, small read-modify-write transactions, a few hot rows],
    [Which isolation default?], [Justify a default; expect to defend READ COMMITTED vs snapshot isolation],
    [Concurrency control?], [Show both families: locking (2PL) and versioning (MVCC); know when OCC wins],
    [Crash model?], [Process kill and power loss; storage survives. Byzantine corruption is out of scope],
    [Replication?], [Mention streaming the WAL to replicas; deep replication design is Chapter 9's territory],
  ),
)

#notebox([Agreed scope])[
  + Define the four guarantees as enforceable contracts and identify the
    mechanism behind each: log (A, D), locks/versions (I), constraints +
    application logic (C).
  + Design the *write path*: WAL with commit records, group commit,
    checkpoints, recovery (redo/undo) in the spirit of ARIES.
  + Design the *concurrency path*: two-phase locking with deadlock
    handling, MVCC snapshots, and when optimistic control beats both.
  + Enumerate the *anomaly zoo* and map isolation levels onto it —
    including where snapshot isolation famously stops (write skew).
  + Close with the distributed boundary: 2PC, its blocking failure mode,
    and sagas — and the bridge to Chapter 9's invariant boundary.
  + All reference code in Rust with deterministic tests.
]

== Functional Requirements

+ *Transactional demarcation.* `BEGIN`, `COMMIT`, `ABORT`, with savepoints
  for partial rollback; every statement between them is one atomic unit.
+ *Atomic commit.* A crash at any instant leaves either all of the
  transaction's effects or none; recovery decides from the log alone.
+ *Durable acknowledgment.* `COMMIT` returns only after the commit record
  is on stable storage (and, if configured, on a replica).
+ *Selectable isolation.* Per-transaction isolation levels from READ
  COMMITTED to SERIALIZABLE, with documented anomaly guarantees.
+ *Concurrent correctness.* Readers never block writers and vice versa
  under MVCC; writers never corrupt each other under any level;
  deadlocks are detected and broken by victim abort.
+ *Point-in-time consistency.* A transaction reads a stable snapshot for
  its lifetime (under snapshot isolation), including its own writes.

== Non-Functional Requirements

- *Throughput.* ≥ 10⁴ txn/s single-node for small transactions; the log
  append and lock table must not become the ceiling.
- *Commit latency.* p99 ≤ 2 ms via group commit — one flush amortized
  over a batch, never one flush per transaction.
- *Recovery time.* After a crash, the database accepts work again in
  seconds: bounded redo since the last checkpoint, no full-data scans.
- *Version hygiene.* MVCC garbage (dead versions) is collected
  continuously; a long-lived snapshot may pin versions, and that hazard
  is surfaced as a metric, not discovered as a full disk.
- *Honest degradation.* Under lock contention the system degrades into
  waits and rare victim aborts — never into wrong answers.

== Back-of-the-Envelope: The Cost of the Four Letters

Assumptions: 10⁴ txn/s; average transaction = 20 row reads + 10 row
writes; a redo record ≈ 100 B per written row; a row ≈ 200 B; SSD flush
≈ 0.5–1 ms.

#tbl(
  (auto, 1fr),
  header: (hcell[Quantity], hcell[Estimate (with assumptions)]),
  body: (
    [WAL bandwidth], [10⁴ txn/s × 10 writes × 100 B ≈ *10 MB/s* of redo — append-friendly, trivial next to an SSD's hundreds of MB/s],
    [Flush discipline], [One flush per commit ⇒ ≤ ~1–2k txn/s, not 10⁴. *Group commit* batches ~100 txns per flush: 10⁴ txn/s at ~100 flushes/s, +~1 ms commit latency],
    [Write amplification], [1 logical write ⇒ WAL record + eventual data-page write + replica stream ≈ *3×*; checkpoints smooth the page-write side (§11.7)],
    [MVCC version churn], [10⁵ row-writes/s × 200 B ≈ *20 MB/s of new versions* ≈ 1.7 TB/day → vacuum cadence is an operational SLO, and a day-long snapshot can pin all of it],
    [Lock manager load], [10⁴ txn/s × ~30 lock acquisitions ≈ *3 × 10⁵ ops/s* on an in-memory table — the table is never the bottleneck; *hot rows* are (Chapter 6's leaderboard keys, again)],
    [Recovery window], [Checkpoint every 5 min ⇒ redo replays ≤ 5 min of WAL ≈ 3 GB at 100+ MB/s ⇒ *back up in well under a minute*],
  ),
)

#insight([The four letters are bought with four currencies])[
  Atomicity costs log space (undo/redo images). Durability costs flush
  latency (amortized by group commit). Isolation costs either *waiting*
  (locks), *aborting* (optimistic validation), or *space* (MVCC
  versions) — pick your tax. Consistency costs schema constraints and
  careful transaction authorship. A transaction system is a price list;
  the interview is reading it aloud without flinching.
]

== The Core Challenge: Two Enemies, One Log, One Schedule

A transaction layer fights two enemies that never coordinate with each
other, which is exactly what makes the problem hard.

*Enemy one: the crash.* A machine can stop between any two instructions.
The transfer transaction writes two pages — debit A, credit B — and the
buffer pool (Chapter 8) may flush either, both, or neither, in any order,
at any time. If the debit's page reaches disk and the credit's does not,
the restart finds money destroyed. The crash does not have to be likely;
at 10⁴ transactions per second, "unlikely per transaction" becomes
"certain this quarter".

*Enemy two: concurrency.* Thousands of transactions interleave on the
same rows. Without control, their reads and writes interleave too — and
every anomaly in Section 11.8's zoo is a specific interleaving with a
name and a victim. The transfer read by a concurrent reporter mid-flight
shows the bank \$100 short; two concurrent increments to the same counter
produce one increment.

The two enemies share one battlefield — the *order of writes* — and the
design answers each with one discipline:

#insight([Log first, then order the interleavings])[
  Against crashes: *never let data reach disk before its description
  does* — the write-ahead log. One append-only stream, ordered by arrival,
  holding enough to redo what committed and undo what did not; recovery
  is replay, and replay is idempotent. Against concurrency: *decide which
  interleavings are legal* — with locks that forbid them (pessimistic) or
  versions that route around them (optimistic/MVCC). Every transaction
  system in production is a combination of one answer from each list.
  The rest of this chapter is the menu, the prices, and four Rust
  skeletons that make the menu concrete.
]

== Deep Dive: Atomicity & Durability — The Write-Ahead Log

The WAL of Chapter 8 insured individual *pages*; here it is promoted to
insure *transactions*. The discipline has three rules, and everything else
is optimization.

+ *Log before data.* Before any dirty data page may reach disk, every log
  record describing its changes must already be on stable storage. Then a
  crash can never leave a change on disk that the log cannot explain.
+ *Commit means flushed.* `COMMIT` appends a *commit record* and flushes
  the log tail to stable storage (and returns only after the flush
  acknowledges). The data pages may still be dirty — they can be rebuilt
  from the log forever. The commit record is the exact instant a
  transaction becomes real.
+ *Recovery is two passes.* On restart: *redo* the effects of every
  committed transaction (durability), *undo or discard* the effects of
  every uncommitted one (atomicity). The Rust listing in Section 11.13
  implements the conceptual core in thirty lines.

#defterm([Steal / no-force buffer management])[
  The two freedoms that make the WAL necessary and sufficient. _Steal_:
  the buffer pool may write a page to disk *while a transaction that
  dirtied it is still uncommitted* (stealing its frame) — legal because
  the undo information is already in the log. _No-force_: a committing
  transaction is *not* required to flush its data pages — legal because
  the redo information is in the log. Steal buys memory flexibility;
  no-force buys commit speed; the WAL is the price of both. The
  industrial-strength formulation of all of this is the ARIES protocol
  (log sequence numbers on every page and record, physiological logging,
  repeating history before undo) — same three rules, hardened.
]

#defterm([Group commit / checkpoint])[
  _Group commit_ amortizes the one expensive operation — the flush — over
  a batch: transactions queue at commit, one flush confirms them all
  (~10⁴ txn/s at ~100 flushes/s from the estimation table). A
  _checkpoint_ periodically forces all dirty pages to disk and records
  the point in the log up to which recovery never needs to look; it caps
  the redo window so crash recovery is seconds, not a full replay of
  history.
]

== Deep Dive: Isolation Levels and the Anomaly Zoo

"Isolation" becomes precise only when stated negatively: which *anomalies*
— named, reproducible bad interleavings — a level forbids. Learn the zoo
first; the levels are just fences around subsets of it.

#defterm([Isolation anomaly])[
  A specific, nameable interleaving of two or more transactions that
  produces a result no serial execution could produce (or that leaks
  uncommitted state). Anomalies are the vocabulary of correctness: "our
  system is buggy" is a complaint; "our system allows write skew" is a
  diagnosis with a known cure.
]

#tbl(
  (0.85fr, 1.9fr, 1.5fr),
  header: (hcell[Anomaly], hcell[The interleaving], hcell[The damage]),
  body: (
    [Dirty read], [T1 reads a row T2 has written but not committed; T2 aborts], [T1 acted on data that never officially existed],
    [Non-repeatable read], [T1 reads a row; T2 updates and commits; T1 re-reads and gets a different value], [One transaction, two realities],
    [Phantom], [T1 runs a predicate query ("accounts over 1 000"); T2 inserts a matching row and commits; T1 re-runs and sees a new row], [Sets change under a reader's feet],
    [Lost update], [T1 and T2 both read counter = 10, both write 11], [An increment silently vanishes — Chapter 5's vote counters, unprotected],
    [Read skew], [T1 reads A, T2's transfer A→B commits, T1 reads B], [T1 saw A before and B after: the \$100, mid-flight, visible to no one else],
    [Write skew], [T1 and T2 each read a *set* ("doctors on call = 2") and each writes a *different* row (their own status)], [Both commit; the invariant dies — snapshot isolation's famous blind spot (§11.13)],
  ),
)

The SQL standard sells isolation as four fences, each excluding a subset
of the zoo:

#tbl(
  (1.15fr, 0.75fr, 0.95fr, 0.7fr, 0.85fr, 0.85fr),
  header: (hcell[Level], hcell[Dirty], hcell[Non-rep.], hcell[Phantom], hcell[Lost upd.], hcell[Write skew]),
  body: (
    [READ UNCOMMITTED], [possible], [possible], [possible], [possible], [possible],
    [READ COMMITTED], [prevented], [possible], [possible], [possible], [possible],
    [REPEATABLE READ (SI)], [prevented], [prevented], [prevented], [prevented], [*possible*],
    [SERIALIZABLE], [prevented], [prevented], [prevented], [prevented], [prevented],
  ),
)

#notebox([The names lie; the mechanisms don't])[
  The standard's table is a floor, not a description of any real engine.
  PostgreSQL's REPEATABLE READ is *snapshot isolation* — phantoms
  prevented, lost updates prevented by first-committer-wins, write skew
  admitted. MySQL/InnoDB's REPEATABLE READ is *next-key-locked two-phase
  locking* — phantoms prevented by locking index gaps, write skew
  admitted unless you `SELECT ... FOR UPDATE`. PostgreSQL's SERIALIZABLE
  is SSI (snapshot isolation plus lightweight dangerous-structure
  detection), not a lockout. Asking "which engine, which mechanism, which
  anomalies *actually* excluded?" is the difference between reciting the
  standard and knowing a database.
]

#defterm([Snapshot isolation (SI)])[
  The MVCC isolation level: each transaction reads from a *snapshot* — the
  committed state as of its start, plus its own writes — so its view never
  changes under it, and writes use *first-committer-wins* (two
  transactions writing the same row: second to commit aborts). SI forbids
  every anomaly in the table except *write skew*, because write skew's
  transactions write *different* rows — no first-committer-wins conflict
  exists to catch it. The cure is promotion (serialize the dangerous
  read-write dependency, as SSI does) or materialization (`SELECT ...
  FOR UPDATE` turns the read rows into write-locked ones), both
  demonstrated in the Rust section.
]

== Deep Dive: Pessimistic Concurrency Control — Two-Phase Locking

The oldest working answer: before touching a row, take a lock on it, and
let the lock table — not luck — decide which interleavings are legal.

#defterm([Two-phase locking (2PL); strict 2PL])[
  Transactions acquire *shared* locks to read and *exclusive* locks to
  write; shared locks coexist, exclusive locks exclude everything. The
  two phases: a _growing_ phase in which locks are only acquired, and a
  _shrinking_ phase in which they are only released — once a transaction
  releases any lock, it may take no new ones. That discipline alone
  guarantees conflict-serializable schedules. Production databases use
  _strict_ 2PL, which holds all exclusive locks until commit/abort —
  slightly less parallelism, but no transaction ever reads uncommitted
  data (so no cascading aborts), and recovery stays simple.
]

2PL's famous failure is not incorrectness but *deadlock*: T1 holds A and
waits for B; T2 holds B and waits for A; neither can move. The answers:

- *Detection*: maintain a *wait-for graph* — an edge T→U when T waits on
  a lock U holds — and find cycles (the Rust listing in Section 11.13
  detects them by iteratively trimming transactions nobody waits on).
  Break a cycle by aborting the *victim*: youngest transaction, least
  work done, or fewest locks — anything cheap and deterministic.
- *Avoidance*: timeouts (crude, universal) or lock ordering (take locks
  in key order everywhere — eliminates cycles by construction, at the
  price of application discipline).

#tip([Deadlock hygiene is an interview freebie])[
  Three habits kill most production deadlocks, and naming them signals
  experience: (1) touch rows in a consistent order (primary-key order is
  fine); (2) keep transactions short — no network calls, no user think
  time inside a lock scope; (3) take the coarsest necessary lock latest
  in the transaction. Deadlocks are not a mystery; they are a scheduling
  choice you can usually design away before detection ever fires.
]

== Deep Dive: Optimistic Control and MVCC

Locking pays for correctness with *waiting*. Two alternatives pay with
other currencies.

*Optimistic concurrency control (OCC).* Assume conflicts are rare: run
the whole transaction against private state, keeping a read set and a
write set; at commit, *validate* — did any row I read change underneath
me? does my write set collide with a concurrent committer? — then commit
or abort. No locks held during execution, so no waits and no deadlocks;
the cost is abort storms under contention (on a hot row, OCC aborts
exactly the transactions 2PL would merely delay). OCC wins for
read-heavy, conflict-sparse workloads; it is the wrong tool for Chapter
6's hot leaderboard keys.

#defterm([MVCC — multiversion concurrency control])[
  Never overwrite a row in place; every write creates a new *version*
  stamped with its creator's transaction id, and readers follow *version
  chains* to the newest version their snapshot may see. The result is the
  property application developers actually want: *readers never block
  writers and writers never block readers* — reads are snapshot reads,
  writes only contend with concurrent writes to the same row
  (first-committer-wins). The price is space (Section 11.5's version
  churn) and a garbage collector (_vacuum_ in PostgreSQL vocabulary) that
  may reclaim a version only when no live snapshot can still see it —
  which is why a day-old transaction pinning an ancient snapshot is an
  operational emergency, not a curiosity.
]

*Serializable snapshot isolation (SSI)* deserves one paragraph because it
is the modern summit: run snapshot isolation as usual, but track
*dangerous structures* — the read-write antidependency pairs that underlie
write skew — and abort one participant when the pattern completes.
Serializable outcomes at near-SI cost: PostgreSQL's SERIALIZABLE since
9.1, and the reason "serializable is too slow" is a decade out of date.

== Deep Dive: The Distributed Boundary — 2PC and Sagas

Everything so far is one machine's machinery. The moment a transaction
spans nodes — the transfer's two accounts live in different regions — no
local log can commit it atomically, and Chapter 9's physics returns.

#defterm([Two-phase commit (2PC)])[
  The distributed atomic-commit protocol. _Prepare_: the coordinator asks
  every participant to durably promise "I can commit" (each writes a
  prepared record to its own log and locks its rows). _Commit_: if all
  vote yes, the coordinator logs the decision and tells everyone to
  commit; any no (or timeout) means abort. 2PC delivers atomicity across
  nodes, and its flaw is structural: after voting yes, a participant is
  *blocked* — locked and unable to finish — until it learns the
  decision, so a coordinator crash mid-protocol holds locks hostage until
  recovery. 2PC is correct, blocking, and increasingly confined to
  single-cluster use; across organizations and regions it is effectively
  extinct.
]

#defterm([Saga])[
  The microservice-era replacement for cross-service transactions: split
  the global transaction into a chain of local ACID transactions, each
  with a *compensating action* that undoes it ("capture payment" ↔
  "refund payment"). Steps run without locks held across services; a
  failure triggers compensations in reverse order. Sagas trade I for
  availability — intermediate states are visible — which is exactly
  Chapter 10's workflow-compensation pattern and Chapter 9's invariant
  boundary restated: when coordination is unaffordable, replace atomicity
  with apology.
]

#insight([The trilogy's moral])[
  Chapter 8 built pages; this chapter makes multi-statement changes
  correct on one node — at the price of coordination (locks, validation,
  a commit flush). Chapter 9 showed systems that refuse coordination and
  therefore *cannot* offer this chapter's guarantees across regions. CAP
  is the seam between them: ACID is what you can promise inside the
  coordination boundary; CRDTs are what you can promise outside it; and
  senior system design is choosing — per datum, per operation — which
  side of the seam each piece of state lives on.
]

== API Design

The interface is small because the semantics are heavy. Every verb below
maps to exactly one mechanism from the deep dives.

#tbl(
  (1.5fr, 0.8fr, 1.95fr),
  header: (hcell[Statement], hcell[Mechanism], hcell[Semantics]),
  body: (
    [`BEGIN [ISOLATION LEVEL …]`], [txn manager], [Opens a transaction; under MVCC, takes the snapshot now; under 2PL, opens the lock scope],
    [`SELECT …`], [MVCC / S-locks], [Snapshot read (no locks) or shared-lock read (strict 2PL), per engine and level],
    [`SELECT … FOR UPDATE`], [X-locks], [Materializes reads as write locks — the portable write-skew vaccine],
    [`INSERT / UPDATE / DELETE`], [versions + X-locks], [Writes new versions (MVCC) under exclusive locks; redo records stream to the WAL],
    [`SAVEPOINT name`], [partial undo], [Marks a point inside the transaction; `ROLLBACK TO` undoes back to it without aborting the whole unit],
    [`COMMIT`], [WAL + locks], [Validate (OCC/SI) → append commit record → *flush* → release locks → ack],
    [`ABORT`], [undo], [Discard versions / apply undo records → release locks; idempotent and always safe],
    [`CHECKPOINT` / `VACUUM`], [internal], [Cap the redo window; reclaim versions no snapshot can see],
  ),
)

== High-Level Architecture

The transaction manager is the conductor; the three instruments are the
lock table, the version store, and the log. Note how little of this
diagram is new: the buffer pool and data pages are Chapter 8, unchanged —
transactions are a *layer*, not a rebuild.

#canvas(h: 5.3cm)[
  // row 0
  #node(0.4cm, 0cm, 3.4cm, 0.85cm, [Clients / SQL], fill: faint, edge: slate)
  #node(4.6cm, 0cm, 6.0cm, 0.85cm, [Transaction manager \ begin · snapshot · commit · abort], edge: primary, fill: faint-blue)
  #arrow(3.8cm, 0.42cm, 4.6cm, 0.42cm, color: slate)
  #glabel(10.85cm, 0.3cm)[BEGIN · READ · WRITE · COMMIT]

  // row 1: lock mgr, mvcc, wal
  #node(0.4cm, 1.9cm, 4.7cm, 0.95cm, [Lock manager \ 2PL + deadlock detector], edge: primary, fill: faint-blue)
  #node(5.6cm, 1.9cm, 5.2cm, 0.95cm, [MVCC store \ version chains + snapshots], edge: primary, fill: faint-blue)
  #node(11.3cm, 1.9cm, 4.8cm, 0.95cm, [WAL \ append-only redo/undo], edge: teal, fill: faint-teal)
  #arrow(6.2cm, 0.85cm, 2.75cm, 1.9cm, color: slate)
  #arrow(7.6cm, 0.85cm, 8.2cm, 1.9cm, color: slate)
  #arrow(9.4cm, 0.85cm, 13.7cm, 1.9cm, color: teal)

  // row 2: buffer pool, data pages, log file
  #node(0.4cm, 3.85cm, 5.8cm, 1.0cm, [Buffer pool (Ch. 8) \ steal / no-force], edge: primary, fill: faint-blue)
  #node(7.0cm, 3.85cm, 4.0cm, 1.0cm, [Data pages \ B+ tree (Ch. 8)], edge: slate, fill: faint)
  #node(11.9cm, 3.85cm, 4.2cm, 1.0cm, [Log file \ fsync at commit], edge: teal, fill: faint-teal)
  #arrow(8.2cm, 2.85cm, 3.3cm, 3.85cm, color: slate)
  #arrow(6.2cm, 4.35cm, 7.0cm, 4.35cm, color: slate)
  #arrow(13.7cm, 2.85cm, 13.7cm, 3.85cm, color: teal)
  #glabel(6.15cm, 3.5cm)[dirty pages flushed lazily by checkpoints]
  #glabel(13.85cm, 3.25cm, fg: teal)[commit = flush]
]

#notebox([Reading the diagram])[
  A `COMMIT` traces the teal spine: transaction manager → WAL append →
  flush to the log file → ack. The data pages are deliberately *not* on
  that path — no-force means they reach disk later, at checkpoint time,
  via the buffer pool. That indirection is the whole performance story:
  the commit path is one sequential append (fast, batchable), while the
  random page writes it logically implies are deferred and coalesced.
  Recovery walks the log file, replays committed transactions into the
  buffer pool, and discards the rest — the diagram's two disks answer the
  two enemies of Section 11.6.
]

== Rust Reference Implementations

Four pieces with deterministic tests: an MVCC store with snapshot
transactions, a 2PL lock table with deadlock detection, a WAL with
recovery, and — using the first — a live demonstration of write skew and
its cure. Together they are Section 11.6's "one answer from each list",
made executable.

=== MVCC: Snapshot Transactions

```rust
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// One version of a key: a value plus the id of the transaction that
/// created it. Old versions are never overwritten in place — readers on
/// old snapshots keep walking the chain. (A real engine also tracks an
/// `end` stamp; vacuum reclaims versions no live snapshot can see.)
#[derive(Debug, Clone)]
struct Version {
    value: u64,
    begin: u64,
}

/// A minimal MVCC store providing snapshot isolation:
///  - each transaction reads the committed state as of its begin, plus
///    its own buffered writes;
///  - writers conflict via FIRST-COMMITTER-WINS on the same key.
pub struct MvccStore {
    data: BTreeMap<String, Vec<Version>>,         // versions, oldest -> newest
    committed: BTreeSet<u64>,
    active: BTreeSet<u64>,
    snapshots: BTreeMap<u64, BTreeSet<u64>>,      // txn -> active set at its begin
    pending: BTreeMap<u64, HashMap<String, u64>>, // txn -> buffered writes
    next_txn: u64,
}

impl MvccStore {
    pub fn new() -> Self {
        MvccStore {
            data: BTreeMap::new(),
            committed: BTreeSet::new(),
            active: BTreeSet::new(),
            snapshots: BTreeMap::new(),
            pending: BTreeMap::new(),
            next_txn: 0,
        }
    }

    pub fn begin(&mut self) -> u64 {
        self.next_txn += 1;
        let id = self.next_txn;
        self.snapshots.insert(id, self.active.clone()); // the snapshot
        self.active.insert(id);
        id
    }

    /// Visible to `txn` iff the version's creator committed BEFORE `txn`
    /// began: lower id, not in the snapshot (i.e. not still active at
    /// begin), and committed. Own writes bypass this via `pending`.
    fn visible(&self, v: &Version, txn: u64) -> bool {
        v.begin < txn
            && self.committed.contains(&v.begin)
            && !self.snapshots[&txn].contains(&v.begin)
    }

    pub fn read(&self, txn: u64, key: &str) -> Option<u64> {
        if let Some(v) = self.pending.get(&txn).and_then(|w| w.get(key)) {
            return Some(*v); // read your own writes
        }
        self.data.get(key)?
            .iter()
            .rev()                          // newest first
            .find(|v| self.visible(v, txn))
            .map(|v| v.value)
    }

    pub fn write(&mut self, txn: u64, key: &str, value: u64) {
        self.pending.entry(txn).or_default().insert(key.to_string(), value);
    }

    /// Commit, or abort with a write-write conflict: some *concurrent*
    /// transaction (active at my begin, or begun after me) has already
    /// committed a key I also wrote. First committer wins.
    pub fn commit(&mut self, txn: u64) -> Result<(), ()> {
        let conflict = self.pending.get(&txn).map(|writes| {
            writes.keys().any(|key| {
                self.data.get(key).and_then(|vs| vs.last()).map_or(false, |latest| {
                    let c = latest.begin;
                    c != txn
                        && (self.snapshots[&txn].contains(&c) || c > txn)
                        && self.committed.contains(&c)
                })
            })
        }).unwrap_or(false);
        if conflict {
            self.abort(txn);
            return Err(());
        }
        let writes = self.pending.remove(&txn).unwrap_or_default();
        for (k, v) in writes {
            self.data.entry(k).or_default().push(Version { value: v, begin: txn });
        }
        self.committed.insert(txn);
        self.active.remove(&txn);
        self.snapshots.remove(&txn);
        Ok(())
    }

    pub fn abort(&mut self, txn: u64) {
        self.pending.remove(&txn);   // buffered writes simply vanish
        self.active.remove(&txn);
        self.snapshots.remove(&txn);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_isolation_gives_repeatable_reads() {
        let mut s = MvccStore::new();
        let t0 = s.begin();
        s.write(t0, "balance", 100);
        assert!(s.commit(t0).is_ok());

        let reader = s.begin();          // snapshot taken here
        let writer = s.begin();
        s.write(writer, "balance", 200);
        assert!(s.commit(writer).is_ok()); // commits AFTER reader began

        // The reader's snapshot is frozen: same key, same answer, forever.
        assert_eq!(s.read(reader, "balance"), Some(100));
        s.abort(reader);

        let fresh = s.begin();           // a new snapshot sees the commit
        assert_eq!(s.read(fresh, "balance"), Some(200));
    }

    #[test]
    fn first_committer_wins_on_write_conflict() {
        let mut s = MvccStore::new();
        let t1 = s.begin();
        let t2 = s.begin();
        s.write(t1, "k", 1);
        s.write(t2, "k", 2);
        assert!(s.commit(t1).is_ok());   // first committer...
        assert!(s.commit(t2).is_err());  // ...wins; t2 aborts
        let t3 = s.begin();
        assert_eq!(s.read(t3, "k"), Some(1)); // no lost update, no torn value
    }
}
```

=== Two-Phase Locking with Deadlock Detection

```rust
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode { Shared, Exclusive }

#[derive(Debug, Default)]
struct LockState {
    holders: BTreeMap<u64, Mode>, // txn -> mode held on this key
}

/// A non-blocking strict-2PL lock table: acquisition succeeds or reports
/// the conflict (the caller waits and retries); every conflict is also an
/// edge in the wait-for graph, where cycles are deadlocks. Real engines
/// park waiters on queues; the graph math is identical.
pub struct LockManager {
    locks: BTreeMap<String, LockState>,
    waits: BTreeMap<u64, BTreeSet<u64>>, // waiter -> holders it waits on
}

impl LockManager {
    pub fn new() -> Self {
        LockManager { locks: BTreeMap::new(), waits: BTreeMap::new() }
    }

    /// Shared locks coexist; exclusive locks exclude all but the holder's
    /// own. (Lock UPGRADE is just re-acquisition at a stronger mode.)
    fn compatible(state: &LockState, txn: u64, mode: Mode) -> bool {
        state.holders.iter().all(|(&h, &m)| {
            h == txn || (m == Mode::Shared && mode == Mode::Shared)
        })
    }

    pub fn acquire(&mut self, txn: u64, key: &str, mode: Mode) -> Result<(), ()> {
        let state = self.locks.entry(key.to_string()).or_default();
        if Self::compatible(state, txn, mode) {
            state.holders.insert(txn, mode);
            Ok(())
        } else {
            for &h in state.holders.keys() {
                if h != txn { self.waits.entry(txn).or_default().insert(h); }
            }
            Err(())
        }
    }

    /// Commit/abort releases everything (strict 2PL) and forgets the
    /// transaction's waits.
    pub fn release_all(&mut self, txn: u64) {
        for state in self.locks.values_mut() {
            state.holders.remove(&txn);
        }
        self.waits.remove(&txn);
        for edges in self.waits.values_mut() {
            edges.remove(&txn);
        }
    }

    /// Deadlock = a cycle in the wait-for graph. Iteratively remove txns
    /// nobody waits on (they can finish, so they can't be stuck); what
    /// remains is deadlocked or doomed behind the deadlocked.
    pub fn deadlock(&self) -> Option<Vec<u64>> {
        let mut g: BTreeMap<u64, BTreeSet<u64>> = BTreeMap::new();
        for (w, holders) in &self.waits {
            for h in holders {
                g.entry(*w).or_default().insert(*h);
                g.entry(*h).or_default();
            }
        }
        loop {
            let mut indeg: BTreeMap<u64, usize> = g.keys().map(|&k| (k, 0)).collect();
            for outs in g.values() {
                for o in outs {
                    if let Some(d) = indeg.get_mut(o) { *d += 1; }
                }
            }
            let free: Vec<u64> = indeg.iter()
                .filter(|(_, &d)| d == 0)
                .map(|(&n, _)| n)
                .collect();
            if free.is_empty() { break; }
            for f in free { g.remove(&f); }
        }
        if g.is_empty() { None } else { Some(g.keys().copied().collect()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_locks_coexist_and_exclusive_waits() {
        let mut lm = LockManager::new();
        assert!(lm.acquire(1, "row", Mode::Shared).is_ok());
        assert!(lm.acquire(2, "row", Mode::Shared).is_ok());
        assert!(lm.acquire(3, "row", Mode::Exclusive).is_err()); // must wait
        assert_eq!(lm.deadlock(), None); // a wait chain is not a cycle
    }

    #[test]
    fn deadlock_is_detected_and_broken_by_victim_abort() {
        let mut lm = LockManager::new();
        assert!(lm.acquire(1, "a", Mode::Exclusive).is_ok());
        assert!(lm.acquire(2, "b", Mode::Exclusive).is_ok());
        assert!(lm.acquire(1, "b", Mode::Exclusive).is_err()); // 1 waits on 2
        assert!(lm.acquire(2, "a", Mode::Exclusive).is_err()); // 2 waits on 1
        let stuck = lm.deadlock().unwrap();
        assert!(stuck.contains(&1) && stuck.contains(&2));

        lm.release_all(2);                 // victim abort
        assert_eq!(lm.deadlock(), None);
        assert!(lm.acquire(1, "b", Mode::Exclusive).is_ok()); // survivor proceeds
    }
}
```

=== The WAL and Recovery

```rust
use std::collections::{BTreeMap, BTreeSet};

/// A write-ahead log record. The discipline is the contract: a record
/// reaches stable storage BEFORE the data change it describes, and
/// COMMIT returns only after this log is flushed.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Record {
    Begin(u64),
    Set(u64, String, u64), // txn, key, value — the redo image
    Commit(u64),
    Abort(u64),
}

pub struct Wal {
    records: Vec<Record>, // production: an append-only file, fsync'd per group commit
}

impl Wal {
    pub fn new() -> Self { Wal { records: vec![] } }

    pub fn append(&mut self, r: Record) { self.records.push(r); }

    /// Replay after a crash. Two passes over one stream: find every
    /// committed transaction, then redo exactly their writes. Committed
    /// work survives (durability); uncommitted work vanishes (atomicity).
    /// ARIES adds page-level LSNs and an undo pass; this is the moral core.
    pub fn recover(&self) -> BTreeMap<String, u64> {
        let mut committed = BTreeSet::new();
        for r in &self.records {
            if let Record::Commit(t) = r { committed.insert(*t); }
        }
        let mut state = BTreeMap::new();
        for r in &self.records {
            if let Record::Set(t, k, v) = r {
                if committed.contains(t) {
                    state.insert(k.clone(), *v);
                }
            }
        }
        state
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn committed_work_survives_the_crash() {
        let mut wal = Wal::new();
        wal.append(Record::Begin(1));
        wal.append(Record::Set(1, "alice".into(), 100));
        wal.append(Record::Set(1, "bob".into(), 50));
        wal.append(Record::Commit(1));
        let state = wal.recover();
        assert_eq!(state.get("alice"), Some(&100));
        assert_eq!(state.get("bob"), Some(&50));
    }

    #[test]
    fn uncommitted_work_vanishes() {
        let mut wal = Wal::new();
        wal.append(Record::Begin(1));
        wal.append(Record::Set(1, "alice".into(), 100));
        wal.append(Record::Commit(1));
        wal.append(Record::Begin(2));
        wal.append(Record::Set(2, "alice".into(), 999)); // crash: no Commit(2)
        let state = wal.recover();
        assert_eq!(state.get("alice"), Some(&100)); // txn 2 never happened
    }

    #[test]
    fn aborted_work_is_skipped_even_though_logged() {
        let mut wal = Wal::new();
        wal.append(Record::Begin(1));
        wal.append(Record::Set(1, "k".into(), 1));
        wal.append(Record::Abort(1));
        assert_eq!(wal.recover().get("k"), None);
    }
}
```

=== Write Skew, Demonstrated and Cured

Snapshot isolation's blind spot, reproduced against the MVCC store above
(same crate). The setup is the classic on-call rota: the invariant is "at
least one doctor is on call"; each doctor's transaction reads *both* rows
and writes *only their own* — no write-write conflict exists for
first-committer-wins to catch.

```rust
// uses MvccStore from the MVCC listing (same crate)

#[test]
fn write_skew_survives_snapshot_isolation() {
    let mut s = MvccStore::new();
    let t0 = s.begin();
    s.write(t0, "alice", 1); // 1 = on call
    s.write(t0, "bob", 1);
    s.commit(t0).unwrap();

    let ta = s.begin();
    let tb = s.begin();
    // Both doctors check the rota: two on call, safe to step away.
    assert_eq!(s.read(ta, "alice"), Some(1));
    assert_eq!(s.read(ta, "bob"), Some(1));
    assert_eq!(s.read(tb, "alice"), Some(1));
    assert_eq!(s.read(tb, "bob"), Some(1));
    // Each takes THEMSELVES off call — different keys, no conflict.
    s.write(ta, "alice", 0);
    s.write(tb, "bob", 0);
    assert!(s.commit(ta).is_ok());
    assert!(s.commit(tb).is_ok()); // SI allows it...

    let check = s.begin();
    assert_eq!(s.read(check, "alice"), Some(0));
    assert_eq!(s.read(check, "bob"), Some(0)); // ...and nobody is on call.
}

#[test]
fn materializing_the_read_catches_the_skew() {
    // The `SELECT ... FOR UPDATE` cure: each transaction also WRITES the
    // row it depends on, turning the read-write dependency into a
    // write-write conflict that first-committer-wins can see.
    let mut s = MvccStore::new();
    let t0 = s.begin();
    s.write(t0, "alice", 1);
    s.write(t0, "bob", 1);
    s.commit(t0).unwrap();

    let ta = s.begin();
    let tb = s.begin();
    s.write(ta, "alice", 0);
    s.write(ta, "bob", 1);   // "I depend on bob being on call"
    s.write(tb, "alice", 1); // "I depend on alice"
    s.write(tb, "bob", 0);
    assert!(s.commit(ta).is_ok());
    assert!(s.commit(tb).is_err()); // conflict on both keys -> abort

    let check = s.begin();
    assert_eq!(s.read(check, "bob"), Some(1)); // invariant saved
}
```

#pitfall([Testing the happy path only])[
  Notice what the first test proves: *the invariant died with every
  operation returning success.* No error, no conflict, no log line — SI
  did exactly what it promises, and the rota still emptied. Correctness
  bugs at the isolation layer are silent; the only defenses are choosing
  the level with the anomaly table in hand, materializing reads that
  carry invariants, and writing tests (like these) that execute the
  dangerous interleaving on purpose. If your test suite only ever runs
  one transaction at a time, it has tested none of this.
]

== Scaling the Design

Single-node transaction throughput scales up (bigger buffer pools, faster
flushes, more parallel group-commit batches) until the write wall arrives;
then the levers are structural.

*Read scale is easy, write scale is earned.* Replicas stream the WAL and
serve snapshot reads — Chapter 9's machinery carrying this chapter's log —
but every write still funnels through one log tail. Sharding writes by
key range (Chapter 5's approach) splits the log per shard-group; the
price is that cross-shard transactions now need 2PC or must be designed
away by *co-locating* what transacts together (account pairs on the same
shard — the transfer example is deliberately co-locatable).

*Contention, not capacity, is usually the ceiling.* A hot row — the
merchant's settlement account in the morning, Chapter 6's top leaderboard
entry — serializes every transaction that touches it, whatever the
isolation level. The playbook: batch counter increments through
intermediate rows and sum at read; shorten transactions so locks are held
for microseconds; move truly hot aggregates out of the transactional path
entirely (Chapter 6's leaderboard does not need serializability per
score).

*Version GC is a throughput feature.* Vacuum that falls behind turns
every table into a history of itself: indexes bloat (Chapter 8's fill
factor), snapshots walk longer chains, and the buffer pool fills with
garbage. Autovacuum tuning is unglamorous and load-bearing.

== Failure Modes & Degradation

#tbl(
  (0.95fr, 1.4fr, 1.8fr),
  header: (hcell[Failure], hcell[Symptom], hcell[Handling]),
  body: (
    [Crash mid-transaction], [Partial effects possibly on disk], [Recovery: redo committed, discard uncommitted — the WAL decides, pages never lie (§11.7)],
    [Crash after flush, before ack], [Client unsure whether commit landed], [Client retries with its idempotency key (Chapter 10's rule); the transaction either is or isn't in the log — never half],
    [Deadlock], [Two txns frozen], [Wait-for cycle detected; victim aborted with a retryable error; app retries],
    [Long-lived snapshot], [Version bloat, vacuum blocked], [Metric + alert on snapshot age; statement timeouts; kill the session, not the server],
    [Lock convoy on a hot row], [Throughput collapses to serial], [Shorten txns; batch via intermediate rows; move the aggregate out of the transactional path],
    [Log disk full], [All commits block — total write outage], [The WAL is the single point of *write* failure: alert early, checkpoint diligently, never let it fill],
    [Replica lag], [Stale reads on replicas], [Monotonic-read tokens (Ch. 9's contexts) or route reads-after-writes to the leader],
  ),
)

#pitfall([Retrying without idempotency])[
  The commit-ack ambiguity row deserves emphasis because it bites weekly
  in production: the log flushed, the network dropped the ack, and the
  client genuinely cannot know whether its transfer exists. Retrying
  blindly risks double-charging; not retrying risks losing a payment.
  The only correct shape is Chapter 10's: the client owns an idempotency
  key, the retry is safe, and the ambiguity is absorbed by the dedup
  table. Transactions make *the database* correct; end-to-end correctness
  is a protocol between client and server.
]

== Trade-offs & Alternatives

#tbl(
  (1.05fr, 1.15fr, 1.15fr, 1.7fr),
  header: (hcell[Choice], hcell[We picked], hcell[Alternative], hcell[When the alternative wins]),
  body: (
    [Concurrency control], [MVCC (snapshot isolation)], [Strict 2PL / OCC], [2PL: strong consistency semantics with simpler reasoning; OCC: conflict-sparse, read-mostly workloads where aborts stay rare],
    [Default isolation], [READ COMMITTED or SI], [SERIALIZABLE everywhere], [Hot, invariant-carrying paths justify SSI's abort cost; most web workloads never see an anomaly at RC],
    [Durability], [Local flush + replica ack], [Local flush only / fully synchronous multi-region], [Latency budget vs. RPO=0 across regions; Chapter 9 prices the far end of this dial],
    [Distributed atomicity], [Avoid; co-locate + sagas], [2PC across services], [Single-cluster, short-lived, coordinator-protected transactions — 2PC's safe habitat],
    [Write path], [Steal/no-force + WAL], [Force-at-commit (no redo)], [Tiny embedded engines where simplicity beats commit latency],
  ),
)

#insight([Isolation is a product decision, not a database default])[
  Every isolation level is a price-performance point on the correctness
  curve, and the right answer depends on what an anomaly *costs the
  business*. A social feed tolerates phantoms; a ledger does not tolerate
  anything. The senior move is per-workload selection: SI for the OLTP
  core, SERIALIZABLE (or materialized reads) exactly where invariants
  carry money, READ COMMITTED where speed matters and anomalies don't —
  and a written note, in the design doc, saying which anomalies each
  service has agreed to live with.
]

== Observability & SLOs

#tbl(
  (1.0fr, 1.5fr, 1.15fr),
  header: (hcell[Signal], hcell[What it measures], hcell[Alert when]),
  body: (
    [Commit latency], [Time from COMMIT to ack (group-commit batching)], [p99 \> 2 ms: flush path slow or batches starving],
    [WAL flush rate / backlog], [Log throughput vs. generation], [Backlog growing: disk saturated — the write ceiling],
    [Lock waits], [Time blocked per txn; wait-for edge count], [P95 wait climbing: contention shift or a new hot row],
    [Deadlocks / aborts], [Victim aborts, SI conflicts per minute], [Spike = a deploy changed access order; SSI abort storms on hot paths],
    [Snapshot age], [Oldest active snapshot], [\> minutes: vacuum is pinned, bloat incoming — page before the disk fills],
    [Recovery drill], [Time-to-open after kill -9], [Practiced, not theoretical: measured in game days],
  ),
)

*SLOs.* Commit latency p99 ≤ 2 ms (group commit); recovery ≤ 60 s to
accepting writes; zero committed-data loss at single-node fault (RPO = 0
with replica ack); deadlock resolution ≤ 100 ms from formation; snapshot
age ≤ 5 min at p99. Every one of these is a mechanism from this chapter
plus a number.

== Interview Wrap-Up

*Likely follow-ups, with the shape of a strong answer.*

- _"Which ACID letter is not the database's job?"_ C. The database
  enforces constraints and provides A, I, D; the invariant "money is
  conserved" is authored by the transaction writer. Candidates who say
  this unprompted stand out immediately.
- _"Default isolation for a new service?"_ READ COMMITTED or SI, chosen
  by naming the anomalies you are accepting — the table in Section 11.8
  is the answer, not a footnote.
- _"PostgreSQL vs MySQL REPEATABLE READ?"_ SI vs next-key-locked 2PL:
  same name, different anomalies excluded. Know one engine's mechanism
  deeply rather than both engines' marketing.
- _"Why is 2PC dying?"_ The blocking window: a coordinator crash holds
  participants' locks hostage until recovery. Inside one cluster with a
  protected coordinator it is fine; across services it is a reliability
  anti-pattern — sagas won.
- _"Speed up commits?"_ Group commit; then steal/no-force (already
  assumed); then async commit with an explicit durability downgrade,
  said out loud.
- _"How does this square with Chapter 9?"_ ACID lives inside the
  coordination boundary; CRDTs outside it; choose per datum. The
  interviewer's favorite systems answer in 2026 is this sentence.

*Checklist for the whiteboard.* (1) Define each letter as a contract with
its mechanism: log (A, D), locks/versions (I), constraints (C). (2) Draw
the commit path through the WAL and say "commit = flush". (3) Recite
three anomalies and the level that kills each. (4) Know SI's blind spot
and both cures. (5) Sketch deadlock detection as a graph problem. (6) For
distributed, refuse 2PC across services and offer sagas. (7) Mention one
operational war story: snapshot age, log-full, or lock convoy.

== Summary & Further Reading

A transaction layer is two disciplines answering two enemies. Against
*crashes*, the write-ahead log: describe before you write, commit means
flushed, recovery is replay — redo the committed, discard the rest, and
let steal/no-force buffer management keep commits fast while checkpoints
keep recovery short. Against *concurrency*, a legal-interleaving
discipline: strict two-phase locking with deadlock detection, optimistic
validation when conflicts are rare, or MVCC version chains that let
readers and writers pass without blocking — each paying its tax in waits,
aborts, or space. Isolation is sold in levels defined by the anomalies
they forbid, and the map has exactly one trap door left open by the
industry's favorite level: snapshot isolation admits write skew, cured by
materializing the reads or by SSI's dangerous-structure detection. Past
the single node, 2PC extends atomicity at the price of blocking, sagas
replace it with compensation, and Chapter 9's boundary reappears on cue:
ACID is what coordination buys; the art is knowing which data can afford
it. Chapter 8 supplied the pages; this chapter supplied the promises.

*Further reading.*

- The source video: _"Intro to ACID Database Transactions — Systems
  Design Interview: 0 to 1 with Google Software Engineer"_ (Jordan has no
  life): `https://www.youtube.com/watch?v=oGmxzUBCYtY`
- Gray & Reuter — _Transaction Processing: Concepts and Techniques_ —
  the field's foundational text; the lock manager chapter alone justifies
  the shelf space.
- Mohan et al. — _"ARIES: A Transaction Recovery Method"_ (1992) — the
  recovery protocol every serious engine implements.
- Adya — _"Weak Consistency: A Generalized Theory and Optimistic
  Implementations for Distributed Transactions"_ (1999) — the anomaly
  taxonomy done rigorously.
- Berenson et al. — _"A Critique of ANSI SQL Isolation Levels"_ (1995) —
  why the standard's names do not mean what engines ship.
- Cahill et al. — _"Serializable Snapshot Isolation"_ (2008) — the
  PostgreSQL 9.1 implementation paper; serializable without the lockout.
- PostgreSQL and MySQL/InnoDB documentation on their isolation
  implementations — the same names, two different machines.

== Chapter Glossary

#tbl(
  (auto, 1fr),
  header: (hcell[Term], hcell[Meaning]),
  body: (
    [ACID], [Atomicity, Consistency, Isolation, Durability — the four contracts of a transaction],
    [ARIES], [The industrial recovery protocol: LSNs everywhere, repeat history, then undo],
    [Atomicity], [All-or-nothing execution; enforced by the log at recovery time],
    [Checkpoint], [Periodic dirty-page flush + log marker capping the redo window],
    [Commit record], [The log entry whose flush makes a transaction real],
    [Consistency (C)], [Invariants preserved; enforced by constraints, authored by the application],
    [Deadlock], [A cycle in the wait-for graph; detected, then broken by victim abort],
    [Dirty read], [Reading another transaction's uncommitted write],
    [Durability], [Committed survives crashes; a property of the log, not the pages],
    [First-committer-wins], [SI write-conflict rule: second committer on a contested row aborts],
    [Group commit], [One flush confirming a batch of commits; the throughput unlock],
    [Isolation], [Concurrency invisibility; sold in levels defined by forbidden anomalies],
    [Lost update], [Two read-modify-writes clobbering each other; increments vanish],
    [MVCC], [Multiversion concurrency control: writers append versions, readers walk snapshots],
    [Non-repeatable read], [Re-reading a row yields a new committed value mid-transaction],
    [OCC], [Optimistic control: run unlocked, validate at commit, abort on conflict],
    [Phantom], [A predicate query re-run sees newly committed matching rows],
    [Read skew], [A transaction sees pre-transfer A and post-transfer B — an impossible mix],
    [Redo / undo], [Replaying committed changes / erasing uncommitted ones, both from the log],
    [Saga], [Chained local transactions with compensating actions; atomicity traded for availability],
    [Savepoint], [An in-transaction marker allowing partial rollback],
    [Snapshot isolation (SI)], [Read a begin-time snapshot; first-committer-wins on writes; admits write skew],
    [SSI], [Serializable SI: detect dangerous read-write structures, abort a participant],
    [Steal / no-force], [Pages flushable while uncommitted / not forced at commit — the WAL's license],
    [Strict 2PL], [Two-phase locking with exclusive locks held to commit; no dirty reads, no cascading aborts],
    [Two-phase commit (2PC)], [Prepare + commit across nodes; atomic, blocking, coordinator-fragile],
    [Vacuum], [MVCC garbage collection of versions no live snapshot can see],
    [WAL], [Write-ahead log: the append-only stream every change is described in first],
    [Wait-for graph], [Edges waiter→holder; cycles are deadlocks],
    [Write skew], [Two txns read a shared set, write different rows, kill the invariant — SI's blind spot],
  ),
)

#v(0.8em)
#align(center)[
  #text(size: 8.5pt, fill: slate)[
    — End of Chapter 11 · Next: Chapter 12 —
  ]
]
