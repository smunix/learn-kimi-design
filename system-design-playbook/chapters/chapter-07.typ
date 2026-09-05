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

Notice how different this prompt feels from everything before it, and let
that difference guide your whole posture. Every prior chapter had a crisp
correct answer to compute: the rate limiter either allows or rejects, the
leaderboard has one true ranking, the comment count is a fact. This system
computes a *guess*. There is no test that tells you the feed was correct —
only a business metric, watched weeks later through aggregated behavior,
whispering that the guesses seem to be getting better or worse. You might
expect that to make the engineering softer. It does the opposite. Because
the output is a guess, the system must be built to *guess well under
constraints*: take a billion-item catalog and one user's entire history,
spend no more than 300 milliseconds, and produce an ordering that maximizes
a metric nobody can measure directly at request time. The design that
emerged across the industry — a *funnel* of candidate generation followed
by ranking — is the spine of this chapter, and understanding *why* the
funnel has that shape is most of the interview. The rest of the machinery
you have already built: the event pipeline is Chapter 4 again, the trending
board is Chapter 6 again, the caching debates are Chapter 5 again. What is
new is how machine learning enters the design — not as magic, but as a
component with a latency budget, a freshness SLO, and a supply chain.

#defterm([Recommendation / the feed])[
  A _recommendation_ is a predicted-relevance ordering of catalog items for
  a specific user at a specific moment. The _feed_ is its product form: the
  ranked, paginated, infinite scroll. Unlike search (Chapter 4's inverted
  index answers "what matches this query"), the feed answers "what does
  this user want, having asked nothing" — the query is the user's history.
]

#defterm([Implicit vs. explicit feedback])[
  _Explicit_ feedback is deliberate: likes, ratings, follows, "not
  interested". _Implicit_ feedback is behavioral exhaust: impressions (the
  item was shown), plays, watch time, skips, rewatches. Implicit feedback
  is 1000× more abundant and is what actually trains the system — watch
  time and skips are votes every user casts on every item, whether they
  mean to or not (Chapter 5's votes, but continuous and uninvited).
]

Hold the implicit-feedback idea still for a moment, because everything in
this chapter drinks from it. When the prompt says "we know everything
they've watched, liked, skipped, and how long they lingered," it is
describing a *data advantage* that only implicit feedback provides: every
user, on every visit, generates dozens of training labels for free. An
explicit-feedback-only system (star ratings, say) would see a few labels
per user per week and starve. The system's first job, before any model
exists, is therefore *capture* — recording that exhaust faithfully, at
scale, without making the product slower. Keep that ordering in mind:
telemetry first, model second. It will be reflected in the architecture
diagram, where the event log sits at the same rank as the ranker.

== Scope & Clarifying Questions

The prompt is one sentence long and hides a dozen systems. Before drawing
anything, find out which dozen. The dialogue below is the one you want to
have — each answer deletes an ambiguity that would otherwise surface at the
worst possible moment (usually while you are mid-whiteboard on something
else):

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

Read the answers as a map of where your effort goes. "What surfaces — just
the home feed" deletes search and ads and gives you a single, obsessable
latency target. "What do we optimize — assume a business metric exists" is
permission to stay an engineer: you will not design loss functions today,
but you *will* design the pipeline that delivers labels and features, and
you should say so explicitly — that boundary, named out loud, is itself a
senior signal. "Model training — not the focus" works the same way in
reverse: you own the model's *supply chain* (data in, features in,
versioned models out, rollback when bad) while its internals belong to
someone else. And the last two rows quietly hand you the two hardest
sub-problems: the scale row gives you numbers that will force the funnel
shape (Section 7.6 derives this), and the cold-start row promises the
interviewer will ask how a day-old video or a brand-new user ever gets a
fair chance — a question with a structural answer (Section 7.9), not a
shrug.

#notebox([Agreed scope])[
  + *Feed generation*: personalized, ranked, paginated home feed per user.
  + *Feedback loop*: impressions/plays/watch-time/likes recorded and
    reflected — in-session effects within seconds, model retraining daily.
  + *Candidate diversity*: multiple retrieval channels (follows,
    similarity, embeddings, trending), blended.
  + *Freshness & cold start*: new items get an exploration quota; new
    users get trending + rapid personalization from first signals.
  + *Guardrails*: dedup, policy filter, diversity caps in the final mix.
  + Out: search, ads ranking, model architecture design, content
    moderation itself.
]

== Functional Requirements

Six requirements, and the first thing to notice is that they come in two
voices: three describe what the *user* experiences, and three describe what
the *system* must do so those experiences are possible. The vocabulary
split that makes the whole chapter legible arrives first, so define it
before any requirement uses it:

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
+ *FR-3 — Session adaptation.* Signals from *this* session (last N
  watches) influence the next page within seconds.
+ *FR-4 — Channel blend.* Every page mixes sources: followed creators,
  similar-to-history, embedding neighbors, trending, and an exploration
  quota for new items.
+ *FR-5 — Negative feedback.* "Not interested" removes the item and
  down-weights its ilk immediately.
+ *FR-6 — Cold start.* New users receive trending + category picks,
  personalizing from the very first events; new videos receive a small,
  guaranteed stream of test impressions.

Walk them once in the order a user meets them. FR-1 is the front door —
one endpoint, twenty items, a cursor for the infinite scroll. FR-2 is the
bill that pays for everything: every pixel the feed shows generates events,
and those events are the only fuel the personalization engine will ever
have — lose them and the system goes blind while looking healthy. FR-3 is
the one users *feel*: watch two cooking videos and the third page leans
culinary. It is also an engineering provocation, because "within seconds"
is far faster than any model retrains — the resolution (update *features*
in seconds, keep the *model* fixed) is one of the chapter's core ideas, and
Section 7.8 makes it concrete. FR-4 protects the feed from monoculture;
FR-5 gives the user a steering wheel; FR-6 is the scope dialogue's cold-start
promise written as a requirement, and notice it has *two* halves — new
users and new videos are different problems with different mechanisms, and
conflating them is a common interview stumble.

== Non-Functional Requirements

#defterm([Latency budget])[
  The total time a request may consume, allocated across stages. Ours:
  300 ms p95 end-to-end for a feed page — ~50 ms retrieval fan-out,
  ~150 ms ranking ~5k candidates, ~50 ms re-rank + assemble, ~50 ms network
  and slack. The budget *dictates the architecture*: anything that cannot
  fit its allocation must be precomputed offline.
]

That last sentence is the one to internalize, because it inverts how you
design. In CRUD systems you start from the data model and let latency fall
where it lands. Here you start from the budget and let it decide what is
allowed to exist at request time at all. Anything too slow for its
allocation — similarity computations, model training, most of the catalog —
does not get optimized; it gets *moved*, into offline jobs whose results
are read as tables. You will see this move repeat three times in the next
five sections; when an interviewer watches you proactively say "this part
cannot run at request time, so it becomes a precomputed table," you have
demonstrated the core instinct of ML systems design.

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

Two rows deserve a second look. *Availability* defines graceful degradation
concretely — "trending + follows" is a feed you can assemble with no model
at all — which means the availability target survives even a total ML
outage; the screen is never empty, merely less clever. And *model
staleness* introduces a trio of clocks you will track for the rest of the
chapter: the model may be a day old, ordinary features an hour, session
features ten seconds. Three freshness tiers, each a deliberate price paid
for stability, each eventually becoming an SLO row in Section 7.17.

#insight([Relevance is a budget problem])[
  Scoring one (user, item) pair well is a solved ML problem. The system's
  entire shape comes from arithmetic: 2B requests/day × a 1B-item catalog
  means you may score, at most, a few thousand items per request.
  Everything — retrieval channels, approximate nearest neighbors,
  precomputed similarities, the funnel itself — is a device for spending
  that tiny scoring allowance on the right few thousand items.
]

== Back-of-the-Envelope Estimation

*Assumptions*: 500M daily users, 4 feed sessions each, ~20 items viewed
per first page; ~100 events per user per day; catalog 1B videos, growing
~20M/day. As always, the point of these numbers is not their precision —
it is discovering which constraints bite and which never will.

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

Read the table for its *ratios*, not its absolutes. Events outnumber feed
requests 25:1 — every page view generates a page of telemetry, which is why
the event pipeline is Chapter 4-sized while the feed API is Chapter
5-sized. The scoring rate is the number that shapes hardware: 115 million
inferences per second average is not a service you run on general-purpose
CPUs next to the web tier; it is why "the ranker" in the coming
architecture is a fleet of inference-optimized machines with the feature
store in front of it. And the two store sizes — 500 GB and 1.25 TB — are
the comfortable kind of big: shardable key-value territory, point lookups,
nothing exotic. The estimation's real deliverable is the realization below.

#insight([Three systems wearing one trench coat])[
  The estimation reveals the real architecture: a *telemetry firehose*
  (580k events/s — Chapter 4 verbatim), a *serving system* (23k requests/s
  with a 300 ms budget — Chapters 5 and 6 territory), and an *offline
  factory* (10 TB/day of training data in, one fresh model out daily). The
  recommendation interview is three familiar interviews stitched by two
  seams: the feature store and the model store.
]

Keep that decomposition in view all chapter. When a section feels
unfamiliar, ask which of the three systems you are inside — odds are you
have built that one before under another name, and the novelty is confined
to the seams. The pipeline of the chapter: Section 7.6 derives the funnel;
7.7–7.9 walk its stages (retrieve, rank, re-rank); 7.10–7.12 design APIs,
architecture, and the training/serving split; 7.13 implements the core
pieces in Rust; 7.14–7.20 scale, harden, and review.

== The Core Challenge: The Funnel

Why must the system be two-staged at all? Resist answering "because that's
how YouTube does it" — derive it from cost arithmetic, in the room, because
the derivation *is* the interview pivot. A good ranking model costs
~10⁶–10⁷ flops per (user, item) pair. Scoring the whole catalog per request
is 10¹⁵ flops per page view — a data center per user. But *not* scoring is
worse: a feed of random items is a dead product. Trapped between
"score everything" (impossible) and "score nothing" (worthless), you resolve
the dilemma the way systems always resolve impossible budgets: apply cheap
relevance filters first and expensive ones last, letting each stage buy the
next stage's right to be expensive:

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

Read the picture from top to bottom, the way one feed request experiences
it — the narrowing bars are the funnel, and each bar's width is literally
how much of the catalog survives that stage. The top bar is the whole
*catalog*: 10⁹ items, and the only thing that happens here is filtering,
not scoring — policy-eligibility, language, region — because filters cost
boolean checks while scoring costs model flops. The first arrow
(10⁹ → 10³·⁵) is the miracle hop: *candidate generation* shrinks a billion
to roughly five thousand using mechanisms so cheap they are barely
computation at all — index lookups, precomputed tables, a nearest-neighbor
query — and its job is *recall*: it may surface mediocre items, but it must
not miss anything this user would love. The middle bar is *ranking*, the
teal heart of the funnel: now and only now does the expensive model run,
scoring each of the ~5 000 survivors with the full feature set — the arrow
label "score everything" is suddenly affordable precisely because
"everything" was redefined by the stage above. The bottom bar is
*re-rank & blend*: twenty final slots, where score order is adjusted by
product rules — dedup, diversity caps, an exploration slot — before the
page ships. Two things to say while drawing this. First, each stage is
allowed to be expensive *per item* in proportion to how few items reach it:
filters at 10⁹, table lookups at 10³·⁵, full model at 5×10³, hand-rules at
20. Second, the funnel's stages fail differently: retrieval failures are
*silent* (a great video never considered looks identical to a great video
never existing), while ranking failures are *visible* (the right videos in
the wrong order) — which is why Section 7.17 measures candidate coverage as
a first-class SLO.

#pitfall([Ranking the catalog])[
  The naive answer — "score every video for every user" — fails by six
  orders of magnitude of compute (Section 7.5: it would need ~10¹¹
  inferences/s average). Equally wrong in the other direction: *only*
  candidate channels with no learned ranking, which can't order by the
  actual objective. The funnel is not an optimization; it is the only shape
  that satisfies both relevance and the latency budget. State this trade
  explicitly — it is the pivot of the whole interview.
]

== Deep Dive: Candidate Generation — Recall at 50 ms

Zoom into the second bar. Retrieval is not one clever index; it is several
*channels* running in parallel, each a cheap, independent source of a few
hundred to a few thousand candidates, each with a quota in the final mix.
The multiplicity is deliberate — no single channel is trusted with the
user's whole attention:

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

Read the "how it is served cheaply" column slowly, because it is the
section's thesis: *every channel is a lookup*. Not one of them runs a model
at request time. The follows channel is Chapter 2's pull fanout wearing a
new hat; the co-watch channel is a precomputed table where yesterday's
batch job did all the mathematics; the embedding channel queries an index
that was built offline; trending is literally Chapter 6's leaderboard; the
exploration pool is a queue with a quota. The entire recall stage of the
world's most sophisticated recommendation systems reduces, at request time,
to five reads fanned out in parallel and merged — the 50 ms budget is spent
on *network fan-out*, not arithmetic. Two definitions make the two learned
channels precise:

#defterm([Collaborative filtering / co-watch similarity])[
  _Collaborative filtering_: recommending items via the behavior of *other
  users* ("users like you liked..."), needing no understanding of content.
  Its cheapest industrial form is _item-item co-watch similarity_: count
  how often pairs of items are watched by the same users, normalize into a
  cosine similarity, and precompute each item's most-similar list offline.
  Serving a user is then `union(similar-to(x) for x in recent_history)` —
  table lookups, no math at request time.
]

#defterm([Embedding / ANN index])[
  An _embedding_ is a learned dense vector (e.g. 128 floats) representing
  a user or item such that *distance encodes taste*: items near a user's
  vector are items they'd probably like (matrix factorization / two-tower
  models produce them). Retrieval asks for the nearest ~500 item vectors
  to the user vector — over 1B items, done with an _approximate nearest
  neighbor_ (ANN) index (graph- or quantization-based), trading ~1% recall
  for ~10 ms latency. Exact search would eat the whole budget.
]

The two channels complement each other in a way worth articulating: co-watch
is *behavioral* (it knows what co-occurs but nothing about what anything
is), while embeddings are *semantic* (they place items in a space where
distance means something, even for items nobody has co-watched yet). And
the ANN trade-off is the first honest approximation of the chapter: you
deliberately sacrifice about 1% of recall — some true nearest neighbors are
missed — to buy two orders of magnitude of latency. At the retrieval stage
that trade is nearly free, because the ranker below will re-score whatever
arrives; a missed neighbor only matters if *all five* channels miss it,
which is the quiet statistical reason the multi-channel blend is robust:
channels fail independently, and relevance survives as long as any one of
them remembers.

== Deep Dive: Ranking — Precision at 150 ms

The ranker is the funnel's expensive stage, and your job as the systems
engineer in the room is not to design the model — the scope dialogue
assigned that to data scientists — but to be an expert in *what the model
needs at request time* and where those needs come from. Four feature
families feed every scoring call:

- *Item features*: category, duration, language, age since upload,
  popularity counters, embedding. All precomputed; all point-lookup reads.
- *User features*: historical category affinities, average watch time,
  creator affinities, embedding. Same story — computed offline or streamed,
  read at request time.
- *Cross features* (the gold): does this item's category match this user's
  affinity; similarity between the two embeddings. These are where ranking
  accuracy concentrates, and they are *computed at request time* from the
  two lookup results — cheap arithmetic over already-fetched vectors, the
  only math the ranker is allowed to do that is not the model itself.
- *Context/session features*: time of day, device, and the last N
  in-session watches — the reason the feed reacts "within the session"
  (FR-3): these features are updated by the event stream in seconds,
  *without retraining the model*.

Pause on the session-features row, because it resolves the FR-3 provocation
from earlier and the resolution generalizes. "The feed reacts within
seconds" sounds like "the model learns within seconds," and conflating the
two leads candidates into the online-learning tarpit (Section 7.16's table
buries that idea properly). The trick is that the model is a *function* —
`score = f(user, item, context)` — and functions need not be retrained to
react; they need fresh *inputs*. Session features are fresh inputs. The
model already learned, from yesterday's 50 billion examples, how "just
watched two cooking videos" tends to shift watch probabilities; today it
merely reads that fact from a fast store. Freshness without retraining —
the same separation Chapter 4 used between collection and storage, applied
to taste.

#defterm([Feature store])[
  The serving-time database of precomputed ML inputs: user features, item
  features, and embeddings, keyed for point lookup at ~ms, refreshed by the
  event stream (fast path) and batch jobs (slow path). It is the seam
  between the offline factory and online serving — the ranker never
  computes features from raw events at request time; it *reads* them.
]

The model outputs a score per candidate — typically a blend like predicted
watch time, or `P(click) × E[watch | click]`. The training label comes
from yesterday's implicit feedback: an impression with 80% watch-through
is a strong positive; a 2-second skip is a strong negative. *The product's
metric choice is the model's soul* — optimize raw clicks and you get
clickbait; optimize watch time and you get binge; Section 7.17's guardrail
metrics exist because the objective is a policy decision with an
engineering delivery mechanism. As the engineer you do not pick the
objective — but you are expected to *name its failure modes*, because the
pipeline you build will amplify whichever objective it is given, faithfully
and at planetary scale. A recommender never says "this objective was
unwise"; it just quietly optimizes it into a product problem.

== Deep Dive: Re-Ranking — The Last 50 ms

Raw score order is not the feed. If you shipped the ranker's ordering
directly, the feed would be a monoculture within days — one binged topic
flooding every slot, the same video arriving from three channels, fresh
uploads nowhere. The final stage applies product rules to the ranked few
hundred, and each rule exists because of a specific, observed failure:

+ *Dedup* — the same video arriving from three channels appears once.
  (Multi-channel recall guarantees duplicates; Section 7.13 shows the
  two-line fix and what "first occurrence wins" preserves.)
+ *Diversity caps* — e.g., ≤2 per category/creator per page (Section 7.13
  implements this exactly). Uncapped, the ranker collapses the feed to
  whatever topic the user binged last night — the *filter bubble* failure
  mode.
+ *Freshness boost* — new uploads from followed creators get a bounded
  bonus; subscriptions must mean something, or users learn that following
  is decorative.
+ *Exploration slot* — reserve ~1 of 20 slots for the exploration pool,
  the mechanism that keeps the whole learning loop honest:

#defterm([Exploration vs. exploitation / multi-armed bandit])[
  _Exploitation_: show what the model already believes is best.
  _Exploration_: spend a small quota on items whose value is uncertain, to
  *learn* — new videos literally cannot be ranked honestly until someone
  watches them. The _multi-armed bandit_ framing formalizes the trade: an
  ε-greedy policy exploits with probability 1−ε and explores uniformly
  with probability ε. Without a guaranteed exploration quota, the feedback
  loop is a closed circle: only shown items get data, only items with data
  get shown — new creators starve and the catalog fossilizes. Exploration
  is not charity; it is the system's only source of new information.
]

Trace the closed-circle sentence until it scares you a little, because it is
the single most important dynamics argument in the chapter. A
pure-exploitation feed shows items the model already scores highly; those
items gather more watches, which raises their scores further; items never
shown gather nothing and are never shown. Left alone, the feed converges to
yesterday's winners and the catalog's long tail freezes — a system that is
locally optimal (each page is "the best known guesses") and globally
suicidal (the supply of future winners dries up). The exploration quota is
the deliberate inefficiency that prevents this: one slot in twenty is spent
buying *information* rather than satisfaction. And note where the cost
lands: the user sees one uncertain item per page — a nearly invisible tax
that funds the entire future relevance of the product.

#insight([The feed is controlled by whoever sets the caps])[
  Notice what happened across three sections: the *model* orders
  candidates, but the *product* owns the final screen — dedup rules,
  diversity caps, freshness boosts, exploration quota. This is deliberate
  and healthy: ML optimizes the measurable; humans govern the mixture. In
  the interview, calling out this separation (and where each lever lives)
  reads as having operated such a system, not just read about one.
]

== API Design

The surface is deliberately small — five endpoints — because the
interesting decisions all live behind the feed call. A small API is a
feature here: personalization is hard to cache, hard to debug, and hard to
reason about, so the contract with the client should be boring.

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

Feed responses carry `{items: [{id, rank, channel}], cursor}`. The
`channel` tag is returned on purpose, and the reasons stack: it powers the
explainability endpoint, it enables per-channel metrics (Section 7.17's
coverage SLO reads these tags), and it gives clients diversity hints for
free. The cursor deserves its usual respect — it pins the session's
candidate set so page two does not reshuffle page one's rejects into view
(Section 7.16's "feed consistency" row carries the full argument). Event
ingestion is fire-and-forget for the client (202 Accepted), exactly the
Chapter 4 contract — the feed must never block on its own telemetry, and
the client must never learn whether the event pipeline is healthy; those
are the system's problems, not the user's.

== High-Level Architecture

Here is the whole chapter in one picture. Before the tour, orient yourself
to its three vertical bands: the *top rows* are the request path (serving,
300 ms budget), the *middle row* is the data path (telemetry and features),
and the *bottom row* is the factory (training and model supply). The
picture is worth drawing slowly in the interview, because nearly every
arrow is a section you have already reasoned through:

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

*Follow a feed request first* — the slate and blue arrows. The client
(top-left, gray) calls the *Feed API*, the only door and deliberately
stateless, so it scales horizontally and any instance can serve any page —
cursor contents carry the session state. From the Feed API, five slate
arrows fan out to the *candidate channels* drawn in a row — follows index,
co-watch table, ANN index, trending, exploration pool — and the fan-out
shape is the point: the channels are independent, so they are queried in
parallel, and the stage's latency is the *slowest* channel, not their sum
(another reason each channel is kept simple and table-shaped). Five arrows
then converge on the *Blend* box, which applies the per-channel quotas —
this is where "multi-channel" becomes a mixture rather than a pile — and
emits one merged candidate set, labeled "~5k", into the *Ranker*. The
ranker's downward arrow from the *feature store* (the blue box below it)
is its lifeline: every scoring call reads user features, item features, and
embeddings from there at millisecond latency, and the model artifact itself
arrives by the dashed blue "deploy ≤36h" arrow from the model store — the
ranker is stateless code plus two read-only dependencies, which is what
makes it horizontally scalable and rollback-able. From the ranker, scored
candidates flow right into the crimson-edged *Re-rank + policy gate* —
crimson on purpose, because this is the box where the product's conscience
overrides the model's math (dedup, diversity caps, freshness boost,
exploration slot, safety filter). Then the response takes the long blue
elbow home: down from re-rank, left along the "ranked page" arrow, and up
into the Feed API, which assembles the page, stamps the cursor, and
answers the client.

*Now follow the exhaust* — the teal arrows, the chapter's other half. Every
impression and watch the client renders also flows down the left edge
("events") into the *event log* — 580k events/s of durable buffer, Chapter
4's shock absorber for the third time in this book. Right of it, the
*stream features* job consumes the log continuously and maintains session
state — the "last N watches" that let the feed react within seconds —
writing into the *feature store* beside it. Notice the geometry: the
feature store sits on row D, *between* the event pipeline and the ranker,
touching both — it is drawn as the seam because that is exactly what it is.

*Finally, the factory* — the amber bottom row. The dashed amber arrows show
the slow loop: yesterday's events leave the event log as *labels*, reach
*batch training* (daily: join, featurize, train, evaluate), and the
graduating model lands in the *model store* — versioned, canaried,
rollback-able, because a bad model is a deploy incident treated exactly
like bad code. The dashed blue arrow from model store up to the ranker
closes the loop: the factory's output becomes serving's input on a ≤36 h
cadence. Step back and look at the whole: the online loop (slate/blue)
reacts in seconds through features; the offline loop (amber) reacts in a
day through weights. Two loops, two clocks, one feature store keeping them
honest — that is the architecture, and every box below exists to serve it.

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

The bottom two rows of the diagram run on different clocks and different
engineering cultures, and keeping them honest relative to each other is a
full-time discipline. The *offline factory* runs daily: join yesterday's
50B events into labeled examples (impression ↔ watch outcome within an
attribution window), compute features, train, evaluate against holdout, and
publish a versioned model. The *online factory* serves 23k requests/s with
that frozen model plus fresh features. The two factories touch only through
versioned artifacts — the feature definitions and the model file — and the
discipline that touchpoint must protect has a name:

#pitfall([Training/serving skew])[
  The subtlest recommender bug: the model trains on features computed one
  way (batch SQL over the warehouse) and serves on features computed
  another (stream jobs with different semantics) — e.g., "watches in last
  7 days" counted by calendar week offline and rolling 168 h online. The
  model silently degrades and no dashboard alarms, because *both*
  computations are internally correct. Defense: one feature *definition*
  compiled to both paths (a feature store with shared definitions), plus
  canary evaluation of every new model on live traffic before promotion.
  If you name one ML systems pitfall in the interview, name this one.
]

Understand why skew is *worse* than an ordinary bug. Ordinary bugs crash,
log, alert. Skew does none of these: training accuracy looks fine, serving
latency looks fine, every dashboard is green — while the model quietly
misbehaves because the number it reads as "watches in last 7 days" at
serving time means something slightly different from what it meant in its
training data. The degradation is real but *unattributable*: nothing is
broken, two things are merely inconsistent. This is why the defense is
structural rather than vigilance-based — you do not ask engineers to be
careful; you make one feature definition compile to both paths so the
inconsistency cannot be written down. When you hear a team say "the model
got worse and we don't know why," skew is the prime suspect, and the fix is
almost always organizational before it is technical.

Freshness policy: the model is ≤36 h old (daily train + evaluation +
canary); user/item features ≤1 h; session features ≤10 s. Each tier of
staleness is a deliberate price paid for stability — a daily model means a
bad Tuesday model hurts for hours, not seconds, and a canary catches most
of those before they hurt at all — and each tier becomes an SLO row in
Section 7.17, because a freshness promise nobody measures is a hope, not a
policy.

== Rust Reference Implementations

Four pieces with deterministic tests, one per funnel idea that had
real logic in it: item-item collaborative filtering (the co-watch channel
of Section 7.7), the diversity re-ranker (Section 7.9's caps), ε-greedy
exploration (the bandit that keeps the feedback loop open), and embedding
similarity (the ANN channel's exact-math teaching core). As always, the
tests are the argument — each one encodes a claim the prose made about how
the system behaves.

=== Item-Item Collaborative Filtering

The first listing is the co-watch channel reduced to its essence. Read the
`similarity` function alongside its doc comment: cosine similarity over the
*co-watch relation* — two items are similar in proportion to how many
watchers they share, normalized by audience size so that a popular item
does not look similar to everything merely by being watched by everyone.
The production system runs this offline per item and stores the top-similar
list; here it runs inline so you can see the math. And note what
`recommend` does *not* do: it never surfaces an item the user already saw
(`seen.contains` guard) — the recall channel's first duty is to not waste
the ranker's budget on reruns.

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

Walk the tiny fixture, because its six watches tell a complete
recommendation story. Users 1 and 2 both watched items 10 and 20 — so
those two items have *identical audiences* and similarity 1.0, the test's
first assertion. Item 30 shares exactly one watcher (user 2) with item 10
out of audiences of two and two, giving 1/√4 = 0.5; items 30 and 40 share
user 3 out of audiences of two and one, giving 1/√2 ≈ 0.7071. Now ask for
recommendations for user 1, who watched {10, 20}: item 30 is similar to
both of those (0.5 + 0.5 = 1.0 of summed evidence), item 40 is similar to
neither, and items 10 and 20 themselves are excluded as already-seen. The
test asserts the entire outcome in one line: `recs == vec![(30, 1.0)]`. Six
watches in, one principled recommendation out — you have just watched
collaborative filtering work with no model, no training, and no content
understanding, which is precisely why it is the industry's cheapest recall
channel.

=== The Re-Ranker: Dedup + Diversity Quotas

The second listing is Section 7.9's product rules as executable policy.
`dedup` is two lines and one decision — *first occurrence wins* — which,
applied to score-ordered input, means the same video arriving from three
channels keeps its best score and appears once. `rerank_with_quota` is the
diversity cap, and its *two-pass* structure is the detail to narrate: pass
one respects the cap strictly (at most `per_category` items per category),
but anything skipped goes to a `leftover` list, and pass two fills any
remaining page slots from it in score order — *so the page is never short*.
A cap that could starve the page would trade a filter bubble for an empty
screen; the two-pass design caps dominance without ever failing to serve.

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

The quota test encodes the filter-bubble scenario in miniature: the ranker,
left alone, would have served three sport videos at the top (scores 9.0,
8.5, 8.0 — it learned the user binged sport last night). The cap of two
admits items 1 and 2, skips item 3 into `leftover`, admits music (4) and
news (5) — and only then, with four slots filled and the page one short,
reaches back into the leftover pile for item 3. Final page: `[1, 2, 4, 5, 3]`.
Read that vector as the product compromise made literal: the model's
conviction is honored (the two best sports lead), the user's evening is
varied (music and news interrupt the binge), and the page is complete (the
third sport returns as filler rather than vanishing). Governance without
amnesia — the caps rule the top of the page, not the whole of it.

=== ε-Greedy Exploration (Multi-Armed Bandit)

The third listing is the exploration slot's brain. A *multi-armed bandit*
(Section 7.9's definition) is the formal version of a question the feed
asks twenty times per page: which uncertain option deserves a trial? The
`EpsilonGreedy` policy answers with the simplest possible honesty — with
probability 1−ε pull the arm with the best observed mean (exploit), with
probability ε pull a uniformly random arm (explore). Two implementation
details deserve your attention. The `pull` method begins with an
*initialization pass* — every arm is tried once before any policy applies,
because an arm with zero observations has no mean to exploit; this is the
code-level form of "new items get their guaranteed first impressions." And
`record` updates the mean *incrementally* — `mean += (reward − mean)/n` —
so the bandit's memory is O(1) per arm, no reward history retained; at
580k events/s, that is not a nicety but a necessity. The tiny `XorShift`
generator exists purely so the tests are reproducible — a deterministic
stream of "randomness" that lets assertions be exact.

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

The three tests bracket the policy's behavioral envelope, and each maps to
a feed regime. `zero_epsilon_exploits_after_initialization`: with ε = 0,
after the three mandatory initialization pulls the bandit locks onto arm 2
(true mean 0.9) forever — `[1, 1, 101]` — which is exactly the
rich-get-richer fossilization Section 7.9 warned about, here demonstrated
as a *correct* consequence of a pure-exploitation policy.
`pure_exploration_spreads_uniformly`: with ε = 1, 303 pulls spread across
the arms within a loose uniform band (60–140 each) — maximum learning,
zero exploitation, the catalog-surveying extreme. Production lives between
the two, at ε ≈ 0.05: mostly the best-known feed, a reserved trickle of
trials. And `running_mean_converge` pins the incremental update's
arithmetic so the O(1) memory claim is tested, not merely asserted.

=== Embedding Similarity: Cosine Top-K

The last listing is the semantic channel's kernel. *Cosine similarity*
measures the angle between two taste vectors, ignoring their lengths — and
the test shows why that choice matters: an item vector five times longer
than the query but pointing the same direction scores a perfect 1.0, while
a nearly-aligned one scores 0.9939 and an orthogonal one 0.0. *Direction
beats magnitude* is exactly right for taste: a video watched ten times more
often is not ten times more *relevant*; it is the same direction of appeal,
louder. The doc comment on `top_k_similar` carries the chapter's honesty
habit: this is O(n·d) — fine for a test, absurd over 10⁹ items — and
production swaps in the ANN index of Section 7.7 with an identical
interface and ~99% of the recall. The swap is the interview answer; the
exact version is the understanding that lets you defend the swap.

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

Each layer of the funnel scales on its own axis, and the table's right
column keeps naming earlier chapters — that repetition is the point. A
recommender is an *integration* of systems this book has already scaled;
the new work is confined to the seams.

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

The last row states a rule worth generalizing, and the insight below states
it sharply. Note the candidate-channels row too: *each channel scales
independently* is not a convenience but a consequence of the blend
architecture — because quotas, not internals, define each channel's
contribution, you can shard the ANN index this quarter and rebuild the
co-watch pipeline next quarter without the feed ever noticing. Independent
scaling is what the blend buys operationally, on top of what it buys in
relevance.

#insight([Personalization is cache-hostile by definition])[
  Chapter 5 cached windows shared by millions; here *every response is
  unique*. The caching strategy inverts: cache the shared ingredients
  (trending boards, co-watch lists, item features, embeddings) and assemble
  the personalized result fresh. A recommender that caches feeds has
  accidentally built trending-with-extra-latency.
]

== Failure Modes & Degradation

Walk the diagram and break things, as always — but notice this system's
failures come in two flavors with different shapes: *infrastructure*
failures (pipeline lag, channel outages, store staleness), which look like
every other chapter's, and *model* failures (bad deploys, feedback spirals),
which fail *in quality space* — nothing is down, latency is fine, and the
product is quietly worse. The table covers both, and the responses to the
second kind are process machinery (canaries, guardrails, rollbacks), not
just engineering ones.

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

Two rows deserve a second read. *One candidate channel down* is the blend
architecture justifying itself in reverse: because quotas are soft and
channels independent, losing the ANN index for an hour means the feed gets
slightly less semantic and slightly more social — users notice nothing, the
coverage SLO does. Design the mixture so that any single ingredient can
fail and the meal survives; "no single point of taste" is the recommender's
version of "no single point of failure." And *ranker overload* shows the
budget's graceful-degradation ladder: the first response to latency
pressure is not adding machines but *scoring fewer candidates* — 5k to 1k
— because the funnel's shape means relevance degrades logarithmically while
latency degrades linearly. You are allowed to buy time with recall at the
margin; that dial exists only because retrieval over-fetches in the first
place.

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

The *model freshness* row is the one interviewers most often push on, so
have the argument ready: online learning (updating weights per event) is
fresher by four orders of magnitude, and it is still rejected — because a
model that changes continuously is a model you cannot roll back (which
yesterday's weights do you return to?), a feedback-loop amplifier (a bad
update trains on the behavior the bad update caused), and a distributed-systems
nightmare (which replica's gradient wins?). The chapter's chosen split —
frozen daily model + real-time *features* — buys nearly all the practical
freshness (the feed reacts in seconds, Section 7.8) while keeping the
artifact under version control. Freshness is a spectrum; put the *weights*
at the stable end and the *inputs* at the volatile end. The *feed
consistency* row is its mirror image: pin the candidate set at session
start (cursor = snapshot) so infinite scroll never reshuffles beneath the
user's thumb — in a system whose entire purpose is reacting to the user,
the scroll itself must be the one thing that holds still.

== Observability & SLOs

Two metric families — system health (Chapter 4's bread and butter) and
*quality* health, which only this kind of system has. The second family is
the novelty: a recommender can be perfectly available, perfectly fast, and
perfectly terrible, and only quality metrics can tell you.

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

Note how the table's rows trace the chapter's anatomy: candidate coverage
watches the blend (a silently dead channel shows here first), exploration
health watches the quota (the feedback loop's open door, measured), model
freshness watches the factory. Every structural claim made earlier has a
row that would catch its violation — that correspondence between design and
dashboard is what "operable" means for an ML system.

#insight([Guardrail metrics are the product's conscience])[
  Every optimization target can be gamed by the optimizer itself: CTR
  invites clickbait, watch time invites doomscrolling. Production
  recommenders therefore ship *pairs* of metrics — the objective and the
  guardrails (diversity, negative feedback, long-term retention) — and a
  model that improves the objective while moving a guardrail does not
  ship. Encoding this in the deploy pipeline is systems work, and it is
  the difference between a recommender and a slot machine.
]

== Interview Wrap-Up

Likely follow-ups, and the shape of strong answers:

+ *"Make it real-time: the feed reacts to every watch instantly."* Already
  half-built: session features update in seconds. The next step — updating
  the *user embedding* mid-session — is streaming inference, not training:
  recompute the user vector from the new history with the frozen item
  tower. True online weight updates trade the rollback story for freshness;
  say what you'd be giving up (Section 7.16's freshness row, out loud).
+ *"A new creator with zero viewers — how do they ever surface?"* The
  exploration quota (Section 7.9) plus *content-based* features: with no
  watch history, the video's own metadata (category, title embeddings,
  thumbnail features) place it near known items. First impressions go to
  users whose taste vector is near the *content* vector — cold start is
  why content features exist at all.
+ *"TikTok vs. YouTube — what differs in the system?"* The graph: YouTube
  leans on subscriptions (the follows channel is strong); TikTok is
  graph-free — nearly pure engagement ranking, which makes its exploration
  quota and per-session adaptation much larger shares of the mix. Same
  funnel, different quotas. *Architecture is the constants* — a sentence
  worth saying verbatim, because it reframes a product comparison as a
  parameter comparison.
+ *"Where do ads fit?"* A second ranking system with its own objective
  (expected revenue × relevance), blended into slots by an auction — and
  the reason feed slots are strictly partitioned between organic and
  sponsored before re-ranking. Two objectives never share one scoring
  pass; they share a layout.
+ *"How would you detect the model amplifying harmful content?"* Guardrail
  metrics per content class, policy-gate recalls, and audit sampling of
  what the exploration pool promotes — plus the honest answer: ranking
  amplifies whatever the objective correlates with, so this is fought at
  the objective-and-guardrail layer, not with filters alone.

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
- Sutton & Barto, _Reinforcement Learning_ — the multi-armed bandit
  chapters behind Section 7.9's exploration quota.
- Chapter 4's monitoring reading applies twice here — guardrail metrics
  are SLOs with a conscience.

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
    — End of Chapter 7 · Next: Chapter 8, Designing a Database Index: How B-Trees Work —
  ]
]
