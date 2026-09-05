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

The interviewer looks up and says:

#block(inset: (left: 14pt), stroke: (left: 2pt + primary), above: 0.9em, below: 0.9em)[
  #text(style: "italic", size: 10.5pt)[
    "Design a rate limiter. Our public API is used by a million developers, and
    we need to make sure no single caller can overwhelm the service — or use
    more than their plan allows."
  ]
]

Chapters 1 and 2 designed user-facing products. This chapter designs a piece of
*infrastructure* — a component that sits in front of every request and decides,
in well under a millisecond, whether the request may proceed. The difficulty is
not the concept ("count requests, reject past a threshold" is a five-line
program on one machine). The difficulty is doing it *correctly and cheaply on
the hot path of a distributed system*: fifty gateway servers must enforce one
shared limit per caller, under concurrency, without meaningful latency, and
without the limiter itself becoming the outage it exists to prevent.

#defterm([Rate limiting / throttling])[
  Controlling the *rate* at which a caller may invoke a system: at most _n_
  requests per time window per identity (API key, user, IP address, tenant).
  Calls beyond the limit are rejected (or queued, or slowed — hence
  _throttling_). Rate limiting serves three distinct masters: *protection*
  (abuse, brute force, accidental stampede), *capacity* (one noisy caller must
  not starve the rest), and *monetization* (usage tiers are limits with a price
  tag). Keep all three in mind: they produce different requirements.
]

#defterm([Quota vs. rate limit])[
  A _quota_ is a budget over a long period ("100,000 calls per month") used for
  billing and plan enforcement; it tolerates approximate, batched accounting.
  A _rate limit_ governs short windows ("100 calls per second") to shape live
  traffic; it must be enforced *now*, on the request's critical path. This
  chapter is about rate limits; Section 3.18 discusses how quotas differ.
]

== Scope & Clarifying Questions

The prompt spans everything from login-page brute-force protection to planetary
DDoS absorption. Narrow it:

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
  local fallbacks, timeouts) is downstream of the answer.
]

== Functional Requirements

Chapter 1 defined functional requirements; ours:

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

== Non-Functional Requirements

Three qualities dominate, and they pull against each other — naming the tension
is half the answer:

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

#defterm([False rejection / overshoot])[
  The two ways a limiter can be wrong. A _false rejection_ denies a caller who
  is under the limit — an availability bug, visible and unforgivable.
  _Overshoot_ allows more than the limit — a protection degradation, tolerable
  in small doses. Accuracy requirements should always be stated in this
  asymmetric vocabulary, because the two errors have opposite costs and
  different causes.
]

#insight([Latency, accuracy, availability: pick the trade-off consciously])[
  *Exact* global counting wants a synchronous round trip to a strongly
  consistent store (latency + availability cost). *Zero added latency* wants
  purely local counting (accuracy cost: 50 nodes × local limit). *Maximum
  availability* wants fail-open everywhere (protection cost). Every real design
  is a point in this triangle; the rest of the chapter locates ours and prices
  it.
]

== Back-of-the-Envelope Estimation

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

#insight([The scarce resource is round trips, not hardware])[
  Six gigabytes of state and a few hundred thousand ops per second are, by
  Chapter 2's standards, nothing. The entire design problem is: *where does the
  check happen relative to the request?* A centralized exact check costs one
  network round trip (~1 ms in-region — the whole budget). A local check costs
  zero round trips but is approximate. Estimation tells you this is a *latency
  topology* problem, not a capacity problem — design accordingly.
]

== The Core Challenge: Counting Correctly Under Concurrency

The limit check is a read-modify-write: *read* the caller's count, *decide*,
*write* the incremented count. Two naive placements fail in instructive ways.

*Naive strategy 1 — count locally on each gateway.* No shared state, zero added
latency. But the limit is *per key*, and a key's requests land on all ~50
gateways. If each node enforces 100 req/s locally, the caller effectively has
*5,000 req/s* — FR-4 is unmet. Lowering each node's limit to 100/50 = 2 req/s
misfires the other way: a caller whose traffic happens to hit one node gets
strangled. Per-instance limits cannot express a global limit.

*Naive strategy 2 — a shared counter store with plain reads and writes.* Put
the counters in one shared, in-memory store; each gateway does `GET`, compare,
`INCR`. This fails under concurrency:

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

So the core challenge decomposes into two questions that the rest of the
chapter answers: *what exactly is the count* (which algorithm — Section 3.7),
and *how is the check made atomic across the fleet* (Section 3.12).

== The Algorithm Zoo

Five algorithms cover the entire design space. Each is a different answer to
"what does 'at most _n_ per window' mean, exactly?"

#defterm([Fixed window counter])[
  Divide time into fixed windows (e.g., each clock minute) keyed
  `rl:{key}:{window_id}`; each request increments the current window's counter;
  reject when it exceeds the limit. O(1) memory per key, one atomic increment
  per request — and a famous flaw: *the boundary burst*. A caller can fire 100
  requests at 0:59.9 and 100 more at 1:00.0 — 200 requests in 0.1 seconds, all
  legal, because the two bursts sit in different windows.
]

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

The comparison that ends the discussion:

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

== API & Protocol Design

A rate limiter's "API" is mostly *other people's responses*. The contract that
matters:

#defterm([HTTP 429 / Retry-After])[
  Status *429 Too Many Requests* (RFC 6585) means "you, specifically, are
  calling too fast." The *`Retry-After`* header tells the caller how many
  seconds to wait before retrying. Together they convert a rejection into a
  negotiation: a well-built client backs off exactly as instructed instead of
  hammering harder. A limiter that rejects without `Retry-After` trains
  clients to retry blindly — worse for everyone.
]

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

(An IETF draft standardizes these as `RateLimit-*` fields; the `X-` forms
remain the de-facto convention. Either is defensible — knowing both exist is
the point.)

A rejection response, end to end:

```json
HTTP/1.1 429 Too Many Requests
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 45
Retry-After: 1
Content-Type: application/json

{ "error": "rate_limit_exceeded", "limit": 100, "window": "1s", "plan": "free" }
```

The *admin* surface (FR-2, FR-6) is ordinary REST: rules as records —
`{ api_key or tier, route pattern, algorithm, limit/rate, burst, window }` —
created and updated through an admin API, versioned, and pushed to every
gateway within seconds (Section 3.10).

== Data Model & Storage

#tbl(
  (auto, 1.5fr, 1.1fr),
  header: (hcell[Entity], hcell[Contents], hcell[Store]),
  body: (
    [Limit state], [`rl:{api_key}:{route}` → `{tokens, last_refill_ms}` (bucket) or window counters; TTL = window so idle keys self-clean], [In-memory store cluster (Redis-class), sharded by key hash],
    [Rule], [tier or key → {algorithm, rate, burst, window, route pattern}; versioned], [Durable KV/relational store, fanned out to gateway-local caches],
    [Quota ledger], [monthly usage per key for billing], [Append-only log → batch aggregation; *not* on the request path (Section 3.2)],
  ),
)

Two decisions to name. First, state entries carry a *TTL* (Chapter 2) equal to
the window, so the 100M-active-keys problem is self-cleaning: idle keys vanish
without a garbage collector. Second, rules are cached *on each gateway* with
push-based invalidation — a per-request rule lookup must never add a second
network hop.

== High-Level Architecture

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

#insight([The one-op rule])[
  Per request, the design allows itself *exactly one* atomic store operation
  and zero synchronous config reads. Everything — the algorithm choice (O(1)
  state), the TTL self-cleaning, the gateway rule caches — exists to preserve
  that invariant. When an interviewer pushes on any component, return to it.
]

== Deep Dive: The Token Bucket, Precisely

The token bucket's elegance is that *time is never advanced by a timer*. State
is two numbers, updated lazily when a request arrives:

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

Reading the parameters as product language: _r_ = sustained rate ("100 req/s"),
_b_ = burst allowance ("…with bursts up to 150"). The retry hint is free:
`retry_after` is exactly how long until one token exists.

A worked trace (limit 5 req/s, burst 8), to have in hand at the whiteboard:

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

#pitfall([Refill by background timer])[
  Implementing refill as a cron or timer per key means a million timers, clock
  drift between timer and request paths, and state that never cleans itself up.
  Lazy refill has none of these: no timers, no drift (one clock, read once per
  request), and a TTL on the key reclaims idle state for free. If you find
  yourself scheduling work per key, you have re-invented the sliding log's
  costs inside the token bucket.
]

#notebox([One clock, and make it monotonic])[
  Distributed machines disagree about wall-clock time (clock skew), and even on
  one machine the wall clock can jump backwards (NTP corrections) — a backward
  jump would *refund* tokens. Two defenses: (1) perform the bucket update
  *inside the store* with a server-side script, so one clock governs every
  gateway (Section 3.12); (2) where local time is unavoidable, read a
  *monotonic* clock (one that never moves backwards), as Section 3.13's Rust
  does.
]

== Deep Dive: Distributed Enforcement & the Race

Section 3.6's race came from splitting *check* and *update* across a network.
Three production-grade fixes, in increasing order of sophistication:

*Fix 1 — atomic increment-as-decision.* For window algorithms, one atomic
`INCR` already returns the post-increment value: the store's returned count *is*
the check. Reject when the returned value exceeds the limit. One round trip, no
client-side race, and the first increment of a window sets the key's TTL in the
same atomic step. Fixed window and sliding counter ship this way.

*Fix 2 — server-side script for read-modify-write.* Token bucket needs
read-compute-write (refill, compare, decrement). Executing that sequence *on
the store*, as one atomic script, removes the race identically: the store
serializes script execution, so no two requests ever observe the same balance.
Section 3.13 shows the client side, with the script embedded as data.

*Fix 3 — approximate local counting.* The radical option: skip the store on the
hot path entirely. Each gateway keeps local counters and periodically
*publishes* them; a background aggregator broadcasts fleet-wide totals, and
each node denies when `local_estimate + fleet_total ≥ limit`. Zero added
latency, and the store is off the critical path (fail-open for free) — but
between syncs, overshoot is bounded by roughly `limit × (sync_lag / window)`.
Choose it when protection matters more than precision (abuse mitigation); never
for billing-adjacent limits.

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

#tip([Say the quiet part: exactness is a product decision])[
  "How exact does this need to be?" has no technical answer — it depends on
  whether the limit protects revenue (exact: paid tiers), infrastructure
  (approximate fine: abuse), or other users' experience (approximate fine:
  fairness). Volunteering this framing turns an algorithm comparison into a
  senior-level requirements discussion.
]

== Deep Dive: Rust Reference Implementations

Three pieces, all executable: the token bucket with deterministic-time tests,
the fixed-window/sliding-counter pair showing the boundary burst and its cure,
and the atomic store check with the server-side script embedded as data.

=== Token bucket with a testable clock

Time is injected through a `Clock` trait so tests control it exactly — the
difference between a test that *suggests* correctness and one that *proves* it.

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
3.9); and the retry hint falls out of the window arithmetic for free.

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

== Scaling & Sharding

Sharding (Chapter 1) is by API key — the natural key, since every limit check
is scoped to exactly one:

- *Limit-state store*: keys hash-sharded across 4–6 shards with replicas
  (Section 3.5's arithmetic). Each check touches exactly one key, so there is
  no cross-shard coordination on the hot path.
- *Gateways*: stateless; any request can be checked anywhere, because the state
  lives in the shared store.
- *Rules*: fully replicated to every gateway — config is megabytes, and the
  read pattern (every request) demands local memory.

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

== Failure Modes & Recovery

#defterm([Fail-open / fail-closed])[
  What a dependent system does when its dependency fails. _Fail-open_ serves
  traffic anyway (availability over enforcement); _fail-closed_ refuses
  (enforcement over availability). The choice is per-route: abuse protection on
  a public API fails open with a local cap; a login endpoint defending against
  brute force fails *closed-ish* — refusing logins during a store outage is
  cheaper than admitting a credential-stuffing wave.
]

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

== Trade-offs & Alternatives

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

== Observability & SLOs

SLIs and SLOs (Chapter 1) for a limiter are unusual in one way: the system
*working* looks like rejections. Instrument accordingly:

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
assumed; later chapters assume all three.

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
