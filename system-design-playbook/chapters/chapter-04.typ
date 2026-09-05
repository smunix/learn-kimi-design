// ============================================================================
//  CHAPTER 4 — DISTRIBUTED LOGGING & METRICS PLATFORM
//  Source problem: "14: Distributed Logging & Metrics Framework"
//  (Systems Design Interview Questions With Ex-Google SWE, Jordan has no life)
// ============================================================================

#import "../template.typ": *

= Designing a Logging & Metrics Platform

#block(fill: faint, radius: 6pt, inset: (x: 14pt, y: 11pt), width: 100%)[
  #set text(size: 9.2pt)
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 8pt, weight: "bold", fill: slate, tracking: 0.1em)[PROBLEM SOURCE]
  #v(4pt)
  This chapter solves the problem posed in the talk
  #link("https://www.youtube.com/watch?v=p_q-n09B8KA")[*"14: Distributed Logging & Metrics Framework"*]
  from the series _Systems Design Interview Questions With Ex-Google SWE_
  (channel: _Jordan has no life_). The talk designs the observability backbone
  for a microservices fleet: how telemetry leaves thousands of hosts, where it
  is buffered, how logs and metrics are stored and queried, and how alerts fire.
  This chapter follows the same arc, deepened with full definitions, capacity
  mathematics, query and retention design, and Rust reference implementations.
]

#v(0.4em)

== The Problem Statement

The interviewer looks up and says:

#block(inset: (left: 14pt), stroke: (left: 2pt + primary), above: 0.9em, below: 0.9em)[
  #text(style: "italic", size: 10.5pt)[
    "We run thousands of services across tens of thousands of machines. When
    something breaks at 3 a.m., engineers need to see what happened — search
    every log, graph every metric, and get paged before users notice. Design
    the logging and metrics platform that makes that possible."
  ]
]

The previous chapters designed systems that *serve users*. This one designs the
system that watches all of them — including, recursively, the ones from
Chapters 1–3. It is a data pipeline problem wearing an operations costume: an
enormous, never-ending write stream on one side, and on the other a handful of
humans asking very expensive questions at the worst possible moment (during an
outage, when both data volume and query volume spike together).

#defterm([Observability / telemetry])[
  The ability to answer questions about a system's internal state from its
  *outputs*: the data it emits as it runs. _Telemetry_ is that emitted data.
  The canonical "three pillars" are *logs* (timestamped event records),
  *metrics* (numeric measurements over time), and *traces* (the path of one
  request through many services). This chapter designs the platform for the
  first two; traces are a follow-up (Section 4.18).
]

#defterm([Log vs. metric])[
  A _log record_ is a discrete, semi-structured event: "at 03:14:22.017,
  service `checkout` on host `i-9f2` logged `ERROR payment timeout user=…`" —
  high volume, low per-record value, queried by *searching text*. A _metric_ is
  a named numeric measurement repeated over time:
  `http_requests_total{service="checkout", status="500"} = 87341` — small,
  structured, queried by *range scans and aggregations*. They look like cousins
  and demand opposite storage engines. Holding that distinction is the core of
  this chapter (Section 4.6).
]

== Scope & Clarifying Questions

#tbl(
  (auto, 1fr),
  header: (hcell[Speaker], hcell[Dialogue]),
  body: (
    [*Candidate*], ["What's in scope — logs, metrics, distributed tracing, all three?"],
    [*Interviewer*], ["Logs and metrics. Tracing is a future extension; don't design it, but don't preclude it."],
    [*Candidate*], ["Scale of the fleet being observed?"],
    [*Interviewer*], ["About 50,000 service instances across a few thousand hosts, in several regions."],
    [*Candidate*], ["How quickly must emitted data be queryable?"],
    [*Interviewer*], ["Logs within about a minute; metrics within about thirty seconds. Alerts within a minute of the condition."],
    [*Candidate*], ["How long do we keep data?"],
    [*Interviewer*], ["Logs: two weeks fast-searchable, three months retrievable. Metrics: thirteen months, and nobody needs per-15-second resolution on data from last year."],
    [*Candidate*], ["Is some data loss acceptable under extreme overload?"],
    [*Interviewer*], ["Metrics — yes, they're statistical; drop samples rather than fall over. Logs — avoid it; engineers notice gaps. State how you'd degrade."],
    [*Candidate*], ["Who queries, and how often?"],
    [*Interviewer*], ["A few thousand engineers. Dashboards refresh continuously; searches spike during incidents."],
  ),
)

#block(fill: faint-blue, radius: 6pt, inset: (x: 14pt, y: 10pt), width: 100%)[
  #set text(size: 9.2pt)
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 8pt, weight: "bold", fill: primary, tracking: 0.1em)[AGREED SCOPE]
  #v(4pt)
  Logs + metrics for a *50k-instance* fleet. Logs: full-text search, queryable
  ≤ 1 min after emission, 2 weeks hot + 3 months cold. Metrics: label-filtered
  queries and dashboards, fresh ≤ 30 s, 13 months retained with downsampling.
  Alerting on both, notification ≤ 1 min from condition. Metrics may drop under
  extreme load; logs degrade by *sampling*, never silent gaps.
]

== Functional Requirements

+ *FR-1 — Collection.* Every instance's logs and metrics flow to the platform
  automatically, within seconds of emission, with no per-service plumbing by
  engineers.
+ *FR-2 — Log search.* Engineers query logs by full text, structured fields,
  and time range; results over hot data return in seconds.
+ *FR-3 — Metric queries & dashboards.* Engineers query series by name and
  labels over time ranges, with aggregations (rate, sum, percentile), rendered
  as auto-refreshing dashboards.
+ *FR-4 — Alerting.* Rules over logs and metrics evaluate continuously; when a
  condition holds for its configured duration, notifications fire — once, not
  repeatedly (Section 4.12).
+ *FR-5 — Retention & tiering.* Data ages automatically through hot → warm →
  cold → deleted, per configured policy, with no manual intervention.
+ *FR-6 — Self-service config.* Teams register services, set retention, and
  define alerts through an API/UI — the platform team is not in the loop.

== Non-Functional Requirements

#defterm([Ingestion latency (freshness, telemetry sense)])[
  The time from an event being emitted on a host to it being *queryable*.
  Chapter 2's freshness measured data age; this one measures pipeline speed.
  Our targets: logs ≤ 60 s, metrics ≤ 30 s — fast enough that an engineer
  watching a deploy sees its effect while watching.
]

#tbl(
  (auto, 1fr),
  header: (hcell[Quality], hcell[Target]),
  body: (
    [*Ingestion throughput*], [~10M log events/s average, 3× that in bursts; ~0.7M metric samples/s (Section 4.5)],
    [*Ingestion latency*], [Logs queryable ≤ 60 s; metrics ≤ 30 s],
    [*Query latency*], [Hot log search p95 ≤ 5 s; dashboard refresh ≤ 2 s],
    [*Durability*], [Logs: at-least-once, gaps are visible and rare. Metrics: loss-tolerant by nature (sampling tolerates gaps)],
    [*Availability*], [Ingestion path ≥ 99.9% — it is the fleet's black-box recorder; query path may degrade first],
    [*Cost discipline*], [Storage dominates; compression and tiering are first-class requirements, not optimizations],
  ),
)

#insight([The system's worst day is everyone else's])[
  When the fleet has an incident, two things happen at once: services emit
  *more* telemetry (error storms, stack traces) and engineers query *harder*
  (everyone opens dashboards). The platform must be sized for the correlated
  spike — the day it is needed most is the day it is loaded most. This
  observation drives the buffer-first architecture of Section 4.11.
]

== Back-of-the-Envelope Estimation

*Assumptions:*

- 50k service instances; each emits ~200 log lines/s average (quiet services
  less, chatty ones more), ~200 B per line.
- Each instance exposes ~200 metric series (name + label combinations);
  sampled every 15 s.
- Dashboards/searches: ~2k engineers, spiking to ~5k queries/s during
  incidents.

*Derived numbers:*

#tbl(
  (1.25fr, 0.9fr, 1.3fr),
  header: (hcell[Quantity], hcell[Estimate], hcell[How]),
  body: (
    [Log event rate], [≈ 10M events/s avg, ~30M burst], [50k instances × 200 lines/s, ×3 incident factor],
    [Log bandwidth], [≈ 2 GB/s avg], [10M × 200 B],
    [Raw logs per day], [≈ 170 TB], [2 GB/s × 86,400 s],
    [Hot log tier (14 days)], [≈ 0.5–1 PB], [sampling/filtering trims to ~30–50 TB/day indexed; × 14 days, plus index overhead],
    [Metric sample rate], [≈ 0.7M samples/s], [50k × 200 series ÷ 15 s],
    [Metric storage per day], [≈ 120 GB *compressed*], [0.7M/s × 86,400 s × ~2 B per compressed sample (Section 4.9)],
    [Metrics, 13 months], [tens of TB], [after rollups; an order of magnitude less than logs' *daily* raw volume],
    [Buffer capacity], [≈ 2–5 GB/s sustained], [a Kafka-class cluster of ~20–30 brokers, ~200 partitions],
  ),
)

#insight([What the math tells us])[
  Two facts shape everything. First, *logs are the cost center*: ~170 TB/day
  raw versus metrics' ~120 GB/day — three orders of magnitude apart. Storage
  design for logs is really *cost* design (sampling, tiering, compression);
  storage design for metrics is *query-shape* design (fast range scans over
  tiny values). Second, the write rate utterly dwarfs the query rate, so the
  system is organized as a pipeline: absorb first, index second, query third.
]

== The Core Challenge: One Firehose, Two Shapes of Data

Logs and metrics arrive on the same wire from the same hosts — and must part
ways immediately, because they are different kinds of data with different query
patterns and different economics:

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Property], hcell[Logs], hcell[Metrics]),
  body: (
    [Record], [Semi-structured text event], [Name + labels + (timestamp, number)],
    [Volume], [~170 TB/day raw], [~120 GB/day compressed],
    [Per-record value], [Low individually; priceless during one incident], [Low individually; aggregates are the product],
    [Query pattern], [Full-text search, field filters, recent time ranges], [Range scan by name/labels; aggregations over time],
    [Index needed], [Inverted index over tokens (Section 4.8)], [Compressed time-ordered blocks (Section 4.9)],
    [Loss tolerance], [Low — gaps break investigations], [High — statistics tolerate dropped samples],
  ),
)

#pitfall([One store for both])[
  The classic junior move: "just put it all in one database." Indexing metrics
  as log lines wastes the log pipeline's expensive text machinery on tiny
  numbers; storing logs in a time-series engine forfeits text search entirely.
  The chapter's architecture forks *right after the buffer* into two
  purpose-built stores — Section 4.8 and 4.9 exist because this fork exists.
]

== Data Ingestion: Agents, Push vs. Pull, and the Buffer

#defterm([Telemetry agent])[
  A small daemon running on every host (or beside every workload as a
  sidecar), owned by the platform team: it tails log files, collects or
  receives metrics, batches, compresses, and ships both upstream — buffering
  locally when upstream is unavailable. Agents are how collection (FR-1)
  happens "automatically": a service writes to stdout and exposes a metrics
  endpoint; the agent does the rest.
]

The one genuine design fork in collection is *who initiates the metrics
transfer*:

#defterm([Push vs. pull (scrape)])[
  _Push_: the source (or its agent) sends metrics upstream when it has them.
  _Pull_: the collector periodically *requests* metrics from each target's
  endpoint ("scrapes" `/metrics` every 15 s). Pull gives the collector control
  of sample timing, automatic *up/down detection* (a target that doesn't answer
  is itself a signal), and easy correctness (one place enforces the schedule).
  Push fits short-lived jobs that vanish before they can be scraped, and
  crossing trust boundaries outward. Production fleets commonly run both: pull
  for services, push gateways for batch jobs.
]

#defterm([Backpressure])[
  What a pipeline does when a downstream stage is slower than upstream: the
  pressure must propagate backward and be *absorbed somewhere* — a queue grows,
  a producer is slowed, or data is deliberately shed. A pipeline without a
  backpressure plan converts every slow consumer into a cascading outage. Our
  answer: a durable buffer between agents and processors, plus explicit
  drop policies per data class (metrics shed first, logs sampled — Section
  4.2's degradation agreement).
]

#insight([The buffer is the shock absorber])[
  A Kafka-class log (Chapter 2) between agents and processors buys four things
  at once: spikes are absorbed (the incident-storm insight of Section 4.4);
  indexing can lag and replay after outages; a bad deploy of the indexing fleet
  costs *lag*, not data; and new consumers (the future tracing pipeline, a
  billing tap) attach without touching producers. Decoupling ingestion from
  indexing is the single highest-leverage decision in the chapter.
]

And a deliberate callback: the buffer's tenants are protected from each other
with per-team *ingestion quotas* — Chapter 3's rate limiter, applied to
telemetry. One team's debug-level flood must not evict everyone else's logs.

== Log Storage: The Inverted Index

Log search answers "find the records containing these tokens, in this time
range, with these field values, among billions of records" in seconds. A scan
is impossible; the index must be inverted.

#defterm([Inverted index / posting list])[
  The data structure behind every text search engine: a map from *token* to the
  sorted list of records containing it (the _posting list_). `"payment"` →
  [rec 17, rec 203, rec 8811, …]. A query like `payment AND timeout`
  intersects two posting lists — set intersection over sorted lists, not a scan
  of the data. Building the index is work done *at write time* so that reads
  stay fast: logs are a write-once, read-rarely, read-expensively workload, and
  the inverted index prices exactly that.
]

#defterm([Tokenization / structured logging])[
  _Tokenization_ splits raw text into searchable terms (lower-cased, split on
  punctuation). _Structured logging_ emits logs as JSON records —
  `{"level":"ERROR","service":"checkout","msg":"payment timeout",...}` — so
  fields are indexed *as fields* (`service:checkout`) rather than dug out of
  text at query time. The platform ingests both; structure makes queries faster
  and sampling smarter, and FR-6's self-service story nudges teams toward it.
]

Three storage decisions carry the load:

+ *Immutable segments, merged in the background.* Incoming records are buffered
  into small index *segments* written to disk immutably; a background process
  merges small segments into larger ones. Appends and merges are sequential
  I/O — the cheapest disk work there is (same lesson as Chapter 1's operation
  log).
+ *Sharding by time.* The index is partitioned into time buckets (e.g., one
  index per day per tenant class). Queries prune whole days by timestamp before
  touching a posting list — and *retention becomes deletion of an old index
  file*, not a billion per-record deletes. Time-sharding turns FR-5 into `rm`.
+ *Hot / warm / cold tiers.* Today's indices live on fast SSD nodes with
  replicas (hot); last week's on cheaper nodes (warm); months-old data as
  compressed archives in object storage (cold), rehydrated on the rare
  historical query. Cost per GB falls by an order of magnitude per tier —
  Section 4.5 made clear this *is* the design.

== Metrics Storage: The Time-Series Database

#defterm([Time series / sample / label set])[
  A _time series_ is a named, labeled sequence of *(timestamp, value)* pairs:
  `http_requests_total{service="checkout", status="500"}` sampled every 15 s.
  A _sample_ is one such pair. The _labels_ (tags) are the dimensions queries
  filter and group by. The number of *distinct series* — the product of all
  label-value combinations — is the _cardinality_, and it is the metric
  system's one true nemesis.
]

#pitfall([Cardinality explosion])[
  Labels must be *dimensions*, never *identifiers*. `status="500"` is a
  dimension (a handful of values); `user_id="u_91827"` is an identifier —
  millions of series, each seen once, index structures bloated beyond RAM,
  queries scanning garbage. Rule of thumb: a label whose value set grows with
  *traffic or users* does not belong on a metric; it belongs in a log or a
  trace. Every metrics interview eventually arrives here — arrive first.
]

Why a purpose-built store: samples of one series arrive in time order and
change slowly, so they compress almost to nothing:

#defterm([Delta encoding / delta-of-delta])[
  Store differences, not values. Timestamps sampled every 15 s delta-encode to
  a constant 15000 ms; the *delta-of-delta* (difference of consecutive deltas)
  is 0 almost always — compressible to a single bit per timestamp in the
  production scheme (Facebook's Gorilla, which also XOR-encodes values so only
  meaningful bits are stored). ~16-byte samples become ~1–2 bytes. Section
  4.13 implements the delta+zigzag+varint core of the idea.
]

#defterm([Downsampling / rollup])[
  Replacing old high-resolution samples with precomputed aggregates — keep
  15-second resolution for a week, 1-minute for a quarter, 1-hour beyond:
  `avg/min/max/sum/count` per bucket, computable incrementally. Nobody asks for
  15-second data from last year (Section 4.2), and rollups turn 13 months of
  retention from a petabyte problem into a terabyte one.
]

Queries are then range scans over compressed blocks, sharded by metric-name
hash: fetch the blocks for matching series in the range, decompress, aggregate.
Dashboard panels are exactly this, cached and refreshed.

== API & Query Design

Three surfaces — ingestion, query, config — each deliberately boring:

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Method], hcell[Path], hcell[Purpose]),
  body: (
    [`POST`], [`/v1/logs:batch`], [Agent push: compressed batch of log records with source metadata],
    [`GET`], [`/metrics` (on targets)], [The scrape endpoint pull collectors call every 15 s],
    [`POST`], [`/v1/metrics:write`], [Push path for short-lived jobs],
    [`GET`], [`/v1/logs/search?q=&from=&to=`], [Log search: query string, time range, cursor-paginated],
    [`POST`], [`/v1/metrics/query`], [Instant and range queries over series],
    [`POST`], [`/v1/alerts/rules`], [Create/update alert rules (FR-4, FR-6); versioned like Chapter 3's rules],
  ),
)

Query languages, sketched to show the shape (not to design in full):

```text
-- logs: field filters + free text + time range
service:checkout AND level:ERROR AND "payment timeout"   @ last 1h

-- metrics: series selector + aggregation over a range
rate(http_requests_total{service="checkout", status=~"5.."}[5m])
  |> sum by (region)
```

Alert rules are records: `{ name, query, threshold, comparison, for_duration,
severity, notify_channels }` — evaluated by the alerting engine of Section
4.12.

== High-Level Architecture

#v(0.3em)
#align(center)[
#canvas(h: 7.4cm)[
  // producers
  #node(0.2cm, 0.1cm, 3.3cm, 1.0cm, [50k instances \ stdout + /metrics], fill: faint, edge: slate, size: 7.4pt)
  #node(4.5cm, 0.1cm, 3.3cm, 1.0cm, [Telemetry agents \ tail · scrape · batch], fill: white, edge: primary, size: 7.4pt)
  #node(9.2cm, 0.1cm, 3.5cm, 1.0cm, [Buffer \ Kafka-class, ~200 partitions], fill: white, edge: teal, size: 7.4pt)
  // fork
  #node(6.6cm, 2.15cm, 3.6cm, 0.9cm, [Log indexer \ tokenize · build segments], fill: white, edge: primary, size: 7.2pt)
  #node(11.4cm, 2.15cm, 3.6cm, 0.9cm, [Metrics writer \ compress · rollup], fill: white, edge: primary, size: 7.2pt)
  // stores
  #node(6.6cm, 4.1cm, 3.6cm, 0.95cm, [Log index \ hot SSD · warm · cold obj], fill: faint-blue, edge: primary, size: 7.2pt)
  #node(11.4cm, 4.1cm, 3.6cm, 0.95cm, [TSDB \ compressed blocks, by metric], fill: faint-blue, edge: primary, size: 7.2pt)
  // read path
  #node(0.2cm, 5.6cm, 3.4cm, 0.9cm, [Query layer \ search · PromQL-ish], fill: white, edge: slate, size: 7.4pt)
  #node(4.6cm, 5.6cm, 3.2cm, 0.9cm, [Dashboards & search UI], fill: white, edge: slate, size: 7.6pt)
  #node(9.6cm, 5.6cm, 3.4cm, 0.9cm, [Alerting engine \ evaluates rules], fill: white, edge: crimson, size: 7.4pt)
  #node(14.1cm, 5.6cm, 2.6cm, 0.9cm, [Notify \ page · chat · email], fill: faint-red, edge: crimson, size: 7.4pt)
  #node(14.1cm, 0.1cm, 2.6cm, 1.0cm, [Config \ rules · retention], fill: white, edge: amber.darken(15%), size: 7.4pt)
  // arrows producers to buffer
  #arrow(3.55cm, 0.6cm, 4.45cm, 0.6cm)
  #arrow(7.85cm, 0.6cm, 9.15cm, 0.6cm)
  #glabel(8.15cm, 0.28cm, [2 GB/s], size: 6.8pt)
  // buffer fork
  #arrow(10.1cm, 1.13cm, 8.4cm, 2.1cm, color: teal)
  #arrow(11.7cm, 1.13cm, 13.2cm, 2.1cm, color: teal)
  // processors to stores
  #arrow(8.4cm, 3.08cm, 8.4cm, 4.05cm)
  #arrow(13.2cm, 3.08cm, 13.2cm, 4.05cm)
  // query path
  #arrow(3.65cm, 6.0cm, 4.55cm, 6.0cm)
  #arrow(6.6cm, 4.6cm, 3.4cm, 5.55cm, color: slate)
  #arrow(11.4cm, 4.6cm, 5.0cm, 5.55cm, color: slate)
  // alerting
  #arrow(11.1cm, 6.05cm, 8.5cm, 5.05cm, color: crimson, dashed: true)
  #arrow(13.05cm, 6.05cm, 14.05cm, 6.05cm, color: crimson)
  // config fanout
  #arrow(15.4cm, 1.13cm, 15.4cm, 5.55cm, color: amber.darken(15%), dashed: true)
  #arrow(14.05cm, 2.6cm, 15.35cm, 1.15cm, color: amber.darken(15%), dashed: true)
  // labels
  #glabel(10.6cm, 1.5cm, [fork by data class], fg: teal.darken(12%), size: 6.8pt)
  #glabel(11.25cm, 5.3cm, [evaluate every 15–60 s], fg: crimson, size: 6.6pt)
  #glabel(0.2cm, 6.75cm, [One write path, two stores. The buffer absorbs incident storms; the query layer federates across both stores.], size: 7pt)
]]
#v(0.2em)

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Component], hcell[Responsibility], hcell[Why it is shaped this way]),
  body: (
    [Telemetry agents], [Tail logs, scrape/collect metrics, batch + compress, ship], [Per-host daemon = zero per-service work (FR-1); local buffer rides out upstream blips],
    [Buffer (Kafka-class)], [Durable, replayable queue between agents and processors], [The shock absorber of Section 4.7: spikes, replays, new consumers],
    [Log indexer], [Parse, tokenize, build inverted-index segments], [Stateless consumers of the log topic; scale with partition count],
    [Log index cluster], [Hot/warm/cold inverted indices, time-sharded], [Search needs posting lists; retention needs cheap tiers (Section 4.8)],
    [Metrics writer], [Compress samples into blocks; maintain rollups], [Stateless consumers of the metrics topic],
    [TSDB cluster], [Compressed time-series blocks; label index], [Range scans over ~2 B samples (Section 4.9)],
    [Query layer], [Federate queries across both stores; cache dashboard panels], [One door for engineers; caches absorb dashboard refresh storms],
    [Alerting engine], [Evaluate rules continuously; notify without flapping], [Section 4.12 — its correctness is the product's voice],
    [Config service], [Rules, retention, quotas; versioned, pushed], [Chapter 3's lesson: config never fetched on the hot path],
  ),
)

== Deep Dive: The Alerting Engine

Alerting is where the metrics store earns its keep. The engine's loop is
trivially stated — *every evaluation interval (15–60 s), run every rule's
query, compare against the threshold* — and the difficulty is entirely in not
crying wolf.

#defterm([Flapping / hysteresis / "for" duration])[
  _Flapping_: an alert that oscillates OK → FIRING → OK → FIRING as the metric
  jitters around the threshold, paging a human every oscillation until the rule
  is muted and the signal lost. The cures: a _"for" duration_ — the condition
  must hold continuously for N minutes before firing (a PENDING state); and
  _hysteresis_ — firing and clearing use *different* thresholds (fire at
  p99 > 500 ms for 5 min, clear only when p99 < 450 ms for 10 min), so a
  metric straddling one line cannot cross both. Alert fatigue is a *system
  failure mode*, and it is engineered against, exactly like throughput.
]

The per-rule state machine:

#align(center)[
#canvas(h: 3.0cm)[
  #node(0.5cm, 0.4cm, 3.0cm, 0.95cm, [OK \ condition false], fill: faint-teal, edge: teal.darken(10%), size: 7.6pt)
  #node(6.6cm, 0.4cm, 3.6cm, 0.95cm, [PENDING \ true, timer running], fill: faint-amber, edge: amber.darken(15%), size: 7.6pt)
  #node(13.2cm, 0.4cm, 3.2cm, 0.95cm, [FIRING \ notified], fill: faint-red, edge: crimson, size: 7.6pt)
  #arrow(3.55cm, 0.7cm, 6.55cm, 0.7cm, color: amber.darken(15%))
  #glabel(4.0cm, 0.15cm, [condition true], size: 6.8pt)
  #arrow(10.25cm, 0.7cm, 13.15cm, 0.7cm, color: crimson)
  #glabel(10.9cm, 0.15cm, [`for` elapsed], size: 6.8pt)
  #arrow(6.55cm, 1.12cm, 3.55cm, 1.12cm, color: slate, dashed: true)
  #glabel(3.75cm, 1.5cm, [false again → timer reset], size: 6.6pt)
  #arrow(14.8cm, 1.4cm, 14.8cm, 2.05cm, color: teal.darken(10%), dashed: true)
  #arrow(14.75cm, 2.05cm, 1.95cm, 2.05cm, color: teal.darken(10%), dashed: true)
  #arrow(1.9cm, 2.0cm, 1.9cm, 1.42cm, color: teal.darken(10%), dashed: true)
  #glabel(6.3cm, 2.42cm, [clear threshold passed → resolved notification], size: 6.6pt)
]]
#v(0.2em)

Three more engineering points:

- *Deduplication and grouping.* One dying dependency fires forty service
  alerts; the engine groups by root labels (`region`, `dependency`) into *one*
  page with the forty attached as context. Notifications are facts about
  *state transitions*, not about every evaluation.
- *Evaluation must be independent of ingestion health of the thing it watches.*
  If the alerting engine shares a failure domain with the metrics pipeline, the
  one outage that must page is the one that can't. It runs on separate
  infrastructure and — critically — can fire on *absence* of data (Section
  4.15).
- *Self-service with guardrails (FR-6).* Teams write rules in config; the
  platform validates them (query parses, series cardinality bounded, threshold
  sane) and versions every change, exactly the Chapter 3 rule-lifecycle
  pattern.

== Rust Reference Implementations

Four distilled pieces, each with a deterministic test. They are teaching
skeletons of what runs at platform scale: a mini inverted index for log
search, timestamp compression for the TSDB, incremental rollups, and the
alert state machine.

=== A Mini Inverted Index for Log Search

Structured records are tokenized; each token maps to a sorted posting list of
record ids. A two-term `AND` query intersects the lists in linear time.

```rust
use std::collections::HashMap;

/// One structured log record, as the indexer sees it after parsing.
#[derive(Debug, Clone)]
pub struct LogRecord {
    pub id: u64,
    pub timestamp_ms: u64,
    pub service: String,
    pub level: String,
    pub message: String,
}

/// Lower-case, split on anything that isn't alphanumeric:
/// "payment TIMEOUT after 3s" -> ["payment", "timeout", "after", "3s"].
fn tokenize(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(str::to_string)
        .collect()
}

/// token -> sorted ids of records containing it ("posting list").
/// Also index the searchable fields under `field:value` tokens so that
/// `service:checkout` is just another posting-list lookup.
#[derive(Default)]
pub struct InvertedIndex {
    postings: HashMap<String, Vec<u64>>,
}

impl InvertedIndex {
    pub fn add(&mut self, rec: &LogRecord) {
        let mut tokens = tokenize(&rec.message);
        tokens.push(format!("service:{}", rec.service.to_lowercase()));
        tokens.push(format!("level:{}", rec.level.to_lowercase()));
        tokens.sort();
        tokens.dedup();
        for tok in tokens {
            let list = self.postings.entry(tok).or_default();
            // ids are appended in increasing order, so lists stay sorted;
            // a real engine would also store positions for phrase queries.
            list.push(rec.id);
        }
    }

    pub fn lookup(&self, token: &str) -> &[u64] {
        self.postings.get(token).map(Vec::as_slice).unwrap_or(&[])
    }

    /// Intersection of two sorted lists: the heart of `A AND B`.
    pub fn and(&self, a: &str, b: &str) -> Vec<u64> {
        let (xs, ys) = (self.lookup(a), self.lookup(b));
        let (mut i, mut j, mut out) = (0, 0, Vec::new());
        while i < xs.len() && j < ys.len() {
            match xs[i].cmp(&ys[j]) {
                std::cmp::Ordering::Less => i += 1,
                std::cmp::Ordering::Greater => j += 1,
                std::cmp::Ordering::Equal => {
                    out.push(xs[i]);
                    i += 1;
                    j += 1;
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(id: u64, service: &str, level: &str, msg: &str) -> LogRecord {
        LogRecord { id, timestamp_ms: id, service: service.into(),
                    level: level.into(), message: msg.into() }
    }

    #[test]
    fn search_intersects_posting_lists() {
        let mut ix = InvertedIndex::default();
        ix.add(&rec(1, "checkout", "ERROR", "payment timeout after 3s"));
        ix.add(&rec(2, "checkout", "INFO",  "payment authorized"));
        ix.add(&rec(3, "search",   "ERROR", "timeout talking to index"));
        ix.add(&rec(4, "checkout", "ERROR", "payment timeout after 5s"));

        // free text
        assert_eq!(ix.lookup("timeout"), &[1, 3, 4]);
        // field query
        assert_eq!(ix.lookup("service:checkout"), &[1, 2, 4]);
        // the incident query: payment AND timeout, checkout only
        assert_eq!(ix.and("payment", "timeout"), &[1, 4]);
        assert_eq!(
            ix.and("service:checkout", "level:error")
                .into_iter()
                .collect::<Vec<_>>(),
            vec![1, 4]
        );
    }
}
```

Production engines add positions (for phrase queries), compression of posting
lists, skip pointers for faster intersection, and segment files instead of a
`HashMap` — but the *algorithm* the interviewer wants to hear is the sorted
intersection above, unchanged since the 1960s.

=== Delta + Zigzag + Varint: Compressing Timestamps

The honest core of Gorilla-style compression: store the first timestamp, then
*delta-of-deltas*; encode each as a zigzag varint so small numbers — including
small *negative* corrections — cost one byte.

```rust
/// Zigzag maps signed -> unsigned so small magnitudes (either sign)
/// become small unsigned ints: 0->0, -1->1, 1->2, -2->3, 2->4, ...
fn zigzag(n: i64) -> u64 {
    ((n << 1) ^ (n >> 63)) as u64
}
fn unzigzag(z: u64) -> i64 {
    ((z >> 1) as i64) ^ -((z & 1) as i64)
}

/// Unsigned varint: 7 bits per byte, high bit = "more bytes follow".
fn write_varint(mut z: u64, out: &mut Vec<u8>) {
    loop {
        let byte = (z & 0x7f) as u8;
        z >>= 7;
        if z == 0 { out.push(byte); break; }
        out.push(byte | 0x80);
    }
}
fn read_varint(bytes: &[u8], pos: &mut usize) -> u64 {
    let (mut z, mut shift) = (0u64, 0);
    loop {
        let byte = bytes[*pos];
        *pos += 1;
        z |= ((byte & 0x7f) as u64) << shift;
        if byte & 0x80 == 0 { return z; }
        shift += 7;
    }
}

/// Compress a sorted series of millisecond timestamps:
/// first value verbatim, then delta-of-delta as zigzag varints.
pub fn compress_timestamps(ts: &[u64]) -> Vec<u8> {
    assert!(!ts.is_empty());
    let mut out = Vec::new();
    write_varint(ts[0], &mut out);
    let (mut prev_ts, mut prev_delta) = (ts[0] as i64, 0i64);
    for w in ts.windows(2) {
        let delta = w[1] as i64 - prev_ts;
        let dod = delta - prev_delta;                 // 0 for a steady 15s scrape
        write_varint(zigzag(dod), &mut out);
        prev_ts = w[1] as i64;
        prev_delta = delta;
    }
    out
}

pub fn decompress_timestamps(bytes: &[u8], count: usize) -> Vec<u64> {
    let mut pos = 0;
    let first = read_varint(bytes, &mut pos) as i64;
    let mut out = vec![first as u64];
    let (mut prev_ts, mut prev_delta) = (first, 0i64);
    for _ in 1..count {
        let dod = unzigzag(read_varint(bytes, &mut pos));
        let delta = prev_delta + dod;
        prev_ts += delta;
        prev_delta = delta;
        out.push(prev_ts as u64);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zigzag_roundtrip_and_small_magnitudes() {
        for n in [-2, -1, 0, 1, 2, 15000, -15000] {
            assert_eq!(unzigzag(zigzag(n)), n);
        }
        assert_eq!(zigzag(-1), 1);
        assert_eq!(zigzag(0), 0);
    }

    #[test]
    fn steady_15s_scrape_compresses_to_about_a_byte_per_point() {
        let base = 1_700_000_000_000u64;           // some epoch-ms
        let ts: Vec<u64> = (0..1000).map(|i| base + i * 15_000).collect();
        let packed = compress_timestamps(&ts);
        assert_eq!(decompress_timestamps(&packed, ts.len()), ts);
        // 1000 x 8-byte timestamps -> ~1007 bytes: ~1 byte per point.
        assert!(packed.len() < 1100, "got {} bytes", packed.len());
    }

    #[test]
    fn jitter_and_gaps_survive_roundtrip() {
        // scrape jitter (+/- 3ms) plus one 30s gap where a sample was lost
        let mut ts = vec![1_000u64, 16_003, 31_002, 61_001, 75_997];
        let packed = compress_timestamps(&ts);
        assert_eq!(decompress_timestamps(&packed, ts.len()), ts);
        ts.clear(); // prove the bytes alone reconstruct everything
        assert!(ts.is_empty());
    }
}
```

Gorilla additionally XORs consecutive *values* and stores only meaningful
bit-runs — the same philosophy: at scale, the difference between 16 bytes and
1.4 bytes per sample is the difference between a petabyte and a rack.

=== Incremental Rollups for Retention

A rollup bucket carries just enough state to be mergeable: `sum`, `min`,
`max`, `count`. Raw samples stream in; the bucket answers the five aggregates
without remembering any sample.

```rust
/// One downsampled bucket: mergeable in O(1) without raw samples.
/// This is why rollups scale: merging two 1-hour buckets is
/// adding sums, taking min/max, adding counts.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bucket {
    pub sum: f64,
    pub min: f64,
    pub max: f64,
    pub count: u64,
}

impl Bucket {
    pub fn empty() -> Self {
        Bucket { sum: 0.0, min: f64::INFINITY, max: f64::NEG_INFINITY, count: 0 }
    }
    pub fn add(&mut self, value: f64) {
        self.sum += value;
        self.min = self.min.min(value);
        self.max = self.max.max(value);
        self.count += 1;
    }
    /// Merge another bucket's aggregates in O(1) — no raw samples needed.
    /// This associativity is exactly why rollups scale: two hour-buckets
    /// combine into a day-bucket with four cheap operations.
    pub fn merge(&mut self, other: &Bucket) {
        if other.count == 0 { return; }
        self.sum += other.sum;
        self.min = self.min.min(other.min);
        self.max = self.max.max(other.max);
        self.count += other.count;
    }
    pub fn avg(&self) -> Option<f64> {
        (self.count > 0).then(|| self.sum / self.count as f64)
    }
}

/// Assign a timestamp (ms) to its bucket of `width_ms`, then fold in.
pub fn rollup(samples: &[(u64, f64)], width_ms: u64)
    -> std::collections::BTreeMap<u64, Bucket>
{
    let mut buckets = std::collections::BTreeMap::new();
    for &(ts, v) in samples {
        buckets.entry(ts / width_ms).or_insert_with(Bucket::empty).add(v);
    }
    buckets
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rollup_buckets_match_hand_computation() {
        // 15s samples across two 1-minute buckets; base aligned to a
        // minute boundary so the first four samples share bucket 0.
        let t = 1_700_000_040_000u64; // == 28_333_334 * 60_000
        let samples: Vec<(u64, f64)> = (0..8)
            .map(|i| (t + i * 15_000, (100 + i * 10) as f64))
            .collect();
        let m = rollup(&samples, 60_000);
        let keys: Vec<u64> = m.keys().copied().collect();
        assert_eq!(keys.len(), 2);
        let b0 = m[&keys[0]];
        assert_eq!(b0.count, 4);                       // t, t+15s, t+30s, t+45s
        assert_eq!(b0.sum, 100.0 + 110.0 + 120.0 + 130.0);
        assert_eq!(b0.min, 100.0);
        assert_eq!(b0.max, 130.0);
        assert_eq!(b0.avg(), Some(115.0));
    }

    #[test]
    fn buckets_merge_without_raw_samples() {
        let mut a = Bucket::empty();
        for v in [10.0, 20.0, 30.0] { a.add(v); }
        let mut b = Bucket::empty();
        for v in [5.0, 50.0] { b.add(v); }
        a.merge(&b);
        assert_eq!(a.count, 5);
        assert_eq!(a.sum, 115.0);
        assert_eq!(a.min, 5.0);
        assert_eq!(a.max, 50.0);
        assert_eq!(a.avg(), Some(23.0));
    }
}
```

=== The Alert Evaluator: OK → PENDING → FIRING

The state machine of Section 4.12, made executable. The test demonstrates the
two failure modes it prevents: a single bad spike must *not* page (no `for`
violation), and a sustained breach must page *once*, not on every evaluation.

```rust
/// States of Section 4.12's machine. `pending_since` is Some(ms) while
/// the condition has been continuously true but `for_ms` hasn't elapsed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlertState {
    Ok,
    Pending { since_ms: u64 },
    Firing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Notification {
    Fired,
    Resolved,
}

pub struct AlertRule {
    pub threshold: f64,
    pub for_ms: u64,
}

pub struct AlertEvaluator {
    pub rule: AlertRule,
    state: AlertState,
}

impl AlertEvaluator {
    pub fn new(rule: AlertRule) -> Self {
        AlertEvaluator { rule, state: AlertState::Ok }
    }

    /// Feed one evaluation (one query result) at time `now_ms`.
    /// Returns a notification only on *transitions*.
    pub fn evaluate(&mut self, breached: bool, now_ms: u64) -> Option<Notification> {
        use AlertState::*;
        match (self.state, breached) {
            (Ok, true) => {
                self.state = Pending { since_ms: now_ms };
                None
            }
            (Pending { since_ms }, true) => {
                if now_ms - since_ms >= self.rule.for_ms {
                    self.state = Firing;
                    Some(Notification::Fired)          // page once
                } else {
                    None                               // still waiting
                }
            }
            (Firing, true) => None,                    // already paged; stay quiet
            (Firing, false) => {
                self.state = Ok;
                Some(Notification::Resolved)
            }
            (Pending { .. }, false) => {
                self.state = Ok;                       // spike ended: reset timer
                None
            }
            (Ok, false) => None,
        }
    }

    pub fn is_breach(&self, value: f64) -> bool {
        value > self.rule.threshold
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn evaluator() -> AlertEvaluator {
        AlertEvaluator::new(AlertRule { threshold: 500.0, for_ms: 300_000 })
    }

    #[test]
    fn single_spike_never_pages() {
        let mut ev = evaluator();
        // p99 jumps over threshold for one 15s evaluation, then recovers
        assert_eq!(ev.evaluate(true, 0), None);        // -> Pending
        assert_eq!(ev.evaluate(false, 15_000), None);  // recovered: reset
        assert_eq!(ev.state, AlertState::Ok);
    }

    #[test]
    fn sustained_breach_pages_once_then_resolves() {
        let mut ev = evaluator();
        let mut t = 0u64;
        let step = 60_000;                             // evaluate every minute
        let mut notes = Vec::new();
        // breach for 6 consecutive minutes, `for` = 5 minutes
        for _ in 0..6 {
            if let Some(n) = ev.evaluate(true, t) { notes.push((t, n)); }
            t += step;
        }
        // fired exactly once, when the timer elapsed (t = 5 min)
        assert_eq!(notes, vec![(300_000, Notification::Fired)]);
        // keep breaching: silence
        assert_eq!(ev.evaluate(true, t), None);
        // recovery -> one resolved notification
        assert_eq!(ev.evaluate(false, t + step), Some(Notification::Resolved));
        assert_eq!(ev.state, AlertState::Ok);
    }

    #[test]
    fn threshold_boundary_is_not_a_breach() {
        let ev = evaluator();
        assert!(!ev.is_breach(500.0));                 // strictly greater
        assert!(ev.is_breach(500.1));
    }
}
```

== Scaling the Platform

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Layer], hcell[Scale axis], hcell[Mechanism]),
  body: (
    [Agents], [Fleet size (50k+)], [Embarrassingly parallel: one per host; sizing is a per-host CPU/RAM budget, not a cluster problem],
    [Buffer], [Ingestion GB/s], [Partitions (~200) spread over ~20–30 brokers; keyed by tenant+service so one team's flood is contained and quota'd (Chapter 3 callback)],
    [Log indexers], [Events/s], [Stateless consumers, one per partition lane; autoscale on consumer lag],
    [Log index], [Data volume + query QPS], [Time-sharded indices spread over nodes; hot tier replicated; incident query storms absorbed by the query-layer cache],
    [Metrics writers], [Samples/s], [Stateless consumers; ~0.7M samples/s is small — headroom is free],
    [TSDB], [Series cardinality × retention], [Shard by metric-name hash; rollups shrink old data ~100× before it becomes a storage problem],
    [Alerting engine], [Rule count × eval rate], [Partition rules across evaluators by hash; evaluations are independent, so this scales linearly],
  ),
)

#insight([The incident storm is the sizing case])[
  Average load (2 GB/s) is not the design point; *everyone's worst day at once*
  is. An outage multiplies error logs 3–5×, and two thousand engineers open
  dashboards simultaneously. The buffer absorbs the write spike; the query
  cache absorbs the read spike; per-tenant quotas keep one service's panic
  from evicting the logs everyone else needs to debug it. A telemetry
  platform sized for the average is a platform that dies exactly when it is
  needed.
]

== Failure Modes & Degradation

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Failure], hcell[Symptom], hcell[Response]),
  body: (
    [Telemetry agent dies], [A host goes silent], [Agents buffer locally, so restarts lose nothing; and silence itself is a signal — a heartbeat-absence alert fires (the alerting engine evaluates *absence*, not just thresholds)],
    [Buffer fills / brokers down], [Agents' local buffers grow], [Local disk spooling buys hours; on recovery, consumers replay the backlog. Durability is the buffer's whole job],
    [Log indexer lags or crashes], [Search results fall behind ingest], [Lag is visible as a metric on the buffer (meta-observability, Section 4.17); stateless indexers are replaced and replay from last offset],
    [Index node lost], [A shard of one day's index unavailable], [Replicas on the hot tier serve queries; the shard is rebuilt from the buffer while it is still retained],
    [TSDB node lost], [Gap in dashboards], [Replicas; and because metrics are statistics, a brief gap degrades a chart without lying to an alert — `for` durations span it],
    [Alerting engine down], [The silent killer], [It runs in an *independent failure domain* (separate infra, separate credentials), and a meta-monitor outside the platform watches its heartbeat — Section 4.17],
    [Poison record crashes a parser], [One consumer stuck in a crash loop], [Dead-letter queue: N failed attempts → the record is parked aside, processing continues, an operator is notified],
    [Storage budget blown], [Hot tier at capacity], [Enforced sampling on the noisiest tenants (never silent gaps — Section 4.2), accelerated warm/cold migration, quota renegotiation],
  ),
)

#pitfall([Monitoring the monitor])[
  The most dangerous failure of an observability platform is *looking healthy
  while being blind*: dashboards render cached panels, no alerts fire, and
  meanwhile ingestion silently stopped. Every layer must therefore emit
  telemetry about itself into an *independent* pipeline — if the platform's
  own metrics flow through the platform, its failure erases its own
  death certificate. Section 4.17 formalizes this as meta-observability.
]

== Trade-offs & Alternatives

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Decision], hcell[Chosen], hcell[Alternative & why not (here)]),
  body: (
    [Metrics collection], [Pull (scrape) for services + push gateway for batch jobs], [Pure push: loses scrape-time up/down detection and centralized scheduling; pure pull: can't catch short-lived jobs],
    [Log write path], [Index at write time (inverted index)], [Schema-on-read / index-at-query (cheap writes, brutal query scans) — fine for archive-only data; our FR-2 demands interactive search],
    [Log retention], [Hot/warm/cold tiers with time-sharded indices], [Uniform hot storage: correct but ~10× the cost for data that is queried \<1% of the time],
    [Metric resolution], [Fixed 15 s + rollup tiers], [High-res forever: cardinality × retention makes storage explode; variable/adaptive resolution: complex, inconsistent dashboards],
    [Alert condition], [Threshold + `for` duration + clear hysteresis], [Fire on every breach: flapping burns trust; anomaly detection everywhere: powerful for *exploration*, too opaque as the paging contract],
    [Buffer], [Durable log (Kafka-class) between agents and processors], [Direct agent→indexer RPC: no spike absorption, no replay, couples every producer to every consumer's outages],
    [Degradation under overload], [Shed metrics first, sample logs, never silently], [Hard block (429 to agents): telemetry backs up into *application* hosts — the observer becomes the outage],
  ),
)

== SLOs & Meta-Observability

The platform that measures everyone else's SLOs needs its own — measured from
*outside*, by a small independent "meta-monitor" in a separate failure domain:

#tbl(
  (auto, 1fr, auto),
  header: (hcell[Indicator], hcell[Definition], hcell[Target]),
  body: (
    [Ingestion availability], [Share of batches accepted by the buffer], [≥ 99.9%],
    [Log searchability delay], [Event timestamp → present in index, p95], [≤ 60 s],
    [Metric freshness], [Scrape timestamp → queryable, p95], [≤ 30 s],
    [Query latency (hot)], [Log search / dashboard render, p95], [≤ 5 s / ≤ 3 s],
    [Alert latency], [Condition true → notification sent, p95], [≤ 1 min + `for`],
    [Data loss], [Acked bytes later found missing, per month], [≈ 0 (buffer replay)],
    [Pipeline health coverage], [Hosts whose agent heartbeat is watched], [100%],
  ),
)

#tip([State the SLO *of* the telemetry system in the interview])[
  Candidates design observability for everyone else and forget the platform
  itself. Naming meta-observability — "who watches the watcher, and from
  which failure domain" — is a senior-level signal: it shows you have been
  paged by the monitoring system being down, not just by the systems it
  monitors.
]

== Interview Wrap-Up

Likely follow-ups and the shape of strong answers:

+ *"Add distributed tracing — what changes?"* A third pillar with its own
  shape: traces are *trees* (spans with parent ids), stored per-trace-id with
  heavy head-based or tail-based sampling (1–5% head, or tail-sampling that
  keeps errors and slow outliers). Trace ids are *correlation keys*: log
  records carry `trace_id` so a log search pivots to the trace, and
  exemplars link metric spikes to example traces. The platform's buffer and
  tiering lessons transfer directly.
+ *"How do you cut the log bill in half?"* Rank tenants by bytes; enforce
  structured logging; sample repetitive INFO lines at the agent (log 1-in-N,
  keep all WARN+); shorten hot retention for the noisiest services; negotiate
  quotas. The answer is organizational as much as technical.
+ *"PII ends up in logs — now what?"* Scrubbing is cheapest at the agent
  (pattern rules before anything leaves the host), enforced again at the
  indexer; access to raw logs is itself logged; cold-tier encryption keys
  rotate. Treat telemetry as production data with a blast radius.
+ *"A team creates a label with user ids in it — what breaks?"* Cardinality
  explosion (Section 4.9): the TSDB's series index balloons, queries slow
  globally, and you are now storing identifiers you may not be allowed to
  store. Guardrails: reject writes whose label sets exceed per-metric
  cardinality budgets, and alert *the platform team* on the growth itself.
+ *"Why not just use a vendor solution?"* Buy-versus-build: the architecture above is
  exactly what the vendors run internally; the interview question is whether
  you can reason about their trade-offs. At 170 TB/day the build case is
  real; at 170 GB/day it usually is not.

== Summary & Further Reading

#notebox([Chapter summary])[
  A logging-and-metrics platform is *one firehose, two shapes of data*.
  Telemetry agents collect from every host (pull for services, push for batch
  jobs); a durable buffer absorbs the incident storm and decouples ingestion
  from processing; then the data forks: logs into a time-sharded *inverted
  index* (tokenization, posting lists, immutable segments, hot/warm/cold
  tiers that make retention a file deletion), metrics into a *time-series
  store* (delta-of-delta compression, label cardinality as the nemesis,
  mergeable rollups). Alerting is a per-rule state machine —
  OK → PENDING → FIRING — that pages on transitions, never on repetitions,
  and runs in its own failure domain. The platform watches itself from
  outside. The sizing insight: design for everyone else's worst day, because
  that is precisely when this system becomes the most important one in the
  building.
]

*Further reading.*

- The source video: _"14: Distributed Logging & Metrics Framework — Systems
  Design Interview Questions With Ex-Google SWE"_ (Jordan has no life):
  `https://www.youtube.com/watch?v=p_q-n09B8KA`
- Pelkonen, Franklin, Teller, Cavallaro, Huang, Meza, Veeraraghavan —
  _"Gorilla: A Fast, Scalable, In-Memory Time Series Database"_ (VLDB 2015) —
  the delta-of-delta / XOR compression scheme Section 4.9 distills.
- The Prometheus documentation — the pull model, the label model, and the
  `for` / alerting-rule semantics this chapter borrows.
- McCandless, Hatcher, Gospodnetić — _Lucene in Action_ — inverted indices,
  segments, and merges in production depth.
- _Google SRE Book_, chapters "Monitoring Distributed Systems" and "Alerting
  on SLOs" — symptoms vs. causes, and the philosophy behind Section 4.12.

== Chapter Glossary

#tbl(
  (auto, 1fr),
  header: (hcell[Term], hcell[Meaning]),
  body: (
    [Alert fatigue], [The learned ignoring of alerts caused by excessive false or repeated pages; a system failure mode, engineered against with `for` durations and hysteresis],
    [Backpressure], [Propagation of slowness upstream through a pipeline, absorbed by queues, throttling, or deliberate shedding],
    [Cardinality], [The number of distinct time series a metric's label combinations produce; the metric platform's primary scaling constraint],
    [Cold / warm / hot tier], [Storage classes of decreasing cost and speed holding progressively older telemetry; retention is implemented by migrating and deleting time-sharded indices],
    [Dead-letter queue (DLQ)], [A side channel where records that repeatedly fail processing are parked so the pipeline proceeds],
    [Delta-of-delta encoding], [Compressing a timestamp series by storing the difference of consecutive deltas — zero for a steady scrape, near-zero with jitter],
    [Downsampling / rollup], [Replacing old high-resolution samples with precomputed mergeable aggregates (sum/min/max/count) per bucket],
    [Failure domain], [The set of components that can fail together; the alerting engine and meta-monitor must live outside the domain they watch],
    [Flapping], [An alert oscillating between firing and clearing as a metric jitters around its threshold],
    [Hysteresis], [Using different thresholds to enter and leave a state, preventing oscillation at a single boundary],
    [Inverted index], [Map from token to the sorted list of records containing it; the data structure behind text search],
    [Label], [A key=value dimension on a metric series; dimensions, never identifiers],
    [Meta-observability], [Telemetry about the telemetry platform itself, emitted into an independent pipeline so the platform's death cannot erase its own certificate],
    [Observability / telemetry], [The practice (and data) of inferring a system's internal state from its outputs; pillars: logs, metrics, traces],
    [Posting list], [The sorted list of record ids attached to one token in an inverted index; queries intersect posting lists],
    [Pull (scrape) model], [Metrics collection where the collector periodically requests samples from each target's endpoint, gaining up/down detection for free],
    [Push model], [Metrics collection where sources send samples upstream; suits short-lived jobs and outbound trust boundaries],
    [Sample], [One (timestamp, value) pair of a time series],
    [Sampling (logs)], [Keeping a deterministic 1-in-N subset of a repetitive log class; degrades volume without creating silent gaps],
    [Schema-on-read], [Indexing little at write time and interpreting data at query time; cheap writes, expensive queries],
    [Segment (index)], [An immutable shard of an inverted index; small segments are merged in the background],
    [Structured logging], [Emitting logs as fielded records (JSON) rather than free text, enabling field queries and smart sampling],
    [Telemetry agent], [The per-host daemon that tails logs, collects metrics, batches, buffers, and ships telemetry upstream],
    [Time series], [A named, labeled sequence of timestamped values; the atom of the metrics pillar],
    [Tokenization], [Splitting text into searchable terms at index time],
    [Zigzag encoding], [A signed-to-unsigned integer mapping that makes small magnitudes of either sign varint-cheap],
  ),
)

#v(0.8em)
#align(center)[
  #text(size: 8.5pt, fill: slate)[
    — End of Chapter 4 · Next: Chapter 5—
  ]
]
