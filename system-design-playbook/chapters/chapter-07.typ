// ============================================================================
//  CHAPTER 7 — Designing a Recommendation Engine (YouTube / TikTok)
//  Source: "22: Recommendation Engine (YouTube, TikTok)" — Systems Design
//  Interview Questions With Ex-Google SWE (channel: Jordan has no life)
//  Link: https://www.youtube.com/watch?v=QrZTmiZSRcw
// ============================================================================

#import "../template.typ": *

= Designing a Recommendation Engine

#notebox([Problem source])[
  This chapter solves the problem posed in the talk _"22: Recommendation
  Engine (YouTube, TikTok)"_ from the series _Systems Design Interview
  Questions With Ex-Google SWE_ (channel: _Jordan has no life_). The task:
  design the personalized home feed of a video platform — hundreds of
  millions of users, a billion-item catalog, and ~300 milliseconds to decide
  which twenty items a given user sees next. It is the chapter where the
  book's infrastructure (event pipelines, ranking, caching) meets machine
  learning as a *systems* concern: feature stores, model freshness, and
  feedback loops. All terms are defined before use; all reference code is
  Rust with deterministic tests.
]

== The Problem Statement

The interviewer opens a video app's home screen — an endless, uncannily
well-chosen scroll — and says:

_"When a user opens the app, we show them a personalized feed of videos. We
know everything they've watched, liked, skipped, and how long they lingered.
A million new videos arrive every day. Design the system that decides what
goes on this screen."_

Every prior chapter had a crisp correct answer to compute; this one computes
a *guess*. That changes the engineering: the system's job is to take a
billion-item catalog and a user's entire history, and under a hard latency
budget produce an ordering that maximizes a business metric nobody can
measure directly. The design that emerged across the industry — a *funnel*
of candidate generation followed by ranking — is the spine of this chapter,
and understanding *why* it has that shape is most of the interview.

#defterm([Recommendation / the feed])[
  A _recommendation_ is a predicted-relevance ordering of catalog items for a
  specific user at a specific moment. The _feed_ is its product form: the
  ranked, paginated, infinite scroll. Unlike search (Chapter 4's inverted
  index answers "what matches this query"), the feed answers "what does this
  user want, having asked nothing" — the query is the user's history.
]

#defterm([Implicit vs. explicit feedback])[
  _Explicit_ feedback is deliberate: likes, ratings, follows, "not
  interested". _Implicit_ feedback is behavioral exhaust: impressions (the
  item was shown), plays, watch time, skips, rewatches. Implicit feedback is
  1000× more abundant and is what actually trains the system — watch time
  and skips are votes every user casts on every item, whether they mean to
  or not (Chapter 5's votes, but continuous and uninvited).
]

== Scope & Clarifying Questions

#tbl(
  (auto, 1fr),
  header: (hcell[Candidate asks], hcell[Interviewer answers]),
  body: (
    [What surfaces?], [Just the home feed. Search, subscriptions page, and ads are separate systems],
    [What do we optimize?], [Watch time / session satisfaction — assume a business metric exists; your job is the machinery],
    [Freshness requirements?], [A great new video should be discoverable within minutes; user actions should affect their feed within the session],
    [How personalized?], [Fully — no two users' feeds need overlap. But logged-out users get a fallback (trending)],
    [Model training?], [Not the focus — data scientists own model internals. You own data flow, features, serving, latency],
    [Content safety?], [A policy filter gate exists; respect it, don't design it],
    [Scale?], [500M daily users, ~1B public videos, ~2B feed loads/day],
    [Cold start?], [Must have an answer for new users and new videos],
  ),
)

#notebox([Agreed scope])[
  + *Feed generation*: personalized, ranked, paginated home feed per user.
  + *Feedback loop*: impressions/plays/watch-time/likes recorded and
    reflected — in-session effects within seconds, model retraining daily.
  + *Candidate diversity*: multiple retrieval channels (follows, similarity,
    embeddings, trending), blended.
  + *Freshness & cold start*: new items get an exploration quota; new users
    get trending + rapid personalization from first signals.
  + *Guardrails*: dedup, policy filter, diversity caps in the final mix.
  + Out: search, ads ranking, model architecture design, content moderation
    itself.
]

== Functional Requirements

#defterm([Candidate generation (retrieval) vs. ranking (scoring)])[
  The two mandatory stages of any industrial recommender. _Candidate
  generation_ cheaply selects ~10³–10⁴ plausibly-relevant items from the
  billion (per-channel: what your follows posted, items similar to what you
  loved, embedding neighbors, trending). _Ranking_ expensively scores those
  few thousand with the full feature set and orders them. Retrieval is
  recall-shaped ("don't miss anything they'd love"); ranking is
  precision-shaped ("order these twenty slots perfectly"). Neither can do
  the other's job at scale — Section 7.6 derives this.
]

+ *FR-1 — Feed.* `GET /feed` returns the next page of ranked items for the
  user, with an opaque cursor; the first page is the home screen.
+ *FR-2 — Event intake.* Impressions, plays, watch time, likes, skips,
  "not interested" recorded durably and at scale.
+ *FR-3 — Session adaptation.* Signals from *this* session (last N watches)
  influence the next page within seconds.
+ *FR-4 — Channel blend.* Every page mixes sources: followed creators,
  similar-to-history, embedding neighbors, trending, and an exploration
  quota for new items.
+ *FR-5 — Negative feedback.* "Not interested" removes the item and
  down-weights its ilk immediately.
+ *FR-6 — Cold start.* New users receive trending + category picks,
  personalizing from the very first events; new videos receive a small,
  guaranteed stream of test impressions.

== Non-Functional Requirements

#defterm([Latency budget])[
  The total time a request may consume, allocated across stages. Ours:
  300 ms p95 end-to-end for a feed page — ~50 ms retrieval fan-out, ~150 ms
  ranking ~5k candidates, ~50 ms re-rank + assemble, ~50 ms network and
  slack. The budget *dictates the architecture*: anything that cannot fit
  its allocation must be precomputed offline.
]

#tbl(
  (auto, 1fr),
  header: (hcell[Requirement], hcell[Target & reasoning]),
  body: (
    [Feed latency], [p95 ≤ 300 ms per page; it is the app's front door],
    [Event throughput], [~580k events/s avg, ~3M/s peak — Chapter 4's firehose, with a job to do],
    [Feed freshness], [A just-watched video influences the next page ≤ 10 s (session features); new *model* daily],
    [New-item discoverability], [Every eligible new video gets its exploration impressions ≤ 1 h from upload],
    [Availability], [Feed ≥ 99.95%; graceful degradation = trending + follows (never an empty screen)],
    [Diversity], [No category/creator may dominate a page beyond caps; the feed must not collapse to one topic],
    [Model staleness], [Serving model ≤ 36 h old; features ≤ 10 s (session) / ≤ 1 h (rest)],
  ),
)

#insight([Relevance is a budget problem])[
  Scoring one (user, item) pair well is a solved ML problem. The system's
  entire shape comes from arithmetic: 2B requests/day × a 1B-item catalog
  means you may score, at most, a few thousand items per request. Everything
  — retrieval channels, approximate nearest neighbors, precomputed
  similarities, the funnel itself — is a device for spending that tiny
  scoring allowance on the right few thousand items.
]

== Back-of-the-Envelope Estimation

*Assumptions*: 500M daily users, 4 feed sessions each, ~20 items viewed per
first page; ~100 events per user per day; catalog 1B videos, growing ~20M/day.

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Quantity], hcell[Estimate], hcell[Derivation]),
  body: (
    [Feed requests], [2B/day ≈ 23k/s avg, ~100k/s peak], [500M users × 4 sessions; peaks at regional evenings],
    [Feedback events], [50B/day ≈ 580k/s avg, ~3M/s peak], [100 events/user/day: impressions dominate],
    [Candidates per request], [~5k retrieved → ~20 shown], [Retrieval channels × quotas; ranking budget],
    [Scoring rate], [~115M inferences/s avg], [23k req/s × 5k candidates — why ranking runs on inference-optimized hardware],
    [User feature store], [~500 GB], [500M users × ~1 KB dense features],
    [Item feature/embedding store], [~1.25 TB], [1B items × (1 KB features + 128-dim fp16 embedding)],
    [Training data], [~10 TB/day], [50B events × ~200 B per featurized example],
    [Feed page size], [~50 KB JSON], [20 items × metadata + preview refs],
  ),
)

#insight([Three systems wearing one trench coat])[
  The estimation reveals the real architecture: a *telemetry firehose*
  (580k events/s — Chapter 4 verbatim), a *serving system* (23k requests/s
  with a 300 ms budget — Chapters 5 and 6 territory), and an *offline
  factory* (10 TB/day of training data in, one fresh model out daily). The
  recommendation interview is three familiar interviews stitched by two
  seams: the feature store and the model store.
]

The pipeline of the chapter: Section 7.6 derives the funnel; 7.7–7.9 walk
its stages (retrieve, rank, re-rank); 7.10–7.12 design APIs, architecture,
and the training/serving split; 7.13 implements the core pieces in Rust;
7.14–7.20 scale, harden, and review.

== The Core Challenge: The Funnel

Why must the system be two-staged? Cost arithmetic. A good ranking model
costs ~10⁶–10⁷ flops per (user, item) pair. Scoring the whole catalog per
request is 10¹⁵ flops per page view — a data center per user. But *not*
scoring is worse: a feed of random items is a dead product. The resolution
is to apply cheap relevance filters first and expensive ones last:

#v(0.3em)
#align(center)[
#canvas(h: 4.4cm)[
  // funnel as nested bars of decreasing width
  #node(0.4cm, 0.1cm, 16.2cm, 0.85cm, [Catalog — 10⁹ items · cost: $0$ scoring — filters only (policy-eligible, language, region)], fill: faint, edge: slate, size: 7.2pt)
  #node(1.6cm, 1.35cm, 13.8cm, 0.85cm, [Candidate generation — ~5×10³ items · cheap recall: follows, co-watch, embedding neighbors, trending], fill: white, edge: primary, size: 7.2pt)
  #node(2.8cm, 2.6cm, 11.4cm, 0.85cm, [Ranking — score 5×10³ pairs with the full model (~150 ms)], fill: faint-teal, edge: teal.darken(10%), size: 7.2pt)
  #node(4.0cm, 3.85cm, 9.0cm, 0.85cm, [Re-rank & blend — 20 slots: dedup, diversity caps, exploration], fill: faint-amber, edge: amber.darken(15%), size: 7.2pt)
  #arrow(8.5cm, 0.98cm, 8.5cm, 1.3cm, color: slate)
  #arrow(8.5cm, 2.23cm, 8.5cm, 2.55cm, color: slate)
  #arrow(8.5cm, 3.48cm, 8.5cm, 3.8cm, color: slate)
  #glabel(9.0cm, 1.12cm, [10⁹ → 10³·⁵], size: 6.8pt)
  #glabel(9.0cm, 2.37cm, [score everything], size: 6.8pt)
  #glabel(9.0cm, 3.62cm, [10³·⁵ → 20], size: 6.8pt)
]]
#v(0.2em)

#pitfall([Ranking the catalog])[
  The naive answer — "score every video for every user" — fails by six orders
  of magnitude of compute (Section 7.5: it would need ~10¹¹ inferences/s
  average). Equally wrong in the other direction: *only* candidate channels
  with no learned ranking, which can't order by the actual objective. The
  funnel is not an optimization; it is the only shape that satisfies both
  relevance and the latency budget. State this trade explicitly — it is the
  pivot of the whole interview.
]

== Deep Dive: Candidate Generation — Recall at 50 ms

Retrieval runs several *channels* in parallel, each a cheap, independent
source of a few hundred to few thousand candidates with a quota in the final
mix:

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Channel], hcell[What it retrieves], hcell[How it is served cheaply]),
  body: (
    [Follows], [Recent uploads from creators the user follows], [Reverse-chronological pull from the subscription index (Chapter 2's pull fanout — feeds are *pulled* here, not pushed)],
    [Co-watch similarity], [Items watched by people who watched what you watched], [Precomputed item→item similarity table (Section 7.13 computes it); lookup by recent history — no runtime model],
    [Embedding neighbors], [Items nearest the user's taste vector], [User embedding → approximate nearest-neighbor index; a ~10 ms query over 1B vectors],
    [Trending], [What's hot globally/regionally right now], [Chapter 6's leaderboard: time-decayed watch counts, top-K cached per region],
    [Exploration pool], [New/underexposed items earning their first data], [A reserved quota (Section 7.9); without it new items starve — the rich-get-richer loop],
  ),
)

#defterm([Collaborative filtering / co-watch similarity])[
  _Collaborative filtering_: recommending items via the behavior of *other
  users* ("users like you liked..."), needing no understanding of content.
  Its cheapest industrial form is _item-item co-watch similarity_: count how
  often pairs of items are watched by the same users, normalize into a
  cosine similarity, and precompute each item's most-similar list offline.
  Serving a user is then `union(similar-to(x) for x in recent_history)` —
  table lookups, no math at request time.
]

#defterm([Embedding / ANN index])[
  An _embedding_ is a learned dense vector (e.g. 128 floats) representing a
  user or item such that *distance encodes taste*: items near a user's vector
  are items they'd probably like (matrix factorization / two-tower models
  produce them). Retrieval asks for the nearest ~500 item vectors to the
  user vector — over 1B items, done with an _approximate nearest neighbor_
  (ANN) index (graph- or quantization-based), trading ~1% recall for
  ~10 ms latency. Exact search would eat the whole budget.
]

== Deep Dive: Ranking — Precision at 150 ms

The ranker scores each surviving candidate with the expensive model. As
systems engineers we care about *what the model needs at request time*:

- *Item features*: category, duration, language, age since upload,
  popularity counters, embedding.
- *User features*: historical category affinities, average watch time,
  creator affinities, embedding.
- *Cross features* (the gold): does this item's category match this user's
  affinity; similarity between the two embeddings.
- *Context/session features*: time of day, device, and the last N in-session
  watches — the reason the feed reacts "within the session" (FR-3): these
  features are updated by the event stream in seconds, *without retraining
  the model*.

#defterm([Feature store])[
  The serving-time database of precomputed ML inputs: user features, item
  features, and embeddings, keyed for point lookup at ~ms, refreshed by the
  event stream (fast path) and batch jobs (slow path). It is the seam
  between the offline factory and online serving — the ranker never computes
  features from raw events at request time; it *reads* them.
]

The model outputs a score per candidate — typically a blend like predicted
watch time, or `P(click) × E[watch | click]`. The training label comes from
yesterday's implicit feedback: an impression with 80% watch-through is a
strong positive; a 2-second skip is a strong negative. *The product's metric
choice is the model's soul* — optimize raw clicks and you get clickbait;
optimize watch time and you get binge; Section 7.17's guardrail metrics
exist because the objective is a policy decision with an engineering
delivery mechanism.

== Deep Dive: Re-Ranking — The Last 50 ms

Raw score order is not the feed. The final stage applies product rules to
the ranked ~few hundred:

+ *Dedup* — the same video arriving from three channels appears once.
+ *Diversity caps* — e.g., ≤2 per category/creator per page (Section 7.13
  implements this exactly). Uncapped, the ranker collapses the feed to
  whatever topic the user binged last night — the *filter bubble* failure
  mode.
+ *Freshness boost* — new uploads from followed creators get a bounded
  bonus; subscriptions must mean something.
+ *Exploration slot* — reserve ~1 of 20 slots for the exploration pool.

#defterm([Exploration vs. exploitation / multi-armed bandit])[
  _Exploitation_: show what the model already believes is best.
  _Exploration_: spend a small quota on items whose value is uncertain, to
  *learn* — new videos literally cannot be ranked honestly until someone
  watches them. The _multi-armed bandit_ framing formalizes the trade: an
  ε-greedy policy exploits with probability 1−ε and explores uniformly with
  probability ε. Without a guaranteed exploration quota, the feedback loop
  is a closed circle: only shown items get data, only items with data get
  shown — new creators starve and the catalog fossilizes. Exploration is not
  charity; it is the system's only source of new information.
]

#insight([The feed is controlled by whoever sets the caps])[
  Notice what happened across three sections: the *model* orders candidates,
  but the *product* owns the final screen — dedup rules, diversity caps,
  freshness boosts, exploration quota. This is deliberate and healthy: ML
  optimizes the measurable; humans govern the mixture. In the interview,
  calling out this separation (and where each lever lives) reads as having
  operated such a system, not just read about one.
]

== API Design

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Method], hcell[Path], hcell[Purpose]),
  body: (
    [`GET`], [`/v1/feed?cursor=&limit=`], [Next ranked page (FR-1); cursor encodes session + page state, opaque],
    [`POST`], [`/v1/events:batch`], [Impressions, plays, watch-time, likes, skips — compressed batches (FR-2)],
    [`POST`], [`/v1/feedback/not-interested`], [Negative feedback, effective immediately (FR-5)],
    [`GET`], [`/v1/trending?region=`], [Logged-out / cold-start fallback (FR-6); Chapter 6's board, cached],
    [`GET`], [`/v1/feed/explain/{item}`], ["Why am I seeing this?" — the channel that surfaced it (transparency, cheap to add)],
  ),
)

Feed responses carry `{items: [{id, rank, channel}], cursor}`. The `channel`
tag is returned on purpose: it powers explainability, per-channel metrics
(Section 7.17), and client-side diversity hints. Event ingestion is
fire-and-forget for the client (202 Accepted), exactly the Chapter 4
contract — the feed must never block on its own telemetry.

== High-Level Architecture

#v(0.3em)
#align(center)[
#canvas(h: 7.5cm)[
  // row A
  #node(0.2cm, 0.1cm, 3.0cm, 0.95cm, [Clients \ mobile · web · TV], fill: faint, edge: slate, size: 7.4pt)
  #node(0.2cm, 1.55cm, 3.0cm, 1.0cm, [Feed API \ sessions · cursors], fill: white, edge: primary, size: 7.4pt)
  // row B: channels
  #node(3.4cm, 1.55cm, 2.5cm, 0.95cm, [Follows index \ new uploads], fill: white, edge: slate, size: 6.9pt)
  #node(6.1cm, 1.55cm, 2.5cm, 0.95cm, [Co-watch table \ item→item], fill: white, edge: slate, size: 6.9pt)
  #node(8.8cm, 1.55cm, 2.5cm, 0.95cm, [ANN index \ embeddings], fill: white, edge: slate, size: 6.9pt)
  #node(11.5cm, 1.55cm, 2.5cm, 0.95cm, [Trending \ top-K per region], fill: white, edge: slate, size: 6.9pt)
  #node(14.2cm, 1.55cm, 2.5cm, 0.95cm, [Exploration pool \ new items], fill: white, edge: slate, size: 6.9pt)
  // row C
  #node(3.4cm, 3.05cm, 3.0cm, 0.95cm, [Blend \ per-channel quotas], fill: white, edge: primary, size: 7.2pt)
  #node(7.6cm, 3.05cm, 3.4cm, 0.95cm, [Ranker \ scores ~5k candidates], fill: white, edge: primary, size: 7.2pt)
  #node(12.0cm, 3.05cm, 3.4cm, 0.95cm, [Re-rank + policy gate \ dedup · diversity], fill: white, edge: crimson, size: 6.9pt)
  // row D
  #node(0.2cm, 4.65cm, 3.0cm, 0.95cm, [Event log \ 580k events/s], fill: white, edge: teal, size: 7.2pt)
  #node(4.2cm, 4.65cm, 2.8cm, 0.95cm, [Stream features \ session state], fill: white, edge: teal, size: 7.0pt)
  #node(7.8cm, 4.65cm, 3.2cm, 0.95cm, [Feature store \ user + item], fill: faint-blue, edge: primary, size: 7.2pt)
  // row E
  #node(4.2cm, 6.25cm, 3.2cm, 0.95cm, [Batch training \ daily], fill: faint-amber, edge: amber.darken(15%), size: 7.2pt)
  #node(8.6cm, 6.25cm, 3.0cm, 0.95cm, [Model store \ versioned], fill: faint-blue, edge: primary, size: 7.2pt)
  // arrows
  #arrow(1.7cm, 1.1cm, 1.7cm, 1.5cm)
  // feed api -> channels fan
  #arrow(3.25cm, 1.8cm, 4.6cm, 1.5cm, color: slate)
  #arrow(3.25cm, 2.0cm, 7.3cm, 1.5cm, color: slate)
  #arrow(3.25cm, 2.2cm, 10.0cm, 1.5cm, color: slate)
  #arrow(3.25cm, 2.35cm, 12.7cm, 1.5cm, color: slate)
  #arrow(3.25cm, 2.5cm, 15.4cm, 1.5cm, color: slate)
  // channels -> blend
  #arrow(4.65cm, 2.53cm, 4.9cm, 3.0cm, color: slate)
  #arrow(7.35cm, 2.53cm, 5.3cm, 3.0cm, color: slate)
  #arrow(10.05cm, 2.53cm, 5.6cm, 3.0cm, color: slate)
  #arrow(12.75cm, 2.53cm, 5.9cm, 3.0cm, color: slate)
  #arrow(15.45cm, 2.53cm, 6.2cm, 3.0cm, color: slate)
  // blend -> ranker -> rerank
  #arrow(6.45cm, 3.5cm, 7.55cm, 3.5cm)
  #glabel(6.35cm, 3.75cm, [~5k], size: 6.6pt)
  #arrow(11.05cm, 3.5cm, 11.95cm, 3.5cm)
  // response elbow back to feed api
  #arrow(13.7cm, 4.03cm, 13.7cm, 4.3cm, color: primary)
  #arrow(13.65cm, 4.3cm, 0.95cm, 4.3cm, color: primary)
  #arrow(0.9cm, 4.25cm, 0.9cm, 2.6cm, color: primary)
  #glabel(6.3cm, 4.48cm, [ranked page], size: 6.6pt)
  // events flow
  #arrow(1.9cm, 2.58cm, 1.9cm, 4.6cm, color: teal)
  #glabel(2.05cm, 3.5cm, [events], fg: teal.darken(12%), size: 6.6pt)
  #arrow(3.25cm, 5.1cm, 4.15cm, 5.1cm, color: teal)
  #arrow(7.05cm, 5.1cm, 7.75cm, 5.1cm, color: teal)
  // feature store -> ranker
  #arrow(9.4cm, 4.6cm, 9.4cm, 4.05cm)
  // batch training
  #arrow(1.7cm, 5.63cm, 1.7cm, 6.7cm, color: amber.darken(15%), dashed: true)
  #arrow(1.75cm, 6.7cm, 4.15cm, 6.7cm, color: amber.darken(15%), dashed: true)
  #glabel(0.5cm, 6.9cm, [labels], fg: amber.darken(25%), size: 6.6pt)
  #arrow(7.45cm, 6.7cm, 8.55cm, 6.7cm, color: amber.darken(15%))
  // model store -> ranker
  #arrow(10.1cm, 6.2cm, 9.6cm, 4.05cm, color: primary, dashed: true)
  #glabel(10.35cm, 5.15cm, [deploy ≤36h], size: 6.6pt)
]]
#v(0.2em)

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Component], hcell[Responsibility], hcell[Why it is shaped this way]),
  body: (
    [Feed API], [Session context, cursor state, final assembly], [Stateless; the only client-facing door],
    [Candidate channels], [Each retrieves ~10²–10³ plausible items its own way], [Independent, parallel, replaceable; quotas blend them (Section 7.7)],
    [Ranker], [Scores all candidates with the serving model], [The expensive stage: reads the feature store, never computes from raw events],
    [Re-rank + policy], [Dedup, diversity caps, freshness boost, exploration slot, safety filter], [Product rules the model cannot be trusted with (Section 7.9)],
    [Event log], [Durable buffer for all feedback], [Chapter 4's shock absorber, third time in this book],
    [Stream features], [Session state and counters updated in seconds], [In-session adaptation (FR-3) without model retraining],
    [Feature store], [Point-lookup user/item features + embeddings at ms], [The seam between offline factory and online serving],
    [Batch training], [Daily: labels → features → model → evaluation], [Section 7.12; model *internals* are out of scope, its *supply chain* is not],
    [Model store], [Versioned models, canary deploys, rollback], [A bad model is a deploy incident, treated exactly like bad code],
  ),
)

== Training vs. Serving: The Two-Factory Split

The *offline factory* runs daily: join yesterday's 50B events into labeled
examples (impression ↔ watch outcome within an attribution window), compute
features, train, evaluate against holdout, and publish a versioned model.
The *online factory* serves 23k requests/s with that frozen model plus
fresh features. Between them sits the discipline this split exists to
protect:

#pitfall([Training/serving skew])[
  The subtlest recommender bug: the model trains on features computed one
  way (batch SQL over the warehouse) and serves on features computed another
  (stream jobs with different semantics) — e.g., "watches in last 7 days"
  counted by calendar week offline and rolling 168 h online. The model
  silently degrades and no dashboard alarms, because *both* computations are
  internally correct. Defense: one feature *definition* compiled to both
  paths (a feature store with shared definitions), plus canary evaluation of
  every new model on live traffic before promotion. If you name one ML
  systems pitfall in the interview, name this one.
]

Freshness policy: the model is ≤36 h old (daily train + evaluation +
canary); user/item features ≤1 h; session features ≤10 s. Each layer of
staleness is a deliberate price paid for stability, and each is an SLO in
Section 7.17.

== Rust Reference Implementations

Four pieces with deterministic tests: item-item collaborative filtering, the
diversity re-ranker, ε-greedy exploration, and embedding similarity.

=== Item-Item Collaborative Filtering

```rust
use std::collections::{HashMap, HashSet};

/// The co-watch relation: user -> items watched, item -> watchers.
/// Implicit positives only — a watch is a vote (Chapter 7.1).
#[derive(Default)]
pub struct WatchMatrix {
    pub by_user: HashMap<u64, HashSet<u64>>,
    pub watchers: HashMap<u64, HashSet<u64>>,
}

impl WatchMatrix {
    pub fn from_pairs(pairs: &[(u64, u64)]) -> Self {
        let mut m = WatchMatrix::default();
        for &(u, item) in pairs {
            m.by_user.entry(u).or_default().insert(item);
            m.watchers.entry(item).or_default().insert(u);
        }
        m
    }

    /// Cosine similarity over the co-watch relation:
    /// |watchers(a) ∩ watchers(b)| / sqrt(|watchers(a)| * |watchers(b)|).
    /// Precomputed offline per item in production; computed inline here.
    pub fn similarity(&self, a: u64, b: u64) -> f64 {
        let (wa, wb) = match (self.watchers.get(&a), self.watchers.get(&b)) {
            (Some(x), Some(y)) => (x, y),
            _ => return 0.0,
        };
        let (small, big) = if wa.len() <= wb.len() { (wa, wb) } else { (wb, wa) };
        let co = small.iter().filter(|u| big.contains(u)).count() as f64;
        if co == 0.0 { return 0.0; }
        co / (wa.len() as f64 * wb.len() as f64).sqrt()
    }

    /// Recommend unseen items, scored by summed similarity to the user's
    /// whole watch history — the recall channel of Section 7.7.
    pub fn recommend(&self, user: u64, n: usize) -> Vec<(u64, f64)> {
        let seen = self.by_user.get(&user).cloned().unwrap_or_default();
        let mut score: HashMap<u64, f64> = HashMap::new();
        for &item in &seen {
            for &other in self.watchers.keys() {
                if seen.contains(&other) { continue; }
                let s = self.similarity(item, other);
                if s > 0.0 { *score.entry(other).or_default() += s; }
            }
        }
        let mut v: Vec<(u64, f64)> = score.into_iter().collect();
        v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap().then(a.0.cmp(&b.0)));
        v.truncate(n);
        v
    }
}

#[cfg(test)]
mod cf_tests {
    use super::*;

    fn matrix() -> WatchMatrix {
        // users 1,2,3 ; items 10,20,30,40
        WatchMatrix::from_pairs(&[
            (1, 10), (1, 20),
            (2, 10), (2, 20), (2, 30),
            (3, 30), (3, 40),
        ])
    }

    #[test]
    fn similarity_counts_co_watchers() {
        let m = matrix();
        assert_eq!(m.similarity(10, 20), 1.0);       // identical audiences
        assert_eq!(m.similarity(10, 30), 0.5);       // 1 shared of 2 & 2
        assert!((m.similarity(30, 40) - 0.7071).abs() < 1e-3); // 1/sqrt(2)
        assert_eq!(m.similarity(10, 40), 0.0);       // no shared watchers
    }

    #[test]
    fn recommendations_exclude_seen_and_rank_by_evidence() {
        let m = matrix();
        let recs = m.recommend(1, 5);
        // user 1 watched {10, 20}; item 30 scores sim(10,30)+sim(20,30) = 1.0,
        // item 40 scores 0 and is not surfaced
        assert_eq!(recs, vec![(30, 1.0)]);
        assert!(!recs.iter().any(|&(id, _)| id == 10 || id == 20));
    }
}
```

=== The Re-Ranker: Dedup + Diversity Quotas

```rust
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct Candidate {
    pub id: u64,
    pub category: &'static str,
    pub score: f64,
}

/// Same item arriving from several channels: keep its best score, once.
pub fn dedup(ranked: Vec<Candidate>) -> Vec<Candidate> {
    let mut seen = HashSet::new();
    ranked.into_iter().filter(|c| seen.insert(c.id)).collect()
}

/// Take a page of n from score order, allowing at most `per_category`
/// items per category — pass 1 respects the cap, pass 2 fills any
/// remaining slots in score order so the page is never short.
pub fn rerank_with_quota(
    mut ranked: Vec<Candidate>,
    n: usize,
    per_category: usize,
) -> Vec<u64> {
    ranked.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap().then(a.id.cmp(&b.id)));
    let mut out = Vec::with_capacity(n);
    let mut counts: HashMap<&str, usize> = HashMap::new();
    let mut leftover = Vec::new();
    for c in ranked {
        let cnt = counts.entry(c.category).or_insert(0);
        if *cnt < per_category && out.len() < n {
            out.push(c.id);
            *cnt += 1;
        } else {
            leftover.push(c.id);
        }
    }
    for id in leftover {
        if out.len() < n { out.push(id); }
    }
    out
}

#[cfg(test)]
mod rerank_tests {
    use super::*;

    fn c(id: u64, cat: &'static str, score: f64) -> Candidate {
        Candidate { id, category: cat, score }
    }

    #[test]
    fn quota_caps_a_dominant_category_but_fills_the_page() {
        let ranked = vec![
            c(1, "sport", 9.0), c(2, "sport", 8.5), c(3, "sport", 8.0),
            c(4, "music", 7.5), c(5, "news", 7.0),
        ];
        // cap 2 per category, page of 5
        assert_eq!(rerank_with_quota(ranked, 5, 2), vec![1, 2, 4, 5, 3]);
    }

    #[test]
    fn dedup_keeps_first_best_occurrence() {
        let dup = vec![c(1, "sport", 9.0), c(1, "sport", 7.0), c(2, "news", 8.0)];
        let unique = dedup(dup);
        assert_eq!(unique.len(), 2);
        assert_eq!(unique[0].score, 9.0); // first occurrence wins
    }
}
```

=== ε-Greedy Exploration (Multi-Armed Bandit)

```rust
/// Tiny deterministic RNG (xorshift64) so tests are reproducible.
pub struct XorShift(pub u64);
impl XorShift {
    pub fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        self.0 = x;
        x
    }
    pub fn f64(&mut self) -> f64 { (self.next() >> 11) as f64 / (1u64 << 53) as f64 }
    pub fn below(&mut self, n: u64) -> u64 { self.next() % n }
}

/// ε-greedy: exploit the best-estimate arm, explore uniformly with
/// probability ε. Arms = channels or new-item pools earning data.
pub struct EpsilonGreedy {
    pub means: Vec<f64>,
    pub counts: Vec<u64>,
    pub epsilon: f64,
    rng: XorShift,
}

impl EpsilonGreedy {
    pub fn new(arms: usize, epsilon: f64, seed: u64) -> Self {
        EpsilonGreedy {
            means: vec![0.0; arms],
            counts: vec![0; arms],
            epsilon,
            rng: XorShift(seed.max(1)),
        }
    }

    pub fn pull(&mut self) -> usize {
        // initialize: every arm once, in order
        if let Some(i) = self.counts.iter().position(|&c| c == 0) { return i; }
        if self.rng.f64() < self.epsilon {
            self.rng.below(self.means.len() as u64) as usize
        } else {
            self.means
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
                .map(|(i, _)| i)
                .unwrap()
        }
    }

    /// Incremental mean update — the bandit learns from implicit feedback.
    pub fn record(&mut self, arm: usize, reward: f64) {
        self.counts[arm] += 1;
        let n = self.counts[arm] as f64;
        self.means[arm] += (reward - self.means[arm]) / n;
    }
}

#[cfg(test)]
mod bandit_tests {
    use super::*;

    #[test]
    fn zero_epsilon_exploits_after_initialization() {
        let true_means = [0.1, 0.5, 0.9];
        let mut b = EpsilonGreedy::new(3, 0.0, 42);
        let mut counts = [0u64; 3];
        for _ in 0..103 {
            let a = b.pull();
            counts[a] += 1;
            b.record(a, true_means[a]);
        }
        assert_eq!(counts, [1, 1, 101]); // 3 init pulls, then all arm 2
    }

    #[test]
    fn pure_exploration_spreads_uniformly() {
        let true_means = [0.1, 0.5, 0.9];
        let mut b = EpsilonGreedy::new(3, 1.0, 88_172_645_463_325_252);
        let mut counts = [0u64; 3];
        for _ in 0..303 {
            let a = b.pull();
            counts[a] += 1;
            b.record(a, true_means[a]);
        }
        assert_eq!(counts.iter().sum::<u64>(), 303);
        for &c in &counts {
            assert!((60..=140).contains(&c), "counts = {counts:?}");
        }
    }

    #[test]
    fn running_mean_converges() {
        let mut b = EpsilonGreedy::new(1, 0.0, 1);
        b.record(0, 1.0);
        b.record(0, 0.0);
        assert_eq!(b.means[0], 0.5);
    }
}
```

=== Embedding Similarity: Cosine Top-K

```rust
/// Cosine similarity between taste vectors; distance encodes preference.
pub fn cosine(a: &[f64], b: &[f64]) -> f64 {
    let dot: f64 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let na = a.iter().map(|x| x * x).sum::<f64>().sqrt();
    let nb = b.iter().map(|x| x * x).sum::<f64>().sqrt();
    if na == 0.0 || nb == 0.0 { 0.0 } else { dot / (na * nb) }
}

/// Exact nearest neighbors for a user vector. Honest scope note: this is
/// O(n·d) — the teaching core. Production swaps in an ANN index
/// (Section 7.7) with identical interface and ~99% of the recall.
pub fn top_k_similar(
    query: &[f64],
    items: &[(u64, Vec<f64>)],
    k: usize,
) -> Vec<(u64, f64)> {
    let mut scored: Vec<(u64, f64)> =
        items.iter().map(|(id, v)| (*id, cosine(query, v))).collect();
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap().then(a.0.cmp(&b.0)));
    scored.truncate(k);
    scored
}

#[cfg(test)]
mod ann_tests {
    use super::*;

    #[test]
    fn nearest_neighbors_by_direction_not_magnitude() {
        let q = vec![1.0, 0.0, 0.0];
        let items = vec![
            (1, vec![0.9, 0.1, 0.0]),  // nearly aligned
            (2, vec![0.0, 1.0, 0.0]),  // orthogonal
            (3, vec![5.0, 0.0, 0.0]),  // identical direction, 5x magnitude
        ];
        let top2 = top_k_similar(&q, &items, 2);
        let ids: Vec<u64> = top2.iter().map(|e| e.0).collect();
        assert_eq!(ids, vec![3, 1]);          // direction beats magnitude
        assert_eq!(top2[0].1, 1.0);           // perfectly aligned
        assert!((top2[1].1 - 0.9939).abs() < 1e-3);
        assert_eq!(cosine(&q, &items[1].1), 0.0);
    }
}
```

== Scaling the Platform

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Layer], hcell[Scale axis], hcell[Mechanism]),
  body: (
    [Feed API / ranker], [23k req/s avg], [Stateless services, horizontal; ranking replicas scale with scoring rate (~115M inferences/s avg) on inference-optimized hardware],
    [Candidate channels], [Catalog size], [Each channel scales independently: follows index (Chapter 2 pull), precomputed co-watch table (offline), ANN shards (embedding space partitioned), trending cache (Chapter 6)],
    [Event pipeline], [580k events/s avg, 3M/s peak], [Chapter 4 verbatim: partitioned durable log, stream processors for session features, batch for training],
    [Feature store], [500 GB user + 1.25 TB item], [Sharded key-value with point lookups; read-heavy, so replicas carry the load],
    [Training], [10 TB/day examples], [Data-parallel GPU/TPU fleet; the daily cadence bounds both cost and staleness],
    [Feed cache], [Logged-out / cold-start], [Trending pages are shared and cached hard; personalized pages are never shared — cache the *candidates*, not the feed],
  ),
)

#insight([Personalization is cache-hostile by definition])[
  Chapter 5 cached windows shared by millions; here *every response is
  unique*. The caching strategy inverts: cache the shared ingredients
  (trending boards, co-watch lists, item features, embeddings) and assemble
  the personalized result fresh. A recommender that caches feeds has
  accidentally built trending-with-extra-latency.
]

== Failure Modes & Degradation

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Failure], hcell[Symptom], hcell[Response]),
  body: (
    [Event pipeline lag], [Session features stale; feed feels unreactive], [Degrade gracefully to non-session features; lag alerts (Chapter 4); catch-up replay],
    [One candidate channel down], [Feed still full, less varied], [Quotas redistribute to surviving channels; the blend is designed for exactly this — no single point of taste],
    [Ranker overload], [Latency budget breached], [Score fewer candidates (5k → 1k): relevance drops imperceptibly before latency does; then trending fallback],
    [Bad model deploy], [Feed quality craters at scale], [Canary + business-metric guardrails on the deploy pipeline; one-click rollback to previous model version — model incidents are deploy incidents],
    [Feature store stale], [Model serves on old affinities], [Staleness SLO with alerts; beyond threshold, ranker down-weights stale features],
    [Training pipeline fails], [Model ages past 36 h], [Yesterday's model keeps serving; freshness alert pages; investigate like any failed batch job],
    [Feedback loop spiral], [One topic floods a user's feed], [Diversity caps bound the damage structurally; guardrail metrics (Section 7.17) detect drift],
    [Trending fallback poisoned], [Manipulated trending board], [Chapter 6's integrity tools apply: velocity anomalies, quarantine feed],
  ),
)

== Trade-offs & Alternatives

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Decision], hcell[Chosen], hcell[Alternative & why not (here)]),
  body: (
    [Architecture], [Funnel: retrieve → rank → re-rank], [Single-stage scoring of the catalog: 6 orders of magnitude over compute budget (Section 7.6); retrieval-only: no objective-driven order],
    [Retrieval], [Multi-channel blend with quotas], [One giant embedding index alone: best average relevance, worst failure modes — no guarantee follows or fresh uploads ever surface],
    [Model freshness], [Daily retrain + real-time session features], [Online learning (update weights per event): fresher, but a feedback-loop amplifier and an operational nightmare to roll back],
    [Objective], [Watch time with guardrail metrics], [Pure CTR: optimizes clickbait; pure satisfaction surveys: too sparse to train on],
    [Exploration], [Guaranteed quota (ε-greedy slot)], [Pure exploitation: the rich-get-richer loop fossilizes the catalog; Thompson sampling: better theory, same quota slot in practice],
    [Feed consistency], [Cursor paginates over a snapshot], [Re-rank every page live: infinite scroll jumps and repeats; the session cursor pins the candidate set],
    [Cold start], [Trending + category picks, then rapid session adaptation], [Signup interest quizzes: fine complement, cannot be the only path (friction, stale answers)],
  ),
)

== Observability & SLOs

Two metric families — system health (Chapter 4's bread and butter) and
*quality* health, which only this kind of system has:

#tbl(
  (auto, 1fr, auto),
  header: (hcell[Indicator], hcell[Definition], hcell[Target]),
  body: (
    [Feed latency], [Page generation p95], [≤ 300 ms],
    [Event lag], [Event → session feature visible], [≤ 10 s],
    [Model freshness], [Age of serving model], [≤ 36 h, alert past],
    [Candidate coverage], [Pages served with all channels contributing], [≥ 99%],
    [CTR / watch time], [Clicks and minutes per impression, per model version], [Guardrail: never ship a regression],
    [Diversity index], [Distinct categories/creators per page], [≥ policy floor],
    [Exploration health], [Share of new items reaching N impressions in 1 h], [≥ 95%],
    [Negative-feedback rate], ["Not interested" per impression], [Watch trend, alert on spikes],
  ),
)

#insight([Guardrail metrics are the product's conscience])[
  Every optimization target can be gamed by the optimizer itself: CTR invites
  clickbait, watch time invites doomscrolling. Production recommenders
  therefore ship *pairs* of metrics — the objective and the guardrails
  (diversity, negative feedback, long-term retention) — and a model that
  improves the objective while moving a guardrail does not ship. Encoding
  this in the deploy pipeline is systems work, and it is the difference
  between a recommender and a slot machine.
]

== Interview Wrap-Up

Likely follow-ups and the shape of strong answers:

+ *"Make it real-time: the feed reacts to every watch instantly."* Already
  half-built: session features update in seconds. The next step — updating
  the *user embedding* mid-session — is streaming inference, not training:
  recompute the user vector from the new history with the frozen item tower.
  True online weight updates trade the rollback story for freshness; say
  what you'd be giving up.
+ *"A new creator with zero viewers — how do they ever surface?"* The
  exploration quota (Section 7.9) plus *content-based* features: with no
  watch history, the video's own metadata (category, title embeddings,
  thumbnail features) place it near known items. First impressions go to
  users whose taste vector is near the *content* vector — cold start is why
  content features exist at all.
+ *"TikTok vs. YouTube — what differs in the system?"* The graph: YouTube
  leans on subscriptions (the follows channel is strong); TikTok is
  graph-free — nearly pure engagement ranking, which makes its exploration
  quota and per-session adaptation much larger shares of the mix. Same
  funnel, different quotas. Architecture is the constants.
+ *"Where do ads fit?"* A second ranking system with its own objective
  (expected revenue × relevance), blended into slots by an auction —
  and the reason feed slots are strictly partitioned between organic and
  sponsored before re-ranking.
+ *"How would you detect the model amplifying harmful content?"* Guardrail
  metrics per content class, policy-gate recalls, and audit sampling of what
  the exploration pool promotes — plus the honest answer: ranking amplifies
  whatever the objective correlates with, so this is fought at the
  objective-and-guardrail layer, not with filters alone.

== Summary & Further Reading

#notebox([Chapter summary])[
  A recommender is three systems in a trench coat: a telemetry firehose
  (Chapter 4), a latency-bound serving funnel, and a daily model factory.
  The funnel exists because of arithmetic: you may score ~5k of 10⁹ items
  per request, so cheap recall channels (follows, co-watch, embedding ANN,
  trending, exploration) feed one expensive ranker, and a re-ranker applies
  the product's conscience — dedup, diversity caps, freshness, policy.
  Implicit feedback is the fuel; the feature store is the seam that keeps
  training and serving honest (skew is the killer bug); exploration is the
  quota that keeps the feedback loop open; guardrail metrics decide what
  ships. The lesson that transfers: *in ML systems, the model is a
  component — the system around it is the design.*
]

*Further reading.*

- The source video: _"22: Recommendation Engine (YouTube, TikTok) —
  Systems Design Interview Questions With Ex-Google SWE"_ (Jordan has no
  life): `https://www.youtube.com/watch?v=QrZTmiZSRcw`
- Covington, Adams, Sargin — _"Deep Neural Networks for YouTube
  Recommendations"_ (2016) — the canonical two-stage funnel paper this
  chapter's architecture follows.
- Koren, Bell, Volinsky — _"Matrix Factorization Techniques for Recommender
  Systems"_ (2009) — embeddings before they were called embeddings.
- Sutton & Barto, _Reinforcement Learning_ — the multi-armed bandit chapters
  behind Section 7.9's exploration quota.
- Chapter 4's monitoring reading applies twice here — guardrail metrics are
  SLOs with a conscience.

== Chapter Glossary

#tbl(
  (auto, 1fr),
  header: (hcell[Term], hcell[Meaning]),
  body: (
    [A/B test], [Controlled experiment over model/parameter versions; how guardrail and objective metrics earn their keep],
    [ANN index], [Approximate nearest-neighbor structure over embeddings; ~1% recall traded for ~10 ms latency over 1B vectors],
    [Candidate generation], [The recall stage: cheap channels selecting ~10³ plausible items from the catalog],
    [Clickbait / CTR trap], [The failure of optimizing clicks alone: the model learns to promise, not to satisfy],
    [Cold start], [Serving users or items with no history: trending/category fallbacks for users, content features + exploration for items],
    [Collaborative filtering], [Recommendation from other users' behavior, no content understanding required],
    [Co-watch similarity], [Item-item cosine over shared watchers; precomputed offline, looked up at serve time],
    [Cross feature], [A feature combining user and item (e.g., category × affinity); where ranking accuracy concentrates],
    [Diversity cap], [Re-rank rule bounding any category/creator per page; structural filter-bubble defense],
    [Embedding], [Learned dense vector for a user or item; distance encodes taste],
    [ε-greedy], [Bandit policy exploiting the best arm with probability 1−ε, exploring uniformly otherwise],
    [Exploration quota], [Reserved feed slots for uncertain items; the only source of new information in the loop],
    [Feature store], [Serving-time database of precomputed user/item features with shared offline/online definitions],
    [Feedback loop (rich-get-richer)], [Shown items get data, data earns impressions; without exploration the catalog fossilizes],
    [Filter bubble], [Feed collapse to one topic under pure score order; fought with diversity caps],
    [Funnel], [The retrieve → rank → re-rank shape; a compute-budget necessity, not an optimization],
    [Guardrail metric], [A metric that may not regress even when the objective improves; ships alongside the objective],
    [Implicit feedback], [Behavioral signals (watch time, skips, impressions) used as training labels],
    [Latency budget], [300 ms p95 allocated across retrieval, ranking, re-ranking; dictates what must be precomputed],
    [Matrix factorization / two-tower], [Model families producing user and item embeddings from interaction history],
    [Model store], [Versioned model registry with canary deploys and rollback; models are deploys],
    [Multi-armed bandit], [The exploration/exploitation formalism: arms are channels or items, rewards are engagement],
    [Ranking], [The precision stage: scoring retrieval's candidates with the full model under ~150 ms],
    [Re-ranking], [The product-rules stage: dedup, diversity, freshness, policy, exploration slot],
    [Session features], [In-session signals (last N watches) updated in seconds; feed reactivity without retraining],
    [Training/serving skew], [Feature definitions diverging between offline training and online serving; the silent killer of recommenders],
    [Trending], [Time-decayed popularity board per region — Chapter 6's leaderboard reused; the cold-start and outage fallback],
  ),
)

#v(0.8em)
#align(center)[
  #text(size: 8.5pt, fill: slate)[
    — End of Chapter 7 · Next: Chapter 8 —
  ]
]
