// ============================================================================
//  CHAPTER 10 — Designing a Distributed Job Scheduler
//  Source: "20: Distributed Job Scheduler | Systems Design Interview
//  Questions With Ex-Google SWE" (channel: Jordan has no life)
//  Link: https://www.youtube.com/watch?v=pzDwYHRzEnk
// ============================================================================

#import "../template.typ": *

= Designing a Distributed Job Scheduler

#notebox([Problem source])[
  This chapter solves the problem posed in the talk _"20: Distributed Job
  Scheduler"_ from the series _Systems Design Interview Questions with
  Ex-Google SWE_ (channel: _Jordan has no life_). Unlike Chapters 8 and 9
  (fundamentals deep dives), this is a full *product design* in the shape
  of Chapters 1–7: cron-as-a-service, the machinery behind Airflow,
  Kubernetes CronJobs, AWS EventBridge Scheduler, and every "remind me in
  20 minutes" button on Earth. It quietly reuses almost every earlier
  chapter: the due-job index is Chapter 8's B+ tree, the dispatch queue is
  Chapter 4's append-only log, per-tenant fairness is Chapter 3's limiter,
  and shard ownership borrows Chapter 9's vocabulary of leases and clocks.
  All terms are defined before use; all reference code is Rust with
  deterministic tests.
]

== The Problem Statement

The interviewer draws a clock and says:

_"Design a distributed job scheduler. Users register jobs — one-shot
('fire at 3:00 AM'), recurring ('every weekday at 07:30'), or whole
workflows of dependent jobs — and the system fires them reliably, at the
right time, at scale: tens of millions of registered jobs, tens of
thousands of firings per second at the peak. Jobs must not be lost, must
not silently double-execute, and the scheduler itself must survive machine
and region failures."_

Every large company builds this system eventually, because the naive
versions are all traps: a single machine running `cron` is a single point
of failure; a `sleep()` in application code dies with the process; a
database table polled by every worker is a lock convoy. The interview
tests whether you can separate the system's three concerns — *knowing when
jobs are due*, *deciding who fires them*, and *executing them without
duplicates* — and scale each independently.

#defterm([Job / run / trigger])[
  A _job_ is the registered specification: what to execute (a queue
  message, an HTTP call, a worker class plus payload), *when* (its
  _trigger_: a fire timestamp or a schedule), and *how to behave on
  failure* (retry policy, dead-letter). A _run_ (or execution) is one
  actual firing of a job — jobs are few and durable, runs are many and
  ephemeral. Confusing the two tables in the data model is the first
  design error this chapter avoids.
]

#defterm([Schedule / cron expression])[
  A compact description of recurring fire times. The classic _cron
  expression_ has five fields — minute, hour, day-of-month, month,
  day-of-week — so `30 7 * * 1-5` reads "07:30 on weekdays". Two traps
  lurk here and a senior candidate names both unprompted: *time zones*
  (07:30 in whose morning?) and *DST* (on spring-forward day, 02:30 never
  happens; on fall-back day, it happens twice). The store keeps UTC plus
  the tenant's zone; the misfire policy (Section 10.9) decides what "the
  02:30 that never came" means.
]

#defterm([Misfire and catch-up policy])[
  A _misfire_ is a scheduled fire time that passed without firing —
  because the scheduler was down, the shard was being re-leased, or DST
  erased the minute. The _catch-up policy_ is a per-job choice: *fire
  once now* (coalesce all misses into one), *replay every miss*, or *skip
  to the next scheduled time*. A billing job wants replay-every-miss; a
  cache warmer wants skip; an hourly report wants coalesce. There is no
  correct default — only a default you chose on purpose.
]

== Scope & Clarifying Questions

#tbl(
  (auto, 1fr),
  header: (hcell[Candidate asks], hcell[Interviewer answers]),
  body: (
    [Job kinds?], [One-shot delayed jobs, recurring cron jobs, and DAG workflows of dependent jobs],
    [Execution model?], [Scheduler fires by enqueuing to a dispatch queue; worker pools pull and execute. We design both sides],
    [Scale?], [10⁷ registered jobs, ~3 × 10³ firings/s average, ~30× bursts at top-of-hour],
    [Fire latency?], [Seconds matter, microseconds do not: p99 within ~1 s of the scheduled time],
    [Delivery semantics?], [Push for effectively-once execution; expect to explain why raw exactly-once is impossible],
    [Multi-tenant?], [Yes — one tenant's burst must not starve others (Chapter 3 territory)],
    [Durability?], [Registered jobs survive region loss; run history retained 90 days],
  ),
)

#notebox([Agreed scope])[
  + Design the *control plane*: job registration (one-shot, cron, DAG),
    update, cancel, inspect — backed by a durable job store.
  + Design the *trigger side*: how due jobs are found across 10⁷ timers
    without a thread or a full-table scan per timer.
  + Design the *firing side*: sharded scheduler replicas with leases and
    fencing, a durable dispatch queue, and workers that execute
    *effectively-once* via idempotency keys.
  + Design *failure behavior* as a first-class feature: retries with
    backoff and jitter, dead-letter queues, misfire policies.
  + Quantify scale: registered jobs, fire rate, burst shape, worker
    fleet size, run-history storage.
  + Out of scope: the workers' actual business logic; sub-second
    precision timers (that's a kernel problem, not an architecture).
]

== Functional Requirements

+ *Register and manage jobs.* Create, update, cancel, and inspect
  one-shot jobs (`fire_at = T`), recurring jobs (`cron` expression +
  time zone), each with payload, target, and retry policy.
+ *Fire on time.* Every due job produces a fire command within the
  latency SLO of its scheduled time, in all but catastrophe scenarios.
+ *Effectively-once execution.* Clients that follow the idempotency
  protocol see each run execute at most once, even though the transport
  underneath is at-least-once.
+ *Bounded retries.* Failed runs retry with exponential backoff and
  jitter up to a per-job cap, then land in a dead-letter queue with the
  full error context.
+ *Workflows.* Users submit DAGs of dependent jobs; the system runs each
  job only after its dependencies succeed, parallelizes independent
  branches, and applies a per-workflow failure policy (fail-fast vs.
  complete-what-you-can).
+ *Misfire handling.* After downtime or DST gaps, each job follows its
  declared catch-up policy: coalesce, replay, or skip.
+ *Tenant fairness.* Per-tenant fire-rate quotas; bursts are smoothed or
  queued, never allowed to starve other tenants.

== Non-Functional Requirements

- *Durability of the registry.* A registered job must survive the loss of
  any machine and any region: the job store is replicated (Chapter 8's
  machinery underneath), and a fire command, once accepted, is durably
  queued before it is acknowledged.
- *Availability of firing.* The scheduler must keep firing with any one
  replica — or one region — down: shard leases fail over in ≤ 15 s.
- *No lost runs.* Between scheduler crash, queue outage, and worker
  death, a due job may be *delayed* or *duplicated*, but never silently
  dropped. Duplicates are absorbed by the idempotency layer.
- *Bounded staleness.* p99 fire latency ≤ 1 s past due for one-shot jobs;
  ≤ 5 s for cron jobs (their consumers are batch-shaped).
- *Elastic scale-out.* Adding scheduler shards or worker pools raises
  capacity linearly; no component is a hard singleton (leases, not
  process identity, own the shards).

#defterm([At-least-once / at-most-once / exactly-once])[
  The three delivery guarantees a system can offer. _At-most-once_: fire
  and forget — no retries, so failures lose messages. _At-least-once_:
  retry until acknowledged — failures duplicate messages. _Exactly-once_
  end-to-end delivery is *provably impossible* over an unreliable network
  (the receiver cannot distinguish "sender crashed before sending" from
  "sender crashed after sending but before the ack arrived" — the
  classical Two Generals impossibility). What *is* achievable — and what
  this design delivers — is _effectively-once_: at-least-once transport
  plus *idempotent* processing, so duplicates exist on the wire but are
  invisible to the application.
]

#defterm([Idempotency / idempotency key])[
  An operation is _idempotent_ if performing it twice has the same effect
  as performing it once. A scheduler achieves this by stamping every fire
  command with a unique _idempotency key_ — `(job_id, scheduled_time)` is
  the natural choice — and having the executor check a _dedup store_
  before its first side effect: first arrival claims the key and runs;
  any duplicate sees the claimed key and exits as a no-op. Chapter 5's
  vote endpoint used the same trick; here it is the backbone of the whole
  system.
]

== Back-of-the-Envelope: Timers, Bursts, and Workers

Three numbers size the design: how many timers exist, how unevenly they
fire, and how much execution capacity the fire rate implies.

*Assumptions.* 10⁷ registered jobs; recurring jobs fire hourly on average;
job spec ≈ 1 KB; average run duration 30 s; 90-day run history at 1 KB per
run record.

#tbl(
  (auto, 1fr),
  header: (hcell[Quantity], hcell[Estimate (with assumptions)]),
  body: (
    [Registered jobs], [10⁷ × 1 KB ≈ *10 GB* of job specs — comfortably one replicated store, Chapter 8 style],
    [Average fire rate], [10⁷ jobs × 1 fire/hour ≈ *2.8 × 10³ fires/s*],
    [Top-of-hour burst], [~50% of cron jobs pinned to minute 0 → 5 × 10⁶ fires in one minute ≈ *8 × 10⁴ fires/s — a 30× burst*. Splaying (§10.6) is mandatory],
    [Due-job discovery], [64 shards × one indexed range scan per second — the B+ tree leaf walk of Chapter 8; trivial against 10⁷ rows],
    [Concurrent executions], [2.8 × 10³ fires/s × 30 s avg ≈ *8.4 × 10⁴ in flight* → ~1 000 workers × 100 slots each],
    [Dispatch traffic], [≤ 8.3 × 10⁴ msg/s × 1 KB ≈ *83 MB/s peak* — well inside Chapter 4's log throughput],
    [Run history], [2.8 × 10³ runs/s × 86 400 s × 90 days × 1 KB ≈ *22 TB* → retention windows and rollups, Chapter 4 style],
    [Lease failover], [TTL 10 s + probe 5 s → *≤ 15 s* worst-case pause on a shard when its scheduler dies],
  ),
)

#insight([The burst, not the average, designs the system])[
  The average fire rate needs one modest scheduler; the top-of-hour spike
  — half the world's cron jobs pinned to minute 0 — needs thirty. A
  scheduler designed for the average melts at 00:00 UTC daily; one
  designed for the peak idles 97% of the day. The resolution is to
  *reshape the demand*: splay recurring jobs across their period
  (`0 * * * *` becomes "minute `hash(job_id) mod 60`, every hour"), which
  flattens a 30× burst to ~1.5× — and then size for that. Every scheduler
  interview should contain the sentence "and then we desynchronize the
  timers"; it is the same thundering-herd lesson as Chapter 3's jittered
  retries and Chapter 8's rightmost hotspot, wearing a clock face.
]

== The Core Challenge: "Exactly Once" Is a Lie We Tell Well

Ask ten engineers what a job scheduler must guarantee and nine say
"exactly-once execution". The tenth — the one who has run one — says
"effectively-once, and here is why." The reason is not engineering
laziness; it is impossibility. Between "scheduler enqueues fire command"
and "worker performs the side effect", a network and two processes can
fail in combinations no protocol can distinguish: the worker that executed
the job and *then* crashed before acking is indistinguishable from the
worker that crashed before executing. The scheduler must retry, so
duplicates on the wire are unavoidable. The only question is whether
anyone can see them.

So the challenge splits in two, and the design addresses each half with a
different weapon:

+ *The trigger side is a data-structures problem.* Ten million timers,
  thirty thousand firing per second at the peak, each fire time
  computable but volatile (jobs are cancelled and rescheduled
  constantly). Neither a thread per timer nor a full-table poll survives
  contact with these numbers; Section 10.7 picks the structure that does.
+ *The firing side is a distributed-systems problem.* Several scheduler
  replicas must divide the work without double-firing, workers must
  absorb duplicates they cannot prevent, and a crashed component's
  in-flight work must be reclaimed — all without a global lock. Section
  10.8 assembles leases, fencing tokens, and idempotency keys into
  exactly that.

#insight([Effectively-once = at-least-once + idempotency + a dedup store])[
  The industry's entire answer, in one line: *deliver at least once,
  process idempotently, remember what you processed.* The scheduler
  guarantees every fire command lands on the queue at least once
  (durable enqueue before ack); the worker, before any side effect,
  claims the run's idempotency key in a dedup store (`INSERT ... IF NOT
  EXISTS` — the same compare-and-set discipline as Chapter 5's votes);
  the key's TTL outlives any plausible duplicate window. Duplicates still
  happen on the wire — they just never happen twice to the application.
  This is the exact pattern behind Kafka's idempotent producers,
  Stripe's idempotency-keyed API, and every payment retrier you have ever
  trusted with your card.
]

== Deep Dive: The Trigger Side — Finding What's Due

The trigger side answers one question, 64 times a second per shard:
*which jobs are due right now?* Three designs, in increasing
sophistication — name all three in the interview, then defend your pick.

*Design A: the indexed scan.* Store every job with a materialized
`next_fire_at` column and a B+ tree index on `(shard, next_fire_at)` —
Chapter 8's structure, doing exactly the job it was designed for. A
scheduler tick is one range scan (`next_fire_at ≤ now` within its shard
slice) plus a linked-leaf walk; due jobs stream out in fire-time order at
index speed. After firing (or enqueueing), the job's `next_fire_at` is
recomputed from its cron expression and the row updated — the index
maintains itself. This is the design this chapter ships: durable by
construction (the timers *are* the database), crash-transparent (a dead
scheduler's successor rescans and finds everything), and simple enough to
reason about at 2 AM.

*Design B: the in-memory min-heap.* Keep a priority queue of
`(fire_at, job)` keyed by soonest-first (the Rust listing in Section
10.13). O(log n) per schedule or cancel-via-lazy-tombstone, O(1) peek at
the next due job, zero index maintenance. The catch: the heap is
*volatile* — it must be rebuilt from the store on every failover, and at
10⁷ timers that is a 10–30 s cold start during which the shard is blind.
Production systems use the heap as a *hot cache in front of Design A*:
the tick loop keeps the next few seconds of timers in memory so the scan
runs once per window, not once per timer.

*Design C: the hashed timing wheel.* The classic kernel answer (Kafka,
Netty, and the Linux kernel itself): an array of buckets representing
time slots — slot `i` holds every timer due at `now + i·tick` mod the
wheel's circumference — so insert and expire are O(1) pointer pushes. A
*hierarchical* wheel (a seconds-wheel feeding a minutes-wheel feeding an
hours-wheel, like a clock's gears) covers far-future timers in O(wheels)
per operation. Beautiful, optimal, and entirely in-memory: the same
durability problem as the heap, plus resize pain, plus a poor fit for
cancel-heavy workloads. Worth describing to show range; wrong as the
system of record.

#defterm([Timing wheel (hashed / hierarchical)])[
  A ring buffer of buckets indexed by time slot: a timer due in _k_ ticks
  lands in bucket `(current + k) mod circumference`; each tick, the
  current bucket's timers fire or cascade. The _hierarchical_ variant
  stacks wheels of coarser granularity (seconds, minutes, hours) so a
  timer due next year parks cheaply in the year-wheel until it degrades
  down through the gears. O(1) amortized insert and expiry — the price is
  volatility and the complexity of cascading on the wheel boundary.
]

#pitfall([The poll-everything anti-pattern])[
  The first draft everyone sketches — `SELECT * FROM jobs` every second,
  filter in application code — turns 10⁷ rows into 10⁷ row-reads per
  second per scheduler replica: the database melts, and the interview
  with it. The index on `next_fire_at` is not an optimization; it *is*
  the trigger design. If you take one sentence from this section: the due
  set is a range query, and range queries are a solved problem (Chapter
  8) — spend your design budget on the firing side instead.
]

== Deep Dive: The Firing Side — Leases, Fencing, Idempotency

The firing side answers a harder question: *who* may fire shard 37's due
jobs — and how do we stop yesterday's answer from firing them again?

*Shard ownership by lease.* The 10⁷ jobs are hash-partitioned by `job_id`
into (say) 64 shards. A scheduler replica acquires a shard by taking its
*lease* from a small highly-available coordination store; it renews the
lease every few seconds and loses it silently if it stalls (GC pause,
network hiccup, death). A standby replica takes over an expired lease —
failover in ≤ 15 s, per the SLO.

#defterm([Lease])[
  A time-bounded grant of exclusive ownership: "replica R owns shard S
  until time T, and may renew." Leases convert *membership* ("who owns
  this shard?") from a consensus-per-operation cost into a
  heartbeat-per-few-seconds cost. Their danger is the gap between "my
  lease silently expired" and "I find out": during that gap the old owner
  still believes itself owner, and two owners double-fire.
]

#defterm([Fencing token])[
  A monotonically increasing number issued by the lease store on every
  acquisition, which the holder must present with *every* action it
  performs on behalf of the lease — and which downstream systems check:
  "accept this dispatch only if its token exceeds every token you have
  seen for this shard." Fencing closes the lease's blind gap: the stale
  owner's late dispatches carry an old token and are rejected even if it
  never learns it was deposed. A lease without fencing is optimism; a
  lease with fencing is a protocol. (The Rust listing in Section 10.13
  implements both in forty lines.)
]

*Why duplicates survive all of this anyway.* Suppose leases and fencing
work perfectly: single owner per shard, always. A fire command is still
delivered at-least-once, because the worker may crash *after* executing
but *before* acking, and the queue (correctly) redelivers. Fencing cannot
help here — the *same* token legitimately appears twice. This is why the
last line of defense lives at the point of side effect: the worker claims
the run's idempotency key `(job_id, scheduled_time)` in the dedup store
before touching the world, and marks it complete after. A redelivered
command finds the key claimed and exits 0. The system is a pipeline of
decreasing error rates: leases make double-ownership rare, fencing makes
it harmless, queues make delivery at-least-once, and idempotency makes
that invisible.

#defterm([Heartbeat])[
  A periodic "I am alive and working on X" signal from a component —
  workers to the scheduler, lease-holders to the lease store. Missed
  heartbeats past a timeout flip the component to *suspect*, then *dead*,
  and its work is reclaimed: its lease expires, its in-flight runs return
  to the queue. The heartbeat's only subtlety is the timeout: too short
  and GC pauses cause flapping takeovers; too long and failover violates
  the 15 s SLO. Ten seconds with three-miss tolerance is the field's
  default for a reason.
]

== Deep Dive: Retries, Backoff, Jitter, and the Dead-Letter Queue

A run fails. What happens next is policy, and policy is design.

*Retry with exponential backoff and full jitter.* Attempt _k_ waits
`random(0, min(cap, base · 2ᵏ))`: the mean doubles each attempt (giving a
struggling dependency room to recover), the cap keeps the tail sane, and
the randomization — *full jitter*, drawn fresh per (job, attempt) —
spreads a fleet of simultaneous failures across the whole window instead
of re-stampeding the dependency in lockstep. This is Chapter 3's token
bucket seen from the other side: there we *rate-limited clients*; here we
rate-limit *ourselves*, because a retry storm is a self-inflicted
denial-of-service.

#defterm([Dead-letter queue (DLQ)])[
  The terminal queue for runs that exhaust their retry budget. A DLQ is
  not a trash can; it is a *quarantine with a promise*: every entry keeps
  its full context (payload, error, attempt history, stack), an alarm
  fires on arrival rate, and an operator tool can inspect, patch, and
  *re-drive* entries back into the dispatch queue once the underlying
  fault is fixed. The design rule: nothing may fail silently, and no
  human should ever reconstruct state from logs alone.
]

*Which failures retry and which don't.* Distinguish *retryable* errors
(timeouts, 502s, connection resets — the dependency might recover) from
*permanent* ones (400, schema rejection, "no such user" — retrying is
just slow failure). Only retryable errors consume the budget; permanent
errors dead-letter immediately. One more taxonomy line separates senior
answers: a *poison message* — a run that crashes every worker that
touches it — is detected by "attempts exhausted with crash-looping
workers" and dead-lettered before it can saw through the fleet.

#tip([Say the quiet part about 2:30 AM])[
  Retry policy, misfire policy, and DST policy are where schedulers hurt
  people in production, and interviewers know it. Volunteer the stories:
  the billing job that double-charged because a retry lacked an
  idempotency key; the report that silently skipped a day because
  catch-up defaulted to skip; the 02:30 job that fired twice on fall-back
  day. You do not need to have lived them — you need to show you know
  they are *policy choices*, not accidents.
]

== Deep Dive: Workflows — DAGs of Jobs

Real pipelines are not independent jobs: _extract_ must finish before
_transform_, which feeds three parallel _load_ jobs, which gate
_notify_. The scheduler must understand dependencies.

#defterm([DAG (directed acyclic graph) / workflow])[
  A _directed_ graph: edges mean "depends on" (B's incoming edge from A
  means A must succeed before B may fire). _Acyclic_: no dependency
  loops — a cycle has no valid execution order, so it is rejected at
  *submission time* (the Rust listing's cycle detection), never
  discovered at 3 AM at runtime. The _layers_ of the DAG — Kahn's
  algorithm peels zero-dependency nodes level by level — are the free
  parallelism: every job in a layer is independent and may fire
  concurrently; the workflow's critical path is its longest layer chain.
]

*Mechanics.* A workflow is stored as a job graph plus one *run record* per
workflow instance. When a run completes, the scheduler decrements the
*pending-dependency count* of each child in the store; a child whose
count hits zero becomes a normal due job and enters the trigger pipeline
— no special machinery downstream. Failure policy is per-workflow:
*fail-fast* (first failure cancels pending descendants, workflow run
fails) or *complete-branches* (unaffected branches run to completion —
right for fan-out reports). Compensation — "payment captured, refund if
shipping fails" — is the workflow-level echo of Chapter 9's invariant
boundary: it is *application* logic the scheduler must make expressible,
not a guarantee it can manufacture.

#insight([The scheduler's data model in one breath])[
  `jobs` (durable specs, indexed by `(shard, next_fire_at)`) ·
  `runs` (one per firing: status, attempt count, idempotency key) ·
  `workflow_edges` (job → depends-on) ·
  `dedup` (claimed idempotency keys with TTL) ·
  `leases` (shard → holder, fencing token, expiry).
  Five tables. Everything else in this chapter — wheels, retries,
  takeovers, DLQs — is a process reading and writing those five tables
  under a discipline. If your whiteboard has more boxes than that, you are
  designing the org chart, not the system.
]

== API Design

The surface is deliberately small: jobs and workflows in, runs and
dead-letters out, and a handful of internal endpoints for the lease and
dispatch machinery. Every mutating client call accepts an idempotency key
(Chapter 5's vote endpoint, generalized); every internal dispatch carries
a fencing token (Section 10.8).

#tbl(
  (1.35fr, 0.7fr, 2.25fr),
  header: (hcell[Endpoint], hcell[Scope], hcell[Semantics]),
  body: (
    [`POST /jobs`], [client], [Register one-shot (`fire_at`) or recurring (`cron` + `tz`) job; validates the schedule, computes first `next_fire_at`, applies splay offset],
    [`PATCH /jobs/{id}`], [client], [Update spec; schedule changes re-materialize `next_fire_at` — the old timer dies as a lazy tombstone (§10.13)],
    [`DELETE /jobs/{id}`], [client], [Cancel: no future fire times; the in-flight run is left to finish or killed per the job's `cancel_policy`],
    [`GET /jobs/{id}`], [client], [Spec + status + `next_fire_at` + summary of the last run],
    [`POST /workflows`], [client], [Submit a DAG {jobs, edges}; *cycle-checked at submission* (§10.10); returns a workflow id],
    [`GET /runs?job_id=…&cursor=`], [client], [Run history, cursor-paginated — Chapter 5's cursor pattern, unchanged],
    [`POST /dlq/{run}/redrive`], [operator], [Re-enqueue a dead-lettered run once the underlying fault is fixed],
    [`POST /leases/{shard}`], [internal], [Acquire or renew a shard lease; response carries the new fencing token],
    [`POST /dispatch/pull`], [internal], [Worker pulls a batch of fire commands; the visibility timeout starts],
    [`POST /dispatch/ack`], [internal], [Report outcome; un-acked commands redeliver when the timeout lapses],
  ),
)

#defterm([Visibility timeout])[
  The queue's redelivery timer: a pulled message becomes invisible to
  other consumers for T seconds; if the puller neither acks nor abandons
  it within T, the message reappears and another worker takes it. It is
  the queue-level twin of the shard lease — same trick, same blind gap
  ("am I still the owner?"), same final answer: idempotency at the point
  of side effect, because neither lease nor timeout can ever be airtight.
]

== High-Level Architecture

Read the diagram top to bottom as *registration*, then top to bottom
again as *firing*: two flows sharing five tables. The write path a user
sees ends at the job store; everything below it is the system talking to
itself.

#canvas(h: 8.1cm)[
  // row 0: clients, api, job store
  #node(0.4cm, 0cm, 3.4cm, 0.85cm, [Clients], fill: faint, edge: slate)
  #node(4.7cm, 0cm, 4.4cm, 0.85cm, [API service — validation, \ cron parsing, splay], edge: primary, fill: faint-blue)
  #node(10.0cm, 0cm, 6.1cm, 0.85cm, [Job store — specs, runs, \ index on (shard, next\_fire\_at)], edge: primary, fill: faint-blue)
  #arrow(3.8cm, 0.42cm, 4.7cm, 0.42cm, color: slate)
  #arrow(9.1cm, 0.42cm, 10.0cm, 0.42cm, color: slate)

  // lease caption + schedulers
  #glabel(0.55cm, 1.6cm)[schedulers own shards via leases; every dispatch carries a fencing token]
  #node(0.4cm, 1.95cm, 4.9cm, 1.0cm, [Scheduler replica \ shards 0–21], edge: primary, fill: faint-blue)
  #node(5.8cm, 1.95cm, 4.9cm, 1.0cm, [Scheduler replica \ shards 22–42], edge: primary, fill: faint-blue)
  #node(11.2cm, 1.95cm, 4.9cm, 1.0cm, [Scheduler standby \ shards 43–63], edge: slate, fill: faint)
  #arrow(13.6cm, 0.85cm, 13.6cm, 1.95cm, color: slate)
  #glabel(13.75cm, 1.3cm)[poll due slice]

  // dispatch queue
  #node(0.4cm, 3.85cm, 6.6cm, 1.0cm, [Dispatch queue — durable, \ at-least-once log (Ch. 4)], edge: teal, fill: faint-teal)
  #arrow(2.85cm, 2.95cm, 2.85cm, 3.85cm, color: teal)
  #arrow(6.25cm, 2.95cm, 5.6cm, 3.85cm, color: teal)
  #arrow(13.65cm, 2.95cm, 6.5cm, 3.82cm, color: teal)
  #glabel(3.0cm, 3.32cm, fg: teal)[fire commands, idempotency-keyed]

  // workers + dedup store
  #node(0.4cm, 5.65cm, 5.6cm, 1.0cm, [Dedup / result store \ idempotency keys, run status], edge: primary, fill: faint-blue)
  #node(8.0cm, 5.65cm, 3.9cm, 1.0cm, [Worker pool \ execute + heartbeat], edge: slate, fill: faint)
  #node(12.2cm, 5.65cm, 3.9cm, 1.0cm, [Worker pool \ GPU / batch], edge: slate, fill: faint)
  #arrow(7.0cm, 4.35cm, 8.0cm, 5.55cm, color: slate)
  #glabel(3.35cm, 5.0cm)[workers pull; ack only after the side effect]
  #arrow(8.0cm, 6.15cm, 6.0cm, 6.15cm, color: slate)
  #glabel(6.15cm, 6.28cm)[claim key first]

  // dead letter queue
  #node(8.0cm, 7.05cm, 5.2cm, 0.95cm, [Dead-letter queue \ retries exhausted], edge: crimson, fill: faint-red)
  #arrow(9.95cm, 6.65cm, 9.95cm, 7.05cm, color: crimson, dashed: true)
]

#notebox([Reading the diagram])[
  *Registration* flows right along the top: the API validates the cron
  expression, stamps the job with its shard (`hash(job_id) mod 64`), its
  splay offset, and its first `next_fire_at`, and writes it to the job
  store — done; the user gets an ack without any timer existing yet.
  *Firing* flows downward: each scheduler replica range-scans the due
  slice of *its* shards (the Chapter 8 leaf walk), enqueues
  idempotency-keyed fire commands, workers pull and execute — checking
  the dedup store before any side effect — and exhausted runs drain to
  the DLQ with their full context. No box is a global singleton: the API
  is stateless, the store is replicated, schedulers are fungible behind
  leases, the queue is a partitioned log, workers are a pool.
]

== Rust Reference Implementations

Four pieces with deterministic tests: the due-job heap, the lease table
with fencing, the backoff schedule, and the DAG layerer. Together they are
the scheduler's entire inner loop, small enough to hold in your head and
sharp enough to defend line by line.

=== The Due-Job Heap (Lazy Cancellation)

```rust
use std::collections::{BinaryHeap, HashMap};

/// One scheduled firing. `fire_at` is epoch millis; `seq` breaks ties so
/// equal fire times fire in submission order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Scheduled {
    pub fire_at: u64,
    pub seq: u64,
    pub job: u64,
}

// BinaryHeap is a MAX-heap; invert the comparison so the SOONEST
// fire_at is "greatest" and pops first.
impl Ord for Scheduled {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        other.fire_at
            .cmp(&self.fire_at)
            .then(other.seq.cmp(&self.seq))
            .then(other.job.cmp(&self.job))
    }
}
impl PartialOrd for Scheduled {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

/// In-memory timer structure sitting in front of the durable store.
/// Cancel/reschedule are lazy: the stale heap entry is left in place and
/// skipped when popped — an entry is valid iff `live[job] == fire_at`.
pub struct Scheduler {
    heap: BinaryHeap<Scheduled>,
    live: HashMap<u64, u64>, // job id -> currently valid fire_at
    seq: u64,
}

impl Scheduler {
    pub fn new() -> Self {
        Scheduler { heap: BinaryHeap::new(), live: HashMap::new(), seq: 0 }
    }

    /// Schedule (or reschedule: a second call for the same job supersedes
    /// the first — the old heap entry becomes a dud on its own).
    pub fn schedule(&mut self, job: u64, fire_at: u64) {
        self.seq += 1;
        self.heap.push(Scheduled { fire_at, seq: self.seq, job });
        self.live.insert(job, fire_at);
    }

    pub fn cancel(&mut self, job: u64) {
        self.live.remove(&job); // heap entry stays; popped-and-skipped later
    }

    /// Drain every job due at or before `now`, soonest first.
    pub fn pop_due(&mut self, now: u64) -> Vec<u64> {
        let mut due = Vec::new();
        while let Some(&top) = self.heap.peek() {
            if top.fire_at > now { break; }
            let entry = self.heap.pop().unwrap();
            if self.live.get(&entry.job) != Some(&entry.fire_at) {
                continue; // cancelled or superseded: a dud
            }
            self.live.remove(&entry.job);
            due.push(entry.job);
        }
        due
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fires_in_fire_time_order() {
        let mut s = Scheduler::new();
        s.schedule(1, 300);
        s.schedule(2, 100);
        s.schedule(3, 200);
        assert!(s.pop_due(50).is_empty());      // nothing due yet
        assert_eq!(s.pop_due(200), vec![2, 3]); // soonest first
        assert_eq!(s.pop_due(1000), vec![1]);
    }

    #[test]
    fn cancel_prevents_firing() {
        let mut s = Scheduler::new();
        s.schedule(1, 100);
        s.schedule(2, 100);
        s.cancel(1);
        assert_eq!(s.pop_due(100), vec![2]);   // job 1's dud is skipped
        assert!(s.pop_due(1000).is_empty());
    }

    #[test]
    fn reschedule_fires_once_at_new_time() {
        let mut s = Scheduler::new();
        s.schedule(7, 100);
        s.schedule(7, 400);                    // reschedule = supersede
        assert!(s.pop_due(150).is_empty());    // the old time must NOT fire
        assert_eq!(s.pop_due(400), vec![7]);   // the new time fires, once
        assert!(s.pop_due(1000).is_empty());   // and no ghost fires after
    }
}
```

The `live` map is the whole trick: cancellation in a binary heap is O(n)
if done eagerly (find the entry, remove it, re-heapify) and O(1) if done
lazily (record the truth, let the heap find out when it matters). With
cancel-heavy workloads this is the difference between a timer structure
and a performance incident — and the same lazy-tombstone pattern as
Chapter 9's OR-Set removals.

=== Leases with Fencing Tokens

```rust
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Lease {
    pub holder: u64,
    pub fence: u64,      // monotonically increasing across ALL acquisitions
    pub expires_at: u64,
}

/// Shard ownership registry. A scheduler replica may dispatch a shard's
/// due jobs only while it holds the lease; the fencing token lets every
/// downstream store reject a stale holder whose lease silently lapsed.
pub struct LeaseTable {
    leases: HashMap<u64, Lease>,
    next_fence: u64,
}

impl LeaseTable {
    pub fn new() -> Self {
        LeaseTable { leases: HashMap::new(), next_fence: 0 }
    }

    /// Acquire or renew the lease on `shard`. Fails only if another
    /// holder's lease is still live; an expired lease can be taken over.
    pub fn acquire(&mut self, shard: u64, holder: u64, now: u64, ttl: u64) -> Option<Lease> {
        match self.leases.get(&shard) {
            Some(l) if l.holder != holder && l.expires_at > now => None, // held by someone else
            _ => {
                self.next_fence += 1;
                let lease = Lease { holder, fence: self.next_fence, expires_at: now + ttl };
                self.leases.insert(shard, lease);
                Some(lease)
            }
        }
    }

    /// The downstream check, kept as per-shard "highest token seen":
    /// accept a dispatch only from a strictly newer holder. A deposed
    /// scheduler waking from a GC pause presents an old token and is
    /// turned away — that rejection is fencing doing its one job.
    pub fn check_fence(highest_seen: &mut u64, fence: u64) -> bool {
        if fence > *highest_seen { *highest_seen = fence; true } else { false }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lease_excludes_second_holder_until_expiry() {
        let mut t = LeaseTable::new();
        let a = t.acquire(0, 1, 1000, 500).unwrap();    // holder 1 until t=1500
        assert!(t.acquire(0, 2, 1200, 500).is_none());  // contender rejected
        let b = t.acquire(0, 2, 1600, 500).unwrap();    // after expiry: takeover
        assert!(b.fence > a.fence);                     // token strictly rises
    }

    #[test]
    fn renewal_keeps_ownership() {
        let mut t = LeaseTable::new();
        let a = t.acquire(0, 1, 1000, 500).unwrap();
        let r = t.acquire(0, 1, 1400, 500).unwrap();    // same holder renews
        assert_eq!(r.holder, 1);
        assert_eq!(r.expires_at, 1900);
        assert!(r.fence > a.fence);                     // every grant gets a new token
    }

    #[test]
    fn stale_fence_is_rejected() {
        let mut highest = 0;
        assert!(LeaseTable::check_fence(&mut highest, 5));  // fresh holder accepted
        assert!(!LeaseTable::check_fence(&mut highest, 4)); // stale holder deposed
        assert!(!LeaseTable::check_fence(&mut highest, 5)); // replay also rejected
        assert!(LeaseTable::check_fence(&mut highest, 6));  // next holder proceeds
    }
}
```

=== Exponential Backoff with Full Jitter

```rust
/// Retry schedule: attempt k waits random(0, min(cap, base * 2^k)).
/// The exponential mean gives a struggling dependency room to recover;
/// full jitter spreads a fleet of simultaneous failures across the whole
/// window so they don't re-stampede in lockstep (Section 10.9).
pub struct Backoff {
    pub base_ms: u64,
    pub cap_ms: u64,
    pub max_attempts: u32,
}

impl Backoff {
    /// splitmix64 over (job, attempt): a deterministic, decorrelated
    /// jitter source — reproducible per job, no shared RNG state.
    fn jitter(&self, job: u64, attempt: u32) -> u64 {
        let mut x = job
            .wrapping_mul(0x9E3779B97F4A7C15)
            .wrapping_add(attempt as u64);
        x = (x ^ (x >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        x = (x ^ (x >> 27)).wrapping_mul(0x94D049BB133111EB);
        x ^ (x >> 31)
    }

    /// Delay before retry `attempt` (0-based). None = budget exhausted,
    /// send the run to the dead-letter queue.
    pub fn delay(&self, job: u64, attempt: u32) -> Option<u64> {
        if attempt >= self.max_attempts { return None; }
        let exp = self.base_ms.saturating_mul(1u64 << attempt.min(20));
        let ceiling = exp.min(self.cap_ms);
        Some(self.jitter(job, attempt) % (ceiling + 1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_grows_then_caps() {
        let b = Backoff { base_ms: 100, cap_ms: 10_000, max_attempts: 8 };
        for attempt in 0..8u32 {
            let d = b.delay(42, attempt).unwrap();
            let ceiling = (100u64 << attempt).min(10_000);
            assert!(d <= ceiling); // within this attempt's window
        }
        assert_eq!(b.delay(42, 8), None); // exhausted -> dead-letter
    }

    #[test]
    fn jitter_stays_in_bounds_and_varies() {
        let b = Backoff { base_ms: 1000, cap_ms: 60_000, max_attempts: 10 };
        assert_eq!(b.delay(7, 2), b.delay(7, 2)); // deterministic per (job, attempt)
        let first = b.delay(0, 3).unwrap();
        let mut varies = false;
        for job in 0..1000u64 {
            let d = b.delay(job, 3).unwrap();
            assert!(d <= 8000);          // hard bound: base * 2^3
            if d != first { varies = true; }
        }
        assert!(varies);                 // the fleet actually spreads
    }
}
```

=== DAG Layers (Kahn's Algorithm)

```rust
use std::collections::{BTreeMap, BTreeSet, VecDeque};

/// Execution layers of a job DAG: layer 0 = roots (no dependencies),
/// layer k = jobs whose dependencies all sit in earlier layers. Jobs
/// within a layer are independent and run in parallel; layers run in
/// order. `deps` are (job, depends_on) pairs.
///
/// Returns None on a cycle or an unknown job: a malformed workflow must
/// fail loudly at submission time, never hang silently at runtime.
pub fn layers(jobs: &[u64], deps: &[(u64, u64)]) -> Option<Vec<Vec<u64>>> {
    let mut indegree: BTreeMap<u64, usize> = jobs.iter().map(|&j| (j, 0)).collect();
    let mut children: BTreeMap<u64, Vec<u64>> = BTreeMap::new();
    for &(job, dep) in deps {
        *indegree.get_mut(&job)? += 1;        // unknown job -> reject
        children.entry(dep).or_default().push(job);
    }

    // Kahn's algorithm: repeatedly peel the zero-indegree frontier.
    let mut frontier: VecDeque<u64> = indegree
        .iter()
        .filter(|(_, &d)| d == 0)
        .map(|(&j, _)| j)
        .collect();
    let mut out: Vec<Vec<u64>> = Vec::new();
    let mut placed = 0usize;

    while !frontier.is_empty() {
        let layer: BTreeSet<u64> = frontier.drain(..).collect();
        placed += layer.len();
        let mut next = Vec::new();
        for &j in &layer {
            for &c in children.get(&j).into_iter().flatten() {
                let d = indegree.get_mut(&c).unwrap();
                *d -= 1;
                if *d == 0 { next.push(c); }  // all dependencies satisfied
            }
        }
        out.push(layer.into_iter().collect());
        next.sort_unstable();
        next.dedup();
        frontier = next.into_iter().collect();
    }

    if placed == jobs.len() { Some(out) } else { None } // unplaced => cycle
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diamond_runs_in_three_layers() {
        //     1
        //    / \
        //   2   3      layer 2 = {2, 3} runs in parallel
        //    \ /
        //     4
        let jobs = vec![1, 2, 3, 4];
        let deps = vec![(2, 1), (3, 1), (4, 2), (4, 3)];
        let l = layers(&jobs, &deps).unwrap();
        assert_eq!(l, vec![vec![1], vec![2, 3], vec![4]]);
    }

    #[test]
    fn cycle_is_rejected_at_submission() {
        let jobs = vec![1, 2, 3];
        let deps = vec![(2, 1), (3, 2), (1, 3)]; // 1 <- 2 <- 3 <- 1
        assert_eq!(layers(&jobs, &deps), None);
    }

    #[test]
    fn unknown_dependency_is_rejected() {
        assert_eq!(layers(&[1, 2], &[(2, 99)]), None);
    }

    #[test]
    fn independent_jobs_share_layer_zero() {
        let l = layers(&[10, 20, 30], &[]).unwrap();
        assert_eq!(l, vec![vec![10, 20, 30]]);
    }
}
```

The layer view is not just validation — it *is* the workflow execution
plan. The scheduler fires layer 0, and each run completion decrements its
children's pending counts in the store; a child reaching zero is promoted
to a normal due job. The trigger pipeline from Section 10.7 never learns
that workflows exist — separation of concerns, enforced by the data model.

#tip([Name the classics when you borrow them])[
  Kahn's algorithm (1962) for topological layering, the hashed timing
  wheel (Varghese & Lauck, 1987), the Two Generals problem for
  exactly-once, splitmix64 for jitter — dropping the name plus the year
  signals that your design is assembled from proven parts, not invented
  under pressure. One sentence each is enough; the interviewer will
  either nod or lean in, and both are wins.
]

== Scaling the Design

*More timers.* Sharding by `hash(job_id) mod N` scales the trigger side
horizontally: 64 shards today, 1 024 tomorrow — a lease-table rebalance,
not a redesign. The due-scan per shard stays a bounded range query no
matter how large the job table grows, because the index, not the table
size, sets the cost (Chapter 8's height-3 lesson). The in-memory heap of
Section 10.13 rides in front of each shard's scan as a hot cache: the
replica refills it with the next few seconds of timers per tick, so the
store sees one scan per shard-second, not one per timer.

*More firing rate.* The dispatch queue partitions by shard and scales like
Chapter 4's log; worker pools scale independently per execution class —
the GPU pool and the HTTP pool share nothing but the queue. Per-tenant
fairness is enforced at *enqueue* time with Chapter 3's token bucket: a
tenant past its quota has its fire commands delayed, not dropped, and the
splay from Section 10.5 keeps the aggregate curve flat enough that quotas
rarely bite.

*More regions.* The job store replicates cross-region (Chapter 9's
machinery would make specs available everywhere); schedulers run
active-active with region-local shard ownership, so a region loss moves
leases, not data. Clock discipline is the quiet dependency: schedulers
reason about "now" via NTP-disciplined UTC, and fire times are always
stored in UTC with the tenant's zone applied at materialization — the DST
trap of Section 10.1 is a data-model decision, not a runtime surprise.

== Failure Modes & Degradation

#tbl(
  (0.95fr, 1.4fr, 1.8fr),
  header: (hcell[Failure], hcell[Symptom], hcell[Handling]),
  body: (
    [Scheduler crash], [Shard goes quiet], [Lease expires ≤ 10 s; standby takes over and *rescans* — the store is the truth, the queue an accelerator, so nothing due is lost],
    [Scheduler GC pause], [Stale holder keeps dispatching after lease loss], [Fencing tokens: every downstream write from the old holder is rejected (§10.8)],
    [Queue partition], [Fire commands not flowing], [Schedulers keep scanning; enqueue retries with backoff; on heal, misfire policy (coalesce/replay/skip) applies per job],
    [Worker death mid-run], [Side effect maybe done, ack never sent], [Visibility timeout redelivers; dedup store makes the second attempt a no-op — at-least-once + idempotency = effectively-once],
    [Poison message], [Run crash-loops workers], [Attempt counter exhausts → DLQ; per-target circuit breaker pauses dispatch to the failing dependency],
    [Clock skew], [Two schedulers disagree on "now" by seconds], [Fire times in UTC, NTP alerting; a job firing 2 s late is a blip, not a bug — the SLO already budgets it],
    [DLQ flood], [Operator pager fires], [Alarm on inflow rate; redrive tool after the fix; the DLQ is a quarantine, not a graveyard],
  ),
)

#pitfall([The double-fire you designed yourself])[
  The most common self-inflicted duplicate: a scheduler that enqueues the
  fire command and *then* updates `next_fire_at` — crashing in between
  means the successor rescans, finds the job still due, and fires again.
  Two honest answers: (1) claim-then-enqueue — atomically advance
  `next_fire_at` in the same transaction as recording the fire, so a
  rescan sees the job already handled; (2) accept the duplicate and let
  the idempotency key absorb it. Production systems do both: belt at the
  scheduler, suspenders at the worker. Skipping both is how billing
  systems end up in the news.
]

== Trade-offs & Alternatives

#tbl(
  (1.2fr, 1.15fr, 1.35fr, 1.35fr),
  header: (hcell[Choice], hcell[We picked], hcell[Alternative], hcell[Why the alternative loses (here)]),
  body: (
    [Timer structure], [Indexed store scan + heap cache], [Hierarchical timing wheel], [Wheel is O(1) but volatile; the store scan is durable truth and fast enough — rebuild-on-failover is the wheel's hidden tax],
    [Dispatch], [Pull (workers fetch)], [Push (scheduler assigns)], [Pull is self-balancing backpressure: a slow worker simply stops pulling; push needs a feedback loop to not drown stragglers],
    [Ownership], [Sharded leases + fencing], [Single leader scheduler], [A leader is a throughput ceiling and a failover event; leases make failover routine and per-shard],
    [Execution guarantee], [At-least-once + dedup], [Distributed transactions], [XA/2PC across queue + store + worker is operationally brittle and slow; idempotency keys are cheap and honest],
    [Queue substrate], [Durable log (Ch. 4)], [Postgres `SKIP LOCKED` as queue], [Fine at 10³ msg/s, painful at 10⁵; the log replays and partitions better. A fair second choice at small scale — say so],
    [Scheduling in-app], [Central scheduler service], [Per-app cron / k8s CronJob], [Per-app timers scatter retry, misfire, and audit policy across a thousand repos; the service exists to own the policy],
  ),
)

== Observability & SLOs

The scheduler's vital sign is *fire lag*: `now − scheduled_time` at the
moment of enqueue. Everything else is a leading indicator of lag.

#tbl(
  (0.95fr, 1.55fr, 1.15fr),
  header: (hcell[Signal], hcell[What it measures], hcell[Alert when]),
  body: (
    [Fire lag], [Enqueue time minus scheduled time, per shard], [p99 \> 1 s sustained: shard under-provisioned or store slow],
    [Due-scan duration], [Time per shard range scan], [Rising trend: index bloat or hot shard (Ch. 8)],
    [Lease flapping], [Takeovers per hour], [\> a few/day: GC pauses, network instability, or too-short TTL],
    [Queue depth], [Unconsumed fire commands], [Growing: workers down, or a tenant burst past quota],
    [Dedup hit rate], [Duplicates absorbed ÷ runs], [Sudden rise = redelivery storm; sustained ≈ 0 is normal],
    [Retry / DLQ inflow], [Failures per minute by target], [Spike by one target: dependency outage — page its owner, not the scheduler's],
    [Worker slot utilization], [Busy slots ÷ total, per pool], [Sustained ≈ 100%: capacity is the lag's cause],
  ),
)

*SLOs.* Fire latency: p99 ≤ 1 s for one-shot jobs, ≤ 5 s for cron.
Durability: registered jobs and accepted fire commands survive any single
region loss. Failover: shard ownership moves in ≤ 15 s. Visible
duplicates: ≈ 0 — dedup absorbs ≥ 99.99% of at-least-once redeliveries,
and the remainder are reported, not hidden.

== Interview Wrap-Up

*Likely follow-ups, with the shape of a strong answer.*

- _"But can you give me exactly-once?"_ No — and say why in one breath
  (the Two Generals: the worker that crashes after its side effect is
  indistinguishable from one that crashed before). Then give the
  effectively-once recipe and name the dedup store as the price.
- _"A job must run at 09:00 in the user's local zone."_ Store UTC +
  zone; materialize `next_fire_at` against the zone's rules; declare the
  DST policy (skip the impossible 02:30, coalesce the doubled one).
  Volunteering DST before being asked is the seniority signal.
- _"Pause a whole tenant right now."_ A kill-switch flag checked at
  *dispatch pull* and at *scan* — two enforcement points, because the
  queue may already hold their commands.
- _"Charge a credit card on a schedule."_ The side effect leaves your
  blast radius: idempotency key at the payment gateway (Stripe-style),
  retry only on retryable errors, dead-letter fast on card-declined —
  retrying a decline is harassment, not reliability.
- _"Design Airflow."_ This chapter plus the DAG section is Airflow's
  skeleton: its scheduler loop, executor pools, and dead-letter cousin
  (the "failed task" state with manual retry) map one-to-one onto the
  five tables.
- _"What breaks first at 100×?"_ The single-region job store's write
  throughput on `next_fire_at` updates — every fire rewrites the row.
  Answer: shard the store along the same hash, batch the
  re-materialization, and consider LSM-shaped storage (Chapter 8's rival)
  because this workload is write-dominated.

*Checklist for the whiteboard.* (1) Split trigger vs firing vs execution
  in the first five minutes. (2) Give the exactly-once speech unprompted.
  (3) Put the index on `next_fire_at` and say "range scan, Chapter 8
  style". (4) Draw the lease and its fencing token as separate things.
  (5) Retry with jitter, dead-letter with redrive. (6) Splay the
  top-of-hour herd. (7) Five tables, no more.

== Summary & Further Reading

A distributed job scheduler is three systems wearing one trenchcoat. The
*trigger side* turns 10⁷ timers into a per-second range scan over a B+ tree
index — durable, resumable, boring in the best way — with an in-memory
heap as a hot cache and lazy tombstones for cancels. The *firing side*
divides shards among fungible scheduler replicas with leases whose blind
gap is closed by fencing tokens, and hands fire commands to a durable
at-least-once log. The *execution side* makes at-least-once invisible:
workers claim idempotency keys before any side effect, retries decay with
full-jitter exponential backoff, exhausted runs quarantine in a dead-letter
queue with their context intact, and workflows reduce to per-child
dependency counters fed back into the same trigger pipeline. The
uncomfortable truths are the design's load-bearing walls: exactly-once is
impossible, so effectively-once is engineered; the top-of-hour burst, not
the average, sizes the fleet, so demand is splayed flat; and every policy
— misfire, retry, cancel, catch-up — is a choice the system makes
explicit because the alternative is making it by accident at 3 AM.

*Further reading.*

- The source video: _"20: Distributed Job Scheduler — Systems Design
  Interview Questions with Ex-Google SWE"_ (Jordan has no life):
  `https://www.youtube.com/watch?v=pzDwYHRzEnk`
- Varghese & Lauck — _"Hashed and Hierarchical Timing Wheels"_ (1987) —
  the timer structure, from the source.
- Fischer, Lynch, Paterson — _"Impossibility of Distributed Consensus with
  One Faulty Process"_ (1985), and the Two Generals parable — why
  exactly-once was never on the table.
- Kleppmann — _Designing Data-Intensive Applications_, the chapters on
  stream processing and fencing — the effectively-once argument in full.
- Airflow, Temporal, and Kubernetes CronJob documentation — three
  production points in this chapter's design space, with openly documented
  failure semantics.
- AWS Builder's Library — _"Timeouts, retries, and backoff with jitter"_
  — the jitter analysis this chapter's backoff listing implements.

== Chapter Glossary

#tbl(
  (auto, 1fr),
  header: (hcell[Term], hcell[Meaning]),
  body: (
    [At-least-once / at-most-once], [Delivery guarantees: retry-until-ack (duplicates) vs fire-and-forget (losses)],
    [Backoff (exponential, full jitter)], [Retry delay random(0, min(cap, base·2ᵏ)); the randomization prevents retry stampedes],
    [Catch-up policy], [What a misfire costs: coalesce to one firing, replay every miss, or skip to next],
    [Cron expression], [Five-field recurring schedule: minute hour day-of-month month day-of-week],
    [DAG / workflow], [Directed acyclic graph of dependent jobs; cycles rejected at submission],
    [Dead-letter queue], [Quarantine for exhausted runs, with full context and a redrive path],
    [Dedup store], [Claimed idempotency keys with TTL; the effectively-once memory],
    [Effectively-once], [At-least-once transport + idempotent processing; duplicates on the wire, none visible],
    [Fencing token], [Monotonic lease stamp checked downstream; deposes stale holders],
    [Fire lag], [Enqueue time minus scheduled time — the scheduler's vital sign],
    [Heartbeat], [Periodic liveness signal; three misses ≈ dead; work reclaimed],
    [Idempotency key], [Unique operation stamp — `(job_id, scheduled_time)` — claimed before side effects],
    [Job vs run], [Durable specification vs one ephemeral execution of it],
    [Kahn's algorithm], [Peels zero-dependency nodes in layers; both the DAG validator and its execution plan],
    [Lazy tombstone], [Cancel by marking, not removing; the heap entry is skipped when popped],
    [Lease], [Time-bounded exclusive shard ownership, renewable, expiring silently],
    [Misfire], [A scheduled fire time that passed unfired — downtime, failover, or DST],
    [Poison message], [A run that crashes every worker it touches; detected, quarantined],
    [Shard], [`hash(job_id) mod N` slice of the job space; the unit of scheduler ownership],
    [Splay / desynchronization], [Spreading recurring fire times by hash to flatten the top-of-hour herd],
    [Thundering herd], [N timers or retries firing in lockstep, DDoS-ing the next layer down],
    [Timing wheel], [Ring buffer of time-slot buckets; O(1) timers, volatile memory],
    [Two Generals problem], [The impossibility of certain agreement over an unreliable channel],
    [Visibility timeout], [Queue redelivery timer for pulled-but-unacked messages; the consumer-side lease],
  ),
)

#v(0.8em)
#align(center)[
  #text(size: 8.5pt, fill: slate)[
    — End of Chapter 10 · Next: Chapter 11 —
  ]
]
