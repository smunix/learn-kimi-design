// ============================================================================
//  CHAPTER 12 — Designing a Ride-Hailing Marketplace (Uber / Lyft)
//  Source: "10: Design Uber/Lyft | Systems Design Interview Questions
//  With Ex-Google SWE" (channel: Jordan has no life)
//  Link: https://www.youtube.com/watch?v=giwa8Hc0niY
// ============================================================================

#import "../template.typ": *

= Designing a Ride-Hailing Marketplace (Uber / Lyft)

#notebox([Problem source])[
  This chapter solves the problem posed in the talk _"10: Design
  Uber/Lyft"_ from the series _Systems Design Interview Questions with
  Ex-Google SWE_ (channel: _Jordan has no life_). It is a full product
  design in the shape of Chapters 1–7 and 10, and a reunion tour of the
  fundamentals chapters: geospatial indexing from Chapter 2, idempotent
  payments from Chapters 10–11, real-time push from Chapter 1, and the
  per-city placement decisions from Chapter 9. The problem is the
  definitive *marketplace* interview: two sides (riders, drivers), one
  scarce resource (nearby idle drivers), and a clock that never stops.
  All terms are defined before use; all reference code is Rust with
  deterministic tests.
]

== The Problem Statement

The interviewer drops a pin on a map and says:

_"Design Uber. A rider requests a trip; the system finds a nearby driver,
quotes a price and ETA, coordinates pickup and the ride itself, charges
the rider, pays the driver — in real time, in hundreds of cities, while a
million drivers move around updating their location every few seconds."_

What makes this problem a classic is that it is *four* systems in a
trenchcoat: a high-throughput location pipeline, a geospatial search
engine over moving points, a real-time marketplace matcher, and a
pedestrian transactional backend for trips and money. The interview is
won by keeping those four cleanly separated — and by knowing which of
them is actually hard (it is not the one candidates expect).

#defterm([Rider / driver / trip / marketplace])[
  The two sides and the unit of work. _Riders_ request transport;
  _drivers_ supply it; a _trip_ is one fulfilled request with a lifecycle
  (requested → matched → in progress → completed). The system is a
  _marketplace_: it does not own the supply, it *clears* it — matching
  demand to supply fast enough that neither side leaves, and pricing to
  keep the market balanced when it isn't (surge, Section 12.10).
]

#defterm([ETA / deadheading / utilization])[
  _ETA_ is the estimated time of arrival — of the driver to the pickup
  (pickup ETA) and of the trip (dropoff ETA) — produced by the routing
  engine of Chapter 2 over the live road graph. _Deadheading_ is driving
  without a passenger: pure cost. _Utilization_ is the fraction of driver
  hours with a rider in the car — the marketplace's core efficiency
  metric, and the number the matching engine (Section 12.8) silently
  optimizes.
]

== Scope & Clarifying Questions

#tbl(
  (auto, 1fr),
  header: (hcell[Candidate asks], hcell[Interviewer answers]),
  body: (
    [Scale?], [10⁶ drivers online globally, 2 × 10⁷ rides/day, one metro is the unit of operation],
    [Geography?], [Cities are independent shards; cross-city trips are rare and can be treated as an edge case],
    [Matching quality?], [Fast beats perfect: a good match in 2 s outperforms an optimal match in 30 s],
    [Pricing?], [Dynamic (surge) per area; quote shown up front and honored],
    [Shared rides?], [Out of scope for v1 — mention it as the natural extension (multi-stop matching)],
    [Payments?], [Card on file; charge at trip end; idempotency is non-negotiable (Chapters 10–11)],
    [Real-time UX?], [Rider sees the driver's pin move; push over WebSocket (Chapter 1's channel)],
  ),
)

#notebox([Agreed scope])[
  + The *location pipeline*: ingest 2.5 × 10⁵ driver position updates per
    second and keep a queryable, in-memory picture of "who is where".
  + The *geospatial index*: nearby-available-driver queries over points
    that never stop moving.
  + The *matching engine*: rider-to-driver assignment, offer/accept
    protocol, batched matching windows, idle-supply positioning.
  + The *trip backbone*: lifecycle state machine, idempotent payments,
    ratings — the transactional 20% that must never be wrong.
  + *Surge pricing* as a market-balancing control loop, with its failure
    modes designed in, not discovered.
  + Out of scope: pooling/shared rides, routing engine internals
    (Chapter 2), maps data pipelines (Chapter 2), driver onboarding.
]

== Functional Requirements

+ *Location tracking.* Drivers publish position every ~4 s while online;
  the system maintains a fresh, queryable picture per city; stale
  positions expire automatically.
+ *Quotes.* Given pickup and destination, return an upfront price and a
  pickup/dropoff ETA before the rider commits.
+ *Request & match.* A ride request enters matching immediately; an
  offered driver has ~15 s to accept; on decline or timeout the request
  re-enters matching without rider involvement.
+ *Trip lifecycle.* Requested → matched → arriving → in progress →
  completed/cancelled, as an explicit state machine; illegal transitions
  are impossible by construction (Section 12.13).
+ *Payment.* At trip end, charge the rider's card once — exactly once as
  far as the rider can ever observe — and credit the driver's balance.
+ *Real-time status.* Both apps stream trip state and the driver's live
  position; polling is the fallback, not the primary channel.
+ *Surge.* Prices respond to per-area supply/demand within a minute, with
  smoothing and caps.

== Non-Functional Requirements

- *Match latency.* p99 ≤ 5 s from request to driver-accepted in a
  healthy market; the matching engine is never allowed to be the
  bottleneck that leaves riders staring at a spinner.
- *Location freshness.* The geo index reflects a driver's position within
  ~5 s end-to-end; anything staler is treated as offline.
- *Availability asymmetry.* Losing *matching* for a minute is a degraded
  minute; losing *trip records or payments* is a breach — the
  transactional backbone out-availability-targets the real-time side.
- *City isolation.* A city is a failure domain: New York's New Year's Eve
  must not move Lagos's Tuesday morning.
- *Correctness under retries.* Every client-visible effect — requests,
  cancels, charges — is idempotent, because every mobile client retries
  on every elevator ride.

== Back-of-the-Envelope: A Million Moving Dots

Assumptions: 10⁶ drivers online at global peak; position update every 4 s;
2 × 10⁷ rides/day; 5 × 10⁶ concurrent riders at peak; trip record ≈ 2 KB;
city-sharded.

#tbl(
  (auto, 1fr),
  header: (hcell[Quantity], hcell[Estimate (with assumptions)]),
  body: (
    [Location ingest], [10⁶ drivers / 4 s ≈ *2.5 × 10⁵ updates/s*, ~100 B each → 25 MB/s — a Chapter 4 append stream, city-partitioned],
    [Nearby-driver queries], [Rider app polls + matcher candidate fetches ≈ *5 × 10⁴ reads/s* against the geo index — in-memory, so this is CPU, not I/O],
    [Geo index memory], [10⁶ drivers × ~48 B (id, cell, freshness) ≈ *50 MB per region* — fits in cache ten times over; the index is cheap, the *churn* is the story],
    [Match rate], [2 × 10⁷ rides/day ≈ 230/s average → *~1.2 × 10³ matches/s at evening peak*; with 2 s windows, ~2 400 riders and ~10⁴ idle drivers per window globally],
    [Trip storage], [2 × 10⁷ trips/day × 2 KB ≈ *40 GB/day* → ~3.6 TB for a 90-day hot window — Chapter 8's indexed store, partitioned by city and day],
    [Push fanout], [~10⁵ active trips × 2 devices × 1 update/5 s ≈ *4 × 10⁴ msgs/s* — Chapter 1's WebSocket fanout, modest by its standards],
    [Payment volume], [Peak ≈ 1.2 × 10³ charges/s — trivial for the payments stack; the requirement is correctness (idempotency), not throughput],
  ),
)

#insight([Read the table and notice what is *not* hard])[
  Nothing here is big data. Fifty megabytes of live driver positions,
  forty gigabytes of trip records a day, a few thousand matches a second —
  a single modern machine could nearly run the whole thing. The genuine
  difficulty is the *physics of the problem*: positions expire in
  seconds, a match decision locks a moving 15-minute resource, riders
  abandon after ~10 s of spinner, and the two sides of the market react
  to each other with feedback loops. This is a *liveness and correctness*
  design, not a capacity design — budget your interview time accordingly.
]

== The Core Challenge: A Marketplace That Refuses to Sit Still

Strip the product away and three structural difficulties remain — none of
them capacity.

+ *The index never rests.* A geospatial index over 10⁶ points that each
  move every 4 seconds is not a structure you build; it is a structure
  you *maintain at 2.5 × 10⁵ mutations per second*. B-trees and R-trees
  answer "where is this" beautifully and "it moved again" badly; the
  answer is a flat, mutable, in-memory cell index where moving is an
  O(1) re-bucketing (Section 12.7).
+ *Matching is a decision under expiry.* A rider waits seconds; an idle
  driver is claimed by the next request; the road network keeps score.
  The matcher must trade "best possible assignment" against "assignment
  before the rider abandons" — a classic online decision problem, solved
  by batching into short windows (Section 12.8).
+ *The transactional tail must be perfect.* Requests, cancels, charges:
  twenty percent of the traffic and a hundred percent of the trust. A
  double charge is a support ticket and a regulator; a lost trip record
  is a safety incident. This side of the system buys Chapter 11's
  guarantees and pays for them gladly.

#insight([One city, one authority])[
  The cleanest architectural decision in the whole design: *a trip is
  owned by exactly one city's stack.* Geographically partitioned,
  region-local writes, no cross-region consensus on the hot path — the
  trip state machine and its store live where the trip physically is.
  Chapter 9's physics is respected by making the problem almost never
  cross the boundary: riders and drivers move within a city; the rare
  cross-border trip is handed off between city stacks like a roaming
  call. Strong consistency where it is cheap, no coordination where it
  would hurt.
]

== Deep Dive: Geospatial Indexing for Moving Points

The geo index answers one question, 5 × 10⁴ times a second: *which
available drivers are within a few hundred meters of this pickup?* Two
candidate families exist; the moving-point constraint picks the winner.

*R-trees and friends* (Chapter 2's structures) give exact spatial answers
but punish mutation: every driver move is a delete-plus-insert through a
balanced tree, and at 2.5 × 10⁵ moves/s the maintenance cost dominates.
*Grid cells* give up exactness for churn-tolerance: assign each driver to
a cell; a query reads a handful of cells; a move updates two hash-map
entries. Exactness is recovered by post-filtering the (small) candidate
set by true distance — cells are for *recall*, distance math is for
*precision*.

#defterm([Geohash])[
  A string encoding of a grid cell made by interleaving longitude and
  latitude bits, five bits per base-32 character. Its superpower is the
  *prefix property*: a cell's code is a prefix of every cell inside it,
  so "within this area" becomes `starts_with` — string prefix matching as
  a spatial operator. Longer codes are smaller cells (6 characters ≈ a
  1.2 km × 0.6 km cell; 7 ≈ 150 m × 150 m). The Rust listing in Section
  12.13 implements encode/decode in fifty lines. Production systems often
  use hexagonal successors (Uber's H3, Google's S2) whose cells have
  uniform neighbor distances and no pole weirdness; the interview-level
  mechanics are identical.
]

*The query algorithm* is ring expansion over prefixes: look in the
pickup's own cell; if fewer candidates than needed, look in the parent
prefix (a cell ~4× wider); expand again to a grandparent; then
post-filter by straight-line distance and rank by ETA from the routing
engine. Two refinement notes that earn interview points: a driver near a
cell *boundary* can be missed by pure prefix expansion, so production
reads the 8 neighboring cells at each level as well; and cells must be
sized to the market — Manhattan at lunch needs 150 m cells, rural Wyoming
needs 5 km ones, so precision adapts per city and per hour.

*The churn side* is where the design earns its keep: `upsert(driver,
lon, lat)` computes the driver's cell, removes the id from the old cell's
list if it changed, and appends to the new one — O(1), no tree surgery, no
locks beyond a shard-local latch. A driver who stops updating for ~15 s
(the freshness TTL) is evicted by a sweeper and treated as offline.
Freshness is part of the index's contract, not a separate monitoring
system: *a stale position is a wrong position.*

== Deep Dive: The Matching Engine

Given candidates, who gets which rider? Two designs, one evolution.

*Naive dispatch* — offer each request to the single nearest available
driver, then the next on decline — is where every prototype starts and
where every prototype's metrics die: it serializes decisions (each offer
burns a 15 s accept window), and greedy nearest-first assignment is
provably suboptimal in aggregate (the Rust listing includes a case where
it wastes minutes of pickup time).

*Batched matching windows* — the production answer: accumulate ride
requests and idle drivers for a short window (~2 s), then solve the whole
window as one assignment problem: riders on one side, drivers on the
other, edge costs = pickup ETA (plus small penalties for driver rating
mismatches, vehicle-type mismatch, long deadhead). This is a *bipartite
matching* instance; the optimal solution is the Hungarian algorithm's
min-cost assignment, O(n³) on a window of thousands — and a well-ordered
greedy pass (cheapest edge first, skip taken endpoints) lands within
~10–20% of optimal at O(E log E), which is the usual production
compromise at window scale.

#defterm([Bipartite matching / assignment problem])[
  A graph whose vertices split into two sets (riders, drivers) with edges
  only across (a possible pairing, weighted by pickup cost). A _matching_
  is a set of edges sharing no endpoints: each rider, at most one driver.
  The _assignment problem_ asks for the matching of minimum total cost —
  solved exactly by the Hungarian algorithm and approximately, at a tenth
  of the compute, by sorted greedy. Batching requests into windows is
  what turns a stream of myopic one-at-a-time decisions into a global
  optimization — the same trick as Chapter 7's re-ranking stage, applied
  to cars instead of videos.
]

*The offer protocol* rides on Chapter 11's machinery: an offer is a
short-lived exclusive lock on a driver — `offer_token` with a 15 s TTL,
one outstanding offer per driver, accept = compare-and-set on the token.
Decline, timeout, or app death releases the driver into the next window;
the rider's request re-enters with its original timestamp so fairness is
preserved across retries.

*Idle supply positioning* is the matcher's quiet second job: when a city
cell has surplus idle drivers and a neighbor has a deficit, the system
*nudges* drivers toward the deficit (map suggestions, small bonuses),
shrinking future pickup ETAs before any rider appears. Matching reacts to
the market; positioning *shapes* it.

== Deep Dive: The Trip Backbone — State Machine and Money

The real-time side may be fuzzy; this side may not. Every trip is a row
in the city-sharded trip store whose `state` column moves through one
explicit machine:

`REQUESTED → MATCHED → ARRIVING → IN_PROGRESS → COMPLETED` (or
`CANCELLED` from any pre-completion state).

Each transition is a compare-and-set on the row inside a Chapter 11
transaction, triggered by an idempotency-keyed API call. Three rules make
the machine trustworthy:

+ *The table, not the app, owns legality.* `driver_arrived` before
  `match` is not "handled"; it is rejected by the transition function
  (the Rust listing makes illegal transitions unrepresentable as
  successes).
+ *Every transition is idempotent.* Network retries, app restarts, and
  double-taps replay the same key and return the same outcome — Chapter
  10's dedup discipline applied to state changes.
+ *Completion triggers payment exactly once.* The `COMPLETED` transition
  emits one `charge` command with key `(trip_id, "charge")` into the
  payments pipeline; capture is retried until acked, and the dedup store
  guarantees the rider's card sees it once no matter how many times the
  pipeline replays it (Chapter 10's effectively-once, end to end).

Driver payout is deliberately *not* synchronous: the trip completes, the
rider charge settles through the payments pipeline, and the driver's
balance updates via a ledger event — seconds later is fine, because
nobody's card statement depends on the driver's app refreshing in real
time. Decoupling the two money flows keeps the trip state machine small
and the payments pipeline independently auditable.

== Deep Dive: Surge Pricing as a Control Loop

When requests outnumber idle drivers in a cell, the market needs a price
signal — more drivers should come, price-sensitive riders should wait.
The mechanism: per-cell *surge multiplier* = a smoothed, capped function
of the demand/supply ratio, recomputed every ~30 s.

The control-theory traps, named so the interviewer knows you know:

- *Oscillation.* Price rises → drivers flood in → price collapses →
  drivers leave → repeat. Damping: exponential smoothing of the ratio,
  and asymmetric responsiveness — quick up (riders are abandoning *now*),
  slow down (don't whipsaw drivers mid-drive).
- *The feedback loophole.* Drivers learn to wait out the first minute of
  surge for a higher multiplier; riders learn to walk one cell over.
  Mitigations: personalized-but-regulated caps, and never publishing the
  exact per-cell map as a gameable API.
- *Ethics and law.* Emergency contexts cap or disable surge; regulators
  in several jurisdictions constrain the multiplier's ceiling and its
  display. A pricing system is a policy system with a math core.

#pitfall([Surge measured at the wrong granularity])[
  Compute the ratio city-wide and a stadium emptying at midnight surges
  the whole city; compute it per-100 m-cell and a single rider
  plus-or-minus one driver oscillates the price every thirty seconds.
  The cell size must hold *enough actors for statistics* — tens of
  riders and drivers per cell per window — which is why production surge
  uses multi-resolution cells (H3's hierarchy) and falls back up the
  hierarchy when a fine cell is too quiet to measure.
]

== API Design

The API is deliberately small; every mutating call carries an idempotency
key, and everything time-sensitive after the match rides the push
channel rather than polling.

#tbl(
  (0.95fr, 1.9fr, 2.6fr, 1.6fr),
  header: (
    hcell[Verb & path],
    hcell[Purpose],
    hcell[Key fields],
    hcell[Guarantee],
  ),
  body: (
    [`POST /v1/location`],
    [Driver heartbeat into the geo index],
    [`driver_id, lon, lat, heading, seq`],
    [`202`; stale `seq` dropped],
    [`POST /v1/rides/quote`],
    [Fare + pickup-ETA estimate before commitment],
    [`pickup, dropoff` → `quote_id, price_band, eta, surge`],
    [Read-only; quote TTL ~60 s],
    [`POST /v1/rides`],
    [Create trip (`REQUESTED`) and enter matching],
    [`Idempotency-Key, quote_id, rider_id`],
    [Key-safe retry → same `trip_id`],
    [`POST /v1/offers/{id}/accept`],
    [Driver claims an offer within its 15 s TTL],
    [`offer_id, driver_id, offer_token`],
    [Compare-and-set; one winner],
    [`POST /v1/trips/{id}/events`],
    [Advance the state machine],
    [`Idempotency-Key, event: arrived|start|finish|cancel`],
    [Illegal transition → `409`],
    [`GET /v1/rides/{id}`],
    [Snapshot for reconnects and support tools],
    [`trip_id` → full state + last known positions],
    [Strongly consistent (city-primary read)],
    [`WS /v1/stream`],
    [Push: match found, driver en route, receipt],
    [per-user channel, resume token],
    [At-least-once + client dedup (Ch. 1)],
  ),
)

Two design notes. First, the *quote before request* split matters: the
quote is a cheap, cacheable, surge-aware estimate; the request is the
committing write. Riders who balk at the price cost us one read, not one
write-cancel-refund cycle. Second, `POST /v1/trips/{id}/events` is the
only door into the state machine — apps never write `state` directly, so
the transition table (Section 12.13) is enforced in exactly one place.

== High-Level Design

#canvas(h: 8.9cm, {
  // ── clients
  node((0.8cm), (0cm), 3.6cm, 0.85cm, [Rider app], fill: faint, edge: slate)
  node((5.4cm), (0cm), 3.6cm, 0.85cm, [Driver app], fill: faint, edge: slate)
  glabel(4.9cm, 1.2cm, [locations every ~4 s])
  // ── edge
  node((0.8cm), 1.9cm, 5.2cm, 1.0cm, [API gateway + WS push\ (Ch. 1)])
  node((9.8cm), 1.9cm, 6.2cm, 1.0cm, [Location ingest · TTL sweeper])
  // ── real-time core
  node((0.8cm), 3.8cm, 4.6cm, 1.0cm, [Matcher\ 2 s windows · offers])
  node((5.9cm), 3.8cm, 4.6cm, 1.0cm, [Geo index\ cells · in-memory])
  node((11.1cm), 3.8cm, 4.9cm, 1.0cm, [Surge control loop])
  // ── transactional core
  node((0.8cm), 5.7cm, 5.2cm, 1.0cm, [Trip service\ state machine])
  node((6.6cm), 5.7cm, 4.6cm, 1.0cm, [Trip store\ city-sharded (Ch. 8/11)])
  node((0.8cm), 7.5cm, 5.2cm, 0.95cm, [Payments\ effectively-once (Ch. 10)])
  // ── arrows
  arrow(2.6cm, 0.85cm, 2.6cm, 1.9cm)                       // rider → gateway
  arrow(7.2cm, 0.85cm, 11.0cm, 1.9cm)                      // driver → ingest
  arrow(11.0cm, 2.9cm, 9.6cm, 3.8cm)                       // ingest → geo
  glabel(10.55cm, 3.35cm, [re-bucket per update])
  arrow(3.0cm, 2.9cm, 3.0cm, 3.8cm)                        // gateway → matcher
  glabel(3.15cm, 3.3cm, [match requests])
  arrow(5.4cm, 2.9cm, 6.3cm, 3.8cm)                        // gateway → geo
  glabel(6.45cm, 3.3cm, [nearby queries])
  arrow(5.4cm, 4.3cm, 5.9cm, 4.3cm)                        // matcher → geo
  arrow(10.5cm, 4.3cm, 11.1cm, 4.3cm)                      // geo → surge
  arrow(3.0cm, 4.8cm, 3.0cm, 5.7cm)                        // matcher → trip svc
  glabel(3.15cm, 5.15cm, [matched trips])
  arrow(6.0cm, 6.2cm, 6.6cm, 6.2cm)                        // trip svc → store
  arrow(3.2cm, 6.7cm, 3.2cm, 7.5cm)                        // trip svc → payments
  glabel(3.35cm, 7.05cm, [charge, key = (trip, "charge")])
  // ── push bus (dashed teal, left margin)
  arrow(0.8cm, 6.2cm, 0.45cm, 6.2cm, color: teal, dashed: true)
  arrow(0.45cm, 6.2cm, 0.45cm, 2.4cm, color: teal, dashed: true)
  arrow(0.45cm, 2.4cm, 0.8cm, 2.4cm, color: teal, dashed: true)
  glabel(0.02cm, 6.55cm, [push])
})

Reading the diagram left to right, the system has three temperaments.
The *top two rows are soft state*: heartbeats flow driver app → ingest →
geo index, where a missed update simply expires at the TTL sweeper; the
gateway asks "who is nearby" and forwards requests into the matcher.
Nothing here is stored for long and nothing here may block on a disk.
The *bottom half is hard state*: the matcher hands a mutually accepted
pairing to the trip service, which walks the state machine against the
city-sharded store, and exactly one charge command falls out the bottom
into payments. The *dashed teal bus* is the return leg — every accepted
transition is published to the gateway, which pushes it to both apps over
the long-lived connection of Chapter 1. The surge loop stands slightly
apart: it reads the geo index's per-cell supply counts and the gateway's
request rate, and answers quotes with multipliers — it never touches the
trip backbone.

== Rust Reference Implementations

Four small cores carry the chapter: the geohash codec that makes space
prefix-searchable, the cell index that absorbs a quarter-million moves a
second, the windowed matcher, and the state machine that guards the
money. As in every chapter, the tests are the specification.

=== Geohash: space as a string

Bisect longitude and latitude alternately, five bits per character, and
every coordinate becomes a string whose prefixes are its containing
cells. `decode` returns the cell *center* — a geohash names a region,
not a point.

```rust
const BASE32: &[u8; 32] = b"0123456789bcdefghjkmnpqrstuvwxyz";

pub fn encode(lon: f64, lat: f64, precision: usize) -> String {
    let (mut lon_lo, mut lon_hi) = (-180.0_f64, 180.0_f64);
    let (mut lat_lo, mut lat_hi) = (-90.0_f64, 90.0_f64);
    let mut out = String::with_capacity(precision);
    let mut even = true; // even bits refine longitude, odd bits latitude
    for _ in 0..precision {
        let mut ch: u8 = 0;
        for _ in 0..5 {
            ch <<= 1;
            if even {
                let mid = (lon_lo + lon_hi) / 2.0;
                if lon >= mid { ch |= 1; lon_lo = mid; } else { lon_hi = mid; }
            } else {
                let mid = (lat_lo + lat_hi) / 2.0;
                if lat >= mid { ch |= 1; lat_lo = mid; } else { lat_hi = mid; }
            }
            even = !even;
        }
        out.push(BASE32[ch as usize] as char);
    }
    out
}

pub fn decode(cell: &str) -> (f64, f64) {
    let (mut lon_lo, mut lon_hi) = (-180.0_f64, 180.0_f64);
    let (mut lat_lo, mut lat_hi) = (-90.0_f64, 90.0_f64);
    let mut even = true;
    for &b in cell.as_bytes() {
        let mut v = BASE32.iter().position(|&c| c == b).unwrap() as u8;
        for _ in 0..5 {
            let bit = v >> 4;              // consume bits, MSB first
            v = (v << 1) & 0b11111;
            if even {
                let mid = (lon_lo + lon_hi) / 2.0;
                if bit == 1 { lon_lo = mid; } else { lon_hi = mid; }
            } else {
                let mid = (lat_lo + lat_hi) / 2.0;
                if bit == 1 { lat_lo = mid; } else { lat_hi = mid; }
            }
            even = !even;
        }
    }
    ((lon_lo + lon_hi) / 2.0, (lat_lo + lat_hi) / 2.0) // cell center
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_lands_inside_the_cell() {
        let (lon, lat) = (-73.9857, 40.7484); // Manhattan
        let cell = encode(lon, lat, 7);       // ~150 m cells
        let (clon, clat) = decode(&cell);
        assert!((clon - lon).abs() < 0.01);
        assert!((clat - lat).abs() < 0.01);
    }

    #[test]
    fn prefixes_are_containment() {
        let (lon, lat) = (-73.9857, 40.7484);
        let fine   = encode(lon, lat, 8);
        let coarse = encode(lon, lat, 5);
        assert!(fine.starts_with(&coarse)); // "zoom out" = drop a char
    }
}
```

=== The geo index: built for churn

One hash map from cell to drivers, one from driver to cell, and a move
becomes two O(1) updates. `nearby` widens the prefix one character at a
time until enough candidates surface — recall from cells, precision from
the distance sort that would follow in the routing engine.

```rust
use std::collections::{HashMap, HashSet};

pub struct GeoIndex {
    cells: HashMap<String, Vec<u64>>, // cell → drivers inside it
    where_: HashMap<u64, String>,     // driver → its current cell
    precision: usize,
}

impl GeoIndex {
    pub fn new(precision: usize) -> Self {
        GeoIndex { cells: HashMap::new(), where_: HashMap::new(), precision }
    }

    pub fn upsert(&mut self, driver: u64, lon: f64, lat: f64) {
        let cell = encode(lon, lat, self.precision);
        if self.where_.get(&driver) == Some(&cell) { return; } // no cell change
        if let Some(old) = self.where_.insert(driver, cell.clone()) {
            if let Some(list) = self.cells.get_mut(&old) {
                list.retain(|&d| d != driver);
            }
        }
        self.cells.entry(cell).or_default().push(driver);
    }

    pub fn remove(&mut self, driver: u64) { // offline, or TTL swept
        if let Some(old) = self.where_.remove(&driver) {
            if let Some(list) = self.cells.get_mut(&old) {
                list.retain(|&d| d != driver);
            }
        }
    }

    /// Ring expansion: exact cell, then parent prefix, then grandparent…
    pub fn nearby(&self, lon: f64, lat: f64, limit: usize) -> Vec<u64> {
        let mut found = Vec::new();
        let mut seen = HashSet::new();
        let mut prefix = encode(lon, lat, self.precision);
        while !prefix.is_empty() && found.len() < limit {
            for (cell, list) in &self.cells {
                if cell.starts_with(&prefix) {
                    for &d in list {
                        if seen.insert(d) { found.push(d); }
                    }
                }
            }
            prefix.pop(); // zoom out one ring
        }
        found.truncate(limit);
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nearby_finds_local_drivers_only() {
        let mut idx = GeoIndex::new(6);
        idx.upsert(1, -73.9857, 40.7484);   // beside the pickup
        idx.upsert(2, -73.9857, 40.7484);
        idx.upsert(3, -122.4194, 37.7749);  // San Francisco: never matches
        let mut got = idx.nearby(-73.9857, 40.7484, 10);
        got.sort_unstable();
        assert_eq!(got, vec![1, 2]);
    }

    #[test]
    fn moving_a_driver_rebuckets_them() {
        let mut idx = GeoIndex::new(6);
        idx.upsert(7, -73.9857, 40.7484);   // starts in Manhattan
        idx.upsert(7, -122.4194, 37.7749);  // teleports to SF
        assert!(idx.nearby(-73.9857, 40.7484, 10).is_empty());
        assert_eq!(idx.nearby(-122.4194, 37.7749, 10), vec![7]);
    }

    #[test]
    fn going_offline_removes_the_driver() {
        let mut idx = GeoIndex::new(6);
        idx.upsert(9, -73.9857, 40.7484);
        idx.remove(9);
        assert!(idx.nearby(-73.9857, 40.7484, 10).is_empty());
    }
}
```

The reference scans cell keys per ring — O(cells) per widening step,
fine for one city shard; production H3 deployments precompute neighbor
rings or keep per-resolution maps so widening touches only the ring's
cells. The important invariant is unchanged either way: *no driver ever
appears in two cells at once*, because `upsert` removes before it adds.

=== The matcher: a window, sorted edges, two sets

```rust
use std::collections::HashSet;

/// One batched window: pair riders with drivers, cheapest pickup first.
/// Positions are (id, lon, lat); squared distance is enough for ordering.
pub fn match_greedy(drivers: &[(u64, f64, f64)],
                    riders:  &[(u64, f64, f64)]) -> Vec<(u64, u64)> {
    let mut edges: Vec<(f64, u64, u64)> = Vec::new(); // (dist², driver, rider)
    for &(d, dlon, dlat) in drivers {
        for &(r, rlon, rlat) in riders {
            let (dx, dy) = (dlon - rlon, dlat - rlat);
            edges.push((dx * dx + dy * dy, d, r));
        }
    }
    edges.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap()
                            .then(a.1.cmp(&b.1))
                            .then(a.2.cmp(&b.2)));

    let mut used_drivers = HashSet::new();
    let mut used_riders = HashSet::new();
    let mut pairs = Vec::new();
    for &(_, d, r) in &edges {
        // Check BOTH endpoints before inserting either: inserting the
        // driver first would burn it on a rider who is already taken.
        if !used_drivers.contains(&d) && !used_riders.contains(&r) {
            used_drivers.insert(d);
            used_riders.insert(r);
            pairs.push((d, r));
        }
    }
    pairs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greedy_pairs_each_with_the_closest() {
        let drivers = vec![(1, 0.0, 0.0), (2, 1.0, 1.0)];
        let riders  = vec![(10, 0.05, 0.05), (20, 1.05, 1.05)];
        assert_eq!(match_greedy(&drivers, &riders), vec![(1, 10), (2, 20)]);
    }

    #[test]
    fn batching_beats_first_come_first_served() {
        // Serial dispatch serves rider 10 first: its nearest is driver 2
        // (24.01 < 26.01), leaving rider 20 to driver 1 — total 122.02.
        // The window sees both sides and pays 26.02 instead.
        let drivers = vec![(1, 0.0, 0.0), (2, 10.0, 0.0)];
        let riders  = vec![(10, 5.1, 0.0), (20, 9.9, 0.0)];
        assert_eq!(match_greedy(&drivers, &riders), vec![(2, 20), (1, 10)]);
    }

    #[test]
    fn imbalanced_market_leaves_a_rider_for_the_next_window() {
        let drivers = vec![(1, 0.0, 0.0)];
        let riders  = vec![(10, 0.1, 0.1), (20, 0.2, 0.2)];
        assert_eq!(match_greedy(&drivers, &riders), vec![(1, 10)]);
    }
}
```

=== The trip state machine: legality lives here

```rust
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State { Requested, Matched, Arriving, InProgress, Completed, Cancelled }

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Event { Match, DriverArrived, StartTrip, Finish, Cancel }

/// The only legal moves. `None` = reject (HTTP 409); the app never
/// writes state directly, so this function IS the trip's law.
pub fn next(state: State, event: Event) -> Option<State> {
    use Event::*;
    use State::*;
    match (state, event) {
        (Requested, Match)       => Some(Matched),
        (Matched, DriverArrived) => Some(Arriving),
        (Arriving, StartTrip)    => Some(InProgress),
        (InProgress, Finish)     => Some(Completed),
        // Cancellation is legal until completion; mid-trip cancels
        // still bill for distance covered.
        (Requested, Cancel) | (Matched, Cancel)
        | (Arriving, Cancel) | (InProgress, Cancel) => Some(Cancelled),
        _ => None, // terminal states, skipped steps, replayed events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn happy_path_reaches_completed() {
        let mut s = State::Requested;
        for e in [Event::Match, Event::DriverArrived, Event::StartTrip, Event::Finish] {
            s = next(s, e).expect("legal transition");
        }
        assert_eq!(s, State::Completed);
    }

    #[test]
    fn illegal_transitions_are_rejected_not_handled() {
        assert_eq!(next(State::Requested, Event::Finish), None);    // no driver yet
        assert_eq!(next(State::Requested, Event::StartTrip), None); // skipped steps
        assert_eq!(next(State::Completed, Event::Cancel), None);    // terminal
        assert_eq!(next(State::Cancelled, Event::Match), None);     // terminal
    }

    #[test]
    fn cancellation_closes_at_completion() {
        assert_eq!(next(State::Matched, Event::Cancel), Some(State::Cancelled));
        assert_eq!(next(State::InProgress, Event::Cancel), Some(State::Cancelled));
        assert_eq!(next(State::Completed, Event::Cancel), None);
    }
}
```

Paired with an idempotency-keyed event API and a compare-and-set on the
trip row, this function gives the marketplace its spine: replays return
the stored outcome, races have one winner, and every charge the payments
pipeline ever sees traces back to a single, legal `Finish`.

== Scaling

*The city shard is the unit of everything.* Each city runs its own geo
index, matcher, trip store, and surge loop; adding capacity means
splitting a hot city into two stacks along a geographic seam and
re-homing the cells — a config change, not a migration of state machines,
because trips never straddle the seam (a cross-border pickup is handed
off once, at request time, to the city that owns the pickup cell). This
is Chapter 9's lesson applied deliberately: the coordination boundary is
drawn where the physics already is.

*Location ingest* scales horizontally by driver-id hash; any ingest node
can re-bucket any driver because the geo index is the system of record
for "where," not the nodes in front of it. *Matching* scales by cell
partition: disjoint pickup regions can run windows in parallel, with a
thin arbitration layer for boundary cells. *The trip store* is ordinary
Chapter 8 sharding — by `trip_id`, with a rider-id secondary index for
history pages — and is deliberately the least exotic component in the
building.

The one piece that resists scaling-by-addition is the *surge loop's
global view* of a city: per-cell counts aggregate upward through a
hierarchy (Chapter 6's top-k trick in geographic clothing), so even this
reduces to a streaming aggregation problem we have solved before.

== Failure Modes

#tbl(
  (1.5fr, 2.2fr, 2.4fr),
  header: (
    hcell[Failure],
    hcell[Symptom],
    hcell[Response],
  ),
  body: (
    [Driver app dies mid-offer],
    [Offer never answered],
    [Offer TTL (15 s) expires; driver released to next window; rider
     re-entered with original timestamp],
    [Driver stops sending location],
    [Position goes stale in the index],
    [TTL sweeper evicts after ~15 s; driver marked offline; in-flight
     trips continue on rider-reported position],
    [Matcher node crashes],
    [One window's pairings lost],
    [Requests are durable in the gateway queue; next window re-matches
     them — matching state is disposable *by design*],
    [Trip store primary fails],
    [Transitions stall in one shard],
    [Failover to the shard replica (Ch. 11 durability); events queue on
     the API with their idempotency keys and replay after recovery],
    [Payment capture times out],
    [`COMPLETED` trip, no settled charge],
    [The charge command retries with key `(trip_id, "charge")` until
     acked — effectively-once, never twice (Ch. 10)],
    [City network partition],
    [Riders and drivers split across two halves],
    [Both halves keep working with degraded pools (availability
     asymmetry); the trip store accepts no writes it cannot confirm —
     no phantom trips, some unmatched riders],
    [Surge loop goes haywire],
    [Multiplier oscillates or spikes],
    [Hard cap + floor, smoothing window, and a kill switch per city —
     pricing is a control loop and gets a circuit breaker],
  ),
)

#insight([The asymmetry is the design])[
  Notice what each row protects. The real-time side (offers, positions,
  windows) responds to failure by *discarding and retrying* — stale
  soft state is worthless anyway. The backbone (trips, charges) responds
  by *persisting and replaying* — a lost hard state is a lawsuit. A
  system that knows which half it is in at every line of code is a
  system that can be operated at 3 a.m.
]

== Trade-offs

#tbl(
  (1.5fr, 2.2fr, 2.2fr),
  header: (
    hcell[Decision],
    hcell[Chosen],
    hcell[Declined, and why],
  ),
  body: (
    [Geo structure],
    [Flat cells, in-memory, O(1) re-bucket],
    [R-tree: exact but mutation-hostile at 2.5 × 10⁵ moves/s; recall
     + post-filter beats exact indexing here],
    [Dispatch],
    [~2 s batched windows, greedy assignment],
    [Per-request nearest: serializes on offer TTLs and provably wastes
     aggregate pickup time; Hungarian optimum: 10× the compute for a
     sliver of quality at window scale],
    [Consistency of trips],
    [Strong, single city-primary, CAS transitions],
    [Multi-leader across regions: trips are local physics; buying
     cross-region consensus (Ch. 11's price) for a ride across town is
     a bad trade],
    [Location durability],
    [Soft state with TTL; losses self-heal in 4 s],
    [Persisting every heartbeat: 25 MB/s of WAL for data that is stale
     in 15 s — the textbook case *against* durability],
    [Surge authority],
    [Per-cell loop, capped, city kill switch],
    [Global optimization: prettier equilibrium, ungovernable blast
     radius; regulators and drivers both prefer legible cells],
    [Shared rides (pooling)],
    [Out of scope v1],
    [Matching becomes set-packing, ETAs become promises about other
     people's behavior — a whole second interview],
  ),
)

== Observability and SLOs

The four numbers on the on-call dashboard, and what each one *means*:

- *Match p99 latency ≤ 5 s* (request → `MATCHED`). The marketplace's
  heartbeat. Degradation means windows starved of supply — alert on
  per-cell supply/demand ratio, not on the latency itself, which is the
  symptom.
- *Location freshness: ≥ 99% of online drivers with a fix younger than
  15 s.* Below this, the index is lying and every downstream decision
  inherits the lie.
- *Transition success ≥ 99.99%, double-charge count = 0.* The backbone
  SLOs. The second is not a percentage: it is a count with an alarm at
  one, fed by reconciling the payments ledger against `COMPLETED` trips
  nightly (Chapter 10's reconciliation pattern).
- *Push delivery p99 ≤ 2 s* from committed transition to app
  notification, measured with synthetic trips per city (Chapter 4's
  golden signals end-to-end).

Log every offer, every transition, every charge decision with
`trip_id` as the join key — the trip's story must be replayable from
logs alone, because when a rider and a driver disagree about what
happened at 2 a.m., the log is the only witness.

== Interview Wrap-Up

What the interviewer is listening for, roughly in order:

+ *Did you notice the two-systems problem?* Soft real-time state versus
  hard transactional state, with different durability, consistency, and
  failure semantics. Candidates who treat driver locations like rows in
  Postgres have announced their level.
+ *Is your geo story churn-first?* Cells and prefixes, not trees; recall
  plus post-filter, not exactness; TTL as a correctness mechanism.
+ *Does matching have a time axis?* Batched windows beat serial dispatch;
  offers are expiring locks; declined and timed-out offers must recycle
  cleanly. If your matcher never waits and never batches, it is leaving
  minutes of pickup time on the table.
+ *Is the money boring?* State machine, idempotency keys, one charge per
  completed trip, reconciliation. The highest compliment a payments
  design can receive is that there is nothing clever about it.
+ *Do you know surge is a control loop?* Smoothing, asymmetric
  responsiveness, caps, kill switch — and the humility to say "tuned in
  production" rather than deriving a multiplier on the whiteboard.

#tip([The sixty-second answer])[
  "City-sharded marketplace. Drivers heartbeat into an in-memory cell
  index; riders request; a matcher batches two-second windows and solves
  near-optimal assignment with expiring offers; an accepted match enters
  a strongly consistent trip state machine that ends in exactly one
  idempotent charge; a per-cell surge loop prices scarcity. Everything
  real-time is soft state with TTLs; everything financial is a logged,
  replayable, transactional record." That paragraph is the whole chapter
  — the rest is proving you can build it.
]

== Summary and Further Reading

Ride-hailing compresses the whole playbook into one product: Chapter 1's
push channel carries the match, Chapter 2's geography becomes a churn-
tolerant cell index, Chapter 8's pages hold the trips, Chapter 9's
physics dictates the city shard, Chapter 10's scheduler times out the
offers, and Chapter 11's transactions guard the charge. The new muscle
is *economic*: matching as an online optimization under expiry, and
pricing as a feedback control loop. System design at this level stops
being about components and starts being about *which guarantees each
part can afford*.

Further reading: Uber Engineering's posts on H3 (hexagonal indexing) and
on their marketplace matching and surge stack; the S2 geometry library
docs for the spherical-geometry view; Kleinberg & Tardos, *Algorithm
Design*, for bipartite matching and online algorithms; and any control-
theory introduction — PID controllers in particular — before touching a
production pricing loop.

== Chapter Glossary

#tbl(
  (0.85fr, 2.6fr),
  header: (hcell[Term], hcell[Meaning in this chapter]),
  body: (
    [Geohash],
    [Interleaved lon/lat bits as a base-32 string; prefixes are
     containing cells, so spatial search becomes `starts_with`],
    [Cell / H3 / S2],
    [A fixed tile of the map used as an index bucket; hexagonal (H3) and
     spherical-cap (S2) successors to geohash's rectangles],
    [Ring expansion],
    [Widening a nearby-search by dropping prefix characters until enough
     candidates are found],
    [TTL sweeper],
    [The process that evicts drivers whose locations have gone stale;
     freshness as an index invariant],
    [Matching window],
    [The ~2 s batching interval that turns serial dispatch into a joint
     assignment problem],
    [Bipartite matching],
    [Pairing two disjoint sets (riders, drivers) with no shared
     endpoints; minimum-cost version solved by Hungarian, approximated
     by sorted greedy],
    [Offer token],
    [A 15 s exclusive lock on a driver; accept is a compare-and-set,
     timeout recycles the driver],
    [Deadheading],
    [Driving without a passenger; the cost matching and positioning
     exist to minimize],
    [Utilization],
    [Fraction of driver-online time spent earning; the marketplace's
     supply-side health metric],
    [Trip state machine],
    [`REQUESTED → MATCHED → ARRIVING → IN_PROGRESS → COMPLETED` /
     `CANCELLED`; the only legal moves, enforced server-side],
    [Terminal state],
    [`COMPLETED` or `CANCELLED`; accepts no further events, which makes
     replays and late packets harmless],
    [Idempotency key],
    [Client-chosen request identity; retries return the stored outcome —
     the API-level twin of Chapter 10's dedup],
    [Effectively-once],
    [At-least-once delivery plus key-based dedup; how one `Finish`
     becomes one charge],
    [Surge multiplier],
    [Per-cell price factor from smoothed demand/supply; capped,
     damped, kill-switchable],
    [Control loop],
    [Measure → compare → actuate, repeated; surge priced this way
     oscillates unless damped],
    [Feedback loophole],
    [Actors gaming the loop (drivers waiting out surge); mitigated by
     caps and opacity of the per-cell map],
    [City shard],
    [The unit of scale and failure: one city's full stack, strong
     consistency inside, none needed across],
    [Soft state / hard state],
    [Disposable, TTL-governed data (positions) versus durable,
     transactional data (trips, charges) — the chapter's organizing
     split],
    [Compare-and-set (CAS)],
    [Atomic "update only if unchanged"; how offers accept and states
     transition with exactly one winner],
    [Reconciliation],
    [Nightly ledger-versus-trips audit; the alarm that makes
     "double charges = 0" a fact instead of a hope],
  ),
)

#v(1.2em)
#align(center)[#text(fill: slate, size: 9.5pt)[
  — End of Chapter 12 · Next: Chapter 13 —
]]
