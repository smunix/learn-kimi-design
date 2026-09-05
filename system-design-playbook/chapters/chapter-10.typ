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

The interviewer draws a clock on the whiteboard and says:

_"Design a distributed job scheduler. Users register jobs — one-shot
('fire at 3:00 AM'), recurring ('every weekday at 07:30'), or whole
workflows of dependent jobs — and the system fires them reliably, at the
right time, at scale: tens of millions of registered jobs, tens of
thousands of firings per second at the peak. Jobs must not be lost, must
not silently double-execute, and the scheduler itself must survive machine
and region failures."_

Before you reach for any machinery, it is worth understanding why this
problem exists at all — why every large company builds this system
eventually, usually after being burned. The naive versions are all traps,
and you have probably written one of them yourself. A single machine
running `cron` works until the machine dies, and then nothing in the
universe fires — a single point of failure with a silently-absent alarm.
A `sleep()` call in application code is even more fragile: it dies with
the process, and nobody even records that the timer ever existed. And the
classic middle step — a database table of jobs polled by every worker —
turns your database into a lock convoy the moment the worker fleet grows.
What the interview is really testing is whether you can look at this
problem and see that it is actually *three problems wearing one coat*:
*knowing when jobs are due* (a data-structures problem), *deciding who
fires them* (a distributed-ownership problem), and *executing them without
duplicates* (a delivery-semantics problem). Each scales differently, fails
differently, and deserves its own section — and separating them in your
first five minutes at the whiteboard is the single highest-signal move in
this interview.

Three definitions will carry the whole chapter, so let's pin them down
before any design work.

#defterm([Job / run / trigger])[
  A _job_ is the registered specification: what to execute (a queue
  message, an HTTP call, a worker class plus payload), *when* (its
  _trigger_: a fire timestamp or a schedule), and *how to behave on
  failure* (retry policy, dead-letter). A _run_ (or execution) is one
  actual firing of a job — jobs are few and durable, runs are many and
  ephemeral. Confusing the two tables in the data model is the first
  design error this chapter avoids.
]

Notice how much design is already hiding in that distinction. The job is
what the user thinks about; the run is what the system thinks about. When
a user edits a job at 02:59, they expect their edit to apply to the 03:00
firing — but the run for 03:00 may already be enqueued with the old
payload. When the scheduler crashes, the *jobs* must all survive (they are
the product), while the *runs* may be replayed, retried, or reconstructed
(they are the exhaust). Every table we draw later hangs off this one
split.

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

Sit with those last two definitions for a moment, because they are where
this problem stops being a puzzle about timers and becomes a puzzle about
*promises*. "Every weekday at 07:30" sounds like a fact; it is actually a
policy expressed in a notation that predates time-zone databases. The
system you are about to design will make thousands of tiny judgment calls
on behalf of its users — what to do about the minute that never existed,
the hour that happened twice, the six minutes of downtime during a deploy
— and the difference between a junior and a senior answer is whether those
judgment calls are *declared per job* or *discovered in the incident
report*.

== Scope & Clarifying Questions

Here is the conversation that bounds the problem. Notice how each answer
eliminates an entire branch of the design space — that is what clarifying
questions are *for*, and asking them crisply is half the interview.

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

Two of these answers deserve a highlight before we move on. "Seconds
matter, microseconds do not" is a gift: it means you never need kernel
timers, hardware timestamping, or any of the exotic machinery of
low-latency trading — a one-second tick loop is plenty, and the design can
spend its complexity budget on reliability instead of precision. And "push
for effectively-once" is the interviewer telegraphing the chapter's core
challenge: they want to hear you explain, unprompted, why exactly-once is
not a thing engineering can buy. We will get there in Section 10.6.

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

Let's turn the prompt into commitments. Read each requirement and ask
yourself which of the three sub-problems — trigger, firing, execution —
it belongs to; you will find every one lands cleanly, which is your first
confirmation that the three-way split is the right skeleton.

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

Requirement 2 is phrased with unusual care — "produces a fire command",
not "executes the job" — and you should mirror that care when you write
your own requirements on the whiteboard. The scheduler's promise ends at
the dispatch queue's door. How long the job takes, whether the worker
fleet is big enough, whether the target service is up: those are the
*worker's* problems. Keeping the promise boundary sharp is what lets you
reason about the scheduler's SLO without dragging the entire downstream
world into it.

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

Read the third bullet twice — it is the philosophical core of the whole
design. You are *trading* loss for duplication on purpose. Loss is
unrecoverable: a billing run that never happens is money silently gone.
Duplication is recoverable: a billing run that happens twice is a bug you
can detect and absorb — and Section 10.6 will show you exactly the
machinery that absorbs it. Whenever a distributed system lets you choose
which failure mode to live with, choose the one that leaves evidence.

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

Three numbers size this design, and you should extract them from the
interviewer before drawing a single box: how many timers exist (sets the
store and the trigger structure), how unevenly they fire (sets the
burst engineering), and how much execution capacity the fire rate implies
(sets the worker fleet). Here are the assumptions we'll carry.

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

Work the rows in order and you can feel the design assemble itself. The
first row tells you the registry is small — 10 GB is a Tuesday for a
replicated relational store, so durability here is cheap. The second row
tells you the *average* workload is tiny — three thousand fires a second
is one modest service. And then the third row ruins your afternoon: the
top-of-hour burst is thirty times the average, because half of humanity
types `0 * * * *` and means it. Row four is the reassurance that finding
due work is easy *if* you index it (and Section 10.7 is entirely about
that "if"). Rows five and six tell you the worker fleet and the queue are
both comfortably inside machinery you have already designed in earlier
chapters. Row seven quietly introduces a second product — run history is
22 TB, a log-retention problem, not a scheduler problem. And the last row
sets the failover budget the firing side must hit.

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

This is a pattern worth internalizing beyond this chapter: whenever your
estimation table contains a row that is 30× its neighbor, the neighbor is
irrelevant and the outlier *is* the design. You will see the same shape in
Chapter 12's ride-hailing dispatch, where Friday-night demand dwarfs the
weekly average, and in Chapter 3's rate limiter, where the whole point is
that arrivals are not polite.

== The Core Challenge: "Exactly Once" Is a Lie We Tell Well

Ask ten engineers what a job scheduler must guarantee and nine say
"exactly-once execution". The tenth — the one who has run one — says
"effectively-once, and here is why." Let's make you the tenth.

The reason is not engineering laziness; it is impossibility, and it is
worth feeling the impossibility rather than memorizing the slogan. Walk
the path of a single fire command: the scheduler enqueues it, a worker
pulls it, the worker performs the side effect — charges the card, sends
the email — and then acks the queue. Now ask: what happens if the worker
crashes *after* the side effect but *before* the ack? The queue sees an
un-acked command and, correctly, redelivers it. A second worker picks it
up. Nobody anywhere in the system can tell whether the first worker
executed or not — the crash erased exactly the one bit of information
that would distinguish the two worlds. Since you cannot distinguish them,
you must design for the worse one, which means you must retry, which means
duplicates on the wire are unavoidable. That is the Two Generals problem
wearing a hard hat: over an unreliable network, "did you get it?" can
never be answered with certainty by the party who needs to know.

So the core challenge splits cleanly in two, and the design addresses
each half with a different weapon:

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

Notice the intellectual honesty baked into this split. The trigger side
gets to live in a world of clean algorithms, because timers are just data.
The firing side must live in the real world, where processes pause and
networks lie. A common interview failure mode is to spend forty minutes
perfecting the trigger structure and wave at the firing side — precisely
backwards, because nobody's billing system was ever double-charged by a
B+ tree.

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
*which jobs are due right now?* Let's look at three designs in increasing
sophistication. In the interview you should name all three — the contrast
is where the signal lives — and then defend your pick.

*Design A: the indexed scan.* Store every job with a materialized
`next_fire_at` column and a B+ tree index on `(shard, next_fire_at)` —
Chapter 8's structure, doing exactly the job it was designed for. A
scheduler tick is one range scan (`next_fire_at ≤ now` within its shard
slice) plus a linked-leaf walk; due jobs stream out in fire-time order at
index speed. After firing (or enqueueing), the job's `next_fire_at` is
recomputed from its cron expression and the row updated — so the index
maintains itself, and the "timer" for next Tuesday is nothing more than a
row whose index key sorts after today's. This is the design this chapter
ships, and the reasons are worth saying out loud: it is durable by
construction (the timers *are* the database — there is no in-memory state
to lose), crash-transparent (a dead scheduler's successor simply rescans
and finds everything, no rebuild step, no warm-up gap), and simple enough
to reason about at 2 AM, which is when you will be reasoning about it.

*Design B: the in-memory min-heap.* Keep a priority queue of
`(fire_at, job)` keyed by soonest-first — the Rust listing in Section
10.13 implements exactly this. O(log n) per schedule or
cancel-via-lazy-tombstone, O(1) peek at the next due job, zero index
maintenance. As an algorithm it is lovely. The catch is that the heap is
*volatile*: it must be rebuilt from the store on every failover, and at
10⁷ timers that is a 10–30 s cold start during which the shard is blind —
blind, notice, for *longer than the 15-second failover SLO* we just
committed to. The production answer is not to choose but to layer: use
the heap as a *hot cache in front of Design A*. The tick loop keeps only
the next few seconds of timers in memory, refilling from the index once
per window; the store sees one scan per shard-second, not one per timer,
and the heap's volatility no longer matters because its contents are
always re-derivable in one scan.

*Design C: the hashed timing wheel.* The classic kernel answer — Kafka's
delayed operations, Netty's timers, and the Linux kernel itself all use
one. Picture an array of buckets representing time slots: slot `i` holds
every timer due at `now + i·tick`, modulo the wheel's circumference, so
insert and expire are O(1) pointer pushes and the whole structure advances
one slot per tick like a clock hand. A *hierarchical* wheel stacks
coarser wheels the way a clock stacks gears: a seconds-wheel feeds a
minutes-wheel feeds an hours-wheel, and a timer due next year parks
cheaply in the outer wheel until it cascades down through the gears toward
its tick. Beautiful, optimal, and entirely in-memory — which means it
inherits the heap's durability problem, adds resize pain when the wheel
fills, and fits cancel-heavy workloads poorly (cancelling means splicing
out of a bucket you must first find). Worth describing in the interview
to show range; wrong as the system of record. If the interviewer pushes —
"but the wheel is O(1)!" — your answer is: *the scan is already fast
enough, and durability is not a feature you can bolt onto volatility
later.*

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

The firing side answers a harder question than the trigger side ever
asked: *who* may fire shard 37's due jobs — and how do we stop
*yesterday's* answer from firing them again? That second clause is where
the difficulty lives, and it is why this section needs three mechanisms
stacked, not one.

*Shard ownership by lease.* Hash-partition the 10⁷ jobs by `job_id` into
(say) 64 shards — 64 is arbitrary; what matters is that it is much larger
than your replica count, so ownership can be rebalanced finely. A
scheduler replica acquires a shard by taking its *lease* from a small
highly-available coordination store; it renews the lease every few
seconds and loses it silently if it stalls — a GC pause, a network
hiccup, death. A standby replica takes over an expired lease, giving you
failover in ≤ 15 s per the SLO. Why leases instead of a proper consensus
election per scheduling decision? Because consensus-per-operation would
put a WAN round-trip inside every tick, and the tick is once per second.
The lease converts a per-operation cost into a per-few-seconds cost.

#defterm([Lease])[
  A time-bounded grant of exclusive ownership: "replica R owns shard S
  until time T, and may renew." Leases convert *membership* ("who owns
  this shard?") from a consensus-per-operation cost into a
  heartbeat-per-few-seconds cost. Their danger is the gap between "my
  lease silently expired" and "I find out": during that gap the old owner
  still believes itself owner, and two owners double-fire.
]

That danger deserves a concrete scene, because it is the scene fencing
exists for. Replica A holds shard 37's lease with a 10-second TTL. At
t=7 s, A enters a stop-the-world GC pause. At t=10 s the lease expires;
at t=12 s standby B takes over and starts firing shard 37's due jobs. At
t=18 s, A wakes up, checks its clock, believes it is still inside its
lease — its last renewal said "valid until t=10+10" and its clock, frozen
during the pause, tells it only t=9 has passed — and fires the same due
jobs a second time. Two owners, both honest, both wrong. You cannot fix
this by making A smarter; A *cannot know*. So you make the rest of the
world smarter instead.

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

In our scene, A's dispatches carry token 41 and B's carry token 42; the
queue (or the job store) has already seen 42 and turns A away at the
door. The deposed scheduler is stopped not by being informed — informing
it is exactly what the network cannot guarantee — but by being *refused*.
That inversion is the whole idea, and it generalizes far beyond this
chapter: whenever ownership can change hands while a client is
partitioned or paused, the resource itself must check credentials on
every operation, and the credentials must be *ordered*.

*Why duplicates survive all of this anyway.* Now the uncomfortable part,
which is also the most instructive. Suppose leases and fencing work
perfectly: single owner per shard, always. A fire command is *still*
delivered at-least-once, because the worker may crash *after* executing
but *before* acking, and the queue — correctly — redelivers. Fencing
cannot help here, and it is worth seeing precisely why: the duplicate is
not a *stale* holder presenting an old token; it is the *same* holder's
legitimate command appearing twice. Ordered credentials distinguish old
owners from new owners; they say nothing about replays *within* one
owner's reign. This is why the last line of defense lives at the point of
side effect: the worker claims the run's idempotency key
`(job_id, scheduled_time)` in the dedup store before touching the world,
and marks it complete after. A redelivered command finds the key claimed
and exits 0. Step back and admire the shape of what we just built: the
system is a pipeline of decreasing error rates. Leases make
double-ownership rare. Fencing makes double-ownership harmless. The queue
makes delivery at-least-once. And idempotency makes at-least-once
invisible. No single layer is airtight; the stack is.

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

A run fails. What happens next is policy, and policy is design — this
section is short on algorithms and long on judgment, which is exactly why
interviewers probe it.

*Retry with exponential backoff and full jitter.* Attempt _k_ waits
`random(0, min(cap, base · 2ᵏ))`. Unpack each ingredient, because each
neutralizes a specific failure mode. The exponential mean doubles per
attempt, giving a struggling dependency exponentially more room to
recover — if the target database is down for thirty seconds, your first
retry at 100 ms was never going to succeed, so why spend it? The cap
keeps the tail sane: without it, attempt 30 waits a geological age, and
your "retry" is indistinguishable from "lost". And the randomization —
*full jitter*, drawn fresh per (job, attempt) — spreads a fleet of
simultaneous failures across the whole window instead of re-stampeding
the dependency in lockstep. Picture ten thousand runs that all failed at
t=0 because the target hiccuped: without jitter they all retry at
t=100 ms, then all at t=200 ms, a self-inflicted denial-of-service in
perfect formation. With jitter they smear across `[0, 2ᵏ·base)` and the
dependency sees a load it can survive. This is Chapter 3's token bucket
seen from the other side: there we *rate-limited clients*; here we
rate-limit *ourselves*, because a retry storm is friendly fire.

#defterm([Dead-letter queue (DLQ)])[
  The terminal queue for runs that exhaust their retry budget. A DLQ is
  not a trash can; it is a *quarantine with a promise*: every entry keeps
  its full context (payload, error, attempt history, stack), an alarm
  fires on arrival rate, and an operator tool can inspect, patch, and
  *re-drive* entries back into the dispatch queue once the underlying
  fault is fixed. The design rule: nothing may fail silently, and no
  human should ever reconstruct state from logs alone.
]

*Which failures retry and which don't.* Here is a taxonomy line that
separates senior answers: distinguish *retryable* errors (timeouts, 502s,
connection resets — the dependency might recover) from *permanent* ones
(400, schema rejection, "no such user" — retrying is just slow failure,
and slow failure with a backoff cap is the worst of both worlds: you pay
the latency and still land in the DLQ). Only retryable errors consume the
budget; permanent errors dead-letter immediately. And one more category,
rarer but deadlier: a *poison message* — a run that crashes every worker
that touches it, say because its payload triggers an untested code path.
Each individual attempt looks like a worker crash, so naive systems just
keep redelivering, and the message saws through the fleet one worker at a
time. The detection rule is "attempts exhausted *with crash-looping
workers*", and the response is immediate dead-lettering plus a circuit
breaker on the target — quarantine the patient before you autopsy it.

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
_notify_. So far our scheduler understands time but not dependency —
and the moment you say "B runs after A succeeds", you have left the land
of timers and entered the land of graphs. Fortunately you need exactly
one graph concept, and it comes with a built-in execution plan.

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

*Mechanics.* A workflow is stored as a job graph plus one *run record*
per workflow instance — the job/run split from Section 10.1, applied
recursively. When a run completes, the scheduler decrements the
*pending-dependency count* of each child in the store; a child whose
count hits zero becomes a normal due job and enters the trigger pipeline
— no special machinery downstream, and that "no special machinery" is
worth dwelling on. The trigger side never learns that workflows exist.
The firing side never learns that workflows exist. Workflows are a
*write-time transformation* of the data model: dependencies live entirely
in "not due yet". This is one of the cleanest examples in the book of a
principle you should carry everywhere — the best way to add a feature to
a system is to reduce it to something the system already does.

Failure policy is per-workflow, and the two standard policies map onto
two genuinely different product intents: *fail-fast* (first failure
cancels pending descendants; the workflow run fails) is right when the
stages are steps of one logical operation — a half-migrated database is
worse than an un-migrated one; *complete-branches* (unaffected branches
run to completion) is right for fan-out reports, where the marketing
dashboard being generated is no reason to cancel the finance one.
Compensation — "payment captured, refund if shipping fails" — is the
workflow-level echo of Chapter 9's invariant boundary: it is
*application* logic the scheduler must make expressible, not a guarantee
it can manufacture. Say that sentence in the interview; it is the
difference between a candidate who has read about sagas and one who knows
why sagas exist.

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

With the machinery understood, the API almost writes itself — and that is
the point of doing the deep dives first. The surface is deliberately
small: jobs and workflows in, runs and dead-letters out, plus a handful
of internal endpoints for the lease and dispatch machinery. Two
disciplines run through every row of the table, and you should name them
as you draw it: every mutating *client* call accepts an idempotency key
(Chapter 5's vote endpoint, generalized — a retried `POST /jobs` must not
create two jobs), and every *internal* dispatch carries a fencing token
(Section 10.8), because internal traffic is exactly where stale owners
live.

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

Read the `PATCH` row slowly — it hides the most elegant move in the whole
API. When a user reschedules a job, you might expect a hunt through some
timer structure to find and remove the old entry. Instead, the row's
`next_fire_at` is simply overwritten, and the old heap entry — still
sitting in some scheduler's memory — becomes a *lazy tombstone*: when it
eventually pops, the `live` check (the Rust listing's trick, Section
10.13) finds the map disagrees and discards it. The update path never
touches the scheduler fleet at all. And the two `dispatch` rows encode
the queue's half of the reliability story: pulling starts a timer, acking
stops it, and the timer firing means "assume the worst, redeliver".

#defterm([Visibility timeout])[
  The queue's redelivery timer: a pulled message becomes invisible to
  other consumers for T seconds; if the puller neither acks nor abandons
  it within T, the message reappears and another worker takes it. It is
  the queue-level twin of the shard lease — same trick, same blind gap
  ("am I still the owner?"), same final answer: idempotency at the point
  of side effect, because neither lease nor timeout can ever be airtight.
]

== High-Level Architecture

Here is the whole chapter in one picture. Before you trace any arrows,
notice the layout's deliberate honesty: the diagram has two *stories*
running through the same boxes — a registration story (short, horizontal,
top row) and a firing story (long, vertical, everything below) — and the
five tables from the data-model insight are where the stories meet.

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

Let's walk it twice, once per story, the way you would narrate it at the
whiteboard.

*The registration story takes ten seconds and stays on the top row.* A
client calls `POST /jobs` with a cron expression and a time zone. The API
service — stateless, horizontally scaled, doing nothing but validation,
cron parsing, and arithmetic — checks the schedule is well-formed,
computes the job's shard as `hash(job_id) mod 64`, applies the splay
offset that flattens the top-of-hour herd, and materializes the first
`next_fire_at` in UTC. Then it writes the row to the job store and acks.
That is the *entire* user-visible write path: no timer exists yet, no
scheduler has been contacted, no thread is sleeping anywhere. The
registered job is simply a row that sorts into the right place in the
`(shard, next_fire_at)` index — a fact in a B+ tree, waiting for time to
catch up with it. This is worth pausing on, because it is the design's
central aesthetic: *registration is just indexing*. The future fire is
not an action anyone scheduled; it is a query result nobody has run yet.

*The firing story is the system talking to itself, and it flows
downward.* Each scheduler replica holds leases on a slice of shards — the
diagram shows two active replicas and a standby, which is the shape you
want: ownership is pre-divided so failover is an arithmetic reassignment,
not a negotiation. Once per second, each replica range-scans the due
slice of *its* shards against the job store (the Chapter 8 leaf walk —
the "poll due slice" arrow dropping from the store into the standby row
depicts exactly this loop). For every due row it does two things: enqueue
an idempotency-keyed fire command onto the dispatch queue — the teal box,
Chapter 4's durable at-least-once log — and advance the row's
`next_fire_at`, so a rescan never sees the job as due twice. Those teal
arrows fanning from all three schedulers into the one queue are worth a
look: they are the point where ownership converges, and it is why every
command carries a fencing token — the queue is the downstream system that
deposes stale holders.

*The bottom two rows are where the world gets touched, and they are drawn
in the order of paranoia you should feel.* Workers *pull* batches from
the queue — never push — so a slow pool is self-throttling backpressure
rather than a drowning victim. The label "workers pull; ack only after
the side effect" is the at-least-once contract in eight words: the
visibility timeout starts at pull, and only a post-side-effect ack stops
it. Before touching the world, the worker claims the run's idempotency
key in the dedup store — the "claim key first" arrow running from the
worker pool leftward into the dedup box is drawn in that direction on
purpose: the dedup store is consulted *before*, not after. And the dashed
crimson arrow dropping from the workers into the dead-letter queue is the
path nobody wants and everybody needs: retries exhausted, context
preserved, operator paged, redrive possible. Two worker pools are drawn
— a general "execute + heartbeat" pool and a "GPU / batch" pool — to make
one last point visible: execution classes scale independently, sharing
nothing but the queue.

Stand back and count singletons. There are none. The API is stateless.
The job store is replicated. The schedulers are fungible behind leases —
kill any one and the standby's next tick covers its shards. The queue is
a partitioned log. The workers are a pool. The dedup store is a keyed
lookup that any replicated KV can serve. Every box in the diagram can be
replaced while the system is running, and the design's promises survive
the replacement — which, more than any single mechanism, is what
"distributed" was supposed to mean.

== Rust Reference Implementations

Time to make the chapter compile. The four listings below are the
scheduler's entire inner loop: the due-job heap (the trigger side's hot
cache), the lease table with fencing (the firing side's ownership
protocol), the backoff schedule (the failure policy's arithmetic), and
the DAG layerer (the workflow engine in forty lines). Each is small
enough to hold in your head, sharp enough to defend line by line in an
interview, and — most importantly — each ships with deterministic tests
that *demonstrate* the property the prose claimed. When you study these,
don't read the code first; read the tests first. The tests are the
contracts.

=== The Due-Job Heap (Lazy Cancellation)

This is Design B from Section 10.7 — the in-memory min-heap that rides in
front of the indexed scan. Two details repay attention before you read a
line of code. First, Rust's `BinaryHeap` is a *max*-heap, so the `Ord`
impl inverts the comparison — soonest `fire_at` compares "greatest" and
pops first, with a sequence number breaking ties so equal fire times fire
in submission order. Second, cancellation is *lazy*: `cancel` never
touches the heap at all. It just updates the `live` map, and the stale
entry — a "dud" — is discovered and skipped when it pops. Read `pop_due`
as a tiny state machine: peek, compare against `now`, pop, validate
against `live`, and only then emit.

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

The `live` map is the whole trick, and it deserves a cost analysis in
both directions so you can defend the choice under pressure. Eager
cancellation in a binary heap is O(n): find the entry (the heap gives you
no index), remove it, re-heapify. Lazy cancellation is O(1): record the
truth, let the heap find out when it matters. The price you pay is
bounded garbage — every cancel or reschedule leaves one dud in the heap
until its old fire time passes, so the heap can hold at most (operations
so far) entries instead of (live timers) — and for a cache that is
refilled from the store every few seconds anyway, that bound is trivially
acceptable. With cancel-heavy workloads this is the difference between a
timer structure and a performance incident — and you have seen the shape
before: it is the same lazy-tombstone pattern as Chapter 9's OR-Set
removals, where deleting eagerly was impossible and deleting lazily was
free.

=== Leases with Fencing Tokens

This listing is Section 10.8's whole protocol in two functions, and the
brevity is the lesson: leases and fencing are not heavyweight
infrastructure, they are a `HashMap` and a counter. `acquire` implements
the ownership rule — fail only if *another* holder's lease is still live;
an expired lease can always be taken over, and every grant bumps the
global fencing counter. `check_fence` is the downstream side — keep a
per-shard "highest token seen" and accept a dispatch only from a strictly
newer holder. Watch the third test: it is the GC-pause scene from Section
10.8 replayed in miniature. The fresh holder's token 5 is accepted; the
deposed holder waking up with token 4 is turned away; even a *replay* of
the accepted token 5 is rejected, because fencing tokens order holders,
not messages — and then the next legitimate holder proceeds with 6.

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

One design note you can volunteer: `acquire` hands a fresh fencing token
even on *renewal* by the same holder. That is deliberate — a token that
only ever meant "latest owner" would suffice for deposing, but
renew-on-every-grant also makes each individual renewal itself a
witnessed, ordered event, which downstream auditors appreciate. The cost
is one integer.

=== Exponential Backoff with Full Jitter

The retry arithmetic from Section 10.9. Two implementation choices are
worth your attention because interviewers pounce on both. First, the
jitter is *deterministic*: a splitmix64 hash over `(job, attempt)` rather
than a thread-local RNG. That makes every retry schedule reproducible per
job — you can replay an incident's timing exactly — and it removes shared
RNG state from a hot path. Second, the shifts are defensive:
`1u64 << attempt.min(20)` caps the exponent so a pathological
`max_attempts` can never overflow the shift, and `saturating_mul`
guarantees the ceiling math degrades to the cap rather than wrapping.
Read the tests as the two properties you actually bought: the window
grows and caps (test one), and the fleet genuinely spreads inside the
window while staying deterministic per key (test two).

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

Last, the workflow engine — and the surprise is how little of it there
is. Kahn's algorithm (1962) peels the zero-indegree frontier repeatedly:
layer 0 is every job with no dependencies, layer 1 is everything whose
dependencies all landed in layer 0, and so on. The function returns
`Option`: `None` means the graph was malformed — a cycle, or a dependency
on a job that was never submitted — and per Section 10.10's rule, that
rejection happens at *submission time*, loudly, in the API service,
rather than at 3 AM in the trigger pipeline. Note the two data-structure
choices doing quiet work: `BTreeMap`/`BTreeSet` keep iteration ordered so
the layers come out deterministic (essential for testing, pleasant for
debugging), and the `?` on `indegree.get_mut(&job)` is the unknown-job
rejection falling out of the type system for free.

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
plan, and closing that loop is the section's payoff. The scheduler fires
layer 0 through the ordinary trigger pipeline; each run completion
decrements its children's pending counts in the store; a child reaching
zero is promoted to a normal due job with `next_fire_at = now`. The
trigger pipeline from Section 10.7 never learns that workflows exist —
separation of concerns, enforced by the data model. And the cycle check
has one more pleasant property worth naming: because it runs at
submission, a cycle can never be *created by time itself* — no failover,
no race, no partial write can turn an accepted workflow into a hang,
because the shape was proven acyclic before the first job ever fired.

#tip([Name the classics when you borrow them])[
  Kahn's algorithm (1962) for topological layering, the hashed timing
  wheel (Varghese & Lauck, 1987), the Two Generals problem for
  exactly-once, splitmix64 for jitter — dropping the name plus the year
  signals that your design is assembled from proven parts, not invented
  under pressure. One sentence each is enough; the interviewer will
  either nod or lean in, and both are wins.
]

== Scaling the Design

The design scales along three axes, and — as in Chapter 9 — it is worth
naming them separately because they fail and are fixed independently.

*More timers.* Sharding by `hash(job_id) mod N` scales the trigger side
horizontally: 64 shards today, 1024 tomorrow — a lease-table rebalance,
not a redesign. The crucial invariant is that the due-scan per shard
stays a bounded range query no matter how large the job table grows,
because the *index*, not the table size, sets the cost — Chapter 8's
height-3 lesson paying rent again. And remember the layering from Section
10.7: the in-memory heap rides in front of each shard's scan as a hot
cache, so the replica refills it with the next few seconds of timers per
tick and the store sees one scan per shard-second, not one per timer.
Growing timers by 100× changes the fan-in of that refill, nothing else.

*More firing rate.* The dispatch queue partitions by shard and scales
like Chapter 4's log — add partitions, add consumer groups. Worker pools
scale independently per execution class: the GPU pool and the HTTP pool
share nothing but the queue, so a batch-job tenant's fleet can triple
without one HTTP worker being requisitioned. Per-tenant fairness is
enforced at *enqueue* time with Chapter 3's token bucket: a tenant past
its quota has its fire commands delayed, not dropped — delayed, because
dropped fire commands are misfires, and misfires invoke policy, whereas
delays are just latency the SLO already budgets. And the splay from
Section 10.5 keeps the aggregate curve flat enough that quotas rarely
bite in the first place.

*More regions.* The job store replicates cross-region — Chapter 9's
machinery would make specs available everywhere — and schedulers run
active-active with region-local shard ownership, so a region loss moves
*leases*, not data. That distinction is the whole sentence: leases are
recomputed in seconds from a coordination store; data would have to be
re-shipped or, worse, reconstructed. Clock discipline is the quiet
dependency under everything: schedulers reason about "now" via
NTP-disciplined UTC, and fire times are always stored in UTC with the
tenant's zone applied at materialization — the DST trap of Section 10.1
is a data-model decision, not a runtime surprise.

== Failure Modes & Degradation

Walk this table the way an on-call engineer reads a runbook: for each
row, ask "what does the *user* see, and which mechanism we already built
is the one that saves them?" You will find every answer is a mechanism
from Sections 10.6–10.9 operating exactly as designed — no row requires
heroics, which is the definition of a mature failure story.

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

The first row deserves special reverence because it contains the deepest
sentence in the chapter: *the store is the truth, the queue an
accelerator*. Once you believe that sentence, scheduler crashes stop
being scary. The dead replica took no irreplaceable state with it — its
heap was a cache, its leases expire on their own, and its successor's
first action is the same action it performs every second anyway: scan the
due slice. Failover is not a special mode; it is the normal loop, started
from a cold cache. Design every stateful system so that recovery is "the
steady state, resumed" and you will sleep better than engineers who build
recovery procedures.

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

Every row of this table is a decision you made earlier in the chapter;
this section exists so you can defend them as *choices*, with a named
alternative and a reason it loses — here, under these requirements, not
in the abstract. That last qualifier matters: several "losers" below are
the right answer at a different scale, and saying so is worth points.

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

Read the last row as the *organizational* trade-off, because it is the
one interviewers with production scars care about most. Per-app cron
works — that is the damning part. It works right up until the company has
a thousand repos, each with its own retry policy, its own misfire
default, its own idea of what "02:30 on fall-back day" means, and no
audit trail anywhere. The central service exists to *own the policy*: one
place where idempotency, retries, misfires, and fairness live, so a
thousand teams never have to re-derive them. When you frame a service as
"a policy with an API", you sound like someone who has been on call.

== Observability & SLOs

The scheduler's vital sign is *fire lag*: `now − scheduled_time` at the
moment of enqueue. Everything else in the table is a leading indicator of
lag — the signals that move *before* the user-visible number does. That
framing is worth stating on your dashboard's first page, because it turns
alerting from a list into a narrative: scan duration creeps, then queue
depth grows, then lag breaches; the page you get at the first stage is a
gift, the page at the last stage is a post-mortem invitation.

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

Two rows reward a second look. *Lease flapping* is the canary for your
timeout tuning: a takeover is cheap but not free — cold cache, rescan,
ramp — and a few per day means your heartbeat interval is arguing with
your GC pauses, an argument the timeout always loses. And the *retry/DLQ
inflow* row encodes an organizational rule as a metric: a spike
*attributed to one target* is that target's outage, so the alert should
page its owner, not the scheduler's on-call. Routing blame correctly in
the alert text is a kindness you do to your future colleagues.

*SLOs.* Fire latency: p99 ≤ 1 s for one-shot jobs, ≤ 5 s for cron —
different numbers because the consumers differ: a one-shot "remind me"
has a human staring at it, while a cron job's consumer is a batch
pipeline that cannot tell five seconds from five milliseconds. Durability:
registered jobs and accepted fire commands survive any single region
loss. Failover: shard ownership moves in ≤ 15 s. Visible duplicates:
≈ 0 — dedup absorbs ≥ 99.99% of at-least-once redeliveries, and the
remainder are *reported, not hidden*, because a duplicate you can see is
a bug, and a duplicate you cannot see is a billing inquiry.

== Interview Wrap-Up

*Likely follow-ups, with the shape of a strong answer.* Each of these has
a first sentence that carries most of the signal — find it, say it first,
then elaborate.

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
#align(center)[#text(size: 8.5pt, fill: slate)[— End of Chapter 10 · Next: Chapter 11, Designing for Correctness: How ACID Transactions Work —]]
