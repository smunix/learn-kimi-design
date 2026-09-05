// ============================================================================
//  CHAPTER 3 — DISTRIBUTED RATE LIMITER
//  Source problem: "7: Design a Rate Limiter"
//  (Systems Design Interview Questions With Ex-Google SWE, Jordan has no life)
// ============================================================================

#import "../template.typ": *

= Designing a Distributed Rate Limiter

#block(fill: faint, radius: 6pt, inset: (x: 14pt, y: 11pt), width: 100%)[
  #set text(size: 9.2pt)
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 8pt, weight: "bold", fill: slate, tracking: 0.1em)[PROBLEM SOURCE]
  #v(4pt)
  This chapter solves the problem posed in the talk
  #link("https://www.youtube.com/watch?v=VzW41m4USGs")[*"7: Design a Rate Limiter"*]
  from the series _Systems Design Interview Questions With Ex-Google SWE_ (channel:
  _Jordan has no life_). The talk designs a rate-limiting service for a public
  API: why limiting is a business feature and not just a shield, the classic
  limiting algorithms, and how to enforce limits correctly across a fleet of
  stateless servers. This chapter follows the same arc, deepened with full
  definitions, capacity mathematics, protocol details, and Rust reference
  implementations.
]

#v(0.4em)

== The Problem Statement

The interview for this one starts deceptively quietly. The interviewer looks up
and says:

#block(inset: (left: 14pt), stroke: (left: 2pt + primary), above: 0.9em, below: 0.9em)[
  #text(style: "italic", size: 10.5pt)[
    "Design a rate limiter. Our public API is used by a million developers, and
    we need to make sure no single caller can overwhelm the service — or use
    more than their plan allows."
  ]
]

If Chapters 1 and 2 felt like designing *products*, this one will feel
different, and it is worth noticing why. You are not designing something a user
ever sees; you are designing a piece of *infrastructure* — a component that
sits in front of every single request your company receives and decides, in
well under a millisecond, whether that request is allowed to proceed. Nobody
visits your rate limiter. Everybody passes through it. That changes what
"good" means: the best limiter is one nobody knows exists until the day it
saves the service.

And here is the trap the prompt lays for you. The *concept* is trivially
simple — "count requests, reject past a threshold" is a five-line program on
one machine, and if you say so out loud you will watch the interviewer's
interest drain away in real time. The difficulty is not the concept; it is the
*setting*. The counting has to happen correctly and cheaply on the hot path of
a distributed system: fifty gateway servers must enforce *one shared limit*
per caller, under heavy concurrency, without adding meaningful latency, and —
the subtlest requirement of all — without the limiter itself ever becoming
the outage it exists to prevent. Every interesting decision in this chapter is
a consequence of those four words: correct, cheap, shared, and safe to fail.

Before we touch any design, let us define the vocabulary precisely, because
half of all weak interview answers on this topic come from confusing two
words that sound interchangeable and are not.

#defterm([Rate limiting / throttling])[
  Controlling the *rate* at which a caller may invoke a system: at most _n_
  requests per time window per identity (API key, user, IP address, tenant).
  Calls beyond the limit are rejected (or queued, or slowed — hence
  _throttling_). Rate limiting serves three distinct masters: *protection*
  (abuse, brute force, accidental stampede), *capacity* (one noisy caller must
  not starve the rest), and *monetization* (usage tiers are limits with a price
  tag). Keep all three in mind: they produce different requirements.
]

It is worth pausing on those three masters, because they will quietly steer
every later trade-off. If your limiter exists for *protection*, approximate
enforcement is fine — a brute-forcer who gets 4% extra attempts is still
thwarted. If it exists for *capacity*, you care mostly about worst-case
fairness, and small per-caller errors average out. But if it exists for
*monetization* — if a paying customer's contract says "1,000 requests per
second" — then the limiter is adjacent to billing, and suddenly every
rejection had better be correct and every admission had better be defensible,
because customers will audit you. Same component, three different accuracy
budgets. When the interviewer asks "how exact does this need to be?", this is
the reasoning they are hoping you will produce unprompted.

#defterm([Quota vs. rate limit])[
  A _quota_ is a budget over a long period ("100,000 calls per month") used for
  billing and plan enforcement; it tolerates approximate, batched accounting.
  A _rate limit_ governs short windows ("100 calls per second") to shape live
  traffic; it must be enforced *now*, on the request's critical path. This
  chapter is about rate limits; Section 3.18 discusses how quotas differ.
]

Why does the distinction matter so much? Because the two systems live in
different worlds. A quota can be computed an hour late from a log file, and
nobody suffers — the invoice is still right. A rate limit computed an hour
late is not a rate limit at all; the damage it was meant to prevent has
already happened. This single fact — *the decision must be made before the
request runs* — is what forces everything you are about to design onto the
critical path, with all the latency and availability pain that implies. Hold
onto it.

== Scope & Clarifying Questions

Look again at the prompt and count what it leaves unspecified. Are we limiting
HTTP calls, messages, bytes, login attempts? One limit for everyone, or tiers?
How exact must enforcement be? What happens when the limiter's own machinery
breaks? The prompt spans everything from login-page brute-force protection to
planetary DDoS absorption, and a design that tries to cover all of that will
cover none of it well. So you narrow it — out loud, with the interviewer, the
way you would scope a real project with a colleague. Watch how the exchange
buys information, question by question:

#tbl(
  (auto, 1fr),
  header: (hcell[Speaker], hcell[Dialogue]),
  body: (
    [*Candidate*], ["What are we limiting — HTTP API calls, or something else like messages or bytes?"],
    [*Interviewer*], ["HTTP requests to our public REST API. Limit per API key."],
    [*Candidate*], ["Are limits the same for everyone, or tiered — free keys vs. paid plans?"],
    [*Interviewer*], ["Tiered. Rules must be configurable per key and per route, and changeable without redeploying anything."],
    [*Candidate*], ["Scale of the API being protected?"],
    [*Interviewer*], ["Peak 200,000 requests per second, spread across a fleet of about 50 stateless gateway servers. One million registered API keys."],
    [*Candidate*], ["How exact must enforcement be? If a key is limited to 100 requests per second, is 101 a scandal?"],
    [*Interviewer*], ["Never reject a caller who is under their limit. Small overshoot during failures is acceptable; systematic overshoot is not."],
    [*Candidate*], ["How much latency may the check add to each request?"],
    [*Interviewer*], ["A millisecond or two at most — this runs on every single request."],
    [*Candidate*], ["And if the limiter's own state store is down — block everything, or let traffic through?"],
    [*Interviewer*], ["Great question. Decide, and defend the decision."],
  ),
)

Read that dialogue again and notice what each answer *unlocks*. The first
answer tells you the identity you count by: the API key, which is convenient
because it arrives with every request and shards beautifully. The second tells
you limits are *configuration*, not code — which means a rules subsystem with
runtime reload is a requirement, not a luxury. The third gives you the numbers
that decide whether one machine can hold all the state (it can, almost — wait
for Section 3.5's arithmetic). The fourth is the most valuable sentence in the
whole interview: it tells you the accuracy requirement is *asymmetric*, and we
will build the entire error policy on that asymmetry. The fifth hands you a
latency budget so small it eliminates whole categories of designs before you
draw a single box. And the last one — well, the last one is the interview, as
the tip below explains.

#block(fill: faint-blue, radius: 6pt, inset: (x: 14pt, y: 10pt), width: 100%)[
  #set text(size: 9.2pt)
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 8pt, weight: "bold", fill: primary, tracking: 0.1em)[AGREED SCOPE]
  #v(4pt)
  Per-API-key rate limits on a public REST API; tiered limits, configurable per
  key and per route, hot-reloadable; enforced *globally* across ~50 stateless
  gateway nodes at *200k RPS* peak; ≤1–2 ms added latency; *no false
  rejections*, bounded overshoot; and an explicit, defended policy for limiter
  failure (fail-open vs. fail-closed — Section 3.15).
]

#tip([The last question is the interview])[
  "What do we do when the limiter breaks?" separates candidates who build
  components from candidates who build *systems*. Ask it yourself if the
  interviewer doesn't — every subsequent design decision (centralized store,
  local fallbacks, timeouts) is downstream of the answer. A limiter that takes
  the API down with it has inverted its purpose: it was hired to absorb
  failures, not to manufacture them. Everything in Sections 3.10 through 3.15
  is shaped by keeping that inversion impossible.
]

== Functional Requirements

Chapter 1 defined functional requirements as the promises the system makes
about what it *does*. Six promises cover this problem — and notice, as you
read them, that each one traces back to a specific line of the dialogue you
just conducted. That traceability is not decoration; in the interview, it is
how you prove the requirements came from the conversation rather than from a
template you memorized.

+ *FR-1 — Enforcement.* A caller exceeding its limit receives HTTP *429 Too
  Many Requests* with a `Retry-After` hint; everyone else passes through.
+ *FR-2 — Configurable rules.* Limits are defined per API key, optionally per
  route or method, with named tiers (free, pro, enterprise); an admin API
  changes them at runtime.
+ *FR-3 — Transparency.* Responses carry the caller's limit state (limit,
  remaining, reset time) in standard headers, so well-behaved clients can
  self-throttle *before* being rejected.
+ *FR-4 — Global enforcement.* The limit holds across the entire gateway
  fleet, not per server — a caller with 100 req/s cannot get 5,000 req/s by
  being load-balanced across 50 nodes.
+ *FR-5 — Burst policy.* Short bursts above the sustained rate are allowed up
  to a defined allowance (real traffic is bursty; rejecting every microburst
  punishes normal clients).
+ *FR-6 — No false rejections.* A caller under its limit is never rejected.
  (Overshoot is a soft failure; false rejection is a hard one — it breaks
  innocent customers deterministically.)

Three of these deserve a second look because they are easy to state and hard
to honor. FR-3 sounds like politeness — and it is — but it is also load
shedding: every header you hand a well-behaved client is a rejected request
that never has to be sent, retried, or counted. Transparency is cheaper than
enforcement. FR-4 is the requirement that kills the naive "count on each
server" design before it starts; Section 3.6 is entirely about why. And FR-5
encodes a fact about real traffic that your algorithm choice must respect:
legitimate callers do not arrive in a smooth stream, they arrive in clumps —
a mobile app syncing after the subway, a CI pipeline fanning out, a cron job
at the top of the minute. An algorithm that treats any clump as abuse will
generate false rejections against perfectly innocent customers, which FR-6
forbids. Keep FR-5 and FR-6 side by side in your head; the tension between
them is exactly what the token bucket in Section 3.7 resolves.

== Non-Functional Requirements

Functional requirements tell you what to build; non-functional requirements
tell you what will get you fired if you build it naively. Three qualities
dominate this problem, and here is the part most candidates miss: *they pull
against each other*. Naming that tension explicitly — before drawing anything
— is half the answer, because it converts three vague adjectives into a
triangle you can navigate deliberately instead of discovering by accident.

#tbl(
  (auto, 1fr),
  header: (hcell[Quality], hcell[Target]),
  body: (
    [*Added latency*], [≤ 1 ms in-region, p99 — the check is on *every* request's critical path],
    [*Accuracy*], [Zero false rejections; steady-state overshoot within ~1% of the limit; degraded-mode overshoot explicitly bounded],
    [*Availability of the API*], [The limiter must never be a new single point of failure: if the limiter fails, the API stays up (fail-open), with a local safety cap],
    [*Scale*], [200k RPS enforcement across ~50 nodes; 1M keys; 100M+ active keys per day tolerable],
    [*Config freshness*], [Rule changes propagate to all gateways within seconds],
  ),
)

Walk the rows and feel the constraints bite. The latency row says the check is
on *every* request's critical path — so whatever machinery you invent, its
cost is multiplied by 200,000 per second and paid by every caller, including
the ones nowhere near their limits. A design that is "only a little slow"
still makes the entire API a little slow, forever. The accuracy row encodes
the asymmetry the interviewer handed you: one direction of error is
forbidden, the other merely rationed — say that sentence in the interview and
watch the room warm to you. The availability row is FR-6's older sibling: the
limiter is a bodyguard, and a bodyguard who shoots the client during a faint
is worse than no bodyguard. Scale and config freshness are quieter, but both
eliminate options — the first rules out single-node solutions, the second
rules out "redeploy to change a limit."

#defterm([False rejection / overshoot])[
  The two ways a limiter can be wrong. A _false rejection_ denies a caller who
  is under the limit — an availability bug, visible and unforgivable.
  _Overshoot_ allows more than the limit — a protection degradation, tolerable
  in small doses. Accuracy requirements should always be stated in this
  asymmetric vocabulary, because the two errors have opposite costs and
  different causes.
]

This asymmetry deserves one more paragraph, because it will quietly govern
Sections 3.12 and 3.15. A false rejection lands on a customer who did
everything right; it is deterministic, reproducible, and it will be reported,
screenshotted, and escalated. Overshoot, by contrast, is statistical — a few
extra requests slip through a window, the backend absorbs them (your capacity
planning already assumed spikes far larger), and nobody notices anything but
a metric. So when you are forced to choose which error your failure mode
commits, you already know the answer: err toward letting traffic through,
bound how much, and make the bound observable. You will see this principle
return wearing different clothes in the failure-mode table of Section 3.15.

#insight([Latency, accuracy, availability: pick the trade-off consciously])[
  *Exact* global counting wants a synchronous round trip to a strongly
  consistent store (latency + availability cost). *Zero added latency* wants
  purely local counting (accuracy cost: 50 nodes × local limit). *Maximum
  availability* wants fail-open everywhere (protection cost). Every real design
  is a point in this triangle; the rest of the chapter locates ours and prices
  it. The skill on display is not finding a design with no costs — there is
  none — it is demonstrating that you know which vertex you are nearest, what
  you paid to stand there, and what it would take to move.
]

== Back-of-the-Envelope Estimation

Before choosing anything, run the numbers — not because the interviewer loves
arithmetic, but because five minutes of estimation here will tell you *what
kind of problem this actually is*, and it is probably not the kind you
expected. Chapter 1 taught the discipline: state every assumption, derive
only what follows.

*Assumptions* (stated, per Chapter 1's discipline):

- Peak gateway traffic: *200k requests/sec*; every request needs exactly one
  limit check.
- 1M registered keys; up to *100M keys active in a day* (many keys are used
  once and idle for weeks).
- Typical limit: 100 req/s per key; token-bucket state per active key is two
  numbers plus the key itself — ~50–60 bytes.
- A modern in-memory store serves ~100k simple ops/sec per shard.

*Derived numbers:*

#tbl(
  (1.25fr, 0.9fr, 1.3fr),
  header: (hcell[Quantity], hcell[Estimate], hcell[How]),
  body: (
    [Check operations], [200k ops/s peak], [one per request; reads+writes combined],
    [Store shards needed], [4–6 (+ replicas)], [200k ops/s ÷ ~100k ops/s per shard, with headroom],
    [State memory (counters)], [≈ 6 GB worst case], [100M active keys × ~60 B],
    [State memory (sliding log)], [≈ 800 GB worst case], [100M keys × up to 1,000 timestamps × 8 B — *infeasible*],
    [Added latency budget], [≤ 1 ms], [one in-region round trip, or zero with local state],
    [Config size], [a few MB], [1M keys × rule record; trivially cacheable everywhere],
  ),
)

Two rows in that table do the real work. The *counters* row says the entire
planet of state fits in six gigabytes — a rounding error on modern hardware.
The *sliding log* row, two lines below, says that one particular algorithm
for the same problem would need eight hundred gigabytes. Same requirement,
same scale, a hundred-fold difference produced purely by *what you choose to
remember per key*. That is your first concrete lesson in algorithm selection,
and it arrives before you have drawn a single box: memory per key is a design
axis, and the sliding log loses on it so badly that it is eliminated on paper.
(This is why Section 3.7 calls the log "the algorithm you describe to show
you know the trade-off, not the one you ship.")

The config row earns a mention too: a few megabytes of rules, read by every
request, means the only sane placement is *inside each gateway's process
memory* — you will see that decision resurface as the rule cache in
Section 3.10's architecture.

#insight([The scarce resource is round trips, not hardware])[
  Six gigabytes of state and a few hundred thousand ops per second are, by
  Chapter 2's standards, nothing. The entire design problem is: *where does the
  check happen relative to the request?* A centralized exact check costs one
  network round trip (~1 ms in-region — the whole budget). A local check costs
  zero round trips but is approximate. Estimation tells you this is a *latency
  topology* problem, not a capacity problem — design accordingly. Candidates
  who skip the estimation step routinely reach for complex distributed
  machinery to solve a capacity problem this system does not have, while
  ignoring the placement problem it does have. Do the arithmetic; let it aim
  your attention.
]

== The Core Challenge: Counting Correctly Under Concurrency

Now you can state the real problem in one sentence: the limit check is a
read-modify-write. *Read* the caller's count, *decide* whether another request
fits, *write* the incremented count. Three steps, and the correctness of the
whole system lives in the seams between them. Two naive placements of this
operation fail, and both failures are instructive — walk through them slowly,
because the production design in Section 3.10 is nothing more than "the naive
design with both failure modes engineered out."

*Naive strategy 1 — count locally on each gateway.* This is the placement your
latency budget loves: no shared state, no network hop, zero added latency, and
nothing to fail. It dies on a single observation: the limit is *per key*, and
a key's requests land on all ~50 gateways, because that is what a load
balancer is *for*. If each node enforces 100 req/s locally, a caller spraying
requests across the fleet effectively holds 100 × 50 = *5,000 req/s* — fifty
times the limit, exactly proportional to your fleet size, and FR-4 lies in
ruins. Your first instinct might be to divide: give each node 100/50 = 2 req/s
locally. But now watch what happens to an innocent caller whose requests
happen to hash onto one node for a while — they are strangled at 2 req/s
against a 100 req/s contract, which is a false rejection, which FR-6 forbids.
Per-instance limits cannot express a global limit. There is no divisor that
fixes this, because the flaw is not the arithmetic — it is that the *state*
is in the wrong place. The count is a property of the caller, so the count
must live somewhere all the caller's requests can reach.

*Naive strategy 2 — a shared counter store with plain reads and writes.* Fine,
you say: put the counters in one shared, in-memory store, and have each
gateway do `GET`, compare, `INCR`. State placement fixed. But you have just
walked into the oldest trap in concurrent programming, and the diagram below
shows it happening in six numbered steps. Two gateways, one shared store, one
unlucky interleaving:

#v(0.3em)
#align(center)[
#canvas(h: 3.9cm)[
  // two lanes: gateway A and gateway B
  #node(0.2cm, 0.05cm, 3.4cm, 0.62cm, [Gateway A], fill: faint, edge: slate, size: 8pt)
  #node(7.0cm, 0.05cm, 3.4cm, 0.62cm, [Gateway B], fill: faint, edge: slate, size: 8pt)
  #node(13.2cm, 0.05cm, 3.4cm, 0.62cm, [Counter store], fill: faint, edge: slate, size: 8pt)
  #lifeline(1.9cm, 0.72cm, 3.75cm)
  #lifeline(8.7cm, 0.72cm, 3.75cm)
  #lifeline(14.9cm, 0.72cm, 3.75cm)
  // A reads
  #arrow(1.95cm, 1.15cm, 14.85cm, 1.15cm, color: primary)
  #glabel(4.4cm, 0.88cm, [1. GET → 99 (limit is 100)], size: 7pt)
  // B reads
  #arrow(8.75cm, 1.95cm, 14.85cm, 1.95cm, color: teal)
  #glabel(9.0cm, 1.68cm, [2. GET → 99 (stale read)], size: 7pt)
  // both decide allow
  #node(0.7cm, 2.45cm, 2.6cm, 0.62cm, [3. 99 < 100: allow], fill: faint-blue, edge: primary, size: 7pt)
  #node(7.5cm, 2.45cm, 2.6cm, 0.62cm, [4. 99 < 100: allow], fill: faint-teal, edge: teal, size: 7pt)
  // both increment
  #arrow(1.95cm, 3.35cm, 14.85cm, 3.35cm, color: primary)
  #glabel(3.2cm, 3.08cm, [5. INCR → 100], size: 7pt)
  #glabel(9.4cm, 3.55cm, [6. INCR → 101 — *both* requests admitted], fg: crimson, size: 7pt)
]]
#v(0.2em)

Take this diagram apart slowly, because understanding exactly *why* it breaks
is the whole interview in miniature. Time flows downward along the three
vertical lifelines — Gateway A on the left, Gateway B in the middle, the
shared counter store on the right — and each horizontal arrow is a network
message. At step 1, Gateway A asks the store for the current count of some API
key and gets 99, against a limit of 100. So far, so good: one slot remains,
and A is entitled to take it. But before A acts on that information, step 2
happens: Gateway B — serving a *different* request from the *same* key, which
is exactly what a load-balanced fleet produces — issues the same `GET` and
receives the same 99. The label calls this a *stale read*, and the word
"stale" is precise: B's 99 was true when it was sent, but B is about to make
a decision whose validity depends on it *remaining* true until B's write
lands, and nothing guarantees that.

Steps 3 and 4 are the quiet catastrophe: both gateways, working from
individually correct information, conclude "99 < 100, allow" — and both are
right *at the moment they decide*. Step 5 lands A's increment, taking the
counter to 100. Step 6 lands B's, taking it to 101 — and now *both* requests
have been admitted into a window with room for one of them. Count the villains
in this story. There are none. Every component did its local job perfectly;
the failure lives entirely in the *gap between check and use*, a gap that
exists only because you split one logical operation across a network. Neither
gateway retried anything, timed anything out, or misread a value — which is
why no amount of retrying, faster hardware, or "being more careful" closes
this hole.

#defterm([Race condition / check-then-act (TOCTOU)])[
  A _race condition_ is a bug whose outcome depends on the uncontrolled
  interleaving of concurrent operations. The specific species above is
  *time-of-check to time-of-use*: the decision ("count is 99, under the limit")
  is based on state that another actor changes before our write lands. Both
  gateways checked honestly; both were correct *at check time*; the limit was
  still exceeded. No amount of retries fixes a TOCTOU hole — the check and the
  update must become *one indivisible operation*.
]

#defterm([Atomicity / compare-and-swap (CAS)])[
  An operation is _atomic_ if it executes entirely or not at all, with no
  observable intermediate state. _Compare-and-swap_ is the primitive form:
  "set this value to V₂ only if it currently equals V₁," performed as one
  hardware/​server-side step. Our options for making the check atomic:
  a server-side script executed atomically by the store (Section 3.12), a CAS
  loop, or a single atomic increment whose *returned value* is the decision
  input. The last two need no scripting at all — `INCR` already returns the
  post-increment count, which *is* the atomic observation we need.
]

Notice the shape of the fix the definitions are steering you toward: do not
try to make the *gap* safe — eliminate the gap. If the store hands you the
post-increment count as the return value of a single atomic operation, then
there is no window in which another gateway's write can invalidate your
information, because the reading *is* the writing. That one idea reappears as
Fix 1 in Section 3.12 and as the Lua script in Section 3.13.

So the core challenge decomposes into two questions that the rest of the
chapter answers, in order: *what exactly is the count* — which algorithm
defines "at most _n_ per window" precisely enough to implement (Section 3.7)
— and *how is the check made atomic across the fleet* (Section 3.12). Keep
them separate in your head. Candidates who conflate them end up comparing
algorithms when asked about races, and vice versa.

== The Algorithm Zoo

Five algorithms cover the entire design space, and it is worth seeing all five
even though you will only ship one — because each is a different answer to a
question the prompt never spelled out: "what does 'at most _n_ per window'
*mean*, exactly?" As you read them, watch how the definition itself is the
design decision. Two algorithms can enforce "100 per minute" and behave
completely differently at the edges.

#defterm([Fixed window counter])[
  Divide time into fixed windows (e.g., each clock minute) keyed
  `rl:{key}:{window_id}`; each request increments the current window's counter;
  reject when it exceeds the limit. O(1) memory per key, one atomic increment
  per request — and a famous flaw: *the boundary burst*. A caller can fire 100
  requests at 0:59.9 and 100 more at 1:00.0 — 200 requests inside one second,
  all legal, because the two bursts sit in different windows.
]

Sit with that flaw for a moment, because it is the single most-asked follow-up
in rate-limiter interviews. The fixed window never lies — every individual
window honored its limit. The problem is that "windows" were your invention,
not the caller's constraint; the caller experienced one second containing 200
admitted requests, and if your backend's capacity plan assumed 100 per minute,
that one second can hurt. The algorithm is *locally* correct and *globally*
surprising, which is exactly the species of bug that passes code review and
fails in production. Section 3.13 includes a test that demonstrates this burst
executing, because a flaw you can reproduce is a flaw you understand.

#defterm([Sliding window log])[
  Store the *timestamp of every request* in a per-key log; on each request,
  drop timestamps older than the window and reject if the remaining count
  reaches the limit. Perfectly accurate, no boundary problem — but memory is
  O(limit) per key. Section 3.5 priced this at ~800 GB at our scale: the log is
  the algorithm you describe to show you know the trade-off, not the one you
  ship.
]

#defterm([Sliding window counter])[
  The fixed-window/log hybrid. Keep the current and previous window counters
  only, and estimate the sliding window as:

  `estimate = current_count + previous_count × (1 − elapsed / window)`

  If 15 seconds of a 60-second window have elapsed, the previous window's 84
  requests count as `84 × 0.75 = 63`. O(1) memory, one increment per request,
  no boundary burst — at the price of being an *estimate* (it assumes the
  previous window's traffic was spread evenly, which is fair on aggregate;
  published analyses put the misclassification rate well under 1%).
]

Read that formula until the intuition clicks, because it is a beautiful piece
of thrift. You cannot afford to remember *when* last window's requests
happened — that was the log's 800 GB mistake — so instead you make one
defensible assumption: however they were spread across the previous window,
only the fraction that overlaps *this* moment's sliding window should still
count against the caller. Fifteen seconds into a minute-long window, the
trailing 45 seconds of the previous window are still "inside" a true sliding
window, so the previous window's count is weighted by 0.75. You are buying
O(1) memory with a single statistical assumption, and the price — a
sub-1% misclassification rate — lands comfortably inside the accuracy budget
you negotiated in Section 3.2. When an interviewer asks "but is it exact?",
the senior answer is: no, and here is the measured size of the error, and here
is why the error is acceptable for this use case.

#defterm([Token bucket])[
  Each key owns a bucket holding up to _b_ tokens, refilled continuously at _r_
  tokens per second. A request takes one token; an empty bucket rejects. The
  parameters map directly onto product language: _r_ is the sustained rate, _b_
  is the burst allowance (FR-5). O(1) memory (two numbers: tokens, last-refill
  timestamp), and refill is computed *lazily* on each request — no timers, no
  background jobs. This is the industry's default for API limiting, and our
  choice; Section 3.11 deep-dives it and Section 3.13 implements it.
]

#defterm([Leaky bucket / GCRA])[
  Requests enter a conceptual queue and "leak" out at a fixed rate; a request
  is admitted only if the queue has room. Where the token bucket *permits*
  bursts, the leaky bucket *forbids* them — output is perfectly smooth. Its
  stateless formulation is the *Generic Cell Rate Algorithm*: store one
  theoretical-arrival-time per key; admit if now is not earlier than that time
  minus tolerance. The right tool when you meter *into* a fragile downstream
  (payment gateways, SMS providers), overkill for request admission.
]

The contrast in that last definition is the exam answer: token bucket and
leaky bucket are mirror images, and choosing between them is choosing *who
feels the burst*. Token bucket absorbs bursts at the limiter and releases
them at the downstream — good when the downstream is your own robust API and
bursts are a product feature (FR-5 says they are). Leaky bucket smooths bursts
away entirely — good when the downstream is a third party who will fail or
fine you for clumpy traffic. Same O(1) memory, opposite temperament. If the
interviewer ever asks you to "rate limit calls to Stripe's API," reach for
leaky/GCRA without hesitation and say why.

Here is the token bucket drawn as a machine, because it is genuinely easier
to picture than to parse:

#v(0.3em)
#align(center)[
#canvas(h: 4.6cm)[
  // token bucket illustration
  // bucket body
  #node(5.4cm, 1.5cm, 3.2cm, 2.6cm, [], fill: white, edge: primary, radius: 6pt)
  // tokens inside
  #place(dx: 5.75cm, dy: 3.35cm, circle(radius: 0.21cm, fill: teal))
  #place(dx: 6.35cm, dy: 3.35cm, circle(radius: 0.21cm, fill: teal))
  #place(dx: 6.95cm, dy: 3.35cm, circle(radius: 0.21cm, fill: teal))
  #place(dx: 7.55cm, dy: 3.35cm, circle(radius: 0.21cm, fill: teal))
  #place(dx: 6.05cm, dy: 2.72cm, circle(radius: 0.21cm, fill: teal))
  #place(dx: 6.65cm, dy: 2.72cm, circle(radius: 0.21cm, fill: teal))
  #place(dx: 7.25cm, dy: 2.72cm, circle(radius: 0.21cm, fill: white, stroke: 0.9pt + code-edge))
  #glabel(6.35cm, 2.15cm, [capacity _b_ = 8], fg: slate, size: 7.4pt)
  // refill drip from top
  #arrow(7.0cm, 0.35cm, 7.0cm, 1.45cm, color: teal)
  #glabel(7.25cm, 0.5cm, [refill _r_ tokens/s], fg: teal.darken(12%), size: 7.4pt)
  // request taking a token
  #arrow(1.3cm, 2.6cm, 5.35cm, 2.9cm, color: slate)
  #glabel(0.3cm, 2.15cm, [request: needs 1 token], fg: slate, size: 7.4pt)
  // outcomes
  #node(10.1cm, 1.15cm, 2.9cm, 0.8cm, [token present \ → request proceeds], fill: faint-teal, edge: teal, size: 7.2pt)
  #node(10.1cm, 2.65cm, 2.9cm, 0.8cm, [bucket empty \ → 429 + Retry-After], fill: faint-red, edge: crimson, size: 7.2pt)
  #arrow(8.75cm, 2.0cm, 10.05cm, 1.6cm, color: teal)
  #arrow(8.75cm, 3.4cm, 10.05cm, 3.1cm, color: crimson)
  #glabel(0.3cm, 4.25cm, [Two numbers per key — `tokens`, `last_refill` — and no timers: refill is computed when a request arrives.], size: 7pt)
]]
#v(0.2em)

Walk around the diagram once, slowly, because every element carries a design
decision. The large outlined box in the center is the bucket itself, labeled
with capacity _b_ = 8 — the burst allowance from FR-5 drawn as physical
volume. Inside it you can count seven teal discs: full tokens, each one
permission for exactly one request. The eighth disc is drawn hollow, and that
is not decoration: it marks the headroom between *current balance* and
*capacity*, the visual form of the `min(b, ...)` cap you will meet in the
pseudocode of Section 3.11. Tokens cannot accumulate past the rim; a caller
who goes quiet for an hour banks eight requests, not eight hundred. That cap
is what stops "saving up" from becoming an unlimited liability, and if an
interviewer asks "can a user hoard quota by staying idle?", this hollow disc
is your answer.

Now the two arrows feeding the machine. From the top, a teal arrow drips
downward into the bucket: the refill, _r_ tokens per second — the sustained
rate from your requirements, drawn as a faucet. From the left, a slate arrow
carries an incoming request into the bucket's wall, labeled with its cost:
every request must withdraw exactly one token to proceed. The bucket is where
those two flows negotiate.

On the right, the two outcomes split. If the withdrawal succeeds — at least
one teal disc present — the upper arrow carries the request onward and the
API serves it. If the bucket is empty, the lower, crimson arrow ends in the
rejection box: HTTP 429 plus a `Retry-After` hint. And here is the detail to
say out loud, because it is the caption under the whole figure: *there are no
timers anywhere in this machine*. The refill arrow is not a background job
topping the bucket up on a schedule; the bucket's contents are recomputed
lazily, from two stored numbers — `tokens` and `last_refill` — at the
instant each request arrives. Time never has to be *advanced*; it only has to
be *read*. Section 3.11 turns this picture into five lines of pseudocode, and
Section 3.13 turns the pseudocode into Rust with a test proving eight threads
cannot collectively extract more than the capacity.

The comparison that ends the discussion — every candidate should be able to
reproduce this table from a standing start:

#tbl(
  (auto, auto, auto, auto, 1fr),
  header: (hcell[Algorithm], hcell[Memory/key], hcell[Exact?], hcell[Bursts?], hcell[Notes]),
  body: (
    [Fixed window], [O(1)], [window-granular], [2× at boundary], [Simplest; the boundary burst is the interview trap],
    [Sliding log], [O(limit)], [exact], [no], [Memory kills it at scale (Section 3.5)],
    [Sliding counter], [O(1)], [~1% error], [smoothed], [Best accuracy-per-byte when bursts are unwanted],
    [*Token bucket*], [O(1)], [exact accounting], [*allowed* up to _b_], [*Our choice*: burst policy is a product feature here],
    [Leaky / GCRA], [O(1)], [exact pacing], [forbidden], [Choose when downstream needs smooth flow],
  ),
)

Read the table as an elimination bracket, not a catalog. Sliding log: dead on
memory in Section 3.5. Leaky bucket: wrong temperament — your FR-5 wants
bursts *allowed*, not smoothed away. Fixed window: alive and O(1)-cheap, but
carrying the boundary-burst flaw you just dissected. Sliding counter: fixes
the burst, pays with a ~1% estimation error, and — subtle but real — still
*thinks in windows*, so its burst tolerance is incidental rather than
expressible. Token bucket: O(1), exact accounting of what it tracks, and the
only row where "bursts allowed up to _b_" appears as a *parameter you can
hand to product managers* instead of an accident of the algorithm. That last
property is the decider: when your limit is a product feature (tiered plans,
FR-2), the algorithm's knobs should speak the product's language. Rate and
burst do; window-weights do not.

== API & Protocol Design

Here is a small mental shift that separates experienced candidates from
checklist readers: a rate limiter's "API" is mostly *other people's
responses*. Nobody calls your limiter; your limiter annotates — or terminates
— everybody else's calls. So the contract that matters is not an endpoint you
expose but a behavior you impose on every response the API emits, whether the
answer is "here is your data" or "slow down." Design that behavior with the
same care you would give a real endpoint, because a million client
applications will be written against it.

#defterm([HTTP 429 / Retry-After])[
  Status *429 Too Many Requests* (RFC 6585) means "you, specifically, are
  calling too fast." The *`Retry-After`* header tells the caller how many
  seconds to wait before retrying. Together they convert a rejection into a
  negotiation: a well-built client backs off exactly as instructed instead of
  hammering harder. A limiter that rejects without `Retry-After` trains
  clients to retry blindly — worse for everyone.
]

Underline the word *negotiation*. A bare 429 is an insult: it spends the
client's request, tells it nothing useful, and — here is the operational
consequence — invites an immediate retry, because most HTTP clients are
written to treat unknown failures as transient. Multiply that by a fleet of
clients and your limiter has *created* a retry storm in the act of preventing
one. `Retry-After` defuses this by giving the client a cheaper action than
retrying: waiting a known number of seconds. You are not just rejecting load;
you are *scheduling* it into the future, at a moment you know you can absorb.
The same logic, writ large, is why Section 3.15's failure table worries about
"retry storms after a 429 wave" — rejections reshape traffic, and a good
contract shapes it *away* from the wall.

The transparency headers (FR-3) complete the contract:

#tbl(
  (auto, 1fr),
  header: (hcell[Header], hcell[Meaning]),
  body: (
    [`X-RateLimit-Limit`], [The caller's limit for this route, e.g. `100`],
    [`X-RateLimit-Remaining`], [Requests left in the current window / tokens left],
    [`X-RateLimit-Reset`], [When the budget refills (epoch seconds or seconds-from-now)],
    [`Retry-After`], [On 429 only: minimum wait before retry, seconds],
  ),
)

Notice the division of labor across the four rows. `Limit` and `Reset` are
*static context* — they let a client plan. `Remaining` is the load-bearing
one: a client that watches it can throttle *itself* before ever seeing a 429,
which converts your enforcement problem into their scheduling problem —
exactly the outsourcing FR-3 promised. And `Retry-After` appears only on the
429 itself, because only then does the client need a *command*, not context.
Every header earns its place; resist the urge to add more.

(An IETF draft standardizes these as `RateLimit-*` fields; the `X-` forms
remain the de-facto convention. Either is defensible — knowing both exist is
the point. If the interviewer asks which you would ship, say: `X-` forms
today for compatibility, the standard fields alongside them as they finalize,
and both documented. Ten seconds, and you have signaled that you read RFCs
*and* ship product.)

A rejection response, end to end — read it the way a client developer would,
top to bottom, asking at each line "what can I do with this?":

```json
HTTP/1.1 429 Too Many Requests
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 45
Retry-After: 1
Content-Type: application/json

{ "error": "rate_limit_exceeded", "limit": 100, "window": "1s", "plan": "free" }
```

The status line tells the client *what happened*; the headers tell it *when to
come back*; and the JSON body tells it *why* — including, deliberately, the
word `"free"`. That last field is monetization doing quiet work: the error
message itself names the caller's plan, which is both a debugging aid and a
gentle, perfectly-timed upsell delivered at the exact moment the caller feels
the limit's cost. Section 3.17 will note that the list of most-rejected keys
doubles as the sales team's lead list; this body is where that observation
starts.

The *admin* surface (FR-2, FR-6) is ordinary REST by comparison: rules as
records — `{ api_key or tier, route pattern, algorithm, limit/rate, burst,
window }` — created and updated through an admin API, versioned, and pushed
to every gateway within seconds (Section 3.10). Two properties matter more
than the endpoints themselves. *Versioned*, because a bad rule push must be
reversible in seconds — you will see "bad rule pushed" in the failure table
of Section 3.15, and "roll back" is only an option if history exists. And
*pushed*, not polled, because "seconds" of propagation lag is hard to
guarantee when fifty gateways each poll on their own schedule; a push
invalidates everyone at once. Keep this in mind when Section 3.10 draws the
rule fan-out as a first-class arrow.

== Data Model & Storage

Only three kinds of data exist in this entire system, and the table below is
short enough that you should be suspicious of any design that needs a fourth.
Read the *Store* column as a series of placement decisions, each one forced
by the access pattern in the *Contents* column:

#tbl(
  (auto, 1.5fr, 1.1fr),
  header: (hcell[Entity], hcell[Contents], hcell[Store]),
  body: (
    [Limit state], [`rl:{api_key}:{route}` → `{tokens, last_refill_ms}` (bucket) or window counters; TTL = window so idle keys self-clean], [In-memory store cluster (Redis-class), sharded by key hash],
    [Rule], [tier or key → {algorithm, rate, burst, window, route pattern}; versioned], [Durable KV/relational store, fanned out to gateway-local caches],
    [Quota ledger], [monthly usage per key for billing], [Append-only log → batch aggregation; *not* on the request path (Section 3.2)],
  ),
)

Row by row. *Limit state* is tiny (two numbers per key, from Section 3.7),
mutated on every request, and worthless once its window passes — so it lives
in an in-memory cluster where a read-modify-write costs microseconds, sharded
by key hash because every check touches exactly one key (no cross-shard
transactions on the hot path — ever). *Rules* are the opposite temperament:
read constantly, written rarely, and disastrous to lose — so they live in a
durable store behind the admin API, with copies pushed into gateway memory.
And the *quota ledger* — monthly billing usage — is listed here mostly to be
exiled: it flows to an append-only log and batch jobs, explicitly *not* on
the request path, honoring the quota-versus-rate-limit wall you built in
Section 3.1. If you find yourself incrementing billing counters inside the
limit check, stop: you have put an hour-tolerant system inside a
millisecond-budget one, and the millisecond budget will lose.

Two decisions to name, because interviewers probe both. First, state entries
carry a *TTL* (Chapter 2) equal to the window, so the 100M-active-keys problem
from Section 3.5 is self-cleaning: a key used once at 3 a.m. and never again
simply evaporates when its window passes. No garbage collector, no compaction
job, no "state cleanup" cron quietly becoming a second system to operate —
the store's expiry machinery, which you are already paying for, does it for
free. Second, rules are cached *on each gateway* with push-based invalidation
— because a per-request rule lookup must never add a second network hop to a
budget that only contains one.

== High-Level Architecture

Everything you have decided so far — one shared atomic store for state,
rules in gateway memory, decisions in middleware — assembles into a
remarkably small picture. Draw it in the interview exactly like this, left to
right, and narrate as you draw:

#v(0.3em)
#align(center)[
#canvas(h: 5.9cm)[
  #node(0.2cm, 0.1cm, 3.0cm, 0.85cm, [API clients], fill: faint, edge: slate, size: 8pt)
  #node(4.2cm, 0.1cm, 3.2cm, 0.85cm, [Load balancer], fill: white, edge: slate, size: 8pt)
  #node(8.6cm, 0.0cm, 4.2cm, 1.05cm, [Gateway fleet (~50 nodes) \ rate-limit middleware], fill: faint-blue, edge: primary, size: 7.6pt)
  #node(14.0cm, 0.1cm, 2.8cm, 0.85cm, [Backend services], fill: white, edge: slate, size: 7.8pt)
  #node(8.6cm, 2.2cm, 4.2cm, 0.9cm, [Limit-state store \ Redis-class, sharded], fill: white, edge: teal, size: 7.6pt)
  #node(0.2cm, 2.3cm, 3.6cm, 0.85cm, [Rules store \ durable, versioned], fill: white, edge: slate, size: 7.6pt)
  #node(0.2cm, 4.3cm, 3.6cm, 0.8cm, [Admin API], fill: white, edge: slate, size: 8pt)
  #node(5.0cm, 4.3cm, 4.4cm, 0.8cm, [Rule cache on each gateway \ (push invalidation)], fill: white, edge: amber.darken(15%), size: 7.2pt)
  #node(11.0cm, 4.3cm, 3.6cm, 0.8cm, [Metrics pipeline \ rejects, overshoot], fill: white, edge: slate, size: 7.2pt)
  // arrows
  #arrow(3.25cm, 0.52cm, 4.15cm, 0.52cm)
  #arrow(7.45cm, 0.52cm, 8.55cm, 0.52cm)
  #arrow(12.85cm, 0.52cm, 13.95cm, 0.52cm)
  #arrow(10.7cm, 1.08cm, 10.7cm, 2.15cm, color: teal)
  #arrow(3.85cm, 2.72cm, 8.55cm, 2.65cm, dashed: true, color: slate)
  #arrow(2.0cm, 3.18cm, 2.0cm, 4.25cm)
  #arrow(3.85cm, 4.7cm, 4.95cm, 4.7cm, color: amber.darken(15%))
  #arrow(9.4cm, 4.3cm, 10.2cm, 1.08cm, color: amber.darken(15%), dashed: true)
  #arrow(12.4cm, 1.08cm, 12.9cm, 4.25cm, dashed: true, color: slate)
  // labels
  #glabel(10.9cm, 1.55cm, [1 atomic check (≤1 ms)], fg: teal.darken(12%), size: 6.9pt)
  #glabel(4.6cm, 2.35cm, [rule fan-out], size: 6.9pt)
  #glabel(12.6cm, 2.6cm, [429 + headers], size: 6.9pt)
  #glabel(0.2cm, 5.35cm, [The middleware is a read-modify-write on the hot path: one atomic store op per request, rules read locally.], size: 7pt)
]]
#v(0.2em)

Now walk the picture the way a request experiences it, because the diagram is
really two stories layered on one canvas — a *request story* running left to
right along the top, and a *control story* running along the bottom — and
keeping them separate in your narration is what makes the design sound
obvious instead of improvised.

*The request story* starts at the top-left, where API clients send traffic
into a load balancer. The balancer's only job here is spray: it spreads each
key's requests across the ~50-node gateway fleet, which is precisely why
FR-4 forced the count to live off the nodes — remember, this spraying is what
killed naive strategy 1 back in Section 3.6. The request lands on a gateway,
and the *first code it touches* is the rate-limit middleware inside the big
blue box. That middleware does exactly two lookups. First, a local one: which
rule applies to this key and route? That answer is already in process memory
— zero network hops — for reasons the control story will explain in a
moment. Second, the single remote operation the design allows itself: the
teal arrow dropping straight down from the gateway box into the *limit-state
store*, labeled "1 atomic check (≤1 ms)". This is the atomic increment or
server-side script of Section 3.12, and it is the only synchronous dependency
the hot path tolerates. The store answers allow-or-deny. On allow, the request
continues rightward into the backend services, and the response flows back
carrying the transparency headers of Section 3.8. On deny, the request never
reaches the backend at all; the dashed slate arrow angling down from the
gateway to the bottom-right labeled "429 + headers" is the rejection path —
the API's data plane is protected because the rejection happens *before* any
backend work is spent.

*The control story* runs along the bottom row and explains how the middleware
always knows the current rules without ever asking at request time. An
operator (or a pricing change, or an abuse response) updates rules through
the *Admin API* at bottom-left, which writes versioned records into the
durable *rules store* above it. From there, a dashed "rule fan-out" arrow
pushes the new rules toward every gateway, and the amber arrows complete the
circuit: rules land in the *rule cache on each gateway* — the box at
bottom-center — and a dashed amber arrow rises from that cache back up into
the gateway fleet, which is the picture's way of saying "the middleware reads
its rules from local memory." Trace any request and you will find it never
touches the bottom row: config changes propagate in seconds, but they travel
on a completely separate path from the traffic they govern. That separation is
not tidiness; it is what lets you push a bad rule, roll it back, and never
add a microsecond to a single request while doing it.

Finally, the quiet dashed arrow into the *metrics pipeline* at bottom-right:
every decision — allow or deny — is emitted as an event off the hot path.
It looks optional. It is not. Section 3.17 will argue that for a limiter,
observability *is* the correctness evidence: a system whose job is to reject
traffic cannot distinguish "working" from "broken" without these counters,
because both states look like rejections from the outside.

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Component], hcell[Responsibility], hcell[Why it is shaped this way]),
  body: (
    [Rate-limit middleware], [First code every request touches on the gateway: load rule → atomic check → pass or 429], [Middleware placement means *no backend code changes* and one consistent policy for every route],
    [Limit-state store], [Atomic counters/buckets for all active keys], [One shared store is what makes the limit *global* (FR-4); sharded by key hash, replicated for availability],
    [Rules store + admin API], [Versioned rule records; runtime updates], [Config is tiny and read-hot: push it to gateway memory, never fetch per request],
    [Gateway rule cache], [Rules in process memory, invalidated by push], [Zero added hops for config (Section 3.9)],
    [Metrics pipeline], [Every decision emitted as an event], [Section 3.17: you cannot tune what you cannot see],
  ),
)

Read the middle column as the minimal job description of each box, and the
right column as the *argument* for each box's existence — because in the
interview, every box you draw will be challenged with "why is this here?", and
the right column is your rehearsed answer. The middleware row's argument is
worth memorizing as a sentence: putting the check in middleware means every
route gets one consistent policy *and no backend team changes a line of code*.
Adoption costs decide whether infrastructure actually gets used; a limiter
that requires every service to integrate it will be integrated by none of
them.

#insight([The one-op rule])[
  Per request, the design allows itself *exactly one* atomic store operation
  and zero synchronous config reads. Everything — the algorithm choice (O(1)
  state), the TTL self-cleaning, the gateway rule caches — exists to preserve
  that invariant. When an interviewer pushes on any component, return to it:
  "that would cost a second op on the hot path, and the one-op rule is what
  buys the millisecond budget." A single crisp invariant you defend
  consistently is worth more than five features you cannot.
]

== Deep Dive: The Token Bucket, Precisely

You have the picture (Section 3.7's bucket) and the placement (Section 3.10's
one-op rule). Now you need the machine itself, stated precisely enough that
two engineers implementing it on different continents produce byte-identical
behavior. The token bucket's deepest elegance is that *time is never advanced
by a timer* — nothing ticks, nothing fires, nothing drifts. State is two
numbers, updated lazily when a request arrives:

+ `tokens` — current balance, capped at capacity _b_.
+ `last_refill_ms` — when the balance was last recomputed.

On each request at time `now`:

```
elapsed_s   = (now - last_refill_ms) / 1000
tokens      = min(b, tokens + elapsed_s * r)   // lazy refill, capped
last_refill = now
if tokens >= 1: tokens -= 1; ALLOW (remaining = floor(tokens))
else:           DENY  (retry_after_ms = (1 - tokens) / r * 1000)
```

Read the five lines as three acts. The first two lines *catch the balance up
to the present*: however many seconds have passed since the last request,
that many refill-rate's worth of tokens have dripped in — computed
arithmetically, not simulated, which is why no timer exists. The `min(b, ...)`
cap is the hollow disc from the diagram doing its work: idleness banks at
most one full burst. The third act is the decision, and notice how much falls
out of it for free: on denial, `retry_after_ms` is exactly the time until one
token will exist — the `Retry-After` header of Section 3.8 computed from the
same arithmetic that made the decision, so the hint you give clients can never
disagree with the policy you enforce.

Reading the parameters as product language: _r_ = sustained rate ("100 req/s"),
_b_ = burst allowance ("…with bursts up to 150"). When product asks for a new
plan tier, they speak in exactly these two numbers — the algorithm has no
third knob, which means there is nothing for a well-meaning operator to
misconfigure at 2 a.m.

A worked trace (limit 5 req/s, burst 8), to have in hand at the whiteboard —
run it yourself once, right now, because being able to *simulate your own
algorithm out loud* is what separates "I read about token buckets" from "I
can operate one":

#tbl(
  (auto, auto, auto, 1fr),
  header: (hcell[Time], hcell[Event], hcell[Balance after], hcell[Why]),
  body: (
    [`t = 0.0 s`], [8 requests arrive together], [8 → 0], [Full bucket: all 8 pass — the burst allowance],
    [`t = 0.0 s`], [9th request], [0], [Empty: 429, `Retry-After: 1` (1/5 s until one token)],
    [`t = 1.0 s`], [1 request], [5 → 4], [One second refilled 5 tokens],
    [`t = 3.0 s`], [1 request], [8 → 7], [Two more seconds refill 10, capped at capacity 8],
  ),
)

The fourth row is the one interviewers probe. Two idle seconds earned 10
tokens, but the balance shows 8 — the cap fired. Then ask yourself the
follow-up they will ask you: *is the cap right?* For this design, yes —
uncapped banking would let a dormant key return after a week with a
million-token balance and become a denial-of-service against your own
backend. The cap is the moment the token bucket stops being an accounting
device and starts being a safety device.

#pitfall([Refill by background timer])[
  Implementing refill as a cron or timer per key means a million timers, clock
  drift between timer and request paths, and state that never cleans itself up.
  Lazy refill has none of these: no timers, no drift (one clock, read once per
  request), and a TTL on the key reclaims idle state for free. If you find
  yourself scheduling work per key, you have re-invented the sliding log's
  costs inside the token bucket. This is the single most common implementation
  mistake in take-home versions of this problem — the algorithm looks like it
  "ticks," so people build a ticker. It does not tick; it *settles*, on
  demand, when asked.
]

#notebox([One clock, and make it monotonic])[
  Distributed machines disagree about wall-clock time (clock skew), and even on
  one machine the wall clock can jump backwards (NTP corrections) — a backward
  jump would *refund* tokens. Two defenses: (1) perform the bucket update
  *inside the store* with a server-side script, so one clock governs every
  gateway (Section 3.12); (2) where local time is unavoidable, read a
  *monotonic* clock (one that never moves backwards), as Section 3.13's Rust
  does. The refund scenario is worth picturing once: NTP notices the gateway is
  400 ms fast and steps the clock back; every bucket on the host suddenly
  computes a *negative* elapsed time; if your code adds elapsed tokens without
  guarding the sign, you have just minted free requests fleet-wide. One
  subtraction, done carelessly, becomes a money-losing bug — because for
  tiered plans, tokens are revenue.
]

== Deep Dive: Distributed Enforcement & the Race

Section 3.6's race came from splitting *check* and *update* across a network —
two round trips with a decision made in the no-man's-land between them. You
now know the cure in principle ("make it one indivisible operation"); this
section gives you the three production-grade forms that cure actually takes,
in increasing order of sophistication, and — more importantly — teaches you
when each is *allowed*.

*Fix 1 — atomic increment-as-decision.* For window algorithms, one atomic
`INCR` already returns the post-increment value: the store's returned count
*is* the check. Reject when the returned value exceeds the limit. One round
trip, no client-side race, and the first increment of a window sets the key's
TTL in the same atomic step (self-cleaning, from Section 3.9). Admire the
economy: the observation and the mutation are the same network message, so
the TOCTOU gap has literally nowhere to exist. Fixed window and sliding
counter ship this way.

*Fix 2 — server-side script for read-modify-write.* The token bucket needs
more than an increment — it needs read-compute-write (refill from the stored
timestamp, compare against one, decrement). Executing that sequence *on the
store*, as one atomic script, removes the race identically: the store
serializes script execution, so no two requests ever observe the same
balance. Think of it as moving the `Mutex` from Section 3.13's single-process
code into the one place all fifty gateways share. Section 3.13 shows the
client side, with the script embedded as data — and the embedding matters:
the gateway ships *code to the data*, once, instead of shipping *data to the
code* three times per request.

*Fix 3 — approximate local counting.* The radical option, and the one that
separates interviewees who have operated systems from those who have only
diagrammed them: skip the store on the hot path entirely. Each gateway keeps
local counters and periodically *publishes* them; a background aggregator
broadcasts fleet-wide totals, and each node denies when
`local_estimate + fleet_total ≥ limit`. Zero added latency, and the store is
off the critical path (fail-open for free) — but between syncs, overshoot is
bounded by roughly `limit × (sync_lag / window)`. Choose it when protection
matters more than precision (abuse mitigation at enormous scale); *never* for
billing-adjacent limits, because an approximate count next to an invoice is a
lawsuit with extra steps. Notice, though, that Fix 3 is not a rejection of
the design — it is the design's *degraded mode promoted to a feature*. You
will meet it again in Section 3.15 as the fallback when the store fails, and
recognizing that your emergency plan and your extreme-scale plan are the same
plan is a genuinely senior observation.

#tbl(
  (auto, auto, auto, 1fr),
  header: (hcell[Approach], hcell[Latency], hcell[Accuracy], hcell[Choose when]),
  body: (
    [Centralized, atomic op], [+1 RTT (~1 ms)], [exact], [Default. Paid tiers, contractual limits],
    [Centralized, non-atomic], [+1 RTT], [races under concurrency], [Never — Section 3.6],
    [Local + async sync], [~0], [bounded overshoot], [Abuse protection at extreme scale, or store-failure fallback],
    [Sticky routing + local], [~0], [near-exact], [Only if your load balancer can pin keys to nodes — fragile on failover],
  ),
)

The fourth row deserves a word, because it tempts people: if the load balancer
could pin each API key to one gateway, local counting would be exact and
free. It works — until a gateway dies, the pin breaks, the traffic re-hashes,
and your "exact" limit scatters across whatever node caught it, with all
accumulated state stranded on the corpse. You have rebuilt naive strategy 1
with extra machinery and a failover bug. Renting exactness from your load
balancer's stability is renting, not owning; say so if it comes up.

#tip([Say the quiet part: exactness is a product decision])[
  "How exact does this need to be?" has no technical answer — it depends on
  whether the limit protects revenue (exact: paid tiers), infrastructure
  (approximate fine: abuse), or other users' experience (approximate fine:
  fairness). Volunteering this framing turns an algorithm comparison into a
  senior-level requirements discussion. The interviewer cannot teach you
  anything about token buckets you have not already read; what they are
  testing is whether you know that the *choice among* them is a business
  input wearing a technical costume.
]

== Deep Dive: Rust Reference Implementations

Time to make all of it executable. Three pieces follow, and each exists to
*prove* a claim the prose has been making — read them that way, as arguments
with compilers. The token bucket comes with deterministic-time tests, because
a time-dependent algorithm tested against the real clock is a superstition,
not a test. The fixed-window/sliding-counter pair demonstrates the boundary
burst and its cure side by side, so the flaw from Section 3.7 stops being a
story and becomes a failing-then-passing assertion. And the fleet-wide check
embeds the server-side script as data, showing exactly where the atomicity of
Section 3.12 physically lives.

=== Token bucket with a testable clock

Time is injected through a `Clock` trait so tests control it exactly — the
difference between a test that *suggests* correctness and one that *proves*
it. Watch for the `Mutex` around the state tuple: within one process, that is
what makes the read-modify-write of Section 3.6 indivisible. (Across fifty
processes it cannot help you — that is what the third listing is for.)

```rust
use std::sync::Mutex;

/// Time source, injected so tests can control it (Section 3.11).
pub trait Clock: Send + Sync {
    fn now_ms(&self) -> u64;
}

/// Production clock: monotonic — it can never jump backwards and refund
/// tokens (Section 3.11's note).
pub struct MonotonicClock(std::time::Instant);
impl MonotonicClock {
    pub fn new() -> Self { Self(std::time::Instant::now()) }
}
impl Clock for MonotonicClock {
    fn now_ms(&self) -> u64 { self.0.elapsed().as_millis() as u64 }
}

/// The decision every algorithm returns: pass, or reject with a retry hint
/// that becomes the Retry-After header (Section 3.8).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Allow { remaining: u64 },
    Deny { retry_after_ms: u64 },
}

/// Token bucket (Section 3.7): `capacity` tokens, refilled lazily at
/// `refill_per_sec`. The Mutex makes the read-modify-write atomic *within*
/// one process; Section 3.12 handles the fleet-wide version.
pub struct TokenBucket<C: Clock> {
    capacity: f64,
    refill_per_sec: f64,
    state: Mutex<(f64, u64)>, // (tokens, last_refill_ms)
    clock: C,
}

impl<C: Clock> TokenBucket<C> {
    pub fn new(capacity: f64, refill_per_sec: f64, clock: C) -> Self {
        let now = clock.now_ms();
        Self { capacity, refill_per_sec,
               state: Mutex::new((capacity, now)), clock }
    }

    pub fn try_acquire(&self) -> Decision {
        let now = self.clock.now_ms();
        let mut s = self.state.lock().unwrap();
        let elapsed_s = (now - s.1) as f64 / 1000.0;
        let mut tokens = (s.0 + elapsed_s * self.refill_per_sec).min(self.capacity);
        s.1 = now;
        if tokens >= 1.0 {
            tokens -= 1.0;
            s.0 = tokens;
            Decision::Allow { remaining: tokens as u64 }
        } else {
            s.0 = tokens;
            let wait_ms = ((1.0 - tokens) / self.refill_per_sec * 1000.0).ceil() as u64;
            Decision::Deny { retry_after_ms: wait_ms.max(1) }
        }
    }
}
```

Map the code back onto Section 3.11's five pseudocode lines and you will find
a one-to-one correspondence — plus two Rust-specific choices worth being able
to defend. The `Decision` enum forces every caller to *handle* both outcomes:
there is no way to "forget" the deny path, because the compiler will make you
match on it. And the balance is stored even on denial (`s.0 = tokens` in the
`else` arm) — a denied request still *consumed time*, and the fractional
token it earned during its wait must be banked, or a caller hammering an
empty bucket would find their retries perpetually starved by rounding. Small
line, real behavior.

Tests, including the concurrency proof that `Mutex` buys us exactly-once
accounting across threads:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, atomic::{AtomicU64, Ordering}};

    /// A clock the test controls explicitly.
    struct TestClock(AtomicU64);
    impl Clock for TestClock {
        fn now_ms(&self) -> u64 { self.0.load(Ordering::SeqCst) }
    }

    #[test]
    fn burst_then_reject_then_refill() {
        let clock = Arc::new(TestClock(AtomicU64::new(0)));
        let b = TokenBucket::new(8.0, 5.0, clock.clone()); // 8 burst, 5/s
        for i in 0..8 {
            assert!(matches!(b.try_acquire(), Decision::Allow { .. }), "burst #{i}");
        }
        // Bucket empty: denied, and told to wait 1/5s for one token.
        assert_eq!(b.try_acquire(), Decision::Deny { retry_after_ms: 200 });
        // One second passes: 5 tokens return (capped at capacity).
        clock.0.store(1000, Ordering::SeqCst);
        assert_eq!(b.try_acquire(), Decision::Allow { remaining: 4 });
    }

    #[test]
    fn exactly_capacity_across_threads() {
        let clock = Arc::new(TestClock(AtomicU64::new(0)));
        let b = Arc::new(TokenBucket::new(100.0, 1.0, clock));
        let allowed = Arc::new(AtomicU64::new(0));
        std::thread::scope(|s| {
            for _ in 0..8 {
                let (b, allowed) = (b.clone(), allowed.clone());
                s.spawn(move || {
                    for _ in 0..25 {   // 8 threads x 25 = 200 attempts
                        if matches!(b.try_acquire(), Decision::Allow { .. }) {
                            allowed.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                });
            }
        });
        assert_eq!(allowed.load(Ordering::SeqCst), 100); // never one more
    }
}
```

The second test is the one to talk about in the room. Eight threads, 200
attempts, capacity 100, frozen clock — and the assertion is not "roughly
100" or "at most 105" but *exactly* 100, every run, no flakiness. That is the
entire promise of Section 3.6's fix, demonstrated in miniature: when the
read-modify-write is indivisible, the interleaving of threads stops
mattering. If you ever doubt whether a mutex is "worth it" on a hot path,
remember that this assertion is what you are buying.

=== Fixed window, its boundary burst, and the sliding counter's cure

```rust
/// Fixed window counter (Section 3.7): one counter per window per key.
pub struct FixedWindow {
    window_ms: u64,
    count: u64,
    window_start_ms: u64,
}

impl FixedWindow {
    pub fn new(window_ms: u64) -> Self {
        Self { window_ms, count: 0, window_start_ms: 0 }
    }

    pub fn try_acquire(&mut self, now_ms: u64, limit: u64) -> bool {
        let w = now_ms / self.window_ms * self.window_ms;   // window start
        if w != self.window_start_ms {                      // new window
            self.window_start_ms = w;
            self.count = 0;
        }
        self.count += 1;
        self.count <= limit
    }
}

/// Sliding window counter: previous window, weighted by overlap (Section 3.7).
pub struct SlidingWindowCounter {
    window_ms: u64,
    prev_count: u64,
    curr_count: u64,
    curr_window_start_ms: u64,
}

impl SlidingWindowCounter {
    pub fn new(window_ms: u64) -> Self {
        Self { window_ms, prev_count: 0, curr_count: 0, curr_window_start_ms: 0 }
    }

    pub fn try_acquire(&mut self, now_ms: u64, limit: u64) -> bool {
        let w = now_ms / self.window_ms * self.window_ms;
        if w != self.curr_window_start_ms {
            self.prev_count = if w == self.curr_window_start_ms + self.window_ms {
                self.curr_count                       // adjacent window: carry over
            } else { 0 };                             // gap longer than a window
            self.curr_count = 0;
            self.curr_window_start_ms = w;
        }
        let elapsed = (now_ms - w) as f64 / self.window_ms as f64;
        let estimate = self.curr_count as f64
                     + self.prev_count as f64 * (1.0 - elapsed);
        if estimate + 1.0 <= limit as f64 {
            self.curr_count += 1;
            true
        } else {
            false
        }
    }
}
```

One subtlety in the sliding counter deserves attention, because it is easy to
misread: when the window rolls, the code asks *how far* it rolled. If the new
window is exactly the next one, the current count is *carried* into
`prev_count` — the estimate needs it. But if the key went quiet for longer
than a whole window, `prev_count` resets to zero instead, because traffic from
two windows ago has legitimately fallen outside any sliding window anchored
now. That one conditional is the difference between an estimate and a
superstition about the distant past.

And the test that *demonstrates the flaw* — fixed window admits a 2× burst at
the boundary, sliding counter rejects it:

```rust
#[cfg(test)]
mod window_tests {
    use super::*;

    #[test]
    fn fixed_window_admits_boundary_burst() {
        let mut fw = FixedWindow::new(60_000);        // 100 req/min
        // 100 requests at t = 59.5 s .. 59.9 s: all pass (window 0).
        for i in 0..100 {
            assert!(fw.try_acquire(59_500 + i, 100));
        }
        // 100 MORE at t = 60.0 s .. 60.4 s: all pass (window 1).
        // 200 requests in under a second — legal. That is the bug.
        for i in 0..100 {
            assert!(fw.try_acquire(60_000 + i * 4, 100));
        }
    }

    #[test]
    fn sliding_counter_rejects_the_same_burst() {
        let mut sw = SlidingWindowCounter::new(60_000);
        for i in 0..100 {
            assert!(sw.try_acquire(59_500 + i, 100));
        }
        // Just past the boundary the estimate is ~100 x overlap: the
        // previous window still counts almost fully. Burst denied.
        assert!(!sw.try_acquire(60_200, 100));
        assert!(!sw.try_acquire(61_000, 100));
        // Half a window later, weight has decayed: traffic flows again.
        let mut ok = 0;
        for i in 0..60 {
            if sw.try_acquire(90_000 + i * 500, 100) { ok += 1; }
        }
        assert!(ok > 40, "expected roughly half the limit to be available");
    }
}
```

Run the first test in your head and feel the insult of it: two hundred
requests, inside one second, every single one *legal* — the assertion suite
passes precisely because the algorithm is doing exactly what it was specified
to do, and the specification was wrong. Then the second test shows the cure
working through time: denied just past the boundary (the previous window
still weighs almost fully), and flowing again half a window later, with
roughly half the budget returned — which is exactly the overlap math of
Section 3.7 made concrete. Two tests, one story: *same traffic, different
definition of "window," opposite outcomes.* That is why the definition is the
design.

=== The fleet-wide atomic check

Within one process, a `Mutex` makes read-modify-write atomic. Across fifty
gateways, the atomicity must live *in the store*: the whole check ships as one
server-side script that the store executes without interleaving. In production
Rust this is a string constant handed to the client library — the script is
data; the engineering is Rust:

```rust
/// Fleet-wide fixed-window check (Section 3.12, Fix 1). Executed atomically
/// by the store, so the interleaving of Section 3.6 is impossible.
/// KEYS[1] = "rl:{api_key}:{route}:{window_id}", ARGV[1] = window seconds.
const FIXED_WINDOW_LUA: &str = r#"
    local n = redis.call("INCR", KEYS[1])
    if n == 1 then redis.call("EXPIRE", KEYS[1], ARGV[1]) end
    return n
"#;

/// One gateway node's decision: exactly one round trip, and the *returned*
/// count is the check — no client-side read-modify-write at all.
pub async fn allowed(
    con: &mut redis::aio::MultiplexedConnection,
    api_key: &str,
    route: &str,
    limit: u64,
    window_secs: u64,
    now_secs: u64,
) -> redis::RedisResult<Decision> {
    let window_id = now_secs / window_secs;
    let key = format!("rl:{api_key}:{route}:{window_id}");
    let n: u64 = redis::Script::new(FIXED_WINDOW_LUA)
        .key(key)
        .arg(window_secs)
        .invoke_async(con)
        .await?;
    Ok(if n <= limit {
        Decision::Allow { remaining: limit - n }
    } else {
        let reset = (window_id + 1) * window_secs;
        Decision::Deny { retry_after_ms: (reset - now_secs) * 1000 }
    })
}
```

Note what the code makes structural: the key *embeds the window id*, so window
rollover is just a new key (old windows expire by TTL — self-cleaning, Section
3.9); and the retry hint falls out of the window arithmetic for free. Look
also at what is *absent*: no `GET` before the script, no client-side
comparison against a fetched value, no retry loop. There is exactly one round
trip and one atomic observation, and the interleaving from Section 3.6's
diagram has no gap to live in. If you trace gateways A and B from that diagram
through *this* code, one of them receives `n = 100` and passes while the other
receives `n = 101` and is denied — the race is not managed, it is *eliminated*.

=== Where the check sits

The middleware contract, sketched against a generic handler: rules come from
the gateway-local cache (zero hops), the decision from the fleet store (one
hop), and `Deny` maps to the 429 contract of Section 3.8.

```rust
/// Gateway middleware shape (Section 3.10). `handler` is the real API.
pub async fn handle(
    req: Request,
    rules: &RuleCache,            // gateway-local, push-refreshed
    store: &mut Store,            // fleet-wide limit state
) -> Response {
    let rule = rules.for_key_and_route(req.api_key(), req.route());
    match store.check(req.api_key(), req.route(), &rule).await {
        Ok(Decision::Allow { remaining }) => {
            let mut resp = handler(req).await;
            resp.headers_mut().insert("X-RateLimit-Limit", rule.limit.into());
            resp.headers_mut().insert("X-RateLimit-Remaining", remaining.into());
            resp
        }
        Ok(Decision::Deny { retry_after_ms }) => Response::too_many_requests(
            retry_after_ms,          // -> Retry-After + X-RateLimit-Reset
            &rule,
        ),
        Err(_) => fail_open(req).await, // Section 3.15: never take the API down
    }
}
```

This listing is the architecture diagram compiled. Compare its three match
arms against Section 3.10's picture: the happy path decorates the real
response with transparency headers (FR-3) and costs the one allowed hop; the
deny path never calls `handler` at all — the backend spends nothing on
rejected traffic, which is the entire point of placing the check in
middleware; and the error arm — the store itself failing — routes to
`fail_open`, the decision Section 3.15 defends at length. Notice that the
error arm exists *in the type system*: `store.check` returns a `Result`, so
"what if the limiter breaks?" is not a question you remember to ask in a
design review, it is a branch the compiler required you to write. That is the
last question from the scope dialogue, answered in code.

== Scaling & Sharding

Sharding (Chapter 1) is by API key — the natural key, since every limit check
is scoped to exactly one. That sentence sounds obvious, but stop and check it
against the alternatives, because the *choice* of shard key is where scaling
designs are won or lost. Shard by route and one hot endpoint concentrates a
fleet's worth of checks onto one shard. Shard by time window and every shard
rotation becomes a fleet-wide migration. Shard by API key and each check
touches exactly one shard, keys are uniformly random enough to spread load,
and no shard ever needs to talk to another on the hot path. The requirement
you established in Section 3.6 — the count is a property of the caller — turns
out to dictate the sharding for free.

- *Limit-state store*: keys hash-sharded across 4–6 shards with replicas
  (Section 3.5's arithmetic). Each check touches exactly one key, so there is
  no cross-shard coordination on the hot path.
- *Gateways*: stateless; any request can be checked anywhere, because the state
  lives in the shared store.
- *Rules*: fully replicated to every gateway — config is megabytes, and the
  read pattern (every request) demands local memory.

Notice the three different scaling answers for the three data kinds from
Section 3.9: *shard* what is large and hot (limit state), *replicate* what is
small and read-hot (rules), and *leave alone* what must stay cheap and
replaceable (gateways). Uniform answers ("shard everything!" / "replicate
everything!") are a tell of template thinking; the variance across these
three rows is the actual design.

#defterm([Hot key])[
  A single key whose traffic concentrates on one shard hard enough to matter —
  here, one viral API key doing tens of thousands of checks per second. A
  single atomic `INCR` or script call is O(1) and microseconds; a hot key is
  far more likely to be *rejected* fast than to melt a shard. If a key ever
  outgrows one shard, split its counter across sub-shards (`rl:key#0..15`) and
  sum at check time — the same trick Chapter 2's stream used per segment.
]

*Multi-region note.* A truly global limit across regions forces synchronous
cross-region round trips on the hot path — hundreds of milliseconds, violating
the latency NFR. Production answer: enforce per-region limits sized to divide
the global one, and reconcile asynchronously (Chapter 1's PACELC framing:
consistency would cost latency, so availability and latency win, and the
*bounded overshoot* vocabulary of Section 3.4 is how you state the price).
When the interviewer asks "and if we go multi-region?", the trap to avoid is
reaching for a globally consistent counter; the answer they want is the
sentence you just read — divide the budget by region, accept bounded
overshoot at the seams, and say the trade-off out loud before they can ask.

== Failure Modes & Recovery

Here is where the interview's last scoping question gets its full answer. You
already decided *that* the limiter must not take the API down; this section
decides *how*, failure by failure. The definitions first, because the two
words are load-bearing for the rest of your career, not just this chapter:

#defterm([Fail-open / fail-closed])[
  What a dependent system does when its dependency fails. _Fail-open_ serves
  traffic anyway (availability over enforcement); _fail-closed_ refuses
  (enforcement over availability). The choice is per-route: abuse protection on
  a public API fails open with a local cap; a login endpoint defending against
  brute force fails *closed-ish* — refusing logins during a store outage is
  cheaper than admitting a credential-stuffing wave.
]

That last contrast is the sentence to say in the room, because it dissolves
the false binary. "Fail open or closed?" has no global answer; it has a
*per-route* answer driven by which error is cheaper *for that route*. A
rate-limited product API during a store outage: every minute closed costs
revenue and trust, and the risk is a few minutes of uncounted traffic — open
wins. A login endpoint during the same outage: every minute open is an
unthrottled credential-stuffing window against your users' accounts — closed
wins. Same limiter, same outage, opposite policies, both correct. Candidates
who answer "fail open, obviously" have answered a different, easier question.

#tbl(
  (auto, 1fr),
  header: (hcell[Failure], hcell[Handling]),
  body: (
    [Limit-state store shard down], [Fail over to the replica. If all replicas are gone: *fail open* with a per-gateway local token bucket sized `limit / fleet_size` — traffic flows, protection degrades to a bounded multiple of the limit, metrics scream (Section 3.17).],
    [Store unreachable from some gateways (partition)], [Those gateways degrade to local caps; the rest enforce exactly. Converges on heal, no manual action.],
    [Clock skew between gateways], [Structurally impossible to matter: bucket/window math runs on the *store's* clock via the server-side script (Section 3.12); local code uses monotonic time (Section 3.13).],
    [Bad rule pushed], [Rules are versioned; roll back to the previous version. Rate of change is small, so a human-in-the-loop push is fine.],
    [Rule fan-out stalls], [Gateways enforce last-known rules and alert; a stale rule for 60 s beats a missing check for 60 s.],
    [Retry storm after a 429 wave], [`Retry-After` spreads retries; add jitter client-side guidance in docs. A limiter that herds retries into the same second recreates the burst it just rejected.],
    [Hot key], [Sub-shard the counter and sum (Section 3.14). Rare in practice — hot keys are usually already over their limit.],
  ),
)

Read the first row until the *degraded-mode* logic is second nature, because
it is the design's load-bearing failure story. Store down → local token
bucket per gateway, sized `limit / fleet_size`. Wait — didn't Section 3.6
prove per-instance limits can't express a global limit? It did, and look at
why it is acceptable *here*: the failure is temporary, the local cap bounds
total overshoot at roughly `limit × (fleet_reached / fleet_size)` in the worst
case, and the alternative — refusing all traffic because a *protection
component* is ill — violates the availability NFR that outranks accuracy.
You are not contradicting Section 3.6; you are *spending* its lesson
deliberately, in an emergency, with a bound and a pager attached. Degraded
mode is a design, not an apology. The clock-skew row, by contrast, should
satisfy you: a failure mode made *structurally impossible* by an earlier
decision (the store-side script owns the clock) is worth ten failure modes
handled by procedures.

== Trade-offs & Alternatives

Every design is a purchase: this table is the receipt. Read each row as
"benefit bought, cost accepted" — and notice that none of the costs are
hidden, which is the entire point of writing them down:

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Decision], hcell[Benefit purchased], hcell[Cost accepted]),
  body: (
    [Token bucket], [Bursts as a product feature; O(1) state; lazy refill needs no timers], [Two-number accounting must be atomic fleet-wide (script in the store)],
    [Sliding window counter], [No boundary burst, still O(1)], [~1% estimate error; slightly more math at check time],
    [Fixed window alone], [One atomic INCR; trivially explainable], [2× boundary burst (Section 3.13's test proves it)],
    [Centralized exact check], [FR-4 truly holds; no false rejections], [+1 RTT on every request; store on the critical path],
    [Local + async sync], [Zero added latency; fail-open for free], [Bounded overshoot; unusable for billing-adjacent limits],
    [Fail-open default], [The API never dies because the limiter did], [During store outages, protection is a bounded approximation],
  ),
)

If the interviewer pushes on any row, the strongest move is to *agree with
the cost and re-state the budget that justifies it*. "Your centralized check
adds a millisecond to every request." — Yes; the negotiated budget was 1–2 ms
(Section 3.2), and what it buys is FR-4 holding exactly, which the tiered
pricing model depends on. Costs you have already priced are not weaknesses;
they are evidence the design was chosen rather than defaulted into.

== Observability & SLOs

SLIs and SLOs (Chapter 1) for a limiter are unusual in one way that you
should name up front, because it inverts the usual dashboard instinct: for
this system, *working correctly looks like rejections*. A graph full of 429s
might be the limiter failing — or the limiter heroically holding the line
against an abuse wave. Without instrumentation that separates those two
stories, you cannot tell success from outage. Instrument accordingly:

- *Decision rates* per rule: allows vs. 429s, over time. A 429 spike after a
  rule change is a config bug until proven otherwise.
- *Overshoot audit*: sampled per-key realized rates vs. limits — the direct
  measurement of Section 3.4's accuracy NFR.
- *Check latency* p50/p99, split by path (local rules lookup vs. store call);
  SLO: the ≤1 ms budget of Section 3.4.
- *Store health*: shard ops/sec, script latency, replica lag — the one
  dependency on the hot path.
- *Degraded-mode counters*: how many gateways are currently failing open, and
  with what local cap. This number should be zero; when it is not, paging is
  legitimate.
- *Top rejected keys*: the abuse list and the sales list are the same list —
  chronically limited keys are upgrade candidates (limits as monetization,
  Section 3.1).

Two of these bullets are doing more than monitoring. The *overshoot audit* is
what converts your accuracy NFR from a promise into a measurement — sampled
per-key realized rates against limits is the only way to *prove* steady-state
overshoot stays near 1%, and being able to point at the proof is what makes
"bounded overshoot" an engineering statement instead of a hope. And the
*degraded-mode counter* closes the loop with Section 3.15: fail-open is only
a defensible policy if you can see it happen, size it, and page on it. A
silent fail-open is not resilience; it is an outage wearing a costume.

== Interview Wrap-Up

*Likely follow-ups, with one-line answers:*

- _"Per-key AND per-IP AND per-route at once?"_ — Composite rules: evaluate
  each applicable limit; deny if any denies. Order checks cheapest-first.
- _"Monthly quotas for billing?"_ — Different system: append-only usage log,
  batch aggregation, delayed enforcement. Rate limits shape traffic; quotas
  shape invoices (Section 3.1).
- _"Limiter as a shared service vs. a library?"_ — A library removes a hop but
  re-introduces per-language drift and per-instance state; a sidecar/service
  centralizes policy at the price of the hop. State which you picked and why.
- _"Exactly-distributed without a central store?"_ — Gossiped counters or CRDTs
  (Chapter 1) give you *approximate* global counts with zero coordination;
  exactness without coordination is not a thing, and saying so is the answer.
- _"L3/L4 DDoS?"_ — Out of scope by layer: SYN floods and volumetric attacks
  are absorbed at the CDN/edge (Chapter 2) with connection-level defenses. This
  design is L7, per-authenticated-caller.
- _"Adaptive limits under load?"_ — Load-shedding's cousin: when the backend
  browns out, tighten limits dynamically by a global multiplier. Nice extension;
  say it, don't build it live.

Notice what each of these answers has in common: none of them is a feature
list. Each one *locates* the follow-up relative to the design you already
built — inside it (composite rules), beside it (quotas), below it (L3/L4),
or beyond it (adaptive limits). That reflex — classifying a new requirement
against an existing architecture instead of bolting it on — is the
interviewer's final test, and it is a habit you can practice on every
chapter of this book.

*If you remember five things:*

+ A rate limiter is a read-modify-write on the hot path; the design is the art
  of making that operation atomic and ≤ 1 ms.
+ Local counters cannot express a global limit; a non-atomic shared counter
  races. Atomicity lives *in the store*.
+ Token bucket = sustained rate + burst allowance, with lazy refill and
  self-cleaning TTL state.
+ Accuracy is asymmetric: never false-reject, bound the overshoot — and know
  that exactness is a product decision, not a technical one.
+ The limiter must never be the outage: fail open with a local cap, and page on
  degraded mode.

== Summary & Further Reading

We designed a distributed rate limiter for a 200k-RPS public API: a gateway
middleware making exactly one atomic check per request against a sharded
in-memory store; the algorithm zoo (fixed window, sliding log, sliding counter,
token bucket, leaky/GCRA) with token bucket chosen for its burst semantics; the
TOCTOU race and its three fixes (atomic increment-as-decision, server-side
scripts, approximate local counting); the 429 + `Retry-After` contract that
turns rejections into negotiations; runtime-reloadable tiered rules pushed to
gateway memory; and a defended fail-open policy with bounded local caps.

*Primary source for this chapter:*
- #link("https://www.youtube.com/watch?v=VzW41m4USGs")[*"7: Design a Rate Limiter" — Systems Design Interview Questions With Ex-Google SWE (Jordan has no life)*] — the walkthrough this chapter expands.

*Foundations worth reading:*
- Stripe's engineering blog on rate limiters — production limiter design at API-company scale.
- Figma's _An alternative approach to rate limiting_ — the leaky-bucket-in-Redis variant, honestly costed.
- The IETF draft _RateLimit header fields for HTTP_ — the emerging standard response contract.
- Brandur Leach's writing on GCRA and the Redis-cell module — the stateless leaky bucket, implemented.
- NGINX's rate-limiting documentation — the leaky bucket hiding inside a commodity reverse proxy.

== Chapter 3 Glossary

A one-glance index of every term this chapter defined. Chapters 1–2 are
assumed; later chapters assume all three. If any row feels unfamiliar, the
section that defines it is worth a re-read before you move on — later
chapters will use these words without re-defining them.

#tbl(
  (auto, 1fr),
  header: (hcell[Term], hcell[Meaning in one line]),
  body: (
    [Rate limiting / throttling], [Capping requests per identity per window; protection, capacity, monetization],
    [Quota], [Long-period budget for billing; batched, approximate accounting],
    [False rejection], [Denying an under-limit caller — the unforgivable error],
    [Overshoot], [Admitting over-limit traffic — the bounded, tolerable error],
    [Race condition / TOCTOU], [Check and use separated in time; state changes in between],
    [Atomicity / CAS], [All-or-nothing operation / conditional swap as one step],
    [Fixed window counter], [One counter per window; O(1), but 2× boundary bursts],
    [Sliding window log], [Every timestamp kept; exact; memory O(limit) — infeasible at scale],
    [Sliding window counter], [Two windows weighted by overlap; O(1), ~1% error, no burst],
    [Token bucket], [Capacity _b_ refilled at _r_/s; bursts allowed; lazy refill],
    [Leaky bucket / GCRA], [Constant-rate drip; bursts forbidden; smooth output],
    [HTTP 429 / Retry-After], ["Too fast" status + how long to wait — rejection as negotiation],
    [X-RateLimit-\* headers], [Limit, remaining, reset — client-side self-throttling data],
    [API gateway middleware], [First code every request meets; policy without backend changes],
    [Server-side script (Lua)], [Read-modify-write executed atomically inside the store],
    [Local + async sync], [Zero-latency approximate enforcement with bounded overshoot],
    [Monotonic clock], [Time source that never moves backwards; no refunded tokens],
    [Fail-open / fail-closed], [Dependency down: serve anyway / refuse — chosen per route],
    [Hot key], [One key concentrating load on one shard; sub-shard and sum],
    [Tiered limits], [Different limits per plan; limits as pricing],
    [Rule cache], [Gateway-local copy of config; zero hops per request],
    [Key TTL self-cleaning], [Idle keys expire with their window; no garbage collector],
    [Boundary burst], [Two legal window-fulls fired at a window edge — 2× in seconds],
    [Degraded-mode cap], [Local emergency limit while the fleet store is down],
  ),
)

#v(1em)
#align(center)[
  #text(size: 8.5pt, fill: slate, style: "italic")[
    — End of Chapter 3 · Next: Chapter 4, Logging & Metrics at Scale —
  ]
]
